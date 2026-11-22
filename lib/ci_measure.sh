# shellcheck shell=bash
# ci_measure.sh — les minutes de CI d'un projet sur 7 jours glissants, lot 04 de ci-sobre. Un cache par projet ($LAB_STATE/ci-<projet>,
# KEY=value), écrit par lab next et lab close en arrière-plan (un appel jobs par exécution : ~150 pour une semaine de treelab), au plus
# une fois par jour UTC ; lab doctor le lit seul, jamais gh. Une panne de gh garde le cache tel quel. Calcul de scripts/ci-minutes.sh :
# chaque job démarré et terminé, arrondi à la minute supérieure, macOS × 10, sauté exclu.

CI_WINDOW_DAYS=7
ci_file() { printf '%s/ci-%s\n' "$LAB_STATE" "$1"; }
# ci_get <projet> <clé> → valeur du cache, vide sans cache ou sans clé
ci_get() { local f; f="$(ci_file "$1")"; [ -f "$f" ] || return 0; sed -n "s/^$2=//p" "$f" | head -1; }
# ci_fresh <projet> [jours] : rc 0 si la mesure date de moins de <jours> jours UTC (1 par défaut : aujourd'hui)
ci_fresh() {
  local at now
  at="$(ci_get "$1" MEASURED_AT)"; now="$(rdv_now 2>/dev/null)" || return 1
  at="$(rdv_epoch "$at" 2>/dev/null)" && now="$(rdv_epoch "${now%%T*}T00:00:00Z" 2>/dev/null)" || return 1
  [ "$at" -ge $((now - (${2:-1} - 1) * 86400)) ]
}

# ci_jobs <owner/repo> <exécution> → une ligne par job joué : exécution, système, minutes facturées (arrondi supérieur), nom
ci_jobs() {
  with_timeout 60 gh api --paginate "repos/$1/actions/runs/$2/jobs?filter=all&per_page=100" --jq '.jobs[]
    | select(.started_at != null and .completed_at != null and .conclusion != "skipped")
    | ["'"$2"'", (if ((.labels // []) | join(",") | test("macos")) then "macOS" else "Linux" end),
       ((((.completed_at | fromdateiso8601) - (.started_at | fromdateiso8601)) + 59) / 60 | floor), .name] | @tsv' 2>/dev/null
}
# ci_refresh : après load_project, synchrone. Déjà mesuré aujourd'hui → rien, rc 0 ; sans gh, si gh échoue ou si la liste est tronquée
# (1 000 exécutions au plus par requête datée) → rc 1, cache intact ; sinon réécrit le cache, rc 0. Sous-shell : gh lit le dépôt du
# checkout principal ({owner}/{repo} quand le remote n'est pas une URL GitHub reconnue).
ci_refresh() (
  local s now to from tmp id rc=0 n=0 f out full rev
  ci_fresh "$P_NAME" && return 0
  has_gh && cd "$P_ROOT" 2>/dev/null || return 1
  s="$(repo_slug "$P_ROOT" "$P_REMOTE" 2>/dev/null)" || s='{owner}/{repo}'
  now="$(rdv_now)" || return 1; to="${now%%T*}"
  from="$(date -u -r $(( $(rdv_epoch "$now") - (CI_WINDOW_DAYS - 1) * 86400 )) +%Y-%m-%d)" || return 1
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/lab-ci.XXXXXX")" || return 1
  # exécutions : id, événement, branche, PR, conclusion, date de création ; T = total annoncé par l'API
  if ! with_timeout 120 gh api --paginate "repos/$s/actions/runs?created=$from..$to&per_page=100" \
    --jq '"T\t\(.total_count)", (.workflow_runs[] | ["R", .id, .event, (.head_branch // ""), ((.pull_requests // [])[0].number // "" | tostring), (.conclusion // ""), .created_at[0:10]] | @tsv)' \
    >"$tmp/list" 2>/dev/null; then rm -rf "$tmp"; return 1; fi
  awk -F '\t' '$1 == "R"' "$tmp/list" | cut -f 2- >"$tmp/runs"
  [ "$(grep -c . "$tmp/runs" || true)" -ge "$(awk -F '\t' '$1 == "T" && $2 + 0 > t { t = $2 + 0 } END { print t + 0 }' "$tmp/list")" ] \
    || { rm -rf "$tmp"; return 1; }
  # jobs, quatre exécutions à la fois : id, système, minutes facturées, nom ; un second essai par exécution (une semaine de treelab =
  # ~150 appels, un seul raté perdait la mesure du jour au premier essai réel)
  while IFS=$'\t' read -r id _; do
    [ -n "$id" ] || continue
    { ci_jobs "$s" "$id" >"$tmp/jobs.$id" || ci_jobs "$s" "$id" >"$tmp/jobs.$id" || : >"$tmp/failed"; } &
    n=$((n + 1)); [ $((n % 4)) -ne 0 ] || wait
    [ ! -e "$tmp/failed" ] || break   # un échec perd la mesure : plus aucun appel (quota)
  done <"$tmp/runs"
  wait
  [ ! -e "$tmp/failed" ] || { rm -rf "$tmp"; return 1; }
  cat "$tmp"/jobs.* 2>/dev/null >"$tmp/jobs" || : >"$tmp/jobs"
  # jobs gardés par l'étiquette full-suite sur la base : voulus longs, hors HEAVY_PR_JOBS
  rev="$P_REMOTE/$P_BASE"; git -C "$P_ROOT" rev-parse -q --verify "$rev^{commit}" >/dev/null 2>&1 || rev="$P_BASE"
  full="$(WT="$P_ROOT" close_full_suite_jobs "$rev" 2>/dev/null)" || full=""
  out="$(FULL="$full" BASE="$P_BASE" awk -F '\t' '
    BEGIN { nf = split(ENVIRON["FULL"], fs, "\n") }
    FILENAME == ARGV[1] { ev[$1] = $2; key[$1] = ($4 != "" ? $4 : "b:" $3)
      if ($2 == "schedule" && $3 == ENVIRON["BASE"] && ($5 == "failure" || $5 == "timed_out" || $5 == "startup_failure")) red[$6] = 1
      next }
    { m += $3 * ($2 == "macOS" ? 10 : 1)
      if (ev[$1] != "pull_request") next
      if (!(($1) in seen)) { seen[$1] = 1; runs++; if (!(key[$1] in prs)) { prs[key[$1]] = 1; np++ } }
      if ($3 > 15) { full = 0; for (i = 1; i <= nf; i++) if (fs[i] != "" && index($4, fs[i]) == 1) full = 1; if (!full) heavy++ } }
    END { for (d in red) nr++
      printf "MINUTES_WEEK=%d\nRUNS_PER_PR=%d\nHEAVY_PR_JOBS=%d\nNIGHT_RED_DAYS=%d\nPR_RUNS=%d\n", m, (np ? int((runs + np - 1) / np) : 0), heavy, nr, runs }' \
    "$tmp/runs" "$tmp/jobs")" || { rm -rf "$tmp"; return 1; }
  f="$(ci_file "$P_NAME")"; mkdir -p "$(dirname "$f")"
  printf '%s\nPERIOD=%s..%s\nMEASURED_AT=%s\n' "$out" "$from" "$to" "$now" >"$tmp/cache" && mv "$tmp/cache" "$f" || rc=1
  rm -rf "$tmp"; return "$rc"
)

# ci_template_install <worktree> <fiche du lot> : lab new, dans le worktree du nouveau couloir seulement. Sans aucun
# .github/workflows/*.y*ml → le gabarit templates/project/ci.yml y est écrit puis commité seul (chore(ci), relu dans la PR du lot) ;
# un workflow existant n'est jamais touché. KEY CI_TEMPLATE=written|kept|failed. Le départ du couloir (start= de .lab/meta) passe
# après ce commit : un couloir neuf reste « sans commit » pour lab close --abandon, sweep et lab next (revue du lot 04).
# LAB_CI_TEMPLATE=0 (bac à sable des tests qui décrivent un projet sans CI) : rien.
ci_template_install() {
  local wt="$1" n head
  [ "${LAB_CI_TEMPLATE:-1}" != 0 ] || return 0
  if compgen -G "$wt/.github/workflows/*.y*ml" >/dev/null; then kv CI_TEMPLATE kept; return 0; fi
  n="$(basename "$2" | cut -d- -f2)"
  if ! { mkdir -p "$wt/.github/workflows" && cp "$LAB_ROOT/templates/project/ci.yml" "$wt/.github/workflows/ci.yml" \
    && git -C "$wt" add -- .github/workflows/ci.yml \
    && git -C "$wt" commit -q -m "chore(ci): lean CI template from lab (lot-$n)" -- .github/workflows/ci.yml >/dev/null 2>&1; }; then
    git -C "$wt" reset -q -- .github/workflows/ci.yml 2>/dev/null || true   # jamais glissé dans le prochain commit de l'agent
    kv CI_TEMPLATE failed; warn "CI template not committed: see $wt/.github/workflows/ci.yml"; return 0
  fi
  head="$(git -C "$wt" rev-parse HEAD)" && sed -i '' "s/^start=.*/start=$head/" "$wt/.lab/meta"
  kv CI_TEMPLATE written
  log_wrap "CI template committed in .github/workflows/ci.yml: fill in FAST_CMD, TARGETED_CMD, FULL_CMD, E2E_CMD at its top (empty = step skipped)"
}

# ci_refresh_bg : après load_project — lance ci_refresh détaché (lab next et lab close n'attendent pas ~150 appels gh), une seule
# mesure par projet à la fois (verrou <cache>.lock, périmé après une heure), une tentative par jour UTC même en échec (<cache>.tried :
# une panne ne relance pas ~150 appels à chaque commande). Rien sans gh, déjà mesuré ou tenté aujourd'hui, ou LAB_CI_MEASURE=0.
ci_refresh_bg() {
  local lock today
  [ "${LAB_CI_MEASURE:-1}" != 0 ] && has_gh || return 0
  ci_fresh "$P_NAME" && return 0
  today="$(rdv_now 2>/dev/null)" || return 0; today="${today%%T*}"
  [ "$(cat "$(ci_file "$P_NAME").tried" 2>/dev/null)" != "$today" ] || return 0
  lock="$(ci_file "$P_NAME").lock"; mkdir -p "$(dirname "$lock")"
  if ! mkdir "$lock" 2>/dev/null; then
    [ -n "$(find "$lock" -maxdepth 0 -mmin +60 2>/dev/null)" ] && rmdir "$lock" 2>/dev/null && mkdir "$lock" 2>/dev/null || return 0
  fi
  printf '%s\n' "$today" >"$(ci_file "$P_NAME").tried"
  ( trap '' HUP; ci_refresh || true; rmdir "$lock" 2>/dev/null || true ) </dev/null >/dev/null 2>&1 3>&- &
}
