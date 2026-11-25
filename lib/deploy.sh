# shellcheck shell=bash
# deploy.sh — mise en ligne garantie (lot 01 de mise-en-ligne) : une cible déclarée par le projet (deploy.<cible>=, probe.<cible>=)
# part toujours d'un commit propre — origin/<base>, ou un assemblage base + couloirs déclarés poussé sur serve/<cible> — et jamais
# de l'arbre d'une seule branche. Registre $LAB_STATE/<projet>/en-ligne/<cible> (KEY=value) : un couloir servi, ni fusionné, ni
# repris par --with, ni --retire, refuse la mise en ligne qui l'effacerait. Verrou de cible : en-ligne/verrous/<cible>.

deploy_dir() { printf '%s/%s/en-ligne\n' "$LAB_STATE" "$P_NAME"; }
# deploy_cfg <deploy|probe> <cible> → la commande déclarée (préfixe littéral, aucun motif : une cible peut porter un point)
deploy_cfg() { awk -v k="$1.$2=" 'index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$(project_dir "$P_NAME")/config"; }
deploy_targets() { local t; t="$(sed -n 's/^deploy\.\([^=]*\)=.*/\1/p' "$(project_dir "$P_NAME")/config" | paste -sd' ' -)"; printf '%s\n' "${t:-none}"; }
in_words() { local x="$1" w; shift; for w in "$@"; do [ "$w" != "$x" ] || return 0; done; return 1; }
words_or() { if [ "$#" -gt 0 ]; then printf '%s\n' "$*"; else printf 'none\n'; fi; }
# deploy_head_merged <tête> <branche> : la tête servie est dans la base — PR fusionnée (gh), ascendance ou squash (branch_merged,
# patch-id) de la tête servie, ou de la tête actuelle de la branche quand elle la contient (commit poussé après la mise en ligne,
# puis squash de l'ensemble : revue du lot 01)
# [base] : une autre base que P_BASE (staging, à sa promotion)
deploy_head_merged() {
  local c mb base="${3:-$P_BASE}"
  if [ -n "$2" ] && pr_merged_via_gh "$P_ROOT" "$2"; then MERGED_BY="pr-merged"; return 0; fi
  git -C "$P_ROOT" cat-file -e "$1^{commit}" 2>/dev/null || return 1
  for c in "$1" "$(git -C "$P_ROOT" rev-parse -q --verify "refs/remotes/$P_REMOTE/$2" 2>/dev/null || true)" \
      "$(git -C "$P_ROOT" rev-parse -q --verify "refs/heads/$2" 2>/dev/null || true)"; do
    [ -n "$c" ] || continue
    git -C "$P_ROOT" merge-base --is-ancestor "$1" "$c" 2>/dev/null || continue
    mb="$(git -C "$P_ROOT" merge-base "$c" "$P_REMOTE/$base" 2>/dev/null)" || continue
    branch_merged "$P_ROOT" "$c" "$base" "" "$mb" && return 0
  done
  return 1
}
# deploy_lost <registre> [couloir exclu…] → « couloir<TAB>branche<TAB>tête<TAB>PR » (- si vide) par couloir servi, ni exclu (repris
# ou retiré), ni fusionné : annoté merged= par une fusion de lab (lot 02), ou reconnu par deploy_head_merged
deploy_lost() {
  local reg="$1" i lane; local -a l=() b=() h=() p=() m=(); shift
  read -r -a l <<<"$(state_field "$reg" lanes)" || true
  read -r -a b <<<"$(state_field "$reg" branches)" || true
  read -r -a h <<<"$(state_field "$reg" heads)" || true
  read -r -a p <<<"$(state_field "$reg" prs)" || true
  read -r -a m <<<"$(state_field "$reg" merged)" || true
  for i in "${!l[@]}"; do
    lane="${l[$i]}"
    if in_words "$lane" "$@"; then continue
    elif in_words "$lane" "${m[@]+"${m[@]}"}"; then log "lane $lane merged (registry annotated by lab): now served by $P_BASE"
    elif deploy_head_merged "${h[$i]:-}" "${b[$i]:-}"; then log "lane $lane merged ($MERGED_BY): now served by $P_BASE"
    else printf '%s\t%s\t%s\t%s\n' "$lane" "${b[$i]:--}" "${h[$i]:--}" "${p[$i]:--}"; fi
  done
}

# ---------- ce qui est en ligne (lot 02) : registre seul — ni git, ni gh, ni réseau : lu au démarrage, par status et next ----------
deploy_registries() { local f; for f in "$(deploy_dir)"/*; do [ -f "$f" ] && basename "$f"; done; return 0; }
# deploy_summary <cible> → « main@1a2b3c4 + #49 (api, not-merged) » ; fusionné → « (api, merged: lab deploy <cible>) »
deploy_summary() { deploy_summary_set "$1" || return; printf '%s\n' "$DEPLOY_SUMMARY"; }
deploy_summary_set() { # <cible> : DEPLOY_SUMMARY, sans processus ; rc 1 sans registre
  local reg="$LAB_STATE/$P_NAME/en-ligne/$1" i out st; local -a l=() p=() m=()
  [ -f "$reg" ] || return 1
  kv_value "$reg" lanes || true; read -r -a l <<<"$KV_VALUE" || true
  kv_value "$reg" prs || true; read -r -a p <<<"$KV_VALUE" || true
  kv_value "$reg" merged || true; read -r -a m <<<"$KV_VALUE" || true
  kv_value "$reg" base || true; out="$KV_VALUE"; kv_value "$reg" base_rev || true; out="$out@${KV_VALUE:0:7}"
  for i in "${!l[@]}"; do
    if in_words "${l[$i]}" "${m[@]+"${m[@]}"}"; then st="merged: lab deploy $1"; else st=not-merged; fi
    case "${p[$i]:--}" in -) out="$out + ${l[$i]} ($st)" ;; *) out="$out + ${p[$i]} (${l[$i]}, $st)" ;; esac
  done
  prod_check_set "$reg"; DEPLOY_SUMMARY="$out$PROD_CHECK"
}
# ---------- contrôle de prod (lot 08 d'autonomie-tours) ----------
# prod_check.<cible>= (config du projet, écrite à la main) : commande en lecture seule qui dit si la prod marche, lancée par lab
# deploy après la sonde vérifiée et par lab deploy <cible> --check ; résultat dans le registre : check_rc= check_rev= (révision
# servie contrôlée) check_epoch= (cloud_epoch, suit LAB_NOW) check_log=. Rouge : couloirs servis bloqués, aucun retour arrière.
prod_check_summary() { prod_check_set "$1"; printf '%s' "$PROD_CHECK"; } # <registre> → « , check green at 1a2b3c4 » ; rien sans contrôle enregistré
prod_check_set() { # <registre> : PROD_CHECK, sans processus
  local rc
  PROD_CHECK=''
  kv_value "$1" check_rc || true; rc="$KV_VALUE"; [ -n "$rc" ] || return 0
  kv_value "$1" check_rev || true
  case "$rc" in 0) PROD_CHECK=", check green at ${KV_VALUE:0:7}" ;; 124) PROD_CHECK=", check red at ${KV_VALUE:0:7} (timeout)" ;;
    *) PROD_CHECK=", check red at ${KV_VALUE:0:7} (rc $rc)" ;; esac
}
# prod_check_run <cible> <révision> : sous le verrou de la cible tenu par l'appelant ; lancée depuis le checkout principal, sous délai
# (LAB_PROD_CHECK_TIMEOUT, 300 s), avec LAB_DEPLOY_TARGET et LAB_DEPLOY_REV ; journal en-ligne/checks/<cible>-<UTC>-<pid>.log. Pose
# PC_STATE (green | red | none : clé absente), PC_RC, PC_LOG, PC_WHY (rouge : rc ou « timeout », sans la sortie du contrôle — texte venu
# de la prod, jamais recopié dans un motif que lit la tour ; elle reste dans le journal, mode 600 comme le registre).
prod_check_run() {
  local target="$1" rev="$2" reg cmd lane wt limit="${LAB_PROD_CHECK_TIMEOUT:-300}"; local -a l=()
  PC_STATE=none; PC_RC=""; PC_LOG=""; PC_WHY=""
  cmd="$(deploy_cfg prod_check "$target")"; [ -n "$cmd" ] || return 0
  reg="$(deploy_dir)/$target"; PC_RC=0
  PC_LOG="$(deploy_dir)/checks/$target-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
  ( umask 077; mkdir -p "$(dirname "$PC_LOG")" && : >"$PC_LOG" ) || die "prod check log not writable: $PC_LOG"
  (cd "$P_ROOT" && LAB_DEPLOY_TARGET="$target" LAB_DEPLOY_REV="$rev" with_timeout "$limit" bash -c "$cmd") </dev/null >>"$PC_LOG" 2>&1 || PC_RC=$?
  state_write "$reg" "$(grep -v '^check_' "$reg")"$'\n'"$(printf 'check_rc=%s\ncheck_rev=%s\ncheck_epoch=%s\ncheck_log=%s' "$PC_RC" "$rev" "$(cloud_epoch)" "$PC_LOG")"$'\n'
  read -r -a l <<<"$(state_field "$reg" lanes)" || true
  if [ "$PC_RC" = 0 ]; then
    PC_STATE=green
    for lane in "${l[@]+"${l[@]}"}"; do   # un rouge de ce contrôle levé : l'entrée bloquée qu'il avait posée s'efface
      wt="$(worktree_path "$lane")"; [ -d "$wt" ] || continue
      case "$(waits_get "$wt" kind):$(waits_get "$wt" why)" in "blocked:prod check of $target "*) waits_clear "$wt" ;; esac
    done
    return 0
  fi
  PC_STATE=red
  if [ "$PC_RC" = 124 ]; then PC_WHY="prod check of $target red at ${rev:0:7}: timeout after $limit s"
  else PC_WHY="prod check of $target red at ${rev:0:7}: rc $PC_RC"; fi
  for lane in "${l[@]+"${l[@]}"}"; do wt="$(worktree_path "$lane")"; [ ! -d "$wt" ] || tower_signal "$wt" blocked "$PC_WHY"; done
  # la tour est prévenue dans son onglet, même quand la cible ne sert que la base
  ! deploy_tower_project || { wt="$(worktree_path "$TOWER_LANE")"; cmux_notify "$P_NAME · $TOWER_LANE" "$PC_WHY" "$(wt_ws "$wt")" "$(wt_surface "$wt")"; }
}
prod_check_kv() { kv PROD_CHECK "$PC_STATE"; [ -z "$PC_RC" ] || kv PROD_CHECK_RC "$PC_RC"; [ -z "$PC_LOG" ] || kv PROD_CHECK_LOG "$PC_LOG"; }
# deploy_check <cible> : lab deploy <cible> --check — relance le contrôle sur la révision servie du registre, sous le verrou de la
# cible ; rien n'est assemblé ni mis en ligne. Permis à l'agent d'un couloir : il ne déploie rien.
deploy_check() {
  local target="$1" reg rev rc=0
  reg="$(deploy_dir)/$target"
  [ -f "$reg" ] || die "nothing recorded on $target: no registry ($reg) — lab deploy $target first; nothing checked"
  [ -n "$(deploy_cfg prod_check "$target")" ] \
    || die "no prod check for $target: write prod_check.$target=<read-only command> by hand in $(project_dir "$P_NAME")/config (lab-cli skill); nothing checked"
  rev="$(state_field "$reg" rev)"
  resource_take "$target" prod-check "$$" "$(deploy_dir)/verrous" 1 || rc=$?
  [ "$rc" = 0 ] || die "go-live of $target running (lane $RES_PREV): retry when it has finished; nothing checked"
  D_LOCK="$(deploy_dir)/verrous/$target"; D_TMP=""; trap deploy_cleanup EXIT; trap 'exit 130' INT TERM HUP
  prod_check_run "$target" "$rev"
  kv PROJECT "$P_NAME"; kv TARGET "$target"; kv ACTION checked; kv REV "$rev"; prod_check_kv
  [ "$PC_STATE" != red ] || die "$PC_WHY — output in $PC_LOG; nothing deployed, lanes served by $target are blocked"
  log_wrap "prod check of $target green at ${rev:0:7}: nothing deployed."
}
# deploy_serving <couloir> → les cibles qui servent ce couloir sans fusion annotée
deploy_serving() {
  local t; local -a l=() m=()
  for t in $(deploy_registries); do
    read -r -a l <<<"$(state_field "$(deploy_dir)/$t" lanes)" || true
    read -r -a m <<<"$(state_field "$(deploy_dir)/$t" merged)" || true
    in_words "$1" "${l[@]+"${l[@]}"}" && ! in_words "$1" "${m[@]+"${m[@]}"}" && printf '%s\n' "$t"
  done
  return 0
}
# en_ligne_line → « SERVED=prod : main@1a2b3c4 + #49 (api, not-merged) ; site : main@… » ; aucun registre : rien
en_ligne_line() {
  local t out=""
  for t in $(deploy_registries); do out="${out:+$out ; }$t : $(deploy_summary "$t")"; done
  [ -z "$out" ] || printf 'SERVED=%s.\n' "$out"
}
# deploy_status_kv : une ligne SERVED=<cible> <résumé> par registre (lab status)
deploy_status_kv() {
  local f
  for f in "$LAB_STATE/$P_NAME/en-ligne"/*; do [ -f "$f" ] || continue; deploy_summary_set "${f##*/}"; kv SERVED "${f##*/} $DEPLOY_SUMMARY"; done
}
# deploy_lane_warn <couloir> : lab next d'un couloir servi non fusionné rappelle que seule lab deploy met en ligne
deploy_lane_warn() {
  local t
  for t in $(deploy_serving "$1"); do
    warn "lane $1 is live on $t ($(deploy_summary "$t")): going live without it would erase it — use lab deploy $t"
  done
  return 0
}
# deploy_note_merged <branche> [base] : après une fusion confirmée dans la base de mise en ligne, annote merged= les couloirs servis
# par cette branche — rien déployé ; la cible sert encore l'ancienne révision jusqu'à lab deploy <cible>. Promotion de staging dans
# la base : tout couloir servi déjà fusionné dans staging y entre avec elle (revue). Sous le verrou de la cible : une mise en ligne
# en cours réécrit le registre, l'annotation est alors remise à plus tard. Jamais bloquant.
deploy_note_merged() {
  [ -n "${1:-}" ] && [ "${2:-$P_BASE}" = "$P_BASE" ] || return 0
  local t reg i m changed promo=0 lock rc dir="$LAB_STATE/$P_NAME/en-ligne"; local -a l=() b=() h=() mm=()
  [ -z "${P_STAGING:-}" ] || [ "$1" != "$P_STAGING" ] || promo=1
  for reg in "$dir"/*; do   # deploy_registries, sans substitution (lot 05 de charge-processeur)
    [ -f "$reg" ] || continue; t="${reg##*/}"
    lock="$dir/verrous/$t"; changed=0; rc=0
    resource_take "$t" annotation "$$" "$dir/verrous" 1 || rc=$?
    [ "$rc" = 0 ] || { warn "annotation of $t postponed: a go-live is running (it rewrites the registry)"; continue; }
    read -r -a l <<<"$(state_field "$reg" lanes)" || true
    read -r -a b <<<"$(state_field "$reg" branches)" || true
    read -r -a h <<<"$(state_field "$reg" heads)" || true
    m="$(state_field "$reg" merged)"; read -r -a mm <<<"$m" || true
    for i in "${!l[@]}"; do
      in_words "${l[$i]}" "${mm[@]+"${mm[@]}"}" && continue
      if [ "${b[$i]:-}" = "$1" ] || { [ "$promo" = 1 ] && deploy_head_merged "${h[$i]:-}" "${b[$i]:-}" "$P_STAGING"; }; then
        m="${m:+$m }${l[$i]}"; changed=1
      fi
    done
    if [ "$changed" = 1 ] && state_write "$reg" "$(grep -v '^merged=' "$reg")"$'\n'"merged=$m"$'\n'; then
      log "$t: $m now in $P_BASE ($1) — registry annotated, nothing deployed; lab deploy $t updates the target"
    fi
    [ "$(state_field "$lock" pid)" != "$$" ] || rm -f "$lock"
  done
  return 0
}
# ---------- file de prod (lot 05 d'autonomie-tours) ----------
# $LAB_STATE/<projet>/en-ligne/file/<cible> : une ligne par demande, dans l'ordre d'arrivée, champs séparés par une tabulation, « - »
# pour un champ vide (read fusionne deux tabulations) : couloir, epoch d'inscription (cloud_epoch, suit LAB_NOW), révision inscrite,
# --with et --retire d'origine (séparés par des virgules), pid (« - » : demande vidée par la tour ; sinon l'attente hors tour de ce
# processus), cause d'arrêt (« - » : file en marche). Verrou mkdir sur le modèle de cloud_queue_locked ; un couloir disparu et une
# attente au pid mort sortent de la file à la lecture.
deploy_queue_file() { printf '%s/file/%s\n' "$(deploy_dir)" "$1"; }
deploy_queue_targets() { local f; for f in "$(deploy_dir)"/file/*; do [ -f "$f" ] && basename "$f"; done; return 0; }
deploy_queue_max() { printf '%s\n' "${LAB_DEPLOY_WAIT_MAX:-1800}"; }
deploy_queue_locked() { # <cible> <commande…>
  local d n=0 rc=0; d="$(deploy_queue_file "$1").lock"; mkdir -p "$(dirname "$d")"
  until mkdir "$d" 2>/dev/null; do
    n=$((n + 1))
    if [ "$n" -ge 50 ] || cloud_lock_stale "$d" "$n" 20; then cloud_lock_drop "$d"; n=0; continue; fi
    sleep 0.1
  done
  printf '%s\n' "$$" >"$d/pid"
  shift; "$@" || rc=$?
  cloud_lock_drop "$d"; return "$rc"
}
deploy_queue_lines() { # <cible> → demandes vivantes
  local f l e r w x p c; f="$(deploy_queue_file "$1")"; [ -f "$f" ] || return 0
  while IFS=$'\t' read -r l e r w x p c; do
    [ -n "$l" ] || continue
    [ "$l" = outside-lane ] || [ -d "$(worktree_path "$l")" ] || continue
    [ "${p:--}" = - ] || ! pid_dead "$p" || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$l" "${e:--}" "${r:--}" "${w:--}" "${x:--}" "${p:--}" "${c:--}"
  done <"$f"
}
deploy_queue_write() { # <cible> ; entrée standard → fichier, atomiquement (temporaire caché : le glob des cibles ne le voit pas)
  local f tmp; f="$(deploy_queue_file "$1")"; tmp="$(mktemp "$(dirname "$f")/.tmp.XXXXXX")"
  grep . >"$tmp" || true; mv "$tmp" "$f"
}
# deploy_queue_put_ <cible> <couloir> <rév> <with> <retire> : demande de la tour — même couloir : même place, révision et options
# mises à jour, arrêt levé (la file repart) ; sinon en fin de file
deploy_queue_put_() {
  local q; q="$(deploy_queue_lines "$1")"
  if awk -F '\t' -v l="$2" '$1 == l && $6 == "-" {f = 1} END {exit !f}' <<<"$q"; then
    awk -F '\t' -v OFS='\t' -v l="$2" -v r="$3" -v w="$4" -v x="$5" '$1 == l && $6 == "-" {$3 = r; $4 = w; $5 = x; $7 = "-"} {print}' <<<"$q"
  else
    [ -z "$q" ] || printf '%s\n' "$q"; printf '%s\t%s\t%s\t%s\t%s\t-\t-\n' "$2" "$(cloud_epoch)" "$3" "$4" "$5"
  fi | deploy_queue_write "$1"
}
deploy_queue_wait_add_() { # <cible> <couloir> <pid> : attente hors tour, en fin de file
  local q; q="$(deploy_queue_lines "$1")"
  { [ -z "$q" ] || printf '%s\n' "$q"; printf '%s\t%s\t-\t-\t-\t%s\t-\n' "$2" "$(cloud_epoch)" "$3"; } | deploy_queue_write "$1"
}
# [rév] : seulement si la demande porte encore cette révision — une demande refaite pendant la mise en ligne (revue) reste en file
deploy_queue_drop_() { # <cible> <couloir> <pid|-> [rév] : retire cette demande
  local q; q="$(deploy_queue_lines "$1")"
  awk -F '\t' -v l="$2" -v p="$3" -v r="${4:-}" '!($1 == l && $6 == p && (r == "" || $3 == r))' <<<"$q" | deploy_queue_write "$1"
}
deploy_queue_fail_() { # <cible> <couloir> <rév> <cause> : la file de la cible s'arrête sur cette demande, à cette révision
  local q; q="$(deploy_queue_lines "$1")"
  awk -F '\t' -v OFS='\t' -v l="$2" -v r="$3" -v c="$(printf '%s' "$4" | tr '\t\n\r' '   ' | cut -c1-200)" '$1 == l && $6 == "-" && $3 == r {$7 = c} {print}' <<<"$q" | deploy_queue_write "$1"
}
deploy_queue_drop() { [ -f "$(deploy_queue_file "$1")" ] || return 0; deploy_queue_locked "$1" deploy_queue_drop_ "$@"; }
deploy_queue_pos() { # <cible> <couloir> <pid|-> → 1 = premier ; vide hors file
  local q; q="$(deploy_queue_lines "$1")"; awk -F '\t' -v l="$2" -v p="$3" '$1 == l && $6 == p && !n {n = NR} END {if (n) print n}' <<<"$q"
}
# deploy_queue_turn <cible> <pid> : aucune autre attente hors tour inscrite avant celle-ci (les demandes de la tour attendent la tour)
deploy_queue_waiter() { # <cible> → couloir de la première attente hors tour vivante, vide sinon
  local q; q="$(deploy_queue_lines "$1")"; awk -F '\t' '$6 != "-" {print $1; exit}' <<<"$q"
}
deploy_queue_turn() {
  local q; q="$(deploy_queue_lines "$1")"
  awk -F '\t' -v p="$2" '$6 == p {exit 0} $6 != "-" {exit 1} END {}' <<<"$q"
}
# deploy_queue_status_kv : lab status et lab tower — DEPLOY_QUEUE=<cible> <couloir> <pos>/<long> since <heure> par demande,
# DEPLOY_STOPPED=<cible> <couloir> <cause> pour une file arrêtée
deploy_queue_status_kv() {
  local f t q l e c n m
  for f in "$LAB_STATE/$P_NAME/en-ligne"/file/*; do
    [ -f "$f" ] || continue; t="${f##*/}"
    q="$(deploy_queue_lines "$t")"; [ -n "$q" ] || continue
    n=0; m="$(grep -c . <<<"$q")"
    while IFS=$'\t' read -r l e _ _ _ _ c; do
      n=$((n + 1)); kv DEPLOY_QUEUE "$t $l $n/$m since $(compte_heure "$e" 2>/dev/null || printf '%s' "$e")"
      [ "$c" = - ] || kv DEPLOY_STOPPED "$t $l $c"
    done <<<"$q"
  done
  return 0
}
deploy_tower_project() { local wt; wt="$(worktree_path "$TOWER_LANE")"; [ -d "$wt" ] && lane_is_tower "$wt"; }
# deploy_enqueue <cible> <couloir> <with…> -- <retire…> : demande d'un couloir d'un projet doté d'une tour — arbre propre et tête
# poussée vérifiés, puis inscrite ; rien déployé : la tour vide la file (lab deploy <projet> --queue)
deploy_enqueue() {
  local target="$1" lane="$2" w="" x="" a wt pos; shift 2
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do w="${w:+$w,}$1"; shift; done; [ "$#" = 0 ] || shift
  for a in "$@"; do x="${x:+$x,}$a"; done
  git -C "$P_ROOT" fetch -q --prune "$P_REMOTE" 2>/dev/null || die "git fetch $P_REMOTE failed: the head of lane $lane cannot be checked — nothing queued"
  deploy_lane "$lane"
  deploy_queue_locked "$target" deploy_queue_put_ "$target" "$lane" "$DL_HEAD" "${w:--}" "${x:--}"
  wt="$(worktree_path "$lane")"
  case "$(waits_get "$wt" kind):$(waits_get "$wt" why)" in "blocked:lab deploy $target:"*) waits_clear "$wt" ;; esac
  pos="$(deploy_queue_pos "$target" "$lane" -)"
  kv PROJECT "$P_NAME"; kv TARGET "$target"; kv DEPLOY queued; kv POSITION "$pos"; kv REV "$DL_HEAD"
  log_wrap "$target: lane $lane queued at position $pos, revision ${DL_HEAD:0:7}. Nothing deployed: the tower deploys it in order (lab deploy $P_NAME --queue)."
}
# deploy_drain [projet] : lab deploy <projet> --queue, le point de la tour — pour chaque cible, la première demande : file arrêtée →
# rien ; cible tenue par un processus vivant ou CI en cours → au prochain point ; CI rouge → arrêt ; sinon mise en ligne épinglée
# (sous-processus lab deploy --pin), puis la suivante. Un arrêt pose l'entrée blocked du couloir et le notifie.
deploy_drain() {
  local p="" t line lane rev w x c wt br num checks rc journal cause lk state k head; local -a a=(); local -a opts=() ws=() xs=() kept=()
  while [ "$#" -gt 0 ]; do case "$1" in --queue) shift ;; -*) usage ;; *) [ -z "$p" ] || usage; p="$1"; shift ;; esac; done
  load_project "$(resolve_project "$p")"
  [ "$(tower_guard_role)" != lane-agent ] || die "the go-live round belongs to the tower of $P_NAME: from a lane, lab deploy <target> queues it — nothing deployed$(tower_session_note)"
  kv PROJECT "$P_NAME"
  # tête des branches à jour : la CI d'une PR ne vaut que pour la révision inscrite si elle est encore la tête (revue)
  git -C "$P_ROOT" fetch -q --prune "$P_REMOTE" 2>/dev/null || warn "git fetch $P_REMOTE failed: branch heads read as last fetched"
  for t in $(deploy_queue_targets); do
    state='done'; kept=()   # couloirs mis en ligne par ce point sur cette cible, « couloir révision », gardés par les suivants
    while :; do
      # file lue d'abord : un awk qui s'arrête tôt couperait le producteur (SIGPIPE, mort muette sous pipefail)
      line="$(deploy_queue_lines "$t")"; line="$(awk -F '\t' '$6 == "-" {print; exit}' <<<"$line")"
      [ -n "$line" ] || break
      IFS=$'\t' read -r lane _ rev w x _ c <<<"$line"
      wt="$(worktree_path "$lane")"
      if [ "$c" != - ]; then state=stopped; kv DEPLOY_STOPPED "$t $lane $c"; break; fi
      # dernier contrôle de prod rouge (lot 08) : rien d'autre ne part sur la cible avant un --check vert
      c="$(state_field "$(deploy_dir)/$t" check_rc)"
      if [ -n "$c" ] && [ "$c" != 0 ]; then
        state=stopped; kv DEPLOY_STOPPED "$t $lane waits: prod check of $t red — lab deploy $P_NAME $t --check once fixed"; break
      fi
      lk="$(deploy_dir)/verrous/$t"
      if [ -f "$lk" ] && [ "$(pid_state "$(state_field "$lk" pid)")" != dead ]; then
        state=pending; log_wrap "$t: held by lane $(state_field "$lk" lane), live process — lane $lane goes at the next round."; break
      fi
      br="$(branch_name "$wt")"; num="$(pr_info "$P_ROOT" "$br" | cut -f1)"
      head="$(git -C "$P_ROOT" rev-parse -q --verify "refs/remotes/$P_REMOTE/$br" 2>/dev/null || true)"
      if [ -n "$num" ] && [ "$head" != "$rev" ]; then checks=moved
      elif [ -n "$num" ]; then checks="$(pr_checks_now "$wt" "$num" "$rev" "$br" "$P_BASE")"; else checks=none; fi
      if [ "$checks" = pending ]; then state=pending; log_wrap "$t: CI of lane $lane still running (PR #$num) — it goes at the next round."; break; fi
      if [ "$checks" = red ]; then cause="CI red for ${rev:0:7} (PR #$num)"
      elif [ "$checks" = moved ]; then cause="revision ${rev:0:7} is no longer the head of $br (${head:0:7}): the CI of PR #$num is not its own — ask again (lab deploy $t)"
      else
        IFS=, read -r -a ws <<<"${w/#-/}"; IFS=, read -r -a xs <<<"${x/#-/}"; opts=()
        for a in "${ws[@]+"${ws[@]}"}"; do opts+=(--with "$a"); done
        for a in "${xs[@]+"${xs[@]}"}"; do opts+=(--retire "$a"); done
        # un couloir mis en ligne plus tôt dans ce point est gardé à sa révision, sauf --retire explicite : la demande a été faite
        # avant qu'il soit servi (revue : deux demandes simples passent l'une après l'autre)
        for k in "${kept[@]+"${kept[@]}"}"; do
          if [ "${k%% *}" = "$lane" ] || in_words "${k%% *}" "${xs[@]+"${xs[@]}"}"; then continue; fi
          opts+=(--pin "${k%% *}" "${k#* }")
        done
        journal="$(mktemp)"; rc=0
        # sans COLUMNS : le refus final reste sur une ligne, relue ci-dessous (revue du lot 03 de charge-processeur)
        (cd "$P_ROOT" && unset COLUMNS && "$LAB_ROOT/bin/lab" deploy "$P_NAME" "$t" --pin "$lane" "$rev" "${opts[@]+"${opts[@]}"}") </dev/null >"$journal" 2>&1 || rc=$?
        sed 's/^/  /' "$journal" >&2
        cause="$(awk -v p="$DIE_PREFIX" 'index($0, p) == 1 {c = substr($0, length(p) + 1)} END {print c}' "$journal")"; rm -f "$journal"
        if [ "$rc" = 0 ]; then
          deploy_queue_drop "$t" "$lane" - "$rev"; kv DEPLOYED "$t $lane ${rev:0:7}"
          a=(); for k in "${kept[@]+"${kept[@]}"}"; do [ "${k%% *}" = "$lane" ] || a+=("$k"); done; kept=("${a[@]+"${a[@]}"}" "$lane $rev")
          continue
        fi
        if [ "$rc" = 3 ]; then state=pending; break; fi
        if [ "$rc" = 4 ]; then   # en ligne, contrôle rouge : la demande est servie et sort de la file ; le couloir garde la cause du contrôle
          deploy_queue_drop "$t" "$lane" - "$rev"; kv DEPLOYED "$t $lane ${rev:0:7}"
          state=stopped; kv DEPLOY_STOPPED "$t $lane $cause"
          log_wrap "$t: lane $lane is live but its prod check is red. Nothing else goes on $t until lab deploy $P_NAME $t --check is green."
          break
        fi
        cause="go-live failed (code $rc): ${cause:-see the output above}"
      fi
      deploy_queue_locked "$t" deploy_queue_fail_ "$t" "$lane" "$rev" "$cause"
      tower_signal "$wt" blocked "lab deploy $t: $cause"
      state=stopped; kv DEPLOY_STOPPED "$t $lane $cause"
      log_wrap "$t stopped on lane $lane: $cause. Nothing else goes on $t until lane $lane asks again (lab deploy $t) or cancels (--cancel)."
      break
    done
    kv TARGET "$t"; kv DEPLOY "$state"
  done
  return 0
}
deploy_cleanup() {
  [ -z "${DQ_WAIT:-}" ] || deploy_queue_drop "$DQ_WAIT" "$DQ_ME" "$$" || true
  if [ -n "${D_TMP:-}" ] && [ -d "$D_TMP" ]; then
    git -C "$P_ROOT" worktree remove --force "$D_TMP" >/dev/null 2>&1 || true
    rmdir "$D_TMP" 2>/dev/null || true
    git -C "$P_ROOT" worktree prune 2>/dev/null || true
    [ ! -d "$D_TMP" ] || warn "assembly worktree not removed: $D_TMP"
  fi
  if [ -n "${D_LOCK:-}" ] && [ "$(state_field "$D_LOCK" pid)" = "$$" ]; then rm -f "$D_LOCK"; fi
  return 0
}
# deploy_lane <couloir> [révision] : pose DL_BRANCH et DL_HEAD (tête poussée) ; refuse un couloir absent, sale ou dont la tête n'est
# pas poussée. [révision] : celle inscrite dans la file (lot 05 d'autonomie-tours), qui doit être dans <remote>/<branche> — l'arbre du
# couloir et les commits faits depuis la demande ne comptent pas.
deploy_lane() {
  local wt; wt="$(worktree_path "$1")"
  [ -d "$wt" ] || die "unknown lane: $1 (worktree missing: $wt) — nothing deployed"
  DL_BRANCH="$(branch_name "$wt")"; [ -n "$DL_BRANCH" ] || die "lane $1 has no branch (detached HEAD) — nothing deployed"
  if [ -n "${2:-}" ]; then
    has_remote_branch "$P_ROOT" "$DL_BRANCH" "$P_REMOTE" || die "lane $1: $P_REMOTE/$DL_BRANCH missing — nothing deployed"
    # @remote : la tête poussée (couloir --with d'une demande de la file, revue) — son arbre de travail ne compte pas
    [ "$2" != @remote ] || { DL_HEAD="$(git -C "$P_ROOT" rev-parse "$P_REMOTE/$DL_BRANCH")"; return 0; }
    git -C "$P_ROOT" merge-base --is-ancestor "$2" "$P_REMOTE/$DL_BRANCH" 2>/dev/null \
      || die "revision ${2:0:7} queued for lane $1 is not in $P_REMOTE/$DL_BRANCH — ask again from the lane (lab deploy); nothing deployed"
    DL_HEAD="$2"; return 0
  fi
  dirty_report "$wt" || die "dirty working tree in lane $1: $(dirty_tracked_list) — commit and push, then retry; nothing deployed"
  DL_HEAD="$(git -C "$wt" rev-parse HEAD)"
  has_remote_branch "$P_ROOT" "$DL_BRANCH" "$P_REMOTE" || die "head of lane $1 not pushed: $P_REMOTE/$DL_BRANCH missing — git push, then retry; nothing deployed"
  [ "$(git -C "$P_ROOT" rev-parse "$P_REMOTE/$DL_BRANCH")" = "$DL_HEAD" ] \
    || die "head of lane $1 (${DL_HEAD:0:7}) differs from $P_REMOTE/$DL_BRANCH: push or pull the branch, then retry; nothing deployed"
}

# ---------- fichiers privés et modèles de cibles (lot 04) ----------
# include.<cible>=<chemins> : fichiers hors dépôt (configuration de production, ignorée par git) copiés depuis le checkout principal
# dans l'arbre assemblé, juste avant la commande. deploy_includes_check refuse avant tout verrou ou assemblage : chemin absolu ou
# remontant (..), fichier absent ; pose D_INCLUDES (liste lue, vide si aucune).
deploy_includes_check() {
  local f; local -a fs=()
  D_INCLUDES="$(deploy_cfg include "$1")"; read -r -a fs <<<"$D_INCLUDES" || true
  for f in "${fs[@]+"${fs[@]}"}"; do
    case "/$f/" in //*|*/../*) die "include.$1: path refused: $f (relative to the repository, without ..) — nothing deployed" ;; esac
    [ -e "$P_ROOT/$f" ] || die "include.$1: file missing from the main checkout: $f ($P_ROOT/$f) — copy it, then retry; nothing deployed"
  done
}
# deploy_includes_copy <cible> <arbre> : copie ; un chemin suivi par git dans l'arbre assemblé n'est jamais remplacé (la révision
# servie ne serait plus celle du registre)
deploy_includes_copy() {
  local f d; local -a fs=()
  read -r -a fs <<<"${D_INCLUDES:-}" || true
  for f in "${fs[@]+"${fs[@]}"}"; do
    # un dossier parent lien symbolique (venu d'une branche assemblée) ferait écrire la copie hors de l'arbre : refusé
    d="$f"; while case "$d" in */*) true ;; *) false ;; esac; do
      d="${d%/*}"; [ ! -L "$2/$d" ] || die "include.$1: $d is a symbolic link in the assembled tree — copy refused; nothing deployed"
    done
    [ ! -L "$2/$f" ] || die "include.$1: $f is a symbolic link in the assembled tree — copy refused; nothing deployed"
    [ -z "$(git -C "$2" ls-files -- "$f" 2>/dev/null)" ] || die "include.$1: $f is tracked by git — it already ships with the revision; remove it from include.$1; nothing deployed"
    { mkdir -p "$2/$(dirname "$f")" && cp -Rp "$P_ROOT/$f" "$2/$f"; } || die "include.$1: copy failed: $f — nothing deployed"
  done
  [ "${#fs[@]}" = 0 ] || log "private files copied from $P_ROOT: ${fs[*]}"
}
# deploy_find <motif ERE de nom de fichier> [dossier] → les dossiers (profondeur ≤ 2, fichiers suivis par git de la base locale) qui
# portent ce fichier ; « . » pour la racine
deploy_find() {
  git -C "$P_ROOT" ls-files 2>/dev/null | grep -E "^([^/]+/){0,2}$1\$" | while IFS= read -r f; do
    case "$f" in */*) f="${f%/*}" ;; *) f=. ;; esac
    [ -z "${2:-}" ] || [ "$f" = "$2" ] || continue; printf '%s\n' "$f"
  done | sort -u
}
# deploy_add [projet] [worker|rsync|cloudrun] <cible> [--dir <dossier>] [--include <chemins>] [--build <commande>] [--host <hôte> --path <chemin>
# --restart <commande>] [--region <région>] [--service <service>] : écrit le bloc deploy./probe./include. d'un modèle dans la
# config du projet ; type déduit des fichiers suivis (wrangler.json[c]/toml → worker, Dockerfile → cloudrun) ; cible déjà déclarée
# → refus, rien écrit. Le modèle est une commande ordinaire : relue et corrigée par l'utilisateur au besoin, avant --dry-run.
deploy_add() {
  local type="" target w dir="" host="" path="" restart="" region="" service="" build="" cfg cmd probe pre inst conf="" rel="" src f q
  local -a pos=() incl=() found=()
  while [ "$#" -gt 0 ]; do case "$1" in
    --add) shift ;;
    --dir|--include|--build|--host|--path|--restart|--region|--service)
      [ -n "${2:-}" ] || usage
      case "$1" in --dir) dir="${2%/}" ;; --include) read -r -a found <<<"$2"; incl+=("${found[@]}") ;; --host) host="$2" ;;
        --path) path="${2%/}" ;; --restart) restart="$2" ;; --build) build="$2" ;; --region) region="$2" ;; --service) service="$2" ;; esac; shift 2 ;;
    -*) usage ;; *) if in_words "$1" worker rsync cloudrun && [ -z "$type" ]; then type="$1"; else pos+=("$1"); fi; shift ;; esac; done
  case "${#pos[@]}" in
    1) load_project "$(resolve_project "")"; target="${pos[0]}" ;;
    2) load_project "$(resolve_project "${pos[0]}")"; target="${pos[1]}" ;;
    *) usage ;;
  esac
  valid_slug "$target" || die "invalid target: $target"
  cfg="$(project_dir "$P_NAME")/config"
  for w in deploy probe include; do
    [ -z "$(deploy_cfg "$w" "$target")" ] || die "target already declared: $w.$target= in $cfg — nothing rewritten (choose another name, or remove its deploy./probe./include. lines to declare it again)"
  done
  # chaque valeur finit dans une ligne de config lue ligne à ligne, puis exécutée par bash -c : ni retour à la ligne, ni chemin hors
  # du dépôt, ni dossier qui demanderait des guillemets
  case "$dir$host$path$restart$region$service$build${incl[*]+"${incl[*]}"}" in *$'\n'*|*$'\r'*) die "--add: line break refused in a value; nothing written" ;; esac
  for f in "${incl[@]+"${incl[@]}"}"; do
    case "/$f/" in //*|*/../*) die "--include: path refused: $f (relative to the repository, without ..)" ;; esac
    case "$f" in *[!A-Za-z0-9._/-]*) die "--include: path refused: $f (unaccented letters, digits, . _ / - only); nothing written" ;; esac
  done
  case "$dir" in /*|..|../*|*/../*|*/..) die "--dir: folder relative to the repository expected, without ..: $dir" ;; esac
  case "$dir" in *[!A-Za-z0-9._/-]*) die "--dir: unaccented letters, digits, . _ / - only: $dir; nothing written" ;; esac
  case "$host" in -*) die "--host: a host does not start with a dash: $host; nothing written" ;; esac
  [ -z "$build" ] || [ "$type" = worker ] || [ -z "$type" ] || die "--build: reserved for the worker template (rsync and cloudrun build by themselves); nothing written"
  if [ -z "$type" ]; then
    if [ -n "$(deploy_find 'wrangler\.(json|jsonc|toml)' "$dir")" ]; then type=worker
    elif [ -n "$(deploy_find Dockerfile "$dir")" ]; then type=cloudrun
    else die "target type unknown: neither wrangler.json[c] nor Dockerfile${dir:+ in $dir} — give the type: worker, rsync or cloudrun; nothing written"; fi
    log "type inferred from the repository files: $type"
  fi
  if [ -z "$dir" ]; then
    case "$type" in
      worker) read -r -a found <<<"$(deploy_find 'wrangler\.(json|jsonc|toml)' | paste -sd' ' -)" || true ;;
      cloudrun) read -r -a found <<<"$(deploy_find Dockerfile | paste -sd' ' -)" || true ;;
      rsync) found=() ;;
    esac
    [ "${#found[@]}" -le 1 ] || die "several possible folders for $type: ${found[*]} — give --dir; nothing written"
    dir="${found[0]:-.}"
  fi
  pre=""; [ "$dir" = . ] || pre="cd $dir && "
  case "$type" in
    worker)
      inst="$(detect_install "$P_ROOT/$dir")"
      for f in "${incl[@]+"${incl[@]}"}"; do case "${f##*/}" in wrangler*.json|wrangler*.jsonc|wrangler*.toml) conf="$f"; break ;; esac; done
      if [ -n "$conf" ]; then
        case "$dir:$conf" in .:*) rel="$conf" ;; *:"$dir"/*) rel="${conf#"$dir"/}" ;; *) die "--include: $conf outside the Worker folder ($dir)" ;; esac
        rel=" --config $rel"
      fi
      q="WRANGLER_SEND_METRICS=false npx wrangler"
      # --build : préparation que wrangler deploy ne lance pas (assets générés…), après l'installation, dans le dossier du Worker
      cmd="$pre${inst:+$inst && }${build:+$build && }$q deploy --keep-vars --message \"\$LAB_DEPLOY_REV\"$rel"
      # sonde : déploiement actif (version au plus fort pourcentage), puis message de cette version — la révision passée par --message
      probe="${pre}v=\$($q deployments status --json$rel | node -e 'const d=JSON.parse(require(\"fs\").readFileSync(0,\"utf8\"));process.stdout.write(String(d.versions.sort((a,b)=>b.percentage-a.percentage)[0].version_id))') && $q versions view \"\$v\" --json$rel | node -e 'const d=JSON.parse(require(\"fs\").readFileSync(0,\"utf8\"));process.stdout.write(String((d.annotations||{})[\"workers/message\"]||\"\"))'"
      ;;
    rsync)
      [ -n "$host" ] && [ -n "$path" ] && [ -n "$restart" ] \
        || die "rsync template: --host <host> --path <served folder> --restart <command that restarts the background program> required; nothing written"
      case "$host$path$restart" in *\"*|*\'*|*\$*|*\`*) die "rsync template: no quote, no \$, no backtick in --host, --path, --restart; nothing written" ;; esac
      case "$host$path" in *" "*) die "rsync template: --host and --path without spaces; nothing written" ;; esac
      case "$path" in /*) ;; *) die "rsync template: absolute --path expected on the host: $path; nothing written" ;; esac
      # transit par couloir, tenu exact (--delete n'efface que dans le transit, propre à lab), puis copie fichier par fichier dans
      # le dossier servi : rien n'y est jamais effacé
      src="./"; [ "$dir" = . ] || src="./$dir/"
      cmd="rsync -rlptz --checksum --delete --exclude=.git $src $host:$path.lab-transit-\"\$LAB_DEPLOY_LANE\"/ && ssh $host \"cp -Rp $path.lab-transit-\$LAB_DEPLOY_LANE/. $path/ && echo \$LAB_DEPLOY_REV >$path/.lab-revision && $restart\""
      probe="ssh $host cat $path/.lab-revision"
      ;;
    cloudrun)
      [ -n "$region" ] || die "cloudrun template: --region <region> required; nothing written"
      service="${service:-$target}"
      case "$region$service" in *[!a-z0-9-]*) die "cloudrun template: --region and --service in lowercase letters, digits and dashes; nothing written" ;; esac
      # nouvelle révision sans trafic, étiquetée lab-<rév>, puis bascule de tout le trafic sur cette étiquette
      cmd="gcloud run deploy $service --source $dir --region $region --no-traffic --tag lab-\"\${LAB_DEPLOY_REV:0:7}\" --update-env-vars LAB_DEPLOY_REV=\"\$LAB_DEPLOY_REV\" --quiet && gcloud run services update-traffic $service --region $region --to-tags lab-\"\${LAB_DEPLOY_REV:0:7}\"=100 --quiet"
      # sonde : étiquette de la révision qui reçoit tout le trafic
      probe="gcloud run services describe $service --region $region --format=json | python3 -c 'import json,sys; s=json.load(sys.stdin)[\"status\"]; t=s.get(\"traffic\",[]); r={x.get(\"revisionName\") or s.get(\"latestReadyRevisionName\") for x in t if x.get(\"percent\")==100}; print(next((x[\"tag\"] for x in t if x.get(\"tag\") and x.get(\"revisionName\") in r), \"\"))'"
      ;;
  esac
  registry_locked "$P_NAME" deploy_add_write "$cfg" "$target" "$type" "$cmd" "$probe" "${incl[@]+"${incl[@]}"}"
  for f in "${incl[@]+"${incl[@]}"}"; do [ -e "$P_ROOT/$f" ] || warn "include.$target: $f missing from the main checkout ($P_ROOT) — lab deploy $target will refuse while it is missing"; done
  kv PROJECT "$P_NAME"; kv TARGET "$target"; kv TYPE "$type"; kv FOLDER "$dir"
  kv DEPLOY "$cmd"; kv PROBE "$probe"; kv INCLUDE "$(words_or "${incl[@]+"${incl[@]}"}")"; kv CONFIG "$cfg"
  log "block written; check the plan first: lab deploy $P_NAME $target --dry-run"
}

# deploy_add_write <config> <cible> <type> <deploy> <sonde> [include…] : le bloc de lab deploy --add, sous le verrou du registre ;
# une cible déclarée entre-temps par un autre lab est relue ici et refusée (lot-01 de sans-perte)
deploy_add_write() {
  local cfg="$1" target="$2" type="$3" cmd="$4" probe="$5" w; shift 5
  for w in deploy probe include; do
    [ -z "$(deploy_cfg "$w" "$target")" ] || die "target already declared: $w.$target= in $cfg — nothing rewritten (choose another name, or remove its deploy./probe./include. lines to declare it again)"
  done
  [ -z "$(tail -c1 "$cfg")" ] || printf '\n' >>"$cfg"
  { printf '# target %s: %s template (lab deploy --add, %s)\n' "$target" "$type" "$(date -u +%Y-%m-%d)"
    printf 'deploy.%s=%s\n' "$target" "$cmd"; printf 'probe.%s=%s\n' "$target" "$probe"
    [ "$#" = 0 ] || printf 'include.%s=%s\n' "$target" "$*"; } >>"$cfg"
}

# cmd_deploy [projet] <cible> [--with <couloir>…] [--retire <couloir>…] [--record] [--dry-run] ; --add : deploy_add
# deploy_reg_write <verified> : le registre de la cible, écrit par cmd_deploy avec ses variables (portée dynamique de bash) ; deux
# écritures au plus par mise en ligne, mêmes valeurs sauf verified= (revue du lot 03 de charge-processeur)
deploy_reg_write() {
  state_write "$reg" "$(printf 'target=%s\nrev=%s\nbase=%s\nbase_rev=%s\nlanes=%s\nbranches=%s\nheads=%s\nprs=%s\nsince=%s\nretired=%s\nlane=%s\ndate=%s\nepoch=%s\nverified=%s\n' \
    "$target" "$rev" "$P_BASE" "$base_rev" "${inc[*]+"${inc[*]}"}" "${incb[*]+"${incb[*]}"}" "${inch[*]+"${inch[*]}"}" \
    "$(for pr in "${incp[@]+"${incp[@]}"}"; do printf '%s ' "${pr:--}"; done | sed 's/ $//')" "$since" "${retired[*]+"${retired[*]}"}" \
    "$actor" "$stamp" "$now" "$1")"$'\n'
}
cmd_deploy() {
  case " $* " in *" --add "*) deploy_add "$@"; return ;; *" --queue "*) deploy_drain "$@"; return ;; esac
  local target record=0 dry=0 cancel=0 check=0 here cmd probe got reg base_rev rev part i lane br head pr verified=yes rc=0 pin="" actor lrev
  local waited poll max again=0
  local -a pins=() pin_revs=() pos=() with=() retire=() inc=() incb=() inch=() incp=() r_lanes=() r_since=() lost=() lostn=() retired=()
  while [ "$#" -gt 0 ]; do case "$1" in
    --with) [ -n "${2:-}" ] || usage; valid_slug "$2" || die "invalid lane: $2"; with+=("$2"); shift 2 ;;
    --retire) [ -n "${2:-}" ] || usage; valid_slug "$2" || die "invalid lane: $2"; retire+=("$2"); shift 2 ;;
    --record) record=1; shift ;; --dry-run) dry=1; shift ;; --cancel) cancel=1; shift ;; --check) check=1; shift ;;
    # --pin <couloir> <révision> : mise en ligne lancée par le point de la tour (deploy_drain) — le premier est la demande, à sa
    # révision inscrite ; les suivants, les couloirs mis en ligne avant elle dans ce point, gardés à leur révision
    --pin) valid_slug "${2:-}" && [[ "${3:-}" =~ ^[0-9a-f]{40}$ ]] || usage; pins+=("$2"); pin_revs+=("$3"); shift 3 ;;
    -*) usage ;; *) pos+=("$1"); shift ;; esac; done
  case "${#pos[@]}" in
    1) load_project "$(resolve_project "")"; target="${pos[0]}" ;;
    2) load_project "$(resolve_project "${pos[0]}")"; target="${pos[1]}" ;;
    *) usage ;;
  esac
  valid_slug "$target" || die "invalid target: $target"
  cmd="$(deploy_cfg deploy "$target")"; probe="$(deploy_cfg probe "$target")"
  [ -n "$cmd" ] || die "undeclared target: $target — declared for $P_NAME: $(deploy_targets) (key deploy.<target>= of $(project_dir "$P_NAME")/config; lab deploy --add <type> $target writes it)"
  if [ "$check" = 1 ]; then
    [ "$record$dry$cancel" = 000 ] && [ "${#pins[@]}" = 0 ] && [ "${#with[@]}" = 0 ] && [ "${#retire[@]}" = 0 ] || usage
    deploy_check "$target"; return
  fi
  deploy_includes_check "$target"
  # depuis un couloir, sa branche part avec la cible ; depuis le checkout principal, la base seule
  here="$(here_lane)"; case "$here" in main-checkout) here="" ;; esac
  # mode épinglé : ni le dossier courant (la tour), ni sa branche — seul le couloir inscrit part, à sa révision
  pin="${pins[0]:-}"
  if [ -n "$pin" ]; then
    here=""; for lane in "${pins[@]}"; do in_words "$lane" "${with[@]+"${with[@]}"}" || with+=("$lane"); done
  fi
  actor="${here:-${pin:-outside-lane}}"
  # lot 06 d'autonomie-tours : l'agent d'un couloir n'a que l'essai à blanc, le retrait de sa demande et l'inscription depuis son couloir
  if [ "$cancel" = 0 ] && [ "$dry" = 0 ] && [ "$(tower_guard_role)" = lane-agent ] \
    && { [ -n "$pin" ] || [ "$record" = 1 ] || [ -z "$here" ] || lane_is_tower "$(worktree_path "$here")"; }; then
    die "this go-live of $target belongs to the tower of $P_NAME: from a lane, lab deploy $target queues it and the tower deploys it at its round — nothing deployed$(tower_session_note)"
  fi
  if [ "$cancel" = 1 ]; then
    [ -z "$pin" ] && [ "$dry" = 0 ] && [ "$record" = 0 ] || usage
    kv PROJECT "$P_NAME"; kv TARGET "$target"
    if [ -n "$(deploy_queue_pos "$target" "$actor" -)" ]; then
      deploy_queue_drop "$target" "$actor" -; kv DEPLOY cancelled; log_wrap "$target: request of lane $actor removed from the queue."
      [ "$actor" = outside-lane ] || case "$(waits_get "$(worktree_path "$actor")" kind):$(waits_get "$(worktree_path "$actor")" why)" in
        "blocked:lab deploy $target:"*) waits_clear "$(worktree_path "$actor")" ;; esac
    else kv DEPLOY none; log_wrap "$target: no request of lane $actor in the queue."; fi
    return 0
  fi
  for lane in "${retire[@]+"${retire[@]}"}"; do
    ! in_words "$lane" "${with[@]+"${with[@]}"}" "$here" || die "lane $lane both included and retired: choose one — nothing deployed"
  done
  # projet doté d'une tour, depuis un autre couloir : la demande entre dans la file, la tour la lance à son tour
  if [ "$dry" = 0 ] && [ "$record" = 0 ] && [ -z "$pin" ] && [ -n "$here" ] && deploy_tower_project && ! lane_is_tower "$(worktree_path "$here")"; then
    deploy_enqueue "$target" "$here" "${with[@]+"${with[@]}"}" -- "${retire[@]+"${retire[@]}"}"; return 0
  fi

  if [ "$dry" = 0 ]; then
    D_LOCK="$(deploy_dir)/verrous/$target"; D_TMP=""
    trap deploy_cleanup EXIT; trap 'exit 130' INT TERM HUP
    # une attente hors tour déjà inscrite passe d'abord : le nouvel arrivant s'inscrit derrière elle, même cible libre (revue)
    head="$(deploy_queue_waiter "$target")"
    if [ -z "$pin" ] && [ -n "$head" ]; then rc=1; RES_PREV="$head (waiting before you)"
    else resource_take "$target" "$actor" "$$" "$(deploy_dir)/verrous" 1 || rc=$?; fi
    [ "$rc" != 2 ] || { D_LOCK=""; die "go-live lock not writable: $(deploy_dir)/verrous"; }
    # le point de la tour ne patiente pas : la demande reste en file, au prochain point
    [ "$rc" = 0 ] || [ -z "$pin" ] || { D_LOCK=""; log "go-live of $target already running: lane $RES_PREV — $pin waits for the next round"; exit 3; }
    if [ "$rc" = 1 ]; then
      # hors tour : cible tenue par un processus vivant → inscription, puis attente de son tour, bornée (LAB_DEPLOY_WAIT_MAX)
      max="$(deploy_queue_max)"; poll="${LAB_DEPLOY_POLL:-10}"; waited="$SECONDS"
      DQ_WAIT="$target"; DQ_ME="$actor"; deploy_queue_locked "$target" deploy_queue_wait_add_ "$target" "$actor" "$$"
      log_wrap "$target is held by lane $RES_PREV: waiting for its turn, at most $max s (position $(deploy_queue_pos "$target" "$actor" "$$"))."
      while :; do
        sleep "$poll"; rc=1
        if deploy_queue_turn "$target" "$$"; then rc=0; resource_take "$target" "$actor" "$$" "$(deploy_dir)/verrous" 1 || rc=$?; fi
        [ "$rc" != 0 ] || break
        [ "$rc" != 2 ] || { D_LOCK=""; die "go-live lock not writable: $(deploy_dir)/verrous"; }
        if [ $((SECONDS - waited)) -ge "$max" ]; then
          D_LOCK=""
          warn_wrap "gave up after $((SECONDS - waited)) s of waiting (LAB_DEPLOY_WAIT_MAX=$max): retry when lane ${RES_PREV%% *} has finished."
          die "go-live of $target held by lane $RES_PREV, live process — nothing deployed"
        fi
        log_wrap "still waiting for $target: held by lane ${RES_PREV%% *} ($((SECONDS - waited)) s of $max s)."
      done
      deploy_queue_drop "$target" "$actor" "$$"; DQ_WAIT=""
      log_wrap "$target is free: going on."
    fi
  fi
  git -C "$P_ROOT" fetch -q --prune "$P_REMOTE" 2>/dev/null \
    || die "git fetch $P_REMOTE failed: without a fresh state of the remote, lab cannot tell what $target would lose — nothing deployed"
  has_remote_branch "$P_ROOT" "$P_BASE" "$P_REMOTE" || die "base $P_REMOTE/$P_BASE not found — nothing deployed"
  base_rev="$(git -C "$P_ROOT" rev-parse "$P_REMOTE/$P_BASE")"

  # registre : couloirs servis par la dernière mise en ligne (listes alignées)
  reg="$(deploy_dir)/$target"
  read -r -a r_lanes <<<"$(state_field "$reg" lanes)" || true
  read -r -a r_since <<<"$(state_field "$reg" since)" || true
  # couloirs inclus : ceux déjà servis d'abord (même ordre d'assemblage), puis --with, puis le couloir courant
  for lane in "${r_lanes[@]+"${r_lanes[@]}"}" "${with[@]+"${with[@]}"}" "$here"; do
    [ -n "$lane" ] || continue
    in_words "$lane" "${with[@]+"${with[@]}"}" "$here" || continue
    in_words "$lane" "${inc[@]+"${inc[@]}"}" && continue
    lrev=""; [ -z "$pin" ] || lrev=@remote
    for i in "${!pins[@]}"; do [ "${pins[$i]}" != "$lane" ] || lrev="${pin_revs[$i]}"; done
    deploy_lane "$lane" "$lrev"
    pr="$(pr_info "$P_ROOT" "$DL_BRANCH" | cut -f1)"
    inc+=("$lane"); incb+=("$DL_BRANCH"); inch+=("$DL_HEAD"); incp+=("${pr:+#$pr}")
  done
  # couloirs perdus : servis, ni repris, ni retirés, ni fusionnés dans la base
  for lane in "${retire[@]+"${retire[@]}"}"; do
    if in_words "$lane" "${r_lanes[@]+"${r_lanes[@]}"}"; then retired+=("$lane"); else warn "lane $lane not served by $target: --retire $lane has no effect"; fi
  done
  while IFS=$'\t' read -r lane br head pr; do
    [ -n "$lane" ] || continue; [ "$pr" != - ] || pr=""
    lost+=("$lane ($br @ ${head:0:7}${pr:+, PR $pr})"); lostn+=("$lane")
  done < <(deploy_lost "$reg" "${inc[@]+"${inc[@]}"}" "${retired[@]+"${retired[@]}"}")
  part="$P_BASE@${base_rev:0:7}"
  for i in "${!inc[@]}"; do part="$part + ${inc[$i]}@${inch[$i]:0:7}"; done

  if [ "$dry" = 1 ]; then
    kv PROJECT "$P_NAME"; kv TARGET "$target"; kv ACTION plan; kv BASE "$P_BASE@${base_rev:0:7}"; kv PART "$part"
    kv INCLUDED "$(words_or "${inc[@]+"${inc[@]}"}")"; kv RETIRED "$(words_or "${retired[@]+"${retired[@]}"}")"
    kv LOST "$(if [ "${#lost[@]}" -gt 0 ]; then printf '%s ; ' "${lost[@]}" | sed 's/ ; $//'; else printf none; fi)"
    kv FILES "${D_INCLUDES:-none}"
    [ "${#lost[@]}" = 0 ] || warn "this go-live would be refused: it would erase $(printf '%s ; ' "${lost[@]}" | sed 's/ ; $//')"
    return 0
  fi
  if [ "${#lost[@]}" -gt 0 ]; then
    die "go-live refused: $target also serves $(printf '%s ; ' "${lost[@]}" | sed 's/ ; $//'), not merged — this deployment would erase it. Include it ($(printf -- '--with %s ' "${lostn[@]}" | sed 's/ $//')) or retire it explicitly ($(printf -- '--retire %s ' "${lostn[@]}" | sed 's/ $//')); nothing deployed"
  fi

  # --record inscrit ce qui est déjà servi : aucun assemblage neuf, aucun push de serve/<cible> (revue du lot 01) ; la révision
  # inscrite est la base, ou la tête du couloir seul ; plusieurs couloirs : inconnue
  if [ "$record" = 1 ]; then
    case "${#inc[@]}" in 0) rev="$base_rev" ;; 1) rev="${inch[0]}" ;; *) rev=unknown ;; esac
  else
    # construction depuis un commit propre, dans un chantier temporaire retiré même sur erreur
    D_TMP="$(mktemp -d "${TMPDIR:-/tmp}/lab-deploy.XXXXXX")"
    git -C "$P_ROOT" worktree add -q --detach "$D_TMP" "$base_rev" >/dev/null 2>&1 || die "assembly worktree failed: $D_TMP — nothing deployed"
    for i in "${!inc[@]}"; do
      if ! git -C "$D_TMP" merge -q --no-edit -m "lab deploy $target : + ${inc[$i]} (${incb[$i]})" "${inch[$i]}" >/dev/null 2>&1; then
        got="$(git -C "$D_TMP" diff --name-only --diff-filter=U | paste -sd, - | sed 's/,/, /g')"
        git -C "$D_TMP" merge --abort >/dev/null 2>&1 || true
        die "assembly failed: lane ${inc[$i]} (${incb[$i]}) conflicts with $(printf '%s' "$part" | sed "s/ + ${inc[$i]}@.*//") on ${got:-some files} — reconcile the branches, then retry; nothing deployed"
      fi
    done
    rev="$(git -C "$D_TMP" rev-parse HEAD)"
    if [ "${#inc[@]}" -gt 0 ]; then
      # seul push forcé de lab : serve/<cible>, reconstruite à chaque mise en ligne, avec bail sur la valeur lue au fetch
      head="$(git -C "$P_ROOT" rev-parse -q --verify "refs/remotes/$P_REMOTE/serve/$target" 2>/dev/null || true)"
      git -C "$D_TMP" push -q --force-with-lease="refs/heads/serve/$target:$head" "$P_REMOTE" "HEAD:refs/heads/serve/$target" >/dev/null 2>&1 \
        || die "push of serve/$target refused (another go-live moved it?) — nothing deployed"
    fi
  fi

  if [ "$record" = 1 ]; then
    verified=no; log "$target recorded without deployment: $part"
  else
    deploy_includes_copy "$target" "$D_TMP"
    log "going live on $target: $part"
    (cd "$D_TMP" && LAB_DEPLOY_TARGET="$target" LAB_DEPLOY_REV="$rev" LAB_DEPLOY_LANE="$actor" bash -c "$cmd") </dev/null >&2 || {
      rc=$?; die "go-live command failed (code $rc): $cmd — the target may be in a partial state; registry unchanged"; }
  fi
  # since= : première mise en ligne de chaque couloir servi, gardée tant qu'il le reste (le doctor mesure son ancienneté)
  local since="" now stamp j s; now="$(epoch_now)"; stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for lane in "${inc[@]+"${inc[@]}"}"; do
    s="$now"
    for j in "${!r_lanes[@]}"; do [ "${r_lanes[$j]}" != "$lane" ] || s="${r_since[$j]:-$(state_field "$reg" epoch)}"; done
    since="${since:+$since }${s:-$now}"
  done
  if [ "$record" = 0 ] && [ -z "$probe" ]; then
    verified=no; warn "no probe for $target (key probe.$target= of the config): the served revision is not verified"
  elif [ "$record" = 0 ]; then
    # la cible sert encore l'ancienne révision quelques instants après la commande (propagation, cache) : la sonde est relue
    # toutes les LAB_DEPLOY_PROBE_EVERY s (5), LAB_DEPLOY_PROBE_WAIT s au plus (120) — jamais juste : le même refus qu'avant
    # (lot 03 de charge-processeur : le site devait commencer par sleep 60, coupé par le doctor et jamais lu). Le registre dit
    # d'abord la révision mise en ligne, non vérifiée : un appel coupé pendant la relecture la laisse inscrite (revue du lot 03)
    deploy_reg_write no
    poll="${LAB_DEPLOY_PROBE_EVERY:-5}"; max="${LAB_DEPLOY_PROBE_WAIT:-120}"
    [[ "$poll" =~ ^[1-9][0-9]*$ ]] || poll=5; [[ "$max" =~ ^[0-9]+$ ]] || max=120
    waited="$SECONDS"
    while :; do
      got="$( (cd "$D_TMP" && LAB_DEPLOY_TARGET="$target" LAB_DEPLOY_LANE="$actor" bash -c "$probe") </dev/null 2>/dev/null | grep -oE '[0-9a-f]{7,40}' | head -1 || true)"
      case "$rev" in "${got:-empty}"*) break ;; esac
      if [ $((SECONDS - waited)) -ge "$max" ]; then verified=no; break; fi
      [ "$again" = 1 ] || log_wrap "probe of $target: served revision ${got:-unreadable}, expected ${rev:0:7} — read again every $poll s, $max s at most."
      again=1; sleep "$poll"
    done
  fi
  deploy_reg_write "$verified"
  kv PROJECT "$P_NAME"; kv TARGET "$target"; kv ACTION "$(if [ "$record" = 1 ]; then printf recorded; else printf deployed; fi)"
  kv REV "$rev"; kv BASE "$P_BASE@${base_rev:0:7}"; kv INCLUDED "$(words_or "${inc[@]+"${inc[@]}"}")"
  kv RETIRED "$(words_or "${retired[@]+"${retired[@]}"}")"; [ "${#inc[@]}" = 0 ] || [ "$record" = 1 ] || kv SERVE "serve/$target"
  kv VERIFIED "$verified"
  if [ "$record" = 0 ] && [ -n "$probe" ] && [ "$verified" = no ]; then
    die_wrap "probe of $target: served revision ${got:-unreadable}, expected ${rev:0:7} — the go-live is not verified (registry marked verified=no)"
  fi
  # lot 08 d'autonomie-tours : la prod contrôlée sur la révision servie, une fois la sonde vérifiée ; --record ne lance rien
  PC_STATE=none; PC_RC=""; PC_LOG=""
  if [ "$verified" = yes ]; then prod_check_run "$target" "$rev"
  elif [ "$record" = 0 ] && [ -n "$(deploy_cfg prod_check "$target")" ]; then warn_wrap "prod check of $target not run: the served revision is not verified."; fi
  prod_check_kv
  # rouge après la mise en ligne : rc 4, distinct d'un échec (le point de la tour retire alors la demande, servie, revue du lot 08)
  if [ "$PC_STATE" = red ]; then
    printf '%s%s\n' "$DIE_PREFIX" "$PC_WHY — output in $PC_LOG; the go-live stays (no rollback), lanes served by $target are blocked: fix, then lab deploy $P_NAME $target --check" >&2
    exit 4
  fi
}
