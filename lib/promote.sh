# shellcheck shell=bash
# shellcheck disable=SC2034 # SLUG et WT sont lus par watch_arm, watch_file et watch_done (lib/watch.sh).
# promote.sh — lab promote (lot 16) : staging mène en production par une PR staging → main datée, fusionnée par commit de fusion à la
# révision exacte de staging après la CI verte, par le veilleur du lot 14 (pseudo-couloir _promote, main rendue). Tout se lit par fetch,
# git en lecture et gh : aucun commit, aucun checkout, aucune écriture de branche depuis le checkout principal, rien sur staging.
# Sans --confirm <projet>, la commande présente ce qui partirait et s'arrête, rien écrit.

PROMOTE_LANE=_promote   # jamais un nom de couloir valide (valid_slug) : l'état du veilleur ne croise aucun couloir réel

promote_join() { awk 'NF { printf "%s%s", (n++ ? " ; " : ""), $0 } END { if (n) printf "\n" }'; }
promote_slug() {
  repo_slug "$P_ROOT" "$P_REMOTE" 2>/dev/null \
    || (cd "$P_ROOT" && with_timeout 20 gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)
}
# promote_ci <sha> → « green|red|pending|none<TAB>contrôles en échec ou en cours » ; rc 1 : gh illisible.
# Le dernier passage de chaque contrôle (filtre « latest » de l'API) : une relance verte remplace l'échec qu'elle corrige.
promote_ci() {
  local slug lines failed running
  slug="$(promote_slug)" && [ -n "$slug" ] || return 1
  lines="$(with_timeout 30 gh api --paginate "repos/$slug/commits/$1/check-runs" \
    --jq '.check_runs[] | [.name, .status, (.conclusion // "")] | @tsv' 2>/dev/null)" || return 1
  failed="$(printf '%s\n' "$lines" | awk -F'\t' '$3 ~ /^(failure|cancelled|timed_out|action_required|startup_failure|stale)$/ { print $1 }')"
  running="$(printf '%s\n' "$lines" | awk -F'\t' 'NF && $2 != "completed" { print $1 }')"
  if [ -n "$failed" ]; then printf 'red\t%s\n' "$(printf '%s\n' "$failed" | sort -u | sync_join)"
  elif [ -n "$running" ]; then printf 'pending\t%s\n' "$(printf '%s\n' "$running" | sort -u | sync_join)"
  elif [ -z "$(printf '%s' "$lines" | tr -d '[:space:]')" ]; then printf 'none\t\n'
  else printf 'green\t\n'; fi
}
# promote_check : contrôles nommés, dans l'ordre ; chaque refus meurt avant toute écriture. Pose PROMOTE_FROM (révision de staging),
# PROMOTE_MAIN et PROMOTE_STATE (vide, ou « none » : staging n'apporte aucun commit).
promote_check() {
  local st mn ahead ci names rc=0
  PROMOTE_STATE=""
  [ -n "$P_STAGING" ] || die "$P_NAME has no staging branch configured: its batches go straight into $P_BASE, nothing to promote"
  local lr=0; with_timeout "${LAB_SYNC_TIMEOUT:-30}" git -C "$P_ROOT" ls-remote --exit-code --heads "$P_REMOTE" "$P_STAGING" >/dev/null 2>&1 || lr=$?
  [ "$lr" != 2 ] || die "$P_REMOTE/$P_STAGING not found: the staging branch does not exist on $P_REMOTE — nothing created"
  with_timeout "${LAB_SYNC_TIMEOUT:-30}" git -C "$P_ROOT" fetch --quiet "$P_REMOTE" "$P_BASE" "$P_STAGING" 2>/dev/null \
    || die "fetch of $P_REMOTE/$P_BASE and $P_REMOTE/$P_STAGING impossible (offline?): nothing created"
  st="$P_REMOTE/$P_STAGING"; mn="$P_REMOTE/$P_BASE"
  git -C "$P_ROOT" rev-parse --verify --quiet "$st^{commit}" >/dev/null || die "$st not found: the staging branch does not exist on $P_REMOTE"
  git -C "$P_ROOT" rev-parse --verify --quiet "$mn^{commit}" >/dev/null || die "$mn not found"
  PROMOTE_FROM="$(git -C "$P_ROOT" rev-parse "$st")"; PROMOTE_MAIN="$(git -C "$P_ROOT" rev-parse "$mn")"
  kv FROM "$P_STAGING@${PROMOTE_FROM:0:12}"; kv TO "$P_BASE@${PROMOTE_MAIN:0:12}"
  if [ "$(git -C "$P_ROOT" rev-list --count "$mn..$st")" = 0 ]; then PROMOTE_STATE=none; return 0; fi
  # les commits de fusion des promotions passées ne vivent que sur main : seuls les autres rendent main « en avance »
  ahead="$(git -C "$P_ROOT" log --no-merges --format='%h %s' "$st..$mn")"
  if [ -n "$ahead" ]; then
    kv MAIN_AHEAD "$(printf '%s\n' "$ahead" | promote_join)"
    die "$P_BASE carries $(printf '%s\n' "$ahead" | wc -l | tr -d ' ') commit(s) missing from $P_STAGING ($(printf '%s\n' "$ahead" | promote_join)): bring $P_BASE into $P_STAGING through a PR merged by a merge commit, then run lab promote $P_NAME again — nothing created"
  fi
  ci="$(promote_ci "$PROMOTE_FROM")" || die "CI of $st at ${PROMOTE_FROM:0:12} unreadable by gh: nothing created, run lab promote $P_NAME again"
  names="${ci#*$'\t'}"; ci="${ci%%$'\t'*}"
  kv CHECKS_STAGING "$ci"
  case "$ci" in
    red) die "CI red on $st at ${PROMOTE_FROM:0:12} ($names): fix staging through a PR, then run lab promote $P_NAME again — nothing created" ;;
    pending) die "CI running on $st at ${PROMOTE_FROM:0:12} ($names): run lab promote $P_NAME again once it is finished — nothing created" ;;
    none) warn "no check on $st at ${PROMOTE_FROM:0:12}: the CI of the promotion PR will be the only evidence" ;;
  esac
  sync_dry "$P_ROOT" "$st" "$mn" || rc=$?
  case "$rc" in
    0) kv DRY_RUN "no conflict" ;;
    1) kv DRY_RUN conflict; kv CONFLICT_FILES "$(printf '%s\n' "$SYNC_FILES" | sync_join)"
       die "conflict between $mn and $st on $(printf '%s\n' "$SYNC_FILES" | sync_join): bring $P_BASE into $P_STAGING through a PR that resolves it, then run lab promote $P_NAME again — nothing created" ;;
    *) kv DRY_RUN not-checkable; warn "dry run impossible (git < 2.38): merge not checked in advance" ;;
  esac
}
# promote_pr_ci <root> <numéro> → « <contrôles de la PR elle-même (pull_request…)> <dont passés> <dont échoués ou annulés> », en une seule lecture : ceux lancés
# sur staging elle-même portent la même révision et gh pr checks les lit verts avant que la CI de la PR n'apparaisse, puis pendant
# qu'elle tourne (parcours réel du lot 16 : #6 et #8 fusionnées CI de PR en cours) ; vide si gh ne répond pas
promote_pr_ci() {
  local -a rargs=(); local s r
  s="$(repo_slug "$1" "${P_REMOTE:-origin}" 2>/dev/null)" && rargs=(-R "$s")
  # gh sort en erreur tant qu'un contrôle est en cours, --json compris : seule la sortie compte
  r="$(with_timeout 30 gh pr checks "${rargs[@]+"${rargs[@]}"}" "$2" --json event,bucket --jq \
    '[.[] | select(.event | startswith("pull_request"))] | "\(length) \([.[] | select(.bucket == "pass" or .bucket == "skipping")] | length) \([.[] | select(.bucket == "fail" or .bucket == "cancel")] | length)"' 2>/dev/null)" || true
  case "$r" in [0-9]*' '[0-9]*' '[0-9]*) printf '%s\n' "$r" ;; esac
}
# promote_pr_ci_ready <root> <numéro> <armé à, secondes epoch> : chaque contrôle de la PR elle-même est passé ; ou aucun n'est apparu
# LAB_PROMOTE_PR_GRACE s après l'armement (défaut 300) — un dépôt dont la CI ne tourne que sur ses branches garde le vert de staging,
# déjà vérifié. gh illisible : pas prêt (rc 1). Un contrôle de la PR échoué ou annulé : rc 2, rouge.
promote_pr_ci_ready() {
  local r total pass bad; r="$(promote_pr_ci "$1" "$2")"; [ -n "$r" ] || return 1
  read -r total pass bad <<<"$r"
  [ "$bad" = 0 ] || return 2
  if [ "$total" -gt 0 ]; then [ "$total" = "$pass" ]; return; fi
  [ "$(( $(date +%s) - ${3:-0} ))" -ge "${LAB_PROMOTE_PR_GRACE:-300}" ] || return 1
  log "no CI of PR #$2 itself after ${LAB_PROMOTE_PR_GRACE:-300} s: the green of $P_STAGING, checked before arming, counts"
}
# promote_prs → « #<n> <titre> » par PR fusionnée dans staging dont le commit de fusion n'est pas encore dans main
promote_prs() {
  local list mine slug; local -a rargs=()
  slug="$(promote_slug)" && [ -n "$slug" ] && rargs=(-R "$slug")
  list="$(with_timeout 30 gh pr list "${rargs[@]+"${rargs[@]}"}" --base "$P_STAGING" --state merged --limit 200 \
    --json number,title,mergeCommit --jq '.[] | [.number, (.mergeCommit.oid // ""), .title] | @tsv' 2>/dev/null)" || return 1
  mine="$(git -C "$P_ROOT" rev-list "$P_REMOTE/$P_BASE..$P_REMOTE/$P_STAGING")"
  printf '%s\n' "$list" | awk -F'\t' 'NR == FNR { keep[$1] = 1; next } NF >= 2 && keep[$2] { print "#" $1 " " $3 }' <(printf '%s\n' "$mine") - | sort -t'#' -k2 -n
}
# promote_inflight → PR encore en route vers staging : ouvertes (gh), ou attendues par un veilleur de couloir (armé, en file)
promote_inflight() {
  local slug open f pr br on; local -a rargs=()
  slug="$(promote_slug)" && [ -n "$slug" ] && rargs=(-R "$slug")
  open="$(with_timeout 30 gh pr list "${rargs[@]+"${rargs[@]}"}" --base "$P_STAGING" --state open --limit 100 \
    --json number,headRefName --jq '.[] | "#\(.number) \(.headRefName)"' 2>/dev/null)" || open=""
  printf '%s\n' "$open" | sed '/^$/d'
  for f in "$LAB_STATE/watch/$P_NAME"/*/*; do
    [ -f "$f" ] || continue; case "$f" in *.log|*.records|*.body|*.tmp.*|*/"$PROMOTE_LANE"/*) continue ;; esac
    case "$(watch_state "$f")" in armed|waiting) ;; *) continue ;; esac
    [ "$(watch_get "$f" base)" = "$P_STAGING" ] || continue
    pr="$(watch_get "$f" pr)"; br="$(watch_get "$f" branch)"; on="$(watch_get "$f" on_pr)"
    if [ -n "$pr" ]; then printf '%s\n' "$open" | grep -q "^#$pr " || printf '#%s %s (watcher)\n' "$pr" "$br"
    else printf '%s (queued after #%s)\n' "$br" "$on"; fi
  done
}
# promote_body <fichier> <date> <PR incluses> : corps de la PR de promotion
promote_body() {
  {
    # shellcheck disable=SC2016 # accents graves littéraux du Markdown
    printf 'Promotion of `%s` to `%s` by `lab promote` (%s), merged by a merge commit at revision `%s`.\n\n' \
      "$P_STAGING" "$P_BASE" "$2" "${PROMOTE_FROM:0:12}"
    printf '## PRs included since the last promotion\n\n'
    if [ -n "$3" ]; then printf '%s\n' "$3" | sed 's/^/- /'; else printf -- '- no PR read (commits sent directly or gh unreadable)\n'; fi
    printf '\n## Commits\n\n'
    git -C "$P_ROOT" log --no-merges --format='- %h %s' "$P_REMOTE/$P_BASE..$P_REMOTE/$P_STAGING"
  } >"$1"
}

# lab promote [projet] [--confirm <projet>]
cmd_promote() {
  local confirm="" confirmed=0 today prs inflight info num state base title body view head checks slug url
  local -a pos=() rargs=()
  while [ "$#" -gt 0 ]; do
    case "$1" in --confirm) [ "$#" -ge 2 ] || usage; confirm="$2"; confirmed=1; shift 2 ;; -*) usage ;; *) pos+=("$1"); shift ;; esac
  done
  [ "${#pos[@]}" -le 1 ] || usage
  PROJECT="$(resolve_project "${pos[0]:-}")"; load_project "$PROJECT"
  [ "$confirmed" = 0 ] || [ "$confirm" = "$P_NAME" ] || die "confirmation \"$confirm\" ≠ project $P_NAME: nothing done (lab promote $P_NAME --confirm $P_NAME)"
  has_gh || die "gh required"
  kv PROJECT "$P_NAME"
  promote_check
  if [ "$PROMOTE_STATE" = none ]; then kv PROMOTE none; log "$P_STAGING brings no commit to $P_BASE: nothing to promote"; return 0; fi
  prs="$(promote_prs)" || { prs=""; warn "PRs merged into $P_STAGING unreadable by gh: commit list only"; }
  kv INCLUDED "$(printf '%s\n' "$prs" | promote_join)"
  kv COMMITS "$(git -C "$P_ROOT" rev-list --count --no-merges "$P_REMOTE/$P_BASE..$P_REMOTE/$P_STAGING")"
  inflight="$(promote_inflight)"
  if [ -n "$inflight" ]; then
    kv INFLIGHT "$(printf '%s\n' "$inflight" | promote_join)"
    warn "PRs still on their way to $P_STAGING ($(printf '%s\n' "$inflight" | promote_join)): they will not ship with this promotion"
  fi
  today="$(rdv_now 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"; today="${today%%T*}"
  title="release: $P_STAGING → $P_BASE ($today)"
  SLUG="$PROMOTE_LANE"; WT="$P_ROOT"   # le veilleur de promotion travaille depuis le checkout principal, par gh seulement
  info="$(pr_info "$P_ROOT" "$P_STAGING")"
  num="$(printf '%s' "$info" | cut -f1)"; state="$(printf '%s' "$info" | cut -f2)"; base="$(printf '%s' "$info" | cut -f3)"
  if [ "$state" = OPEN ] && [ "$base" != "$P_BASE" ]; then die "the open PR #$num of $P_STAGING targets $base, not $P_BASE: close it, then run lab promote $P_NAME again"; fi
  [ "$state" = OPEN ] || num=""
  if [ "$confirmed" = 0 ]; then
    kv PROMOTE preview
    if [ -n "$num" ]; then kv PR "#$num (open, reused)"; else kv PR "to create: $title"; fi
    git -C "$P_ROOT" log --no-merges --format='%h %s' "$P_REMOTE/$P_BASE..$P_REMOTE/$P_STAGING" | sed 's/^/lab:   would ship: /' >&2
    log "presentation only, nothing written: to promote, lab promote $P_NAME --confirm $P_NAME"
    return 0
  fi
  slug="$(promote_slug)" && [ -n "$slug" ] && rargs=(-R "$slug")
  if [ -z "$num" ]; then
    body="$(watch_file "$P_STAGING").body"; mkdir -p "$(dirname "$body")"
    promote_body "$body" "$today" "$prs"
    url="$(cd "$P_ROOT" && with_timeout 60 gh pr create "${rargs[@]+"${rargs[@]}"}" --base "$P_BASE" --head "$P_STAGING" \
      --title "$title" --body-file "$body")" || die "gh pr create refused for $P_STAGING → $P_BASE: nothing else done"
    num="$(printf '%s' "$url" | sed -n 's|.*/pull/\([0-9]*\).*|\1|p' | head -1)"
    [ -n "$num" ] || die "promotion PR number unreadable ($url)"
    kv PR "#$num (created)"; kv URL "$url"
  else
    kv PR "#$num (reused)"
  fi
  pr_make_ready "$P_ROOT" "$num"
  view="$(pr_view_state "$P_ROOT" "$num")" || view=""; head="$(printf '%s' "$view" | cut -f2)"
  [ -n "$head" ] || die "revision of PR #$num unreadable by gh: nothing armed; run lab promote $P_NAME --confirm $P_NAME again"
  [ "$head" = "$PROMOTE_FROM" ] || die "PR #$num carries ${head:0:12}, $P_STAGING is at ${PROMOTE_FROM:0:12}: staging moved, run lab promote $P_NAME --confirm $P_NAME again"
  checks="$(pr_checks_now "$P_ROOT" "$num" "$head" "$P_STAGING" "$P_BASE")"   # workflows lus dans staging, qui part (lot 01 de ci-pr)
  if [ "$checks" = green ]; then
    local ready=0; promote_pr_ci_ready "$P_ROOT" "$num" "$(date +%s)" || ready=$?
    case "$ready" in
      0) ;;
      2) checks=red ;;
      *) checks=pending; log "the CI of PR #$num itself has not appeared yet or is not green yet: the watcher waits for it" ;;
    esac
  fi
  kv CHECKS "$checks"
  [ "$checks" != none ] || pr_ci_kv "$P_ROOT" "$head" "$P_STAGING" "$P_BASE"
  case "$checks" in
    green|none)
      pr_merge_exact "$P_ROOT" "$num" "$head" merge || die "merge of #$num refused by GitHub (merge commits forbidden, permissions or revision changed)"
      watch_done "$P_STAGING" merged "#$num merged in place by lab promote at ${head:0:12}"
      deploy_note_merged "$P_STAGING" "$P_BASE" || true   # couloirs servis entrés dans la base avec staging (lot 02 de mise-en-ligne)
      kv PROMOTE merged; log "$P_STAGING promoted into $P_BASE by a merge commit at ${head:0:12} (#$num)" ;;
    pending)
      watch_arm promote "$P_STAGING" pr="$num" sha="$head" base="$P_BASE" method=merge mode=veille armed_at="$(date +%s)"
      kv PROMOTE armed
      log "lab promote hands back: the watcher will merge #$num by a merge commit at ${head:0:12} after green CI — outcome in lab status $P_NAME" ;;
    *) kv PROMOTE blocked; die "CI red on promotion PR #$num: no merge — fix staging through a PR, then run lab promote $P_NAME --confirm $P_NAME again" ;;
  esac
}
