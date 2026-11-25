# shellcheck shell=bash
# ressource.sh — vivre avec son projet (lot 18 de lab-enhancement) : ressources partagées entre couloirs (simulateur, base locale,
# port…) déclarées par le projet (resources=…) et tenues par lab lock ; build servie par le serveur de dev (lab served, appelé par
# scripts/dev.sh). État sous $LAB_STATE/<projet>/ : ressources/<nom> et servi/<couloir>, KEY=value. Aucun hook ne bloque : le
# contexte de démarrage nomme seulement détenteurs et build servie.

resource_dir() { printf '%s/%s/ressources\n' "$LAB_STATE" "$P_NAME"; }
served_dir() { printf '%s/%s/servi\n' "$LAB_STATE" "$P_NAME"; }
# resource_declared <nom> : le nom figure dans resources= de la config du projet (liste séparée par des espaces ou des virgules)
resource_declared() { case " $(printf '%s' "${P_RESOURCES:-}" | tr ',' ' ') " in *" $1 "*) return 0 ;; esac; return 1; }
# here_lane [dossier] → le couloir du dossier courant, « main-checkout » dans le checkout du projet, vide hors du projet
here_lane() {
  local r; r="$(repo_root "${1:-$PWD}" 2>/dev/null)" || return 0
  if same_path "$r" "$P_ROOT"; then printf 'main-checkout\n'
  elif [ "$(main_root "$r" 2>/dev/null)" = "$(main_root "$P_ROOT" 2>/dev/null)" ]; then wt_lane "$r"; fi
}
epoch_now() { date -u +%s; }
# age_of <epoch> → « 12 min », « 3 h », « 2 j » (« à l'instant » sous une minute ; vide si illisible)
age_of() {
  local s; [[ "${1:-}" =~ ^[0-9]+$ ]] || return 0
  s=$(( $(epoch_now) - $1 )); [ "$s" -ge 0 ] || s=0
  if [ "$s" -lt 60 ]; then printf "just now\n"
  elif [ "$s" -lt 3600 ]; then printf '%d min\n' $((s / 60))
  elif [ "$s" -lt 86400 ]; then printf '%d h\n' $((s / 3600))
  else printf '%d d\n' $((s / 86400)); fi
}
state_field() { if kv_value "$1" "$2"; then printf '%s\n' "$KV_VALUE"; fi; }
# state_write <fichier> <contenu> : écriture atomique, mode 600 ; le temporaire est caché (.tmp.*) : le glob * des lectures ne le voit
# jamais, et aucun nom de ressource ou de couloir n'est filtré par erreur (revue du lot 18)
state_write() { local tmp; mkdir -p "$(dirname "$1")"; tmp="$(mktemp "$(dirname "$1")/.tmp.XXXXXX")"; printf '%s' "$2" >"$tmp"; chmod 600 "$tmp"; mv "$tmp" "$1"; }

# ---------- lab lock / lab unlock ----------
# resource_take <nom> <couloir> <pid> : pose RES_ACTION (taken | taken-over | already), RES_PREV (détenteur précédent) ; rc 1 si un autre
# couloir la tient avec un processus vivant ou incertain (RES_PREV le nomme) — un doute ne libère jamais une ressource (même règle que
# le verrou de session, lot 02) ; rc 2 si l'état est inaccessible. Lecture, décision et écriture se font sous un verrou shlock du
# dossier (.verrou) : deux couloirs qui prennent ou reprennent en même temps, un seul gagne (revue du lot 18).
# [dossier] remplace resource_dir ; [strict] = 1 refuse aussi le même couloir tenu par un autre processus vivant (verrou de mise en
# ligne, lot 01 de mise-en-ligne : deux lab deploy d'un même couloir ne se croisent pas plus que deux couloirs).
resource_take() {
  local name="$1" lane="$2" pid="$3" dir="${4:-}" strict="${5:-0}" f held hlane rc=0 i
  RES_ACTION=taken; RES_PREV=""; dir="${dir:-$(resource_dir)}"; f="$dir/$name"
  mkdir -p "$dir" 2>/dev/null || return 2
  for i in $(seq 1 50); do (umask 077; /usr/bin/shlock -f "$dir/.verrou" -p "$$") 2>/dev/null && break; [ "$i" != 50 ] || return 2; sleep 0.1; done
  if [ -f "$f" ]; then
    held="$(state_field "$f" pid)"; hlane="$(lang_code "$(state_field "$f" lane)")"   # « hors-couloir » : verrou d'un lab d'avant le lot 09
    RES_PREV="$hlane (pid $held since $(state_field "$f" since))"
    if [ "$hlane" = "$lane" ] && { [ "$strict" != 1 ] || [ "$held" = "$pid" ] || [ "$(pid_state "$held")" = dead ]; }; then RES_ACTION=already
    elif [ "$(pid_state "$held")" != dead ]; then rc=1
    else RES_ACTION=taken-over; fi
  fi
  if [ "$rc" = 0 ]; then
    state_write "$f" "$(printf 'lane=%s\npid=%s\nsince=%s\nepoch=%s\n' "$lane" "$pid" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(epoch_now)")"$'\n' || rc=2
  fi
  rm -f "$dir/.verrou"
  return "$rc"
}
cmd_lock() {
  local pid="" name lane rc=0; local -a pos=()
  while [ "$#" -gt 0 ]; do case "$1" in --pid) pid="$2"; shift 2 ;; -*) usage ;; *) pos+=("$1"); shift ;; esac; done
  resource_args "${pos[@]+"${pos[@]}"}"; name="$RES_NAME"; lane="$(here_lane)"; lane="${lane:-outside-lane}"
  pid="${pid:-$(agent_pid)}"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || die "unreadable pid: $pid"
  kv PROJECT "$P_NAME"; kv RESOURCE "$name"
  resource_take "$name" "$lane" "$pid" || rc=$?
  [ "$rc" != 2 ] || die "state of resource $name not writable: $(resource_dir)"
  if [ "$rc" = 1 ]; then
    die "resource $name held by lane $RES_PREV, live process: wait for its release (lab unlock $P_NAME $name, run from its lane) — nothing taken"
  fi
  kv ACTION "$RES_ACTION"; kv LANE "$lane"; kv PID "$pid"
  [ "$RES_ACTION" != taken-over ] || log "resource $name taken over: the previous holder $RES_PREV is dead"
}
cmd_unlock() {
  local name lane f hlane; local -a pos=()
  while [ "$#" -gt 0 ]; do case "$1" in -*) usage ;; *) pos+=("$1"); shift ;; esac; done
  resource_args "${pos[@]+"${pos[@]}"}"; name="$RES_NAME"; lane="$(here_lane)"; lane="${lane:-outside-lane}"
  f="$(resource_dir)/$name"; kv PROJECT "$P_NAME"; kv RESOURCE "$name"
  [ -f "$f" ] || { kv ACTION free; return 0; }
  hlane="$(lang_code "$(state_field "$f" lane)")"
  if [ "$hlane" != "$lane" ] && [ "$(pid_state "$(state_field "$f" pid)")" != dead ]; then
    die "resource $name held by lane $hlane (pid $(state_field "$f" pid)), not by $lane: only its holder releases it — nothing released"
  fi
  rm -f "$f"; kv ACTION released; kv LANE "$hlane"
}
# resource_args [projet] <ressource> : pose RES_NAME, charge le projet ; ressource non déclarée → refus nommé
resource_args() {
  local p=""
  case "$#" in 1) RES_NAME="$1" ;; 2) p="$1"; RES_NAME="$2" ;; *) usage ;; esac
  load_project "$(resolve_project "$p")"
  resource_declared "$RES_NAME" || die "undeclared resource: $RES_NAME — declared for $P_NAME: ${P_RESOURCES:-none} (resources= key of $(project_dir "$P_NAME")/config)"
}
# resource_hook_line → « RESOURCES=sim: held by alpha (pid 12, 3 h) ; base: releasable (beta, dead process …). » ou rien
resource_hook_line() {
  local f name lane out="" item
  for f in "$(resource_dir)"/*; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"; lane="$(state_field "$f" lane)"
    if [ "$(pid_state "$(state_field "$f" pid)")" = dead ]; then item="$name: releasable ($lane, dead process — lab lock $P_NAME $name takes it over)"
    else item="$name: held by $lane (pid $(state_field "$f" pid), $(age_of "$(state_field "$f" epoch)"))"; fi
    out="${out:+$out ; }$item"
  done
  [ -z "$out" ] || printf 'RESOURCES=%s.\n' "$out"
}

# ---------- build servie ----------
# cmd_served <port> [--pid <pid>] : appelé par scripts/dev.sh du projet (gabarit) avant d'exécuter le serveur — enregistre couloir,
# révision, port et pid ; le pid par défaut est celui du parent (le dev.sh qui exécute ensuite le serveur par exec)
cmd_served() {
  local port="" pid="" lane rev root; local -a pos=()
  while [ "$#" -gt 0 ]; do case "$1" in --pid) pid="$2"; shift 2 ;; -*) usage ;; *) pos+=("$1"); shift ;; esac; done
  [ "${#pos[@]}" -ge 1 ] || usage; port="${pos[0]}"
  [[ "$port" =~ ^[0-9]+$ ]] || die "unreadable port: $port"
  pid="${pid:-$PPID}"; [[ "$pid" =~ ^[1-9][0-9]*$ ]] || die "unreadable pid: $pid"
  load_project "$(resolve_project "")"
  root="$(repo_root)" || die "not in a repository"; lane="$(here_lane "$root")"; rev="$(git -C "$root" rev-parse HEAD)"
  state_write "$(served_dir)/$lane" "$(printf 'lane=%s\nroot=%s\nrev=%s\nport=%s\npid=%s\nepoch=%s\n' "$lane" "$root" "$rev" "$port" "$pid" "$(epoch_now)")"$'\n'
  kv PROJECT "$P_NAME"; kv LANE "$lane"; kv REV "$rev"; kv PORT "$port"; kv PID "$pid"
}
# served_hook_line → « DEV_SERVER=alpha @ 1a2b3c4 on :3000 ; beta @ 5d6e7f8 on :3001 (stale: HEAD 9a8b7c6). » ; processus mort : rien
served_hook_line() {
  local f rev head root out="" item
  for f in "$(served_dir)"/*; do
    [ -f "$f" ] || continue
    pid_alive "$(state_field "$f" pid)" || continue
    rev="$(state_field "$f" rev)"; root="$(state_field "$f" root)"
    head="$(git -C "$root" rev-parse HEAD 2>/dev/null || true)"
    item="$(state_field "$f" lane) @ ${rev:0:7} on :$(state_field "$f" port)"
    [ -z "$head" ] || [ "$head" = "$rev" ] || item="$item (stale: HEAD ${head:0:7})"
    out="${out:+$out ; }$item"
  done
  [ -z "$out" ] || printf 'DEV_SERVER=%s.\n' "$out"
}
