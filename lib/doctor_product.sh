# shellcheck shell=bash
# shellcheck disable=SC2034 # Résultats partagés avec doctor.sh et sa présentation.
# Contrôles de pose : lecteurs seulement, aucun préflight ni rejeu.
doctor_version_read() {
  local version part prerelease
  [ -f "$1/VERSION" ] && [ -r "$1/VERSION" ] || return 1
  version="$(awk 'NR != 1 || !NF {bad=1} {v=$0} END {if (NR!=1 || bad) exit 1; print v}' "$1/VERSION" 2>/dev/null)" || return 1
  [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]] || return 1
  prerelease="${version%%+*}"
  case "$prerelease" in *-*)
    prerelease="${prerelease#*-}"
    while :; do
      part="${prerelease%%.*}"
      if [[ "$part" =~ ^[0-9]+$ ]] && [ "${#part}" -gt 1 ] && [ "${part:0:1}" = 0 ]; then return 1; fi
      case "$prerelease" in *.*) prerelease="${prerelease#*.}" ;; *) break ;; esac
    done ;;
  esac
  printf '%s\n' "$version"
}
# doctor_manifest_metadata : les métadonnées de chaque ligne — aucun retrait en cours, row et after lisibles, after = la valeur de la
# ligne, dossier en 700, row = la ligne préparée (after « pending », sauf un skip) ; la première ligne fausse décide. Lot 03 de
# charge-processeur : verdict rendu par le passage de la validation (LAB_TXN_META), sinon par une lecture perl de plus
doctor_manifest_metadata() {
  local m="${LAB_TXN_META:-}"
  [ -n "$m" ] || m="$(perl -e "$TXN_FACTS_PL" meta "$LAB_TXN_MANIFEST" "$LAB_TXN_BACKUPS" 2>/dev/null | sed -n 's/^meta\t//p')"
  case "$m" in ok) return 0 ;; removal) DOC_MANIFEST_CAUSE=REMOVAL_PENDING; return 1 ;; *) return 1 ;; esac
}
# doctor_setup_info : _setup_info, sans relire le manifeste que la validation vient de lire (lot 03 de charge-processeur : 13 % de son
# travail) — mêmes lignes, toutes découpées par _txn_parse, en-tête seulement en tête, dernière ligne terminée : la note de pose en sort
# telle quelle. Validation d'un autre manifeste, ou ligne skip sans note : la relecture d'avant.
doctor_setup_info() {
  [ "${LAB_TXN_SETUP_FOR:-}" = "$LAB_TXN_MANIFEST" ] || { _setup_info; return; }
  LAB_SETUP_INFO="$LAB_TXN_SETUP_NOTE"; _setup_info_check
}
doctor_product_context() {
  DOC_CLAUDE=yes; DOC_CODEX=yes; DOC_INSTALLED=no; DOC_COLLISIONS=0; DOC_SETUP_TXN=''
  DOC_HOOK_ROOT="$LAB_INSTALL_ROOT"; DOC_RELEASE=no; DOC_MANIFEST_CAUSE=MANIFEST_INVALID
  [ ! -f "$LAB_INSTALL_ROOT/.release" ] || DOC_RELEASE=yes
  . "$LAB_ROOT/lib/install_merge.sh"
  . "$LAB_ROOT/lib/install.sh"
  . "$LAB_ROOT/lib/setup.sh"
  . "$LAB_ROOT/lib/update.sh"
  _update_register
  local valid=no info=no line
  local backup pending=no
  for backup in "$LAB_STATE/backups"/txn.*; do
    if [ -e "$backup" ] || [ -L "$backup" ]; then pending=yes; break; fi
  done
  if [ ! -e "$LAB_STATE/install-manifest.tsv" ] && [ ! -L "$LAB_STATE/install-manifest.tsv" ] && [ "$pending" = no ]; then
    DOC_MANIFEST_CAUSE=MANIFEST_MISSING
  elif _txn_paths && _txn_validate_manifest; then
    if [ -f "$LAB_TXN_MANIFEST" ] && doctor_setup_info && [ -n "$LAB_SETUP_INFO" ]; then info=yes; fi
    if ! _txn_pending; then DOC_MANIFEST_CAUSE=MANIFEST_INVALID
    elif [ -n "$LAB_TXN_PENDING" ]; then DOC_MANIFEST_CAUSE=TRANSACTION_PENDING
    elif [ -f "$LAB_TXN_MANIFEST" ]; then
      if [ "$info" = yes ] && doctor_manifest_metadata; then valid=yes; fi
    else DOC_MANIFEST_CAUSE=MANIFEST_MISSING
    fi
  fi
  # Les sélections restent lisibles même lorsqu'une reprise est nécessaire.
  if [ "$info" = yes ]; then
    DOC_INSTALLED=yes
    DOC_CLAUDE="$(printf '%s' "$LAB_SETUP_INFO" | jq -r .claude)"
    DOC_CODEX="$(printf '%s' "$LAB_SETUP_INFO" | jq -r .codex)"
    DOC_HOOK_ROOT="$(printf '%s' "$LAB_SETUP_INFO" | jq -r .root)"
    # Une surcharge explicite reste prioritaire ; une release contrôle sa copie.
    if [ "$DOC_ROOT_EXPLICIT" != yes ] && [ "$DOC_RELEASE" != yes ]; then
      LAB_INSTALL_ROOT="$(real_path "$DOC_HOOK_ROOT")"
      SKILLS_DIR="${LAB_SKILLS_DIR:-$LAB_INSTALL_ROOT/skills}"
    fi
    LAB_CLAUDE_HOME="${LAB_CLAUDE_HOME:-$(printf '%s' "$LAB_SETUP_INFO" | jq -r .claude_home)}"
    LAB_CODEX_HOME="${LAB_CODEX_HOME:-${CODEX_HOME:-$(printf '%s' "$LAB_SETUP_INFO" | jq -r .codex_home)}}"
    LAB_AGENTS_HOME="${LAB_AGENTS_HOME:-$(printf '%s' "$LAB_SETUP_INFO" | jq -r .agents_home)}"
    LAB_CLAUDE_SETTINGS="${LAB_CLAUDE_SETTINGS:-$(printf '%s' "$LAB_SETUP_INFO" | jq -r .settings)}"
    while IFS= read -r line; do
      [ "$line" != $'treelab-install\t1' ] || continue
      _txn_parse "$line" || break
      case "${LAB_TXN_FIELDS[8]:-}" in treelab-setup-v1:*) DOC_SETUP_TXN="${LAB_TXN_FIELDS[0]}" ;; esac
    done <"$LAB_TXN_MANIFEST"
  fi
  if [ "$valid" = yes ]; then flag install.manifest.ok ok yes 'Manifest and backups consistent; no resumption pending.'
  else
    case "$DOC_MANIFEST_CAUSE:$DOC_RELEASE" in
      MANIFEST_MISSING:no) flag install.manifest.ok warn historical 'Historical development without a manifest; integrations checked separately.' HISTORICAL ;;
      TRANSACTION_PENDING:*|REMOVAL_PENDING:*) flag install.manifest.ok red incomplete 'Resumption pending: keep the backups, fix the cause, then run treelab uninstall --resume.' "$DOC_MANIFEST_CAUSE" ;;
      *) flag install.manifest.ok red invalid 'Manifest or backups missing, unreadable or inconsistent: keep them and restore their complete copy before any installation.' "$DOC_MANIFEST_CAUSE" ;;
    esac
  fi
  doctor_product_checks
}
doctor_product_checks() {
  local installed executed command_path license mode
  installed="$(doctor_version_read "$LAB_INSTALL_ROOT")" || installed=''
  executed="$(doctor_version_read "$LAB_ROOT")" || executed=''
  if [ -n "$executed" ] && [ "$DOC_RELEASE" = no ] && [ "$DOC_MANIFEST_CAUSE" = MANIFEST_MISSING ] &&
     [ ! -e "$LAB_INSTALL_ROOT/.release" ] && [ ! -L "$LAB_INSTALL_ROOT/.release" ] &&
     [ ! -e "$LAB_INSTALL_ROOT/VERSION" ] && [ ! -L "$LAB_INSTALL_ROOT/VERSION" ] &&
     [ -f "$LAB_INSTALL_ROOT/bin/lab" ] && [ -x "$LAB_INSTALL_ROOT/bin/lab" ]; then
    flag install.version warn unknown "Historical development copy without VERSION: $LAB_INSTALL_ROOT; unknown version. Doctor running: $executed. Check where it comes from before an update." VERSION_UNKNOWN
  elif [ -z "$installed" ] || [ -z "$executed" ]; then
    flag install.version red unavailable "VERSION missing, unreadable or invalid; restore the complete copy: $LAB_INSTALL_ROOT (running: $LAB_ROOT)." VERSION_INVALID
  elif [ "$installed" != "$executed" ]; then
    flag install.version warn "$installed" "Checked version: $installed; running: $executed. Use the command of the checked installation." VERSION_DIFFERENT
  else flag install.version ok "$installed" 'Version of the checked copy.'; fi
  command_path="$(command -v treelab || true)"
  if [ ! -x "$LAB_INSTALL_ROOT/bin/lab" ] || { [ "$DOC_INSTALLED" = yes ] && [ ! "$DOC_HOOK_ROOT" -ef "$LAB_INSTALL_ROOT" ]; }; then
    flag install.path red target "Wrong copy or broken current link: $DOC_HOOK_ROOT; point the link back to the checked copy: $LAB_INSTALL_ROOT." ROOT_INVALID
  elif [ "$DOC_RELEASE" = yes ] && { [ ! "$HOME/.lab/current" -ef "$LAB_INSTALL_ROOT" ] || [ ! -x "$command_path" ] || [ ! "$command_path" -ef "$LAB_INSTALL_ROOT/bin/lab" ]; }; then
    flag install.path red unreachable "Check that current points to $LAB_INSTALL_ROOT and put $HOME/.local/bin in PATH; treelab must point to this installation." PATH_INVALID
  else flag install.path ok yes 'Command reachable; running it directly is allowed in development.'; fi
  command_path="$(command -v lab || true)"
  if [ -x "$command_path" ] && [ "$command_path" -ef "$LAB_INSTALL_ROOT/bin/lab" ]; then
    flag install.lab-cli.conflict ok no 'The name lab points to Treelab.'
  else flag install.lab-cli.conflict warn yes 'The name lab is foreign, hidden or missing; use treelab. No unknown command was run.' SHORT_NAME ; fi
  license="$LAB_HOME/license"
  if [ ! -e "$license" ] && [ ! -L "$license" ]; then
    if [ "$DOC_RELEASE" = no ]; then flag install.license ok missing 'No license needed in development.' LICENSE_DEV
    else flag install.license warn missing "Local license missing; put the provided file at $license with mode 0600. Activation not checked." LICENSE_MISSING; fi
  else
    mode="$(stat -f %Lp "$license" 2>/dev/null || true)"
    if [ ! -L "$license" ] && [ -f "$license" ] && [ -s "$license" ] && [ -r "$license" ] && [ "$mode" = 600 ]; then
      flag install.license ok present 'Present locally, activation not checked.' LICENSE_PRESENT
    else flag install.license warn to-check "Local license: $license; use a regular, non-empty, readable file, not a link, with mode 0600. Activation not checked." LICENSE_CHECK; fi
  fi
  doctor_entitlement
}
# doctor_entitlement : fin des droits aux mises à jour, cache local seul (lot 05 de refonte-onboarding) ; WARN pour une fin proche
# ou passée, jamais rouge (à l'arrêt, rien ne casse) ; aucune lecture de la licence ni du réseau
doctor_entitlement() {
  declare -F entitlement_state >/dev/null || . "$LAB_ROOT/lib/entitlement.sh"
  entitlement_state
  case "$ENT_STATE" in
    ending|ended) flag install.entitlement warn "$ENT_STATE" "$(entitlement_line "$ENT_STATE")" "ENTITLEMENT_$(printf '%s' "$ENT_STATE" | tr '[:lower:]' '[:upper:]')" ;;
    active) flag install.entitlement ok active "Updates included until $(entitlement_day "$ENT_UNTIL") (UTC); read on $(entitlement_day "$ENT_CHECKED") by treelab update." ENTITLEMENT_ACTIVE ;;
    none) flag install.entitlement ok none 'Updates without an end date.' ENTITLEMENT_NONE ;;
    *) flag install.entitlement ok unknown 'Update rights not read yet; treelab update reads them.' ENTITLEMENT_UNKNOWN ;;
  esac
}
