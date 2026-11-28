# shellcheck shell=bash
# night.sh — la nuit GitHub de la base (événement schedule), lot 03 de ci-sobre : la suite lourde ne tourne plus sur les PR, la nuit
# est le filet. Un cache par projet ($LAB_STATE/night-<projet>, KEY=value), écrit par lab next et lab close (un seul appel gh) ;
# le hook de démarrage le lit seul, jamais gh. Une panne de gh garde le cache tel quel.

night_file() { printf '%s/night-%s\n' "$LAB_STATE" "$1"; }
# night_get <projet> <clé> → valeur du cache, vide sans cache ou sans clé
night_get() { local f; f="$(night_file "$1")"; [ -f "$f" ] || return 0; sed -n "s/^$2=//p" "$f" | head -1; }

# Lecture gh → une ligne, champs séparés par 0x1F (jamais une tabulation : read fusionnerait des champs vides consécutifs) : état, workflow, run, url, date du dernier rouge, date du premier rouge, sha du dernier rouge,
# sha du premier rouge, sha de la dernière verte. Terminées seulement ; annulées, sautées et neutres ne tranchent rien. La dernière
# conclusion de chaque workflow décide : un seul rouge suffit, le plus récent est décrit. Sans verte connue, le sha vert est vide.
# shellcheck disable=SC2016 # programme jq littéral
NIGHT_JQ='
  [ .[] | select(.status == "completed" and ((.conclusion // "") as $c | ["success", "failure", "timed_out", "startup_failure"] | index($c))) ]
  | sort_by(.createdAt) | reverse | . as $r
  | if length == 0 then ["none", "", "", "", "", "", "", "", ""]
    else
      [ ($r | map(.workflowName) | unique)[] as $w | first($r[] | select(.workflowName == $w)) ] as $latest
      | [ $latest[] | select(.conclusion != "success") ] as $reds
      | if ($reds | length) == 0 then ($latest | max_by(.createdAt)) as $g | ["green", $g.workflowName, $g.databaseId, $g.url, $g.createdAt, "", "", "", $g.headSha]
        else ($reds | max_by(.createdAt)) as $w
          | [ $r[] | select(.workflowName == $w.workflowName) ] as $wr
          | ($wr | map(.conclusion == "success") | index(true)) as $gi
          | (if $gi == null then $wr[-1] else $wr[$gi - 1] end) as $first
          | ["red", $w.workflowName, $w.databaseId, $w.url, $w.createdAt, $first.createdAt, $w.headSha, $first.headSha,
             (if $gi == null then "" else $wr[$gi].headSha end)]
        end
    end
  | map(tostring) | join("\u001f")'

# night_attribute <sha vert> <sha du premier rouge> → deux lignes : couloirs (séparés par une espace), puis numéros de PR.
# Commits first-parent entre la dernière verte et le premier rouge, lus dans le checkout principal (un fetch au plus si un sha
# manque, jamais sous lab close --dry-run : CLOSE_DRY=1) ; couloirs = sous-dossiers de docs/lots/ touchés, aucun ⇒ « main » ; docs hors dépôt (LAB_DOCS) ⇒ PR seulement.
night_attribute() {
  local green="$1" red="$2" c lanes="" prs="" subject n l
  [ -n "$green" ] && [ -n "$red" ] || { printf '\n\n'; return 0; }
  if [ "${CLOSE_DRY:-0}" != 1 ] && { ! git -C "$P_ROOT" cat-file -e "$green^{commit}" 2>/dev/null || ! git -C "$P_ROOT" cat-file -e "$red^{commit}" 2>/dev/null; }; then
    with_timeout 60 git -C "$P_ROOT" fetch -q "$P_REMOTE" "$P_BASE" 2>/dev/null || true
  fi
  if ! git -C "$P_ROOT" cat-file -e "$green^{commit}" 2>/dev/null || ! git -C "$P_ROOT" cat-file -e "$red^{commit}" 2>/dev/null; then
    printf '\n\n'; return 0
  fi
  for c in $(git -C "$P_ROOT" rev-list --first-parent --reverse "$green..$red" 2>/dev/null); do
    subject="$(git -C "$P_ROOT" log -1 --format=%s "$c")"
    n="$(printf '%s\n' "$subject" | sed -n 's/.*(#\([0-9][0-9]*\)).*/\1/p; s/^Merge pull request #\([0-9][0-9]*\).*/\1/p' | head -1)"
    [ -z "$n" ] || case " $prs " in *" #$n "*) ;; *) prs="${prs:+$prs }#$n" ;; esac
    [ "$P_DOCS" = repo ] || continue
    for l in $(git -C "$P_ROOT" diff --name-only "$c^1" "$c" 2>/dev/null | sed -n 's|^docs/lots/\([^/]*\)/.*|\1|p' | sort -u); do
      case " $lanes " in *" $l "*) ;; *) lanes="${lanes:+$lanes }$l" ;; esac
    done
  done
  [ "$P_DOCS" != repo ] || [ -n "$lanes" ] || lanes=main
  printf '%s\n%s\n' "$lanes" "$prs"
}

# night_refresh : après load_project. rc 1 (cache intact) sans gh ou si gh échoue ; sinon réécrit le cache, rc 0.
night_refresh() {
  local -a rargs=(); local s json row state wf run url date since last first green lanes prs f tmp
  has_gh || return 1
  s="$(repo_slug "$P_ROOT" "$P_REMOTE" 2>/dev/null)" && rargs=(-R "$s")
  json="$(with_timeout 20 gh run list "${rargs[@]+"${rargs[@]}"}" --event schedule --branch "$P_BASE" --limit 40 \
    --json databaseId,workflowName,status,conclusion,headSha,createdAt,url 2>/dev/null)" || return 1
  row="$(printf '%s' "$json" | jq -r "$NIGHT_JQ" 2>/dev/null)" && [ -n "$row" ] || return 1
  IFS=$'\037' read -r state wf run url date since last first green <<<"$row"
  lanes=""; prs=""
  if [ "$state" = red ]; then { IFS= read -r lanes; IFS= read -r prs; } < <(night_attribute "$green" "$first"); fi
  f="$(night_file "$P_NAME")"; mkdir -p "$(dirname "$f")"; tmp="$(mktemp "$f.XXXXXX")"
  printf 'state=%s\nbase=%s\nworkflow=%s\nrun=%s\nurl=%s\ndate=%s\nsince=%s\nred_sha=%s\nfirst_red_sha=%s\ngreen_sha=%s\nlanes=%s\nprs=%s\nchecked=%s\n' \
    "$state" "$P_BASE" "$wf" "$run" "$url" "$date" "$since" "$last" "$first" "$green" "$lanes" "$prs" "$(rdv_now)" >"$tmp" && mv "$tmp" "$f"
}

# night_red <projet> : rc 0 si le cache dit rouge
night_red() { [ "$(night_get "$1" state)" = red ]; }
# night_age <horodatage> → « 5m », « 3h », « 2d » depuis cet instant ; vide s'il est illisible
night_age() {
  local at now d
  at="$(rdv_epoch "${1:-}" 2>/dev/null)" && now="$(rdv_epoch "$(rdv_now)" 2>/dev/null)" || return 0
  d=$((now - at)); [ "$d" -ge 0 ] || d=0
  if [ "$d" -lt 3600 ]; then printf '%dm\n' $((d / 60)); elif [ "$d" -lt 172800 ]; then printf '%dh\n' $((d / 3600)); else printf '%dd\n' $((d / 86400)); fi
}
night_fix_cmd() { printf 'lab new %s fix-nuit-%s --kind fix\n' "$1" "$(night_get "$1" date | cut -c1-10)"; }
# night_involved <projet> <couloir> : rc 0 si le couloir est attribué
night_involved() { case " $(night_get "$1" lanes) " in *" $2 "*) return 0 ;; esac; return 1; }
# night_summary <projet> → « nightly CI on main red since … (last …, read …) after lanes … (PR …) » ; vide si la nuit n'est pas rouge
night_summary() {
  local p="$1" lanes prs age who
  night_red "$p" || return 0
  lanes="$(night_get "$p" lanes)"; prs="$(night_get "$p" prs)"; age="$(night_age "$(night_get "$p" checked)")"
  who="${lanes:+lanes ${lanes// /, }}"; [ "$lanes" != main ] || who="main"
  [ -z "$prs" ] || who="${who:+$who }(PR $prs)"
  printf 'nightly %s on %s red since %s (last %s%s)%s\n' "$(night_get "$p" workflow)" "$(night_get "$p" base)" \
    "$(night_get "$p" since | cut -c1-10)" "$(night_get "$p" date | cut -c1-10)" "${age:+, read $age ago}" "${who:+ after $who}"
}
# night_first <n> <séparateur> <mots> → les n premiers mots joints par le séparateur, puis « +k » s'il en reste
night_first() { printf '%s' "$3" | awk -v n="$1" -v sep="$2" '{ for (i = 1; i <= NF && i <= n; i++) printf "%s%s", (i > 1 ? sep : ""), $i; if (NF > n) printf " +%d", NF - n }'; }
# night_line <projet> [couloir] → la ligne du contexte de démarrage, vide si la nuit n'est pas rouge (cache seul). Courte : elle passe
# en tête, avant la coupe à 800 — trois couloirs et quatre PR au plus, le reste compté.
night_line() {
  local p="$1" lanes prs age who
  night_red "$p" || return 0
  lanes="$(night_first 3 ', ' "$(night_get "$p" lanes)")"; prs="$(night_first 4 ' ' "$(night_get "$p" prs)")"
  age="$(night_age "$(night_get "$p" checked)")"
  who="$lanes${prs:+${lanes:+ }($prs)}"
  printf 'NIGHT=red on %s since %s%s%s%s: fix in a fix/ lane, %s.\n' "$(night_get "$p" base)" "$(night_get "$p" since | cut -c1-10)" \
    "${age:+ (read $age ago)}" "${who:+ after $who}" "$(! night_involved "$p" "${2:-}" || echo ' — this lane is involved')" "$(night_fix_cmd "$p")"
}

# ---------- lab close : accord explicite sur une nuit rouge ----------
NIGHT_AGREE_FIELD='Accord nuit rouge'
# night_close_refusal → le message du refus, partagé par lab close et lab close --dry-run
night_close_refusal() {
  printf 'last night red — %s: fix it first (%s), or close anyway with lab close %s %s --night-red-ok "<reason>"; nothing delivered\n' \
    "$(night_summary "$P_NAME")" "$(night_fix_cmd "$P_NAME")" "$P_NAME" "$SLUG"
}
# night_button_refusal (lot 10) : le refus donné à un agent — le bouton à poser, dont le clic lu par lab est l'accord nuit rouge ;
# night_refusal_for_caller : celui de l'agent, ou celui de l'utilisateur dans son terminal (--night-red-ok)
night_button_refusal() {
  printf 'last night red — %s: fix it first (%s), or ask the user once with AskUserQuestion, one button labelled "Close %s despite the red night" (in the user'"'"'s language) and one "Keep %s": their click, read by lab, is the night red agreement — then run lab close %s %s again; nothing delivered\n' \
    "$(night_summary "$P_NAME")" "$(night_fix_cmd "$P_NAME")" "$SLUG" "$SLUG" "$P_NAME" "$SLUG"
}
night_refusal_for_caller() { if [ "$(caller_role)" = human ]; then night_close_refusal; else night_button_refusal; fi; }
# night_words_reason : le motif écrit par lab pour un accord nuit rouge venu des mots ou du clic de l'utilisateur (words_valid lu)
night_words_reason() {
  case "$WD_SOURCE" in click) printf "user's click" ;; voice) printf "user's voice" ;; *) printf "user's words" ;; esac
  printf ': "%s" (%s)' "$WD_SAID" "$(words_where)"
}
# night_order_reason (lot 04 d'onglet-tower) : le motif écrit par lab quand l'accord par les mots (via=words close=yes, AG_SAID posé
# par agreement_by_words) tient lieu d'accord de nuit rouge — un seul « oui ferme » suffit, la nuit nommée par lab sans question
night_order_reason() { printf 'user'"'"'s order to close: "%s", given with the acceptance, red night named by lab' "$AG_SAID"; }
# night_fix_proof <tête> → « <run> <sha> », rc 0 : la plus récente nuit manuelle (workflow_dispatch) verte du workflow de la nuit
# rouge, sur une révision qui contient le premier rouge et précède la tête (lot 02 de fix-nuit-2026-11-14), qui a joué en vert
# chaque tâche rouge de la nuit rouge (lot 02 de ci-legere : la nuit manuelle est Linux seule sauf case macos cochée — verte sans
# macOS, elle ne prouve pas un rouge macOS). Lectures gh : la liste, puis les tâches de la nuit rouge et de chaque candidate ; aucun
# fetch : une révision absente du dépôt local n'est l'ancêtre d'aucune tête locale. Sans gh, gh en panne, tâches illisibles ou
# rien de valide → rc 1.
# shellcheck disable=SC2016 # programme jq littéral
NIGHT_PROOF_JQ='[ .[] | select(.status == "completed" and .conclusion == "success" and .workflowName == $wf) ]
  | sort_by(.createdAt) | reverse | .[] | "\(.databaseId) \(.headSha)"'
# night_run_jobs <run> [-R <dépôt>] → « conclusion<TAB>nom » par tâche de la dernière tentative ; une liste vide (startup_failure)
# est lisible et ne rend rien ; rc ≠ 0 si gh échoue ou si la réponse n'a pas de liste de tâches
night_run_jobs() {
  local run="$1" json; shift
  json="$(with_timeout 20 gh run view "$run" "$@" --json jobs 2>/dev/null)" || return 1
  printf '%s' "$json" | jq -r '.jobs | if type == "array" then .[] | [(.conclusion // ""), .name] | @tsv else error("no jobs") end' 2>/dev/null
}
# night_covers <tâches rouges> <tâches de la candidate> : rc 0 si chaque nom rouge y est conclu success
night_covers() {
  local name ok=$'success\t'
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    grep -qxF "$ok$name" <<<"$2" || return 1
  done <<<"$1"
}
night_fix_proof() {
  local head="$1" wf first s json id sha red="" reds="" jobs; local -a rargs=()
  night_red "$P_NAME" && [ -n "$head" ] || return 1
  wf="$(night_get "$P_NAME" workflow)"; first="$(night_get "$P_NAME" first_red_sha)"
  [ -n "$wf" ] && [ -n "$first" ] && has_gh || return 1
  s="$(repo_slug "$P_ROOT" "$P_REMOTE" 2>/dev/null)" && rargs=(-R "$s")
  json="$(with_timeout 20 gh run list "${rargs[@]+"${rargs[@]}"}" --event workflow_dispatch --workflow "$wf" --limit 40 \
    --json databaseId,workflowName,status,conclusion,headSha,createdAt,url 2>/dev/null)" || return 1
  while read -r id sha; do
    [ -n "$sha" ] || continue
    git -C "$P_ROOT" merge-base --is-ancestor "$first" "$sha" 2>/dev/null || continue
    git -C "$P_ROOT" merge-base --is-ancestor "$sha" "$head" 2>/dev/null || continue
    # tâches rouges de la nuit rouge, lues une fois et seulement devant une candidate : illisibles → aucune preuve
    if [ -z "$red" ]; then
      jobs="$(night_run_jobs "$(night_get "$P_NAME" run)" "${rargs[@]+"${rargs[@]}"}")" || return 1
      reds="$(awk -F '\t' 'NF >= 2 && $1 != "success" && $1 != "skipped" && $1 != "neutral" { print $2 }' <<<"$jobs")"; red=1
    fi
    if [ -n "$reds" ]; then
      jobs="$(night_run_jobs "$id" "${rargs[@]+"${rargs[@]}"}")" || continue
      night_covers "$reds" "$jobs" || continue
    fi
    printf '%s %s\n' "$id" "$sha"; return 0
  done < <(printf '%s' "$json" | jq -r --arg wf "$wf" "$NIGHT_PROOF_JQ" 2>/dev/null)
  return 1
}
# night_proof_reason <run> <sha> → le motif de l'accord prouvé, partagé par la note du dry run et la ligne de recette
night_proof_reason() {
  printf 'proof of fix: manual night run %s green on %s, contains the first red %s and precedes the head' \
    "$1" "$(printf '%s' "$2" | cut -c1-12)" "$(night_get "$P_NAME" first_red_sha | cut -c1-12)"
}
# night_agree_write <fiche> <ligne> : la ligne ajoutée en fin de section de recette (avant la section suivante), rien d'autre ne bouge
night_agree_write() {
  local tmp; tmp="$(mktemp "$1.XXXXXX")"
  LINE="$2" awk -v re="^## ($(lang_section_re 'Recette du couloir'))[[:space:]]*$" '
    function put() { if (inside && !done) { printf "%s\n", ENVIRON["LINE"]; done = 1 } }
    function flush() { while (blank > 0) { print ""; blank-- } }
    !fence && inside && /^## / { put(); if (!blank) blank = 1; flush(); inside = 0; print; next }
    /^[[:space:]]*(```|~~~)/ { flush(); fence = !fence; print; next }
    !fence && $0 ~ re { inside = 1; print; next }
    inside && /^[[:space:]]*$/ { blank++; next }
    { flush(); print }
    END { put(); flush() }' "$1" >"$tmp" && mv "$tmp" "$1"
}
# night_close_gate <motif> <posé=0|1> : avant toute livraison. Nuit rouge sans accord → refus nommé ; avec un motif → la ligne datée
# est écrite dans la section de recette de la fiche, commitée et poussée comme lab acceptance (une seule fois par nuit rouge). Sans
# motif, une preuve de correctif (night_fix_proof sur la tête du couloir), le clic du bouton ou l'accord par les mots en tiennent lieu.
# night_agreed_file / night_agreed_here <fiche> (revue de sécurité du lot 10) : l'accord de nuit commité par lab lui-même, marqué
# dans son état (numéro de la nuit, commit) — une ligne écrite dans la fiche par un agent ne porte jamais une relance de lab close
night_agreed_file() { printf '%s/%s/night-agreed/%s\n' "$LAB_STATE" "$P_NAME" "$SLUG"; }
night_agreed_here() {
  local run body; run="$(night_get "$P_NAME" run)"
  [ -n "$run" ] && [ "$(sed -n 's/^run=//p' "$(night_agreed_file)" 2>/dev/null)" = "$run" ] || return 1
  body="$(recette_filter body <"$1" 2>/dev/null)" && grep -qF "night run $run " <<<"$body"
}
night_close_gate() {
  local reason="$1" set="$2" lot droot rel lang line nn branch run proof clicked=0 body
  night_refresh || true
  night_red "$P_NAME" || return 0
  lot="$(wt_lot_file "$WT")"; lot="$(real_path "$(dirname "$lot")")/$(basename "$lot")"
  run="$(night_get "$P_NAME" run)"
  # revue du lot 10 : l'accord de cette nuit déjà commité (un clic consommé, puis une fermeture arrêtée plus loin) vaut pour la relance
  if [ "$set" != 1 ] && night_agreed_here "$lot"; then
    close_recette_guard; log "night red agreement already in $(basename "$lot"): closing goes on"; return 0
  fi
  if [ "$set" != 1 ]; then
    if proof="$(night_fix_proof "$(git -C "$WT" rev-parse HEAD 2>/dev/null)")"; then reason="$(night_proof_reason "${proof% *}" "${proof#* }")"
    # lot 10 : le clic de l'utilisateur sur « Close <couloir> despite the red night », lu par lab, est l'accord ; motif écrit par lab
    elif words_valid "$WT" night; then reason="$(night_words_reason)"; clicked=1
    elif agreement_by_words "$WT"; then reason="$(night_order_reason)"   # lot 04 d'onglet-tower : le oui de fermer couvre la nuit
    else die "$(night_refusal_for_caller)"; fi
  fi
  close_recette_guard   # l'accord s'ajoute à une recette valide, jamais à sa place
  if body="$(recette_filter body <"$lot")" && grep -qF "night run $run " <<<"$body"; then
    log "night red agreement already in $(basename "$lot"): closing goes on"; return 0
  fi
  droot="$(real_path "$(repo_root "$(dirname "$lot")")")"; rel="${lot#"$droot"/}"
  lang="$(lang_doc_of "$lot")"
  line="$(printf '**%s** : %s — %s (night run %s red on %s since %s)' "$(lang_word "$lang" "$NIGHT_AGREE_FIELD")" "$(rdv_now | cut -c1-10)" \
    "$reason" "$run" "$(night_get "$P_NAME" red_sha | cut -c1-12)" "$(night_get "$P_NAME" since | cut -c1-10)")"
  night_agree_write "$lot" "$line"
  nn="$(lot_number_of "$lot")"
  git_commit_paths "$droot" "docs(acceptance): $SLUG — night red agreement${nn:+ (lot-$nn)}" "$rel"
  [ "$COMMIT_RESULT" != failed ] || die "night red agreement written but not committed — git: $COMMIT_REASON; lane kept"
  kv NIGHT_AGREEMENT "$COMMIT_RESULT"
  ( umask 077; mkdir -p "$(dirname "$(night_agreed_file)")" && printf 'run=%s\ncommit=%s\n' "$run" "$COMMIT_RESULT" >"$(night_agreed_file)" ) 2>/dev/null || true
  [ "$clicked" = 0 ] || words_clear "$SLUG"   # le clic a servi une fois
  branch="$(branch_name "$WT")"
  if same_path "$WT" "$droot" && [ -n "$branch" ] && git -C "$WT" ls-remote --exit-code "$P_REMOTE" "refs/heads/$branch" >/dev/null 2>&1; then
    git -C "$WT" push -q "$P_REMOTE" "HEAD:refs/heads/$branch" 2>/dev/null \
      || die "night red agreement committed but not pushed to $P_REMOTE/$branch: push the branch, then run lab close $P_NAME $SLUG again"
  fi
  log "night red agreement recorded in $rel: $reason"
}
