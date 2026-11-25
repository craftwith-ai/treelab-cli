# shellcheck shell=bash
# terminal.sh — l'app de terminal que lab pilote (lot 02 d'app-treelab) : lue dans la config et dans les paquets posés, sans aucune
# commande de cmux. Chargé par lib/cmux.sh et par la garde (lib/guard_fast.sh), qui protège la commande du fork comme celle de cmux.
declare -F kv_value >/dev/null || . "${BASH_SOURCE[0]%/*}/kv.sh"   # des tests chargent ce fichier sans lib/project.sh

# ---------- app de terminal pilotée (lot 02 d'app-treelab) ----------
# lab pilote cmux, ou une autre app qui en garde la commande, le socket et le vocabulaire AppleScript (le fork Treelab) :
# terminal_app=<chemin du .app> de la config du projet, sinon de $LAB_HOME/config ; sans ligne, la commande cmux du PATH (comportement
# d'avant), sinon une app candidate posée qui porte sa commande (LAB_TERMINAL_APPS, chemins séparés par des deux-points, remplace
# TERMINAL_APPS_DEFAULT ; vide : aucune) ; sinon aucune. terminal_cli= et terminal_socket= se lisent dans le même ordre et ne valent
# que pour une app nommée ou trouvée. Une ligne qui nomme une app absente : avertissement, app injoignable, rien ouvert ailleurs.
# Retour arrière : retirer la ligne. Une app se reconnaît à son chemin et à sa commande, jamais à son seul identifiant (Treelab.app du
# lot 01 et le fork peuvent partager le leur).
TERMINAL_APPS_DEFAULT="/Applications/Treelab.app:$HOME/Applications/Treelab.app"
# variables qu'un terminal de cmux (ou du fork) pose et que sa commande lit : socket, mot de passe, espace et onglet par défaut

# terminal_plist_set <app> : PL_ID (CFBundleIdentifier) et PL_EXEC (CFBundleExecutable) de son Info.plist. Le XML se lit par le shell
# seul ; un plist binaire passe par plutil (absent, sous Linux : rien lu). rc 1 si rien ne se lit
terminal_plist_set() {
  local f="$1/Contents/Info.plist" xml=""
  PL_ID=""; PL_EXEC=""
  [ -f "$f" ] && [ -r "$f" ] || return 1
  IFS= read -r -d '' xml <"$f" || true
  case "$xml" in
    bplist*) command -v plutil >/dev/null 2>&1 && xml="$(plutil -convert xml1 -o - -- "$f" 2>/dev/null)" || return 1 ;;
  esac
  ! terminal_plist_key "$xml" CFBundleIdentifier || PL_ID="$PL_VALUE"
  ! terminal_plist_key "$xml" CFBundleExecutable || PL_EXEC="$PL_VALUE"
  [ -n "$PL_ID$PL_EXEC" ]
}
terminal_plist_key() { # <xml> <clé> → PL_VALUE, la chaîne qui suit <key>clé</key>
  local rest="${1#*"<key>$2</key>"}"
  PL_VALUE=""
  [ "$rest" != "$1" ] || return 1
  rest="${rest#"${rest%%[![:space:]]*}"}"
  case "$rest" in "<string>"*) rest="${rest#<string>}"; PL_VALUE="${rest%%</string>*}" ;; *) return 1 ;; esac
}
# terminal_app_read <app> [commande imposée] : AR_ID et AR_CLI de ce paquet — la commande imposée, sinon Contents/Resources/bin/cmux,
# sinon Contents/Resources/bin/<CFBundleExecutable en minuscules> ; rc 1 sans commande exécutable
terminal_app_read() {
  local app="$1"
  AR_ID=""; AR_CLI=""
  [ -d "$app/Contents" ] || return 1
  terminal_plist_set "$app" || true
  AR_ID="$PL_ID"
  if [ -n "${2:-}" ]; then AR_CLI="$2"
  elif [ -x "$app/Contents/Resources/bin/cmux" ]; then AR_CLI="$app/Contents/Resources/bin/cmux"
  elif [ -n "$PL_EXEC" ]; then terminal_lower "$PL_EXEC"; AR_CLI="$app/Contents/Resources/bin/$T_LOWER"
  fi
  [ -n "$AR_CLI" ] && [ -f "$AR_CLI" ] && [ -x "$AR_CLI" ]
}
# terminal_lower <mot> : T_LOWER, ses lettres ASCII en minuscules, sans processus (la barre des menus relit les apps chaque minute)
terminal_lower() {
  local w="$1" c i up=ABCDEFGHIJKLMNOPQRSTUVWXYZ lo=abcdefghijklmnopqrstuvwxyz
  T_LOWER=""
  while [ -n "$w" ]; do
    c="${w:0:1}"; w="${w:1}"
    case "$up" in *"$c"*) i="${up%%"$c"*}"; c="${lo:${#i}:1}" ;; esac
    T_LOWER="$T_LOWER$c"
  done
}
terminal_path() { # <valeur lue> → T_PATH, ~/ développé, sans barre finale
  T_PATH="$1"
  # shellcheck disable=SC2088 # un ~ écrit dans la config, comparé tel quel puis développé ici
  case "$T_PATH" in "~/"*) T_PATH="$HOME/${T_PATH#"~/"}" ;; esac
  while [ "${T_PATH%/}" != "$T_PATH" ] && [ "$T_PATH" != / ]; do T_PATH="${T_PATH%/}"; done
}
# terminal_key <clé> : KV_VALUE, la valeur de la config du projet chargé, sinon de $LAB_HOME/config ; T_FILE, le fichier lu
terminal_key() {
  T_FILE=""
  if [ -n "${P_NAME:-}" ] && [ -n "${LAB_PROJECTS:-}" ] && kv_value "$LAB_PROJECTS/$P_NAME/config" "$1" && [ -n "$KV_VALUE" ]; then
    T_FILE="$LAB_PROJECTS/$P_NAME/config"; return 0
  fi
  if [ -n "${LAB_HOME:-}" ] && kv_value "$LAB_HOME/config" "$1" && [ -n "$KV_VALUE" ]; then T_FILE="$LAB_HOME/config"; return 0; fi
  KV_VALUE=""; return 1
}
# cmux lui-même : identifiant com.cmuxterm.app (ses variantes com.cmuxterm.*) ; ses paquets posés hors du PATH, LAB_CMUX_APPS (chemins
# séparés par des deux-points) remplace TERMINAL_CMUX_APPS_DEFAULT ; vide : aucun
TERMINAL_CMUX_APPS_DEFAULT="/Applications/cmux.app:$HOME/Applications/cmux.app"
terminal_cmux_id() { case "$1" in com.cmuxterm.app|com.cmuxterm.*) return 0 ;; *) return 1 ;; esac; }
# terminal_bundle_of <commande> : T_PATH, le paquet .app qui la contient (vide hors d'un paquet), et PL_ID, son identifiant lu
terminal_bundle_of() {
  T_PATH=""; PL_ID=""
  case "$1" in /*.app/Contents/*) T_PATH="${1%%.app/Contents/*}.app"; terminal_plist_set "$T_PATH" || true ;; esac
}
# terminal_cmux_app : la commande de cmux lui-même — la première commande cmux du PATH qui n'est pas celle d'une autre app (le fork,
# dont les terminaux mettent leur bin/ en tête du PATH, la nomme aussi cmux : sautée), sinon, après une commande sautée seulement,
# celle d'un paquet de cmux posé (LAB_CMUX_APPS). T_CMD : « cmux », son nom, quand c'est la première du PATH (l'appel d'avant, à l'identique), sinon son chemin ;
# T_CMDPATH : son chemin ; T_PATH : son paquet, vide hors d'un paquet (un lien de brew est pris pour cmux) ; T_OTHER : le paquet d'une
# commande cmux sautée. Le shell seul. rc 1 sans aucune
terminal_cmux_app() {
  local list="$PATH" d f first=1
  T_CMD=""; T_CMDPATH=""; T_PATH=""; T_OTHER=""
  while [ -n "$list" ]; do
    d="${list%%:*}"; if [ "$d" = "$list" ]; then list=""; else list="${list#*:}"; fi
    f="${d:-.}/cmux"; [ -f "$f" ] && [ -x "$f" ] || continue
    terminal_bundle_of "$f"
    if [ -z "$T_PATH" ] || [ -z "$PL_ID" ] || terminal_cmux_id "$PL_ID"; then
      if [ "$first" = 1 ]; then T_CMD=cmux; else T_CMD="$f"; fi
      T_CMDPATH="$f"; return 0
    fi
    [ -n "$T_OTHER" ] || T_OTHER="$T_PATH"
    first=0
  done
  # le paquet posé seulement quand une autre app a pris le nom (terminal du fork) ; sinon rien de plus qu'avant (command -v cmux)
  [ -n "$T_OTHER" ] || { T_PATH=""; return 1; }
  list="${LAB_CMUX_APPS-$TERMINAL_CMUX_APPS_DEFAULT}"
  while [ -n "$list" ]; do
    d="${list%%:*}"; if [ "$d" = "$list" ]; then list=""; else list="${list#*:}"; fi
    [ -n "$d" ] || continue
    terminal_path "$d"; f="$T_PATH/Contents/Resources/bin/cmux"
    [ -f "$f" ] && [ -x "$f" ] || continue
    PL_ID=""; terminal_plist_set "$T_PATH" || true
    [ -z "$PL_ID" ] || terminal_cmux_id "$PL_ID" || continue
    T_CMD="$f"; T_CMDPATH="$f"; return 0
  done
  T_PATH=""; return 1
}
# terminal_resolve : l'app pilotée pour le projet chargé ($P_NAME), une fois par processus, projet et environnement (TA_FOR) —
# TA_SOURCE (project|global|cmux|fork|none), TA_APP (paquet ; vide pour cmux), TA_BUNDLE et TA_CMDPATH (paquet et chemin de la
# commande, cmux compris), TA_ID, TA_CLI, TA_SOCKET,
# TA_FILE et TA_LINE (la ligne lue), TA_OK (1 : joignable) et TA_FOREIGN (1 : lab tourne dans le terminal d'une autre app — son
# CMUX_BUNDLE_ID diffère : ses variables de socket et d'onglet ne sont jamais passées à la commande). Sans aucune ligne, la commande
# cmux (terminal_cmux_app), appelée comme avant ; étrangère dans le terminal d'une autre app. Aucun processus sans ligne
terminal_resolve() {
  local key="${P_NAME:-}|${LAB_HOME:-}|${LAB_PROJECTS:-}|$PATH|${LAB_TERMINAL_APPS-default}|${LAB_CMUX_APPS-default}|${CMUX_BUNDLE_ID:-}"
  local c list cli=""
  [ "${TA_FOR:-}" != "$key" ] || return 0
  TA_FOR="$key"; TA_SOURCE=none; TA_APP=""; TA_ID=""; TA_CLI=""; TA_SOCKET=""; TA_FILE=""; TA_LINE=""; TA_OK=0; TA_FOREIGN=0; TA_WARNED=0
  TA_BUNDLE=""; TA_CMDPATH=""
  if terminal_key terminal_app; then
    TA_FILE="$T_FILE"; TA_LINE="$KV_VALUE"
    if [ "$TA_FILE" = "${LAB_HOME:-}/config" ]; then TA_SOURCE=global; else TA_SOURCE=project; fi
    terminal_path "$KV_VALUE"; TA_APP="$T_PATH"
  elif terminal_cmux_app; then
    # shellcheck disable=SC2034 # TA_BUNDLE et TA_CMDPATH : lus par lib/app.sh
    TA_SOURCE=cmux; TA_CLI="$T_CMD"; TA_OK=1; TA_BUNDLE="$T_PATH"; TA_CMDPATH="$T_CMDPATH"; TA_ID="${PL_ID:-com.cmuxterm.app}"
    # dans le terminal d'une autre app (le fork) : jamais ses variables de socket ni d'onglet ; une variante de cmux garde les siennes
    [ -z "${CMUX_BUNDLE_ID:-}" ] || terminal_cmux_id "$CMUX_BUNDLE_ID" || TA_FOREIGN=1
    return 0
  else
    list="${LAB_TERMINAL_APPS-$TERMINAL_APPS_DEFAULT}"
    while [ -n "$list" ]; do
      c="${list%%:*}"; if [ "$c" = "$list" ]; then list=""; else list="${list#*:}"; fi
      [ -n "$c" ] || continue
      terminal_path "$c"
      if terminal_app_read "$T_PATH"; then TA_SOURCE=fork; TA_APP="$T_PATH"; break; fi
    done
    [ "$TA_SOURCE" = fork ] || return 0
  fi
  # terminal_cli= et terminal_socket= : ceux du fichier qui nomme l'app, jamais d'un autre (le fork trouvé sans ligne n'en a pas)
  if [ -n "$TA_FILE" ] && kv_value "$TA_FILE" terminal_cli && [ -n "$KV_VALUE" ]; then terminal_path "$KV_VALUE"; cli="$T_PATH"; fi
  ! terminal_app_read "$TA_APP" "$cli" || TA_OK=1
  TA_ID="$AR_ID"
  # shellcheck disable=SC2034 # TA_CLI, TA_SOCKET et TA_FOREIGN : lus par cmx et cmux_identify (lib/cmux.sh)
  TA_CLI="$AR_CLI"
  # shellcheck disable=SC2034 # lus par lib/app.sh
  TA_BUNDLE="$TA_APP"
  # shellcheck disable=SC2034
  TA_CMDPATH="$TA_CLI"
  if [ -n "$TA_FILE" ] && kv_value "$TA_FILE" terminal_socket && [ -n "$KV_VALUE" ]; then
    terminal_path "$KV_VALUE"
    # shellcheck disable=SC2034 # lu par cmx (lib/cmux.sh)
    TA_SOCKET="$T_PATH"
  fi
  # shellcheck disable=SC2034
  if [ -n "${CMUX_BUNDLE_ID:-}" ] && { [ -z "$TA_ID" ] || [ "$CMUX_BUNDLE_ID" != "$TA_ID" ]; }; then TA_FOREIGN=1; fi
  return 0
}
# terminal_warn : une ligne terminal_app= qui nomme une app absente (ou sans commande), dite une fois par processus — fichier et clé
terminal_warn() {
  [ -n "$TA_FILE" ] && [ "$TA_OK" != 1 ] && [ "$TA_WARNED" != 1 ] || return 0
  TA_WARNED=1
  warn "terminal_app=$TA_LINE in $TA_FILE: no terminal app with its command there — treated as cmux unreachable, nothing opened elsewhere (remove the line to go back to cmux)"
}
# terminal_found_set : les apps de terminal posées sur ce Mac, une fois par processus — la commande cmux du PATH (son paquet, sinon son
# chemin), les apps nommées par terminal_app= ($LAB_HOME/config, puis chaque projet) et les candidates (LAB_TERMINAL_APPS), celles
# qui portent leur commande : TERMINAL_FOUND (chemins), TERMINAL_FOUND_IDS (identifiants lus) et TERMINAL_FOUND_CLIS (noms de leur
# commande), un par ligne, sans doublon. lab top, la barre des menus et la garde les protègent tous, quel que soit le projet
terminal_found_set() {
  local key="${LAB_HOME:-}|${LAB_PROJECTS:-}|$PATH|${LAB_TERMINAL_APPS-default}|${LAB_CMUX_APPS-default}" list c f cli other
  local -a files=()
  [ "${TF_FOR:-}" != "$key" ] || return 0
  TF_FOR="$key"; TERMINAL_FOUND=""; TERMINAL_FOUND_IDS=""; TERMINAL_FOUND_CLIS=""
  # cmux, puis l'autre app dont la commande cmux le précède dans le PATH (le fork, depuis un de ses terminaux)
  if terminal_cmux_app; then other="$T_OTHER"; terminal_found_add "${T_PATH:-$T_CMDPATH}" "$PL_ID" cmux; else other="$T_OTHER"; fi
  if [ -n "$other" ]; then PL_ID=""; terminal_plist_set "$other" || true; terminal_found_add "$other" "$PL_ID" cmux; fi
  [ -z "${LAB_HOME:-}" ] || files+=("$LAB_HOME/config")
  [ -z "${LAB_PROJECTS:-}" ] || files+=("$LAB_PROJECTS"/*/config)
  for f in "${files[@]+"${files[@]}"}"; do
    kv_value "$f" terminal_app && [ -n "$KV_VALUE" ] || continue
    terminal_path "$KV_VALUE"; c="$T_PATH"; cli=""
    if kv_value "$f" terminal_cli && [ -n "$KV_VALUE" ]; then terminal_path "$KV_VALUE"; cli="$T_PATH"; fi
    ! terminal_app_read "$c" "$cli" || terminal_found_add "$c" "$AR_ID" "${AR_CLI##*/}"
  done
  list="${LAB_TERMINAL_APPS-$TERMINAL_APPS_DEFAULT}"
  while [ -n "$list" ]; do
    c="${list%%:*}"; if [ "$c" = "$list" ]; then list=""; else list="${list#*:}"; fi
    [ -n "$c" ] || continue
    terminal_path "$c"; c="$T_PATH"
    ! terminal_app_read "$c" || terminal_found_add "$c" "$AR_ID" "${AR_CLI##*/}"
  done
  return 0
}
terminal_found_add() { # <chemin> <identifiant> <nom de commande> : une app de plus, une seule fois par chemin
  local nl=$'\n'
  case "$nl$TERMINAL_FOUND$nl" in *"$nl$1$nl"*) return 0 ;; esac
  TERMINAL_FOUND="$TERMINAL_FOUND${TERMINAL_FOUND:+$nl}$1"
  case "$nl$TERMINAL_FOUND_IDS$nl" in *"$nl$2$nl"*) ;; *) [ -z "$2" ] || TERMINAL_FOUND_IDS="$TERMINAL_FOUND_IDS${TERMINAL_FOUND_IDS:+$nl}$2" ;; esac
  case "$nl$TERMINAL_FOUND_CLIS$nl" in *"$nl$3$nl"*) ;; *) [ -z "$3" ] || TERMINAL_FOUND_CLIS="$TERMINAL_FOUND_CLIS${TERMINAL_FOUND_CLIS:+$nl}$3" ;; esac
}
