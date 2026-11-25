# shellcheck shell=bash
# shellcheck disable=SC2030,SC2031 # Le plan est isolé ; txn_begin crée l'état réel ensuite.
# Plan de pose commun à la simulation et à l'exécution ; temporaires hors du compte.

_setup_all_done() {
  local line d
  [ -f "$LAB_TXN_MANIFEST" ] || return 0
  while IFS= read -r line; do
    [ "$line" != $'treelab-install\t1' ] || continue
    _txn_parse "$line" || return
    d="$LAB_TXN_BACKUPS/${LAB_TXN_FIELDS[0]}/${LAB_TXN_FIELDS[1]}"
    [ -f "$d/done" ] || return 1
  done <"$LAB_TXN_MANIFEST"
}
_setup_archive() {
  local dir line id seen='|'
  _setup_all_done || return 1
  [ -f "$LAB_TXN_MANIFEST" ] || return 0
  dir="$(mktemp -d "$LAB_TXN_BACKUPS/archive.XXXXXXXX")" || return
  _txn_copy "$LAB_TXN_MANIFEST" "$dir/install-manifest.tsv" || return
  # Sceller avant de retirer le manifeste actif : les sauvegardes archivées ne
  # doivent jamais être considérées comme une transaction en attente de rollback.
  while IFS= read -r line; do
    [ "$line" != $'treelab-install\t1' ] || continue
    _txn_parse "$line" || return
    id="${LAB_TXN_FIELDS[0]}"
    case "$seen" in *"|$id|"*) continue ;; esac
    seen="$seen$id|"
    _txn_write "$LAB_TXN_BACKUPS/$id/retired" treelab-retired-v1 || return
  done <"$LAB_TXN_MANIFEST"
  cmp -s "$LAB_TXN_MANIFEST" "$dir/install-manifest.tsv" && rm "$LAB_TXN_MANIFEST"
}
_setup_remove_kind() {
  local path="$1" field candidate
  [ -n "$LAB_SETUP_INFO" ] || return 1
  for field in settings claude_home codex_home profile; do
    candidate="$(printf '%s' "$LAB_SETUP_INFO" | jq -r ".$field")"
    case "$field" in
      claude_home) candidate="$candidate/CLAUDE.md" ;;
      codex_home)
        if [ "$path" = "$(_txn_resolve_modify "$candidate/hooks.json" 2>/dev/null)" ]; then printf 'hooks\n'; return 0; fi
        candidate="$candidate/AGENTS.md" ;;
    esac
    [ -n "$candidate" ] || continue
    if [ "$path" = "$(_txn_resolve_modify "$candidate" 2>/dev/null)" ]; then
      case "$field" in settings) printf 'hooks\n' ;; profile) printf 'shell\n' ;; *) printf 'block\n' ;; esac
      return 0
    fi
  done
  return 1
}
_setup_remove_prepare() (
  local path="$1" kind="$2" output="$3" temp="$4"
  export LAB_TXN_ACTIVE="$temp" LAB_TXN_SEQ=0
  # shellcheck disable=SC2329
  _merge_publish() { cp -p "$2" "$output"; }
  cp -p "$path" "$output" || return
  case "$kind" in
    hooks) hooks_remove "$path" "$(printf '%s' "$LAB_SETUP_INFO" | jq -r .root)" && _setup_legacy_restore "$path" "$output" ;;
    block) block_remove "$path" ;;
    shell) shell_block_remove "$path" ;;
    *) return 1 ;;
  esac
)
# Retrait sélectif d'un fichier de hooks modifié depuis la pose : les hooks de l'installation importée que setup --import avait
# retirés reviennent depuis la plus ancienne sauvegarde de cette cible, sauf ceux déjà présents ; les ajouts clients restent.
_setup_legacy_restore() {
  local target="$1" output="$2" legacy line d before='' restored
  legacy="$(printf '%s' "$LAB_SETUP_INFO" | jq -c '.legacy_hooks // []')" || return
  [ "$legacy" != '[]' ] && [ -f "$LAB_TXN_MANIFEST" ] || return 0
  while IFS= read -r line; do
    [ "$line" != $'treelab-install\t1' ] || continue
    _txn_parse "$line" || return 1
    d="$LAB_TXN_BACKUPS/${LAB_TXN_FIELDS[0]}/${LAB_TXN_FIELDS[1]}"
    if [ "${LAB_TXN_FIELDS[3]}" = "$target" ] && [ -f "$d/before" ] && [ ! -L "$d/before" ]; then before="$d/before"; break; fi
  done <"$LAB_TXN_MANIFEST"
  [ -n "$before" ] || return 0
  restored="$(mktemp "$LAB_TXN_ACTIVE/restore.XXXXXXXX")" || return
  jq --slurpfile before "$before" --argjson legacy "$legacy" "$LAB_MERGE_LEGACY_JQ"'
    reduce ($before[0].hooks // {} | to_entries[] | select(.value | type == "array")) as $e (.;
      reduce ($e.value[] | select(type == "object" and (.hooks | type == "array"))) as $g (.;
        [.hooks[$e.key][]?.hooks[]?.command] as $present
        | [$g.hooks[] | select(legacy_hook) | select(.command as $c | any($present[]; . == $c) | not)] as $add
        | if ($add | length) > 0 then .hooks[$e.key] = ((.hooks[$e.key] // []) + [$g | .hooks = $add]) else . end))
  ' "$output" >"$restored" || { rm -f "$restored"; return 1; }
  cat "$restored" >"$output" && rm -f "$restored"
}
_setup_directory_retained() {
  # targets/projected appartiennent au plan appelant (portée dynamique bash 3.2).
  local child j future
  for child in "$1"/.[!.]* "$1"/..?* "$1"/*; do
    _txn_exists "$child" || continue
    future=present; j=0
    while [ "$j" -lt "${#targets[@]}" ]; do
      if [ "${targets[j]}" = "$child" ]; then future="${projected[j]}"; break; fi
      j=$((j + 1))
    done
    [ "$future" = absent ] || return 0
  done
  return 1
}
uninstall_plan() (
  local temp="$1" line rows=() i d target action current after before kind prepared seen='|'
  local targets=() projected=() j index
  : >"$temp/plan"; : >"$temp/consent"
  _setup_info || return
  [ -f "$LAB_TXN_MANIFEST" ] || return 0
  while IFS= read -r line; do rows+=("$line"); done <"$LAB_TXN_MANIFEST"
  i=$((${#rows[@]} - 1))
  while [ "$i" -ge 1 ]; do
    line="${rows[i]}"; i=$((i - 1))
    _txn_parse "$line" || return
    d="$LAB_TXN_BACKUPS/${LAB_TXN_FIELDS[0]}/${LAB_TXN_FIELDS[1]}"
    target="${LAB_TXN_FIELDS[3]}"; action="${LAB_TXN_FIELDS[2]}"
    before="${LAB_TXN_FIELDS[4]}"; after="${LAB_TXN_FIELDS[5]}"
    [ ! -f "$d/done" ] || continue
    case "$seen" in *"|$target|"*) continue ;; esac
    if [ "$action" = skip ]; then
      _txn_row skip "$target" "$d" '' '' '' '' '' >>"$temp/plan"; continue
    fi
    _preflight_source_safe "$target" && _preflight_writable "$(dirname "$target")" || return
    current="$(_txn_fingerprint "$target")" || return
    # Simuler les versions successives d'une cible : le second inverse verra
    # l'objet restauré par le premier, pas l'objet encore présent avant le retrait.
    j=0; index=${#targets[@]}
    while [ "$j" -lt "${#targets[@]}" ]; do
      if [ "${targets[j]}" = "$target" ]; then index=$j; current="${projected[j]}"; break; fi
      j=$((j + 1))
    done
    prepared=''
    if _update_retained_target "$target"; then
      action='keep-release'; before="$current"; seen="$seen$target|"
    elif [ "$action" = cmd ] && [ "${LAB_TXN_FIELDS[6]}" = _merge_unlink ] && [ "$after:$current" = absent:absent ]; then
      # Un retrait attribué est déjà l'état voulu de la désinstallation. Son
      # inverse ne doit pas ressusciter les intégrations des anciennes releases.
      action='forget-removal'; before=absent; seen="$seen$target|"
    elif [ -d "$d/retirement" ]; then
      action=resume-retire; before=retained
    elif [ "$action" = mkdir ]; then
      if _setup_directory_retained "$target"; then action='keep-directory'; before=retained
      else action=directory; fi
    elif [ "$current" != "$after" ] && [ "$current" != "$before" ]; then
      if [ -f "$target" ] && [ ! -L "$target" ] && kind="$(_setup_remove_kind "$target")"; then
        prepared="$(mktemp "$temp/removal.XXXXXXXX")" || return
        _setup_remove_prepare "$target" "$kind" "$prepared" "$temp" || return
        action=retire; seen="$seen$target|"; before=retained
      elif [ "${LAB_TXN_FIELDS[2]}" = replace ] && [ -d "$target" ] && [ -L "$d/before" ]; then
        # Les enfants attribués seront retirés avant la restauration du lien.
        action=migration
      else
        _setup_message "Incomplete removal: $target has changed. Keep the recent data, restore the installed object from $d, then run uninstall --resume."
        return 1
      fi
    else action=undo
    fi
    targets[index]="$target"; projected[index]="$before"
    printf '%s\n' "$line" >"$temp/row-$i"
    _txn_row "$action" "$target" "$d" "$prepared" "$temp/row-$i" '' '' '' >>"$temp/plan"
    _txn_row "$action" "$target" "$current" "${prepared:+$(shasum -a 256 <"$prepared" | cut -d ' ' -f 1)}" '' '' '' '' >>"$temp/consent"
    if [ "$action" = keep-directory ]; then _setup_message "Keep the folder: $target"
    else _setup_message "Planned removal: $target"; fi
  done
)
_setup_uninstall_apply() {
  local plan="$1" row action target d prepared line
  # La phase précède tout inverse, et reste liée aux seules transactions à retirer.
  while IFS= read -r row; do
    [ "$row" != $'treelab-install\t1' ] || continue
    _txn_parse "$row" || return
    d="$LAB_TXN_BACKUPS/${LAB_TXN_FIELDS[0]}"
    if [ ! -f "$d/${LAB_TXN_FIELDS[1]}/done" ] && [ ! -f "$d/remove-started" ]; then
      _txn_write "$d/remove-started" treelab-removal-v1 || return
    fi
  done <"$LAB_TXN_MANIFEST"
  while IFS= read -r row; do
    _txn_parse "$row" || return
    action="${LAB_TXN_FIELDS[0]}"; target="${LAB_TXN_FIELDS[1]}"; d="${LAB_TXN_FIELDS[2]}"
    prepared="${LAB_TXN_FIELDS[3]}"; line="${LAB_TXN_FIELDS[4]}"
    case "$action" in
      keep-release|forget-removal) _txn_retirement_ack "$d" "$target" || return ;;
      skip) _txn_write "$d/done" 'done' || return ;;
      keep-directory)
        _setup_message "Folder kept with its data: $target"
        _txn_write "$d/done" 'done' || return ;;
      directory)
        if [ -d "$target" ]; then
          if rmdir "$target" 2>/dev/null; then :
          else
            local child occupied=no
            for child in "$target"/.[!.]* "$target"/..?* "$target"/*; do
              if _txn_exists "$child"; then occupied=yes; break; fi
            done
            if [ "$occupied" = yes ]; then _setup_message "Folder kept with its data: $target"
            else _setup_message "Empty folder cannot be removed: $target. Fix the permissions, then resume with uninstall --resume."; return 1; fi
          fi
        fi
        _txn_write "$d/done" 'done' || return ;;
      retire) uninstall_retire "$target" "$prepared" || return ;;
      resume-retire) _txn_retirement_apply "$d" "$target" || return ;;
      undo|migration) _txn_undo_row "$(cat "$line")" yes || return ;;
      *) return 1 ;;
    esac
  done <"$plan"
}
cmd_uninstall() (
  local option dry=no keep=no temp check
  export LAB_SETUP_MODE=uninstall LAB_SETUP_RESUME=no
  for option in "$@"; do
    case "$option" in --dry-run) dry=yes ;; --keep-state) keep=yes ;; --resume) LAB_SETUP_RESUME=yes ;;
      *) _setup_message "Unknown uninstall option: $option. Use uninstall [--dry-run] [--keep-state] [--resume]."; return 2 ;;
    esac
  done
  LAB_PREFLIGHT_ERRORS=0; _preflight_system
  [ "$LAB_PREFLIGHT_ERRORS" = 0 ] || return 1
  operation_acquire || { _setup_message 'Another operation is running. Wait for it to finish, then run treelab uninstall again.'; return 1; }
  trap 'operation_release' EXIT
  _setup_operation_guard || return 1
  merge_register_commands
  preflight || return
  if [ -n "$LAB_TXN_PENDING" ]; then
    _setup_message "Restore needed first: $LAB_TXN_PENDING. Backups kept."
    _setup_resume_guard "$LAB_TXN_PENDING" || return
    if [ "$dry" = yes ]; then kv RESULT simulated; _setup_message 'Dry run: a restore is needed first, then the removal will be computed again.'; return 0; fi
    _setup_confirm 'Resume the unfinished restore before preparing the Treelab removal?' || return
    _setup_resume_guard "$LAB_TXN_PENDING" || return
    txn_rollback || {
      _setup_resume_capture || true
      _setup_message "Fix the cause, then run $(shell_quote "$LAB_ROOT/bin/lab") uninstall --resume"; return 1
    }
  fi
  # lot 04 de pilotage-voix : les gestes Ginkgo (app arrêtée, micro oublié, clé et dossier retirés) entrent au plan et au consentement
  . "$LAB_ROOT/lib/ginkgo.sh"
  temp="$(mktemp -d /private/tmp/treelab-uninstall.XXXXXXXX)" || return
  trap 'rm -R "$temp"; operation_release' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if _setup_all_done; then
    ginkgo_uninstall_plan "$keep" alone >"$temp/ginkgo"
    if [ ! -s "$temp/ginkgo" ]; then
      _setup_message 'Nothing to uninstall.'
      if [ "$dry" = no ] && [ "$keep" = no ]; then _setup_archive || return; fi
      kv RESULT absent; return 0
    fi
    _setup_message 'No Treelab integration left to remove; Ginkgo still has the steps below.'
    ginkgo_uninstall_show "$temp/ginkgo"
    if [ "$dry" = yes ]; then kv RESULT simulated; _setup_message 'Dry run finished; nothing removed.'; return 0; fi
    _setup_confirm 'Do the Ginkgo steps listed above?' || return
    ginkgo_uninstall_plan "$keep" alone >"$temp/ginkgo-check"
    cmp -s "$temp/ginkgo" "$temp/ginkgo-check" || { _setup_message 'The removal plan has changed; run uninstall again to confirm the new effects.'; return 1; }
    ginkgo_uninstall_apply "$temp/ginkgo"
    if [ "$keep" = no ]; then _setup_archive || return; fi
    kv RESULT uninstalled; return 0
  fi
  uninstall_plan "$temp" || return
  ginkgo_uninstall_plan "$keep" >"$temp/ginkgo"; ginkgo_uninstall_show "$temp/ginkgo"; cat "$temp/ginkgo" >>"$temp/consent"
  _setup_message "Backups stay in $LAB_STATE/backups."
  _setup_message 'Registries, earlier settings, repositories, project trusts and exclusions are kept. cmux stays installed.'
  if [ "$keep" = yes ]; then _setup_message "Installation state kept and marked as removed."
  else _setup_message 'After removal, the finished log is archived with the backups.'; fi
  if [ "$dry" = yes ]; then kv RESULT simulated; _setup_message 'Dry run finished; nothing removed.'; return 0; fi
  _setup_confirm 'Remove the Treelab integrations and commands listed above?' || return
  check="$temp/check"; mkdir "$check"
  preflight && uninstall_plan "$check" || return
  ginkgo_uninstall_plan "$keep" >"$check/ginkgo"; cat "$check/ginkgo" >>"$check/consent"
  if ! cmp -s "$temp/consent" "$check/consent"; then
    _setup_message 'The removal plan has changed; run uninstall again to confirm the new effects.'; return 1
  fi
  if ! _setup_uninstall_apply "$check/plan"; then
    _setup_message "Incomplete removal. Backups: $LAB_STATE/backups. Fix the cause, then run $(shell_quote "$LAB_ROOT/bin/lab") uninstall --resume"
    return 1
  fi
  if ! _setup_all_done; then
    _setup_message 'Incomplete removal: user data prevents restoring a legacy link.'
    local line d
    while IFS= read -r line; do
      [ "$line" != $'treelab-install\t1' ] || continue
      _txn_parse "$line" || return
      d="$LAB_TXN_BACKUPS/${LAB_TXN_FIELDS[0]}/${LAB_TXN_FIELDS[1]}"
      if [ ! -f "$d/done" ]; then
        _setup_message "Kept: ${LAB_TXN_FIELDS[3]}. Set the recent data aside, then restore the link saved in $d/before."
      fi
    done <"$LAB_TXN_MANIFEST"
    _setup_message "To resume: $(shell_quote "$LAB_ROOT/bin/lab") uninstall --resume"
    return 1
  fi
  ginkgo_uninstall_apply "$check/ginkgo"
  if [ "$keep" = no ]; then _setup_archive || return; fi
  kv RESULT uninstalled
  _setup_message "Uninstall finished. Backups kept: $LAB_STATE/backups"
)
_setup_message() { lab_say "$*"; }
_setup_profile() {
  local shell="${SHELL:-}"
  case "${shell##*/}" in
    zsh) printf '%s/.zprofile\n' "${ZDOTDIR:-$HOME}" ;;
    bash)
      local file
      for file in .bash_profile .bash_login .profile; do
        if _txn_exists "$HOME/$file"; then printf '%s/%s\n' "$HOME" "$file"; return; fi
      done
      printf '%s/.bash_profile\n' "$HOME" ;;
    *) _setup_message "Unknown shell profile: ${SHELL:-none}. Add $HOME/.local/bin to PATH by hand." ;;
  esac
}
_setup_info() {
  LAB_SETUP_INFO=''
  local line note
  [ -f "$LAB_TXN_MANIFEST" ] || return 0
  while IFS= read -r line; do
    [ "$line" != $'treelab-install\t1' ] || continue
    _txn_parse "$line" || return 1
    if [ "${LAB_TXN_FIELDS[2]}" = skip ]; then
      note="${LAB_TXN_FIELDS[8]}"
      case "$note" in treelab-setup-v1:*) LAB_SETUP_INFO="${note#treelab-setup-v1:}" ;; esac
    fi
  done <"$LAB_TXN_MANIFEST"
  _setup_info_check
}
# _setup_info_check : LAB_SETUP_INFO vide, ou l'objet de la première pose, valide
_setup_info_check() {
  [ -n "$LAB_SETUP_INFO" ] || return 0
  printf '%s' "$LAB_SETUP_INFO" | jq -e '
    type=="object" and (.root|type=="string" and startswith("/")) and
    (.claude=="yes" or .claude=="no") and (.codex=="yes" or .codex=="no") and
    ([.claude_home,.codex_home,.agents_home,.settings,.profile]|all(type=="string")) and
    ((has("legacy_hooks")|not) or (.legacy_hooks|type=="array" and all(.[]; type=="string" and startswith("/"))))
  ' >/dev/null || { _setup_message 'Invalid installation information; keep the manifest and the backups.'; return 1; }
}
_setup_configuration() {
  if [ "${LAB_SETUP_DEV:-no}" = yes ]; then LAB_SETUP_ROOT="$LAB_ROOT"
  else
    LAB_SETUP_ROOT="$HOME/.lab/current"
    # treelab update --adopt (lot 22) : current désigne encore la release quittée, LAB_UPDATE_FROM.
    if [ ! -d "$LAB_SETUP_ROOT" ] || [ ! "$LAB_SETUP_ROOT" -ef "${LAB_UPDATE_FROM:-$LAB_ROOT}" ]; then
      _preflight_error "$LAB_SETUP_ROOT" 'Point the current link to this local copy, or use setup --dev for a checkout.'; return 1
    fi
  fi
  LAB_SETUP_PROFILE="$(_setup_profile)"
  _setup_info || return
  local legacy='[]' file
  [ -z "$LAB_SETUP_INFO" ] || legacy="$(printf '%s' "$LAB_SETUP_INFO" | jq -c '.legacy_hooks // []')"
  if [ -n "$LAB_SETUP_INFO" ]; then
    LAB_SETUP_ROOT="$(printf '%s' "$LAB_SETUP_INFO" | jq -r .root)"
    LAB_SETUP_CLAUDE="$(printf '%s' "$LAB_SETUP_INFO" | jq -r .claude)"
    LAB_SETUP_CODEX="$(printf '%s' "$LAB_SETUP_INFO" | jq -r .codex)"
    LAB_SETUP_PROFILE="$(printf '%s' "$LAB_SETUP_INFO" | jq -r .profile)"
    # Les destinations attribuées restent celles de la première pose.
    LAB_CLAUDE_HOME="$(printf '%s' "$LAB_SETUP_INFO" | jq -r .claude_home)"
    LAB_CODEX_HOME="$(printf '%s' "$LAB_SETUP_INFO" | jq -r .codex_home)"
    LAB_AGENTS_HOME="$(printf '%s' "$LAB_SETUP_INFO" | jq -r .agents_home)"
    LAB_CLAUDE_SETTINGS="$(printf '%s' "$LAB_SETUP_INFO" | jq -r .settings)"
    export LAB_CLAUDE_HOME LAB_CODEX_HOME LAB_AGENTS_HOME LAB_CLAUDE_SETTINGS
  fi
  # setup --import : les préfixes des hooks retirés restent connus de lab uninstall, même après une pose suivante.
  if [ -n "${LAB_SETUP_IMPORT:-}" ]; then
    for file in "$(_setup_hooks_file claude)" "$(_setup_hooks_file codex)"; do
      [ -z "$file" ] || legacy="$(jq -cn --argjson a "$legacy" --argjson b "$(_merge_legacy_prefixes "$file")" '$a + $b | unique')"
    done
  fi
  LAB_SETUP_INFO="$(jq -cn --arg root "$LAB_SETUP_ROOT" --arg claude "$LAB_SETUP_CLAUDE" --arg codex "$LAB_SETUP_CODEX" \
    --arg claude_home "$(claude_home)" --arg codex_home "$(codex_home)" --arg agents_home "$(agents_home)" \
    --arg settings "${LAB_CLAUDE_SETTINGS:-$(claude_home)/settings.json}" --arg profile "$LAB_SETUP_PROFILE" --argjson legacy "$legacy" \
    '{root:$root,claude:$claude,codex:$codex,claude_home:$claude_home,codex_home:$codex_home,agents_home:$agents_home,settings:$settings,profile:$profile}
     | if ($legacy | length) > 0 then .legacy_hooks = $legacy else . end')"
}
_setup_migrated() {
  local path
  for path in ${LAB_SETUP_MIGRATIONS[@]+"${LAB_SETUP_MIGRATIONS[@]}"}; do
    case "$1/" in "$path/"*) printf '%s\n' "$path"; return 0 ;; esac
  done
  return 1
}
_setup_generated() { case "$1" in "$LAB_STATE/"*) _txn_target_allowed "$1" modify ;; *) return 1 ;; esac; }
_setup_destination() {
  local path="$1" action="$2" migration p suffix='' base
  _txn_field "$path" || return 1
  if migration="$(_setup_migrated "$path")"; then
    _preflight_writable "$(dirname "$migration")" || return
    LAB_SETUP_TARGET="$path"
  elif [ "$action" = modify ] && [ -f "$path" ] && [ ! -L "$path" ] && _setup_generated "$path"; then
    # Agent Codex généré sous le journal (lib/install.sh) : seule donnée dérivée qu'une mise à jour modifie (0.8.1).
    LAB_SETUP_TARGET="$path"
    _preflight_writable "$LAB_SETUP_TARGET" || return
  elif [ "$action" = modify ]; then
    _merge_target_original "$path" || return
    LAB_SETUP_TARGET="$LAB_MERGE_TARGET"
    _preflight_writable "$LAB_SETUP_TARGET" || return
  else
    p="$(dirname "$path")"; base="${path##*/}"
    while ! _txn_exists "$p"; do suffix="/${p##*/}$suffix"; p="${p%/*}"; p="${p:-/}"; done
    if ! { [ -d "$p" ] && p="$(cd "$p" && pwd -P)"; }; then
      _preflight_error "$path" 'Fix the parent folder.'; return 1
    fi
    LAB_SETUP_TARGET="${p%/}$suffix/$base"
    _preflight_writable "$p" || return
  fi
  _preflight_source_safe "$LAB_SETUP_TARGET"
}
_setup_add() {
  local action="$1" path="$2" payload="${3:-}" note="${4:-}" before digest='' label
  _setup_destination "$path" "$action" || return
  path="$LAB_SETUP_TARGET"
  _txn_field "$payload" && _txn_field "$note" || return 1
  before="$(_txn_fingerprint "$path")" || return
  case "$action" in create|modify|replace)
    digest="$(shasum -a 256 <"$payload" | cut -d ' ' -f 1)" || return ;;
    symlink|relink) digest="$payload" ;;
  esac
  _txn_row "$action" "$path" "$payload" "$note" "$before" "$digest" '' '' >>"$LAB_SETUP_TEMP/plan"
  _txn_row "$action" "$path" "$note" "$before" "$digest" '' '' '' >>"$LAB_SETUP_TEMP/consent"
  case "$note" in treelab-setup-v1:*) note='Selection and paths kept in the installation log' ;; esac
  # Un objet déjà en place est compté, son détail va au fichier nommé par _setup_kept_summary ; une collision ou un
  # retrait client reste listé.
  case "$action:$note" in skip:'Already satisfied'|skip:'Already present, link kept'|skip:'Selection and paths kept'*)
    printf '%s — %s\n' "$path" "$note" >>"$LAB_SETUP_TEMP/kept"; return 0 ;;
  esac
  case "$action" in
    create) label='Create the file' ;; modify) label='Update' ;; replace) label='Replace the legacy link' ;;
    mkdir) label='Create the folder' ;; symlink) label='Add the link' ;; unlink) label='Remove the outdated Treelab link' ;; relink) label='Replace with a link, object backed up' ;; skip) label='Left in place' ;; migrate-dir) label='Migrate the linked folder' ;;
    *) label="$action" ;;
  esac
  _setup_message "$label: $path${note:+ — $note}"
}
# _setup_imported_link <chemin> : lien dont la cible résolue est dans la copie importée (setup --import), donc historique.
_setup_imported_link() {
  local target
  [ -n "${LAB_SETUP_IMPORT:-}" ] && [ -L "$1" ] || return 1
  # resolve_file refuse une cible dossier : un dossier existant se résout en suivant ses liens.
  if [ -d "$1" ]; then target="$(real_path "$1")"; else target="$(_txn_resolve_modify "$1" 2>/dev/null)" || return 1; fi
  _preflight_in_import "$target"
}
_setup_relinked() {
  local path
  for path in ${LAB_SETUP_RELINKS[@]+"${LAB_SETUP_RELINKS[@]}"}; do [ "$path" != "$1" ] || return 0; done
  return 1
}
_setup_migration() {
  local path="$1" source="$2" kind="$3"
  [ -L "$path" ] || return 0
  if [ "$path" -ef "$source" ] || _setup_imported_link "$path"; then
    LAB_SETUP_MIGRATIONS+=("$path")
    if [ "$kind" = directory ]; then
      _setup_add migrate-dir "$path" '' 'Legacy link backed up, replaced with a separate folder'
    else
      _setup_add replace "$path" "$LAB_SETUP_TEMP/empty-file" 'Legacy link backed up, replaced with a block'
    fi
  elif [ "$kind" = file ]; then
    # Une instruction cliente liée peut être fusionnée par sa cible privée.
    return 0
  else
    _preflight_error "$path" 'Foreign link kept; prepare a real folder or restore a traceable origin before trying again.'; return 1
  fi
}
_setup_plan_overrides() {
  # Renommage de fonctions du programme seulement, jamais de texte du compte.
  eval "$(declare -f _merge_target | sed '1s/_merge_target/_merge_target_original/')"
  # shellcheck disable=SC2329
  _merge_target() {
    if _setup_migrated "$1" >/dev/null; then LAB_MERGE_TARGET="$LAB_SETUP_TEMP/absent"
    else _merge_target_original "$1" && _preflight_source_safe "$LAB_MERGE_TARGET"; fi
  }
  # shellcheck disable=SC2329
  _merge_publish() {
    local path="$1" prepared="$2" action=create
    if [ -L "$path" ] && _setup_migrated "$path" >/dev/null; then action=modify; fi
    if [ -f "$path" ] && ! _setup_migrated "$path" >/dev/null; then
      if cmp -s "$path" "$prepared"; then _setup_add skip "$path" '' 'Already satisfied'; return; fi
      action=modify
    fi
    _setup_add "$action" "$path" "$prepared"
  }
  # shellcheck disable=SC2329
  install_link() {
    local source="$1" path="$2"
    if [ -n "${LAB_SETUP_SOURCE:-}" ]; then
      case "$source" in "$LAB_SETUP_SOURCE/"*) source="$LAB_SETUP_ROOT/${source#"$LAB_SETUP_SOURCE/"}" ;; esac
    fi
    _merge_discovery_dir "$(dirname "$path")" || return
    if _setup_relinked "$path"; then _setup_add relink "$path" "$source"; return; fi
    if [ "${LAB_SETUP_REAPPLY:-no}" = yes ] && _update_client_removed "$path"; then
      _setup_add skip "$path" '' 'User removal kept'; return
    fi
    if _txn_exists "$path" && ! _setup_migrated "$path" >/dev/null; then
      if [ -L "$path" ] && [ "$path" -ef "$source" ]; then
        _setup_add skip "$path" '' 'Already present, link kept'
      else _setup_add skip "$path" '' 'Collision: name already taken, user object kept'; fi
    else _setup_add symlink "$path" "$source"; fi
  }
  # shellcheck disable=SC2329
  _merge_agent_replaceable() {
    # Un agent Codex ordinaire au nom d'un agent treelab vient de l'installation importée : remplacé, sauvegardé.
    [ -n "${LAB_SETUP_IMPORT:-}" ] && [ -f "$1" ] && [ ! -L "$1" ] || return 1
    LAB_SETUP_RELINKS+=("$1")
  }
  # shellcheck disable=SC2329
  _merge_discovery_dir() {
    local p="$1"
    while [ "$p" != / ]; do
      if _setup_migrated "$p" >/dev/null; then return 0; fi
      if [ -L "$p" ] || { [ -e "$p" ] && [ ! -d "$p" ]; }; then
        _preflight_error "$p" 'Foreign discovery folder kept; prepare a real folder.'; return 2
      fi
      p="${p%/*}"; p="${p:-/}"
    done
  }
  # shellcheck disable=SC2329
  record_op() {
    local action="$1" target="$2"; shift 2
    case "$action" in
      mkdir) _setup_add mkdir "$target" ;;
      skip) _setup_add skip "$target" '' "$1" ;;
      symlink) _setup_add symlink "$target" "$1" ;;
      create|modify|replace)
        local saved
        saved="$(mktemp "$LAB_SETUP_TEMP/prepared.XXXXXXXX")" || return
        cp -p "$1" "$saved" || return
        _setup_add "$action" "$target" "$saved" ;;
      *) _preflight_error "$target" "Unknown preparation operation: $action."; return 1 ;;
    esac
  }
}
_setup_commands() {
  local name path found
  for name in treelab lab; do
    path="$HOME/.local/bin/$name"; found="$(command -v "$name" || true)"
    if [ "$name" = lab ] && _setup_imported_link "$path"; then
      LAB_SETUP_RELINKS+=("$path"); install_link "$LAB_SETUP_ROOT/bin/lab" "$path" || return; continue
    fi
    if { _txn_exists "$path" && ! { [ -L "$path" ] && [ "$path" -ef "$LAB_SETUP_ROOT/bin/lab" ]; }; } ||
       { [ -n "$found" ] && [ "$found" != "$path" ] && ! [ "$found" -ef "$LAB_SETUP_ROOT/bin/lab" ]; }; then
      if [ "$name" = treelab ]; then _preflight_error "${found:-$path}" 'The treelab command is taken; free this name before trying again.'; return 1
      else _setup_add skip "$path" '' "Foreign lab command kept: ${found:-$path}; use treelab"; fi
    else install_link "$LAB_SETUP_ROOT/bin/lab" "$path" || return; fi
  done
}
# _setup_kept_summary : une ligne « Conserver : N … (détail : <fichier>) ». Le détail reste hors du compte, à côté du verrou
# d'opération (operation_paths), réécrit à chaque plan : un refus ne modifie rien sous HOME (inventaires des tests update).
_setup_kept_summary() {
  local kept="$LAB_SETUP_TEMP/kept" n detail='' staged
  [ -s "$kept" ] || return 0
  n="$(wc -l <"$kept" | tr -d ' ')"
  # Mêmes garanties que operation_acquire : dossier réel, à l'utilisateur, mode 700 ; sinon la ligne reste sans détail.
  if operation_paths 2>/dev/null && [ -d "$LAB_OPERATION_DIRECTORY" ] && [ ! -L "$LAB_OPERATION_DIRECTORY" ] &&
    [ "$(stat -f %u "$LAB_OPERATION_DIRECTORY")" = "$(id -u)" ] && [ "$(stat -f %Lp "$LAB_OPERATION_DIRECTORY")" = 700 ] &&
    staged="$(mktemp "$LAB_OPERATION_DIRECTORY/.conserves.XXXXXXXX" 2>/dev/null)"; then
    if { cp "$kept" "$staged" && mv -f "$staged" "$LAB_OPERATION_FILE.conserves.txt"; } 2>/dev/null; then
      detail="$LAB_OPERATION_FILE.conserves.txt"
    else rm -f "$staged"; fi
  fi
  if [ "$n" = 1 ]; then n='1 item'; else n="$n items"; fi
  _setup_message "Keep: $n already in place${detail:+ (details: $detail)}"
}
# _setup_reapproval_publish <dossier du plan> : la marque de réapprobation Codex notée par le plan (hooks_merge) rejoint l'état,
# seulement après une pose appliquée — jamais pour une simulation ni un refus (revue du lot 05 du couloir anglais)
_setup_reapproval_publish() {
  [ -f "$1/codex-hooks-reapproval" ] || return 0
  { mkdir -p "$LAB_STATE" && cp "$1/codex-hooks-reapproval" "$LAB_STATE/codex-hooks-reapproval"; } 2>/dev/null || true
}
setup_plan() (
  local temp="$1" item payload failures=0
  LAB_SETUP_TEMP="$temp"; LAB_SETUP_MIGRATIONS=(); LAB_SETUP_RELINKS=()
  # shellcheck disable=SC2034 # lue par hooks_merge (lib/install_merge.sh)
  LAB_REAPPROVAL_MARK="$temp/codex-hooks-reapproval"
  : >"$temp/plan"; : >"$temp/consent"; : >"$temp/empty-file"
  export LAB_TXN_ACTIVE="$temp" LAB_TXN_SEQ=0
  _setup_plan_overrides
  _setup_configuration || return
  LAB_SETUP_SOURCE="${LAB_SETUP_SOURCE:-$LAB_SETUP_ROOT}"
  printf '%s\n' "$LAB_SETUP_INFO" >"$temp/info"
  _setup_message "Planned integrations: Claude=$LAB_SETUP_CLAUDE; Codex=$LAB_SETUP_CODEX"
  if [ "$LAB_SETUP_BREW" = yes ]; then _setup_message 'After a separate agreement: brew install --cask cmux'; fi
  _setup_message "Backups kept: $LAB_STATE/backups"
  if [ "$LAB_SETUP_CODEX" = yes ]; then
    _setup_migration "$(agents_home)/skills" "$LAB_SETUP_ROOT/skills" directory || failures=1
    _setup_migration "$(codex_home)/AGENTS.md" "$LAB_SETUP_ROOT/templates/global-instructions.md" file || failures=1
  fi
  if [ "$LAB_SETUP_CLAUDE" = yes ]; then
    _setup_migration "$(claude_home)/skills" "$LAB_SETUP_ROOT/skills" directory || failures=1
    _setup_migration "$(claude_home)/agents" "$LAB_SETUP_ROOT/agents" directory || failures=1
    _setup_migration "$(claude_home)/CLAUDE.md" "$LAB_SETUP_ROOT/templates/global-instructions.md" file || failures=1
  fi
  [ "$failures" = 0 ] || return 1
  [ -z "${LAB_SETUP_IMPORT:-}" ] || _setup_legacy_hooks
  if [ "$LAB_SETUP_CLAUDE" = yes ]; then
    hooks_merge "${LAB_CLAUDE_SETTINGS:-$(claude_home)/settings.json}" claude "$LAB_SETUP_ROOT" || failures=1
    payload="$(mktemp "$temp/instructions.XXXXXXXX")"
    printf '@%s/templates/global-instructions.md\n' "$LAB_SETUP_ROOT" >"$payload"
    block_upsert "$(claude_home)/CLAUDE.md" "$payload" || failures=1
    install_claude_agents "$LAB_SETUP_SOURCE" || failures=1
  fi
  if [ "$LAB_SETUP_CODEX" = yes ]; then
    hooks_merge "$(codex_hooks_file)" codex "$LAB_SETUP_ROOT" || failures=1
    block_upsert "$(codex_home)/AGENTS.md" "$LAB_SETUP_SOURCE/templates/global-instructions.md" || failures=1
    install_codex_agents "$LAB_SETUP_SOURCE" || failures=1
  fi
  for item in "$LAB_SETUP_SOURCE"/skills/*; do
    [ -d "$item" ] || continue
    # Claude possède artifact-design en natif ; cette adaptation est pour Codex.
    if [ "$LAB_SETUP_CLAUDE" = yes ] && [ "${item##*/}" != visual-artifacts ]; then install_link "$item" "$(claude_home)/skills/${item##*/}" || failures=1; fi
    if [ "$LAB_SETUP_CODEX" = yes ]; then install_link "$item" "$(agents_home)/skills/${item##*/}" || failures=1; fi
  done
  [ -z "${LAB_SETUP_IMPORT:-}" ] || _setup_foreign_skills || failures=1
  _setup_legacy || failures=1
  _setup_commands || failures=1
  if [ -n "$LAB_SETUP_PROFILE" ]; then
    payload="$(mktemp "$temp/path.XXXXXXXX")"
    # shellcheck disable=SC2016 # Programme shell produit comme texte, sans évaluation.
    printf 'case ":$PATH:" in\n  *:%s:*) ;;\n  *) export PATH=%s:"$PATH" ;;\nesac\n' "$(shell_quote "$HOME/.local/bin")" "$(shell_quote "$HOME/.local/bin")" >"$payload"
    shell_block_upsert "$LAB_SETUP_PROFILE" "$payload" || failures=1
  fi
  _setup_add skip "$HOME/.local/bin/treelab" '' "treelab-setup-v1:$LAB_SETUP_INFO" || failures=1
  _setup_kept_summary
  _setup_message 'Foreign settings are kept. Hooks are approved afterwards inside the agents.'
  [ "$failures" = 0 ]
)
# Anciens noms (LAB_LEGACY_*, lib/install_merge.sh) : un lien treelab intact se retire ; un lien modifié reste, annoncé ; un objet
# réel ou un lien que le manifeste n'attribue pas à treelab est au client, hors de cette table.
_setup_legacy() {
  local path
  while IFS= read -r path; do
    { [ -L "$path" ] && install_legacy_known "$path"; } || continue
    _txn_target "$path" || return
    if _merge_installed_unchanged "$LAB_TXN_TARGET" link; then _setup_add unlink "$path"
    else _setup_add skip "$path" '' 'Outdated Treelab link kept: link changed'; fi
  done < <(install_legacy_paths)
}
# Hooks de la copie importée retirés dans la même fusion que la pose des hooks treelab ; hooks tiers conservés.
_setup_legacy_hooks() {
  local file n
  for file in "$(_setup_hooks_file claude)" "$(_setup_hooks_file codex)"; do
    [ -f "$file" ] || continue
    n="$(jq --argjson legacy "$(_merge_legacy_prefixes "$file")" "$LAB_MERGE_LEGACY_JQ"'
      [.hooks // {} | .[]? | .[]? | .hooks? // [] | .[]? | select(legacy_hook)] | length' "$file" 2>/dev/null)" || continue
    [ "$n" = 0 ] || _setup_message "Hooks of the earlier installation removed in the same merge: $n in $file"
  done
}
_setup_hooks_file() { # claude|codex → fichier de hooks fusionné par la pose, vide si l'agent n'est pas posé
  case "$1:$LAB_SETUP_CLAUDE:$LAB_SETUP_CODEX" in
    claude:yes:*) printf '%s\n' "${LAB_CLAUDE_SETTINGS:-$(claude_home)/settings.json}" ;;
    codex:*:yes) codex_hooks_file ;;
  esac
}
# Entrées du dossier de skills de la copie absentes de treelab : un lien vers leur cible réelle les garde découvrables.
_setup_foreign_skills() {
  local item name target
  for item in "$LAB_SETUP_IMPORT"/skills/*; do
    [ -d "$item" ] || continue
    name="${item##*/}"; [ ! -e "$LAB_SETUP_SOURCE/skills/$name" ] || continue
    target="$(real_path "$item")"
    if [ "$LAB_SETUP_CLAUDE" = yes ] && _setup_migrated "$(claude_home)/skills" >/dev/null; then
      install_link "$target" "$(claude_home)/skills/$name" || return
    fi
    if [ "$LAB_SETUP_CODEX" = yes ] && _setup_migrated "$(agents_home)/skills" >/dev/null; then
      install_link "$target" "$(agents_home)/skills/$name" || return
    fi
  done
}

_setup_confirm() {
  local message="$1" answer=''
  if ! { exec 9<> /dev/tty; } 2>/dev/null; then
    _setup_message 'Terminal required: run this command again in a visible terminal to read the summary and confirm.'
    return 2
  fi
  if declare -F onboard_wrap >/dev/null; then printf '%s\n' "$message" | onboard_wrap "$(onboard_cols)" >&2; else printf '%s\n' "$message" >&2; fi
  printf 'Type I accept to continue: ' >&2
  if IFS= read -r answer <&9; then :; else exec 9>&-; _setup_message 'No agreement received; nothing changed.'; return 1; fi
  exec 9>&-
  # réponse anglaise ; les réponses françaises restent acceptées (scripts et habitudes des poses antérieures)
  case "$answer" in 'I accept'|'i accept'|"j’accepte"|"j'accepte") return 0 ;;
    *) _setup_message 'Not accepted; nothing changed.'; return 1 ;;
  esac
}
_setup_resume_capture() {
  # Une reprise ultérieure ne peut écraser un changement intervenu après la panne.
  local d line current
  [ -n "${LAB_TXN_ACTIVE:-}" ] || return 0
  for d in "$LAB_TXN_ACTIVE"/[0-9]*; do
    [ -f "$d/row" ] && [ ! -f "$d/done" ] || continue
    line="$(cat "$d/row")" && _txn_validate_row "$line" no || return 1
    case "${LAB_TXN_FIELDS[2]}" in skip|mkdir) continue ;; esac
    current="$(_txn_fingerprint "${LAB_TXN_FIELDS[3]}")" || return
    _txn_write "$d/resume-current" "$current" || return
  done
}
_setup_resume_guard() {
  local pending="$1" command="${2:-uninstall --resume}" d line current expected target
  for d in "$pending"/[0-9]*; do
    [ -f "$d/row" ] && [ ! -f "$d/done" ] || continue
    line="$(cat "$d/row")" && _txn_validate_row "$line" no || return 1
    case "${LAB_TXN_FIELDS[2]}" in skip|mkdir) continue ;; esac
    target="${LAB_TXN_FIELDS[3]}"
    current="$(_txn_fingerprint "$target")" || return
    [ "$current" != "${LAB_TXN_FIELDS[4]}" ] || continue
    expected="${LAB_TXN_FIELDS[5]}"
    if _txn_exists "$d/resume-current"; then
      if ! { _txn_plain_path "$d/resume-current" && [ -f "$d/resume-current" ] &&
        [ "$(stat -f %Lp "$d/resume-current")" = 600 ]; }; then
        _setup_message "Invalid resume fingerprint: $d/resume-current. Backups kept."; return 1
      fi
      expected="$(cat "$d/resume-current")" || return
    elif [ -f "$d/after" ]; then expected="$(cat "$d/after")" || return
    fi
    if ! { [[ "$expected" = absent || "$expected" =~ ^[0-9a-f]{64}$ ]] && [ "$current" = "$expected" ]; }; then
      _setup_message "Resume paused: recent change or unrecognised partial state: $target."
      _setup_message "Set the recent data aside, then restore the original object saved in $d/before (or its initial absence) before $command."
      return 1
    fi
  done
}
_setup_apply() {
  local plan="$1" composed="${2:-no}" line action path payload note plan_dir
  plan_dir="$(dirname "$plan")" || return
  set -E
  [ "$composed" = yes ] || txn_begin || return
  while IFS= read -r line; do
    _txn_parse "$line" || return 1
    action="${LAB_TXN_FIELDS[0]}"; path="${LAB_TXN_FIELDS[1]}"
    payload="${LAB_TXN_FIELDS[2]}"; note="${LAB_TXN_FIELDS[3]}"
    case "$action" in
      migrate-dir)
        local empty
        empty="$(mktemp -d "$plan_dir/directory.XXXXXXXX")" || return
        record_op replace "$path" "$empty" || return
        rmdir "$empty" || return ;;
      mkdir) record_op mkdir "$path" || return ;;
      unlink) install_legacy_remove "$path" || return ;;
      relink)
        # Le moteur remplace l'objet sauvegardé par une copie du lien préparé (cp -P).
        local relink
        relink="$(mktemp -d "$plan_dir/relink.XXXXXXXX")" && ln -s "$payload" "$relink/link" || return
        record_op replace "$path" "$relink/link" || return ;;
      skip)
        # Le moteur exige un parent réel ; les collisions sur un chemin absent
        # sont consignées à côté d'un parent créé par la pose.
        [ -d "$(dirname "$path")" ] || record_op mkdir "$(dirname "$path")" || return
        record_op skip "$path" "$note" || return ;;
      symlink|create|modify|replace)
        [ -d "$(dirname "$path")" ] || record_op mkdir "$(dirname "$path")" || return
        record_op "$action" "$path" "$payload" || return ;;
      *) return 2 ;;
    esac
  done <"$plan"
  [ "$composed" = yes ] || txn_commit
}
cmd_setup() (
  local dry=no temp check dependency=no rc import='' blocked=no
  LAB_SETUP_DEV=no
  if [ "${1:-}" = --reapply ]; then
    [ "$#" -eq 1 ] || { _setup_message 'Use treelab setup --reapply [--json], on its own.'; return 2; }
    cmd_reapply; return
  fi
  while [ "$#" -gt 0 ]; do
    case "$1" in --dry-run) dry=yes ;; --dev) LAB_SETUP_DEV=yes ;;
      --import)
        [ "$#" -ge 2 ] && [ -n "$2" ] || { _setup_message "Use setup --import <copy>: the folder of the earlier lab installation."; return 2; }
        import="$2"; shift ;;
      *) _setup_message "Unknown setup option: $1. Use setup [--dev] [--dry-run] [--import <copy>]."; return 2 ;;
    esac
    shift
  done
  LAB_PREFLIGHT_ERRORS=0; _preflight_system
  [ "$LAB_PREFLIGHT_ERRORS" = 0 ] || return 1
  operation_acquire || { _setup_message 'Another operation is running. Wait for it to finish, then run treelab setup again.'; return 1; }
  trap 'operation_release' EXIT
  _setup_operation_guard || return 1
  merge_register_commands
  if [ -n "$import" ]; then import_recognize "$import" || return 1; fi
  if ! preflight; then
    # Une simulation va au bout du plan quand seules des sessions bloquent ; la pose réelle s'arrête avant toute écriture.
    if [ "$dry" = yes ] && [ "$LAB_PREFLIGHT_ERRORS" = "${LAB_PREFLIGHT_SESSION_ERRORS:-0}" ]; then blocked=yes; else return 1; fi
  fi
  temp="$(mktemp -d /private/tmp/treelab-setup.XXXXXXXX)" || return
  trap 'rm -R "$temp"; operation_release' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [ -n "$import" ]; then import_plan || return 1; fi
  setup_plan "$temp" || return
  if [ -n "$import" ]; then import_inventory || return 1; fi
  if [ "$dry" = yes ]; then
    kv RESULT simulated
    if [ "$blocked" = yes ]; then
      printf '%s' "$LAB_PREFLIGHT_SESSION_LIST" | while IFS= read -r line; do _setup_message "Blocks the installation: $line"; done
      _setup_message 'Dry run finished; no file installed. The real installation will refuse while these sessions are alive: end them before running it.'
      return 1
    fi
    _setup_message 'Dry run finished; no file installed.'; return 0
  fi
  if [ -n "$import" ]; then
    _setup_confirm "Import the data, then install Treelab and the changes listed above? The old copy will not be changed." || return
  else
    _setup_confirm 'Install Treelab and the changes listed above?' || return
  fi
  # Refaire le même plan avec des temporaires distincts ; le consentement compare
  # les données et empreintes, jamais les noms aléatoires des temporaires.
  check="$temp/check"; mkdir "$check"
  preflight && setup_plan "$check" || return
  if ! cmp -s "$temp/consent" "$check/consent"; then
    _setup_message 'The plan has changed since the summary; nothing installed. Run setup again to confirm the new effects.'; return 1
  fi
  if [ "$LAB_SETUP_BREW" = yes ]; then
    _setup_confirm 'Install cmux separately with brew install --cask cmux? This dependency stays installed after a removal or a failure.' || return
    _setup_message 'Installing cmux: brew install --cask cmux'
    brew install --cask cmux >&2 || { _setup_message 'Homebrew failed; no Treelab setting merged. Fix this installation, then run setup again.'; return 1; }
    dependency=yes
    _preflight_tool cmux || { _setup_message 'cmux is still not found; fix PATH, then run setup again. Homebrew may have installed the dependency.'; return 1; }
    local after_brew="$temp/after-brew"
    mkdir "$after_brew" || return
    if ! { preflight && setup_plan "$after_brew" && cmp -s "$check/consent" "$after_brew/consent"; }; then
      _setup_message 'The Mac or the plan changed during Homebrew; cmux stays in place. Run setup again to confirm the new effects.'; return 1
    fi
    check="$after_brew"
  fi
  if [ -n "$import" ]; then import_data || return 1; fi
  if _setup_apply "$check/plan"; then
    _setup_reapproval_publish "$check"
    kv RESULT installed
    _setup_message "Files installed. Run $HOME/.local/bin/treelab doctor; approve the hooks in the agents concerned if the report asks for it."
    _setup_message "Then, in your project folder: $HOME/.local/bin/treelab onboard"
  else
    rc=$?
    [ -z "${LAB_TXN_ACTIVE:-}" ] || txn_rollback || true
    _setup_resume_capture || _setup_message 'Resume fingerprint not saved; resuming will need a recognised state or restoring the backup.'
    if [ "$dependency" = yes ]; then _setup_message 'cmux was installed separately and stays in place.'; fi
    if [ -n "$import" ]; then _setup_message "Imported data kept in $LAB_HOME; a new installation does not copy it again."; fi
    _setup_message "Installation failed. Backups: $LAB_STATE/backups. To resume: $(shell_quote "$LAB_ROOT/bin/lab") uninstall --resume"
    return "$rc"
  fi
)
