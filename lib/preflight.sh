# shellcheck shell=bash
# Préparation en lecture seule ; aucun test de droits par création de fichier.
declare -F terminal_resolve >/dev/null || . "${BASH_SOURCE[0]%/*}/terminal.sh"   # le fork de cmux posé (lot 02 d'app-treelab)
_preflight_error() { printf 'lab: Blocked: %s. %s\n' "$1" "$2" >&2; LAB_PREFLIGHT_ERRORS=$((LAB_PREFLIGHT_ERRORS + 1)); }
_preflight_tool() { command -v "$1" >/dev/null 2>&1; }
_preflight_system() {
  local os version tool
  os="$(uname -s)"; version="$(sw_vers -productVersion 2>/dev/null || true)"
  if [ "$os" != Darwin ] || ! [[ "${version%%.*}" =~ ^[0-9]+$ ]] || [ "${version%%.*}" -lt 13 ]; then
    _preflight_error "macOS 13 or later required (system: $os $version)" 'Use a compatible macOS machine.'
  fi
  for tool in git jq; do
    _preflight_tool "$tool" || _preflight_error "$tool missing" "Install $tool, then run the command again."
  done
  export LAB_SETUP_CLAUDE=no LAB_SETUP_CODEX=no LAB_SETUP_BREW=no
  _preflight_tool claude && LAB_SETUP_CLAUDE=yes
  _preflight_tool codex && LAB_SETUP_CODEX=yes
  if [ "${LAB_SETUP_MODE:-setup}" = setup ] && [ "$LAB_SETUP_CLAUDE:$LAB_SETUP_CODEX" = no:no ]; then
    _preflight_error 'no agent available' 'Install the claude or codex command, then try again.'
  fi
  # sans cmux, une app de terminal posée (le fork, ou celle de terminal_app= de ~/.lab/config) suffit : rien à proposer
  if [ "${LAB_SETUP_MODE:-setup}" = setup ] && ! _preflight_tool cmux && ! { terminal_resolve; [ "$TA_OK" = 1 ]; }; then
    if _preflight_tool brew; then LAB_SETUP_BREW=yes
    else _preflight_error 'cmux and Homebrew missing' 'Install cmux, then run the command again.'; fi
  fi
}
_preflight_writable() {
  local input="$1" p="$1"
  _txn_field "$p" || { _preflight_error "$input" 'Remove the control characters from the path.'; return 1; }
  case "$p/" in /*) ;; *) _preflight_error "$p" 'Use an absolute path.'; return 1 ;; esac
  case "$p/" in *'/../'*|*'/./'*|*'//'*) _preflight_error "$p" 'Use a normalized path.'; return 1 ;; esac
  while ! _txn_exists "$p"; do p="${p%/*}"; p="${p:-/}"; done
  if [ -L "$p" ]; then
    if ! p="$(_txn_resolve_modify "$p")" || ! [ -e "$p" ]; then
      _preflight_error "$input" 'Fix the broken link or its loop before trying again.'; return 1
    fi
  fi
  if [ ! -w "$p" ] || { [ -d "$p" ] && [ ! -x "$p" ]; }; then
    _preflight_error "$input" "Restore write and traverse permissions on $p."; return 1
  fi
  while [ "$p" != / ]; do
    p="${p%/*}"; p="${p:-/}"
    [ -d "$p" ] && [ -x "$p" ] || { _preflight_error "$input" "Restore access to the folder $p."; return 1; }
  done
}
# _preflight_in_import <chemin> : le chemin ou l'un de ses dossiers parents est l'installation importée sur le disque (-ef), casse comprise.
_preflight_in_import() {
  local p="$1"
  [ -n "${LAB_SETUP_IMPORT:-}" ] || return 1
  case "$p" in /*) ;; *) return 1 ;; esac
  while [ -n "$p" ] && [ "$p" != / ]; do
    if [ "$p" -ef "$LAB_SETUP_IMPORT" ]; then return 0; fi
    p="${p%/*}"
  done
  return 1
}
_preflight_source_safe() {
  local target="$1" root part
  # Une destination cliente peut pointer vers la précédente ou une autre release.
  # Toute l'arborescence publiée reste immuable, même hors des dossiers de code.
  root="$(real_path "$HOME/.lab/releases")"
  case "$target/" in "$root/"*)
    _preflight_error "$target" 'Destination inside the program; fix the link before trying again.'; return 1 ;;
  esac
  if _preflight_in_import "$target"; then
    _preflight_error "$target" "Destination inside the imported installation, never written; fix the link before trying again."; return 1
  fi
  for root in "$LAB_ROOT" "${LAB_SETUP_ROOT:-$LAB_ROOT}" "${LAB_SETUP_SOURCE:-$LAB_ROOT}"; do
    root="$(real_path "$root")"
    for part in bin lib hooks skills agents templates; do
      case "$target/" in "$root/$part/"*)
        _preflight_error "$target" 'Destination inside the program; fix the link before trying again.'; return 1 ;;
      esac
    done
  done
}
_preflight_lock() {
  local file="$1" pid
  _txn_exists "$file" || return 0
  if [ ! -f "$file" ] || [ -L "$file" ] || [ ! -r "$file" ]; then
    _preflight_error 'session existence undeterminable' 'Keep the lock and restore its read access before changing the integrations.'; return 1
  fi
  pid="$(lock_field "$file" pid)"
  if ! [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
    _preflight_error "$file" 'Invalid PID; check the session and restore its lock.'; return 1
  fi
  case "$(pid_state "$pid")" in   # la règle « prouvé mort » vit dans lib/lock.sh (lot 02) : kill -0 puis ps sans erreur ni sortie
    alive)
      LAB_PREFLIGHT_SESSION_LIST="${LAB_PREFLIGHT_SESSION_LIST:-}live session (PID $pid): $file"$'\n'
      _preflight_error "live session (PID $pid): $file" 'End this session before changing the integrations.'; return 1 ;;
    dead) return 0 ;;
  esac
  LAB_PREFLIGHT_SESSION_LIST="${LAB_PREFLIGHT_SESSION_LIST:-}session existence undeterminable: $file"$'\n'
  _preflight_error "session existence undeterminable: $file" 'Allow reading the processes, then start again; the lock is kept.'
  return 1
}
_preflight_sessions() {
  local config root path seen='|' registry errors="$LAB_PREFLIGHT_ERRORS"
  LAB_PREFLIGHT_SESSION_LIST=''
  # Lire les seuls chemins racines du registre (et de celui de l'installation importée), sans charger ni nettoyer leurs données.
  for registry in "$LAB_PROJECTS" ${LAB_SETUP_IMPORT:+"$LAB_SETUP_IMPORT/projects"}; do
  for config in "$registry"/*/config; do
    [ -f "$config" ] || continue
    root="$(sed -n 's/^root=//p' "$config" | head -1)"; [ -d "$root" ] || continue
    for path in "$root" "$root"/.worktrees/*; do
      case "$seen" in *"|$path|"*) continue ;; esac
      seen="$seen$path|"; _preflight_lock "$path/.lab/session.lock" || true
    done
  done
  done
  _preflight_lock "$LAB_ROOT/.lab/session.lock" || true
  [ -z "${LAB_SETUP_IMPORT:-}" ] || _preflight_lock "$LAB_SETUP_IMPORT/.lab/session.lock" || true
  if operation_paths; then
    if [ -L "$LAB_SESSION_DIRECTORY" ]; then
      _preflight_error 'session index is a link' 'Restore a regular folder so sessions can be checked before trying again.'
    elif _txn_exists "$LAB_SESSION_DIRECTORY"; then
      if [ ! -d "$LAB_SESSION_DIRECTORY" ] || [ ! -r "$LAB_SESSION_DIRECTORY" ] ||
        [ ! -x "$LAB_SESSION_DIRECTORY" ] || [ "$(stat -f %u "$LAB_SESSION_DIRECTORY")" != "$(id -u)" ]; then
        _preflight_error "session index undeterminable: $LAB_SESSION_DIRECTORY" 'Keep its content and restore read and traverse access to the folder before trying again.'
      else
        for path in "$LAB_SESSION_DIRECTORY"/*; do
          _preflight_lock "$path" || true
        done
      fi
    fi
  else
    _preflight_error 'session index undeterminable' 'Restore read access to the home folder and the processes before trying again.'
  fi
  # shellcheck disable=SC2034 # Lu par cmd_setup : une simulation que seules des sessions bloquent va au bout du plan.
  LAB_PREFLIGHT_SESSION_ERRORS=$((LAB_PREFLIGHT_ERRORS - errors))
}
_preflight_removal() {
  local line d id='' started=no remaining=no unfinished=no
  [ "${LAB_SETUP_MODE:-setup}" = setup ] && [ -f "$LAB_TXN_MANIFEST" ] || return 0
  while IFS= read -r line; do
    [ "$line" != $'treelab-install\t1' ] || continue
    _txn_parse "$line" || return 1
    if [ "$id" != "${LAB_TXN_FIELDS[0]}" ]; then
      if [ "$started:$remaining" = yes:yes ]; then unfinished=yes; fi
      started=no; remaining=no; id="${LAB_TXN_FIELDS[0]}"
      [ ! -f "$LAB_TXN_BACKUPS/$id/remove-started" ] || started=yes
    fi
    d="$LAB_TXN_BACKUPS/${LAB_TXN_FIELDS[0]}/${LAB_TXN_FIELDS[1]}"
    if [ -f "$d/done" ]; then started=yes; else remaining=yes; fi
    if [ -d "$d/retirement" ]; then started=yes; fi
  done <"$LAB_TXN_MANIFEST"
  if [ "$started:$remaining" = yes:yes ] || [ "$unfinished" = yes ]; then
    _preflight_error 'unfinished removal' 'Finish treelab uninstall --resume before a new install.'
  fi
}
preflight() {
  LAB_PREFLIGHT_ERRORS=0
  _preflight_system
  _preflight_writable "$LAB_STATE" || true
  _preflight_source_safe "$LAB_STATE" || true
  if _preflight_tool jq; then
    if ! { _txn_paths && _txn_validate_manifest && _txn_pending; }; then
      _preflight_error "$LAB_STATE" 'Invalid journal or backups; keep them and restore their integrity.'
    elif [ -n "$LAB_TXN_PENDING" ] && [ "${LAB_SETUP_RESUME:-no}" != yes ]; then
      _preflight_error "restore pending: $LAB_TXN_PENDING" 'Run treelab uninstall --resume from a terminal.'
    else _preflight_removal || true
    fi
  fi
  # treelab update bascule current sous des sessions vivantes : elles gardent les fichiers de leur release (lot 21).
  [ "${LAB_PREFLIGHT_SESSIONS:-yes}" = no ] || _preflight_sessions
  if [ -d "$HOME/.git" ] || [ -f "$HOME/.git" ]; then
    printf 'lab: The home folder is under version control; your dotfiles stay managed in that repository. No project or trust added.\n' >&2
  fi
  [ "$LAB_PREFLIGHT_ERRORS" -eq 0 ]
}
