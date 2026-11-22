# shellcheck shell=bash
# log.sh — sortie et erreurs. Tout message humain va sur stderr ; stdout = KEY=value.
log()  { printf 'lab: %s\n' "$*" >&2; }
# log_wrap <texte> : log replié au mot à la largeur du terminal (onboard_wrap) quand stderr est un terminal ou COLUMNS est posé,
# même règle que lab_say ; sinon la ligne entière, comme log (lot 08 du couloir anglais : lab new et lab launch à 40 colonnes).
log_wrap() {
  if { [ -t 2 ] || [ -n "${COLUMNS:-}" ]; } && declare -F onboard_wrap >/dev/null; then printf 'lab: %s\n' "$*" | onboard_wrap "$(onboard_cols)" >&2
  else log "$*"; fi
}
WARN_PREFIX='lab: WARNING '  # écrit par warn seul ; lab onboard le relit dans le journal de lab init
warn() { printf '%s%s\n' "$WARN_PREFIX" "$*" >&2; }
# warn_wrap <texte> : avertissement replié au mot, même règle que log_wrap — le préfixe reste en tête de la première ligne,
# lisible dans un onglet de 40 colonnes (lot 01 de services-couloir)
warn_wrap() {
  if { [ -t 2 ] || [ -n "${COLUMNS:-}" ]; } && declare -F onboard_wrap >/dev/null; then
    printf '%s%s\n' "$WARN_PREFIX" "$*" | onboard_wrap "$(onboard_cols)" >&2
  else warn "$*"; fi
}
DIE_PREFIX='lab: ERROR '    # écrit par die seul ; lab close --dry-run le relit pour nommer un obstacle
# DIE_READ : le motif qui relit un refus, ancien préfixe compris (journal écrit par un lab d'avant le lot 03 du couloir anglais)
# shellcheck disable=SC2034 # lu par lib/watch.sh et lib/cloud.sh
DIE_READ='lab: (ERROR|ERREUR) '   # expression étendue : grep -E, sed -E
# DIE_HOOK : fonction appelée avec le message avant la sortie (lab next : entrée « blocked » de la tour, lot 03 d'autonomie-tours)
# DIE_HOOK est vidé avant l'appel : appelé une seule fois, jamais en boucle si lui-même meurt
die()  { printf '%s%s\n' "$DIE_PREFIX" "$*" >&2; [ -z "${DIE_HOOK:-}" ] || { local h="$DIE_HOOK"; DIE_HOOK=""; "$h" "$*" 2>/dev/null || true; }; exit 1; }
kv()   { printf '%s=%s\n' "$1" "$2"; }
sep()  { printf '\n'; }
# Convertit un flux KEY=value (blocs séparés par une ligne vide) en tableau JSON.
kv_to_json() {
  jq -Rs '
    split("\n\n") | map(select(length > 0)
      | split("\n") | map(select(length > 0) | capture("^(?<k>[^=]+)=(?<v>.*)$"))
      | map({(.k): .v}) | add // {})'
}
# Exécute une commande avec un délai maximal (secondes). macOS ne livre pas GNU `timeout` :
# le repli bash garde le même code 124 au dépassement, afin que les appelants distinguent attente et échec.
# Le repli lance la commande en arrière-plan, où bash lui donne /dev/null pour entrée : WITH_TIMEOUT_STDIN=1 lui passe l'entrée
# standard de l'appelant (mesuré au lot 04 de comptes-complets : un jeton envoyé par stdin à cmux coderouter n'arrivait pas).
with_timeout() {
  local secs="$1"; shift
  local marker pid timer rc=0 started=$SECONDS
  # -k 1 : KILL une seconde après TERM, comme le repli ; GNU rend alors 137, qui vaut délai dépassé une fois l'échéance passée
  # (lot 01 de services-couloir : un crochet qui ignore TERM ne bloque plus une fermeture)
  if command -v timeout >/dev/null 2>&1; then
    # au KILL, GNU timeout se tue avec son groupe : bash l'annoncerait (« line N: <pid> Killed: 9 ») sur le stderr du groupe,
    # mis à /dev/null ; la commande, elle, écrit sur le stderr d'origine (fd 3)
    { timeout -k 1 "$secs" "$@" 2>&3 3>&-; } 3>&2 2>/dev/null || rc=$?
    if [ "$rc" = 137 ] && [ "$((SECONDS - started))" -ge "$secs" ]; then rc=124; fi
    return "$rc"
  fi
  marker="$(mktemp)"
  # Le mode monitor donne au processus et à ses enfants un groupe distinct, sans changer le shell appelant.
  set -m
  if [ "${WITH_TIMEOUT_STDIN:-0}" = 1 ]; then "$@" <&0 & pid=$!; else "$@" & pid=$!; fi
  set +m
  (
    sleeper=""
    trap '[ -z "$sleeper" ] || kill "$sleeper" 2>/dev/null || true; exit 0' HUP INT TERM
    sleep "$secs" & sleeper=$!
    wait "$sleeper" || exit 0
    if kill -0 "$pid" 2>/dev/null; then
      printf 'timeout\n' >"$marker"
      kill -TERM -- "-$pid" 2>/dev/null || true
      sleep 1 & sleeper=$!
      wait "$sleeper" || exit 0
      kill -KILL -- "-$pid" 2>/dev/null || true
    fi
  ) >/dev/null 2>&1 & timer=$!
  # 2>/dev/null : seule la notice de bash sur la tâche tuée (« <pid> Terminated: 15 "$@" ») se tait ; la commande garde son stderr
  wait "$pid" 2>/dev/null || rc=$?
  kill "$timer" 2>/dev/null || true
  wait "$timer" 2>/dev/null || true
  if [ -s "$marker" ]; then rc=124; fi
  rm -f "$marker"
  return "$rc"
}
# Quote POSIX (simple quotes) : sûr pour bash et zsh, conserve l'UTF-8.
shell_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
# Longueur en octets : les accents comptent double en UTF-8 et ${#var} suit la locale — toutes les mesures sont en octets.
byte_len() { printf '%s' "$1" | wc -c | tr -d ' '; }
