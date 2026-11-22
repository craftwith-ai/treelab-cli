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
  if [ "$(recette_status "$1" "$lot")" = valid ]; then SYNC_RECETTE="valid (no lane file in this merge)"
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
  SYNC_FILES=""
  git -C "$wt" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 || return 2
  out="$(git -C "$wt" merge-tree --write-tree -z --name-only --no-messages "$ours" "$ref" 2>/dev/null | tr '\0' '\n')" || rc=$?
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
lane_rank() {
  local wt="$1" br lane f info num draft s; local -a rargs=()
  br="$(branch_name "$wt")"; lane="$(wt_lane "$wt")"; f="$(watch_file "$br" "$lane")"
  case "$(watch_state "$f" 2>/dev/null)" in armed|waiting) printf '0\tPR armed\n'; return ;; esac
  if [ "${2:-1}" = 1 ] && has_gh; then
    info="$(pr_info "$P_ROOT" "$br")"
    if [ "$(printf '%s' "$info" | cut -f2)" = OPEN ]; then
      num="$(printf '%s' "$info" | cut -f1)"
      s="$(repo_slug "$P_ROOT" "$P_REMOTE" 2>/dev/null)" && rargs=(-R "$s")
      draft="$(with_timeout 20 gh pr view "${rargs[@]+"${rargs[@]}"}" "$num" --json isDraft --jq .isDraft 2>/dev/null)" || draft=""
      if [ "$draft" = true ]; then printf '1\tdraft PR #%s\n' "$num"; else printf '0\tready PR #%s\n' "$num"; fi
      return
    fi
  fi
  printf '2\tno PR\n'
}
# lane_since <wt> → date de création du couloir (méta created), sinon date de son premier commit propre ; « 9999 » si inconnue
lane_since() {
  local c; c="$(wt_meta "$1" created)"
  if [ -z "$c" ]; then
    c="$(git -C "$1" log --reverse --format=%cd --date=format:%Y-%m-%dT%H:%M "$(sync_ref)..HEAD" 2>/dev/null | head -1 || true)"
  fi
  printf '%s\n' "${c:-9999}"
}
# live_lanes → chemins des couloirs vivants du projet (worktrees de $P_ROOT/.worktrees)
live_lanes() { local d; for d in "$P_ROOT"/.worktrees/*/; do [ -f "$d.git" ] && printf '%s\n' "${d%/}"; done; return 0; }
# overlaps <wt> → une ligne par autre couloir vivant qui touche les mêmes fichiers : « <couloir><TAB><fichier, fichier…> »
overlaps() {
  local wt="$1" mine other common
  mine="$(lane_files "$wt")"; [ -n "$mine" ] || return 0
  while IFS= read -r other; do
    if [ -z "$other" ] || same_path "$other" "$wt"; then continue; fi
    common="$(comm -12 <(printf '%s\n' "$mine") <(lane_files "$other") | sed '/^$/d')"
    [ -z "$common" ] || printf '%s\t%s\n' "$(wt_lane "$other")" "$(printf '%s\n' "$common" | sync_join)"
  done < <(live_lanes)
}
# overlap_order <wt> <wt> [gh=1] → « premier<TAB>second<TAB>libellé lisible » : PR armée/prête > brouillon > sans PR, puis le plus ancien
overlap_order() {
  local a="$1" b="$2" ra rb ka kb la lb
  ra="$(lane_rank "$a" "${3:-1}")"; rb="$(lane_rank "$b" "${3:-1}")"
  ka="${ra%%$'\t'*}|$(lane_since "$a")"; kb="${rb%%$'\t'*}|$(lane_since "$b")"
  la="$(wt_lane "$a") (${ra#*$'\t'})"; lb="$(wt_lane "$b") (${rb#*$'\t'})"
  if [ "$kb" \< "$ka" ]; then
    printf '%s\t%s\t%s then %s\n' "$(wt_lane "$b")" "$(wt_lane "$a")" "$lb" "$la"
  else
    printf '%s\t%s\t%s then %s\n' "$(wt_lane "$a")" "$(wt_lane "$b")" "$la" "$lb"
  fi
}
# overlap_hook_line <wt> → « CHEVAUCHEMENT=… » pour le contexte de démarrage (git local seul, trois fichiers au plus), ou rien
overlap_hook_line() {
  local lane files n shown out=""
  while IFS=$'\t' read -r lane files; do
    [ -n "$lane" ] || continue
    n="$(printf '%s\n' "$files" | awk -F', ' '{print NF}')"
    shown="$(printf '%s\n' "$files" | awk -F', ' '{for (i = 1; i <= NF && i <= 3; i++) printf "%s%s", (i > 1 ? ", " : ""), $i}')"
    [ "$n" -le 3 ] || shown="$shown, …"
    out="${out:+$out ; }$lane ($shown)"
  done < <(overlaps "$1")
  [ -z "$out" ] || printf 'OVERLAP=%s — merge order: lab status %s.\n' "$out" "$P_NAME"
}
# overlap_status_kv : un bloc par paire de couloirs qui se chevauchent (lab status), chaque paire une seule fois
overlap_status_kv() {
  local wt lane files other order seen=" "
  while IFS= read -r wt; do
    while IFS=$'\t' read -r lane files; do
      [ -n "$lane" ] || continue
      case "$seen" in *" $lane:$(wt_lane "$wt") "*) continue ;; esac
      seen="$seen$(wt_lane "$wt"):$lane "
      other="$(worktree_path "$lane")"; order="$(overlap_order "$wt" "$other")"
      kv OVERLAP "$(wt_lane "$wt") ↔ $lane"; kv FILES "$files"
      kv ORDER "$(printf '%s' "$order" | cut -f3) — $(printf '%s' "$order" | cut -f2) resyncs after $(printf '%s' "$order" | cut -f1) is merged (lab sync $P_NAME $(printf '%s' "$order" | cut -f2))"
      sep
    done < <(overlaps "$wt")
  done < <(live_lanes)
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
