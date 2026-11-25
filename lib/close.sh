# shellcheck shell=bash
# Fermeture explicite : les variables CLOSE_* vivent dans cette seule commande.
# Aucune copie durable de la recette ou de la phase du couloir.

close_recette_guard() {
  close_permanent_guard; close_waiting_guard; close_dirty_guard; close_end_guard; close_recette_check; close_session_guard
}
# close_waiting_guard : une mesure du couloir attend sa date — rien n'est livré ni retiré avant elle (lot 02 d'autonomie-tours)
close_waiting_guard() { wait_block "$WT"; }
# close_permanent_guard : un couloir permanent n'est jamais fermé ni abandonné (lot 01 d'autonomie-tours) ; le remède le rend ordinaire
close_permanent_guard() {
  ! lane_permanent "$WT" || die "permanent lane $SLUG, never closed: lab permanent $P_NAME $SLUG off first"   # < 80 colonnes, préfixe compris
}
# Les gardes de fermeture, une par obstacle : lab close s'arrête à la première, lab close --dry-run les joue toutes (close_obstacles).
close_dirty_guard() {
  is_clean "$WT" || { dirty_report "$WT" || true; die "uncommitted or untracked changes ($DIRTY_LIST): commit or remove them, then resume the acceptance with lab next $P_NAME $SLUG"; }
}
close_end_guard() {
  local lot; lot="$(wt_lot_file "$WT")"
  [ "$(lane_last_lot "$WT" "$lot")" = yes ] && lane_lots_closed "$WT" "$lot" \
    && [ "$(reprise_next_lot "$(extract_reprise "$lot")")" = none ] \
    || die "end of the lane unclear: finish the planned batches, then lab next $P_NAME $SLUG"
}
close_recette_check() {
  local lot status
  lot="$(wt_lot_file "$WT")"
  status="$(recette_status "$WT" "$lot")"
  case "$status" in
    valid) ;;
    absent) die "acceptance missing: try the result with lab next $P_NAME $SLUG" ;;
    rejected) die "acceptance rejected: work through the feedback with lab next $P_NAME $SLUG" ;;
    expired) local stale; stale="$(recette_stale_files "$WT" "$lot")"
             # seul --dry-run arrive ici avec des fichiers sales : ils périment la recette, sans autre fichier du couloir changé
             [ -n "$stale" ] || is_clean "$WT" || die "acceptance to check again: uncommitted changes make it stale; commit or remove them first"
             die "acceptance stale: the result has changed${stale:+ (lane files: $stale)}; try it again with lab next $P_NAME $SLUG" ;;
    unversioned)
      # lab a tenté l'enregistrement juste avant (docs_commit) : un refus git se cite, l'agent n'a rien à deviner (lot 03)
      [ "${DOCS_COMMIT_RESULT:-}" = failed ] && die "acceptance not versioned — git refused to commit the batch files: $DOCS_COMMIT_REASON; fix it, then run lab close $P_NAME $SLUG again"
      die "acceptance not versioned: commit the batch file in its documents repository, then lab next $P_NAME $SLUG" ;;
    *) die "acceptance incomplete: $(recette_incomplete_detail "$WT" "$lot"); complete the section, then lab next $P_NAME $SLUG" ;;
  esac
}
close_session_guard() { # aucune autre session vivante — ni indéterminable : rien n'est retiré sur un doute (lot 02)
  local held; held="$(lock_field "$(lock_file "$WT")" pid 2>/dev/null || true)"
  # le veilleur de close (lot 14) retient la session qui a confirmé : elle n'est pas « une autre session »
  [ -z "$held" ] || pid_dead "$held" || session_owned_here "$WT" || [ "$held" = "${LAB_WATCH_SESSION:-}" ] \
    || die "another live session (pid $held): go back to its tab before closing $SLUG"
}
# Backticks Markdown littéraux dans l’expression régulière.
# shellcheck disable=SC2016
close_branch_of() { [ -f "${1:-}" ] || return 0; lang_norm <"$1" | sed -n 's/^\*\*Branche\*\* *: *`\([^`]*\)`.*/\1/p'; }   # fiche absente : vide
close_branch_elsewhere() { # <branche> → rc 0 si un autre worktree que celui du couloir l'a en cours
  git -C "$WT" worktree list --porcelain | awk -v own="$WT" -v br="refs/heads/$1" '
    /^worktree / {p=substr($0,10)} /^branch / && substr($0,8)==br && p!=own {found=1} END {exit !found}'
}
close_pr_read() { # actualise la PR exacte, sans interpréter un échec comme une absence
  local data
  data="$(with_timeout 20 gh api "repos/$CLOSE_REPO/pulls/$CLOSE_NUM")" \
    || die "PR #$CLOSE_NUM unreadable: lane kept; run lab close $P_NAME $SLUG again"
  CLOSE_PR_HEAD="$(printf '%s' "$data" | jq -er '.head.sha')" || die "PR revision unreadable"
  CLOSE_PR_BASE="$(printf '%s' "$data" | jq -er '.base.ref')" || die "PR target unreadable"
  CLOSE_PR_STATE="$(printf '%s' "$data" | jq -er 'if .merged == true then "MERGED" else .state | ascii_upcase end')" || die "PR state unreadable"
  CLOSE_MERGED="$(printf '%s' "$data" | jq -r '.merge_commit_sha // empty')"
}
close_collect_branches() { # branche<TAB>révision<TAB>PR ou -<TAB>état[<TAB>#PR qui l’a livrée empilée, ou note des commits après fusion<TAB>tête fusionnée]
  local names name file branch head local_head remote_head rc start rel info number state current_num="${CLOSE_NUM:--}" seen=""
  local out="" absorbers="" record by ahead anum t=$'\t' empty=0 late note pr_head
  [ "$CLOSE_PR_STATE" != EMPTY ] || empty=1   # lu avant la boucle : close_pr_read des anciens lots réécrit CLOSE_PR_STATE
  names="$(lane_plan_names "$WT")"; [ -n "$names" ] || names="$(basename "$CLOSE_LOT" .md)"
  while IFS= read -r name; do
    file="$(lots_dir "$(docs_dir "$WT")" "$SLUG")/$name.md"
    [ -f "$file" ] || file="$(lots_dir "$(docs_dir "$WT")")/$name.md"
    branch="$(close_branch_of "$file")"
    case "$branch" in feat/*|fix/*|chore/*) ;; *) die "branch unreadable in $name: nothing removed" ;; esac
    valid_slug "${branch#*/}" || die "invalid branch in $name"
    case "$name" in lot-*-"${branch#*/}") ;; *) die "branch does not match $name: nothing removed" ;; esac
    grep -Fxq "$branch" <<<"$seen" && die "branch $branch announced by two batches: nothing removed"
    seen="$seen
$branch"
    if [ "$branch" = "$CLOSE_BRANCH" ]; then
      out="$out$branch$t$CLOSE_HEAD$t$current_num${t}current
"
      continue
    fi
    local_head="$(git -C "$WT" rev-parse --verify "refs/heads/$branch" 2>/dev/null || true)"
    rc=0; remote_head="$(git -C "$WT" ls-remote --exit-code "$P_REMOTE" "refs/heads/$branch")" || rc=$?
    case "$rc" in 0|2) ;; *) die "old branch $branch cannot be checked: lane kept" ;; esac
    remote_head="${remote_head%%$'\t'*}"; head="${local_head:-$remote_head}"
    [ -n "$head" ] || continue
    # Une branche peut avoir été recréée ailleurs sous le même nom. La fiche
    # doit avoir été introduite après sa création, pas héritée de sa base.
    case "$file" in
      "$WT"/*)
        rel="${file#"$WT"/}"; start="$(branch_start "$WT" "$branch")"
        if [ -z "$start" ] || git -C "$WT" cat-file -e "$start:$rel" 2>/dev/null \
          || ! git -C "$WT" cat-file -e "$head:$rel" 2>/dev/null; then
          warn "branch $branch kept: not proven to belong to the lane"; continue
        fi ;;
      *)
        # Documents externes : le prédécesseur direct d’un fix est encore
        # prouvé par le commit de départ, sans ajouter un historique parallèle.
        # lot vide (lot 01 de close-lot-vide) : le lot suivant part de la base, la tête d'un ancien lot n'y est donc jamais ; sa PR
        # fusionnée vers la base à cette tête exacte prouve qu'elle ne porte rien de plus — la retirer ne perd rien
        if [ "$head" != "$(wt_meta "$WT" start)" ] \
          && { [ "$empty" = 0 ] || ! info="$(pr_info_strict "$P_ROOT" "$branch")" || [ -z "$info" ] \
               || ! close_old_pr_merged "$(printf '%s' "$info" | cut -f1)" "$head"; }; then
          warn "branch $branch kept: old ownership not proven in the external documents"; continue
        fi ;;
    esac
    [ -z "$local_head" ] || [ -z "$remote_head" ] || [ "$local_head" = "$remote_head" ] \
      || die "local and remote branch $branch differ: nothing removed"
    ! close_branch_elsewhere "$branch" || die "branch $branch used by another lane: nothing removed"
    info="$(pr_info "$P_ROOT" "$branch")"; number=-; state=none; note=""; pr_head=""
    if [ -n "$info" ]; then
      number="$(printf '%s' "$info" | cut -f1)"; CLOSE_NUM="$number"; close_pr_read
      { close_pr_matches "$CLOSE_PR_BASE" && [ "$CLOSE_PR_HEAD" = "$head" ]; } \
        || close_after_merge "$head" \
        || die "PR of $branch does not match the expected branch${CLOSE_STACK_WHY:+ ($CLOSE_STACK_WHY)}: nothing removed"
      state="$CLOSE_PR_STATE"
      if [ "$CLOSE_PR_HEAD" != "$head" ]; then
        late="$(close_late_commits "$head" "$CLOSE_PR_HEAD")"
        [ -z "$late" ] || die "$branch received commits after the merge of PR #$number that are missing from the tried result: $late: nothing removed"
        note="commits after the merge of #$number, delivered by the final PR #$current_num"
        late="$(close_copied_commits "$head" "$CLOSE_PR_HEAD")"; note="$note${late:+; $late}"
        pr_head="$CLOSE_PR_HEAD"
      fi
    fi
    record="$branch$t$head$t$number$t$state${note:+$t$note$t$pr_head}"
    if [ "$state" = MERGED ] && [ -n "$CLOSE_MERGED" ] \
      && git -C "$WT" merge-base --is-ancestor "$CLOSE_MERGED" "$CLOSE_HEAD" 2>/dev/null; then
      absorbers="$absorbers$head$t$number
"
    elif ! git -C "$WT" merge-base --is-ancestor "$head" "$CLOSE_HEAD" 2>/dev/null; then
      record="?$record"   # lot 28 : peut-être livrée empilée dans la PR fusionnée d’un autre lot
    fi
    out="$out$record
"
  done <<<"$names"
  # Seconde passe : une branche en attente est admise si la tête d’un autre lot
  # du couloir, livré par une fusion incluse dans le résultat, la contient.
  while IFS= read -r record; do
    case "$record" in
      '?'*)
        record="${record#?}"; branch="${record%%"$t"*}"; head="$(printf '%s' "$record" | cut -f2)"; by=""
        while IFS=$'\t' read -r ahead anum; do
          [ -n "$ahead" ] && [ "$ahead" != "$head" ] || continue
          if git -C "$WT" merge-base --is-ancestor "$head" "$ahead" 2>/dev/null; then by="$anum"; break; fi
        done <<<"$absorbers"
        [ -n "$by" ] || die "work of $branch not included in the tried result: lane kept"
        printf '%s\t#%s\n' "$record" "$by" ;;
      ?*) printf '%s\n' "$record" ;;
    esac
  done <<<"$out"
}
# close_after_merge <tête de branche> (lot 03 de mcp-sobres) : rc 0 si la PR lue est fusionnée vers la base à une tête ancêtre de la
# branche — des commits ajoutés après la fusion ; l'appelant exige ensuite qu'ils soient dans le résultat essayé
close_after_merge() {
  [ "$CLOSE_PR_STATE" = MERGED ] && [ "$CLOSE_PR_HEAD" != "$1" ] \
    && git -C "$WT" merge-base --is-ancestor "$CLOSE_PR_HEAD" "$1" 2>/dev/null && close_pr_matches "$CLOSE_PR_BASE"
}
# close_late_commits <tête de branche> <tête fusionnée> → « sha12 sujet, … » des commits absents du résultat essayé (5 au plus) ;
# un commit recopié à l'identique (même patch-id, « - » de git cherry) dont le changement y reste est déjà livré (lot 05 de
# ci-sobre) ; git cherry ignore les fusions : toute fusion tardive hors du résultat reste absente
close_late_commits() {
  local list cherry mark sha subject
  if cherry="$(git -C "$WT" cherry -v "$CLOSE_HEAD" "$1" "$2")" \
    && list="$(git -C "$WT" log --min-parents=2 --abbrev=12 --format='%h %s' "$1" "^$2" "^$CLOSE_HEAD" --)"; then
    while read -r mark sha subject; do
      [ -n "$sha" ] || continue
      [ "$mark" = - ] && close_change_kept "$sha" && continue
      list="${list:+$list
}${sha:0:12} $subject"
    done <<<"$cherry"
  else list="$1 (unreadable)"
  fi
  [ -n "$list" ] || return 0
  printf '%s\n' "$list" | awk 'NR <= 5 { s = s (NR > 1 ? ", " : "") $0 } END { print s (NR > 5 ? " and " NR - 5 " more" : "") }'
}
close_change_kept() { # <commit> : rc 0 si son changement s'annule à l'envers sur l'arbre du résultat essayé (pas défait depuis)
  local idx rc=1
  idx="$(mktemp "${TMPDIR:-/tmp}/lab-copie.XXXXXX")" || return 1
  GIT_INDEX_FILE="$idx" git -C "$WT" read-tree "$CLOSE_HEAD" 2>/dev/null \
    && git -C "$WT" diff --binary "$1^" "$1" -- | GIT_INDEX_FILE="$idx" git -C "$WT" apply --cached -R --check 2>/dev/null && rc=0
  rm -f "$idx"; return "$rc"
}
# close_copied_commits <tête de branche> <tête fusionnée> → « orig12 delivered as copie12, … » des commits tardifs recopiés à
# l'identique dans le résultat essayé, appariés par patch-id stable ; rien si aucun
close_copied_commits() {
  local late
  late="$(git -C "$WT" cherry "$CLOSE_HEAD" "$1" "$2" 2>/dev/null | sed -n 's/^- //p')"
  [ -n "$late" ] || return 0
  { printf '%s\n' "$late" | git -C "$WT" log --stdin --no-walk -p --format='commit %H' | git -C "$WT" patch-id --stable | sed 's/^/o /'
    git -C "$WT" log -p --format='commit %H' "$CLOSE_HEAD" "^$1" -- | git -C "$WT" patch-id --stable | sed 's/^/c /'
  } 2>/dev/null | awk '$1 == "o" { o[$2] = $3; n[++k] = $2; next } ($2 in o) && !($2 in c) { c[$2] = $3 }
    END { for (i = 1; i <= k; i++) if (n[i] in c) s = s (s ? ", " : "") substr(o[n[i]], 1, 12) " delivered as " substr(c[n[i]], 1, 12)
          if (s != "") print s }'
}
close_old_pr_merged() { # <numéro> <tête> : rc 0 si la PR est fusionnée vers la base à cette tête exacte ; l'instantané courant reste
  local CLOSE_NUM="$1" CLOSE_PR_HEAD CLOSE_PR_BASE CLOSE_PR_STATE CLOSE_MERGED
  close_pr_read
  [ "$CLOSE_PR_STATE" = MERGED ] && [ "$CLOSE_PR_HEAD" = "$2" ] && close_pr_matches "$CLOSE_PR_BASE"
}
close_redundant_pr() { # <numéro> <head> : ferme une demande incluse, ne la fusionne jamais
  local CLOSE_NUM="$1" CLOSE_PR_HEAD CLOSE_PR_BASE CLOSE_PR_STATE CLOSE_MERGED response
  close_pr_read
  { close_pr_matches "$CLOSE_PR_BASE" && [ "$CLOSE_PR_HEAD" = "$2" ]; } \
    || die "old PR changed${CLOSE_STACK_WHY:+ ($CLOSE_STACK_WHY)}: lane kept"   # une PR empilée livrée est fusionnée : rien à fermer
  if [ "$CLOSE_PR_STATE" = OPEN ]; then
    response="$(with_timeout 30 gh api "repos/$CLOSE_REPO/pulls/$CLOSE_NUM" --method PATCH -f state=closed)" \
      || die "old PR #$CLOSE_NUM not closed: run lab close $P_NAME $SLUG again"
    printf '%s' "$response" | jq -e '.state == "closed"' >/dev/null || die "closing of the old PR not proven"
  fi
}
close_prepare() { # contrôles locaux et instantané distant, aucune mutation
  local problems
  close_recette_guard
  close_branch_check
  close_pr_find
  CLOSE_BILAN=0; CLOSE_STACK=""; CLOSE_DELIVERED=""
  if [ "$CLOSE_PR_STATE" = EMPTY ]; then close_empty_old_lots   # lot vide : rien à fusionner, ni bilan ; les anciens lots livrés
  else
    problems="$(close_pr_problems)" || die "$(printf '%s\n' "$problems" | awk -F '\t' '$1 != "stack" && $1 != "delivered"' | head -1 | cut -f2-)"
    CLOSE_DELIVERED="$(printf '%s\n' "$problems" | awk -F '\t' '$1 == "delivered"' | cut -f2-)"   # fichiers déjà dans la base
    CLOSE_STACK="$(printf '%s\n' "$problems" | awk -F '\t' '$1 == "stack"' | cut -f2-)"   # pile livrée : dite au récapitulatif
    ! close_bilan_wanted || CLOSE_BILAN=1
  fi
  CLOSE_RECORDS="$(close_collect_branches)" || return 1
}
close_branch_values() { # pose CLOSE_LOT, CLOSE_HEAD, CLOSE_BRANCH et CLOSE_BASE, sans rien juger
  CLOSE_LOT="$(wt_lot_file "$WT")"; CLOSE_HEAD="$(git -C "$WT" rev-parse HEAD)"
  CLOSE_BRANCH="$(close_branch_of "$CLOSE_LOT")"; CLOSE_BASE="$(pr_base)"
}
close_branch_check() {
  local branch elsewhere
  close_branch_values
  case "$CLOSE_BRANCH" in feat/*|fix/*|chore/*) ;; *) die "batch branch unreadable: lane kept" ;; esac
  valid_slug "${CLOSE_BRANCH#*/}" || die "invalid batch branch"
  case "$(basename "$CLOSE_LOT")" in lot-*-"${CLOSE_BRANCH#*/}".md) ;; *) die "branch does not match the batch file: lane kept" ;; esac
  branch="$(branch_name "$WT")"
  [ -z "$branch" ] || [ "$branch" = "$CLOSE_BRANCH" ] || die "branch does not match the tried result: redo the acceptance"
  elsewhere="$(git -C "$WT" worktree list --porcelain | awk -v own="$WT" -v branch="refs/heads/$CLOSE_BRANCH" '
    /^worktree / {path=substr($0,10)} /^branch / && substr($0,8)==branch && path!=own {print path}')"
  [ -z "$elsewhere" ] || die "branch used in another lane: nothing removed"
}
close_repo_resolve() { # pose CLOSE_REPO ; rc 1 si GitHub ne le donne pas
  CLOSE_REPO="$(repo_slug "$P_ROOT" "$P_REMOTE" || true)"
  [ -n "$CLOSE_REPO" ] || CLOSE_REPO="$(cd "$WT" && with_timeout 20 gh repo view --json nameWithOwner --jq .nameWithOwner)" || return 1
}
close_pr_find() { # pose CLOSE_NUM, CLOSE_REPO et l'instantané de la PR du lot courant ; lot vide : CLOSE_PR_STATE=EMPTY, sans PR
  local info
  has_gh || die "gh required to check the delivery; lane kept"
  info="$(pr_info "$P_ROOT" "$CLOSE_BRANCH")"
  if [ -z "$info" ]; then   # l'absence de PR se relit stricte : une panne de gh n'est jamais un lot vide
    close_lot_empty fetch || die "$(close_no_pr_message)"
    info="$(pr_info_strict "$P_ROOT" "$CLOSE_BRANCH")" || die "PR of $CLOSE_BRANCH cannot be checked (gh failed or offline): lane kept; run lab close $P_NAME $SLUG again"
  fi
  close_repo_resolve || die "GitHub repository not found"
  [[ "$CLOSE_REPO" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]] || die "GitHub repository unreadable"
  if [ -z "$info" ]; then
    CLOSE_NUM=""; CLOSE_PR_STATE=EMPTY; CLOSE_PR_HEAD="$CLOSE_HEAD"; CLOSE_PR_BASE="$CLOSE_BASE"; CLOSE_MERGED="$CLOSE_HEAD"; return 0
  fi
  CLOSE_NUM="$(printf '%s' "$info" | cut -f1)"
  [[ "$CLOSE_NUM" =~ ^[0-9]+$ ]] || die "PR number unreadable"
  close_pr_read
}
close_no_pr_message() { printf 'no PR for %s: prepare the delivery with the batch-end skill\n' "$CLOSE_BRANCH"; }
# ---------- lot vide (lot 01 de close-lot-vide) : dernier lot sans commit, sa branche déjà contenue dans la base ----------
# GitHub refuse une PR vide : la preuve de livraison est HEAD dans <remote>/<base>, la recette et la confirmation nommée restent exigées.
# close_lot_empty [fetch] : rc 0 si HEAD est contenu dans <remote>/<base> (rev-list <base>..HEAD = 0). fetch : base relue fraîche,
# une base illisible qui semblait contenir HEAD est un refus nommé ; sans fetch (--dry-run) : la dernière lecture locale.
close_lot_empty() {
  local fresh=1 remote rc=0
  [ "${1:-}" != fetch ] || with_timeout "${LAB_SYNC_TIMEOUT:-30}" git -C "$WT" fetch --quiet "$P_REMOTE" "$CLOSE_BASE" 2>/dev/null || fresh=0
  git -C "$WT" merge-base --is-ancestor "$CLOSE_HEAD" "$P_REMOTE/$CLOSE_BASE" 2>/dev/null || return 1
  # la branche distante du lot, absente ou à HEAD : des commits poussés ailleurs ne sont jamais pris pour un lot vide (revue)
  remote="$(git -C "$WT" ls-remote --exit-code "$P_REMOTE" "refs/heads/$CLOSE_BRANCH" 2>/dev/null)" || rc=$?
  case "$rc" in 0) [ "${remote%%$'\t'*}" = "$CLOSE_HEAD" ] || return 1 ;; 2) ;; *) [ "${1:-}" != fetch ] || fresh=0 ;; esac
  [ "$fresh" = 1 ] || die "no PR for $CLOSE_BRANCH and base $P_REMOTE/$CLOSE_BASE unreadable (offline?): empty batch not proven, lane kept; run lab close $P_NAME $SLUG again"
}
# close_empty_old_lots : chaque ancien lot dont la branche existe encore est livré — sa tête dans <remote>/<base>, ou sa PR vers la
# base fusionnée à cette tête ; sinon refus qui le nomme. Même avec des fiches externes, où l'attribution d'une branche n'est pas prouvée.
close_empty_old_lots() {
  local names name file branch head info
  names="$(lane_plan_names "$WT")"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    file="$(lots_dir "$(docs_dir "$WT")" "$SLUG")/$name.md"
    [ -f "$file" ] || file="$(lots_dir "$(docs_dir "$WT")")/$name.md"
    branch="$(close_branch_of "$file")"
    [ -n "$branch" ] && [ "$branch" != "$CLOSE_BRANCH" ] || continue
    head="$(git -C "$WT" rev-parse --verify --quiet "refs/heads/$branch" 2>/dev/null       || git -C "$WT" rev-parse --verify --quiet "refs/remotes/$P_REMOTE/$branch" 2>/dev/null || true)"
    [ -n "$head" ] || continue
    ! git -C "$WT" merge-base --is-ancestor "$head" "$P_REMOTE/$CLOSE_BASE" 2>/dev/null || continue
    info="$(pr_info_strict "$P_ROOT" "$branch")" || die "PR of $branch cannot be checked (gh failed or offline): lane kept"
    [ -z "$info" ] || ! close_old_pr_merged "$(printf '%s' "$info" | cut -f1)" "$head" || continue
    die "batch $name not delivered to $CLOSE_BASE (branch $branch has no PR merged at its head): deliver it with lab merge $P_NAME $SLUG; lane kept"
  done <<<"$names"
}
# ---------- pile de deux PR (lot 01 de close-pr-empilee) : lot → branche intermédiaire, puis intermédiaire → base ----------
# close_stack_check <numéro> <base de la PR> <état> <fusion> : rc 0 si la PR, fusionnée dans la branche intermédiaire, est livrée à la
# base par une PR relais fusionnée et que sa fusion est contenue dans <remote>/<base> — imprime alors la note ; sinon le refus nommé,
# rc 1. Une PR ouverte vers une branche intermédiaire garde le refus d'origine : lab ne fusionne jamais une pile. Branche intermédiaire
# jamais touchée. Chemin réel : base relue fraîche avant de refuser ; --dry-run (CLOSE_DRY) : dernière lecture locale.
close_stack_check() {
  local num="$1" mid="$2" state="$3" merged="$4" info rnum rstate rbase ref="$P_REMOTE/$CLOSE_BASE"
  [ "$state" = MERGED ] || { printf 'PR #%s targets %s, expected destination %s\n' "$num" "$mid" "$CLOSE_BASE"; return 1; }
  info="$(pr_info_strict "$P_ROOT" "$mid")" \
    || { printf 'PR #%s merged into %s: relay PR %s → %s cannot be checked (gh failed or offline); run lab close %s %s again\n' "$num" "$mid" "$mid" "$CLOSE_BASE" "$P_NAME" "$SLUG"; return 1; }
  [ -n "$info" ] \
    || { printf 'PR #%s merged into %s, but no PR %s → %s: deliver %s to %s, then run lab close %s %s again\n' "$num" "$mid" "$mid" "$CLOSE_BASE" "$mid" "$CLOSE_BASE" "$P_NAME" "$SLUG"; return 1; }
  IFS=$'\t' read -r rnum rstate rbase _ <<<"$info"
  [ "$rbase" = "$CLOSE_BASE" ] \
    || { printf 'stack deeper than two levels: PR #%s → %s, PR #%s → %s, expected %s\n' "$num" "$mid" "$rnum" "$rbase" "$CLOSE_BASE"; return 1; }
  [ "$rstate" = MERGED ] \
    || { printf 'PR #%s merged into %s, relay PR #%s (%s → %s) %s: deliver #%s, then run lab close %s %s again\n' "$num" "$mid" "$rnum" "$mid" "$CLOSE_BASE" "$rstate" "$rnum" "$P_NAME" "$SLUG"; return 1; }
  if [ -z "$merged" ] || ! git -C "$WT" merge-base --is-ancestor "$merged" "$ref" 2>/dev/null; then
    if [ -n "$merged" ] && [ "${CLOSE_DRY:-0}" != 1 ]; then   # chemin réel : une base en retard se relit avant tout refus
      with_timeout "${LAB_SYNC_TIMEOUT:-30}" git -C "$WT" fetch --quiet "$P_REMOTE" "$CLOSE_BASE" 2>/dev/null \
        || { printf 'PR #%s merged into %s and relay PR #%s merged, but base %s unreadable (offline?): stack delivery not proven; run lab close %s %s again\n' "$num" "$mid" "$rnum" "$ref" "$P_NAME" "$SLUG"; return 1; }
    fi
    if [ -z "$merged" ] || ! git -C "$WT" merge-base --is-ancestor "$merged" "$ref" 2>/dev/null; then
      printf 'PR #%s merged into %s and relay PR #%s merged, but the merge of #%s is missing from %s%s (relay squashed?): deliver %s to %s by a merge commit, then run lab close %s %s again\n' \
        "$num" "$mid" "$rnum" "$num" "$ref" "${CLOSE_DRY:+ (last local read: git fetch first)}" "$mid" "$CLOSE_BASE" "$P_NAME" "$SLUG"
      return 1
    fi
  fi
  printf 'stack: PR #%s merged into %s, delivered to %s by PR #%s — %s kept\n' "$num" "$mid" "$CLOSE_BASE" "$rnum" "$mid"
}
# close_pr_matches <base de la PR> : rc 0 si la PR (instantané CLOSE_*) vise la base, ou y est livrée par une pile de deux PR ;
# sinon CLOSE_STACK_WHY garde la raison, que l'appelant cite (une panne de gh n'est jamais dite « PR changée »)
close_pr_matches() {
  CLOSE_STACK_WHY=""
  [ "$1" != "$CLOSE_BASE" ] || return 0
  CLOSE_STACK_WHY="$(close_stack_check "$CLOSE_NUM" "$1" "$CLOSE_PR_STATE" "$CLOSE_MERGED")"
}
close_pr_problems() { # → « clé<TAB>message » par écart entre la PR lue et le résultat essayé ; rc 1 s'il y en a
  # une pile livrée n'est pas un écart, ni des fichiers déjà dans la base : leurs lignes « stack<TAB>note » et « delivered<TAB>note »
  # s'impriment avec rc 0, les appelants en font une NOTE
  local rc=0 off stack n
  if [ "$CLOSE_PR_BASE" != "$CLOSE_BASE" ]; then
    if stack="$(close_stack_check "$CLOSE_NUM" "$CLOSE_PR_BASE" "$CLOSE_PR_STATE" "$CLOSE_MERGED")"; then printf 'stack\t%s\n' "${stack#stack: }"
    else printf 'destination\t%s\n' "$stack"; rc=1; fi
  fi
  if [ "$CLOSE_PR_HEAD" != "$CLOSE_HEAD" ]; then
    # lot 01 de close-apres-fusion : PR fusionnée avant la recette, seule la section Recette a suivi → bilan livré par PR dédiée
    if [ "$CLOSE_PR_STATE" = MERGED ] && git -C "$WT" merge-base --is-ancestor "$CLOSE_PR_HEAD" "$CLOSE_HEAD" 2>/dev/null; then
      # lot 01 de close-arbre-livre : chemin réel, base relue fraîche avant de comparer ; --dry-run : dernière lecture locale
      # une ref absente après un fetch réussi (refspec restreinte) est aussi illisible : jamais tous les fichiers gardés en silence (revue)
      if { [ "${CLOSE_DRY:-0}" != 1 ] && ! with_timeout "${LAB_SYNC_TIMEOUT:-30}" git -C "$WT" fetch --quiet "$P_REMOTE" "$CLOSE_BASE" 2>/dev/null; } \
        || ! git -C "$WT" rev-parse --verify --quiet "$P_REMOTE/$CLOSE_BASE^{commit}" >/dev/null; then
        printf 'revision\tPR #%s already merged; base %s/%s unreadable (offline?)%s: changes since the merge cannot be compared, lane kept; run lab close %s %s again\n' \
          "$CLOSE_NUM" "$P_REMOTE" "$CLOSE_BASE" "${CLOSE_DRY:+ (last local read: git fetch first)}" "$P_NAME" "$SLUG"; return 1
      fi
      off="$(close_bilan_offside)" \
        || { printf 'revision\tPR #%s already merged; changed since outside the acceptance section: %s — this work would never reach %s: remove it from the branch or deliver it through a new lane, then run lab close %s %s again\n' \
               "$CLOSE_NUM" "$off" "$CLOSE_BASE" "$P_NAME" "$SLUG"; rc=1; }
      off="$(close_bilan_aside)"   # apportés par la base ramenée : déjà livrés, dits par une NOTE (« delivered »), jamais un refus
      if [ -n "$off" ]; then
        n="$(printf '%s\n' "$off" | wc -l | tr -d ' ')"
        printf 'delivered\t%s file%s changed since PR #%s already identical to %s, set aside: %s\n' \
          "$n" "$([ "$n" = 1 ] || echo s)" "$CLOSE_NUM" "$CLOSE_BASE" "$(printf '%s\n' "$off" | sync_join)"
      fi
    else
      printf 'revision\tPR revision does not match the tried result: push the exact result, then redo the acceptance\n'; rc=1
    fi
  fi
  case "$CLOSE_PR_STATE" in OPEN|MERGED) ;; *) printf 'state\tPR #%s %s: lane kept\n' "$CLOSE_NUM" "$CLOSE_PR_STATE"; rc=1 ;; esac
  return "$rc"
}
# close_bilan_offside → changements de la tête fusionnée à HEAD hors de la seule section Recette de la fiche du dernier lot,
# nommés (« a, b » ou « <fiche> (hors de sa section …) ») ; rc 1 s'il y en a. Documents externes : tout fichier changé est hors tolérance.
close_bilan_offside() {
  local rel="" files others
  case "$CLOSE_LOT" in "$WT"/*) rel="${CLOSE_LOT#"$WT"/}" ;; esac
  files="$(close_bilan_files kept)"
  others="$(printf '%s\n' "$files" | awk -v r="$rel" 'NF && $0 != r' | sync_join)"
  [ -z "$others" ] || { printf '%s\n' "$others"; return 1; }
  [ -n "$rel" ] && grep -Fxq -- "$rel" <<<"$files" || return 0
  git -C "$WT" cat-file -e "$CLOSE_PR_HEAD:$rel" 2>/dev/null \
    && [ "$(git -C "$WT" show "$CLOSE_PR_HEAD:$rel" | recette_filter strip)" = "$(git -C "$WT" show "$CLOSE_HEAD:$rel" | recette_filter strip)" ] \
    || { printf '%s (outside its lane acceptance section)\n' "$rel"; return 1; }
}
# close_bilan_files kept|aside → fichiers changés de la tête fusionnée à HEAD encore différents de <remote>/<base> (kept), ou déjà
# identiques à elle (aside : apportés par la base ramenée, déjà livrés — lot 01 de close-arbre-livre) ; base illisible : tout est gardé
close_bilan_files() {
  local files base
  files="$(git -C "$WT" -c core.quotePath=false diff --name-only "$CLOSE_PR_HEAD" "$CLOSE_HEAD")"
  base="$(git -C "$WT" -c core.quotePath=false diff --name-only "$P_REMOTE/$CLOSE_BASE" "$CLOSE_HEAD" 2>/dev/null)" \
    || { [ "$1" = aside ] || printf '%s\n' "$files"; return 0; }
  printf '%s\n' "$files" | awk -v keep="$([ "$1" = kept ] && echo 1)" 'NR == FNR { b[$0] = 1; next } NF && (($0 in b) == (keep == 1))' \
    <(printf '%s\n' "$base") -
}
close_bilan_aside() { close_bilan_files aside; }
# close_bilan_wanted : contrôles passés (close_pr_problems), PR fusionnée à une autre tête et la fiche du dépôt changée depuis — seule
# sa section Recette, prouvé par close_bilan_offside ; fiches externes ou diff vide : fermeture ordinaire, sans bilan (revue du lot 01).
# Fiche déjà identique à la base : close_bilan_open le voit (SUMMARY=already in <base>) et n'ouvre aucune PR (close-arbre-livre)
close_bilan_wanted() {
  [ "$CLOSE_PR_STATE" = MERGED ] && [ "$CLOSE_PR_HEAD" != "$CLOSE_HEAD" ] || return 1
  case "$CLOSE_LOT" in "$WT"/*) ;; *) return 1 ;; esac
  local changed
  changed="$(git -C "$WT" -c core.quotePath=false diff --name-only "$CLOSE_PR_HEAD" "$CLOSE_HEAD")" && grep -Fxq -- "${CLOSE_LOT#"$WT"/}" <<<"$changed"
}
close_verify_delivery() { # [commit qui porte la fiche livrée, défaut : la fusion du lot — la fusion de la PR de bilan sinon]
  local proof="${1:-$CLOSE_MERGED}"
  [ -n "$CLOSE_MERGED" ] || die "merge not proven: lane kept; run lab close $P_NAME $SLUG again"
  git -C "$WT" fetch --quiet "$P_REMOTE" "$CLOSE_BASE" || die "delivery cannot be checked offline: lane kept"
  git -C "$WT" merge-base --is-ancestor "$CLOSE_MERGED" "$P_REMOTE/$CLOSE_BASE" \
    || die "merge missing from $CLOSE_BASE: lane kept"
  [ "$proof" = "$CLOSE_MERGED" ] || git -C "$WT" merge-base --is-ancestor "$proof" "$P_REMOTE/$CLOSE_BASE" \
    || die "acceptance summary missing from $CLOSE_BASE: lane kept; run lab close $P_NAME $SLUG again"
  # Les documents externes restent dans leur dépôt ; les docs du projet doivent
  # être retrouvables dans le commit livré, avec la même recette.
  case "$CLOSE_LOT" in
    "$WT"/*)
      local delivered current
      delivered="$(git -C "$WT" show "$proof:${CLOSE_LOT#"$WT"/}" | git hash-object --stdin)" || die "acceptance proof missing from the delivery"
      current="$(git hash-object "$CLOSE_LOT")"
      [ "$delivered" = "$current" ] || die "acceptance proof differs in the delivery: lane kept" ;;
  esac
}
# ---------- bilan de recette (lot 01 de close-apres-fusion) : PR du lot déjà fusionnée, la fiche à jour part par une PR dédiée ----------
# Branche chore/<couloir>-recette, un seul commit sur <remote>/<base> fraîche : la fiche du dernier lot telle que HEAD la porte.
# Relance idempotente : une PR de bilan ouverte ou fusionnée qui porte cette fiche, et rien d'autre, est retrouvée par sa branche, jamais
# doublée ; une branche poussée sans PR reçoit sa PR. Une PR fermée sans fusion, ou d'un autre contenu (ancien couloir du même nom),
# n'est pas une preuve : ignorée (revue du lot 01). Base qui porte déjà la fiche : aucun bilan (BILAN=déjà dans <base>).
# Pose CLOSE_BILAN_BRANCH, CLOSE_BILAN_NUM, CLOSE_BILAN_HEAD, CLOSE_BILAN_STATE (OPEN, MERGED ou NONE) et CLOSE_BILAN_MERGED.
close_bilan_open() {
  local br="chore/$SLUG-recette" rel blob info remote rc=0 parent tree commit idx url lot
  rel="${CLOSE_LOT#"$WT"/}"; blob="$(git -C "$WT" hash-object "$CLOSE_LOT")"; lot="$(basename "$CLOSE_LOT" .md)"
  CLOSE_BILAN_BRANCH="$br"
  info="$(pr_info_strict "$P_ROOT" "$br")" || die "summary PR of $br cannot be checked (gh failed or offline): lane kept; run lab close $P_NAME $SLUG again"
  if [ -n "$info" ]; then
    close_bilan_read "$(printf '%s' "$info" | cut -f1)"
    case "$CLOSE_BILAN_STATE" in OPEN|MERGED) close_bilan_only "$CLOSE_BILAN_HEAD" "$rel" "$blob" || info="" ;; *) info="" ;; esac
  fi
  if [ -z "$info" ]; then
    git -C "$WT" fetch --quiet "$P_REMOTE" "$CLOSE_BASE" || die "base $CLOSE_BASE unreadable (offline?): summary not delivered, lane kept"
    parent="$(git -C "$WT" rev-parse "$P_REMOTE/$CLOSE_BASE")"
    if [ "$(git -C "$WT" rev-parse --verify --quiet "$parent:$rel" 2>/dev/null)" = "$blob" ]; then
      CLOSE_BILAN_NUM=""; CLOSE_BILAN_HEAD=""; CLOSE_BILAN_STATE=NONE; CLOSE_BILAN_MERGED="$parent"
      kv SUMMARY "already in $CLOSE_BASE"; return 0
    fi
    remote="$(git -C "$WT" ls-remote --exit-code "$P_REMOTE" "refs/heads/$br")" || rc=$?
    case "$rc" in
      0) commit="${remote%%$'\t'*}"   # poussée lors d'un essai interrompu : reprise si elle porte exactement cette fiche, et rien d'autre
         { git -C "$WT" fetch --quiet "$P_REMOTE" "refs/heads/$br" 2>/dev/null && close_bilan_only "$commit" "$rel" "$blob"; } \
           || die "branch $br already exists with other content than the tried batch file: remove it, then run lab close $P_NAME $SLUG again" ;;
      2) idx="$(mktemp "${TMPDIR:-/tmp}/lab-bilan.XXXXXX")"
         tree="$(GIT_INDEX_FILE="$idx" git -C "$WT" read-tree "$parent" \
           && GIT_INDEX_FILE="$idx" git -C "$WT" update-index --add --cacheinfo "100644,$blob,$rel" \
           && GIT_INDEX_FILE="$idx" git -C "$WT" write-tree)" || { rm -f "$idx"; die "summary commit impossible: lane kept"; }
         rm -f "$idx"
         commit="$(git -C "$WT" commit-tree "$tree" -p "$parent" -m "docs(acceptance): acceptance summary of the lane $SLUG ($(printf '%s' "$lot" | cut -d- -f1-2))")" \
           || die "summary commit impossible: lane kept"
         git -C "$WT" push --quiet "$P_REMOTE" "$commit:refs/heads/$br" \
           || die "push of $br refused (branch protection or permissions): summary not delivered, lane kept" ;;
      *) die "remote branch $br cannot be checked (offline?): lane kept; run lab close $P_NAME $SLUG again" ;;
    esac
    url="$(cd "$WT" && with_timeout 60 gh pr create --base "$CLOSE_BASE" --head "$br" --title "docs(acceptance): acceptance summary of the lane $SLUG" \
      --body "Acceptance summary of the lane $SLUG: PR #$CLOSE_NUM was merged before the acceptance; only the acceptance section of $rel follows. Opened by lab close.")" \
      || die "gh pr create refused for $br: lane kept; run lab close $P_NAME $SLUG again (the pushed branch will be reused)"
    close_bilan_read "${url##*/}"
    { [ "$CLOSE_BILAN_STATE" = OPEN ] && close_bilan_only "$CLOSE_BILAN_HEAD" "$rel" "$blob"; } \
      || die "summary PR #$CLOSE_BILAN_NUM ($CLOSE_BILAN_STATE) does not carry only the tried batch file: close it, remove $br, then run lab close $P_NAME $SLUG again"
  fi
  [ "${CLOSE_BILAN_SAID:-}" = "$CLOSE_BILAN_NUM" ] || kv SUMMARY "#$CLOSE_BILAN_NUM"   # dit une fois : ouverture puis livraison
  CLOSE_BILAN_SAID="$CLOSE_BILAN_NUM"
}
close_bilan_read() { # <numéro> : relit la PR de bilan (tête, état, fusion), sa tête rapatriée si besoin ; destination vérifiée
  [[ "$1" =~ ^[0-9]+$ ]] || die "summary PR number unreadable: lane kept"
  local CLOSE_NUM="$1" CLOSE_PR_HEAD CLOSE_PR_BASE CLOSE_PR_STATE CLOSE_MERGED
  close_pr_read
  [ "$CLOSE_PR_BASE" = "$CLOSE_BASE" ] || die "summary PR #$CLOSE_NUM targets $CLOSE_PR_BASE, expected destination $CLOSE_BASE: lane kept"
  CLOSE_BILAN_NUM="$1"; CLOSE_BILAN_HEAD="$CLOSE_PR_HEAD"; CLOSE_BILAN_STATE="$CLOSE_PR_STATE"; CLOSE_BILAN_MERGED="$CLOSE_MERGED"
  git -C "$WT" cat-file -e "$CLOSE_BILAN_HEAD^{commit}" 2>/dev/null \
    || git -C "$WT" fetch --quiet "$P_REMOTE" "refs/heads/$CLOSE_BILAN_BRANCH" 2>/dev/null || true
}
# close_bilan_only <commit> <fiche> <blob> : rc 0 si le commit porte cette fiche exacte et ne change qu'elle depuis la base — une
# branche de bilan reprise (essai interrompu ou PR ouverte) n'apporte jamais un autre fichier dans la fusion
close_bilan_only() {
  local since
  [ "$(git -C "$WT" rev-parse --verify --quiet "$1:$2" 2>/dev/null)" = "$3" ] || return 1
  git -C "$WT" fetch --quiet "$P_REMOTE" "$CLOSE_BASE" 2>/dev/null || return 1
  since="$(git -C "$WT" merge-base "$1" "$P_REMOTE/$CLOSE_BASE")" || return 1
  [ "$(git -C "$WT" -c core.quotePath=false diff --name-only "$since" "$1")" = "$2" ]
}
# close_bilan_deliver : après confirmation, attend les contrôles de la PR de bilan, la fusionne à sa tête exacte (sha), rien sur un doute
close_bilan_deliver() {
  local checks result
  close_bilan_open
  [ "$CLOSE_BILAN_STATE" = OPEN ] || return 0
  checks="$(pr_checks_wait "$WT" "$CLOSE_BILAN_NUM" "$CLOSE_BILAN_HEAD" "$CLOSE_BILAN_BRANCH" "$CLOSE_BASE")"; kv CHECKS "$checks"
  case "$checks" in
    green|none) ;;
    pending) die "checks of summary PR #$CLOSE_BILAN_NUM pending: run lab close $P_NAME $SLUG again once green" ;;
    *) die "red checks on summary PR #$CLOSE_BILAN_NUM: fix them; lane kept" ;;
  esac
  result="$(with_timeout 120 gh api "repos/$CLOSE_REPO/pulls/$CLOSE_BILAN_NUM/merge" --method PUT -f "sha=$CLOSE_BILAN_HEAD" -f "merge_method=$P_MERGE_METHOD")" \
    || die "merge of summary PR #$CLOSE_BILAN_NUM refused (check, conflict or permissions): lane kept; run lab close $P_NAME $SLUG again"
  printf '%s' "$result" | jq -e '.merged == true' >/dev/null || die "summary PR not merged: lane kept"
  CLOSE_BILAN_MERGED="$(printf '%s' "$result" | jq -er '.sha')" || die "summary merge proof unreadable: lane kept"
}
# ---------- jobs de la suite complète (lot 02 de ci-sobre) ----------
# Lot 02 de restes-cloud : lab close ne pose plus l'étiquette full-suite et n'attend plus la suite complète (la nuit et le tag la
# jouent) ; seule la CI de la PR décide. Reste la lecture des jobs gardés, pour la mesure HEAVY_PR_JOBS (lib/ci_measure.sh).
# close_full_suite_jobs <révision> : début du nom (avant toute expression de matrice) de chaque job que les workflows de la révision
# ne jouent qu'avec l'étiquette full-suite — contains(…labels…, 'full-suite') non nié dans son if: ; vide : aucun.
# rc 1 si un workflow cite l'étiquette sans pouvoir être lu (ruby absent, YAML invalide).
close_full_suite_jobs() {
  local files text
  files="$(git -C "$WT" ls-tree --name-only "$1" -- .github/workflows/ 2>/dev/null | grep -E '\.ya?ml$')" || return 0
  # lu en entier : sous pipefail, un grep -q qui s'arrête tôt casse git show (SIGPIPE) sur un gros workflow
  text="$(printf '%s\n' "$files" | while IFS= read -r f; do git -C "$WT" show "$1:$f" 2>/dev/null; done)" || true
  case "$text" in *full-suite*) ;; *) return 0 ;; esac
  command -v ruby >/dev/null 2>&1 || { warn "ruby not found: the full-suite jobs of the workflows cannot be read"; return 1; }
  # shellcheck disable=SC2016 # programme ruby littéral
  printf '%s\n' "$files" | ruby -Ku -ryaml -e '
    root, rev = ARGV
    STDIN.read.split("\n").each do |path|
      text = IO.popen(["git", "-C", root, "show", "#{rev}:#{path}"], err: File::NULL, &:read)
      w = YAML.safe_load(text, aliases: true)
      jobs = w.is_a?(Hash) && w["jobs"].is_a?(Hash) ? w["jobs"] : {}
      jobs.each do |id, j|
        next unless j.is_a?(Hash) && j["if"].to_s.match?(/(?<!!)contains\([^)]*["\x27]full-suite["\x27]\s*\)/)
        puts (j["name"] || id).to_s.split("${{", 2)[0].strip
      end
    end' "$WT" "$1" 2>/dev/null || { warn "workflow citing full-suite unreadable at ${1:0:12}"; return 1; }
}
close_deliver() { # déjà validé et confirmé : aucun auto-merge différé
  local head="$CLOSE_HEAD" base="$CLOSE_BASE" records="$CLOSE_RECORDS" document checks result
  document="$(git hash-object "$CLOSE_LOT")"
  delivery_guard
  if [ "$CLOSE_PR_STATE" = OPEN ]; then
    pr_make_ready "$WT" "$CLOSE_NUM"
    # lot 02 de restes-cloud : seule la CI de la PR décide ; la suite complète tourne la nuit et au tag, jamais attendue ici
    checks="$(pr_checks_wait "$WT" "$CLOSE_NUM" "$head" "$CLOSE_BRANCH" "$base")"; kv CHECKS "$checks"
    if [ "$checks" = none ] && pr_ci_none "$WT" "$head" "$CLOSE_BRANCH" "$base" 2>/dev/null; then
      kv CI "none (no pull request workflow)"
      # shellcheck disable=SC2034 # lu par watch_close (lib/watch.sh)
      CLOSE_CI_NOTE=" — CI=none (no pull request workflow)"
    fi
    case "$checks" in
      green|none) ;;
      pending) die "checks pending: no merge scheduled; run lab close $P_NAME $SLUG again once green" ;;
      *) die "red checks: fix them; lane kept" ;;
    esac
    # Après l’attente, reprendre toutes les preuves. Le paramètre sha protège
    # aussi l’intervalle entre cette lecture et la mutation distante.
    close_prepare
    [ "$CLOSE_HEAD" = "$head" ] && [ "$CLOSE_BASE" = "$base" ] && [ "$CLOSE_RECORDS" = "$records" ] \
      && [ "$(git hash-object "$CLOSE_LOT")" = "$document" ] || die "result changed during the check: new acceptance required"
    close_recheck "$head" "$base"   # la base a pu avancer pendant l'attente des contrôles : revérifiée fraîche juste avant la fusion
    # PUT synchrone : contrairement à gh pr merge, ne met pas en file d’attente
    # une PR soumise à une merge queue. Un refus conserve le couloir.
    result="$(with_timeout 120 gh api "repos/$CLOSE_REPO/pulls/$CLOSE_NUM/merge" --method PUT -f "sha=$head" -f "merge_method=$P_MERGE_METHOD")" \
      || die "merge refused (check, conflict or permissions): lane kept; run lab close $P_NAME $SLUG again after fixing it"
    printf '%s' "$result" | jq -e '.merged == true' >/dev/null || die "merge not done: lane kept"
    CLOSE_MERGED="$(printf '%s' "$result" | jq -er '.sha')" || die "merge proof unreadable: lane kept"
  fi
  if [ "$CLOSE_BILAN" = 1 ]; then close_bilan_deliver; close_verify_delivery "$CLOSE_BILAN_MERGED"
  else close_verify_delivery; fi   # lot vide : CLOSE_MERGED=HEAD, la preuve est HEAD dans la base fraîche
  if [ "$CLOSE_PR_STATE" = EMPTY ]; then kv DELIVERY "already in $CLOSE_BASE"
  else kv DELIVERY "delivered to $CLOSE_BASE"; kv MERGE_COMMIT "$CLOSE_MERGED"; fi
  [ "$CLOSE_BILAN" != 1 ] || kv BILAN_COMMIT "$CLOSE_BILAN_MERGED"
  deploy_note_merged "$CLOSE_BRANCH" "$CLOSE_BASE" || true   # registre de mise en ligne annoté, rien déployé (lot 02 de mise-en-ligne)
}
close_remove_branch() { # <branche> <révision attendue> [autre révision distante admise] : après livraison seulement
  local branch="$1" expected="$2" local_head remote_head rc=0
  local_head="$(git -C "$WT" rev-parse --verify "refs/heads/$branch" 2>/dev/null || true)"
  [ -z "$local_head" ] || [ "$local_head" = "$expected" ] || die "branch $branch changed since the acceptance: lane kept"
  remote_head="$(git -C "$WT" ls-remote --exit-code "$P_REMOTE" "refs/heads/$branch")" || rc=$?
  case "$rc" in 0|2) ;; *) die "remote branch cannot be checked: lane kept" ;; esac
  remote_head="${remote_head%%$'\t'*}"
  [ -z "$remote_head" ] || [ "$remote_head" = "$expected" ] || [ "$remote_head" = "${3:-}" ] || die "remote branch $branch changed: lane kept"
  if [ -n "$remote_head" ]; then
    git -C "$WT" push --quiet "--force-with-lease=refs/heads/$branch:$remote_head" "$P_REMOTE" ":refs/heads/$branch" \
      || die "remote removal refused: lane kept; run lab close $P_NAME $SLUG again"
  fi
  if [ -n "$local_head" ]; then
    git -C "$WT" branch -D -- "$branch" >/dev/null || die "removal of $branch refused: lane kept; run lab close $P_NAME $SLUG again"
  fi
}
close_confirm() { # <confirmation> <posée=0|1> <verbe> : accord nommé déjà reçu (--confirm) ou tapé au terminal ; rc 1 = couloir conservé
  local answer=""
  if [ "$2" = 1 ]; then
    [ "$1" = "$SLUG" ] || die "confirmation does not match the exact name $SLUG: lane kept"
    return 0
  fi
  [ -t 0 ] || die "confirmation required in a terminal; --confirm $SLUG is reserved for an explicit agreement already received"
  printf 'Type the exact name "%s" to %s; Enter keeps it: ' "$SLUG" "$3" >&2
  trap 'log "Closing interrupted: lane kept."; exit 130' INT TERM HUP
  IFS= read -r answer || answer=""
  trap - INT TERM HUP
  [ "$answer" = "$SLUG" ] || { kv ACTION cancelled; log "Closing cancelled: lane $SLUG kept."; return 1; }
}
# ---------- fermeture seule par la tour (lot 08 d'autonomie-tours) ----------
# close_alone_state <wt> <couloir> [relance=0|1] : les trois verts pour chaque cible qui sert le couloir (lanes= de son registre) —
# recette valide, tête servie = révision essayée avec verified=yes, contrôle de prod vert sur la révision servie depuis moins de
# LAB_PROD_CHECK_MAX_AGE s (24 h). relance=1 (lab close) : registre relu sous le verrou de la cible (une mise en ligne ne le réécrit
# pas entre la lecture et la relance, revue du lot 08), contrôle absent, d'une autre révision ou trop vieux relancé ; relance=0 (vue,
# --dry-run) : seul un contrôle vert mais ancien compte, « relancé à la fermeture ». Pose CA_OK (yes | no) et CA_WHY (le manque ou
# le résumé) ; aucun refus, aucune écriture sans relance.
close_alone_state() {
  local wt="$1" lane="$2" rerun="${3:-0}" lot status tried t lk served=""; local -a l=()
  CA_OK=no; CA_WHY=""; CA_MISS=""; CA_STALE=""
  lot="$(wt_lot_file "$wt")"; status="$(recette_status "$wt" "$lot")"
  case "$status" in valid) ;; absent) CA_WHY="acceptance missing"; return 0 ;; expired) CA_WHY="acceptance stale"; return 0 ;;
    *) CA_WHY="acceptance $status"; return 0 ;; esac
  agreement_valid "$wt" || { CA_WHY="$AG_WHY"; return 0; }   # lot 09 : l'accord gardé par lab, jamais la fiche seule
  tried="$(recette_revision_of "$(recette_field "$lot" 'Révision essayée')")"
  for t in $(deploy_registries); do
    l=(); read -r -a l <<<"$(state_field "$(deploy_dir)/$t" lanes)" || true
    in_words "$lane" "${l[@]+"${l[@]}"}" || continue
    served="${served:+$served }$t"
    if [ "$rerun" = 0 ]; then close_alone_target "$t" "$lane" "$tried" 0; continue; fi
    lk=0; resource_take "$t" prod-check "$$" "$(deploy_dir)/verrous" 1 || lk=$?
    [ "$lk" = 0 ] || { CA_MISS="$CA_MISS; $t: go-live running (lane $RES_PREV), nothing checked"; continue; }
    close_alone_target "$t" "$lane" "$tried" 1
    [ "$(state_field "$(deploy_dir)/verrous/$t" pid)" != "$$" ] || rm -f "$(deploy_dir)/verrous/$t"
  done
  [ -n "$served" ] || { CA_WHY="lane $lane served by no target: closing alone needs a served, checked revision"; return 0; }
  [ -z "$CA_MISS" ] || { CA_WHY="${CA_MISS#; }"; return 0; }
  CA_OK=yes
  CA_WHY="acceptance valid, ${tried:0:7} served on $served (verified), prod check green${CA_STALE:+ — older than $(( ${LAB_PROD_CHECK_MAX_AGE:-86400} / 3600 )) h on $CA_STALE: lab close runs it again}"
}
# close_alone_target <cible> <couloir> <révision essayée> <relance> : une cible, registre lu ici (sous verrou si relance=1) ; ajoute
# à CA_MISS ce qui manque, à CA_STALE une cible au contrôle vert mais ancien
close_alone_target() {
  local t="$1" lane="$2" tried="$3" reg i idx="" rc age max fresh=0 cause; local -a l=() h=()
  reg="$(deploy_dir)/$t"; max="${LAB_PROD_CHECK_MAX_AGE:-86400}"
  read -r -a l <<<"$(state_field "$reg" lanes)" || true
  read -r -a h <<<"$(state_field "$reg" heads)" || true
  for i in "${!l[@]}"; do [ "${l[$i]}" != "$lane" ] || idx="$i"; done
  [ -n "$idx" ] || { CA_MISS="$CA_MISS; $t no longer serves lane $lane"; return 0; }
  [ "${h[$idx]:-}" = "$tried" ] || { CA_MISS="$CA_MISS; $t serves ${h[$idx]:0:7}, not the tried revision ${tried:0:7}"; return 0; }
  [ "$(state_field "$reg" verified)" = yes ] || { CA_MISS="$CA_MISS; $t: served revision not verified"; return 0; }
  [ -n "$(deploy_cfg prod_check "$t")" ] || { CA_MISS="$CA_MISS; $t: no prod_check.$t= in the config of $P_NAME"; return 0; }
  rc="$(state_field "$reg" check_rc)"; age=$(( $(cloud_epoch) - $(state_field "$reg" check_epoch | grep -E '^[0-9]+$' || echo 0) ))
  [ -z "$rc" ] || [ "$(state_field "$reg" check_rev)" != "$(state_field "$reg" rev)" ] || [ "$age" -gt "$max" ] || fresh=1
  case "$rc" in 124) cause=timeout ;; *) cause="rc $rc" ;; esac
  if [ "$fresh" = 1 ]; then [ "$rc" = 0 ] || CA_MISS="$CA_MISS; $t: prod check red ($cause)"; return 0; fi
  if [ "$rerun" = 0 ]; then   # sans relance : seul un vert ancien sur la révision servie compte (revue du lot 08)
    if [ -z "$rc" ] || [ "$(state_field "$reg" check_rev)" != "$(state_field "$reg" rev)" ]; then
      CA_MISS="$CA_MISS; $t: prod check not run on the served revision (lab close runs it)"
    elif [ "$rc" = 0 ]; then CA_STALE="${CA_STALE:+$CA_STALE }$t"
    else CA_MISS="$CA_MISS; $t: prod check red ($cause), older than $((max / 3600)) h"; fi
    return 0
  fi
  log_wrap "prod check of $t older than $((max / 3600)) h or not run on the served revision: running it again."
  prod_check_run "$t" "$(state_field "$reg" rev)"
  [ "$PC_STATE" = green ] || CA_MISS="$CA_MISS; $PC_WHY"
}
# close_alone_notify <texte> : notification cmux vers l'onglet de la tour (la fermeture a retiré celui du couloir)
close_alone_notify() {
  local wt; wt="$(worktree_path "$TOWER_LANE")"
  cmux_notify "$P_NAME · $TOWER_LANE" "$1" "$(wt_ws "$wt")" "$(wt_surface "$wt")"
}
# close_words_notify <texte> (lot 10) : la même notification, pour une fermeture sur les mots de l'utilisateur — projet doté d'une tour
close_words_notify() { deploy_tower_project || return 0; close_alone_notify "$1"; }
# close_caller_tab (lot 10) : l'onglet du couloir où vit la session appelante, repéré par close_procs_stop, fermé avec elle (--force)
# une fois tout fait — la conversation reste reprenable ; cmux qui refuse : la session est nommée, jamais tuée par lab
close_caller_tab() {
  [ -n "${CLOSE_CALLER_TAB:-}" ] || return 0
  log "the calling session's tab (${CLOSE_CALLER_TAB#* }) closes with it: the conversation stays resumable"
  close_top_load; cmux_spare_tab "${CLOSE_CALLER_TAB%% *}" "${CLOSE_CALLER_TAB#* }" "$P_ROOT"
  top_cmux close-surface --workspace "${CLOSE_CALLER_TAB%% *}" --surface "${CLOSE_CALLER_TAB#* }" --force >/dev/null 2>&1 \
    || warn "the calling session's tab was not closed by cmux: exit that session yourself"
  CLOSE_CALLER_TAB=""
}
close_tab() { # <workspace> <surface> <nom> : ferme l'onglet du couloir par sa référence, sinon par son nom s'il est seul à le porter
  # dans l'ancre du projet (lot 06) ; sinon le laisse et dit pourquoi — un onglet absent ou ambigu ne fait jamais échouer la fermeture
  local tab ws surface
  [ -n "$2" ] && has_cmux || return 0
  # déjà fermé avec la session qu'il portait (close_procs_stop) : ne pas le chercher, il n'existe plus
  if [ "${CLOSE_LANE_TAB_CLOSED:-0}" = 1 ]; then cmx clear-status "lab-lane-$SLUG" --workspace "$1" >/dev/null 2>&1 || true; return 0; fi
  tab="$(cmux_lane_tab "$1" "$2" "$3")"; ws="$(cmux_tab_field "$tab" workspace)"; surface="$(cmux_tab_field "$tab" surface)"
  case "$(cmux_tab_field "$tab" way)" in
    reference|name)
      cmx clear-status "lab-lane-$SLUG" --workspace "$ws" >/dev/null 2>&1 || true
      cmux_spare_tab "$ws" "$surface" "$P_ROOT"
      if ! cmux_close_named_surface "$ws" "$surface" "$3"; then warn "tab kept: cmux did not close $surface ($3); close it yourself"
      elif [ "$(cmux_tab_field "$tab" way)" = name ]; then log "tab $3 found by its name ($2 → $surface) and closed"; fi ;;
    ambiguous)
      warn "tab kept: $(printf '%s\n' "$surface" | wc -w | tr -d ' ') tabs carry the name $3 ($(printf '%s' "$surface" | sed 's/ /, /g')); close the right one yourself" ;;
    *)
      if [ "$3" = main ]; then warn "tab kept: its reference no longer matches main, a name never searched"
      else warn "tab kept: its reference no longer matches $3 and no tab carries this name"; fi ;;
  esac
}

# ---------- processus du couloir (lot 01 de fermeture-propre) ----------
# Un processus appartient au couloir quand son dossier courant est dans le worktree, seul critère. Une session claude ou codex n'est
# jamais tuée : son onglet cmux se ferme avec --force — sans lui cmux refuse un onglet où un processus vit (« confirmation_required »),
# l'onglet restait (« tab kept ») et la session vivait dans un dossier retiré (cause de la session de 17 h) ; sans onglet, elle est
# nommée. Hors agent : TERM, puis KILL après TOP_STOP_WAIT secondes (top_stop). Jamais visés : lab et ses enfants, la session
# appelante et ses parents, root, un autre compte, cmux, cmux-cua, les assistants d'agent, le parent d'une session (règles de guard()
# de lib/top.sh). La liste est relue au moment d'agir : un pid noté avant la confirmation, parfois des heures avant (veilleur),
# peut avoir été réattribué.
# chargement à la demande, non suivi par shellcheck : il confondrait les tableaux locaux de lib/top.sh (pr) avec ceux de cmd_close
# shellcheck source=/dev/null
# les apps de terminal posées (le fork de cmux, lot 02 d'app-treelab) y sont la famille cmux, jamais arrêtées : top_terminals
close_top_load() { declare -F top_stop >/dev/null || { . "$LAB_ROOT/lib/top.sh"; . "$LAB_ROOT/lib/top_cut.sh"; }; top_terminals; }
# close_lane_procs → « genre<TAB>pid<TAB>nom<TAB>âge<TAB>session[<TAB>lien] » par processus du dossier $WT ; genre : agent (session du
# couloir), caller (la session appelante, dans le dossier), sub (agent lancé par une session), proc (hors agent) ; session : la plus
# proche session parmi ses parents, sinon celle de son terminal (une copie du shell de l'onglet n'est pas l'enfant de l'agent mais
# vit dans son onglet, mesuré sur le poste) ; rc 2 si la table ou lsof est illisible (rien mesuré) ; lien d'un proc à sa session : shell (commande lancée par un shell de l'agent), - (enfant
# direct ou par un autre programme : caffeinate, serveur d'outils), tty (par son seul terminal) — lu par batch_processes
close_lane_procs() {
  local real ps_out pids cwds uid sibs pipes=""
  close_top_load; uid="$(id -u)"
  real="$(cd "$WT" 2>/dev/null && pwd -P)" || real="$WT"
  # le terminal en tête de la commande : ps_parse le laisse dans P_ARGS, d'où il est retiré
  ps_out="$(LC_ALL=en_US.UTF-8 ps -axww -o pid=,ppid=,uid=,stat=,rss=,%cpu=,etime=,tty=,args= 2>/dev/null)" || true
  [ -n "$ps_out" ] || { warn "process table unreadable (ps): processes in $WT not checked"; return 2; }
  command -v lsof >/dev/null 2>&1 || { warn "lsof missing: processes in $WT not checked"; return 2; }
  # lsof sur les seuls pid du compte : le dossier courant de chacun, une passe
  pids="$(printf '%s\n' "$ps_out" | LC_ALL=C awk -v uid="$uid" "$TOP_AWK_LIB"'ps_parse($0) && P_UID == uid { printf "%s%s", (n++ ? "," : ""), P_PID }')"
  [ -n "$pids" ] || return 0
  cwds="$({ LC_ALL=en_US.UTF-8 lsof -a -d cwd -p "$pids" -Fpfn 2>/dev/null || true; } | LC_ALL=C awk -v a="$WT" -v b="$real" '
    /^p/ { p = substr($0, 2) } /^n/ { d = substr($0, 2); if (d == a || d == b || index(d, a "/") == 1 || index(d, b "/") == 1) print p }')"
  [ -n "$cwds" ] || return 0
  # le tube autour de lab (lot 03) : « cmd | lab … | grep | tail » lance des frères de lab (même shell parent), pas ses enfants ; seul
  # lsof les distingue d'un serveur lancé en fond par ce shell : chaque extrémité de tube porte son adresse (d) et celle de son pair
  # (n->0x…, mesuré sur macOS 26). Sonde illisible : rien d'exclu de plus, jamais un faux zéro
  sibs="$(printf '%s\n' "$ps_out" | LC_ALL=C awk -v self="$$" -v uid="$uid" "$TOP_AWK_LIB"'ps_parse($0) && P_UID == uid { PP[P_PID] = P_PPID; o[++n] = P_PID }
    END { q = PP[self]; if (q == "" || q == "0" || q == "1") exit; for (i = 1; i <= n; i++) if (PP[o[i]] == q && o[i] != self) printf ",%s", o[i] }')"
  [ -z "$sibs" ] || pipes="$({ LC_ALL=en_US.UTF-8 lsof -a -d 0,1 -p "$$$sibs" -Fpftdn 2>/dev/null || true; } | LC_ALL=C awk '
    /^p/ { p = substr($0, 2) } /^t/ { t = substr($0, 2) } /^d/ { d = substr($0, 2) }
    /^n->/ && t == "PIPE" { print p "\t" d "\t" substr($0, 4) }')"
  printf '#C\n%s\n#T\n%s\n#S\n%s\n' "$cwds" "$pipes" "$ps_out" | LC_ALL=C awk -v self="$$" -v uid="$uid" "$TOP_AWK_LIB"'
    function up(p, set,   q, d) { q = p; d = 0; while (q != "" && q != "0" && q != "1" && d < 64) { set[q] = 1; q = PP[q]; d++ } }
    function mine(p,   q, d) { q = p; d = 0; while (q != "" && q != "0" && d < 64) { if (q == self || (q in TUBE)) return 1; q = PP[q]; d++ } return 0 }
    # x et y partagent un tube : une extrémité de l un a pour pair une extrémité de l autre
    function linked(x, y,   k, a) { for (k = 1; k <= TN; k++) if (TP[k] == x) { a = TD[k]; if (index(PE[y], " " a " ")) return 1 }
      for (k = 1; k <= TN; k++) if (TP[k] == y) { a = TD[k]; if (index(PE[x], " " a " ")) return 1 } return 0 }
    function owner(p,   q, d) { q = PP[p]; d = 0; while (q != "" && q != "0" && q != "1" && d < 64) { if (AG[q] == "claude" || AG[q] == "codex") return q; q = PP[q]; d++ } return "" }
    function age(s) { return (s >= 86400) ? int(s / 86400) "d" : (s >= 3600) ? int(s / 3600) "h" : int(s / 60) "m" }
    function shl(a,   w) { split(a, w, " "); w[1] = top_base(w[1]); sub(/^-/, "", w[1]); return w[1] ~ /^(sh|bash|zsh|fish|dash|ksh)$/ }
    function via(p, o,   q, d, s) { q = PP[p]; d = 0; s = 0; while (q != "" && q != o && q != "0" && d < 64) { if (shl(ARGS[q])) s = 1; q = PP[q]; d++ } return (q != o) ? "tty" : s ? "shell" : "-" }
    /^#[A-Z]$/ { sec = substr($0, 2); next }
    sec == "C" { IN[$0] = 1; next }
    sec == "T" && split($0, w, "\t") == 3 { TN++; TP[TN] = w[1]; TD[TN] = w[2]; PE[w[1]] = PE[w[1]] " " w[3] " "; next }
    sec == "S" && ps_parse($0) {
      t = P_ARGS; sub(/[ \t].*/, "", t); sub(/^[^ \t]+[ \t]+/, "", P_ARGS)
      n++; ORD[n] = P_PID; PP[P_PID] = P_PPID; UID[P_PID] = P_UID; ET[P_PID] = etime_s(P_ET); ARGS[P_PID] = P_ARGS; AG[P_PID] = agent_of(P_ARGS); TT[P_PID] = t
    }
    END {
      up(PP[self], ANC)   # la session appelante et ses parents
      # membres du tube de lab, de proche en proche : seuls les frères sondés ont des extrémités (#T)
      TUBE[self] = 1; grow = TN
      while (grow) { grow = 0; for (x in PE) if (!(x in TUBE)) for (y in TUBE) if (linked(x, y)) { TUBE[x] = 1; grow = 1; break } }
      for (i = 1; i <= n; i++) if (AG[ORD[i]] == "claude" || AG[ORD[i]] == "codex") {   # parents des sessions, session de chaque terminal
        up(PP[ORD[i]], AP); if (TT[ORD[i]] ~ /^tty/) TA[TT[ORD[i]]] = ORD[i]
      }
      for (i = 1; i <= n; i++) {
        p = ORD[i]
        if (!(p in IN) || UID[p] != uid || UID[p] == "0" || mine(p)) continue
        s = (AG[p] == "claude" || AG[p] == "codex"); row = "\t" p "\t" name_of(ARGS[p]) "\t" age(ET[p]) "\t"
        if (p in ANC) { if (s) print "caller" row; continue }
        # agent lancé par une session (codex exec, sous-agent) : il hérite de son onglet, le fermer tuerait la session parente
        if (s && (o = owner(p)) != "") { print "sub" row o; continue }
        if (s) { print "agent" row; continue }
        f = family_of(ARGS[p], AG[p])
        if (f == "cmux" || f == "cmux-cua" || f == "agent-helper" || (p in AP)) continue
        o = owner(p); if (o == "" && (TT[p] in TA)) o = TA[TT[p]]
        print "proc" row o "\t" ((o == "") ? "-" : via(p, o))
      }
    }'
}
# close_procs_plan → « geste<TAB>pid<TAB>nom<TAB>âge<TAB>onglet<TAB>espace<TAB>session » ; geste : tab (onglet fermé), untabbed (session
# hors cmux, nommée), caller (session appelante, laissée), stop (TERM puis KILL), stays (enfant d'une session laissée : il vit avec elle) ;
# un champ vide vaut « - » (read avec IFS tabulation fusionne deux tabulations : un champ vide décalerait les suivants)
close_procs_plan() {
  local procs agents envs="" cm=0
  close_top_load
  procs="$(close_lane_procs)" || true; [ -n "$procs" ] || return 0   # illisible : déjà nommé par close_lane_procs
  agents="$(printf '%s\n' "$procs" | awk -F '\t' '$1 == "agent" { printf "%s%s", (n++ ? "," : ""), $2 }')"
  [ -z "$agents" ] || envs="$(top_envs "$agents")"
  ! has_cmux || cm=1
  printf '#E\n%s\n#P\n%s\n' "$envs" "$procs" | awk -F '\t' -v cm="$cm" '
    /^#[A-Z]$/ { sec = substr($0, 2); next }
    sec == "E" { if (NF >= 2) { SF[$1] = $2; SW[$1] = $3 } next }
    sec == "P" && NF >= 4 { n++; K[n] = $1; P[n] = $2; N[n] = $3; A[n] = $4; O[n] = $5 }
    END {
      for (i = 1; i <= n; i++) {
        if (K[i] == "caller") { G[i] = "caller"; stay[P[i]] = 1 }
        else if (K[i] == "agent") { if (cm && SF[P[i]] != "" && SW[P[i]] != "") G[i] = "tab"; else { G[i] = "untabbed"; stay[P[i]] = 1 } }
      }
      for (i = 1; i <= n; i++) {
        if (K[i] == "sub") G[i] = "stays"   # jamais tué ni son onglet fermé : il vit et part avec sa session
        else if (K[i] == "proc") G[i] = (O[i] in stay) ? "stays" : "stop"
        print G[i] "\t" P[i] "\t" N[i] "\t" A[i] "\t" (G[i] == "tab" ? SF[P[i]] "\t" SW[P[i]] : "-\t-") "\t" (O[i] == "" ? "-" : O[i])
      }
    }'
}
# close_procs_show <plan> : le récapitulatif avant confirmation, sur stderr ; close_procs_kv <plan> : PROCESS=<pid> <nom> <âge> <geste>
close_procs_show() {
  local g pid nm age o
  close_top_load
  if [ -z "$1" ]; then printf 'Folder processes: none\n' >&2; return 0; fi
  printf 'Folder processes, after confirmation:\n' >&2
  # deux lignes par processus, la seconde pour le geste : chacune tient en 40 colonnes, sauf un nom très long
  while IFS=$'\t' read -r g pid nm age _ _ o; do
    printf '  pid %s %s, %s\n' "$pid" "$nm" "$age"
    case "$g" in
      tab) printf '    tab closed, conversation resumable\n' ;;
      untabbed) printf '    no cmux tab, never killed: exit it\n' ;;
      caller) printf '    calling session: exit it once closed\n' ;;
      stays) printf '    stays with session %s\n' "$o" ;;
      stop) printf '    TERM, then KILL after %s s\n' "$TOP_STOP_WAIT" ;;
    esac
  done <<<"$1" >&2
}
close_procs_kv() {
  local g pid nm age
  [ -z "$1" ] || while IFS=$'\t' read -r g pid nm age _; do kv PROCESS "$pid $nm $age $g"; done <<<"$1"
}
# close_procs_stop <workspace> <surface> : après confirmation et livraison, juste avant le retrait du dossier ; aucun tty exigé
# (veilleur). Pose CLOSE_LANE_TAB_CLOSED=1 quand l'onglet du couloir s'est fermé avec sa session : close_tab ne le cherche plus.
close_procs_stop() {
  local plan g pid nm age sv sw o out r lane_id="" kept=" " stops=""
  CLOSE_LANE_TAB_CLOSED=0; CLOSE_CALLER_TAB=""; close_top_load
  plan="$(close_procs_plan)"; [ -n "$plan" ] || return 0
  if [ -n "$2" ] && has_cmux; then
    lane_id="$(cmx tree --workspace "$1" --json --id-format both 2>/dev/null | jq -r --arg s "$2" \
      '.. | objects | select(.ref? == $s or .id? == $s) | .id // empty' 2>/dev/null | head -1 || true)"
  fi
  # sessions d'abord : celle que cmux refuse de fermer garde ses enfants, comme une session sans onglet
  while IFS=$'\t' read -r g pid nm age sv sw o; do
    case "$g" in
      tab)
        cmux_spare_tab "$sw" "$sv" "$P_ROOT"
        if out="$(top_cmux close-surface --workspace "$sw" --surface "$sv" --force 2>&1)"; then
          log "session $pid ($nm, $age): its tab is closed, the conversation stays resumable"
          [ -z "$lane_id" ] || [ "$sv" != "$lane_id" ] || CLOSE_LANE_TAB_CLOSED=1
        else
          r="$(top_cmux_refusal "$out")"; kept="$kept$pid "
          warn "session $pid ($nm, $age) kept: cmux did not close its tab (${r#*$'\t'}); lab never kills an agent, exit it yourself"
        fi ;;
      untabbed) warn "session $pid ($nm, $age) has no cmux tab: lab never kills an agent, exit it yourself" ;;
      # lot 10 : la session appelante est celle de l'onglet du couloir (son CMUX_SURFACE_ID, hérité par lab) — l'onglet se ferme avec
      # elle en tout dernier (close_caller_tab), jamais avant la livraison et le retrait ; dans un autre onglet, elle est nommée
      caller)
        if [ -n "$lane_id" ] && [ "${CMUX_SURFACE_ID:-}" = "$lane_id" ] && [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
          CLOSE_CALLER_TAB="$CMUX_WORKSPACE_ID $CMUX_SURFACE_ID"; CLOSE_LANE_TAB_CLOSED=1
          log "calling session $pid ($nm, $age): the lane's tab closes with it once the lane is closed"
        else warn "calling session $pid ($nm, $age) stays in the removed folder: exit it once the lane is closed"; fi ;;
    esac
  done <<<"$plan"
  while IFS=$'\t' read -r g pid nm age sv sw o; do
    case "$g" in stays|stop) ;; *) continue ;; esac
    if [ "$g" = stays ] || [[ "$kept" == *" $o "* ]]; then log "process $pid ($nm, $age) stays with session $o"; continue; fi
    stops="$stops${stops:+,}$pid"; log "process $pid ($nm, $age): TERM, then KILL after $TOP_STOP_WAIT s"
  done <<<"$plan"
  [ -n "$stops" ] || return 0
  TOP_RESULTS=""; top_stop "" lane "ROOTS=$stops"
  log "$(top_field "$(top_block "$TOP_RESULTS" BLOCK=RESULT)" DETAIL)"
}

# batch_processes (lab batch processes, lot 02 de fermeture-propre) : ce qui vit encore dans le dossier $WT en fin de lot, pour le
# skill batch-end — tout sauf la session appelante, ses parents et lab, y compris un serveur qu'elle a lancé ; aucun signal, rc 0 :
# l'agent arrête chaque processus ou justifie dans la fiche pourquoi il vit. PROCESS=<pid> <nom> <âge> <genre> (agent : autre
# session, sub : agent lancé par une session, proc : hors agent), PROCESSES=<n>, ou unmeasured si ps ou lsof est illisible ; vue sur stderr, deux lignes de 40 colonnes.
batch_processes() {
  local rows k pid nm age o all rc=0
  # ni ce qui vit avec une autre session du dossier (nommée elle-même), ni les aides de la session appelante : d'elle, seulement ce
  # qu'elle a lancé par un shell (mesuré sur le poste : caffeinate, enfant direct de Claude Code, et la copie du shell de l'onglet
  # sortaient sinon) ; ce qu'une session hors du dossier y a lancé reste nommé, personne d'autre ne le ferait
  all="$(close_lane_procs)" || rc=$?
  if [ "$rc" != 0 ]; then kv PROCESSES unmeasured; return 0; fi   # jamais un faux « rien ne tourne » (revue)
  rows="$(printf '%s\n' "$all" | awk -F '\t' 'NF == 0 { next } $1 == "caller" { C[$2] = 1; next } { n++; R[n] = $0; O[n] = $5; K[n] = $1; V[n] = $6; if ($1 == "agent") A[$2] = 1 }
    END { for (i = 1; i <= n; i++) if (O[i] == "" || ((O[i] in C) && (K[i] == "sub" || V[i] == "shell")) || (!(O[i] in C) && !(O[i] in A))) print R[i] }')"
  if [ -z "$rows" ]; then printf 'Folder processes: none\n' >&2; kv PROCESSES 0; return 0; fi
  printf 'Folder processes, stop or justify each:\n' >&2
  while IFS=$'\t' read -r k pid nm age o; do
    kv PROCESS "$pid $nm $age $k"
    printf '  pid %s %s, %s\n' "$pid" "$nm" "$age" >&2
    case "$k" in
      agent) printf '    other session: exit or justify it\n' >&2 ;;
      sub) printf '    agent of session %s: let it end\n' "$o" >&2 ;;
      *) printf '    kill %s, or justify it\n' "$pid" >&2 ;;
    esac
  done <<<"$rows"
  kv PROCESSES "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')"
}

# lane_leftovers <racine> → « genre<TAB>pid<TAB>nom<TAB>âge<TAB>couloir » (lot 02 de fermeture-propre) : ce que lab doctor et lab
# sweep nomment sans rien arrêter. session : claude ou codex dont le dossier courant est sous <racine>/.worktrees/<couloir> retiré
# (lsof garde le chemin d'un dossier supprimé) ; orphan : processus hors agent repris par launchd depuis TOP_ORPHAN_AGE dans un dossier
# de couloir, présent ou retiré (top_lane_orphans de lib/top.sh). Compte courant seul ; ps illisible, ou lsof absent : rc 2, rien.
lane_leftovers() {
  local root="$1" real ps_out agents found="" k pid lane rows=""
  close_top_load
  real="$(cd "$root" 2>/dev/null && pwd -P)" || real="$root"
  ps_out="$(LC_ALL=en_US.UTF-8 ps -axww -o pid=,ppid=,uid=,stat=,rss=,%cpu=,etime=,args= 2>/dev/null)" || return 2
  [ -n "$ps_out" ] || return 2
  command -v lsof >/dev/null 2>&1 || return 2
  agents="$(printf '%s\n' "$ps_out" | LC_ALL=C awk -v uid="$(id -u)" "$TOP_AWK_LIB"'
    ps_parse($0) && P_UID == uid { a = agent_of(P_ARGS); if (a == "claude" || a == "codex") printf "%s%s", (n++ ? "," : ""), P_PID }')"
  if [ -n "$agents" ]; then
    found="$({ LC_ALL=en_US.UTF-8 lsof -a -d cwd -p "$agents" -Fpfn 2>/dev/null || true; } | LC_ALL=C awk -v a="$root/.worktrees/" -v b="$real/.worktrees/" '
      /^p/ { p = substr($0, 2); next }
      /^n/ { d = substr($0, 2); r = (index(d, a) == 1) ? a : (index(d, b) == 1) ? b : ""; if (r == "") next
        l = substr(d, length(r) + 1); sub(/\/.*$/, "", l); if (l != "") print "session\t" p "\t" l }')"
  fi
  found="$found${found:+$'\n'}$(top_lane_orphans "$ps_out" "-"$'\t'"$root"$'\n'"-"$'\t'"$real" | awk -F '\t' '{ print "orphan\t" $1 "\t" $3 }')"
  while IFS=$'\t' read -r k pid lane; do
    [ -n "$pid" ] || continue
    [ "$k" = orphan ] || [ ! -d "$root/.worktrees/$lane" ] || continue   # une session dans un couloir présent y travaille
    rows="$rows$k"$'\t'"$pid"$'\t'"$lane"$'\n'
  done <<<"$found"
  [ -n "$rows" ] || return 0
  printf '#R\n%s#S\n%s\n' "$rows" "$ps_out" | LC_ALL=C awk -F '\t' "$TOP_AWK_LIB"'
    function age(s) { return (s >= 86400) ? int(s / 86400) "d" : (s >= 3600) ? int(s / 3600) "h" : int(s / 60) "m" }
    /^#[A-Z]$/ { sec = substr($0, 2); next }
    sec == "R" { if (!(($2) in K)) { n++; ORD[n] = $2 } K[$2] = $1; L[$2] = $3; next }
    sec == "S" && ps_parse($0) { NM[P_PID] = name_of(P_ARGS); ET[P_PID] = etime_s(P_ET) }
    END { for (i = 1; i <= n; i++) { p = ORD[i]; if (p in NM) print K[p] "\t" p "\t" NM[p] "\t" age(ET[p]) "\t" L[p] } }'
}

# ---------- session vivante sans verrou (lot 01 de reprise-apres-migration) ----------
# lane_live_agents_load <racine> : LIVE_AGENTS = « pid<TAB>agent<TAB>couloir<TAB>appelant (1|0) » par session claude ou codex
# vivante du compte dont le dossier courant est sous <racine>/.worktrees/<couloir> (même règle que top_attach, via=cwd) ; un ps et
# un lsof par commande et par racine (cache LIVE_AGENTS_ROOT). rc 2 si ps ou lsof est illisible : état incertain, l'appelant ne
# refuse jamais sur ce doute (même règle que pid_state).
lane_live_agents_load() {
  local root="$1" real agents self="" cwds rc=0 rest pids=""
  if [ "${LIVE_AGENTS_ROOT:-}" = "$root" ]; then return "${LIVE_AGENTS_RC:-0}"; fi
  LIVE_AGENTS_ROOT="$root"; LIVE_AGENTS=""; LIVE_AGENTS_RC=2
  close_top_load
  real="$(cd "$root" 2>/dev/null && pwd -P)" || real="$root"
  self="$(agent_pid_found 2>/dev/null)" || self=""
  # lue par awk directement : la table entière d'un Mac chargé (2 000 processus, 700 Ko) ne passe plus par une variable du shell
  agents="$({ LC_ALL=en_US.UTF-8 ps -axww -o pid=,ppid=,uid=,stat=,rss=,%cpu=,etime=,args= 2>/dev/null || printf '\034\n'; } | LC_ALL=C awk -v uid="$EUID" "$TOP_AWK_LIB"'
    $0 == "\034" { bad = 1 }
    NF { n++ }
    (index($0, "claude") || index($0, "codex")) && ps_parse($0) && P_UID == uid { a = agent_of(P_ARGS); if (a == "claude" || a == "codex") out = out P_PID "\t" a "\n" }
    END { if (bad || !n) print "\034"; else printf "%s", out }')" || return 2
  [ "$agents" != $'\034' ] || return 2
  command -v lsof >/dev/null 2>&1 || return 2
  [ -n "$agents" ] || { LIVE_AGENTS_RC=0; return 0; }
  # lsof rend 1 dès qu'un des pid a disparu entre ps et lui : seul un échec sans aucune ligne vaut table illisible (revue du lot)
  rest="$agents"$'\n'
  while [ -n "$rest" ]; do pids="$pids${pids:+,}${rest%%$'\t'*}"; rest="${rest#*$'\n'}"; done
  cwds="$(LC_ALL=en_US.UTF-8 lsof -a -d cwd -p "$pids" -Fpn 2>/dev/null)" || rc=$?
  if [ "$rc" != 0 ] && [ -z "$cwds" ]; then return 2; fi
  LIVE_AGENTS_RC=0
  LIVE_AGENTS="$(printf '%s\n' "$cwds" \
    | LIVE_AG="$agents" LC_ALL=C awk -v a="$root/.worktrees/" -v b="$real/.worktrees/" -v self="$self" '
      BEGIN { n = split(ENVIRON["LIVE_AG"], rows, "\n"); for (i = 1; i <= n; i++) { split(rows[i], f, "\t"); A[f[1]] = f[2] } }
      /^p/ { p = substr($0, 2); next }
      /^n/ { d = substr($0, 2); r = (index(d, a) == 1) ? a : (index(d, b) == 1) ? b : ""; if (r == "" || !(p in A)) next
        l = substr(d, length(r) + 1); sub(/\/.*$/, "", l); if (l != "") print p "\t" A[p] "\t" l "\t" (p == self ? 1 : 0) }')" || true
  return 0
}
# lane_unlocked_live <worktree> [caller] : rc 0 et UNLOCKED_LIVE=<pid>:<agent> si une session vivante travaille dans ce couloir alors
# que son verrou est libre (ou prouvé mort) ; rc 1 sinon, rc 2 si la table des processus est illisible. L'agent appelant n'est
# compté qu'avec « caller » : status et doctor ne le nomment jamais ; next, launch et open, si (lab next ne remplace que la session
# qui tient le verrou). Hors substitution : le cache sert à toute la commande (lab status lit chaque couloir).
lane_unlocked_live() {
  local wt="$1" with="${2:-}" root lane rest row pid agent l self; UNLOCKED_LIVE=""
  if [ "${3:-}" = locked-checked ]; then :   # état du verrou déjà lu par l'appelant (describe_wt)
  else lock_state_set "$wt"; case "$LOCK_STATE" in free|dead:*) ;; *) return 1 ;; esac; fi
  root="${wt%/*}"; root="${root%/*}"; lane="${wt##*/}"
  lane_live_agents_load "$root" || return 2
  rest="$LIVE_AGENTS"
  while [ -n "$rest" ]; do
    row="${rest%%$'\n'*}"
    case "$rest" in *$'\n'*) rest="${rest#*$'\n'}" ;; *) rest='' ;; esac
    IFS=$'\t' read -r pid agent l self <<<"$row" || true
    if [ "$l" = "$lane" ] && { [ "$self" = 0 ] || [ "$with" = caller ]; }; then UNLOCKED_LIVE="$pid:$agent"; return 0; fi
  done
  return 1
}
# unlocked_live_refuse <worktree> : refus des commandes qui ouvrent une session (next, launch, open) — aucune seconde session
unlocked_live_refuse() {
  lane_unlocked_live "$1" caller || return 0
  die "live session without lock in $1 (pid ${UNLOCKED_LIVE%%:*}, ${UNLOCKED_LIVE#*:}): its lock is taken at its next tool — use a tool in that session, or close it; no second session opened"
}

# ---------- abandon : un couloir sans commit ni PR se retire explicitement ----------
# Retour 5 du lot 01 : un couloir créé sans jamais rien committer n'avait ni recette ni PR ; close le refusait, sweep n'y touche pas.
# Le retrait exige --abandon et la même confirmation nommée que close ; chaque refus nomme ce qui l'empêche, rien n'est retiré sur un doute.
close_lane_branches() { # branche courante puis celles annoncées par les fiches du couloir, sans doublon ; lecture seule
  local names name file branch seen
  branch="$(branch_name "$WT")"; [ -n "$branch" ] || return 0
  printf '%s\n' "$branch"; seen="$branch"
  names="$(lane_plan_names "$WT")"; [ -n "$names" ] || return 0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    file="$(lots_dir "$(docs_dir "$WT")" "$SLUG")/$name.md"
    [ -f "$file" ] || file="$(lots_dir "$(docs_dir "$WT")")/$name.md"
    [ -f "$file" ] || continue
    branch="$(close_branch_of "$file")"; [ -n "$branch" ] || continue
    grep -Fxq "$branch" <<<"$seen" && continue
    has_local_branch "$P_ROOT" "$branch" || continue
    printf '%s\n' "$branch"; seen="$seen
$branch"
  done <<<"$names"
}
close_abandon_scan() { # pose CLOSE_ABANDON_BRANCHES, CLOSE_ABANDON_FILES (non suivis sous docs/, partent avec le dossier) et
  # CLOSE_ABANDON_OBSTACLE : la première cause qui interdit l'abandon, vide si le couloir n'a ni commit ni PR ni travail non enregistré
  local branch start info line path remote_head rc work=""
  CLOSE_ABANDON_OBSTACLE=""; CLOSE_ABANDON_FILES=""
  CLOSE_ABANDON_BRANCHES="$(close_lane_branches)"
  [ -n "$CLOSE_ABANDON_BRANCHES" ] || { CLOSE_ABANDON_OBSTACLE="detached HEAD in $WT: git -C $WT switch <branch> first"; return; }
  while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    start=""; [ "$branch" != "$(branch_name "$WT")" ] || start="$(wt_meta "$WT" start)"
    start="$(branch_start "$P_ROOT" "$branch" "$start")"   # sans départ connu, « aucun commit » ne se prouve pas (revue du lot 02)
    [ -n "$start" ] || { CLOSE_ABANDON_OBSTACLE="start of $branch unknown: the absence of commits cannot be proven"; return; }
    if branch_has_work "$P_ROOT" "$branch" "$start"; then
      CLOSE_ABANDON_OBSTACLE="branch $branch carries $(git -C "$P_ROOT" rev-list --count "$start..$branch") commit(s) since its start"; return
    fi
    if ! branch_in_base "$P_ROOT" "$(branch_base_tip "$P_ROOT" "$branch")" "$P_BASE" "$P_STAGING"; then
      CLOSE_ABANDON_OBSTACLE="branch $branch outside $(pr_base) (different base)"; return
    fi
    info="$(pr_info_strict "$P_ROOT" "$branch")" || { CLOSE_ABANDON_OBSTACLE="PR of $branch cannot be checked (gh missing, offline or failed)"; return; }
    [ -z "$info" ] || { CLOSE_ABANDON_OBSTACLE="branch $branch has a PR #$(printf '%s' "$info" | cut -f1) ($(printf '%s' "$info" | cut -f2))"; return; }
    ! close_branch_elsewhere "$branch" || { CLOSE_ABANDON_OBSTACLE="branch $branch used by another lane"; return; }
    # le distant se lit et vaut le local avant tout détachement : un retrait interrompu ne laisse pas un couloir irrécupérable
    rc=0; remote_head="$(git -C "$WT" ls-remote --exit-code "$P_REMOTE" "refs/heads/$branch" 2>/dev/null)" || rc=$?
    case "$rc" in 0|2) ;; *) CLOSE_ABANDON_OBSTACLE="remote branch $branch cannot be checked (offline?)"; return ;; esac
    remote_head="${remote_head%%$'\t'*}"
    [ -z "$remote_head" ] || [ "$remote_head" = "$(git -C "$P_ROOT" rev-parse --verify "refs/heads/$branch")" ] \
      || { CLOSE_ABANDON_OBSTACLE="local and remote branch $branch differ"; return; }
  done <<<"$CLOSE_ABANDON_BRANCHES"
  # fichiers : un fichier suivi modifié ou un fichier non suivi hors docs/ est du travail, tous nommés ; les documents semés partent avec le dossier, listés avant confirmation
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path="${line:3}"
    case "$line" in
      '?? docs/'*) CLOSE_ABANDON_FILES="$CLOSE_ABANDON_FILES$path"$'\n' ;;
      *) work="$work${work:+, }$path" ;;
    esac
  done < <(git -C "$WT" -c core.quotePath=false status --porcelain --untracked-files=all)
  [ -z "$work" ] || CLOSE_ABANDON_OBSTACLE="uncommitted changes outside the lane documents: $work"
}
close_abandon_guard() {
  close_session_guard
  close_abandon_scan
  [ -z "$CLOSE_ABANDON_OBSTACLE" ] || die "$CLOSE_ABANDON_OBSTACLE: nothing abandoned — deliver this work (lab merge $P_NAME $SLUG) or remove it yourself, then run lab close $P_NAME $SLUG --abandon again"
}
close_abandon() { # <confirmation> <posée=0|1>
  local branches files ws surface name docs branch head current vm cws
  close_abandon_guard
  branches="$CLOSE_ABANDON_BRANCHES"; files="$CLOSE_ABANDON_FILES"
  ws="$(wt_ws "$WT")"; surface="$(wt_surface "$WT")"; name="$(wt_cmux_value "$WT" name)"; name="${name:-$SLUG}"
  kv PROJECT "$P_NAME"; kv LANE "$SLUG"; kv BRANCH "$(branch_name "$WT")"
  printf 'Abandon the lane %s: no commit, no PR, nothing to deliver.\nRemoval: folder %s\nEmpty branches removed, local and remote:\n' "$SLUG" "$WT" >&2
  printf '%s\n' "$branches" | sed 's/^/  /' >&2
  if [ -n "$files" ]; then printf 'Uncommitted files removed with the folder:\n' >&2; printf '%s' "$files" | sed 's/^/  /' >&2; fi
  docs="$(docs_dir "$WT")"
  case "$docs" in "$WT"/*) ;; *) printf 'External documents kept, remove them yourself: %s and %s\n' "$(treeplan_file "$docs" "$SLUG")" "$(lots_dir "$docs" "$SLUG")" >&2 ;; esac
  printf 'Target tab: %s (%s)\n' "$name" "${surface:-not assigned}" >&2
  services_show "$WT"
  close_procs_show "$(close_procs_plan)"
  close_confirm "$1" "$2" abandon || return 0
  load_project "$PROJECT"; close_abandon_guard
  [ "$CLOSE_ABANDON_BRANCHES" = "$branches" ] && [ "$CLOSE_ABANDON_FILES" = "$files" ] || die "lane changed during the confirmation: run lab close $P_NAME $SLUG --abandon again"
  current="$(branch_name "$WT")"
  git -C "$WT" switch --quiet --detach || die "removal preparation refused: lane kept"
  while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    head="$(git -C "$P_ROOT" rev-parse --verify "refs/heads/$branch")"
    ( close_remove_branch "$branch" "$head" ) && continue
    # un retrait interrompu rend la branche au couloir : --abandon se relance après correction (revue du lot 02)
    if git -C "$WT" switch --quiet "$current" 2>/dev/null; then die "removal interrupted: lane kept on $current; run lab close $P_NAME $SLUG --abandon again after fixing it"; fi
    die "removal interrupted on a detached HEAD: git -C $WT switch <branch>, then run lab close $P_NAME $SLUG --abandon again"
  done <<<"$branches"
  vm="$(wt_meta "$WT" cloud_machine)"; cws="$(cloud_pane | cut -f1)"   # workspace de la ligne d'état Cloud (lot 09)
  cd "$P_ROOT" || die "main checkout not found"
  services_close "$WT"   # le crochet du projet voit encore son dossier (lot 01 de services-couloir)
  close_procs_stop "$ws" "$surface"
  git -C "$P_ROOT" worktree remove --force "$WT" || die "branches removed but folder kept: git -C $WT switch <branch> is no longer possible, remove the folder with git -C $P_ROOT worktree remove --force $WT"
  agreement_clear "$SLUG"; rm -f "$(night_agreed_file)" "$(close_retire_file)"
  codex_trust_remove "$WT" || die "lane removed, Codex entry to check"
  close_tab "$ws" "$surface" "$name"
  cloud_close_vm "$vm" "$SLUG" "$cws"   # après le retrait seulement : un refus plus haut garde la VM (lot 05)
  kv ACTION abandoned; log "Lane $SLUG abandoned: folder and empty branches removed, nothing delivered."
}

# close_recheck <révision> <base> : avant toute fusion, la base relue fraîche — essai à blanc puis contrôle de régression hors couloir
# (lot 04 de mise-en-ligne, comme lab merge et le veilleur) ; conflit, régression ou base illisible → refus nommé, rien fusionné.
# Les commits retirés voulus viennent de --retire (CLOSE_RETIRE) ; départ du lot inconnu : conflit seul vérifié.
close_recheck() {
  local ref="$P_REMOTE/$2" rc=0
  with_timeout "${LAB_SYNC_TIMEOUT:-30}" git -C "$WT" fetch --quiet "$P_REMOTE" "$2" 2>/dev/null \
    || die "fresh base $ref unreadable (offline?): nothing merged, lane kept; run lab close $P_NAME $SLUG again"
  sync_dry "$WT" "$ref" "$1" || rc=$?
  case "$rc" in
    1) die "conflict with the fresh base $ref on $(printf '%s\n' "$SYNC_FILES" | sync_join): nothing merged, lane kept — lab sync $P_NAME $SLUG, resolve with git merge, redo the acceptance, then run lab close $P_NAME $SLUG again" ;;
    2) warn "dry run impossible ($ref missing or git < 2.38): merge not checked again" ;;
  esac
  rc=0; merge_regression "$WT" "$ref" "$(lot_start)" "$1" "${CLOSE_RETIRE[@]+"${CLOSE_RETIRE[@]}"}" || rc=$?
  case "$rc" in
    1) kv REGRESSION "$(printf '%s\n' "$REGRESSION_LIST" | wc -l | tr -d ' ') range(s)"
       regression_report "$ref" "lab close $P_NAME $SLUG${CLOSE_CONFIRMED:+ --confirm $SLUG}"   # --confirm : seulement après l'accord
       die "regression outside the lane on the fresh base: nothing merged, lane kept" ;;
    2) warn "regression check impossible (batch start unknown in .lab/meta): only the conflict checked" ;;
    *) kv REGRESSION none ;;
  esac
  rc=0; migrations_collide "$WT" "$ref" "$1" || rc=$?
  if [ "$rc" = 1 ]; then
    kv MIGRATIONS collision; migrations_report "$ref"
    die "colliding migration on the fresh base: nothing merged, lane kept; run lab close $P_NAME $SLUG again after the rename"
  fi
  [ "$rc" != 2 ] || { kv MIGRATIONS not-checkable; warn "migrations check impossible ($ref unreadable): numbers not checked"; }
}

# ---------- lot 04 d'onglet-tower : un seul « oui ferme » ----------
# --retire gardé : chaque SHA d'un lab close confirmé dont le contrôle de régression est passé (jamais un essai à blanc, ni une
# fermeture refusée avant l'accord) est rangé hors du couloir, dans $LAB_STATE/<projet>/retire/<couloir> (700/600), puis relu par
# chaque lab close de ce couloir, celui de la tour compris, qui le nomme (RETIRE_KEPT=) ; parti avec le couloir. Un SHA devenu
# illisible est sauté, nommé.
close_retire_file() { printf '%s/%s/retire/%s\n' "$LAB_STATE" "$P_NAME" "$SLUG"; }
close_retire_keep() {
  local f; f="$(close_retire_file)"
  [ "${#CLOSE_RETIRE[@]}" -gt 0 ] || return 0
  ( umask 077; mkdir -p "$(dirname "$f")" && { cat "$f" 2>/dev/null || true; printf '%s\n' "${CLOSE_RETIRE[@]}"; } | sort -u >"$f.tmp.$$" \
    && mv "$f.tmp.$$" "$f" && chmod 600 "$f" ) 2>/dev/null || warn "--retire not kept for the tower ($f): give it again at the next lab close"
}
close_retire_load() {
  local f r h have kept=""; f="$(close_retire_file)"
  [ -f "$f" ] && [ ! -L "$f" ] || return 0
  while IFS= read -r r; do
    [[ "$r" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || continue
    git -C "$WT" cat-file -e "$r^{commit}" 2>/dev/null || { warn "kept --retire ${r:0:7} unreadable in $WT: skipped"; continue; }
    have=0; for h in "${CLOSE_RETIRE[@]+"${CLOSE_RETIRE[@]}"}"; do [ "$h" != "$r" ] || have=1; done
    [ "$have" = 1 ] || CLOSE_RETIRE+=("$r")
    kept="${kept:+$kept }${r:0:7}"
  done <"$f"
  [ -z "$kept" ] || kv RETIRE_KEPT "$kept"
}
# close_after_set : CLOSE_AFTER, ce qui a changé après le oui de l'utilisateur (accord par les mots seulement) ; vide sinon
close_after_set() {
  CLOSE_AFTER=""
  agreement_by_words "$WT" || return 0
  local lot; lot="$(wt_lot_file "$WT")"
  CLOSE_AFTER="$(recette_after_agreement "$WT" "$(recette_revision_of "$(recette_field "$lot" 'Révision essayée')")" "$lot")"
}

# ---------- lab close --dry-run (lot 01 de livrer-sans-friction) : tous les obstacles d'un coup, rien modifié ----------
# Chaque garde se joue en sous-shell : son die devient une ligne OBSTACLE=<clé>: <message et remède>, la suivante est jouée quand même.
# Ni enregistrement des fiches, ni fetch, ni « prête », ni fusion, ni veilleur : lectures locales et lectures GitHub seulement.
close_obstacle() { kv OBSTACLE "$1: $2"; CLOSE_BLOCKED=1; }
close_try() { # <clé> <garde…> : rc 0 si la garde passe ; sinon OBSTACLE avec son message (et ses lignes « - x »), rc 1
  local key="$1" err msg list rc=0; shift
  err="$(mktemp "${TMPDIR:-/tmp}/lab-close.XXXXXX")"
  ( "$@" ) >/dev/null 2>"$err" || rc=$?
  msg="$(sed -n "s/^$DIE_PREFIX//p" "$err" | tail -1)"; list="$(sed -n 's/^  - //p' "$err" | sync_join)"
  rm -f "$err"
  [ "$rc" != 0 ] || return 0
  close_obstacle "$key" "${msg:-check failed (code $rc)}${list:+: $list}"; return 1
}
close_base_check() { # <révision> <base> : comme close_recheck, sur la base déjà connue localement (sans fetch)
  local ref="$P_REMOTE/$2" rc=0
  sync_dry "$WT" "$ref" "$1" || rc=$?
  [ "$rc" != 1 ] || die "conflict with the base $ref (last local read) on $(printf '%s\n' "$SYNC_FILES" | sync_join) — lab sync $P_NAME $SLUG, resolve with git merge, then redo the acceptance"
  rc=0; merge_regression "$WT" "$ref" "$(lot_start)" "$1" "${CLOSE_RETIRE[@]+"${CLOSE_RETIRE[@]}"}" || rc=$?
  [ "$rc" != 1 ] || die "regression outside the lane on the base $ref: $(printf '%s\n' "$REGRESSION_LIST" | sync_join) — restore these lines or confirm their removal with --retire <sha>"
}
# close_recette_pending : docs externes, seule la fiche du couloir est sale et seule sa section de recette a changé depuis HEAD —
# lab close l'enregistrera (docs_commit) avant ses contrôles : pas un obstacle, une note (revue du lot 01)
close_recette_pending() {
  local lot droot rel path dirty; local -a paths=()
  lot="$(wt_lot_file "$WT")"; droot="$(docs_repo_root "$WT")"
  [ -n "$lot" ] && [ -n "$droot" ] && ! same_path "$WT" "$droot" || return 1
  lot="$(real_path "$(dirname "$lot")")/$(basename "$lot")"; rel="${lot#"$droot"/}"
  while IFS= read -r path; do [ -n "$path" ] && paths+=("$path"); done < <(lane_doc_paths "$WT")
  dirty="$(git -C "$droot" -c core.quotePath=false status --porcelain --untracked-files=all -- "${paths[@]+"${paths[@]}"}" | cut -c4-)"
  [ "$dirty" = "$rel" ] && git -C "$droot" cat-file -e "HEAD:$rel" 2>/dev/null || return 1
  [ "$(git -C "$droot" show "HEAD:$rel" | recette_filter strip)" = "$(recette_filter strip <"$lot")" ]
}
close_pr_dump() { close_pr_read; printf '%s\t%s\t%s\t%s\n' "$CLOSE_PR_HEAD" "$CLOSE_PR_BASE" "$CLOSE_PR_STATE" "$CLOSE_MERGED"; }
# close_obstacles : imprime une ligne OBSTACLE par obstacle, puis RESULT=ok|blocked ; rc 0 si ok, 1 sinon
close_obstacles() {
  local info data problems key msg checks gh_ok=1 CLOSE_DRY=1   # lu par close_stack_check : aucune base relue
  CLOSE_BLOCKED=0
  close_abandon_scan
  if [ -z "$CLOSE_ABANDON_OBSTACLE" ]; then
    close_obstacle empty "lane $SLUG has no commit and no PR: nothing to deliver — lab close $P_NAME $SLUG --abandon removes it after a named confirmation"
  else
    close_try waiting close_waiting_guard || true
    close_try files close_dirty_guard || true
    close_try end close_end_guard || true
    if [ "$(recette_status "$WT" "$(wt_lot_file "$WT")")" = unversioned ] && close_recette_pending; then
      kv NOTE "acceptance: only the acceptance section is uncommitted — lab close will commit it in the batch files repository (DOCS_COMMIT) before its checks"
    else close_try acceptance close_recette_check || true; fi
    close_after_set; [ -z "$CLOSE_AFTER" ] || kv AFTER_AGREEMENT "$CLOSE_AFTER"   # lot 04 d'onglet-tower
    close_try session close_session_guard || true
    # lot 03 de ci-sobre : nuit de la base rouge, lue ici (le cache seul s'écrit) ; l'accord n'est écrit que par lab close
    night_refresh || true
    ci_refresh_bg   # lot 04 de ci-sobre : minutes de CI pour lab doctor, détaché, une fois par jour au plus
    if night_red "$P_NAME"; then
      local proof
      if [ "${CLOSE_NIGHT_SET:-0}" = 1 ]; then kv NOTE "night red: lab close will record the agreement in the acceptance section — $CLOSE_NIGHT_OK"
      elif proof="$(night_fix_proof "$(git -C "$WT" rev-parse HEAD 2>/dev/null)")"; then   # lot 02 de fix-nuit-2026-11-14
        kv NOTE "night red: $(night_proof_reason "${proof% *}" "${proof#* }" | sed 's/^proof of fix:/proof of fix —/'): lab close will record the agreement in the acceptance section"
      elif words_valid "$WT" night; then   # lot 10 : le clic de l'utilisateur sur le bouton de la nuit rouge, lu par lab
        kv NOTE "night red: $(night_words_reason): lab close will record the agreement in the acceptance section"
      elif night_agreed_here "$(wt_lot_file "$WT")"; then
        kv NOTE "night red: agreement for this night already in the acceptance section"   # revue du lot 10 : relance
      elif agreement_by_words "$WT"; then   # lot 04 d'onglet-tower : le oui de fermer couvre la nuit
        kv NOTE "night red: $(night_order_reason): lab close will record the agreement in the acceptance section"
      else close_obstacle night "$(night_refusal_for_caller)"; fi
    fi
    close_branch_values
    close_try branch close_branch_check || true
    close_try delivery delivery_guard || true
    CLOSE_NUM=""; CLOSE_PR_STATE=""
    if [ -z "$CLOSE_BRANCH" ]; then gh_ok=0   # branche illisible, déjà nommée : rien à demander à GitHub
    elif ! has_gh; then gh_ok=0; close_obstacle github "cannot be checked: gh missing — PR, CI and old branches not checked; install gh, then run lab close $P_NAME $SLUG --dry-run again"
    elif ! info="$(pr_info_strict "$P_ROOT" "$CLOSE_BRANCH")" || ! close_repo_resolve; then
      gh_ok=0; close_obstacle github "cannot be checked: gh failed or offline — PR, CI and old branches not checked; run lab close $P_NAME $SLUG --dry-run again once GitHub is reachable"
    elif ! [[ "$CLOSE_REPO" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then gh_ok=0; close_obstacle github "cannot be checked: GitHub repository unreadable (\"$CLOSE_REPO\")"
    elif [ -z "$info" ]; then
      if close_lot_empty; then
        CLOSE_PR_STATE=EMPTY; CLOSE_MERGED="$CLOSE_HEAD"
        kv NOTE "empty batch: no PR for $CLOSE_BRANCH, already contained in $P_REMOTE/$CLOSE_BASE (local read) — closing without a PR"
        close_try old-branches close_empty_old_lots || true
      else close_obstacle pr "$(close_no_pr_message)"; fi
    else
      CLOSE_NUM="$(printf '%s' "$info" | cut -f1)"
      if ! [[ "$CLOSE_NUM" =~ ^[0-9]+$ ]]; then gh_ok=0; close_obstacle github "cannot be checked: PR number unreadable (\"$CLOSE_NUM\")"
      elif ! data="$( (close_pr_dump) 2>/dev/null )"; then
        gh_ok=0; close_obstacle github "cannot be checked: PR #$CLOSE_NUM unreadable by gh (offline?); run lab close $P_NAME $SLUG --dry-run again"
      else
        IFS=$'\t' read -r CLOSE_PR_HEAD CLOSE_PR_BASE CLOSE_PR_STATE CLOSE_MERGED <<<"$data"
        if problems="$(close_pr_problems)"; then
          ! close_bilan_wanted \
            || kv NOTE "summary: PR merged before the acceptance, summary delivered by a dedicated PR (chore/$SLUG-recette)"
        fi
        while IFS=$'\t' read -r key msg; do
          case "$key" in "") ;; stack) kv NOTE "stack: $msg" ;; delivered) kv NOTE "delivered: $msg" ;; *) close_obstacle "$key" "$msg" ;; esac
        done <<<"$problems"
        if [ "$CLOSE_PR_STATE" = OPEN ]; then
          checks="$(pr_checks_now "$WT" "$CLOSE_NUM" "$CLOSE_HEAD" "$CLOSE_BRANCH" "$CLOSE_BASE")"; kv CHECKS "$checks"
          [ "$checks" != red ] || close_obstacle ci "red checks: fix them; lane kept"
        fi
      fi
    fi
    [ "$gh_ok" = 0 ] || close_try branch-list close_collect_branches || true
    case "$CLOSE_PR_STATE" in MERGED|EMPTY) ;; *) close_try base close_base_check "$CLOSE_HEAD" "$CLOSE_BASE" || true ;; esac
  fi
  kv SERVICES "$(services_state "$WT")"   # le crochet est seulement annoncé : --dry-run ne le lance jamais
  close_procs_kv "$(close_procs_plan)"   # ce que la fermeture arrêterait, rien n'est arrêté ici
  # lot 08 : projet doté d'une tour — la tour sait avant lab close si elle ferme seule ; aucun contrôle relancé ici
  if deploy_tower_project; then
    if agreement_by_words "$WT"; then kv CLOSE_ALONE "yes: on the user's words (\"$AG_SAID\")"   # lot 10 : leurs mots sont l'ordre
    else close_alone_state "$WT" "$SLUG" 0; kv CLOSE_ALONE "$CA_OK: $CA_WHY"; fi
  fi
  if [ "$CLOSE_BLOCKED" = 0 ]; then kv RESULT ok; return 0; fi
  kv RESULT blocked; return 1
}

cmd_close() {
  local confirmation="" confirmation_set=0 abandon=0 dry=0 r; local -a pos=() retire=(); CLOSE_RETIRE=()
  CLOSE_NIGHT_OK=""; CLOSE_NIGHT_SET=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --confirm) [ "$#" -ge 2 ] || usage; confirmation="$2"; confirmation_set=1; shift 2 ;;
      --night-red-ok) [ "$#" -ge 2 ] || usage; CLOSE_NIGHT_OK="$2"; CLOSE_NIGHT_SET=1; shift 2 ;;
      --retire) [ "$#" -ge 2 ] || usage; retire+=("$2"); shift 2 ;;
      --abandon) abandon=1; shift ;; --dry-run) dry=1; shift ;; -*) usage ;; *) pos+=("$1"); shift ;;
    esac
  done
  [ "${#pos[@]}" -ge 1 ] && [ "${#pos[@]}" -le 2 ] || usage
  # un motif d'une ligne, non vide : il est écrit tel quel dans la fiche
  if [ "$CLOSE_NIGHT_SET" = 1 ]; then
    case "$CLOSE_NIGHT_OK" in *[$'\n\r']*) die "--night-red-ok: the reason fits on a single line" ;; esac
    [ -n "${CLOSE_NIGHT_OK//[[:space:]]/}" ] || die "--night-red-ok: empty reason — say why the lane is closed despite the red night"
  fi
  split_project_slug "${pos[@]+"${pos[@]}"}"; load_project "$PROJECT"
  valid_slug "$SLUG" || die "invalid lane name"
  WT="$(worktree_path "$SLUG")"
  if [ ! -d "$WT" ]; then rm -f "$(close_retire_file)"; kv ACTION absent; log "Lane $SLUG already gone: nothing else removed."; return; fi
  [ ! -L "$WT" ] && same_path "$(main_root "$WT")" "$P_ROOT" && [ "$(wt_lane "$WT")" = "$SLUG" ] || die "folder does not match the expected lane: nothing removed"
  # lot 06 d'autonomie-tours : projet doté d'une tour — la fermeture est un geste de la tour, sur le oui de l'utilisateur
  local role="" alone=0 words=0; [ "$dry" = 1 ] || role="$(tower_guard_role)"
  # lot 10 : l'accord venu des mots de l'utilisateur (via=words close=yes, lu par le crochet de lab) est aussi son ordre de fermer —
  # l'agent du couloir ou la tour ferment sans --confirm, couloir servi par aucune cible compris ; sans lui, rien ne change
  [ "$dry" = 1 ] || [ "$abandon" = 1 ] || ! agreement_by_words "$WT" || words=1
  if [ "$role" = lane-agent ] && [ "$words" = 0 ]; then
    die "closing lane $SLUG belongs to the tower of $P_NAME: the tower closes it at its next round, your acceptance is its order — nothing removed; the user's own words, read by lab in this tab, also let it close here$(tower_session_note)"
  fi
  # lot 08 : la tour sans --confirm ferme seule sur les trois verts, sinon elle demande à l'utilisateur
  if [ "$role" = tower ] && [ "$confirmation_set" = 0 ] && [ "$abandon" = 0 ] && [ "$words" = 0 ]; then
    [ "$CLOSE_NIGHT_SET" = 0 ] || die "closing $SLUG alone refused: --night-red-ok records the user's agreement — ask the user, then lab close $P_NAME $SLUG --confirm $SLUG --night-red-ok <their reason> on their yes; nothing removed"
    close_alone_state "$WT" "$SLUG" 1
    [ "$CA_OK" = yes ] || die "closing $SLUG alone refused: $CA_WHY — ask the user, then lab close $P_NAME $SLUG --confirm $SLUG on their yes; nothing removed"
    alone=1; log_wrap "closing $SLUG alone: $CA_WHY."
  fi
  [ "$dry" = 1 ] || cloud_close_guard   # session de lot vivante sur sa VM : rien n'est retiré (lot 05 de cmux-pro)
  if lane_permanent "$WT"; then   # avant toute autre garde : ni fermeture, ni abandon, ni essai à blanc qui dirait « ok »
    [ "$dry" = 1 ] || close_permanent_guard
    CLOSE_BLOCKED=0; close_try permanent close_permanent_guard || true; kv RESULT blocked; return 1
  fi
  if [ "$abandon:$dry" = 1:1 ]; then
    CLOSE_BLOCKED=0; close_try session close_session_guard || true; close_abandon_scan
    [ -z "$CLOSE_ABANDON_OBSTACLE" ] || close_obstacle abandon "$CLOSE_ABANDON_OBSTACLE: nothing abandoned"
    kv SERVICES "$(services_state "$WT")"   # annoncé, jamais lancé par un essai à blanc
    close_procs_kv "$(close_procs_plan)"
    if [ "$CLOSE_BLOCKED" = 0 ]; then kv RESULT ok; return 0; fi
    kv RESULT blocked; return 1
  fi
  if [ "$abandon" = 1 ]; then close_abandon "$confirmation" "$confirmation_set"; return; fi
  for r in "${retire[@]+"${retire[@]}"}"; do   # retrait voulu d'un commit hors couloir : SHA lisible, rangé complet (comme lab merge)
    r="$(git -C "$WT" rev-parse --verify --quiet "$r^{commit}" 2>/dev/null)" || die "--retire: unknown commit in $WT; run git fetch, then give the SHA named by the refusal"
    CLOSE_RETIRE+=("$r")
  done
  close_retire_load   # lot 04 d'onglet-tower : ceux qu'un lab close confirmé a déjà gardés pour ce couloir, nommés (RETIRE_KEPT)
  if [ "$dry" = 1 ]; then close_obstacles; return; fi
  close_abandon_scan   # un couloir vide n'a rien à livrer : la fermeture normale renvoie vers le retrait explicite
  [ -n "$CLOSE_ABANDON_OBSTACLE" ] || die "lane $SLUG has no commit and no PR: nothing to deliver — lab close $P_NAME $SLUG --abandon removes it after a named confirmation"
  docs_commit "$WT" acceptance   # la section de recette écrite par l'agent est versionnée par lab, jamais par lui (lot 03)
  night_close_gate "$CLOSE_NIGHT_OK" "$CLOSE_NIGHT_SET"   # lot 03 de ci-sobre : nuit de la base rouge → accord explicite, avant tout
  close_prepare
  local head="$CLOSE_HEAD" base="$CLOSE_BASE" records="$CLOSE_RECORDS" document ws surface name
  document="$(git hash-object "$CLOSE_LOT")"; ws="$(wt_ws "$WT")"; surface="$(wt_surface "$WT")"; name="$(wt_cmux_value "$WT" name)"; name="${name:-$SLUG}"
  local dest="$base (PR #$CLOSE_NUM)" pr_kv="#$CLOSE_NUM"
  [ "$CLOSE_PR_STATE" != EMPTY ] || { dest="$base (no PR: batch without commits, already contained)"; pr_kv=none; }
  [ -z "$CLOSE_STACK" ] || dest="$base (PR #$CLOSE_NUM via $CLOSE_PR_BASE, PR #$(printf '%s' "$CLOSE_STACK" | sed -n 's/.* by PR #\([0-9]*\).*/\1/p'))"
  kv PROJECT "$P_NAME"; kv LANE "$SLUG"; kv REVISION "$head"; kv PR "$pr_kv"; kv TARGET "$base"
  close_after_set; [ -z "$CLOSE_AFTER" ] || kv AFTER_AGREEMENT "$CLOSE_AFTER"   # lot 04 d'onglet-tower : ce qui a changé après le oui
  [ -z "$CLOSE_STACK" ] || kv NOTE "stack: $CLOSE_STACK"
  [ -z "$CLOSE_DELIVERED" ] || kv NOTE "delivered: $CLOSE_DELIVERED"
  printf 'Close the lane %s\nBatches:\n' "$SLUG" >&2
  local names
  names="$(lane_plan_names "$WT")"; [ -n "$names" ] || names="$(basename "$CLOSE_LOT" .md)"
  printf '%s\n' "$names" | sed 's/^/  /' >&2
  printf 'Tried result: %s\nTarget: %s\nRemoval: folder %s\nFinal branch: %s\nTarget tab: %s (%s)\nClosing removes this folder and this tab. The evidence stays versioned.\n' \
    "$(recette_revision_of "$(recette_field "$CLOSE_LOT" 'Révision essayée')")" "$dest" "$WT" "$CLOSE_BRANCH" "$name" "${surface:-not assigned}" >&2
  [ "$CLOSE_BILAN" != 1 ] || printf 'PR #%s already merged before the acceptance:\nsummary delivered by a dedicated PR (chore/%s-recette), then removed\n' "$CLOSE_NUM" "$SLUG" >&2
  printf 'Proven branches, local and remote, to remove:\n' >&2
  printf '%s\n' "$records" | awk -F '\t' '{ print "  " $1 ($5 == "" ? "" : " — " ($5 ~ /^#/ ? "delivered by " : "") $5) }' \
    | if { [ -t 2 ] || [ -n "${COLUMNS:-}" ]; } && declare -F onboard_wrap >/dev/null; then onboard_wrap "$(onboard_cols)"; else cat; fi >&2
  services_show "$WT"
  close_procs_show "$(close_procs_plan)"
  CLOSE_CONFIRMED=""; [ "$confirmation_set" = 0 ] || CLOSE_CONFIRMED=1
  [ "$CLOSE_PR_STATE" != OPEN ] || close_recheck "$head" "$base"   # refus nommé avant même de demander l'accord
  if [ "$alone" = 1 ]; then kv CLOSED_BY tower
  elif [ "$words" = 1 ] && [ "$confirmation_set" = 0 ]; then kv CLOSED_BY words; log_wrap "closing $SLUG on the user's words (\"$AG_SAID\"): no --confirm."
  else close_confirm "$confirmation" "$confirmation_set" close || return 0; fi
  CLOSE_CONFIRMED=1
  # lot 04 d'onglet-tower (revue de sécurité) : --retire gardé seulement ici — fermeture confirmée (mots, --confirm ou tour seule) et
  # contrôle de régression déjà passé avec eux ; jamais par un essai à blanc ni par une fermeture refusée plus haut
  close_retire_keep
  # lot 14 : la main est rendue — CI déjà verte (ou PR déjà fusionnée) → fermeture sur place ; CI en cours → veilleur qui fusionne
  # à la révision confirmée puis retire le couloir, en revérifiant tout (close_finish) ; rouge → rien
  # bilan (lot 01 de close-apres-fusion) : la PR dédiée est ouverte sur place ; ses contrôles décident comme ceux d'une PR ouverte
  local pr="$CLOSE_NUM" sha="$head" br="$CLOSE_BRANCH" state="$CLOSE_PR_STATE"
  if [ "$CLOSE_BILAN" = 1 ]; then
    delivery_guard; close_bilan_open
    pr="$CLOSE_BILAN_NUM" sha="$CLOSE_BILAN_HEAD" br="$CLOSE_BILAN_BRANCH" state="$CLOSE_BILAN_STATE"
  fi
  if [ "$state" = OPEN ]; then
    local checks
    [ "$CLOSE_BILAN" = 1 ] || { delivery_guard; pr_make_ready "$WT" "$CLOSE_NUM"; }
    # lot 02 de restes-cloud : seule la CI de la PR décide (verte → sur place, en cours → veilleur, rouge → refus)
    checks="$(pr_checks_now "$WT" "$pr" "$sha" "$br" "$base")"; kv CHECKS "$checks"
    [ "$checks" != none ] || pr_ci_kv "$WT" "$sha" "$br" "$base"
    case "$checks" in
      red) die "red checks${CLOSE_BILAN_NUM:+ on summary PR #$CLOSE_BILAN_NUM}: fix them; lane kept" ;;
      pending)
        local f; f="$(watch_file "$CLOSE_BRANCH")"; mkdir -p "$(dirname "$f")"; printf '%s\n' "$records" >"$f.records"
        watch_arm close "$CLOSE_BRANCH" pr="$pr" sha="$sha" head="$head" base="$base" document="$document" ws="$ws" surface="$surface" name="$name" \
          retire="${CLOSE_RETIRE[*]+"${CLOSE_RETIRE[*]}"}" alone="$alone" words="$words" after="${CLOSE_AFTER:-}"
        kv ACTION armed; log "lab close hands back: the watcher will merge #$pr at ${sha:0:12} after green CI, then remove $SLUG — outcome in lab status $P_NAME"
        [ "$alone" = 0 ] || close_alone_notify "closing alone: $SLUG at ${head:0:7}, the watcher merges #$pr after green CI"
        [ "$words" = 0 ] || close_words_notify "closing on the user's words: $SLUG at ${head:0:7}, the watcher merges #$pr after green CI${CLOSE_AFTER:+ — after the yes: $CLOSE_AFTER}"
        return 0 ;;
    esac
  fi
  close_finish "$head" "$base" "$records" "$document" "$ws" "$surface" "$name"
  [ "$alone" = 0 ] || close_alone_notify "closed alone: $SLUG delivered at ${head:0:7} to $dest — acceptance, served revision verified, prod check green"
  [ "$words" = 0 ] || close_words_notify "closed on the user's words: $SLUG delivered at ${head:0:7} to $dest${CLOSE_AFTER:+ — after the yes: $CLOSE_AFTER}"
  close_caller_tab   # lot 10 : en tout dernier — la session appelante, celle du couloir, part avec son onglet
}
# close_finish <révision> <base> <branches> <fiche> <workspace> <surface> <nom> : après confirmation, revérifie tout, livre, puis retire.
# Appelé sur place par lab close, ou plus tard par le veilleur (lot 14) : rien n'est retiré sur un doute.
close_finish() {
  local head="$1" base="$2" records="$3" document="$4" ws="$5" surface="$6" name="$7" vm cws
  load_project "$PROJECT"; cloud_close_guard; close_prepare
  [ "$CLOSE_HEAD" = "$head" ] && [ "$CLOSE_BASE" = "$base" ] && [ "$CLOSE_RECORDS" = "$records" ] && [ "$(git hash-object "$CLOSE_LOT")" = "$document" ] \
    || die "revision changed during the confirmation: new acceptance required; lane kept"
  close_deliver
  # Garder le dossier jusqu’à la réussite des retraits de branches : un refus
  # local laisse la fiche et ses métadonnées disponibles pour relancer close.
  close_recette_guard
  [ "$(git -C "$WT" rev-parse HEAD)" = "$head" ] || die "result changed after delivery: lane kept"
  git -C "$WT" switch --quiet --detach "$head" || die "removal preparation refused: lane kept"
  local branch revision number disposition pr_head
  while IFS=$'\t' read -r branch revision number disposition _ pr_head; do
    # commits après fusion : la PR fusionnée se relit à sa propre tête, la branche se retire à la sienne
    [ "$disposition" = current ] || [ "$number" = - ] || close_redundant_pr "$number" "${pr_head:-$revision}"
    # bilan, ou pile livrée (close-pile-branche) : la branche distante peut être restée à la tête fusionnée, sans les commits
    # de recette livrés par la PR dédiée ou la base suivie en local après la livraison
    if [ "$disposition" = current ] && { [ "$CLOSE_BILAN" = 1 ] || { [ -n "$CLOSE_STACK" ] && [ "$CLOSE_PR_STATE" = MERGED ]; }; }; then
      close_remove_branch "$branch" "$revision" "$CLOSE_PR_HEAD"
    else close_remove_branch "$branch" "$revision"; fi
  done <<<"$records"
  [ "$CLOSE_BILAN" != 1 ] || [ -z "$CLOSE_BILAN_HEAD" ] || close_remove_branch "$CLOSE_BILAN_BRANCH" "$CLOSE_BILAN_HEAD"
  vm="$(wt_meta "$WT" cloud_machine)"; cws="$(cloud_pane | cut -f1)"   # workspace de la ligne d'état Cloud (lot 09)
  cd "$P_ROOT" || die "main checkout not found"
  services_close "$WT"   # après la livraison, avant le retrait : le crochet voit encore son dossier (veilleur compris)
  close_procs_stop "$ws" "$surface"
  git -C "$P_ROOT" worktree remove ${SERVICES_FORCE:+--force} "$WT" || die "delivery done but folder kept: run lab close $P_NAME $SLUG again"
  agreement_clear "$SLUG"; words_clear "$SLUG"   # lots 09 et 10 : accord et mots partent avec le couloir, jamais hérités d'un homonyme
  rm -f "$(night_agreed_file)" "$(close_retire_file)"   # lot 04 d'onglet-tower : --retire gardé aussi
  codex_trust_remove "$WT" || die "lane removed, Codex entry to check"
  close_tab "$ws" "$surface" "$name"
  cloud_close_vm "$vm" "$SLUG" "$cws"   # après le retrait seulement (lot 05)
  kv ACTION closed; log "Lane $SLUG delivered and closed."
}
