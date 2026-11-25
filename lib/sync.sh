# shellcheck shell=bash
# shellcheck disable=SC2034 # SYNC_STATE, SYNC_DETAIL, SYNC_FILES, SYNC_REF, SYNC_KIND et SYNC_RECETTE sont lus par bin/lab (lab sync, lab launch, lab merge).
# sync.sh — couloirs synchronisés (lot 15) : la base (<remote>/<cible des PR>) est mergée dans le couloir, jamais de rebase ni de
# push forcé ; un conflit est annulé (git merge --abort) et nommé ; l'essai à blanc de lab merge passe par git merge-tree ; les
# fichiers touchés par deux couloirs vivants sont annoncés avec un ordre de passage. Aucune fonction d'ici ne pousse.

sync_ref() { printf '%s/%s\n' "$P_REMOTE" "$(pr_base)"; }
# sync_join : lignes sur stdin → « a, b, c » (liste lisible, une seule ligne)
sync_join() { awk 'NF { printf "%s%s", (n++ ? ", " : ""), $0 } END { if (n) printf "\n" }'; }
# sync_stacked <wt> : branche empilée sur un lot non fusionné (lot 14) — replacée par stack_follow dès la fusion prouvée (lot 17)
sync_stacked() { [ -n "$(wt_meta "$1" stacked_on)" ] && [ "$(wt_meta "$1" stack_branch)" = "$(branch_name "$1")" ]; }
# sync_behind <wt> → nombre de commits de la base absents du couloir, lu localement (ni réseau ni écriture : le hook l'appelle)
sync_behind() {
  local ref; ref="$(sync_ref)"
  git -C "$1" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 || { printf '0\n'; return 0; }
  git -C "$1" rev-list --count "HEAD..$ref" 2>/dev/null || printf '0\n'
}
# sync_lane <wt> : merge la base dans le couloir. Pose SYNC_STATE (à-jour | fusionnée | conflit | ignorée), SYNC_DETAIL (motif,
# une ligne), SYNC_FILES (fichiers en conflit, un par ligne), SYNC_REF et SYNC_KIND (merge, non-annulé si git merge --abort échoue, ou stack pour le replacement d'une
# branche empilée). Ne meurt jamais : chaque cas neutre est nommé.
sync_lane() {
  local wt="$1" br ref lot nn behind phase
  SYNC_STATE=ignored; SYNC_DETAIL=""; SYNC_FILES=""; SYNC_KIND=merge; SYNC_RECETTE=""; ref="$(sync_ref)"; SYNC_REF="$ref"
  br="$(branch_name "$wt")"
  [ -n "$br" ] || { SYNC_DETAIL="detached HEAD"; return 0; }
  if [ -f "$(git -C "$wt" rev-parse --git-path MERGE_HEAD 2>/dev/null)" ]; then SYNC_DETAIL="merge in progress: finish it (git commit) or cancel it (git merge --abort)"; return 0; fi
  dirty_report "$wt" || { SYNC_DETAIL="uncommitted changes: $(dirty_tracked_list)"; return 0; }   # un suivi modifié : rien touché
  if sync_stacked "$wt"; then
    # lot d'en dessous fusionné : replacée par rebase --onto, jamais poussée (lot 17) ; conflit → branche intacte, cause nommée
    local src=0; WT="$wt" stack_follow "lab sync $P_NAME $SLUG" || src=$?
    case "$src" in
      1) SYNC_STATE=conflict; SYNC_KIND=stack; SYNC_DETAIL="$STACK_REASON"; return 0 ;;
      2) SYNC_DETAIL="$STACK_REASON"; return 0 ;;
    esac
    if sync_stacked "$wt"; then SYNC_DETAIL="branch stacked on $(wt_meta "$wt" stacked_on) — ${STACK_NOTE:-nothing concluded}"; return 0; fi
  fi
  untracked_warn "$wt" "sync continues" || true
  # lot 07 de refonte-onboarding : un dépôt sans distant (premier couloir guidé, avant gh repo create) n'a rien à fusionner,
  # jamais « offline » ; les fichiers non suivis restent signalés juste au-dessus
  git -C "$wt" remote get-url "$P_REMOTE" >/dev/null 2>&1 || { SYNC_DETAIL="no remote $P_REMOTE yet: nothing to merge"; return 0; }
  if ! with_timeout "${LAB_SYNC_TIMEOUT:-30}" git -C "$wt" fetch --quiet "$P_REMOTE" "$(pr_base)" 2>/dev/null; then
    SYNC_DETAIL="offline: fetch of $ref failed"; return 0
  fi
  git -C "$wt" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 || { SYNC_DETAIL="$ref not found"; return 0; }
  behind="$(git -C "$wt" rev-list --count "HEAD..$ref" 2>/dev/null || echo 0)"
  [ "$behind" -gt 0 ] || { SYNC_STATE=up-to-date; return 0; }
  local clash; clash="$(untracked_clash "$wt" "$ref")"   # git refuserait le merge : jamais présenté comme un conflit (revue du lot 17)
  [ -z "$clash" ] || { SYNC_DETAIL="untracked file(s) the base would overwrite: $clash — move or commit them, then run lab sync $P_NAME $SLUG again"; return 0; }
  # recette ouverte : la base est mergée aussi ; la recette reste valable tant que ce merge n'apporte aucun fichier du couloir (lot 17)
  phase="$(lane_phase "$wt" 2>/dev/null || true)"
  lot="$(basename "$(wt_lot_file "$wt")" .md)"; nn="$(printf '%s' "$lot" | sed -n 's/^\(lot-[0-9]*\).*/\1/p')"
  if git -C "$wt" merge --quiet --no-edit -m "chore(sync): merge $ref${nn:+ ($nn)}" "$ref" >/dev/null 2>&1; then
    SYNC_STATE=merged; SYNC_DETAIL="$behind commit(s) from $ref"
    sync_recette_note "$wt" "$phase"
    return 0
  fi
  SYNC_FILES="$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null || true)"
  sync_conflict_log "$wt" "$SYNC_FILES" "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" "$(git -C "$wt" rev-parse "$ref" 2>/dev/null)"
  # conflit sur les seuls fichiers générés déclarés : version de la base, regen, merge conclu (lot 18) ; sinon annulé comme avant
  local regen_cause=""
  if [ -n "$SYNC_FILES" ] && sync_all_generated "$SYNC_FILES"; then
    if sync_regen "$wt" "$ref" "$nn"; then
      SYNC_STATE=merged; SYNC_DETAIL="$behind commit(s) from $ref; conflict on generated files regenerated ($P_REGEN): $(printf '%s\n' "$SYNC_FILES" | sync_join)"
      SYNC_FILES=""; sync_recette_note "$wt" "$phase"; return 0
    fi
    regen_cause=" — regeneration failed: $SYNC_REGEN_CAUSE"
    # ce que regen a écrit revient d'abord à la version indexée : sinon git merge --abort refuse (« not uptodate ») et le merge
    # resterait en cours sous un message « annulé » (revue du lot 18). Le couloir était propre avant (dirty_report) : fichier par fichier
    local f
    while IFS= read -r f; do [ -z "$f" ] || git -C "$wt" checkout -q -- "$f" 2>/dev/null || true; done \
      < <(git -C "$wt" -c core.quotePath=false diff --name-only 2>/dev/null)
  fi
  git -C "$wt" merge --abort >/dev/null 2>&1 || true
  if [ -f "$(git -C "$wt" rev-parse --git-path MERGE_HEAD 2>/dev/null)" ]; then
    SYNC_STATE=conflict; SYNC_KIND=not-cancelled; SYNC_DETAIL="merge of $ref not cancelled: git merge --abort failed in $wt — finish or cancel it by hand before going on$regen_cause"
    return 0
  fi
  SYNC_STATE=conflict
  if [ -n "$SYNC_FILES" ]; then SYNC_DETAIL="conflict with $ref on $(printf '%s\n' "$SYNC_FILES" | sync_join)$regen_cause"
  else SYNC_DETAIL="merge of $ref refused by git (see git merge $ref)"; fi
}
# sync_conflict_log <wt> <fichiers> <tête> <base> : journal $LAB_STATE/<projet>/conflits, une ligne « epoch⇥date⇥couloir⇥fichier⇥
# tête⇥base » par fichier en conflit avec la base (lot 04 de mise-en-ligne) ; le doctor y compte les épisodes distincts (tête, base) :
# relancer lab sync sur le même conflit encore ouvert n'en fait pas un second. Jamais bloquant.
sync_conflict_log() {
  local f now day lane
  [ -n "$2" ] || return 0
  now="$(date -u +%s)"; day="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; lane="$(basename "$1")"
  mkdir -p "$LAB_STATE/$P_NAME" 2>/dev/null || return 0
  while IFS= read -r f; do [ -z "$f" ] || printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$day" "$lane" "$f" "${3:--}" "${4:--}"; done <<<"$2" >>"$LAB_STATE/$P_NAME/conflits" 2>/dev/null || true
}
# sync_recette_note <wt> <phase> : recette ouverte → SYNC_RECETTE dit si ce merge la laisse valable (lot 17), quel que soit le chemin
# du merge — sans conflit, ou conclu par regen (revue du lot 18)
sync_recette_note() {
  local lot
  [ "$2" = 'acceptance passed' ] || return 0
  lot="$(wt_lot_file "$1")"
  if [ "$(recette_status "$1" "$lot")" = valid ]; then
    if [ -n "$(recette_stale_files "$1" "$lot")" ]; then SYNC_RECETTE="valid (kept by the user's words)"   # lot 04 d'onglet-tower
    else SYNC_RECETTE="valid (no lane file in this merge)"; fi
  else SYNC_RECETTE="expired — lane files changed: $(recette_stale_files "$1" "$lot")"; fi
}
# sync_generated <chemin> : le chemin correspond à un motif de generated= (motifs séparés par des espaces ; * traverse les dossiers)
sync_generated() {
  local pat; local -a pats=()
  read -r -a pats <<<"${P_GENERATED:-}"
  for pat in "${pats[@]+"${pats[@]}"}"; do
    # shellcheck disable=SC2254 # motif voulu : generated= porte des globs
    case "$1" in $pat) return 0 ;; esac
  done
  return 1
}
# sync_all_generated <fichiers> : chacun est déclaré généré, et une commande regen= existe — un seul fichier écrit à la main suffit à refuser
sync_all_generated() {
  local f
  [ -n "${P_REGEN:-}" ] && [ -n "${P_GENERATED:-}" ] || return 1
  while IFS= read -r f; do [ -z "$f" ] || sync_generated "$f" || return 1; done <<<"$1"
}
# sync_regen <wt> <ref> <lot-NN> : merge en conflit sur des fichiers tous générés — chacun prend la version de la base, regen= tourne
# dans le couloir (journal .lab/regen.log, limite LAB_REGEN_TIMEOUT), ce qu'il a refait est ajouté, le merge est conclu. rc 1 et
# SYNC_REGEN_CAUSE si regen échoue ou touche un fichier suivi non déclaré généré : l'appelant annule le merge.
sync_regen() {
  local wt="$1" ref="$2" nn="$3" f rc=0 stray=""
  SYNC_REGEN_CAUSE=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if git -C "$wt" cat-file -e "$ref:$f" 2>/dev/null; then git -C "$wt" checkout "$ref" -- "$f" >/dev/null 2>&1 || return 1
    else git -C "$wt" rm -q --cached -- "$f" >/dev/null 2>&1; rm -f "$wt/$f"; fi
  done <<<"$SYNC_FILES"
  mkdir -p "$wt/.lab"
  (cd "$wt" && with_timeout "${LAB_REGEN_TIMEOUT:-600}" sh -c "$P_REGEN") >"$wt/.lab/regen.log" 2>&1 || rc=$?
  if [ "$rc" != 0 ]; then SYNC_REGEN_CAUSE="\"$P_REGEN\" rc $rc (log $wt/.lab/regen.log)"; return 1; fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if sync_generated "$f"; then git -C "$wt" add -A -- "$f" >/dev/null 2>&1 || return 1; else stray="$stray${stray:+, }$f"; fi
  done < <(git -C "$wt" -c core.quotePath=false diff --name-only 2>/dev/null; git -C "$wt" -c core.quotePath=false ls-files --others --exclude-standard 2>/dev/null | while IFS= read -r f; do sync_generated "$f" && printf '%s\n' "$f"; done)
  if [ -n "$stray" ]; then SYNC_REGEN_CAUSE="\"$P_REGEN\" changed files not declared as generated: $stray"; return 1; fi
  [ -z "$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null)" ] || { SYNC_REGEN_CAUSE="conflict still open after regeneration"; return 1; }
  git -C "$wt" commit -q --no-edit -m "chore(sync): merge $ref${nn:+ ($nn)} — generated files regenerated" >/dev/null 2>&1 \
    || { SYNC_REGEN_CAUSE="merge commit refused by git"; return 1; }
}
# sync_dry <wt> [ref] [ours=HEAD] : essai à blanc, rien n'est écrit dans le couloir. rc 0 sans conflit, 1 conflit (SYNC_FILES),
# 2 non vérifiable ; lab promote essaie staging sur main (ours = <remote>/main) depuis le checkout principal (lot 16)
sync_dry() {
  local wt="$1" ref="${2:-$(sync_ref)}" ours="${3:-HEAD}" out rc=0
  SYNC_FILES=""; SYNC_TREE=""; SYNC_TREE_FOR=""
  # un seul programme sans conflit (lot 05 de charge-processeur : rev-parse, sous-shell et tr avant) : merge-tree rend 128 sur une
  # référence absente comme rev-parse --verify, 129 sur un git < 2.38 ; son arbre, seule ligne d'une fusion propre, est gardé pour
  # merge_regression, qui suit sur les mêmes révisions
  out="$(exec git -C "$wt" merge-tree --write-tree --no-messages "$ours" "$ref" 2>/dev/null)" || rc=$?
  case "$rc" in
    0) SYNC_TREE="$out"; SYNC_TREE_FOR="$wt|$ours|$ref"; return 0 ;;
    1) ;;
    *) return 2 ;;
  esac
  rc=0; out="$(git -C "$wt" merge-tree --write-tree -z --name-only --no-messages "$ours" "$ref" 2>/dev/null | tr '\0' '\n')" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) SYNC_FILES="$(printf '%s\n' "$out" | tail -n +2 | sed '/^$/d')"; return 1 ;;
    *) return 2 ;;   # git < 2.38 : --write-tree inconnu
  esac
}
# sync_mark_clear <wt> : la base est rejointe — la marque d'un conflit passé ne compte plus (une nouvelle cause rouvrira sa correction)
sync_mark_clear() {
  local f="$1/.lab/correction" tmp
  [ -f "$f" ] && grep -Eq '^sync-conflic?t	' "$f" || return 0
  tmp="$(mktemp "$f.XXXXXX")"; grep -Ev '^sync-conflic?t	' "$f" >"$tmp" || true; mv "$tmp" "$f"
}

# ---------- chevauchements entre couloirs vivants ----------
# lane_files <wt> → fichiers que le couloir modifie encore par rapport à la base : écart du couloir depuis l'ancêtre commun, restreint
# aux fichiers qui diffèrent encore de la base (un lot déjà fusionné par squash n'y figure plus), plus les modifications non commitées
lane_files() {
  local wt="$1" ref mb
  ref="$(sync_ref)"
  git -C "$wt" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 || ref="$(pr_base)"
  mb="$(git -C "$wt" merge-base "$ref" HEAD 2>/dev/null)" || mb=""
  {
    if [ -n "$mb" ]; then
      comm -12 <(git -C "$wt" diff --name-only "$mb" HEAD 2>/dev/null | sort -u) <(git -C "$wt" diff --name-only "$ref" HEAD 2>/dev/null | sort -u)
    fi
    git -C "$wt" diff --name-only HEAD 2>/dev/null || true
    git -C "$wt" ls-files --others --exclude-standard 2>/dev/null || true
  } | sed '/^$/d' | sort -u
}
# lane_rank <wt> [gh=1] → « <rang><TAB><libellé> » : 0 PR armée ou prête, 1 brouillon, 2 sans PR ; sans gh (hook), seul le veilleur compte
lane_rank() { lane_rank_set "$@"; printf '%s\n' "$LANE_RANK"; }
lane_rank_set() { # les mêmes arguments : LANE_RANK ; sans processus quand la demande groupée a lu la PR
  local wt="$1" draft s; local -a rargs=()
  head_branch_set "$wt"; wt_lane_set "$wt"
  watch_state_set "$LAB_STATE/watch/$P_NAME/$WT_LANE/${HEAD_BRANCH//\//+}"
  case "$WATCH_STATE" in armed|waiting) LANE_RANK=$'0\tPR armed'; return 0 ;; esac
  if [ "${2:-1}" = 1 ] && has_gh; then
    pr_info_set "$P_ROOT" "$HEAD_BRANCH"
    if [ "$PR_STATE" = OPEN ]; then
      draft="$PR_DRAFT"
      if [ -z "$draft" ]; then
        s="$(repo_slug "$P_ROOT" "$P_REMOTE" 2>/dev/null)" && rargs=(-R "$s")
        draft="$(with_timeout 20 gh pr view "${rargs[@]+"${rargs[@]}"}" "$PR_NUM" --json isDraft --jq .isDraft 2>/dev/null)" || draft=""
      fi
      if [ "$draft" = true ]; then LANE_RANK=$'1\tdraft PR #'"$PR_NUM"; else LANE_RANK=$'0\tready PR #'"$PR_NUM"; fi
      return 0
    fi
  fi
  LANE_RANK=$'2\tno PR'
}
# lane_since <wt> → date de création du couloir (méta created), sinon date de son premier commit propre ; « 9999 » si inconnue
lane_since() { lane_since_set "$1"; printf '%s\n' "$LANE_SINCE"; }
lane_since_set() { # <wt> : LANE_SINCE ; git seulement pour un couloir sans date de création
  kv_value "$1/.lab/meta" created || true; LANE_SINCE="$KV_VALUE"
  [ -n "$LANE_SINCE" ] || LANE_SINCE="$(git -C "$1" log --reverse --format=%cd --date=format:%Y-%m-%dT%H:%M "$(sync_ref)..HEAD" 2>/dev/null | head -1 || true)"
  LANE_SINCE="${LANE_SINCE:-9999}"
}
# live_lanes → chemins des couloirs vivants du projet (worktrees de $P_ROOT/.worktrees)
live_lanes() { local d; for d in "$P_ROOT"/.worktrees/*/; do [ -f "$d.git" ] && printf '%s\n' "${d%/}"; done; return 0; }
# ---------- les fichiers de tous les couloirs, lus en une fois (lot 02 de charge-processeur) ----------
# Comparer chaque couloir aux autres relisait les fichiers de tous les couloirs pour chacun : 2 500 relectures à 50 couloirs. Deux git
# par couloir (status, merge-base), puis deux pour tout le projet — les arbres, et tous les écarts d'un seul diff-tree —, et un tri.
# lane_status_set <wt> : LANE_STATUS, git status du couloir (forme v2) ; gardé pour les chevauchements quand LANE_STATUS_KEEP=1
LANE_STATUS_KEEP=0; LK_WT=() LK_ST=()
lane_status_set() {
  # --no-optional-locks : git status ne rafraîchit pas l'index sous index.lock — l'agent du couloir lu peut committer en même temps
  LANE_STATUS="$(exec git --no-optional-locks -C "$1" status --porcelain=v2 --branch --no-ahead-behind --untracked-files=all)" || true
  if [ "$LANE_STATUS_KEEP" = 1 ]; then LK_WT+=("$1"); LK_ST+=("$LANE_STATUS"); fi
}
lane_status_keep() { LANE_STATUS_KEEP=1; LK_WT=() LK_ST=(); }
lane_status_forget() { LANE_STATUS_KEEP=0; LK_WT=() LK_ST=(); }
lane_status_clean() { # LANE_STATUS ne montre aucun fichier : seules des lignes d'en-tête « # … »
  case "$LANE_STATUS" in ''|'#'*) ;; *) return 1 ;; esac
  case "$LANE_STATUS" in *$'\n'[!#]*) return 1 ;; esac
}
# shellcheck disable=SC2016 # programme awk, rien à développer
OVERLAP_FILES_AWK='
  function add(i, p) { if (p != "" && !((i, p) in S)) { S[i, p] = 1; print p "\t" i } }
  function path(line, n) { while (n-- > 0) line = substr(line, index(line, " ") + 1); return line }
  substr($0, 1, 1) == "\035" {
    sect = substr($0, 2, 1); split(substr($0, 3), a, " ")
    if (sect == "S") { i = a[1]; old = a[2]; if (a[3] != "-") { E[++ne] = a[3] " " a[4]; EI[ne] = i; E[++ne] = a[5] " " a[4]; EI[ne] = i } }
    next
  }
  sect == "S" { if ($0 ~ /^\? /) add(i, substr($0, 3)); else if (!old && $0 ~ /^1 /) add(i, path($0, 8)); next }
  sect == "R" { add(i, $0); next }
  sect == "D" { if (q < ne && $0 == E[q + 1]) { q++; next }
    if (q % 2) A[EI[q], $0] = 1; else if ((EI[q], $0) in A) add(EI[q], $0) }'
# shellcheck disable=SC2016 # programme awk, rien à développer
OVERLAP_PAIRS_AWK='
  { t = index($0, "\t"); p = substr($0, 1, t - 1); i = substr($0, t + 1)
    if (!(p in L)) { O[++n] = p; L[p] = i } else L[p] = L[p] " " i }
  END {
    for (k = 1; k <= n; k++) {
      m = split(L[O[k]], g, " ")
      for (x = 1; x <= m; x++) for (y = 1; y <= m; y++) {
        if (only == "" ? g[x] + 0 >= g[y] + 0 : (g[x] != only || x == y)) continue
        # valeur lue puis écrite en deux temps : mawk crée F[clé] avant de calculer la droite (sinon « , » en tête)
        key = g[x] SUBSEP g[y]; v = (key in F) ? F[key] ", " : ""; F[key] = v O[k]
      }
    }
    for (x = 0; x < lanes; x++) for (y = 0; y < lanes; y++) if ((x, y) in F) print x "\t" y "\t" F[x, y]
  }'
# overlaps_load [wt] : OV_WT, les couloirs vivants, et OV_ROWS, une ligne « <i><TAB><j><TAB><fichier, fichier…> » par paire i < j qui
# touche les mêmes fichiers (avec <wt> : OV_SELF, son rang, et les seules paires dont il est le premier) ; même réponse que lane_files
overlaps_load() {
  local wt="${1:-}" d ref base i=0 n k mb oid st old plain=0 feed='' batch='' trees; local -a mbs=() oids=() sts=()
  OV_WT=() OV_ROWS='' OV_SELF=''
  for d in "$P_ROOT"/.worktrees/*/; do if [ -f "$d.git" ]; then OV_WT+=("${d%/}"); fi; done
  if [ -n "$wt" ]; then
    for ((i = 0; i < ${#OV_WT[@]}; i++)); do if same_path "${OV_WT[$i]}" "$wt"; then OV_SELF="$i"; break; fi; done
    [ -n "$OV_SELF" ] || { OV_SELF="${#OV_WT[@]}"; OV_WT+=("$wt"); }
  fi
  n="${#OV_WT[@]}"; [ "$n" -ge 2 ] || return 0
  base="${P_STAGING:-$P_BASE}"; ref="$P_REMOTE/$base"
  git -C "$P_ROOT" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 || ref="$base"
  # renommages ou sous-modules réglés à la main : git diff suit ces réglages, diff-tree non — l'ancienne lecture, couloir par couloir
  ! git -C "$P_ROOT" config --get-regexp '^diff\.(renames|ignoresubmodules|relative)$' >/dev/null 2>&1 || plain=1
  for ((i = 0; i < n; i++)); do
    wt="${OV_WT[$i]}"
    if [ "$plain" = 1 ]; then feed="$feed"$'\035'"S $i 1 -"$'\n'$'\035R\n'"$(lane_files "$wt")"$'\n'; continue; fi
    st=''; old=1
    for ((k = 0; k < ${#LK_WT[@]}; k++)); do if [ "${LK_WT[$k]}" = "$wt" ]; then st="${LK_ST[$k]}"; old=0; break; fi; done
    if [ "$old" = 1 ]; then LANE_STATUS_KEEP=0 lane_status_set "$wt" 2>/dev/null; st="$LANE_STATUS"; fi
    oid="${st#*\# branch.oid }"; [ "$oid" != "$st" ] || oid='-'; oid="${oid%%$'\n'*}"
    mb="$(exec git -C "$wt" merge-base "$ref" HEAD 2>/dev/null)" || mb=''
    case "$oid" in *[!0-9a-f]*) mb='' ;; esac
    mbs[i]="$mb"; oids[i]="$oid"; sts[i]="$st"
    [ -z "$mb" ] || batch="$batch$mb^{tree}"$'\n'"$oid^{tree}"$'\n'
  done
  if [ "$plain" = 0 ]; then
    trees=''
    if [ -n "$batch" ]; then
      trees="$(exec git -C "$P_ROOT" cat-file --batch-check='%(objectname)' <<<"$ref^{tree}"$'\n'"${batch%$'\n'}" 2>/dev/null)" || true
      base="${trees%%$'\n'*}"; trees="${trees#*$'\n'}"$'\n'
    fi
    batch=''
    for ((i = 0; i < n; i++)); do
      wt="${OV_WT[$i]}"; st="${sts[$i]}"; old=0; mb='-' oid='-'
      if [ -n "${mbs[$i]}" ]; then
        mb="${trees%%$'\n'*}"; trees="${trees#*$'\n'}"; oid="${trees%%$'\n'*}"; trees="${trees#*$'\n'}"
        case "$mb$oid$base" in *[!0-9a-f]*) mb='-' ;; *) batch="$batch$mb $oid"$'\n'"$base $oid"$'\n' ;; esac
      fi
      # indexé et modifié à la fois, renommé, en conflit, ajout à venir, sous-module, ajout et suppression ensemble : git diff HEAD seul
      # sait ce qui diffère encore de HEAD
      case $'\n'"$st" in
        *$'\n2 '*|*$'\nu '*|*$'\n1 '[!.][!.]' '*|*$'\n1 .A '*|*$'\n1 '??' S'*) old=1 ;;
        *$'\n1 A'*) case $'\n'"$st" in *$'\n1 D'*|*$'\n1 .D'*) old=1 ;; esac ;;
      esac
      feed="$feed"$'\035'"S $i $old $mb $oid $base"$'\n'"$st"$'\n'
      if [ "$old" = 1 ]; then feed="$feed"$'\035R\n'"$(exec git -C "$wt" diff --name-only HEAD 2>/dev/null)"$'\n'; fi
    done
    if [ -n "$batch" ]; then
      feed="$feed"$'\035D\n'"$(exec git -C "$P_ROOT" diff-tree --stdin -r -M --name-only <<<"${batch%$'\n'}" 2>/dev/null)"$'\n' || true
    fi
  fi
  # triés dans la langue du terminal, comme avant : l'ordre des fichiers affichés ne change pas
  OV_ROWS="$(LC_ALL=C awk "$OVERLAP_FILES_AWK" <<<"$feed" | sort -t "$(printf '\t')" -k1,1 -k2,2n | LC_ALL=C awk -v lanes="$n" -v only="$OV_SELF" "$OVERLAP_PAIRS_AWK")"
}
# overlaps <wt> → une ligne par autre couloir vivant qui touche les mêmes fichiers : « <couloir><TAB><fichier, fichier…> »
overlaps() {
  local i j files
  overlaps_load "$1"
  while IFS=$'\t' read -r i j files; do
    if [ -z "$i" ] || same_path "${OV_WT[$j]}" "$1"; then continue; fi
    wt_lane_set "${OV_WT[$j]}"; printf '%s\t%s\n' "$WT_LANE" "$files"
  done <<<"$OV_ROWS"
}
# overlap_order <wt> <wt> [gh=1] → « premier<TAB>second<TAB>libellé lisible » : PR armée/prête > brouillon > sans PR, puis le plus ancien
overlap_order() { overlap_order_set "$@"; printf '%s\t%s\t%s\n' "$OV_FIRST" "$OV_SECOND" "$OV_LABEL"; }
overlap_order_set() { # les mêmes arguments : OV_FIRST, OV_SECOND, OV_LABEL
  local ra rb ka kb na nb
  overlap_lane "$1" "${3:-1}"; ra="$OL_RANK"; ka="${ra%%$'\t'*}|$OL_SINCE"; na="$OL_NAME"
  overlap_lane "$2" "${3:-1}"; rb="$OL_RANK"; kb="${rb%%$'\t'*}|$OL_SINCE"; nb="$OL_NAME"
  if [ "$kb" \< "$ka" ]; then OV_FIRST="$nb"; OV_SECOND="$na"; OV_LABEL="$nb (${rb#*$'\t'}) then $na (${ra#*$'\t'})"
  else OV_FIRST="$na"; OV_SECOND="$nb"; OV_LABEL="$na (${ra#*$'\t'}) then $nb (${rb#*$'\t'})"; fi
}
# overlap_lane <wt> <gh> : OL_NAME, OL_RANK, OL_SINCE, lus une fois par couloir dans un même affichage (OL_WT, posé par overlap_status_kv)
OL_WT=() OL_N=() OL_R=() OL_S=() OL_MEMO=0
overlap_lane() {
  local k
  if [ "$OL_MEMO" = 1 ]; then
    for ((k = 0; k < ${#OL_WT[@]}; k++)); do
      if [ "${OL_WT[$k]}" = "$1" ]; then OL_NAME="${OL_N[$k]}"; OL_RANK="${OL_R[$k]}"; OL_SINCE="${OL_S[$k]}"; return 0; fi
    done
  fi
  lane_rank_set "$1" "$2"; OL_RANK="$LANE_RANK"; lane_since_set "$1"; OL_SINCE="$LANE_SINCE"; wt_lane_set "$1"; OL_NAME="$WT_LANE"
  if [ "$OL_MEMO" = 1 ]; then OL_WT+=("$1"); OL_N+=("$OL_NAME"); OL_R+=("$OL_RANK"); OL_S+=("$OL_SINCE"); fi
}
# overlap_hook_line <wt> → « CHEVAUCHEMENT=… » pour le contexte de démarrage (git local seul, trois fichiers au plus), ou rien
overlap_hook_line() {
  local lane files one shown n out=""
  while IFS=$'\t' read -r lane files; do
    [ -n "$lane" ] || continue
    n=0; shown=''; files="$files, "
    while [ -n "$files" ]; do
      one="${files%%, *}"; files="${files#*, }"; n=$((n + 1))
      if [ "$n" -gt 3 ]; then shown="$shown, …"; break; fi
      shown="$shown${shown:+, }$one"
    done
    out="${out:+$out ; }$lane ($shown)"
  done < <(overlaps "$1")
  [ -z "$out" ] || printf 'OVERLAP=%s — merge order: lab status %s.\n' "$out" "$P_NAME"
}
# overlap_status_kv [wt] : un bloc par paire de couloirs qui se chevauchent (lab status), chaque paire une seule fois ; avec <wt>, les
# seules paires de ce couloir (lab status <projet> <couloir>)
overlap_status_kv() {
  local i j files wt me lane seen=" "
  overlaps_load; OL_MEMO=1
  while IFS=$'\t' read -r i j files; do
    [ -n "$i" ] || continue
    wt="${OV_WT[$i]}"; if same_path "${OV_WT[$j]}" "$wt"; then continue; fi
    wt_lane_set "${OV_WT[$j]}"; lane="$WT_LANE"; wt_lane_set "$wt"; me="$WT_LANE"
    case "$seen" in *" $lane:$me "*) continue ;; esac
    seen="$seen$me:$lane "
    if [ -n "${1:-}" ] && ! same_path "$wt" "$1" && ! same_path "${OV_WT[$j]}" "$1"; then continue; fi
    overlap_order_set "$wt" "$P_ROOT/.worktrees/$lane"
    kv OVERLAP "$me ↔ $lane"; kv FILES "$files"
    kv ORDER "$OV_LABEL — $OV_SECOND resyncs after $OV_FIRST is merged (lab sync $P_NAME $OV_SECOND)"
    sep
  done <<<"$OV_ROWS"
  OL_MEMO=0 OL_WT=() OL_N=() OL_R=() OL_S=()
}
# overlap_merge_warn <wt> : avertissement non bloquant de lab merge — les couloirs à resynchroniser après cette fusion
overlap_merge_warn() {
  local lane files names=""
  while IFS=$'\t' read -r lane files; do
    [ -n "$lane" ] || continue
    warn "overlap with lane $lane ($files): after this merge, run lab sync $P_NAME $lane"
    names="${names:+$names }$lane"
  done < <(overlaps "$1")
  [ -z "$names" ] || kv RESYNC "$names"
}
