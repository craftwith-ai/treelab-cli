# shellcheck shell=bash
# watch.sh — veilleur de livraison (lot 14) : lab merge et lab close rendent la main ; un processus lab détaché attend la CI et
# fusionne à la révision exacte, puis, pour close, retire le couloir. Un fichier d'état par branche, hors du worktree pour survivre
# à son retrait : $LAB_STATE/watch/<projet>/<couloir>/<branche, / → +>, lignes clé=valeur (pid, action, pr, sha, issue, detail…),
# son journal à côté (.log). Jamais de fusion ni de retrait sur un doute : l'issue le nomme, lab status et le hook de démarrage la lisent.
# Issues, écrites en anglais depuis le lot 09 du couloir anglais : armed (attend la CI), waiting (en file derrière un autre lot),
# merged, closed, red, conflict, changed, failed ; dead est calculé à la lecture (armed ou waiting, pid prouvé mort) et relancé par
# lab next et lab launch. Un fichier posé par un lab d'avant porte encore l'issue en français : lang_code la traduit (watch_state).
watch_key() { printf '%s\n' "$1" | tr '/' '+'; }
watch_dir() { printf '%s/watch/%s/%s\n' "$LAB_STATE" "$P_NAME" "${1:-$SLUG}"; }
watch_file() { printf '%s/%s\n' "$(watch_dir "${2:-$SLUG}")" "$(watch_key "$1")"; }
watch_get() { [ -f "$1" ] || return 0; sed -n "s/^$2=//p" "$1" | head -1; }   # fichier absent : vide, jamais une erreur sous pipefail
watch_put() { # <fichier> <clé> <valeur sur une ligne> : réécriture atomique, le lecteur ne voit jamais un fichier à moitié écrit
  local tmp; tmp="$(mktemp "$1.tmp.XXXXXX")"
  { grep -v "^$2=" "$1" 2>/dev/null || true; printf '%s=%s\n' "$2" "$(printf '%s' "$3" | tr '\n' ' ')"; } >"$tmp" && mv "$tmp" "$1"
}
# un veilleur remplacé par un nouvel armement (revue du lot 14) n'écrit plus rien : seul le titulaire du fichier (pid) le fait
watch_issue() {
  if [ -n "${WATCH_SELF:-}" ] && [ "$(watch_get "$1" pid)" != "$WATCH_SELF" ]; then log "watcher $WATCH_SELF replaced: outcome \"$2\" not written"; exit 0; fi
  watch_put "$1" issue "$2"; watch_put "$1" detail "$3"; watch_put "$1" at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }
# watch_state <fichier> → issue lue en anglais, « dead » pour un veilleur attendu vivant dont le pid est prouvé mort (indéterminable : inchangé)
watch_state() {
  local issue; issue="$(lang_code "$(watch_get "$1" issue)")"   # fichier d'un lab d'avant le lot 09 : issue française relue
  case "$issue" in armed|waiting) ! pid_dead "$(watch_get "$1" pid)" || issue=dead ;; esac
  printf '%s\n' "$issue"
}
# watch_arm <action> <branche> [clé=valeur…] : écrit l'état neuf puis détache le veilleur ; la session qui arme est retenue, pour que
# le retrait de close ne la prenne pas pour une autre session vivante
watch_arm() {
  local action="$1" br="$2" f kv; shift 2
  f="$(watch_file "$br")"; mkdir -p "$(dirname "$f")"
  watch_stop "$f"   # un réarmement (correctif poussé, lab close après lab merge) remplace l'ancien veilleur, jamais deux à la fois
  : >"$f"; : >"$f.log"
  watch_put "$f" action "$action"; watch_put "$f" branch "$br"; watch_put "$f" since "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for kv in "$@"; do watch_put "$f" "${kv%%=*}" "${kv#*=}"; done
  if session_owned_here "$WT"; then watch_put "$f" session "$(lock_field "$(lock_file "$WT")" pid 2>/dev/null || true)"; fi
  case "$action" in
    chain) watch_issue "$f" waiting "queued behind #$(watch_get "$f" on_pr)" ;;
    cloud) watch_issue "$f" armed "waiting for the session to end on $(watch_get "$f" machine)" ;;   # lot 04 de cmux-pro
    file) watch_issue "$f" armed "in the Cloud queue: waiting for a free slot" ;;   # lot 05 de cmux-pro
    *) watch_issue "$f" armed "waiting for the CI of #$(watch_get "$f" pr)" ;;
  esac
  watch_spawn "$br"
  kv WATCHER_PID "$(watch_get "$f" pid)"; kv WATCH_LOG "$f.log"
}
# watch_stop <fichier> : arrête le veilleur vivant de ce fichier (groupe entier : gh et sleep compris)
watch_stop() {
  local pid; pid="$(watch_get "$1" pid)"
  case "$(lang_code "$(watch_get "$1" issue)")" in armed|waiting) ;; *) return 0 ;; esac
  pid_alive "$pid" || return 0
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  log "previous watcher of $(watch_get "$1" branch) (pid $pid) stopped: replaced by this new one"
}
# watch_done <branche> <issue> <détail> : lab merge ou lab close ont livré sur place — l'issue ancienne (rouge…) ne reste pas affichée
watch_done() {
  local f; f="$(watch_file "$1")"; [ -f "$f" ] || return 0
  watch_stop "$f"; watch_issue "$f" "$2" "$3"
}
# watch_spawn <branche> : processus détaché de la session (nouvelle session POSIX : ni la fermeture de l'onglet ni le remplacement
# de la session ne le tuent) ; LAB_WATCH_SYNC=1 (tests) le déroule sur place, sa sortie dans le journal
watch_spawn() {
  local f pid; f="$(watch_file "$1")"
  if [ "${LAB_WATCH_SYNC:-0}" = 1 ]; then
    "$LAB_ROOT/bin/lab" watch "$P_NAME" "$SLUG" "$1" </dev/null >>"$f.log" 2>&1 || true; return 0
  fi
  ( cd "$WT" 2>/dev/null || cd /; exec perl -e 'use POSIX (); POSIX::setsid(); exec @ARGV or exit 127' \
      "$LAB_ROOT/bin/lab" watch "$P_NAME" "$SLUG" "$1" </dev/null >>"$f.log" 2>&1 3>&- ) &
  pid=$!; watch_put "$f" pid "$pid"
}
# watch_resume : lab next et lab launch relancent chaque veilleur du couloir prouvé mort, depuis son état (lot 14)
watch_resume() {
  local f br
  for f in "$(watch_dir)"/*; do
    [ -f "$f" ] || continue; case "$f" in *.log|*.records|*.body|*.tmp.*) continue ;; esac
    [ "$(watch_state "$f")" = dead ] || continue
    br="$(watch_get "$f" branch)"; [ -n "$br" ] || continue
    log "watcher of $br dead ($(lang_code "$(watch_get "$f" issue)") since $(watch_get "$f" since)): restarted from its state"
    watch_spawn "$br"; kv WATCH_RESUMED "$br"
  done
}
# watch_summary [couloir] → une ligne par veilleur : « <branche> #<pr> <action> <issue> — <détail> »
watch_summary() {
  local f pr on
  for f in "$(watch_dir "${1:-$SLUG}")"/*; do
    [ -f "$f" ] || continue; case "$f" in *.log|*.records|*.body|*.tmp.*) continue ;; esac
    pr="$(watch_get "$f" pr)"; on="$(watch_get "$f" on_pr)"
    if [ -n "$pr" ]; then pr="#$pr"; elif [ -n "$on" ]; then pr="after #$on"; else pr="$(watch_get "$f" machine)"; fi
    printf '%s %s %s %s — %s\n' "$(watch_get "$f" branch)" "$pr" \
      "$(watch_get "$f" action)" "$(watch_state "$f")" "$(watch_get "$f" detail)"
  done
}
# watch_has_workflows <révision> <tête> <cible> : un workflow de la révision armée peut produire un contrôle sur la PR — pour une
# promotion, la révision est celle de staging qui part (lot 16) ; schedule ou push vers main seuls n'en sont pas (lot 01 de ci-pr)
watch_has_workflows() { ! pr_ci_none "$WT" "$@" 2>/dev/null; }
# watch_retry : la commande qui relance ce veilleur — lab promote pour la promotion staging → main (lot 16), lab merge pour un couloir
watch_retry() { if [ "$SLUG" = "${PROMOTE_LANE:-_promote}" ]; then printf 'lab promote %s --confirm %s' "$P_NAME" "$P_NAME"; else printf 'lab merge %s %s' "$P_NAME" "$SLUG"; fi; }
# watch_refresh <fichier> : veilleur fini en échec dont la PR a été fusionnée ou fermée hors de lui (lot 02 de close-pr-empilee) —
# MERGED → « merged », CLOSED → « failed » nommé ; PR ouverte, gh absent ou en erreur → rien, rc 0. lab status et lab next seulement :
# le hook de démarrage lit le fichier, sans réseau ; armed, waiting et dead (veilleur vivant ou relancé) relisent déjà la PR
watch_refresh() {
  local f="$1" pr view issue; issue="$(watch_get "$f" issue)"
  case "$(lang_code "$issue")" in red|failed|conflict|changed) ;; *) return 0 ;; esac
  # close fusionne lui-même avant de retirer le couloir : son échec garde son remède (revue du lot)
  case "$(watch_get "$f" action)" in merge|promote) ;; *) return 0 ;; esac
  pr="$(watch_get "$f" pr)"; [ -n "$pr" ] && has_gh || return 0
  view="$(pr_view_state "$P_ROOT" "$pr")" || return 0
  # réarmé par lab merge pendant la lecture (jusqu'à 20 s) : le fichier neuf n'est jamais écrasé
  [ "$(watch_get "$f" issue)" = "$issue" ] && [ "$(watch_get "$f" pr)" = "$pr" ] || return 0
  case "$(printf '%s' "$view" | cut -f1)" in
    MERGED) watch_issue "$f" merged "#$pr merged outside the watcher at $(printf '%s' "$view" | cut -f2 | cut -c1-12)" ;;
    CLOSED) case "$(watch_get "$f" detail)" in "#$pr closed without merge"*) ;; *) watch_issue "$f" failed "#$pr closed without merge outside the watcher" ;; esac ;;
  esac
  return 0
}
watch_refresh_lane() { # [couloir] : watch_refresh sur chaque veilleur du couloir
  local f; for f in "$(watch_dir "${1:-$SLUG}")"/*; do
    [ -f "$f" ] || continue; case "$f" in *.log|*.records|*.body|*.tmp.*) continue ;; esac
    watch_refresh "$f"
  done
}
watch_status_kv() { # <couloir> : WATCHER=… par veilleur, PR fusionnée hors du veilleur relue d'abord
  local line; watch_refresh_lane "$1"
  while IFS= read -r line; do [ -z "$line" ] || kv WATCHER "$line"; done < <(watch_summary "$1")
}

# ---------- le veilleur lui-même : lab watch <projet> <couloir> <branche> (interne) ----------
cmd_watch() {
  [ "$#" -eq 3 ] || usage
  PROJECT="$1"; SLUG="$2"; load_project "$PROJECT"; WT="$(worktree_path "$SLUG")"
  # promotion (lot 16) : aucun couloir, le checkout principal sert aux lectures de gh et de git, jamais à un commit ni un checkout
  [ "$SLUG" != "${PROMOTE_LANE:-_promote}" ] || WT="$P_ROOT"
  WATCH_BRANCH="$3"; WATCH_FILE="$(watch_file "$3")"; [ -f "$WATCH_FILE" ] || die "no watcher armed for $3"
  watch_put "$WATCH_FILE" pid "$$"; WATCH_SELF=$$
  trap 'exit 143' TERM HUP INT   # tué : l'issue reste armée, pid mort → « mort », relancé par lab next
  trap 'watch_on_exit $?' EXIT
  export LAB_CHECKS_TIMEOUT="${LAB_WATCH_TIMEOUT:-10800}"
  # des workflows existent mais aucun contrôle n'est apparu : le veilleur attend jusqu'à son échéance, jamais « none » au bout de 90 s
  export LAB_CHECKS_GRACE="${LAB_WATCH_TIMEOUT:-10800}"
  log "watcher $(date -u +%Y-%m-%dT%H:%M:%SZ) pid $$: $(watch_get "$WATCH_FILE" action) of $3"
  [ "$(watch_get "$WATCH_FILE" action)" != chain ] || watch_chain || return 0
  case "$(watch_get "$WATCH_FILE" action)" in
    merge|promote) watch_merge ;;
    close) watch_close ;;
    cloud) watch_cloud ;;   # lib/cloud.sh
    file) watch_cloud_queue ;;   # lib/cloud.sh, lot 05
    *) die "unknown watcher action: $(watch_get "$WATCH_FILE" action)" ;;
  esac
}
# watch_on_exit <code> : une sortie en erreur (die) pendant armé ou attente devient « échec » avec le dernier message d'erreur
watch_on_exit() {
  local rc="$1" msg
  case "$rc" in 0|129|130|143) return 0 ;; esac
  case "$(lang_code "$(watch_get "$WATCH_FILE" issue)")" in
    armed|waiting)
      msg="$(grep -E "^$DIE_READ" "$WATCH_FILE.log" 2>/dev/null | tail -1 | sed -E "s/^$DIE_READ//")"
      watch_issue "$WATCH_FILE" failed "${msg:-unexpected stop (code $rc)} — nothing else done; log $WATCH_FILE.log" ;;
  esac
}
watch_poll() { sleep "${LAB_WATCH_POLL:-30}"; }
# watch_merge : attend la CI de la PR, puis fusionne à la révision armée — jamais une autre
watch_merge() {
  local f="$WATCH_FILE" pr sha method view st head checks deadline red base note="" rr why
  pr="$(watch_get "$f" pr)"; sha="$(watch_get "$f" sha)"; method="$(watch_get "$f" method)"
  base="$(watch_get "$f" base)"
  red="lab next $P_NAME $SLUG opens the fix"
  [ "$(watch_get "$f" action)" != promote ] || red="fix staging with a PR, then run $(watch_retry) again"
  deadline=$((SECONDS + ${LAB_WATCH_TIMEOUT:-10800}))
  while :; do
    view="$(pr_view_state "$WT" "$pr")" || view=""
    st="$(printf '%s' "$view" | cut -f1)"; head="$(printf '%s' "$view" | cut -f2)"
    case "$st" in
      MERGED) watch_issue "$f" merged "#$pr merged at ${sha:0:12}$note"; git -C "$WT" fetch --quiet "$P_REMOTE" 2>/dev/null || true
              deploy_note_merged "$WATCH_BRANCH" "${base:-$P_BASE}" || true; return 0 ;;
      CLOSED) watch_issue "$f" failed "#$pr closed without merge: nothing done"; return 0 ;;
      OPEN)
        [ "$head" = "$sha" ] || { watch_issue "$f" changed "#$pr is at ${head:0:12}, armed at ${sha:0:12}: no merge — run $(watch_retry) again"; return 0; }
        checks="$(pr_checks_wait "$WT" "$pr" "$sha" "$WATCH_BRANCH" "$base")"; log "checks of #$pr: $checks"
        # des workflows de demande de fusion existent mais aucun contrôle n'est apparu : jamais une fusion « sans contrôle » (revue du lot 14)
        if [ "$checks" = none ] && watch_has_workflows "$sha" "$WATCH_BRANCH" "$base"; then checks=pending; fi
        if [ "$checks" = none ]; then
          note=" — CI=none (no pull request workflow)"; log "CI of #$pr: none (no pull request workflow): merging without waiting"
          watch_put "$f" detail "#$pr: CI=none (no pull request workflow), merge in progress"
        fi
        case "$checks" in
          green|none)
            # promotion : le vert de la seule révision de staging ne vaut pas CI de la PR tant qu'elle peut encore apparaître (lot 16)
            local ready=0
            if [ "$checks" = green ] && [ "$(watch_get "$f" action)" = promote ]; then
              promote_pr_ci_ready "$WT" "$pr" "$(watch_get "$f" armed_at)" || ready=$?
            fi
            case "$ready" in
              2) watch_issue "$f" red "CI of #$pr failed or cancelled at ${sha:0:12}: no merge — $red"; return 0 ;;
              1) log "CI of PR #$pr not there yet or not green yet: still waiting"
                 [ "$SECONDS" -lt "$deadline" ] || { watch_issue "$f" failed "#$pr not merged after ${LAB_WATCH_TIMEOUT:-10800} s (PR CI never green): nothing done"; return 0; }
                 watch_poll; continue ;;
            esac
            # la base a pu avancer depuis l'armement : essai à blanc et régression refaits sur elle, fraîche (lot 03 de mise-en-ligne)
            if [ "$(watch_get "$f" action)" = merge ]; then
              rr=0; watch_recheck "$f" "$sha" "${base:-$(pr_base)}" || rr=$?
              case "$rr" in
                1) return 0 ;;
                2) [ "$SECONDS" -lt "$deadline" ] || { watch_issue "$f" failed "#$pr not merged: fresh base unreadable until the deadline (offline?) — run $(watch_retry) again"; return 0; }
                   watch_poll; continue ;;
              esac
            fi
            pr_merge_exact "$WT" "$pr" "$sha" "$method" || { watch_issue "$f" failed "merge of #$pr refused by GitHub (conflict, rights or changed revision): run $(watch_retry) again"; return 0; }
            continue ;;   # relu : MERGED prouve la fusion
          red)   # gh sorti en erreur (veille, réseau) n'est pas un rouge : confirmé par une lecture qui nomme un échec
            # un reste de brouillon jamais remplacé nomme workflow et remède (couloir veilleur-saute) : l'issue le reprend
            : >"$f.tmp.note" 2>/dev/null || true
            if [ "$(LAB_CHECKS_NOTE="$f.tmp.note" pr_checks_now "$WT" "$pr" "$sha" "$WATCH_BRANCH" "$base")" = red ]; then
              why="$(sed -n '1s/^PR #[0-9]*: //p' "$f.tmp.note" 2>/dev/null)"; rm -f "$f.tmp.note"
              watch_issue "$f" red "red CI of #$pr at ${sha:0:12}: no merge — ${why:-$red}"; return 0
            fi
            rm -f "$f.tmp.note"
            log "checks of #$pr unreadable (gh error), no failure named: still waiting" ;;
        esac
        ;;
    esac
    [ "$SECONDS" -lt "$deadline" ] || { watch_issue "$f" failed "#$pr not merged after ${LAB_WATCH_TIMEOUT:-10800} s (${st:-PR unreadable}): nothing done"; return 0; }
    watch_poll
  done
}
# watch_close : la fermeture confirmée de lab close, reprise telle quelle après la CI verte (close_finish revérifie tout)
# shellcheck disable=SC2034 # CLOSE_RETIRE et CLOSE_CONFIRMED sont lus par close_recheck (lib/close.sh)
watch_close() {
  local f="$WATCH_FILE"
  LAB_WATCH_SESSION="$(watch_get "$f" session)"; export LAB_WATCH_SESSION   # lu par close_session_guard
  CLOSE_CONFIRMED=1   # fermeture déjà confirmée à l'armement
  CLOSE_RETIRE=(); read -r -a CLOSE_RETIRE <<<"$(watch_get "$f" retire)" || true   # --retire de lab close, pour close_recheck
  close_finish "$(watch_get "$f" head)" "$(watch_get "$f" base)" "$(cat "$f.records")" "$(watch_get "$f" document)" \
    "$(watch_get "$f" ws)" "$(watch_get "$f" surface)" "$(watch_get "$f" name)"
  watch_issue "$f" closed "#$(watch_get "$f" pr) merged, lane $SLUG removed${CLOSE_CI_NOTE:-}"
  # fermeture seule de la tour (lot 08 d'autonomie-tours) : la fermeture réelle est notifiée, avec la révision livrée
  [ "$(watch_get "$f" alone)" != 1 ] || close_alone_notify "closed alone: $SLUG delivered at $(watch_get "$f" head | cut -c1-7) by #$(watch_get "$f" pr) — acceptance, served revision verified, prod check green"
  [ "$(watch_get "$f" words)" != 1 ] || close_words_notify "closed on the user's words: $SLUG delivered at $(watch_get "$f" head | cut -c1-7) by #$(watch_get "$f" pr)"
  close_caller_tab
}
# watch_chain : lot empilé mis en file par lab merge — attend la fusion du lot d'en dessous, le replace sur la base, le pousse (jamais
# forcé : il n'a jamais été poussé), ouvre sa PR brouillon, la passe « prête » et devient un veilleur de fusion ordinaire
watch_chain() {
  local f="$WATCH_FILE" onpr st deadline url num
  onpr="$(watch_get "$f" on_pr)"; deadline=$((SECONDS + ${LAB_WATCH_TIMEOUT:-10800}))
  while :; do
    st="$(pr_view_state "$WT" "$onpr" | cut -f1)" || st=""
    case "$st" in
      MERGED) break ;;
      CLOSED) watch_issue "$f" failed "#$onpr closed without merge: $WATCH_BRANCH stays stacked, nothing pushed"; return 1 ;;
    esac
    [ "$SECONDS" -lt "$deadline" ] || { watch_issue "$f" failed "#$onpr not merged after ${LAB_WATCH_TIMEOUT:-10800} s: nothing pushed"; return 1; }
    watch_poll
  done
  # une correction de N peut être en cours dans le couloir : attendre son retour sur la branche empilée, propre (revue du lot 14)
  while [ "$(branch_name "$WT")" != "$WATCH_BRANCH" ] || ! dirty_report "$WT"; do   # des non suivis seuls n'empêchent rien (lot 17)
    [ "$SECONDS" -lt "$deadline" ] || { watch_issue "$f" failed "#$onpr merged, but the lane did not come back clean on $WATCH_BRANCH: nothing pushed"; return 1; }
    watch_poll
  done
  # le sommet de N sous N+1 se relit dans la méta : un retour après correction de N l'a déplacé
  stack_replace "$WATCH_BRANCH" "$(wt_meta "$WT" stack_tip || true)" || { watch_issue "$f" conflict "$STACK_REASON"; return 1; }
  git -C "$WT" push --quiet -u "$P_REMOTE" "$WATCH_BRANCH" || { watch_issue "$f" failed "push of $WATCH_BRANCH refused: nothing else done"; return 1; }
  url="$(cd "$WT" && with_timeout 60 gh pr create --draft --base "$(watch_get "$f" base)" --head "$WATCH_BRANCH" \
    --title "$(watch_get "$f" title)" --body-file "$f.body")" || { watch_issue "$f" failed "gh pr create refused for $WATCH_BRANCH (pushed)"; return 1; }
  num="$(printf '%s' "$url" | sed -n 's|.*/pull/\([0-9]*\).*|\1|p; s|.*/pr/\([0-9]*\).*|\1|p' | head -1)"
  [ -n "$num" ] || { watch_issue "$f" failed "PR number unreadable ($url)"; return 1; }
  pr_make_ready "$WT" "$num" >/dev/null
  watch_put "$f" pr "$num"; watch_put "$f" sha "$(git -C "$WT" rev-parse "$WATCH_BRANCH")"; watch_put "$f" action merge
  watch_put "$f" start "$(wt_meta "$WT" start)"   # départ du lot replacé : la régression hors couloir se revérifie aussi ici (revue, lot 03 de mise-en-ligne)
  watch_issue "$f" armed "rebased after #$onpr, PR #$num opened: waiting for the CI"
  log "chain: $WATCH_BRANCH rebased on $P_REMOTE/$(watch_get "$f" base), PR #$num"
}
# stack_replace <branche> <ancien sommet du lot d'en dessous> [relance] : rebase --onto de la base distante, après la fusion du lot
# d'en dessous ; conflit → rebase annulé, branche intacte, STACK_REASON nommé (avec la commande de relance) ; rc 1 ; non suivis que
# la base écraserait → rien tenté, rc 2
stack_replace() {
  local br="$1" tip="$2" again="${3:-lab merge $P_NAME $SLUG}" base; base="$(wt_meta "$WT" base)"; base="${base:-$(pr_base)}"; STACK_REASON=""
  [ -n "$tip" ] || tip="$(watch_get "${WATCH_FILE:-}" tip)"
  [ -n "$tip" ] || { STACK_REASON="tip of the batch below unknown (empty stack_tip meta): $br not rebased"; return 1; }
  git -C "$WT" fetch --quiet "$P_REMOTE" || { STACK_REASON="fetch $P_REMOTE failed: $br stays stacked"; return 1; }
  untracked_warn "$WT" "rebase continues" || { STACK_REASON="tracked file(s) modified ($(dirty_tracked_list)): $br not rebased, nothing pushed"; return 1; }
  local clash; clash="$(untracked_clash "$WT" "$P_REMOTE/$base")"   # git refuserait le rebase : jamais présenté comme un conflit (revue du lot 17)
  [ -z "$clash" ] || { STACK_REASON="untracked file(s) the base would overwrite: $clash — move or commit them, $br not rebased"; return 2; }
  [ "$(branch_name "$WT")" = "$br" ] || { STACK_REASON="the lane is no longer on $br: nothing rebased"; return 1; }
  # déjà replacée à la main (session de correction d'un conflit) : l'ancien sommet n'est plus dessous, la base l'est — méta vidée seule
  if git -C "$WT" merge-base --is-ancestor "$P_REMOTE/$base" "$br" 2>/dev/null && ! git -C "$WT" merge-base --is-ancestor "$tip" "$br" 2>/dev/null; then :
  elif ! git -C "$WT" rebase --quiet --onto "$P_REMOTE/$base" "$tip" "$br" >/dev/null 2>&1; then
    git -C "$WT" rebase --abort >/dev/null 2>&1 || true
    STACK_REASON="conflict while rebasing $br on $P_REMOTE/$base: rebase aborted, $br untouched — resolve it in a session (git rebase --onto $P_REMOTE/$base ${tip:0:12} $br), then run $again"
    return 1
  fi
  meta_set "$WT" stacked_on ""; meta_set "$WT" stacked_pr ""; meta_set "$WT" stack_tip ""; meta_set "$WT" stack_branch ""
  meta_set "$WT" start "$(git -C "$WT" rev-parse "$P_REMOTE/$base")"
}
# stack_merged_below : la fusion du lot d'en dessous est prouvée — issue « fusionnée » de son veilleur, PR MERGED lue par gh, ou
# branch_merged (ancêtre de la base, squash reconnu sans gh) ; sinon rc 1, rien conclu
stack_merged_below() {
  local on onpr; on="$(wt_meta "$WT" stacked_on)"; onpr="$(wt_meta "$WT" stacked_pr)"; STACK_PROOF=""
  [ -n "$on" ] || return 1
  if [ "$(lang_code "$(watch_get "$(watch_file "$on")" issue)")" = merged ]; then STACK_PROOF="watcher of $on: merged"; return 0; fi
  if [ -n "$onpr" ] && has_gh && [ "$(pr_view_state "$WT" "$onpr" | cut -f1)" = MERGED ]; then STACK_PROOF="PR #$onpr MERGED"; return 0; fi
  if has_local_branch "$WT" "$on" && branch_merged "$P_ROOT" "$on" "$P_BASE" "$P_STAGING" ""; then STACK_PROOF="$on $MERGED_BY"; return 0; fi
  return 1
}
# stack_follow <relance> : branche du dessus, lot d'en dessous fusionné → replacée sur la base distante sans rien pousser (lot 17) ;
# rien à faire (pas empilée, correction de N en cours, veilleur de chaîne actif, hors ligne, fusion non prouvée) → rc 0 sans rien
# toucher, STACK_NOTE dit pourquoi ; conflit → rc 1, non suivis écrasés → rc 2, branche intacte, STACK_REASON nommé
# shellcheck disable=SC2034 # STACK_NOTE est lu par sync_lane
stack_follow() {
  local br f; STACK_REASON=""; STACK_NOTE=""
  sync_stacked "$WT" || return 0
  # correction de N en cours : stack_return décide, jamais ce replacement
  [ -z "$(wt_meta "$WT" return_to)" ] || { STACK_NOTE="fix of $(wt_meta "$WT" stacked_on) in progress: lab next goes back to it first"; return 0; }
  br="$(branch_name "$WT")"; f="$(watch_file "$br")"
  # lab merge l'a mise en file : son veilleur de chaîne la replacera, la poussera et ouvrira sa PR — deux replacements se croiseraient
  if [ "$(watch_get "$f" action)" = chain ]; then
    case "$(watch_state "$f")" in waiting|dead) STACK_NOTE="queued by lab merge: its watcher will rebase and push it"; return 0 ;; esac
  fi
  with_timeout "${LAB_SYNC_TIMEOUT:-30}" git -C "$WT" fetch --quiet "$P_REMOTE" 2>/dev/null \
    || { STACK_NOTE="offline: merge of $(wt_meta "$WT" stacked_on) not checked"; return 0; }
  stack_merged_below || { STACK_NOTE="$(wt_meta "$WT" stacked_on) not merged yet: lab next, lab launch and lab sync will rebase this branch once it is"; return 0; }
  stack_replace "$br" "$(wt_meta "$WT" stack_tip)" "$1" || return $?
  kv STACK_REPLACED "$br"
  log "$br rebased on $P_REMOTE/$(pr_base) ($STACK_PROOF): nothing pushed, the branch is no longer stacked"
}
# watch_recheck <fichier> <sha> <base> : juste avant la fusion, fetch de la base puis essai à blanc et contrôle de régression de la
# révision armée sur elle (lot 03 de mise-en-ligne). rc 0 : fusion permise ; 1 : conflit ou régression, issue « échec » nommée ;
# 2 : base fraîche illisible (hors ligne), la fusion attend. Départ du lot inconnu (veilleur armé avant 0.6.0) : conflit seul vérifié.
watch_recheck() {
  local f="$1" sha="$2" ref="$P_REMOTE/$3" rc=0; local -a retire=()
  with_timeout "${LAB_SYNC_TIMEOUT:-30}" git -C "$WT" fetch --quiet "$P_REMOTE" "$3" 2>/dev/null \
    || { log "fetch of $ref failed (offline?): merge postponed, never on a base not checked again"; return 2; }
  sync_dry "$WT" "$ref" "$sha" || rc=$?
  case "$rc" in
    1) watch_issue "$f" failed "conflict with $ref appeared after arming on $(printf '%s\n' "$SYNC_FILES" | sync_join): no merge — lab sync $P_NAME $SLUG, resolve with git merge, push, then run $(watch_retry) again"; return 1 ;;
    2) log "dry run impossible ($ref missing or git < 2.38): merge not checked again" ;;
  esac
  read -r -a retire <<<"$(watch_get "$f" retire)"
  rc=0; merge_regression "$WT" "$ref" "$(watch_get "$f" start)" "$sha" "${retire[@]+"${retire[@]}"}" || rc=$?
  case "$rc" in
    1) watch_issue "$f" failed "regression outside the lane on $ref: the merge would remove $(printf '%s\n' "$REGRESSION_LIST" | paste -sd ';' - | sed 's/;/ ; /g') — no merge; restore these lines, or for an intended removal: $(watch_retry) --retire <sha>"; return 1 ;;
    2) log "regression check not possible (batch start unknown): only conflicts checked again" ;;
  esac
  rc=0; migrations_collide "$WT" "$ref" "$sha" || rc=$?
  case "$rc" in
    1) watch_issue "$f" failed "migration collision on $ref: $(migrations_brief) — no merge; rename (git mv), commit and push, then run $(watch_retry) again"; return 1 ;;
    2) log "migration check not possible ($ref unreadable)" ;;
  esac
  log "fresh base $ref checked again: no conflict, no regression"
  return 0
}

# ---------- lot empilé (lot 14) : lab next ouvre N+1 par-dessus N non fusionné ----------
# Méta du couloir : stacked_on (branche de N), stacked_pr, stack_tip (sommet de N sous N+1), stack_branch (N+1) ; pendant une
# correction de N : return_to (N+1) et return_wip (1 si un commit d'attente a été posé sur N+1).
# stack_check : avant toute déduction de lab next. STACK_SESSION=1 : une session de correction vient d'être ouverte, rien d'autre à
# faire (un rc 1 appelé dans un || coupait errexit dans toute la session de correction : un die de substitution y rendait 0 — lot 17)
# shellcheck disable=SC2034 # STACK_SESSION est lu par cmd_next (bin/lab), STACK_NOTE par sync_lane
stack_check() {
  local br ret on; STACK_SESSION=0
  br="$(branch_name "$WT")"; ret="$(wt_meta "$WT" return_to)"; on="$(wt_meta "$WT" stacked_on)"
  if [ -n "$ret" ] && [ "$br" != "$ret" ]; then stack_return; return 0; fi
  [ -n "$on" ] && [ "$(wt_meta "$WT" stack_branch)" = "$br" ] || return 0
  if [ "$(watch_state "$(watch_file "$on")")" = red ]; then ci_red_session "$on"; STACK_SESSION=1; return 0; fi
  # lot d'en dessous fusionné : replacée ici (lot 17) ; un conflit n'arrête pas lab next, la synchronisation de lab launch le reprend
  stack_follow "lab next $P_NAME $SLUG" || warn "$STACK_REASON"
  return 0
}
# ci_red_session <branche de N> : la CI de N est rouge. Depuis N+1, un commit d'attente garde son travail, le couloir bascule sur N ;
# une session de correction s'ouvre, une seule fois par révision rouge. Elle corrige, pousse, relance lab merge, puis lab next,
# qui revient sur N+1 replacé sur N corrigé (stack_return).
ci_red_session() {
  local on="$1" f br lot base key sha msg previous tab=$'\t' wip=0
  f="$(watch_file "$on")"; br="$(branch_name "$WT")"; sha="$(watch_get "$f" sha)"; key="ci-red-${sha:0:12}"
  lot="$(wt_lot_file "$WT")"; base="$(basename "$lot" .md)"
  msg="red CI of PR #$(watch_get "$f" pr) on $on at ${sha:0:12}"
  # clé d'un lab d'avant le lot 09 : « ci-rouge-<sha> » vaut « ci-red-<sha> », la session de correction ne se rouvre pas
  previous="$(awk -F'\t' -v k="$key" -v o="ci-rouge-${sha:0:12}" -v b="$base" '($1 == k || $1 == o) && $2 == b {print $3; exit}' "$(correction_file)" 2>/dev/null || true)"
  [ -z "$previous" ] || die "$msg — a fix session was already opened for this revision ($previous): fix on $on, push, lab merge $P_NAME $SLUG, then run lab next $P_NAME $SLUG again"
  if [ "$br" != "$on" ]; then
    if ! is_clean "$WT"; then
      { git -C "$WT" add -A && git -C "$WT" commit --quiet -m "chore(wip): waiting — CI fix of $on"; } || die "waiting commit refused on $br: nothing switched"
      wip=1
    fi
    meta_set "$WT" return_to "$br"; meta_set "$WT" return_wip "$wip"
    local kept=""; [ "$wip" = 0 ] || kept=" (waiting commit made)"
    git -C "$WT" switch --quiet "$on" || die "switch to $on refused: $br kept$kept"
    log "red CI of $on: $br set aside$kept, lane switched to $on to fix it"
  fi
  mkdir -p "$WT/.lab"; ( umask 077; printf '%s\n' "$key$tab$base$tab$(rdv_now 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)$tab$msg" >>"$(correction_file)" )
  kv CI_RED "$on"; warn "$msg: fix session on $on"
  open_fresh_session "$AGENT" correction "$lot"
}
# stack_return : N corrigé et relivré (veilleur réarmé) → retour sur N+1, replacé localement sur le nouveau sommet de N, commit
# d'attente défait (reset --soft : le travail revient tel quel, non enregistré)
stack_return() {
  local ret on tip wip newtip st
  ret="$(wt_meta "$WT" return_to)"; on="$(wt_meta "$WT" stacked_on)"; tip="$(wt_meta "$WT" stack_tip)"; wip="$(wt_meta "$WT" return_wip)"
  st="$(watch_state "$(watch_file "$on")")"
  case "$st" in
    armed|waiting|merged|dead) ;;
    *) die "cannot go back to $ret: the watcher of $on is \"${st:-absent}\" — fix on $on, push, run lab merge $P_NAME $SLUG, then run lab next $P_NAME $SLUG again" ;;
  esac
  untracked_warn "$WT" "return continues" || die "uncommitted changes on $(branch_name "$WT") ($(dirty_tracked_list)): commit the fix of $on before going back to $ret"
  git -C "$WT" switch --quiet "$ret" || die "return to $ret refused"
  newtip="$(git -C "$WT" rev-parse "$on")"
  if [ "$newtip" != "$tip" ]; then
    if ! git -C "$WT" rebase --quiet --onto "$on" "$tip" "$ret" >/dev/null 2>&1; then
      git -C "$WT" rebase --abort >/dev/null 2>&1 || true
      die "conflict while rebasing $ret on the fixed $on: rebase aborted, $ret untouched — git -C $WT rebase --onto $on ${tip:0:12} $ret in a session, then run lab next $P_NAME $SLUG again"
    fi
    meta_set "$WT" stack_tip "$newtip"
  fi
  if [ "$wip" = 1 ] && git -C "$WT" log -1 --format=%s | grep -Eq '^chore\(wip\): (waiting|attente)'; then   # attente : commit d'un lab d'avant le lot 03 du couloir anglais
    git -C "$WT" reset --quiet --soft HEAD~1 && git -C "$WT" reset --quiet
  fi
  meta_set "$WT" return_to ""; meta_set "$WT" return_wip ""
  kv RETURNED "$ret"; log "back on $ret, rebased on $on (${newtip:0:12})"
}
