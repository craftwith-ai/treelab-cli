# shellcheck shell=bash
# lock.sh — verrou de session par worktree : <wt>/.lab/session.lock (pid, agent, since).
declare -F kv_value >/dev/null || . "${BASH_SOURCE[0]%/*}/kv.sh"
declare -F snap_mark >/dev/null || . "${BASH_SOURCE[0]%/*}/snapshot.sh"   # instantané de Treelab.app (lot 03 d'app-treelab)
lock_file() { printf '%s/.lab/session.lock\n' "$1"; }
lock_field() { kv_print "$1" "$2"; }
# pid_state <pid> → vivant | mort | incertain. kill -0 seul ne prouve rien : sous sandbox il répond « Operation not permitted » sur un
# processus vivant d'un autre arbre, et lab status supprimait alors un verrou de session vivante (retour 4, 2026-09-14). Mort seulement
# si ps, exécuté sans erreur, ne trouve rien (rc 1, aucune sortie) ; ps refusé ou en erreur = incertain. Un pid absent ou non numérique
# n'a aucun processus à protéger : mort. Même règle pour _preflight_lock (lib/preflight.sh) : une seule définition.
pid_state() { pid_state_set "${1:-}"; printf '%s\n' "$PID_STATE"; }
pid_state_set() { # <pid> : PID_STATE, sans processus pour un pid vivant ; un ps sinon
  local pid="${1:-}" observed rc=0
  PID_STATE=dead
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 0
  if kill -0 "$pid" 2>/dev/null; then PID_STATE=alive; return 0; fi
  observed="$(ps -p "$pid" -o pid= 2>&1)" || rc=$?
  if [ "$rc" = 0 ] && [ -n "$observed" ]; then PID_STATE=alive   # visible sans droit de signal : sandbox
  elif [ "$rc" = 1 ] && [ -z "$observed" ]; then PID_STATE=dead
  else PID_STATE=uncertain; fi
}
pid_alive() { pid_state_set "${1:-}"; [ "$PID_STATE" = alive ]; }
pid_dead()  { pid_state_set "${1:-}"; [ "$PID_STATE" = dead ]; }
lock_alive() { kv_value "$1" pid || true; pid_alive "$KV_VALUE"; }   # comme pid_alive "$(lock_field …)", sans sous-shell
lock_dead()  { kv_value "$1" pid || true; pid_dead "$KV_VALUE"; }
# Remonte les ancêtres du processus courant jusqu'au binaire de l'agent ; sans agent trouvé, le pid de départ (toujours rc 0).
# shellcheck disable=SC2120 # [pid] : seuls les tests en passent un (tests/lock.bats)
agent_pid() { agent_pid_found "$@" || true; }
# agent_pid_found [pid] : même remontée, rc 1 sans agent parmi les ancêtres (le pid de départ est quand même écrit) — la garde ne
# prend un verrou que pour un vrai agent (lot 01 de reprise-apres-migration). Départ : le pid donné, sinon LAB_AGENT_FROM, posé dans
# son processus par le crochet de démarrage (session_main, lib/guard_fast.sh : lui-même, comme $PPID de « bin/lab hook » avant #239 —
# sans agent, le verrou revient au crochet mort, que SessionEnd retire ; lot 01 de fix-nuit-2026-11-24), sinon $PPID. Jamais hérité :
# l'environnement ne choisit pas le processus qu'un verrou désigne.
unset LAB_AGENT_FROM
agent_pid_found() {
  local from="${1:-${LAB_AGENT_FROM:-$PPID}}" pid comm seen=' '
  pid="$from"
  while [[ "$pid" =~ ^[1-9][0-9]*$ ]] && [ "$pid" != 1 ]; do
    # La profondeur dépend du lanceur ; une boucle ou un parent illisible
    # arrête la recherche sans attribuer le verrou à un autre processus.
    case "$seen" in *" $pid "*) break ;; esac
    seen="$seen$pid "
    comm="$(ps -o comm= -p "$pid" 2>/dev/null)" || comm=''
    case "${comm##*/}" in claude|codex|claude-code) printf '%s\n' "$pid"; return 0 ;; esac
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null)" || pid=''
    pid="${pid// /}"
  done
  printf '%s\n' "$from"
  return 1
}
# detect_agent [pid de l'agent] : le pid déjà trouvé évite une seconde remontée des ancêtres (claim, lot 01 de reprise-apres-migration)
detect_agent() {
  local comm; comm="$(ps -o comm= -p "${1:-$(agent_pid)}" 2>/dev/null)" || comm=''
  case "${comm##*/}" in claude*) echo claude ;; codex*) echo codex ;;
    *) if [ -n "${CLAUDE_PROJECT_DIR:-}${CLAUDE_CODE_ENTRYPOINT:-}" ]; then echo claude
       elif [ -n "${CODEX_HOME:-}${CODEX_SANDBOX:-}" ]; then echo codex; else echo unknown; fi ;;
  esac
}
# claim <wt> [agent] → CLAIMED | OCCUPIED | PENDING | UPDATING | UPDATE_PENDING | REGISTRY_FAILED. Ne pose aucune variable : appelé
# dans une substitution de commande, il ne le pourrait pas (lot 8 : un hook lisait $LOCK_AGENT après claim et mourait sous set -u) —
# l'appelant relit le verrou (lock_field).
# Relance en masse (lot 01 de reprise-apres-migration : cmux a rouvert 35 sessions d'un coup, 17 sont restées sans verrou, annoncées
# « update in progress ») : chaque claim exécutait ses ps sous le verrou commun à la machine, et la file dépassait LAB_OPERATION_WAIT.
# Les ps (agent, état du détenteur) se font donc avant ; sous le verrou ne restent que la relecture du verrou, le registre et le mv.
# Le perdant d'une contention entre sessions répond PENDING (la garde reprend le verrou au premier outil) ; UPDATING seulement si le
# détenteur n'est pas une session (vraie opération, ou lab d'avant ce lot qui ne note pas son type) ; registre refusé : REGISTRY_FAILED.
claim() {
  local wt="$1" agent="${2:-}" lock tmp pid held seen held_state='' since mask
  pid="$(agent_pid)"
  [ -n "$agent" ] || agent="$(detect_agent "$pid")"
  lock="$(lock_file "$wt")"; mkdir -p "$(dirname "$lock")"; chmod 700 "$(dirname "$lock")"
  seen="$(lock_field "$lock" pid || true)"
  if [ -n "$seen" ] && [ "$seen" != "$pid" ]; then held_state="$(pid_state "$seen")"; fi
  # sous le verrou commun, aucun processus lancé hormis shlock, mv et rm : registre contrôlé, date et masque pris avant. Avec une
  # quinzaine de processus par section critique, 25 sessions en PENDING dépassaient de nouveau l'attente au premier outil sous la
  # charge du CI Linux (partie 4 de la PR #196, reproduit en ralentissant chaque commande de 50 ms)
  since="$(date +%Y-%m-%dT%H:%M)"; mask="$(umask)"
  operation_paths || { printf 'UPDATING\n'; return 0; }
  operation_session_check "$pid" || { printf 'REGISTRY_FAILED\n'; return 0; }
  umask 077
  if ! operation_acquire session; then
    umask "$mask"
    if [ "${LAB_OPERATION_FAIL:-}" = busy ] && case "$(operation_holder_kind)" in session|none) true ;; *) false ;; esac; then
      printf 'PENDING\n'
    else printf 'UPDATING\n'; fi
    return 0
  fi
  if [ -e "$HOME/.lab/update-pending" ] || [ -L "$HOME/.lab/update-pending" ]; then
    operation_release; umask "$mask"; printf 'UPDATE_PENDING\n'; return 0
  fi
  lock_value "$lock" pid; held="$LOCK_VALUE"
  # le verrou a changé depuis la première lecture (rare : un autre démarrage du même couloir) : son état se relit sous le verrou
  if [ "$held" != "$seen" ]; then held_state=''; [ -z "$held" ] || [ "$held" = "$pid" ] || held_state="$(pid_state "$held")"; fi
  # seul un processus prouvé mort est repris ; un doute (ps refusé) vaut occupé — un verrou ne se perd jamais sur un doute (lot 02)
  if [ -n "$held" ] && [ "$held" != "$pid" ] && [ "$held_state" != dead ]; then operation_release; umask "$mask"; printf 'OCCUPIED\n'; return 0; fi
  if [ -L "$LAB_SESSION_DIRECTORY/$pid" ] || ! printf 'pid=%s\n' "$pid" 2>/dev/null >"$LAB_SESSION_DIRECTORY/$pid"; then
    operation_release; umask "$mask"; printf 'REGISTRY_FAILED\n'; return 0
  fi
  tmp="$lock.$$"; printf 'pid=%s\nagent=%s\nsince=%s\nworktree=%s\n' "$pid" "$agent" "$since" "$wt" >"$tmp"; mv "$tmp" "$lock"
  operation_release; umask "$mask"
  snap_mark "$wt"
  printf 'CLAIMED\n'
}

# shlock fait partie de macOS. Le lien atomique et sa reprise des PID morts
# sérialisent la pose d'un verrou de session avec toute mutation d'intégrations.
# Le verrou technique reste hors du compte ; son existence seule ne bloque pas.
operation_paths() {
  local key
  LAB_OPERATION_DIRECTORY="/private/tmp/treelab-operations-$(id -u)" || return
  key="$(cd "$HOME" && pwd -P)" || return
  key="$(printf '%s' "$key" | shasum -a 256 | cut -d ' ' -f 1)" || return
  LAB_OPERATION_FILE="$LAB_OPERATION_DIRECTORY/$key"
  LAB_SESSION_DIRECTORY="$LAB_OPERATION_FILE.sessions"
}
# operation_session_check <pid> : le registre des sessions est un vrai dossier, à l'utilisateur, mode 700 (créé s'il manque) ; claim
# le contrôle avant la section critique, puis n'y écrit que le fichier du pid. Une session hors du registre des projets protège
# aussi les intégrations.
operation_session_check() {
  local pid="$1" dir="$LAB_SESSION_DIRECTORY"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && [ ! -L "$dir" ] || return 1
  if [ ! -d "$dir" ]; then mkdir -m 700 "$dir" 2>/dev/null || [ -d "$dir" ] || return 1; fi
  [ "$(stat -f %u "$dir")" = "$(id -u)" ] && [ "$(stat -f %Lp "$dir")" = 700 ]
}
# lock_value <fichier> <clé> : LOCK_VALUE = première valeur « clé=… », lue sans aucun processus (section critique de claim)
lock_value() { kv_value "$1" "$2" 2>/dev/null || true; LOCK_VALUE="$KV_VALUE"; }
# Un verrou tenu par un processus vivant est réessayé LAB_OPERATION_WAIT secondes (2 par défaut, sous les 5 s d'un hook) : deux
# SessionStart simultanés le tiennent chacun une fraction de seconde, et le perdant annonçait à tort « mise à jour en cours » à sa
# session, qui refusait de travailler (essai réel du lot 12). Une vraie opération le tient bien plus longtemps : refus inchangé.
# operation_acquire [type] : type du détenteur (operation par défaut : setup, update, uninstall ; session pour claim), noté AVANT
# chaque tentative dans <verrou>.kind.<pid> — aucune fenêtre où le verrou est tenu sans type lisible. Échec : LAB_OPERATION_FAIL
# (busy : tenu par un vivant ; doubtful : dossier ou fichier douteux) et LAB_OPERATION_HOLDER (pid lu à la dernière tentative).
operation_acquire() {
  local dir file tries rc kind="${1:-operation}"
  LAB_OPERATION_FAIL=doubtful; LAB_OPERATION_HOLDER=''
  operation_paths || return
  dir="$LAB_OPERATION_DIRECTORY"; file="$LAB_OPERATION_FILE"
  [ "$kind" != notice ] || file="$file.notice"
  [ ! -L "$dir" ] || return 1
  if [ ! -d "$dir" ]; then (umask 077; mkdir "$dir") 2>/dev/null || [ -d "$dir" ] || return 1; fi
  [ "$(stat -f %u "$dir")" = "$(id -u)" ] && [ "$(stat -f %Lp "$dir")" = 700 ] || return 1
  [ "$kind" = notice ] || [ -L "$file.kind.$$" ] || (umask 077; printf '%s\n' "$kind" >"$file.kind.$$") 2>/dev/null || true
  tries=$(( ${LAB_OPERATION_WAIT:-2} * 10 ))
  while :; do
    rc=0; operation_try "$file" || rc=$?
    case "$rc" in
      0) LAB_OPERATION_LOCK="$file"; LAB_OPERATION_FAIL=''; return 0 ;;
      2) rm -f "$file.kind.$$"; return 1 ;;
    esac
    if [ "$tries" -le 0 ]; then
      LAB_OPERATION_FAIL=busy; LAB_OPERATION_HOLDER="$(cat "$file" 2>/dev/null || true)"
      rm -f "$file.kind.$$"; return 1
    fi
    tries=$((tries - 1)); sleep 0.1
  done
}
# operation_holder_kind → type noté par le détenteur LAB_OPERATION_HOLDER (session, operation…) ; vide : détenteur sans type (lab plus
# ancien) ; none : plus aucun détenteur. Le type est écrit avant la prise et retiré après le verrou : il existe tant que le verrou
# désigne ce pid — un type absent ne vaut « sans type » que si le verrou le désigne encore (sinon le détenteur a fini entre les
# deux lectures : le test des 35 démarrages répondait UPDATING sur cette fenêtre).
operation_holder_kind() {
  local h="${LAB_OPERATION_HOLDER:-}" f k=''
  [[ "$h" =~ ^[1-9][0-9]*$ ]] || { printf 'none\n'; return 0; }
  f="$LAB_OPERATION_FILE.kind.$h"
  if [ -f "$f" ] && [ ! -L "$f" ]; then k="$(head -1 "$f" 2>/dev/null || true)"; fi
  if [ -z "$k" ] && [ "$(cat "$LAB_OPERATION_FILE" 2>/dev/null || true)" != "$h" ]; then k=none; fi
  printf '%s\n' "$k"
}
# operation_try <fichier> : 0 pris ; 1 tenu par un processus vivant (réessayable) ; 2 fichier douteux (lien, autre propriétaire,
# contenu illisible) — jamais réessayé ni repris
operation_try() {
  local file="$1" pid owner
  [ ! -L "$file" ] || return 2
  if [ -e "$file" ]; then
    # le verrou peut être relâché entre chaque lecture : un fichier disparu se réessaie, seul un fichier présent et douteux refuse
    owner="$(stat -f %u "$file" 2>/dev/null)" || return 1
    pid="$(cat "$file" 2>/dev/null)" || return 1
    [ -e "$file" ] || return 1
    # un fichier qui disparaît entre deux tests a été relâché : réessayable, jamais douteux (relance en masse)
    [ -f "$file" ] && [ "$owner" = "$(id -u)" ] || { [ -e "$file" ] || return 1; return 2; }
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || { [ -e "$file" ] || return 1; return 2; }
    pid_dead "$pid" || return 1   # un verrou technique n'est repris que d'un processus prouvé mort (même règle que les sessions)
  fi
  (umask 077; /usr/bin/shlock -f "$file" -p "$$") 2>/dev/null || return 1
}
operation_release() {
  local h=''
  # lecture du pid sans processus : operation_release ferme la section critique de claim
  if [ -n "${LAB_OPERATION_LOCK:-}" ] && [ ! -L "$LAB_OPERATION_LOCK" ]; then { read -r h <"$LAB_OPERATION_LOCK"; } 2>/dev/null || true; fi
  if [ -n "$h" ] && [ "$h" = "$$" ]; then rm -f "$LAB_OPERATION_LOCK"; rm -f "$LAB_OPERATION_LOCK.kind.$$"; fi   # verrou d'abord, type ensuite
  LAB_OPERATION_LOCK=''
}
release() { local lock pid; lock="$(lock_file "$1")"; [ -f "$lock" ] || return 0
  pid="$(lock_field "$lock" pid)"
  if lock_dead "$lock" || [ "$pid" = "$(agent_pid)" ]; then
    rm -f "$lock"; snap_mark "$1"
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && operation_paths && [ ! -L "$LAB_SESSION_DIRECTORY" ]; then
      rm -f "$LAB_SESSION_DIRECTORY/$pid"
    fi
  fi; }
# lock_state <wt> → libre | vivant:<pid>:<agent>:<since> | mort:… | incertain:… — lecture pure, jamais d'écriture.
lock_state() { lock_state_set "$1"; printf '%s\n' "$LOCK_STATE"; }
lock_state_set() { # <wt> : LOCK_STATE
  local lock="$1/.lab/session.lock" pid agent
  [ -f "$lock" ] || { LOCK_STATE=free; return 0; }
  kv_value "$lock" pid || true; pid="$KV_VALUE"
  kv_value "$lock" agent || true; agent="$KV_VALUE"
  kv_value "$lock" since || true
  pid_state_set "$pid"; LOCK_STATE="$PID_STATE:$pid:$agent:$KV_VALUE"
}
# lock_status <wt> : lock_state, plus une note sur stderr. Ne supprime jamais rien : l'auto-réparation à la lecture (lot 10, 2026-09-03,
# pour un SessionEnd Codex qui ne relâchait pas) a coûté un verrou de session vivante sous sandbox (retour 4). Un verrou mort n'est
# retiré que par lock_reclaim, dans une commande qui écrit ; la reprise par le hook de démarrage (claim) couvre le cas de Codex.
lock_status() { lock_status_set "$1"; printf '%s\n' "$LOCK_STATE"; }
lock_status_set() { # <wt> : LOCK_STATE, la note sur stderr
  lock_state_set "$1"
  case "$LOCK_STATE" in
    dead:*) log "dead lock: $1 (${LOCK_STATE#dead:}) — kept by this read; lab next, launch or open will remove it" ;;
    uncertain:*) log "lock undeterminable from here: $1 (${LOCK_STATE#uncertain:}) — neither alive nor proven dead (sandbox?), kept" ;;
  esac
}
# lock_reclaim <wt> → libre | vivant:… | incertain:… : retire un verrou dont le processus est prouvé mort, avec une note. Réservé aux
# commandes qui ouvrent une session (next, launch, open) ; jamais à une lecture (status, plan, sweep, doctor).
lock_reclaim() {
  local st; st="$(lock_state "$1")"
  case "$st" in
    dead:*) log "dead lock removed: $1 (${st#dead:})"; rm -f "$(lock_file "$1")"; snap_mark "$1"; echo free ;;
    *) printf '%s\n' "$st" ;;
  esac
}
# lock_uncertain_message <wt> <état incertain:…> : le refus commun des commandes qui ouvrent une session
lock_uncertain_message() {
  printf 'session lock undeterminable in %s (%s): neither alive nor proven dead from here (sandbox?) — run again from a terminal outside the sandbox, or close that session if it is still alive; no lock removed\n' "$1" "${2#uncertain:}"
}

# ---------- passation (lot 10 de lab-enhancement) ----------
# cmux relance l'onglet ~0,1 s après l'ordre, la session remplacée meurt ~3 s plus tard (mesuré) : la session neuve lisait son
# verrou vivant et refusait. La session qui se fait remplacer pose donc une marque avant l'ordre ; la session neuve n'attend que
# ce pid-là, et seulement pendant LAB_HANDOFF_WAIT secondes comptées depuis l'ordre.
handoff_file() { printf '%s/.lab/handoff\n' "$1"; }
handoff_write() { # <wt> <pid remplacé> <workspace> <surface> <vu dans l'onglet 0|1> <ligne de reprise>
  local f tmp; f="$(handoff_file "$1")"; tmp="$f.$$"
  ( umask 077; printf 'pid=%s\nsince=%s\nworkspace=%s\nsurface=%s\nseen=%s\nline=%s\n' "$2" "$(date +%s)" "$3" "$4" "$5" "$6" >"$tmp" )
  mv "$tmp" "$f"
}
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000' 2>/dev/null || printf '%s000\n' "$(date +%s)"; }
# handoff_wait <wt> <pid du verrou> : 0 — la session remplacée a disparu, verrou et marque retirés (HANDOFF_WAITED_MS et
# HANDOFF_PROOF posés : appeler hors substitution) ; 1 — aucune passation en cours pour ce pid (autre session : refus immédiat) ;
# 2 — borne dépassée, verrou et marque conservés. Disparue = prouvée morte (pid_state), ou absente de son onglet à deux lectures
# de cmux qui concordent alors qu'elle y figurait avant l'ordre ; une lecture manquée remet le compte à zéro : un doute reste un doute.
# shellcheck disable=SC2034 # HANDOFF_WAITED_MS et HANDOFF_PROOF sont lus par handoff_or_refuse (bin/lab)
handoff_wait() {
  local wt="$1" held="$2" f pid since limit start deadline ws surface seen absent=0 pids
  f="$(handoff_file "$wt")"; [ -f "$f" ] || return 1
  pid="$(lock_field "$f" pid || true)"; [ -n "$pid" ] && [ "$pid" = "$held" ] || return 1
  since="$(lock_field "$f" since || true)"; limit="${LAB_HANDOFF_WAIT:-30}"
  [[ "$since" =~ ^[0-9]+$ ]] && [[ "$limit" =~ ^[0-9]+$ ]] || return 1
  [ $(($(date +%s) - since)) -le "$limit" ] || return 1   # marque périmée : plus aucune passation en cours
  ws="$(lock_field "$f" workspace || true)"; surface="$(lock_field "$f" surface || true)"; seen="$(lock_field "$f" seen || true)"
  start="$(now_ms)"; deadline=$((start + limit * 1000)); HANDOFF_PROOF=""
  while :; do
    if [ "$(pid_state "$pid")" = dead ]; then HANDOFF_PROOF="pid $pid dead"; break; fi
    if [ "$seen" = 1 ] && pids="$(cmux_surface_pids "$ws" "$surface")"; then
      if grep -qx "$pid" <<<"$pids"; then absent=0; else absent=$((absent + 1)); fi
      if [ "$absent" -ge 2 ]; then HANDOFF_PROOF="pid $pid missing from tab $surface on two reads"; break; fi
    else absent=0; fi
    HANDOFF_WAITED_MS=$(($(now_ms) - start))
    [ "$(now_ms)" -lt "$deadline" ] || return 2
    sleep 0.2
  done
  HANDOFF_WAITED_MS=$(($(now_ms) - start))
  # le verrou n'est retiré que s'il désigne encore la session remplacée ; la marque a servi
  [ "$(lock_field "$(lock_file "$wt")" pid || true)" != "$pid" ] || rm -f "$(lock_file "$wt")"
  rm -f "$f"
}

# session_owned_here <wt> : le verrou doit appartenir à ce processus ou à un
# de ses parents. Un PID vivant ailleurs ne donne jamais le droit de le remplacer.
session_owned_here() {
  local held pid parent
  kv_value "$1/.lab/session.lock" pid 2>/dev/null || return 1
  held="$KV_VALUE"; [ -n "$held" ] || return 1
  pid=$$
  while [ -n "$pid" ] && [ "$pid" != 1 ]; do
    [ "$pid" != "$held" ] || return 0
    # le parent direct est connu du shell : un ps de moins, et le cas ordinaire (l'agent lance le crochet) n'en coûte aucun
    if [ "$pid" = "$$" ]; then parent="$PPID"; else parent="$(ps -o ppid= -p "$pid" 2>/dev/null)" || parent=''; parent="${parent// /}"; fi
    [ "$parent" != "$pid" ] || break
    pid="$parent"
  done
  return 1
}
