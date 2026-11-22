# shellcheck shell=bash
# install.sh — transactions locales, bash 3.2. Charger project.sh et git.sh avant usage.
# Aucun effet au chargement. API (stdout vide, diagnostics stderr) :
# Avec set -E (héritage de ERR) : txn_begin ; record_op <action> <cible> [arguments…] ; txn_commit | txn_rollback
# uninstall_replay : processus neuf, même LAB_STATE et même liste de callbacks.
# mkdir cible (parents inclus), symlink cible texte, create/replace/modify cible source,
# skip cible motif, cmd cible fonction inverse [arguments…]. Les callbacks reçoivent
# cible puis arguments distincts. LAB_TXN_COMMANDS=("fonction:inverse" …), définie par
# l'appelant, autorise uniquement des fonctions locales ; tous leurs effets doivent
# être contenus dans la cible déclarée. L'inverse sait traiter un effet partiel.
#
# TSV v1 : en-tête « treelab-install<TAB>1 », puis une ligne par opération :
# @transaction @séquence @action @cible @empreinte-avant @empreinte-après @fonction
# @inverse @argument… (tabulations entre colonnes). @ préserve les valeurs vides.
# Une empreinte est SHA-256, « absent », « none » (skip), ou « pending » avant effet.
# Sauvegarde : backups/<transaction>/<séquence>/before ; row = ligne préparée,
# after = empreinte obtenue ; done = inverse réussi. Les objets sauvegardés gardent
# leurs modes ; les métadonnées sont 0600 dans des dossiers 0700.
# sealed-count fixe le nombre de lignes validées ; manifest-state et manifest.before
# gardent le manifeste antérieur jusqu’à la fin du retour de txn_commit.
# Le manifeste est publié par renommage atomique. Un dossier non référencé dans
# celui-ci est une transaction incomplète, jamais réutilisée par txn_begin.
# txn_rollback peut la reprendre depuis un shell neuf. Les sauvegardes validées et
# marqueurs done restent sur disque : leur rétention relève de la future CLI.
# Pas de concurrence, SIGKILL, ACL/xattrs ni restauration des dates des dossiers.
# Les traps temporaires traitent ERR/EXIT/INT/TERM ; les retours des mutations sont
# également vérifiés si l'appelant neutralise errexit par une condition.

# lab_say <texte> : « lab: texte » sur stderr, replié au mot à la largeur du terminal (onboard_wrap, 40 à 80 colonnes) quand
# lib/onboard.sh est chargé et que stderr est un terminal ou COLUMNS est posé — setup, update et uninstall lisibles à 40 colonnes
# (lot 05 du couloir anglais) ; sinon intacte, car update_auto relit la première ligne de l'erreur.
lab_say() {
  if { [ -t 2 ] || [ -n "${COLUMNS:-}" ]; } && declare -F onboard_wrap >/dev/null; then printf 'lab: %s\n' "$*" | onboard_wrap "$(onboard_cols)" >&2
  else printf 'lab: %s\n' "$*" >&2; fi
}
_txn_message() { lab_say "$*"; }
_txn_field() { case "$1" in *$'\t'*|*$'\r'*|*$'\n'*) return 1 ;; esac; }
_txn_readlink() { # -n et sentinelle : aucun LF ajouté, aucun octet terminal perdu.
  local value
  value="$(command readlink -n "$1"; local rc=$?; printf '.'; exit "$rc")" || return
  LAB_TXN_LINK="${value%.}"
  _txn_field "$LAB_TXN_LINK"
}
_txn_exists() { [ -e "$1" ] || [ -L "$1" ]; }
_txn_plain_path() { # Refus de lien dans TOUS les composants techniques.
  local p="$1"
  case "$p" in /*) ;; *) return 1 ;; esac
  while [ "$p" != / ]; do
    [ ! -L "$p" ] || return 1
    p="${p%/*}"; p="${p:-/}"
  done
}
_txn_paths() {
  if ! { [ -n "${LAB_STATE:-}" ] && _txn_field "$LAB_STATE" && _txn_plain_path "$LAB_STATE"; }; then
    _txn_message "Invalid or linked state: ${LAB_STATE:-none}. Choose a real folder for the backups."; return 1;
  fi
  case "$LAB_STATE/" in *'/../'*|*'/./'*|*'//'*)
    _txn_message "State path not normalised: $LAB_STATE. Use an absolute path without dots or double separators."; return 1 ;;
  esac
  LAB_TXN_MANIFEST="$LAB_STATE/install-manifest.tsv"
  LAB_TXN_BACKUPS="$LAB_STATE/backups"
  if ! { _txn_plain_path "$LAB_TXN_MANIFEST" && _txn_plain_path "$LAB_TXN_BACKUPS"; }; then
    _txn_message "Log or backups are linked: $LAB_STATE. Restore their real location before resuming."; return 1;
  fi
}
_txn_private_file() { (umask 077; : >"$1") && chmod 600 "$1"; }
_txn_write() { # Publication technique atomique ; données seulement.
  local dest="$1"; shift
  _txn_plain_path "$dest" && _txn_plain_path "$dest.tmp" || return 1
  _txn_private_file "$dest.tmp" && printf '%s\n' "$*" >"$dest.tmp" && mv -f "$dest.tmp" "$dest"
}
_txn_row() {
  local field sep=''
  for field in "$@"; do printf '%s@%s' "$sep" "$field" || return; sep=$'\t'; done
  printf '\n'
}
_txn_parse() { # Tableau local à l'appelant, valeurs @ non vides avant découpage.
  local line="$1" field
  LAB_TXN_FIELDS=()
  while :; do
    field="${line%%$'\t'*}"
    case "$field" in @*) LAB_TXN_FIELDS+=("${field#@}") ;; *) return 1 ;; esac
    case "$line" in *$'\t'*) line="${line#*$'\t'}" ;; *) break ;; esac
  done
  [ "${#LAB_TXN_FIELDS[@]}" -ge 8 ]
}
_txn_tree_data() { # Parcours sans lien suivi ; toute erreur de lecture remonte.
  local p="$1" root="${2:-$1}" mode link child
  _txn_field "$p" || return 1
  mode="$(stat -f '%Lp' "$p")" || return
  printf '%s\t%s\t' "${p#"$root"}" "$mode" || return
  if [ -L "$p" ]; then
    _txn_readlink "$p" || return
    link="$LAB_TXN_LINK"
    printf 'L\t%s\n' "$link"
  elif [ -f "$p" ]; then
    local modified; modified="$(stat -f '%m' "$p")" || return
    printf 'F\t%s\t' "$modified" && shasum -a 256 <"$p"
  elif [ -d "$p" ]; then
    [ -r "$p" ] && [ -x "$p" ] || return 1
    printf 'D\n' || return
    for child in "$p"/.[!.]* "$p"/..?* "$p"/*; do
      _txn_exists "$child" || continue
      _txn_tree_data "$child" "$root" || return
    done
  else return 1
  fi
}
_txn_fingerprint() (
  set -o pipefail
  if ! _txn_exists "$1"; then printf 'absent\n'; return; fi
  local data
  data="$(_txn_tree_data "$1")" || return
  printf '%s\n' "$data" | LC_ALL=C sort | shasum -a 256 | cut -d ' ' -f 1
)
_txn_allowed() {
  local pair
  [[ "$1" =~ ^[a-zA-Z_][a-zA-Z_0-9]*$ ]] && [[ "$2" =~ ^[a-zA-Z_][a-zA-Z_0-9]*$ ]] || return 1
  declare -F "$1" >/dev/null && declare -F "$2" >/dev/null || return 1
  for pair in ${LAB_TXN_COMMANDS[@]+"${LAB_TXN_COMMANDS[@]}"}; do
    [ "$pair" != "$1:$2" ] || return 0
  done
  return 1
}
_txn_target_allowed() {
  local target="$1" action="${2:-}" name
  # Données dérivées du programme, à distance du manifeste et des sauvegardes.
  case "$target" in
    "$LAB_STATE/generated"|"$LAB_STATE/generated/codex-agents")
      case "$action" in mkdir|skip) return 0 ;; *) return 1 ;; esac ;;
    "$LAB_STATE/generated/codex-agents/"*)
      name="${target##*/}"
      [ "$target" = "$LAB_STATE/generated/codex-agents/$name" ] || return 1
      [[ "$name" =~ ^[a-zA-Z0-9_-]+\.toml$ ]] || return 1
      case "$action" in create|modify|cmd|skip) return 0 ;; *) return 1 ;; esac ;;
  esac
  case "$target/" in "$LAB_STATE/"*) return 1 ;; esac
  case "$LAB_STATE/" in "$target/"*) return 1 ;; esac
}
_txn_target() { # Canonise le parent, conserve le lien final sauf pour modify.
  local p="$1" parent base
  _txn_field "$p" && [ -n "$p" ] || return 1
  base="$(basename "$p")"; parent="$(dirname "$p")"
  case "$base" in /|.|..) return 1 ;; esac
  parent="$(cd "$parent" && pwd -P && printf '.')" || return
  parent="${parent%$'\n.'}"
  _txn_field "$parent" || return 1
  LAB_TXN_TARGET="${parent%/}/$base"
  _txn_target_allowed "$LAB_TXN_TARGET" "${2:-}"
}
_txn_validate_row() {
  local line="$1" committed="$2" d before after action target forward inverse
  _txn_field "${line//$'\t'/}" && _txn_parse "$line" || return 1
  [[ "${LAB_TXN_FIELDS[0]}" =~ ^txn\.[a-zA-Z0-9]+$ ]] || return 1
  [[ "${LAB_TXN_FIELDS[1]}" =~ ^[1-9][0-9]*$ ]] || return 1
  action="${LAB_TXN_FIELDS[2]}"; target="${LAB_TXN_FIELDS[3]}"
  before="${LAB_TXN_FIELDS[4]}"; after="${LAB_TXN_FIELDS[5]}"
  forward="${LAB_TXN_FIELDS[6]}"; inverse="${LAB_TXN_FIELDS[7]}"
  case "$action" in mkdir|symlink|replace|create|modify|cmd|skip) ;; *) return 1 ;; esac
  case "$target" in /*) ;; *) return 1 ;; esac
  case "$target/" in *'/../'*|*'/./'*|*'//'*) return 1 ;; esac
  _txn_target_allowed "$target" "$action" || return 1
  if [ "$action" = skip ]; then [ "$before:$after" = none:none ] || return 1
  else
    [[ "$before" = absent || "$before" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ "$after" = absent || "$after" = pending || "$after" =~ ^[0-9a-f]{64}$ ]] || return 1
    [ "$committed:$after" != yes:pending ] || return 1
  fi
  if [ "$action" = cmd ]; then _txn_allowed "$forward" "$inverse" || return 1
  else [ -z "$forward$inverse" ] || return 1; fi
  d="$LAB_TXN_BACKUPS/${LAB_TXN_FIELDS[0]}/${LAB_TXN_FIELDS[1]}"
  _txn_plain_path "$d" && [ -d "$d" ] || return 1
  local f
  for f in row after 'done'; do
    _txn_plain_path "$d/$f" || return 1
    if [ -e "$d/$f" ]; then
      [ -f "$d/$f" ] && [ "$(stat -f '%Lp' "$d/$f")" = 600 ] || return 1
    fi
  done
  if [ -f "$d/done" ]; then [ "$(cat "$d/done")" = 'done' ] || return 1; fi
  # Une migration annulée rétablit le lien du dossier parent après ses enfants.
  # Les opérations déjà acquittées n'accèdent plus à cette cible désormais liée.
  [ -f "$d/done" ] || _txn_plain_path "$(dirname "$target")" || return 1
  _txn_retirement_validate "$d" "$target" || return 1
  if [ "$before" != absent ] && [ "$before" != none ]; then
    # before peut lui-même être le lien sauvegardé ; son contenu doit correspondre.
    [ "$(_txn_fingerprint "$d/before")" = "$before" ] || return 1
  fi
}
_txn_sealed_count() {
  local file="$LAB_TXN_BACKUPS/$1/sealed-count"
  _txn_plain_path "$file" && [ -f "$file" ] && [ "$(cat "$file")" = "$2" ] || return 1
  file="$LAB_TXN_BACKUPS/$1/remove-started"
  if [ -e "$file" ] || [ -L "$file" ]; then
    _txn_plain_path "$file" && [ -f "$file" ] && [ "$(stat -f %Lp "$file")" = 600 ] &&
      [ "$(cat "$file")" = treelab-removal-v1 ] || return 1
  fi
}
_txn_validate_manifest() {
  [ ! -e "$LAB_TXN_MANIFEST" ] || {
    [ -f "$LAB_TXN_MANIFEST" ] && [ "$(stat -f '%Lp' "$LAB_TXN_MANIFEST")" = 600 ] || return 1
    local line n=0 prev='' seq=0 seen='|' id order
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n + 1))
      if [ "$n" -eq 1 ]; then [ "$line" = $'treelab-install\t1' ] || return 1; continue; fi
      _txn_validate_row "$line" yes || return 1
      id="${LAB_TXN_FIELDS[0]}"; order="${LAB_TXN_FIELDS[1]}"
      if [ "$id" != "$prev" ]; then
        [ -z "$prev" ] || _txn_sealed_count "$prev" "$seq" || return 1
        case "$seen" in *"|$id|"*) return 1 ;; esac
        seen="$seen$id|"; prev="$id"; seq=0
      fi
      seq=$((seq + 1)); [ "$order" = "$seq" ] || return 1
    done <"$LAB_TXN_MANIFEST"
    [ "$n" -ge 1 ] || return 1
    [ -z "$prev" ] || _txn_sealed_count "$prev" "$seq" || return 1
    # Une dernière ligne sans terminateur est tronquée.
    [ "$(tail -c 1 "$LAB_TXN_MANIFEST" | od -An -tu1 | tr -d ' ')" = 10 ] || return 1
  }
}
_txn_committed() { [ -f "$LAB_TXN_MANIFEST" ] && grep -Fq "@$1"$'\t' "$LAB_TXN_MANIFEST"; }
_txn_pending() {
  local d
  LAB_TXN_PENDING=''
  for d in "$LAB_TXN_BACKUPS"/txn.*; do
    _txn_exists "$d" || continue
    _txn_plain_path "$d" && [ -d "$d" ] || return 1
    if [ -e "$d/retired" ] || [ -L "$d/retired" ]; then
      _txn_plain_path "$d/retired" && [ -f "$d/retired" ] &&
        [ "$(stat -f %Lp "$d/retired")" = 600 ] && [ "$(cat "$d/retired")" = treelab-retired-v1 ] || return 1
      continue
    fi
    if [ -e "$d/rollback" ] || ! _txn_committed "${d##*/}"; then
      [ -z "$LAB_TXN_PENDING" ] || return 1
      LAB_TXN_PENDING="$d"
    fi
  done
}
_txn_restore_shell() {
  [ "${LAB_TXN_ARMED:-no}" = yes ] || return 0
  trap - ERR EXIT INT TERM
  # Seul le texte produit par trap -p de l'appelant est réinstallé. Jamais le TSV.
  eval "$LAB_TXN_SAVED_TRAPS"
  [ "$LAB_TXN_SAVED_E" = yes ] || set +E
  [ "$LAB_TXN_SAVED_PIPE" = yes ] || set +o pipefail
  LAB_TXN_ARMED=no
}
_txn_abort() {
  local rc="$1" cause="$2"
  [ "$rc" -ne 0 ] || rc=1
  export LAB_TXN_ERROR_CODE="$rc" LAB_TXN_ERROR_CAUSE="$cause"
  trap - ERR EXIT INT TERM
  _txn_message "Failed (code $rc): $cause"
  txn_rollback || true
  _txn_restore_shell
  exit "$rc"
}
_txn_fail() {
  local rc="$1" cause="$2"
  export LAB_TXN_ERROR_CODE="$rc" LAB_TXN_ERROR_CAUSE="$cause"
  _txn_message "Failed (code $rc): $cause"
  txn_rollback || true
  return "$rc"
}
_txn_mkdir_technical() {
  local p="$1"
  [ ! -d "$p" ] || return 0
  _txn_mkdir_technical "$(dirname "$p")" || return
  mkdir -m 700 "$p" || return
  LAB_TXN_CREATED=("$p" ${LAB_TXN_CREATED[@]+"${LAB_TXN_CREATED[@]}"})
}
txn_begin() {
  # Sans errtrace, bash masque le trap ERR extérieur dès l'entrée en fonction :
  # il serait impossible de le sauvegarder. Exiger l'héritage avant toute écriture.
  case "$-" in *E*) ;; *) _txn_message 'Enable set -E before txn_begin to keep the ERR trap of your shell.'; return 2 ;; esac
  [ -z "${LAB_TXN_ACTIVE:-}" ] || { _txn_message 'Transaction already open. Finish its restore before starting again.'; return 1; }
  if ! { _txn_paths && _txn_validate_manifest && _txn_pending; }; then
    _txn_message "Invalid log: ${LAB_TXN_MANIFEST:-none}. Keep the backups and restore the log before resuming."; return 1;
  fi
  [ -z "$LAB_TXN_PENDING" ] || {
    _txn_message "Restore pending: $LAB_TXN_PENDING. Resume txn_rollback before an installation."; return 1;
  }
  LAB_TXN_CREATED=()
  if _txn_mkdir_technical "$LAB_TXN_BACKUPS"; then :; else _txn_begin_cleanup; return 1; fi
  LAB_TXN_ACTIVE="$(mktemp -d "$LAB_TXN_BACKUPS/txn.XXXXXXXX")" || { _txn_begin_cleanup; return 1; }
  LAB_TXN_ID="${LAB_TXN_ACTIVE##*/}"; LAB_TXN_SEQ=0
  if _txn_private_file "$LAB_TXN_ACTIVE/parents" &&
     printf '%s\n' ${LAB_TXN_CREATED[@]+"${LAB_TXN_CREATED[@]}"} >"$LAB_TXN_ACTIVE/parents"; then :
  else _txn_begin_cleanup; return 1; fi
  if [ -f "$LAB_TXN_MANIFEST" ]; then
    _txn_write "$LAB_TXN_ACTIVE/manifest-state" present || { _txn_begin_cleanup; return 1; }
    _txn_copy "$LAB_TXN_MANIFEST" "$LAB_TXN_ACTIVE/manifest.before" || { _txn_begin_cleanup; return 1; }
  else
    _txn_write "$LAB_TXN_ACTIVE/manifest-state" absent || { _txn_begin_cleanup; return 1; }
  fi
  LAB_TXN_SAVED_TRAPS="$(trap -p ERR EXIT INT TERM)"
  LAB_TXN_SAVED_E=no; case "$-" in *E*) LAB_TXN_SAVED_E=yes ;; esac
  LAB_TXN_SAVED_PIPE=no; if shopt -qo pipefail; then LAB_TXN_SAVED_PIPE=yes; fi
  set -E -o pipefail
  LAB_TXN_ARMED=yes
  trap '_txn_abort "$?" "$BASH_COMMAND"' ERR
  trap '_txn_abort "$?" "exit without commit"' EXIT
  trap '_txn_abort 130 "INT interruption"' INT
  trap '_txn_abort 143 "TERM interruption"' TERM
}
_txn_begin_cleanup() {
  local p
  if [ -n "${LAB_TXN_ACTIVE:-}" ]; then rm -R "$LAB_TXN_ACTIVE" || return; fi
  LAB_TXN_ACTIVE=''
  for p in ${LAB_TXN_CREATED[@]+"${LAB_TXN_CREATED[@]}"}; do rmdir "$p" || return; done
}
_txn_copy() { cp -pPR "$1" "$2"; }
_txn_remove() { if _txn_exists "$1"; then rm -R "$1"; fi; }
_txn_apply() {
  local action="$1" target="$2"; shift 2
  case "$action" in
    mkdir) mkdir "$target" ;;
    symlink) ln -s "$1" "$target" ;;
    create) _txn_copy "$1" "$target" ;;
    replace) _txn_remove "$target" && _txn_copy "$1" "$target" ;;
    modify) cat "$1" >"$target" ;;
    cmd) local forward="$1"; shift 2; "$forward" "$target" "$@" ;;
    skip) : ;;
  esac
}
record_op() {
  [ -n "${LAB_TXN_ACTIVE:-}" ] || { _txn_message 'No open transaction. Call txn_begin before any write.'; return 1; }
  local rc
  if _txn_record "$@"; then return 0; else rc=$?; fi
  if [ "$rc" -eq 2 ]; then
    _txn_message 'Arguments refused. Check collisions, allowed functions and paths; tab, carriage return and line feed are forbidden.'
  fi
  _txn_fail "$rc" "operation ${1:-missing} on ${2:-missing target}; check the shown cause before trying again."
}
_txn_resolve_modify() (
  # Garder le résolveur commun ; refuser les cibles illisibles en TSV avant qu’une
  # substitution de commande interne puisse retirer leurs LF terminaux.
  # shellcheck disable=SC2329 # Appel indirect par resolve_file de lib/git.sh.
  readlink() { _txn_readlink "$1" && printf '%s\n' "$LAB_TXN_LINK"; }
  resolve_file "$1"
)
_txn_record() {
  [ "$#" -ge 2 ] || return 2
  local action="$1" target="$2" field before after d forward='' inverse='' parent
  shift 2
  for field in "$target" "$@"; do _txn_field "$field" || return 2; done
  case "$action" in
    mkdir)
      [ "$#" -eq 0 ] || return 2
      if [ -d "$target" ] && [ ! -L "$target" ]; then action=skip; set -- 'existing folder'
      elif ! _txn_exists "$target"; then
        parent="$(dirname "$target")"
        [ -d "$parent" ] || _txn_record mkdir "$parent" || return
      else return 2; fi ;;
    symlink)
      [ "$#" -eq 1 ] || return 2
      if [ -L "$target" ] && _txn_readlink "$target" && [ "$LAB_TXN_LINK" = "$1" ]; then action=skip; set -- 'same link'
      else ! _txn_exists "$target" || return 2; fi ;;
    create) [ "$#" -eq 1 ] && [ -f "$1" ] && [ ! -L "$1" ] && ! _txn_exists "$target" || return 2 ;;
    replace) [ "$#" -eq 1 ] && _txn_exists "$1" && _txn_exists "$target" || return 2 ;;
    modify)
      [ "$#" -eq 1 ] && [ -f "$1" ] || return 2
      target="$(_txn_resolve_modify "$target")" && [ -f "$target" ] || return 2 ;;
    cmd) [ "$#" -ge 2 ] && _txn_allowed "$1" "$2" || return 2; forward="$1"; inverse="$2" ;;
    skip) [ "$#" -eq 1 ] || return 2 ;;
    *) return 2 ;;
  esac
  _txn_target "$target" "$action" || return 2; target="$LAB_TXN_TARGET"
  before=none; after=none
  if [ "$action" != skip ]; then before="$(_txn_fingerprint "$target")" || return; after=pending; fi
  LAB_TXN_SEQ=$((LAB_TXN_SEQ + 1)); d="$LAB_TXN_ACTIVE/$LAB_TXN_SEQ"
  mkdir -m 700 "$d" || return
  if [ "$before" != absent ] && [ "$before" != none ]; then _txn_copy "$target" "$d/before" || return; fi
  _txn_private_file "$d/row.tmp" || return
  if [ "$action" = cmd ]; then
    _txn_row "$LAB_TXN_ID" "$LAB_TXN_SEQ" "$action" "$target" "$before" "$after" "$forward" "$inverse" "${@:3}" >"$d/row.tmp" || return
  elif [ "$action" = skip ]; then
    _txn_row "$LAB_TXN_ID" "$LAB_TXN_SEQ" "$action" "$target" "$before" "$after" '' '' "$1" >"$d/row.tmp" || return
  else _txn_row "$LAB_TXN_ID" "$LAB_TXN_SEQ" "$action" "$target" "$before" "$after" '' '' >"$d/row.tmp" || return; fi
  mv "$d/row.tmp" "$d/row" || return
  # Dès cet instant l'opération courante fait partie de l'annulation, même partielle.
  _txn_apply "$action" "$target" "$@" >&2 || return
  if [ "$action" != skip ]; then after="$(_txn_fingerprint "$target")" || return; fi
  _txn_write "$d/after" "$after"
}
_txn_undo_row() {
  local line="$1" prudent="$2" d action target before after current inverse
  _txn_validate_row "$line" "$prudent" || return 1
  d="$LAB_TXN_BACKUPS/${LAB_TXN_FIELDS[0]}/${LAB_TXN_FIELDS[1]}"
  if [ "$prudent" = yes ] && [ -d "$d/retirement" ]; then
    _txn_retirement_apply "$d" "${LAB_TXN_FIELDS[3]}"; return
  fi
  [ ! -f "$d/done" ] || return 0
  action="${LAB_TXN_FIELDS[2]}"; target="${LAB_TXN_FIELDS[3]}"
  before="${LAB_TXN_FIELDS[4]}"; after="${LAB_TXN_FIELDS[5]}"; inverse="${LAB_TXN_FIELDS[7]}"
  if [ "$action" != skip ]; then
    if ! current="$(_txn_fingerprint "$target")"; then
      _txn_message "Object kept, unreadable or holding a control character: $target"
      _txn_message 'Check the permissions and the link target, then resume the replay.'
      return 1
    fi
    # Une panne de publication du marqueur ne répète pas un inverse achevé.
    if [ "$current" = "$before" ]; then _txn_write "$d/done" 'done'; return; fi
  fi
  if [ "$prudent" = yes ] && [ "$action" != skip ]; then
    if [ "$action" = mkdir ] && [ "$current" = absent ]; then :
    elif [ "$current" != "$after" ]; then
      _txn_message "Kept because changed since the installation: $target"
      _txn_message "Backup: $d. Put the recent data somewhere safe, restore the installed state, then resume uninstall_replay."
      return 1
    fi
  fi
  case "$action" in
    skip) : ;;
    mkdir) if _txn_exists "$target"; then rmdir "$target" || return; fi ;;
    cmd)
      local rc
      if "$inverse" "$target" "${LAB_TXN_FIELDS[@]:8}" >&2; then :; else
        rc=$?
        _txn_message "Inverse $inverse failed (code $rc): $target. Fix this function before resuming."
        return "$rc"
      fi
      [ "$(_txn_fingerprint "$target")" = "$before" ] || return 1 ;;
    *)
      _txn_remove "$target" || return
      if [ "$before" != absent ]; then _txn_copy "$d/before" "$target" || return; fi ;;
  esac
  _txn_write "$d/done" 'done'
}
# Retrait sélectif versionné, hors des transactions d'installation : il n'a pas
# d'inverse qui puisse réinstaller une intégration. L'état prêt et les deux copies
# sont publiés avant l'effet. Les lignes précédentes de la même cible sont ensuite
# acquittées ; une reprise répète cet acquittement même si la dernière est déjà done.
_txn_retirement_validate() {
  local d="$1/retirement" target="$2" f
  [ ! -e "$d" ] && [ ! -L "$d" ] && return 0
  _txn_plain_path "$d" && [ -d "$d" ] && [ "$(stat -f %Lp "$d")" = 700 ] || return 1
  for f in state before after; do
    _txn_plain_path "$d/$f" && [ -f "$d/$f" ] || return 1
  done
  [ "$(stat -f %Lp "$d/state")" = 600 ] || return 1
  local lines=() line
  while IFS= read -r line; do lines+=("$line"); done <"$d/state"
  [ "${#lines[@]}" -eq 4 ] && [ "${lines[0]}" = treelab-retirement-v1 ] && [ "${lines[1]}" = "$target" ] || return 1
  [ "$(_txn_fingerprint "$d/before")" = "${lines[2]}" ] && [ "$(_txn_fingerprint "$d/after")" = "${lines[3]}" ]
}
_txn_retirement_ack() {
  local stop="$1" target="$2" line d
  while IFS= read -r line; do
    [ "$line" != $'treelab-install\t1' ] || continue
    _txn_parse "$line" || return 1
    d="$LAB_TXN_BACKUPS/${LAB_TXN_FIELDS[0]}/${LAB_TXN_FIELDS[1]}"
    if [ "${LAB_TXN_FIELDS[3]}" = "$target" ] && [ ! -f "$d/done" ]; then
      # Un ajout client peut empêcher de rétablir le lien d'instructions ancien.
      # Garder cette restauration en attente, même après retrait de notre bloc.
      if [ "${LAB_TXN_FIELDS[2]}" = replace ] && [ -L "$d/before" ]; then :
      else _txn_write "$d/done" 'done' || return; fi
    fi
    [ "$d" != "$stop" ] || return 0
  done <"$LAB_TXN_MANIFEST"
  return 1
}
_txn_retirement_apply() {
  local d="$1" target="$2" current before after tmp
  _txn_retirement_validate "$d" "$target" || return 1
  if [ ! -f "$d/done" ]; then
    current="$(_txn_fingerprint "$target")" || return
    before="$(sed -n '3p' "$d/retirement/state")"; after="$(sed -n '4p' "$d/retirement/state")"
    if [ "$current" = "$before" ]; then
      tmp="$(mktemp "$(dirname "$target")/.treelab-retire.XXXXXXXX")" || return
      if _txn_copy "$d/retirement/after" "$tmp" && mv -f "$tmp" "$target"; then :
      else local rc=$?; rm -f "$tmp"; return "$rc"; fi
    elif [ "$current" != "$after" ]; then
      _txn_message "Incomplete removal, recent change kept: $target. Backups: $d/retirement. Restore the saved target before resuming."
      return 1
    fi
  fi
  _txn_retirement_ack "$d" "$target"
}
# uninstall_retire <cible canonique> <fichier préparé> : seulement un fichier
# partagé modifié depuis sa pose. La préparation sélective appartient à la CLI.
uninstall_retire() {
  local target="$1" prepared="$2" line latest='' d='' staging before after action
  [ -z "${LAB_TXN_ACTIVE:-}" ] && _txn_paths && _txn_validate_manifest && _txn_pending && [ -z "$LAB_TXN_PENDING" ] || return 1
  [ -f "$target" ] && [ ! -L "$target" ] && [ -f "$prepared" ] && [ ! -L "$prepared" ] || return 1
  [ -f "$LAB_TXN_MANIFEST" ] || return 1
  while IFS= read -r line; do
    [ "$line" != $'treelab-install\t1' ] || continue
    _txn_parse "$line" || return 1
    if [ "${LAB_TXN_FIELDS[3]}" = "$target" ] && [ "${LAB_TXN_FIELDS[2]}" != skip ]; then latest="$line"; fi
  done <"$LAB_TXN_MANIFEST"
  [ -n "$latest" ] && _txn_parse "$latest" || return 1
  action="${LAB_TXN_FIELDS[2]}"; case "$action" in create|modify) ;; *) return 1 ;; esac
  d="$LAB_TXN_BACKUPS/${LAB_TXN_FIELDS[0]}/${LAB_TXN_FIELDS[1]}"
  if [ -d "$d/retirement" ]; then _txn_retirement_apply "$d" "$target"; return; fi
  [ ! -f "$d/done" ] || return 0
  staging="$(mktemp -d "$d/retirement.XXXXXXXX")" || return
  if _txn_copy "$target" "$staging/before" && _txn_copy "$prepared" "$staging/after" &&
     chmod "$(stat -f %Lp "$target")" "$staging/after" &&
     before="$(_txn_fingerprint "$staging/before")" && after="$(_txn_fingerprint "$staging/after")" &&
     _txn_write "$staging/state" "$(printf 'treelab-retirement-v1\n%s\n%s\n%s' "$target" "$before" "$after")" &&
     mv "$staging" "$d/retirement"; then :
  else local rc=$?; _txn_remove "$staging"; return "$rc"; fi
  _txn_retirement_apply "$d" "$target"
}
_txn_restore_manifest() {
  local d="$LAB_TXN_ACTIVE"
  _txn_plain_path "$d/manifest.before" && _txn_plain_path "$d/manifest.restore" && _txn_plain_path "$d/manifest-state" || return 1
  local previous; previous="$(cat "$d/manifest-state")" || return
  case "$previous" in present|absent) ;; *) return 1 ;; esac
  if [ "$previous" = present ]; then
    [ -f "$d/manifest.before" ] || return 1
    # Préserver octets, mode et date du manifeste ancien, y compris après son mv.
    if ! cmp -s "$d/manifest.before" "$LAB_TXN_MANIFEST"; then
      _txn_copy "$d/manifest.before" "$d/manifest.restore" && mv -f "$d/manifest.restore" "$LAB_TXN_MANIFEST"
    fi
  elif [ -e "$LAB_TXN_MANIFEST" ]; then rm "$LAB_TXN_MANIFEST"
  fi
}
txn_rollback() {
  _txn_paths || return
  if [ -z "${LAB_TXN_ACTIVE:-}" ]; then
    _txn_validate_manifest && _txn_pending || return 1
    LAB_TXN_ACTIVE="$LAB_TXN_PENDING"
  fi
  if [ -z "$LAB_TXN_ACTIVE" ]; then _txn_message 'Nothing to restore.'; return 0; fi
  local d line p failed=0 dirs=() parents=()
  if ! { _txn_write "$LAB_TXN_ACTIVE/rollback" pending && _txn_restore_manifest; }; then
    _txn_restore_shell
    _txn_message "Incomplete restore of the manifest: $LAB_TXN_MANIFEST. Backups kept: $LAB_TXN_ACTIVE. Fix the permissions, then resume txn_rollback."
    return 1
  fi
  _txn_plain_path "$LAB_TXN_ACTIVE" && _txn_plain_path "$LAB_TXN_ACTIVE/parents" || return 1
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    _txn_field "$p" && _txn_plain_path "$p" || return 1
    case "$LAB_TXN_BACKUPS/" in "$p/"*) parents+=("$p") ;; *) return 1 ;; esac
  done <"$LAB_TXN_ACTIVE/parents"
  while IFS= read -r d; do dirs+=("$d"); done < <(find "$LAB_TXN_ACTIVE" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort -t / -k 1,1)
  # Les noms des opérations sont numériques ; ne jamais trier 10 avant 2.
  local n max=0
  for d in ${dirs[@]+"${dirs[@]}"}; do n="${d##*/}"; [[ "$n" =~ ^[1-9][0-9]*$ ]] || { failed=1; break; }; [ "$n" -le "$max" ] || max="$n"; done
  # Prévalider toutes les lignes avant le premier inverse, même en reprise.
  for d in ${dirs[@]+"${dirs[@]}"}; do
    _txn_plain_path "$d/row" || { failed=1; break; }
    if [ -f "$d/row" ]; then
      if ! { line="$(cat "$d/row")" && _txn_validate_row "$line" no; }; then failed=1; break; fi
    fi
  done
  n="$max"
  while [ "$failed" -eq 0 ] && [ "$n" -gt 0 ]; do
    d="$LAB_TXN_ACTIVE/$n"
    if [ -f "$d/row" ]; then
      line="$(cat "$d/row")" || { failed=1; break; }
      if _txn_undo_row "$line" no; then :; else failed=1; break; fi
    fi
    n=$((n - 1))
  done
  if [ "$failed" -eq 0 ]; then
    rm -R "$LAB_TXN_ACTIVE" || failed=1
    if [ "$failed" -eq 0 ]; then
      LAB_TXN_ACTIVE=''
      for p in ${parents[@]+"${parents[@]}"}; do rmdir "$p" || { failed=1; break; }; done
    fi
  fi
  _txn_restore_shell
  if [ "$failed" -ne 0 ]; then
    _txn_message "Incomplete restore. Backups kept: ${LAB_TXN_ACTIVE:-$LAB_TXN_BACKUPS}"
    _txn_message 'Fix the shown cause (permissions or inverse), then resume txn_rollback.'
    return 1
  fi
  _txn_message 'Restore finished.'
}
txn_commit() {
  [ -n "${LAB_TXN_ACTIVE:-}" ] || { _txn_message 'No transaction to commit. Call txn_begin before trying again.'; return 1; }
  local rc
  if _txn_commit; then LAB_TXN_ACTIVE=''; _txn_restore_shell; return 0; else rc=$?; fi
  _txn_fail "$rc" 'commit impossible; check the log and the permissions, then try again.'
}
_txn_commit() {
  local tmp="$LAB_TXN_ACTIVE/manifest" n=1 d line after
  _txn_validate_manifest && _txn_private_file "$tmp" || return
  if [ -f "$LAB_TXN_MANIFEST" ]; then cat "$LAB_TXN_MANIFEST" >"$tmp" || return
  else printf 'treelab-install\t1\n' >"$tmp" || return; fi
  # Même une transaction vide est représentée ; elle ne doit pas devenir orpheline.
  [ "$LAB_TXN_SEQ" -gt 0 ] || _txn_record skip "$(dirname "$LAB_STATE")/transaction-vide" 'transaction vide' || return
  while [ "$n" -le "$LAB_TXN_SEQ" ]; do
    d="$LAB_TXN_ACTIVE/$n"; line="$(cat "$d/row")" && after="$(cat "$d/after")" || return
    _txn_validate_row "$line" no || return
    LAB_TXN_FIELDS[5]="$after"
    line="$(_txn_row "${LAB_TXN_FIELDS[@]}")" || return
    _txn_validate_row "$line" yes || return
    printf '%s\n' "$line" >>"$tmp" || return
    n=$((n + 1))
  done
  _txn_write "$LAB_TXN_ACTIVE/sealed-count" "$LAB_TXN_SEQ" || return
  mv -f "$tmp" "$LAB_TXN_MANIFEST"
}
uninstall_replay() {
  [ -z "${LAB_TXN_ACTIVE:-}" ] || { _txn_message 'Transaction open. Finish txn_rollback before the replay.'; return 1; }
  if ! { _txn_paths && _txn_validate_manifest && _txn_pending; }; then
    _txn_message "Invalid log: ${LAB_TXN_MANIFEST:-none}. Keep the backups and restore the log before resuming."; return 1;
  fi
  [ -z "$LAB_TXN_PENDING" ] || { _txn_message "Restore pending: $LAB_TXN_PENDING. Resume txn_rollback."; return 1; }
  if [ ! -f "$LAB_TXN_MANIFEST" ]; then _txn_message 'Nothing to undo.'; return 0; fi
  local line rows=() i
  while IFS= read -r line; do rows+=("$line"); done <"$LAB_TXN_MANIFEST"
  i=$((${#rows[@]} - 1))
  while [ "$i" -ge 1 ]; do
    if _txn_undo_row "${rows[i]}" yes; then :; else
      _txn_message "Incomplete restore. Backups kept: $LAB_TXN_BACKUPS"
      _txn_message 'Fix the shown cause, then resume uninstall_replay.'; return 1
    fi
    i=$((i - 1))
  done
  _txn_message 'Undo finished; nothing more to undo.'
}
