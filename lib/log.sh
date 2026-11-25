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
# die_wrap : un refus lu par une personne seulement (jamais relu par un programme), coupé aux espaces à la largeur du terminal
# comme warn_wrap ; sans terminal ni COLUMNS, la ligne unique de die (lot 02 de charge-processeur : couloir inconnu à 40 colonnes)
die_wrap() {
  if { [ -t 2 ] || [ -n "${COLUMNS:-}" ]; } && declare -F onboard_wrap >/dev/null; then
    printf '%s%s\n' "$DIE_PREFIX" "$*" | onboard_wrap "$(onboard_cols)" >&2
    [ -z "${DIE_HOOK:-}" ] || { local h="$DIE_HOOK"; DIE_HOOK=""; "$h" "$*" 2>/dev/null || true; }
    exit 1
  fi
  die "$*"
}
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
  # veilleur de PR (lot 05 de charge-processeur) : gh borné par ses FIFO, sans programme de garde ; sortie rendue ligne à ligne
  if [ "$1" = gh ] && [ "${WITH_TIMEOUT_STDIN:-0}" != 1 ] && gh_piped; then shift; gh_bounded "$secs" print - "$@"; return; fi
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
# ---------- pauses et gh sans programme, dans le veilleur de PR (lot 05 de charge-processeur) ----------
# Le veilleur ouvre deux FIFO à lui (watch_fifos_open) : LAB_TICK_FD, ouverte en lecture et écriture, où rien n'arrive jamais —
# read -t y attend sans processus, et un TERM l'interrompt aussitôt ; LAB_GH_PIPE, où gh seul écrit, lue jusqu'à sa fin. Hors du
# veilleur, rien de cela : sleep, timeout et substitutions comme avant.
# lab_pause <secondes> : attente sans processus quand la FIFO de pause est ouverte (secondes entières), sinon sleep
lab_pause() {
  case "$1" in ''|*[!0-9]*|0) sleep "$1"; return ;; esac
  if [ -n "${LAB_TICK_FD:-}" ]; then read -r -t "$1" -u "$LAB_TICK_FD" _ || true; else sleep "$1"; fi
}
gh_piped() { [ -n "${LAB_GH_PIPE:-}" ] && [ -n "${LAB_TICK_FD:-}" ] && [ -p "$LAB_GH_PIPE" ]; }
# gh_bounded <secondes> <keep|print|all> <dossier|-> <arguments de gh…> : gh lancé dans <dossier> (cd fait par le fils, qui devient
# gh : aucun processus de plus), sa sortie lue par la FIFO jusqu'à sa fin ou au délai — keep : dans GH_OUT, octet pour octet ;
# print : ligne à ligne sur la sortie (rien d'accumulé : --watch écrit pendant des heures) ; all : comme keep, erreurs de gh
# comprises, dans l'ordre où il les écrit. rc de gh (1 si cd échoue) ; 124 au délai dépassé, gh tué (TERM, KILL une seconde plus
# tard). gh ne laisse aucun descendant qui garderait la FIFO ouverte ; git, qui en laisse (maintenance détachée), garde timeout.
gh_bounded() {
  local secs="$1" mode="$2" dir="$3" pid line end left rc=0; shift 3
  GH_OUT=''
  if [ "$mode" = all ]; then { [ "$dir" = - ] || cd "$dir" || exit 1; exec gh "$@"; } >"$LAB_GH_PIPE" 2>&1 & pid=$!
  else { [ "$dir" = - ] || cd "$dir" || exit 1; exec gh "$@"; } >"$LAB_GH_PIPE" & pid=$!; fi
  exec 7<"$LAB_GH_PIPE"   # rendez-vous : gh ouvre la FIFO en écriture, le veilleur en lecture
  end=$((SECONDS + secs))
  while left=$((end - SECONDS)); [ "$left" -gt 0 ] && IFS= read -r -t "$left" -u 7 line; do
    if [ "$mode" = print ]; then printf '%s\n' "$line"; else GH_OUT="$GH_OUT$line"$'\n'; fi
    line=''
  done
  if [ "$mode" = print ]; then [ -z "$line" ] || printf '%s' "$line"; else GH_OUT="$GH_OUT$line"; fi
  exec 7<&-
  if [ "$SECONDS" -ge "$end" ]; then
    # délai atteint : une FIFO neuve pour l'appel suivant — un fils de gh encore vivant garderait l'ancienne ouverte en écriture, et
    # la lecture suivante attendrait sa fin (revue du lot 05) ; mkfifo refusé : gh_piped faux, repli sur with_timeout
    rm -f "$LAB_GH_PIPE"; mkfifo "$LAB_GH_PIPE" 2>/dev/null || true
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true; read -r -t 1 -u "$LAB_TICK_FD" _ || true; kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || rc=$?
      # tué au délai → 124 ; fini dans la seconde même du délai (sa fin de sortie lue, pas encore ramassé) → son propre code
      case "$rc" in 137|143) return 124 ;; esac
      return "$rc"
    fi
  fi
  wait "$pid" || rc=$?
  return "$rc"
}
# gh_read <secondes> <arguments de gh…> : GH_OUT, la sortie de gh bornée par le délai, fins de ligne finales retirées comme par une
# substitution ; rc de gh (124 au délai). gh_read_all : erreurs de gh comprises (2>&1) ; gh_read_in <dossier> : gh lancé dans ce
# dossier, comme (cd <dossier> && with_timeout …). Dans le veilleur, sans sous-shell ni programme de garde ; ailleurs, with_timeout
# dans une substitution, comme avant
gh_read() { gh_read_mode keep - "$@"; }
gh_read_all() { gh_read_mode all - "$@"; }
gh_read_in() { local d="$1"; shift; gh_read_mode keep "$d" "$@"; }
gh_read_mode() {
  local mode="$1" dir="$2" secs="$3" rc=0; shift 3
  if gh_piped; then
    gh_bounded "$secs" "$mode" "$dir" "$@" || rc=$?
    while [ "${GH_OUT%$'\n'}" != "$GH_OUT" ]; do GH_OUT="${GH_OUT%$'\n'}"; done
    return "$rc"
  fi
  if [ "$dir" != - ]; then GH_OUT="$(cd "$dir" && with_timeout "$secs" gh "$@")"
  elif [ "$mode" = all ]; then GH_OUT="$(with_timeout "$secs" gh "$@" 2>&1)"; else GH_OUT="$(with_timeout "$secs" gh "$@")"; fi
}
# Quote POSIX (simple quotes) : sûr pour bash et zsh, conserve l'UTF-8.
shell_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
# Longueur en octets : les accents comptent double en UTF-8 et ${#var} suit la locale — toutes les mesures sont en octets.
byte_len() { printf '%s' "$1" | wc -c | tr -d ' '; }
