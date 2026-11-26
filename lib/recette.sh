# shellcheck shell=bash
# Recette du couloir : décisions relues dans les fiches, jamais de fichier d’état.
# Dépend de git.sh, project.sh, docs.sh et deploy.sh ; charge lui-même waiting.sh (phase « waiting », lot 02 d'autonomie-tours).
declare -F wait_lane_first >/dev/null || . "${BASH_SOURCE[0]%/*}/waiting.sh"
declare -F snap_mark >/dev/null || . "${BASH_SOURCE[0]%/*}/snapshot.sh"   # instantané de Treelab.app (lot 03 d'app-treelab)

# recette_filter <body|strip|count> : section exacte sur stdin, hors blocs de code.
recette_filter() {
  lang_norm | LC_ALL=C awk -v mode="$1" "$DOC_AWK"'
    BEGIN { recette_reset() }
    {
      r = recette_scan($0)
      if (r == 2) next
      if (mode == "strip" && !RC_IN) print
      else if (mode == "body" && RC_IN && r == 0 && !RC_FENCE) print
    }
    END {if (mode == "count") print RC_COUNT+0}'
}
# recette_validated_by <fiche> : la ligne Validated by de la recette, fiche française ou anglaise (recette_field lit les noms
# internes français) ; le nom reste ici, jamais dans le code qui l'appelle (tests/livre_anglais.bats, CI Linux du 2026-11-21)
recette_validated_by() { local lang=fr; recette_field "$1" "$(lang_word "$lang" 'Validé par')"; }
recette_field() { # <fiche> <champ> : un seul champ, sinon vide
  recette_filter body <"$1" | LC_ALL=C awk -v key="**$2**" "$DOC_AWK"'
    recette_field_scan($0, key) { value = RF_V; n++ }
    END {if (n == 1) print value}'
}
# recette_fact_set <fiche> <champ> : RECETTE_FACT, le même champ, lu avec les autres faits de la fiche (lib/facts.sh)
recette_fact_set() {
  local k
  RECETTE_FACT=''
  case "$2" in Décision) k=DECISION ;; Date) k=DATE ;; 'Révision essayée') k=REVISION ;; Preuves) k=PREUVES ;; 'Révision des documents') k=DOCS ;; *) return 1 ;; esac
  doc_need "$1" F || return 0
  doc_fact "$k"; RECETTE_FACT="$DOC_FACT"
}

# Formes tolérées (retour 1 du lot 01, 2026-09-15 : deux commits documentaires pour fermer un couloir validé, parce que le skill écrivait
# « 2026-09-08, essai … » et « `<sha>` » là où la CLI exigeait une date nue et un hexadécimal nu) : la date peut être suivie d'un
# suffixe libre, la révision entourée d'accents graves. Chaque fonction imprime la valeur normalisée, ou rien ; toujours rc 0.
recette_date_of() { # <valeur> → AAAA-MM-JJ si la valeur commence par une date du calendrier, sinon vide
  local d
  [[ "${1:-}" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})([^0-9].*)?$ ]] || return 0
  d="${BASH_REMATCH[1]}"
  [ "$(LC_ALL=C date -j -f '%Y-%m-%d' "$d" '+%Y-%m-%d' 2>/dev/null || true)" = "$d" ] || return 0
  printf '%s\n' "$d"
}
recette_revision_of() { # <valeur> → révision hexadécimale complète (40 ou 64), accents graves retirés, sinon vide
  local r="${1:-}"
  [[ "$r" =~ ^\`([0-9a-f]+)\`$ ]] && r="${BASH_REMATCH[1]}"
  [[ "$r" =~ ^[0-9a-f]+$ ]] || return 0
  [ "${#r}" = 40 ] || [ "${#r}" = 64 ] || return 0
  printf '%s\n' "$r"
}
# recette_field_check <fiche> <champ> : rc 0 si le champ est lisible ; sinon rc 1 et la valeur relue sur stdout (vide s'il est absent
# ou en double). Une seule règle par champ : recette_status et le refus de lab close lisent la même.
recette_field_check() {
  local value; value="$(recette_field "$1" "$2")"
  recette_value_ok "$value" "$2" && return 0
  printf '%s\n' "$value"; return 1
}
recette_value_ok() { # <valeur> <champ> : la même règle, sur la valeur déjà lue
  local value="$1"
  case "$2" in
    Décision) [ "$(lang_code "$value")" = accepted ] ;;
    Date) [ -n "$(recette_date_of "$value")" ] ;;
    'Révision essayée'|'Révision des documents') [ -n "$(recette_revision_of "$value")" ] ;;
    Preuves) case "$value" in ''|'<'*|TODO*|'à compléter'*) false ;; *) true ;; esac ;;
    *) false ;;
  esac
}
recette_expected() { # <champ> → la forme attendue, dite dans le refus
  case "$1" in
    Décision) printf 'accepted (validée in a French batch file)\n' ;;
    Date) printf 'YYYY-MM-DD, free suffix allowed after the date\n' ;;
    'Révision essayée') printf 'full Git revision (40 hex digits), backticks allowed\n' ;;
    'Révision des documents') printf 'HEAD of the external docs repository (40 hex digits), backticks allowed\n' ;;
    Preuves) printf 'real paths tried and explicit agreement, never the template\n' ;;
  esac
}
# recette_incomplete_detail <wt> <fiche> : le premier champ qui empêche la validation, sa valeur relue et la forme attendue
# (retour 2 du lot 01 : « décision, date, révision essayée, preuves … sont requises » obligeait à lire le code de la CLI).
recette_incomplete_detail() {
  local count field value droot
  count="$(recette_filter count <"$2")"
  [ "$count" = 1 ] || { printf 'section "## Lane acceptance" present %s times, exactly one expected\n' "$count"; return; }
  droot="$(repo_root "$(dirname "$2")" 2>/dev/null || true)"
  for field in Décision Date 'Révision essayée' Preuves 'Révision des documents'; do
    [ "$field" != 'Révision des documents' ] || [ -z "$droot" ] || ! same_path "$1" "$droot" || continue   # documents dans le projet : champ sans objet
    value="$(recette_field_check "$2" "$field")" && continue
    if [ -n "$value" ]; then printf '%s read as "%s" — expected: %s\n' "$(lang_en "$field")" "$value" "$(recette_expected "$field")"
    else printf '%s missing or duplicated — expected: %s\n' "$(lang_en "$field")" "$(recette_expected "$field")"; fi
    return
  done
  printf 'every field is readable; lab status %s gives the computed phase\n' "$P_NAME"
}

# lane_plan_names <wt> : les noms exacts des lots de ce seul couloir.
lane_plan_names() { lane_names_set "$1"; [ -z "$LANE_NAMES" ] || printf '%s\n' "$LANE_NAMES"; }
lane_names_set() { # <wt> : LANE_NAMES, un nom par ligne, et LANE_NAMES_N, leur nombre
  local rows
  docs_dir_set "$1"; wt_lane_set "$1"; plan_lots_set "$DOCS_DIR/treeplans/$WT_LANE.md"; rows="$PLAN_LOTS"
  LANE_NAMES=''; LANE_NAMES_N=0
  [ -n "$rows" ] || return 0
  rows="$rows"$'\n'
  while [ -n "$rows" ]; do
    LANE_NAMES="$LANE_NAMES${LANE_NAMES:+$'\n'}${rows%%$'\t'*}"; LANE_NAMES_N=$((LANE_NAMES_N + 1)); rows="${rows#*$'\n'}"
  done
}
# Refuser une liste partiellement lisible : une entrée ignorée ne vaut pas absence.
lane_plan_complete() { doc_need "$1" T || return 1; doc_fact COMPLETE; [ "$DOC_FACT" = 1 ]; } # <treeplan>
lane_last_lot() { lane_last_set "$@"; printf '%s\n' "$LANE_LAST"; } # <wt> [fiche] → yes | no | unknown
lane_last_set() { # les mêmes arguments : LANE_LAST
  ! lane_permanent "$1" || { LANE_LAST=no; return; }   # un couloir permanent n'a jamais de dernier lot, treeplan à jour ou non
  plan_last_set "$@"
}
# lane_plan_last <wt> [fiche] → yes | no | unknown, lu sur le seul treeplan : lab next y cherche la vraie cause d'un désaccord, même
# dans un couloir permanent (revue du lot 01 d'autonomie-tours)
lane_plan_last() { plan_last_set "$@"; printf '%s\n' "$LANE_LAST"; }
plan_last_set() { # les mêmes arguments : LANE_LAST
  local lot="${2:-}" docs tp name rest one count=0
  LANE_LAST=unknown
  [ -n "$lot" ] || { wt_lot_set "$1"; lot="$WT_LOT"; }
  [ -n "$lot" ] || return 0
  docs_dir_set "$1"; docs="$DOCS_DIR"; wt_lane_set "$1"; tp="$docs/treeplans/$WT_LANE.md"
  if [ ! -d "$docs/treeplans" ]; then
    reprise_next_set "$lot"
    case "$NEXT_SLUG" in none) LANE_LAST=yes ;; '') ;; *) LANE_LAST=no ;; esac
    return 0
  fi
  if [ ! -r "$tp" ] || ! lane_plan_complete "$tp"; then return 0; fi
  if lane_unplanned "$1" "$lot"; then return 0; fi
  name="${lot##*/}"; name="${name%.md}"
  lane_names_set "$1"; [ -n "$LANE_NAMES" ] || return 0
  rest="$LANE_NAMES"$'\n'
  while [ -n "$rest" ]; do one="${rest%%$'\n'*}"; rest="${rest#*$'\n'}"; [ "$one" != "$name" ] || count=$((count + 1)); done
  [ "$count" = 1 ] || return 0
  if [ "$one" = "$name" ]; then LANE_LAST=yes; else LANE_LAST=no; fi
}
lane_next_slug() { lane_next_set "$1" "$2"; printf '%s\n' "$LANE_NEXT"; } # <wt> <fiche> : entrée immédiatement suivante du treeplan, slug nu (vide si la fiche est la dernière)
lane_next_set() { # les mêmes arguments : LANE_NEXT
  local name="${2##*/}" rest one found=0
  LANE_NEXT=''; name="${name%.md}"
  lane_names_set "$1"; [ -n "$LANE_NAMES" ] || return 0
  rest="$LANE_NAMES"$'\n'
  while [ -n "$rest" ]; do
    one="${rest%%$'\n'*}"; rest="${rest#*$'\n'}"
    if [ "$found" = 1 ]; then lot_bare_set "$one"; LANE_NEXT="$LOT_BARE"; return 0; fi
    [ "$one" != "$name" ] || found=1
  done
}
# lane_next_values <wt> <fiche> : pose LANE_NEXT_REPRISE (slug annoncé par la Reprise, « aucun », ou vide) et LANE_NEXT_TREEPLAN
# (entrée suivante du treeplan), tous deux nus — lane_phase les compare, lab next les nomme quand ils divergent.
lane_next_values() {
  reprise_next_set "$2"; LANE_NEXT_REPRISE="$NEXT_SLUG"
  lane_next_set "$1" "$2"; LANE_NEXT_TREEPLAN="$LANE_NEXT"
}
lane_lots_closed() { # <wt> <fiche courante> : toutes les fiches prévues existent et sont closes
  local docs lane name file rest seen=$'\n'
  docs_dir_set "$1"; docs="$DOCS_DIR"; wt_lane_set "$1"; lane="$WT_LANE"
  [ -d "$docs/treeplans" ] || { lot_state_set "$2"; case "$LOT_STATE" in closed*) return 0 ;; *) return 1 ;; esac; }
  lane_plan_complete "$docs/treeplans/$lane.md" || return 1
  lane_names_set "$1"; [ -n "$LANE_NAMES" ] || return 1
  rest="$LANE_NAMES"$'\n'
  while [ -n "$rest" ]; do   # un nom en double ne vaut aucune des deux entrées
    name="${rest%%$'\n'*}"; rest="${rest#*$'\n'}"
    case "$seen" in *$'\n'"$name"$'\n'*) return 1 ;; esac
    seen="$seen$name"$'\n'
  done
  rest="$LANE_NAMES"$'\n'
  while [ -n "$rest" ]; do
    name="${rest%%$'\n'*}"; rest="${rest#*$'\n'}"
    [[ "$name" =~ ^lot-[0-9]+-[a-z0-9][a-z0-9._-]*$ ]] || return 1
    file="$docs/lots/$lane/$name.md"
    [ -f "$file" ] || file="$docs/lots/$name.md"
    lot_state_set "$file"; case "$LOT_STATE" in clos*) ;; *) return 1 ;; esac
  done
}

# recette_lane_changes <wt> <révision essayée> <fichiers changés> → ceux qui appartiennent au couloir (lot 17) : un merge de la base
# qui n'apporte que des fichiers que le couloir ne modifie pas laisse la recette valable. Fichiers du couloir : ceux où il diffère
# encore de la base (lane_files), plus tout fichier touché par un commit propre (hors merge) d'une de ses branches de lot depuis sa
# création — un lot déjà livré par squash, un retour à la version de la base ou une résolution qui efface un changement du couloir
# restent comptés (revue du lot 17). Base distante inconnue : la liste reste entière, comme avant.
recette_lane_changes() {
  local mine
  [ -n "$3" ] || return 0
  mine="$(lane_touched_files "$1" "${SLUG:-}")" || { printf '%s\n' "$3"; return 0; }
  comm -12 <(printf '%s\n' "$3" | sed '/^$/d' | sort -u) <(printf '%s\n' "$mine")
}
# lane_touched_files <wt> [couloir] → les fichiers du couloir (définition de recette_lane_changes), un par ligne ; rc 1 si la base
# distante est inconnue (l'appelant choisit son repli). Partagée avec la recette sur preuve : l'interface touchée se lit dessus (lot 07
# d'autonomie-tours), un lot intermédiaire déjà livré par squash compris.
# shellcheck disable=SC2034 # WT et SLUG locaux sont lus par close_lane_branches
lane_touched_files() {
  local wt="$1" ref b start cur WT="$1" SLUG="${2:-}"
  ref="$(sync_ref 2>/dev/null || true)"
  if [ -z "${P_REMOTE:-}" ] || [ -z "$ref" ] || ! git -C "$wt" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1; then
    return 1
  fi
  [ -n "$SLUG" ] || SLUG="$(wt_lane "$wt")"
  { lane_files "$wt"
    cur="$(branch_name "$wt")"
    declare -F close_lane_branches >/dev/null || . "${BASH_SOURCE[0]%/*}/close.sh"   # démarrage de session : chargée ici seulement
    close_lane_branches 2>/dev/null | while IFS= read -r b; do
      start="$(branch_start "$wt" "$b" "")"
      git -C "$wt" merge-base --is-ancestor "$start" "$b" 2>/dev/null || start=""
      if [ "$b" = "$cur" ] || [ -z "$start" ]; then   # lot courant : ses commits absents de la base (merges de la base exclus)
        git -C "$wt" -c core.quotePath=false log --no-merges --format= --name-only "${start:+$start..}$b" --not "$ref" 2>/dev/null || true
      else                                             # lot déjà livré : la chaîne des premiers parents, livré par squash ou par merge
        git -C "$wt" -c core.quotePath=false log --no-merges --first-parent --format= --name-only "$start..$b" 2>/dev/null || true
      fi
    done
  } | sed '/^$/d' | sort -u
}
# recette_stale_files <wt> <fiche> → « a, b » : fichiers du couloir changés depuis la révision essayée (hors la fiche elle-même), pour
# nommer une recette périmée (lot 17) ; vide si rien de lisible
recette_stale_files() {
  local wt="$1" lot="$2" revision droot rel
  revision="$(recette_revision_of "$(recette_field "$lot" 'Révision essayée')")"
  [ -n "$revision" ] && git -C "$wt" cat-file -e "$revision^{commit}" 2>/dev/null || return 0
  droot="$(repo_root "$(dirname "$lot")" 2>/dev/null || true)"; rel=""
  if [ -n "$droot" ] && same_path "$wt" "$droot"; then rel="$(real_path "$(dirname "$lot")")/$(basename "$lot")"; rel="${rel#"$(real_path "$droot")"/}"; fi
  recette_lane_changes "$wt" "$revision" "$(git -C "$wt" -c core.quotePath=false diff --name-only "$revision" HEAD 2>/dev/null || true)" \
    | awk -v r="$rel" 'NF && $0 != r' | sync_join
}
# recette_early_set <fiche lisible> : RECETTE_EARLY, la réponse que la fiche seule suffit à donner (absent | incomplete | rejected), vide
# quand elle est remplie : git dit alors si elle vaut encore. Un awk au plus, aucun si les faits de la fiche sont déjà lus
recette_early_set() {
  local field
  RECETTE_EARLY=absent
  doc_need "$1" F || return 0
  doc_fact RECETTES
  [ "$DOC_FACT" != 0 ] || return 0
  RECETTE_EARLY=incomplete
  [ "$DOC_FACT" = 1 ] || return 0
  recette_fact_set "$1" Décision; lang_code_set "$RECETTE_FACT"
  [ "$LANG_CODE" != rejected ] || { RECETTE_EARLY=rejected; return 0; }
  for field in Décision Date 'Révision essayée' Preuves; do
    recette_fact_set "$1" "$field"; recette_value_ok "$RECETTE_FACT" "$field" || return 0
  done
  RECETTE_EARLY=''
}
# recette_status <wt> <fiche> : résultat stable, toujours rc=0, aucun fichier créé (hors état gardé ci-dessous).
# La validation est un document Git lié à une révision du résultat ; un nouveau
# commit n’est admis que s’il modifie la seule section de recette de cette fiche.
# RECETTE_CACHE_DIR, posé par le seul écrivain de l'instantané de Treelab.app (lot 03 d'app-treelab) : le résultat est gardé par couloir
# et repris tant que sa clé tient — réglages du projet, couloir lu (SLUG), branche de HEAD, fiche, références git du couloir (show-ref
# --head : HEAD, branches, base distante) ; fiches dans leur propre dépôt (docs=local) : le contenu des chemins du couloir à HEAD de ce
# dépôt (ls-tree), jamais sa révision entière, qu'un commit d'un autre couloir ou projet bougerait —, seulement arbre propre et chemins du
# couloir propres ; sinon recalculé. Hors clé : le reflog (départ d'une branche, branch_start), qui ne bouge qu'à son expiration, et une
# réécriture de l'historique du dépôt des fiches. Un crochet d'un couloir en recette coûtait une trentaine de git, 0,9 s de processeur
# par réécriture (relevé d'une heure, C6).
recette_status() {
  [ -n "${RECETTE_CACHE_DIR:-}" ] || { recette_status_fresh "$@"; return; }
  local wt="$1" lot="$2" f droot refs st p key='' was='' cfg='' doc='' docs=''; local -a paths=()
  if [ -L "$lot" ] || [ ! -r "$lot" ] || ! is_clean "$wt"; then recette_status_fresh "$@"; return; fi
  droot="$(repo_root "${lot%/*}")" || droot=''
  [ -n "$droot" ] || { recette_status_fresh "$@"; return; }
  refs="$(git -C "$wt" show-ref --head 2>/dev/null)" || { recette_status_fresh "$@"; return; }
  if ! same_path "$droot" "$wt"; then
    while IFS= read -r p; do [ -z "$p" ] || paths+=("$p"); done < <(lane_doc_paths "$wt")
    [ "${#paths[@]}" -gt 0 ] || { recette_status_fresh "$@"; return; }
    if [ -n "$(git -C "$droot" status --porcelain --untracked-files=all -- "${paths[@]}" 2>/dev/null)" ]; then
      recette_status_fresh "$@"; return
    fi
    docs="$(git -C "$droot" ls-tree -r HEAD -- "${paths[@]}" 2>/dev/null)" || { recette_status_fresh "$@"; return; }
  fi
  head_branch_set "$wt"
  { IFS= read -r -d '' cfg <"$LAB_PROJECTS/$P_NAME/config"; } 2>/dev/null || true
  { IFS= read -r -d '' doc <"$lot"; } 2>/dev/null || true
  key="v1"$'\n'"${SLUG:-}"$'\n'"$HEAD_BRANCH"$'\n'"$cfg"$'\n'"$doc"$'\n'"$refs"$'\n'"$docs"
  f="$RECETTE_CACHE_DIR/$P_NAME/${wt##*/}"
  { IFS= read -r -d '' was <"$f"; } 2>/dev/null || true
  if [ -n "$was" ] && [ "${was#*$'\n'}" = "$key" ]; then printf '%s\n' "${was%%$'\n'*}"; return; fi
  st="$(recette_status_fresh "$wt" "$lot")"
  { mkdir -p "${f%/*}" && printf '%s\n%s' "$st" "$key" >"$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"; } 2>/dev/null || rm -f "$f.tmp.$$"
  printf '%s\n' "$st"
}
recette_status_fresh() {
  local wt="$1" lot="$2" field revision droot rel changes before after docs_revision
  [ -r "$lot" ] || { printf 'absent\n'; return; }
  recette_early_set "$lot"; [ -z "$RECETTE_EARLY" ] || { printf '%s\n' "$RECETTE_EARLY"; return; }
  recette_fact_set "$lot" 'Révision essayée'; revision="$(recette_revision_of "$RECETTE_FACT")"
  lot="$(real_path "$(dirname "$lot")")/$(basename "$lot")"
  droot="$(repo_root "$(dirname "$lot")" 2>/dev/null || true)"
  [ -n "$droot" ] || { printf 'unversioned\n'; return; }
  droot="$(real_path "$droot")"; rel="${lot#"$droot"/}"
  if [ -L "$lot" ] || ! git -C "$droot" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 \
    || ! git -C "$droot" diff --quiet HEAD -- "$rel"; then printf 'unversioned\n'; return; fi
  if ! git -C "$wt" cat-file -e "$revision^{commit}" 2>/dev/null \
    || ! git -C "$wt" merge-base --is-ancestor "$revision" HEAD 2>/dev/null \
    || ! is_clean "$wt"; then printf 'expired\n'; return; fi
  changes="$(git -C "$wt" -c core.quotePath=false diff --name-only "$revision" HEAD)"
  changes="$(recette_lane_changes "$wt" "$revision" "$changes")"
  if ! same_path "$wt" "$droot"; then
    # Deux dépôts, deux révisions essayées, dans la même et seule recette.
    # Un HEAD projet inchangé ne prouve pas que les documents sont inchangés.
    [ -z "$changes" ] || recette_kept_by_words "$wt" "$2" "$revision" || { printf 'expired\n'; return; }
    recette_fact_set "$2" 'Révision des documents'; docs_revision="$(recette_revision_of "$RECETTE_FACT")"
    [ -n "$docs_revision" ] || { printf 'incomplete\n'; return; }
    # Seuls les chemins du couloir comptent : un fichier sale ou un commit d'un autre couloir ou d'un autre projet dans le même
    # dépôt de fiches ne périme rien (lot 03). Sans chemins connus, tout le dépôt est regardé, comme avant.
    local -a paths=(); local path
    while IFS= read -r path; do [ -n "$path" ] && paths+=("$path"); done < <(lane_doc_paths "$wt")
    if [ -n "$(git -C "$droot" status --porcelain --untracked-files=all -- "${paths[@]+"${paths[@]}"}")" ] \
      || ! git -C "$droot" cat-file -e "$docs_revision^{commit}" 2>/dev/null \
      || ! git -C "$droot" merge-base --is-ancestor "$docs_revision" HEAD 2>/dev/null; then printf 'expired\n'; return; fi
    wt="$droot"; revision="$docs_revision"
    changes="$(git -C "$wt" -c core.quotePath=false diff --name-only "$revision" HEAD -- "${paths[@]+"${paths[@]}"}")"
  fi
  if [ -z "$changes" ]; then printf 'valid\n'; return; fi
  # lot 04 d'onglet-tower : le oui de fermer de l'utilisateur survit aux commits qui suivent (synchro, correctif de CI), arbre propre et
  # révision essayée dans l'historique (vérifiés plus haut) ; la CI verte de la PR décide de la livraison, lab close nomme ces commits
  if same_path "$wt" "$droot" && recette_kept_by_words "$wt" "$2" "$revision"; then printf 'valid\n'; return; fi
  if [ "$changes" != "$rel" ]; then printf 'expired\n'; return; fi
  # Le document doit déjà exister à la révision essayée ; seule sa section de
  # recette est ajoutée ensuite. Une exemption sur tout docs/ serait trop large.
  git -C "$wt" cat-file -e "$revision:$rel" 2>/dev/null || { printf 'expired\n'; return; }
  before="$(git -C "$wt" show "$revision:$rel" | recette_filter strip)"
  after="$(git -C "$wt" show "HEAD:$rel" | recette_filter strip)"
  if [ "$before" = "$after" ]; then printf 'valid\n'; else printf 'expired\n'; fi
}

# lane_phase <wt> [fiche état] → work | in acceptance | acceptance passed | to clarify | permanent | waiting ; expose
# LANE_NEXT_REPRISE et LANE_NEXT_TREEPLAN
lane_phase() { lane_phase_set "$@"; printf '%s\n' "$LANE_PHASE"; }
lane_phase_set() { # les mêmes arguments : LANE_PHASE. Un awk au plus par couloir au travail, aucun si ses documents sont déjà lus
  facts_begin; phase_set "$@"; facts_end
}
phase_set() {
  local lot state last docs list=''
  if [ "$#" -ge 3 ]; then lot="$2"; state="$3"   # fiche déjà lue (lab sweep)
  else
    wt_lot_set "$1"; lot="$WT_LOT"; docs_dir_set "$1"; wt_lane_set "$1"
    # la fiche et le treeplan, seuls documents d'un couloir au travail ou qui enchaîne, en une lecture
    if [ -f "$lot" ] && [ -r "$lot" ] && ! doc_find "$lot"; then list="F"$'\t'"$lot"; fi
    docs="$DOCS_DIR/treeplans/$WT_LANE.md"
    if [ -f "$docs" ] && [ -r "$docs" ] && ! doc_find "$docs" T; then list="$list${list:+$'\n'}T"$'\t'"$docs"; fi
    facts_load "$list"
    lot_state_set "$lot"; state="$LOT_STATE"
  fi
  case "$state" in
    planned*|'in progress'*) LANE_PHASE=work; return ;;
    closed*|waiting*) ;;   # en attente : livré comme un lot clos (lot 02 d'autonomie-tours)
    *) LANE_PHASE='to clarify'; return ;;
  esac
  lane_next_values "$1" "$lot"; lane_last_set "$1" "$lot"; last="$LANE_LAST"; docs_dir_set "$1"; docs="$DOCS_DIR"
  if [ "$LANE_NEXT_REPRISE" != none ]; then
    if [ -n "$LANE_NEXT_REPRISE" ] && { [ ! -d "$docs/treeplans" ] \
      || { [ "$last" = no ] && [ "$LANE_NEXT_REPRISE" = "$LANE_NEXT_TREEPLAN" ]; }; }; then LANE_PHASE=work
    else LANE_PHASE='to clarify'; fi
    return
  fi
  # couloir permanent sans lot restant : ni recette ni fermeture, lab next y ouvre la session libre (lot 01 d'autonomie-tours)
  if lane_permanent "$1"; then LANE_PHASE=permanent; return; fi
  # dernier lot fini, une mesure du couloir attend sa date : ni recette ni fermeture avant elle (lot 02 d'autonomie-tours)
  if [ "$last" = yes ]; then wait_first_set "$1"; if [ -n "$WAIT_FIRST" ]; then LANE_PHASE=waiting; return; fi; fi
  if [ "$last" != yes ] || ! lane_lots_closed "$1" "$lot"; then LANE_PHASE='to clarify'; return; fi
  # mesure partie de la base, retour prévu (lot 01 de fix-mesure-dernier-lot) : la recette attend le retour sur la branche du dernier lot
  measure_return_set "$1"; if [ -n "$MEASURE_RETURN" ]; then LANE_PHASE=work; return; fi
  LANE_PHASE='in acceptance'
  [ -r "$lot" ] || return 0
  recette_early_set "$lot"; [ -z "$RECETTE_EARLY" ] || return 0
  [ "$(recette_status "$1" "$lot")" != valid ] || LANE_PHASE='acceptance passed'
}

# lane_unplanned <wt> [fiche] : couloir neuf pas encore planifié (lot 18) — treeplan sans intention, un seul lot, aucune Reprise dans
# la fiche. Ce seul lot n'est pas « le dernier prévu » : personne n'a encore fixé la suite (le grill-me et batch-plan la fixeront).
lane_unplanned() {
  local lot="${2:-}" tp n=0 rest one
  [ -n "$lot" ] || { wt_lot_set "$1"; lot="$WT_LOT"; }
  docs_dir_set "$1"; wt_lane_set "$1"; tp="$DOCS_DIR/treeplans/$WT_LANE.md"
  [ -r "$tp" ] || return 1
  plan_intent_set "$tp"; [ -z "$PLAN_INTENT" ] || return 1
  lane_names_set "$1"; [ "$LANE_NAMES_N" = 1 ] || return 1
  doc_need "$lot" F || return 0
  doc_fact REPRISE; [ "$DOC_FACT" = 0 ]
}
last_lot_notice() { lot_notice_set "$@"; printf '%s' "$LOT_NOTICE"; } # <wt> [fiche] : indication dérivée, avant et après planification
lot_notice_set() { # les mêmes arguments : LOT_NOTICE
  LOT_NOTICE=''
  lane_last_set "$1" "${2:-}"
  case "$LANE_LAST" in
    yes) LOT_NOTICE='Last planned batch — a check together will follow.' ;;
    unknown) if lane_unplanned "$1" "${2:-}"; then LOT_NOTICE='Next batches: unknown — planning will set them.'; fi ;;
  esac
}

# ---------- lab recette (lot 01 de livrer-sans-friction) : écrire et versionner la recette en un seul geste ----------
# recette_write <fiche> <section> : remplace en place la seule section « ## Recette du couloir » (hors blocs de code), ou l'ajoute à
# la fin ; tout le reste de la fiche est recopié à l'identique, si bien que recette_status la juge sur sa seule section.
# La section s'appelle « ## Lane acceptance » dans une fiche anglaise : les deux titres sont reconnus.
recette_write() {
  local tmp; tmp="$(mktemp "$1.XXXXXX")"
  SECTION="$2" awk -v re="^## ($(lang_section_re 'Recette du couloir'))[[:space:]]*$" '
    /^[[:space:]]*(```|~~~)/ {fence=!fence; if (!skip) print; next}
    !fence && $0 ~ re {printf "%s\n", ENVIRON["SECTION"]; skip=1; done=1; next}
    !fence && skip && /^## / {skip=0; print ""}
    !skip {print}
    END {if (!done) printf "\n%s\n", ENVIRON["SECTION"]}' "$1" >"$tmp" && mv "$tmp" "$1"
}
# ---------- recette sur preuve (lot 07 d'autonomie-tours) ----------
# Preuves typées : « check: » (lab lance acceptance_check= de la config du projet, hors dépôt : l'agent du couloir ne peut pas
# l'affaiblir) et « screens:<lot> » (captures rangées par lab proof, empreintes revérifiées). Dans un projet doté d'une tour, la tour
# accepte sur check:, plus screens: quand le couloir touche l'interface ; l'agent du couloir n'accepte jamais ; l'utilisateur dans son
# terminal et un projet sans tour gardent le texte libre.
# acceptance_interface_spec : un AGENTS.md sur stdin → les dossiers de sa ligne « Interface : » (entre accents graves, avant le point
# médian), un par ligne ; « unknown » si la ligne est encore en commentaire (gabarit) ; rien sans ligne (règle du gabarit)
acceptance_interface_spec() {
  local line
  line="$(LC_ALL=C grep -E '^[[:space:]]*(-[[:space:]]*)?(<!--[[:space:]]*)?Interface[[:space:]]*:' | head -1)"
  [ -n "$line" ] || return 0
  case "$line" in *'<!--'*) echo unknown; return 0 ;; esac
  # shellcheck disable=SC2016 # accents graves littéraux : les dossiers de la ligne Interface
  printf '%s\n' "$line" | LC_ALL=C sed 's/·.*//' | LC_ALL=C grep -o '`[^`]*`' | tr -d '`'
}
# acceptance_interface_touched <wt> [couloir] → dossiers de l'interface que le couloir touche, « a, b » ; « unknown » si une ligne
# Interface lue est encore en commentaire ; vide si aucun. La ligne de la base compte avec celle du couloir (revue du lot 07) :
# l'agent du couloir écrit son AGENTS.md, il ne peut pas retirer seul un dossier de l'interface.
acceptance_interface_touched() {
  local wt="$1" spec ref files d out=""
  ref="$(sync_ref 2>/dev/null || true)"
  spec="$( { [ ! -f "$wt/AGENTS.md" ] || acceptance_interface_spec <"$wt/AGENTS.md"
             [ -z "$ref" ] || git -C "$wt" show "$ref:AGENTS.md" 2>/dev/null | acceptance_interface_spec; } | sed '/^$/d' | sort -u)"
  [ -n "$spec" ] || return 0
  if grep -qx unknown <<<"$spec"; then echo unknown; return 0; fi
  files="$(lane_touched_files "$wt" "${2:-}")" || files="$(lane_files "$wt")"
  while IFS= read -r d; do
    if printf '%s\n' "$files" | awk -v d="$d" 'BEGIN {p = d; sub(/\/$/, "", p)} $0 == p || index($0, p "/") == 1 {f = 1} END {exit !f}'; then
      out="${out:+$out, }$d"
    fi
  done <<<"$spec"
  printf '%s' "$out"
}
# acceptance_screens <lot demandé, vide = lot courant> : captures du couloir revérifiées par proof_verify (même logique, aucun
# double) ; pose AS_NAME (lot-NN-slug) et AS_SUMMARY, sinon refus nommé, rien écrit
acceptance_screens() {
  local want="$1" out err rc=0 bad lane name n
  [ -n "$want" ] || want="$(basename "$(wt_lot_file "$WT")" .md)"
  err="$(mktemp)"
  out="$(proof_verify "$want" 2>"$err")" || rc=$?
  name="$(printf '%s\n' "$out" | sed -n 's/^PROOF_BATCH=//p' | tail -1)"; lane="$(printf '%s\n' "$out" | sed -n 's/^PROOF_LANE=//p' | tail -1)"
  if [ "$rc" != 0 ] && [ -z "$name" ]; then
    out="$(sed -n "s/^$DIE_PREFIX//p" "$err" | tail -1)"; rm -f "$err"
    die "screens:$1 — ${out:-unreadable evidence}; nothing written"
  fi
  rm -f "$err"
  [ "$lane" = "$SLUG" ] || die "screens:$1 names $lane/$name, not a batch of lane $SLUG: nothing written"
  bad="$(printf '%s\n' "$out" | awk -F= '$1 == "PROOF_FILE" {f = substr($0, 12)} $1 == "PROOF_STATUS" && $2 != "ok" {printf "%s%s (%s)", (n++ ? ", " : ""), f, $2}')"
  [ -z "$bad" ] || die "screens:$name — fingerprint check failed: $bad; file the screens again with lab proof $P_NAME $name add --step <new step> — nothing written"
  n="$(printf '%s\n' "$out" | sed -n 's/^PROOF_OK=//p' | tail -1)"
  [ "${n:-0}" -gt 0 ] || die "screens:$name — no screen recorded: lab proof $P_NAME $name add <files…> — nothing written"
  AS_NAME="$name"; AS_SUMMARY="screens: $name ($n file$([ "$n" = 1 ] || echo s), fingerprints verified)"
}
# acceptance_check_run <rôle> : lance acceptance_check= dans le couloir, sur sa révision et son arbre propre, sous délai
# (LAB_ACCEPTANCE_TIMEOUT, 1800 s) ; sortie dans $LAB_STATE/<projet>/acceptance/. Pose AC_SUMMARY. Rouge : refus avec rc et fin de
# sortie, rien écrit ; lancé par la tour, le couloir est bloqué (waits-for) et l'utilisateur prévenu. Arbre ou révision changés : refus.
acceptance_check_run() {
  local role="$1" cfg cmd log rc=0 start secs head last why limit="${LAB_ACCEPTANCE_TIMEOUT:-1800}"
  cfg="$(project_dir "$P_NAME")/config"; cmd="$(config_get "$P_NAME" acceptance_check 2>/dev/null || true)"
  [ -n "$cmd" ] || die "check: needs acceptance_check=<command> in the config of $P_NAME ($cfg), written by hand like recette= (lab-cli skill): nothing written"
  log="$LAB_STATE/$P_NAME/acceptance/$SLUG-$(date -u +%Y%m%dT%H%M%SZ).log"; mkdir -p "$(dirname "$log")"
  head="$(git -C "$WT" rev-parse HEAD)"; start=$SECONDS
  (cd "$WT" && with_timeout "$limit" bash -c "$cmd") </dev/null >"$log" 2>&1 || rc=$?
  secs=$((SECONDS - start))
  kv CHECK_RC "$rc"; kv CHECK_LOG "$log"
  if [ "$rc" != 0 ]; then
    last="$(tail -n 3 "$log" | tr '\n\r\t' '   ' | tr -s ' ' | sed 's/^ //; s/ $//' | cut -c1-160)"
    if [ "$rc" = 124 ]; then why="acceptance check failed: timed out after $limit s"; else why="acceptance check failed: rc $rc"; fi
    # entrée de la tour : la cause d'abord (rc, dernière sortie), la commande et le journal suivent dans le refus et dans CHECK_LOG
    [ "$role" != tower ] || tower_signal "$WT" blocked "$why — ${last:-no output}"
    die "$why ($cmd) — last lines: ${last:-none} — log: $log; nothing written, the acceptance stays open"
  fi
  if [ "$(git -C "$WT" rev-parse HEAD)" != "$head" ] || ! is_clean "$WT"; then
    dirty_report "$WT" || true
    die "the acceptance check changed the lane (${DIRTY_LIST:-new commit}): the tried revision must stay the repository's — make acceptance_check= write outside the lane, clean it, then retry; nothing written"
  fi
  AC_SUMMARY="check: $cmd rc 0 ($secs s)"
}
# acceptance_waits_why <wt> <couloir> : ce que la tour fait d'un couloir en recette — pose TW_EVIDENCE (check | check screens) et TW_WHY
# shellcheck disable=SC2034 # TW_EVIDENCE et TW_WHY sont lus par tower_view (lib/tower.sh)
acceptance_waits_why() {
  local touched lot
  if [ -z "$(config_get "$P_NAME" acceptance_check 2>/dev/null || true)" ]; then   # revue : sans check, la tour ne peut pas accepter
    TW_EVIDENCE=""
    TW_WHY="work finished, to try together: lab next $P_NAME $2 — no acceptance_check= in the config of $P_NAME, the tower cannot accept it"
    return 0
  fi
  touched="$(acceptance_interface_touched "$1" "$2")"; lot="$(basename "$(wt_lot_file "$1")" .md)"
  if [ -z "$touched" ]; then
    TW_EVIDENCE=check
    TW_WHY="work finished outside the interface: the tower accepts it with lab acceptance $P_NAME $2 --accept --evidence check:"
  else
    TW_EVIDENCE='check screens'
    [ "$touched" != unknown ] || touched='Interface line still a comment'
    TW_WHY="work finished, interface touched ($touched): show the screens to the user; on their yes, lab acceptance $P_NAME $2 --accept --evidence check: --evidence screens:$lot"
  fi
}

# ---------- accord gardé par lab (lot 09 d'autonomie-tours) ----------
# La fiche appartient au couloir, dont l'agent peut l'écrire : l'accord qui autorise la tour à fermer seule vit hors du couloir,
# dans $LAB_STATE/<projet>/agreements/<couloir> (dossier et fichier en 700/600), écrit par lab acceptance après le commit de sa
# section — decision=, rev= (révision essayée), docs_rev= (documents externes, vide sinon), role= (user | tower | lane-agent),
# batch= (lot-NN-slug de la fiche ; clé anglaise, règle du code livré), at= ; lot 10 : via=words, close=yes et said= quand l'accord
# vient des mots de l'utilisateur lus par le crochet de lab (lib/words.sh), qui valent aussi l'ordre de fermer. --reject le remplace, lab close l'efface après le retrait ; la garde refuse Write, Edit et
# apply_patch sous $LAB_STATE (lib/hooks.sh). La ligne Validated by de la fiche n'est plus qu'une trace.
agreement_file() { printf '%s/%s/agreements/%s\n' "$LAB_STATE" "$P_NAME" "$1"; }   # <couloir>
# agreement_get <fichier> <champ> : la première valeur, sans processus (kv_print) — huit lectures par couloir réécrit dans l'instantané
# de Treelab.app (lot 03 d'app-treelab)
agreement_get() { [ -f "$1" ] || return 0; kv_print "$1" "$2" || true; }
# agreement_write <couloir> <décision> <révision> <révision des documents> <rôle> <lot> [via] [close] [mots] : réécriture atomique
agreement_write() {
  local f; f="$(agreement_file "$1")"
  ( umask 077; mkdir -p "$(dirname "$f")" && rm -f "$f.tmp.$$" \
    && { printf 'decision=%s\nrev=%s\ndocs_rev=%s\nrole=%s\nbatch=%s\nat=%s\n' "$2" "$3" "$4" "$5" "$6" "$(rdv_now)"
         [ -z "${7:-}" ] || printf 'via=%s\nclose=%s\nsaid=%s\n' "$7" "${8:-no}" "${9:-}"; } >"$f.tmp.$$" \
    && mv "$f.tmp.$$" "$f" ) || return
  snap_mark_lane "$P_NAME" "$1"
}
agreement_clear() { local f; f="$(agreement_file "$1")"; [ -e "$f" ] || [ -L "$f" ] || return 0; rm -f "$f"; snap_mark_lane "$P_NAME" "$1"; }
# agreement_hold <couloir> (lot 04 d'onglet-tower, revue) : l'ordre de fermer donné par les mots est retiré (close=no), l'accord du
# résultat reste — une négation dite après lab acceptance ; rc 1 sans ordre de fermer à retirer. Ses mots, redits, le rendent
agreement_hold() {
  local f; f="$(agreement_file "$1")"
  [ -f "$f" ] && [ ! -L "$f" ] && [ "$(agreement_get "$f" close)" = yes ] || return 1
  agreement_write "$1" "$(agreement_get "$f" decision)" "$(agreement_get "$f" rev)" "$(agreement_get "$f" docs_rev)" \
    "$(agreement_get "$f" role)" "$(agreement_get "$f" batch)" "$(agreement_get "$f" via)" no "$(agreement_get "$f" said)"
}
# agreement_valid <wt> : rc 0 si l'accord au registre vaut pour la recette de la fiche — accepted, rôle user ou tower, même lot,
# même révision essayée, même révision des documents ; sinon rc 1 et AG_WHY nomme le manque (lu par la tour et lab close)
# shellcheck disable=SC2034 # AG_WHY est lu par tower_waits_for (lib/tower.sh) et close_alone_state (lib/close.sh)
agreement_valid() {
  local wt="$1" lane lot f v want
  AG_WHY=""; lane="$(wt_lane "$wt")"; lot="$(wt_lot_file "$wt")"
  # le nom vient de .lab/meta, que le couloir écrit : jamais un chemin hors du registre (revue du lot 09)
  valid_slug "$lane" || { AG_WHY="lane name unreadable in its .lab/meta, no agreement read"; return 1; }
  f="$(agreement_file "$lane")"
  if [ ! -f "$f" ] || [ -L "$f" ]; then AG_WHY="agreement not recorded by lab acceptance"; return 1; fi
  v="$(agreement_get "$f" decision)"
  [ "$v" = accepted ] || { AG_WHY="agreement recorded as ${v:-unreadable}, not accepted"; return 1; }
  v="$(agreement_get "$f" role)"
  case "$v" in user|tower) ;; *) AG_WHY="agreement recorded by the ${v:-unknown} role, neither the user nor the tower"; return 1 ;; esac
  v="$(agreement_get "$f" batch)"; want="$(basename "$lot" .md)"
  [ "$v" = "$want" ] || { AG_WHY="agreement recorded for ${v:-no batch}, not the tried batch $want"; return 1; }
  v="$(agreement_get "$f" rev)"; want="$(recette_revision_of "$(recette_field "$lot" 'Révision essayée')")"
  [ -n "$want" ] && [ "$v" = "$want" ] || { AG_WHY="agreement recorded for revision ${v:0:7}, not the tried revision ${want:0:7}"; return 1; }
  v="$(agreement_get "$f" docs_rev)"; want="$(recette_revision_of "$(recette_field "$lot" 'Révision des documents')")"
  [ "$v" = "$want" ] || { AG_WHY="agreement recorded for other documents (${v:0:7}), not the tried documents ${want:0:7}"; return 1; }
}

# recette_kept_by_words <wt> <fiche> <révision essayée> (lot 04 d'onglet-tower) : rc 0 si l'accord gardé par lab pour ce couloir vient
# des mots de l'utilisateur (decision=accepted, role=user, via=words, close=yes), pour ce lot et cette révision essayée — ce oui survit
# aux commits qui le suivent ; mêmes documents essayés (docs_rev), comme agreement_valid. Projet non chargé ou nom illisible : rc 1, la
# recette reste périmée comme avant. Choix d'Alex (2026-11-25) : ces commits sont livrés sans nouvel essai, CI verte de la PR, et
# nommés par lab close (AFTER_AGREEMENT=) et sa notification
recette_kept_by_words() {
  local lane f
  [ -n "${P_NAME:-}" ] || return 1
  lane="$(wt_lane "$1" 2>/dev/null)"; valid_slug "$lane" || return 1
  f="$(agreement_file "$lane")"; [ -f "$f" ] && [ ! -L "$f" ] || return 1
  [ "$(agreement_get "$f" decision)" = accepted ] && [ "$(agreement_get "$f" role)" = user ] \
    && [ "$(agreement_get "$f" via)" = words ] && [ "$(agreement_get "$f" close)" = yes ] \
    && [ "$(agreement_get "$f" batch)" = "$(basename "$2" .md)" ] && [ -n "$3" ] && [ "$(agreement_get "$f" rev)" = "$3" ] \
    && [ "$(agreement_get "$f" docs_rev)" = "$(recette_revision_of "$(recette_field "$2" 'Révision des documents')")" ]
}
# recette_after_agreement <wt> <révision essayée> [fiche] → « <sha7> <sujet>; …; +N sync(s) with the base » : ce qui a changé après le
# oui (lot 04 d'onglet-tower) — commits propres du couloir hors base, sauf ceux qui ne touchent que la fiche du lot (la recette et
# l'accord de nuit, écrits par lab), puis les synchros de la première lignée ; vide si rien, ou si la révision essayée n'est plus un
# ancêtre de la tête (la recette est alors périmée)
recette_after_agreement() {
  local wt="$1" rev="$2" lot="${3:-}" ref rel="" sha subj files list="" n; local -a not=()
  [ -n "$rev" ] && git -C "$wt" cat-file -e "$rev^{commit}" 2>/dev/null && git -C "$wt" merge-base --is-ancestor "$rev" HEAD 2>/dev/null \
    || return 0
  if [ -n "$lot" ] && [ -f "$lot" ]; then
    rel="$(real_path "$(dirname "$lot")")/$(basename "$lot")"; rel="${rel#"$(real_path "$wt")"/}"
  fi
  ref="$(sync_ref 2>/dev/null || true)"
  [ -z "$ref" ] || ! git -C "$wt" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 || not=(--not "$ref")
  while IFS=' ' read -r sha subj; do
    [ -n "$sha" ] || continue
    files="$(git -C "$wt" -c core.quotePath=false diff-tree --no-commit-id --name-only -r "$sha" 2>/dev/null)"
    [ -z "$rel" ] || [ "$files" != "$rel" ] || continue
    list="${list:+$list; }${sha:0:7} $subj"
  done < <(git -C "$wt" log --reverse --no-merges --format='%H %s' "$rev..HEAD" "${not[@]+"${not[@]}"}" 2>/dev/null)
  n="$(git -C "$wt" rev-list --merges --first-parent --count "$rev..HEAD" 2>/dev/null || echo 0)"
  case "$n" in ''|0|*[!0-9]*) ;; 1) list="${list:+$list; }+1 sync with the base" ;; *) list="${list:+$list; }+$n syncs with the base" ;; esac
  printf '%s' "$list"
}
# agreement_by_words <wt> : rc 0 si l'accord valide vient des mots de l'utilisateur (via=words close=yes, lot 10) — l'agent du couloir
# ou la tour ferment alors sans --confirm ; pose AG_SAID, les mots
# shellcheck disable=SC2034 # AG_SAID est lu par lib/close.sh et lib/tower.sh
agreement_by_words() {
  AG_SAID=""
  agreement_valid "$1" || return 1
  local f; f="$(agreement_file "$(wt_lane "$1")")"
  [ "$(agreement_get "$f" via)" = words ] && [ "$(agreement_get "$f" close)" = yes ] || return 1
  AG_SAID="$(agreement_get "$f" said)"
}

cmd_recette() {
  local decision="" retours="" lot count droot rel revision docs_revision="" proofs_line="" p path dirty status branch push=none nn lang
  local role tower=0 has_check=0 typed=0 touched="" validated="" words=0
  local -a pos=() proofs=() paths=() screens=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      # --accord, --refus, --preuve, --retours : alias français muets
      --accept|--reject|--accord|--refus) [ -z "$decision" ] || die "one decision only: --accept or --reject"
                        case "$1" in --accept|--accord) decision=accepted ;; *) decision=rejected ;; esac; shift ;;
      --evidence|--preuve) [ "$#" -ge 2 ] || usage; proofs+=("$2"); shift 2 ;;
      --feedback|--retours) [ "$#" -ge 2 ] || usage; retours="$2"; shift 2 ;;
      -*) usage ;; *) pos+=("$1"); shift ;;
    esac
  done
  [ "${#pos[@]}" -ge 1 ] && [ "${#pos[@]}" -le 2 ] || usage
  for p in "${proofs[@]+"${proofs[@]}"}" "$retours"; do   # une valeur par ligne de la fiche : un saut de ligne casserait la section
    case "$p" in *$'\n'*) die "--evidence and --feedback each fit on a single line: repeat --evidence for several paths" ;; esac
  done
  for p in "${proofs[@]+"${proofs[@]}"}"; do [ -n "${p//[[:space:]]/}" ] || die "empty evidence: describe the path tried and the agreement received"; done
  split_project_slug "${pos[@]}"; load_project "$PROJECT"
  valid_slug "$SLUG" || die "invalid lane name"
  require_wt
  [ -n "$decision" ] || die "decision required: --accept after the user's explicit agreement, or --reject"
  status="$(lane_phase "$WT")"
  case "$status" in
    'in acceptance'|'acceptance passed') ;;
    permanent) die "lane $SLUG is permanent (phase: permanent): never in acceptance — lab permanent $P_NAME $SLUG off first, if it must end" ;;
    waiting) wait_block "$WT" ;;
    *) die "lane $SLUG is not in acceptance (phase: $status): finish its batches, lab next $P_NAME $SLUG will open the acceptance" ;; esac
  # lot 07 d'autonomie-tours : le rôle est calculé par lab, jamais déclaré ; dans un projet doté d'une tour, l'agent du couloir n'accepte pas
  role="$(caller_role)"; ! deploy_tower_project || tower=1
  # lot 10 : les mots de l'utilisateur, lus par le crochet de lab dans l'onglet du couloir ou de la tour et liés à cette révision,
  # sont son accord — l'agent du couloir ou la tour acceptent alors, sans preuve typée ; sans eux, rien ne change
  if [ "$decision" = accepted ] && [ "$role" != human ] && words_valid "$WT"; then words=1; fi
  if [ "$decision" = accepted ] && [ "$tower" = 1 ] && [ "$role" = lane-agent ] && [ "$words" = 0 ]; then
    die "accepting belongs to the tower of $P_NAME or to the user's own words ($WD_WHY): never give them a command to type — ask once with AskUserQuestion, buttons \"Close $SLUG\" and \"Keep $SLUG\" in their language; lab reads the click (or their words, such as \"I accept\", in this tab), then run lab acceptance again — nothing written; --reject stays open to this lane$(tower_session_note)"
  fi
  is_clean "$WT" || { dirty_report "$WT" || true; die "uncommitted or untracked changes ($DIRTY_LIST): commit or remove them, then try again — the tried revision must be the repository's"; }
  [ "$decision" = rejected ] || [ "${#proofs[@]}" -gt 0 ] || [ "$words" = 1 ] || die "agreement without evidence: add --evidence <path tried, agreement received> (repeatable)"
  for p in "${proofs[@]+"${proofs[@]}"}"; do
    case "$p" in
      # preuves typées : « check: » nu, « screens: » suivi d'un nom de lot ou de rien ; tout autre texte reste libre (décision 5)
      check:) has_check=1; typed=$((typed + 1)) ;;
      screens:*) [[ "${p#screens:}" =~ ^([a-z0-9][a-z0-9._-]*)?$ ]] || continue
                 screens+=("${p#screens:}"); typed=$((typed + 1)) ;;
    esac
  done
  if [ "$decision" = accepted ]; then
    if [ "$tower" = 1 ] && [ "$role" = tower ] && [ "$words" = 0 ]; then
      [ "$typed" -gt 0 ] || die "typed evidence required (check:, screens:): the tower accepts with --evidence check: (lab runs acceptance_check=), plus screens:<batch> when the lane touches the interface — nothing written"
      [ "$has_check" = 1 ] || die "check: required: the tower accepts only after lab runs acceptance_check= (--evidence check:) — nothing written"
      touched="$(acceptance_interface_touched "$WT" "$SLUG")"
      if [ "${#screens[@]}" = 0 ]; then
        [ "$touched" != unknown ] || die "the Interface line of AGENTS.md is still a comment: interface unknown, screens:<batch> required in addition to check: — nothing written"
        [ -z "$touched" ] || die "the lane touches the interface ($touched): screens:<batch> required in addition to check: — screens filed by lab proof $P_NAME <batch> add, shown to the user; nothing written"
      fi
    fi
    nn="$(basename "$(wt_lot_file "$WT")" .md)"; p=""
    for path in "${screens[@]+"${screens[@]}"}"; do
      acceptance_screens "$path"; validated="${validated:+$validated ; }$AS_SUMMARY"; [ "$AS_NAME" != "$nn" ] || p=seen
    done
    # revue de sécurité : des captures exigées sont celles du lot essayé, jamais celles d'un lot plus ancien du couloir
    [ -z "$touched" ] || [ "$p" = seen ] || die "screens of the tried batch $nn required (screens:$nn): screens of an older batch do not show the tried result — nothing written"
    if [ "$has_check" = 1 ]; then acceptance_check_run "$role"; validated="${AC_SUMMARY}${validated:+ ; $validated}"; fi
    case "$role" in tower) p=tower ;; lane-agent) p='lane agent' ;; *) p=user ;; esac
    [ "$words" = 0 ] || { p="user — words \"$WD_SAID\""; proofs+=("$(words_evidence)"); }
    validated="$p${validated:+ — $validated}"
  fi
  lot="$(wt_lot_file "$WT")"; lot="$(real_path "$(dirname "$lot")")/$(basename "$lot")"
  count="$(recette_filter count <"$lot")"
  [ "$count" -le 1 ] || die "section \"## Lane acceptance\" present $count times in $lot: keep only one, then retry"
  droot="$(repo_root "$(dirname "$lot")" 2>/dev/null || true)"
  [ -n "$droot" ] || die "batch file $lot is outside any git repository: the acceptance cannot be versioned; version the batch files folder, then retry"
  droot="$(real_path "$droot")"; rel="${lot#"$droot"/}"
  revision="$(git -C "$WT" rev-parse HEAD)"
  # revue de sécurité : la révision écrite est celle des mots, lue une fois — un commit glissé entre leur lecture et ici refuse tout
  [ "$words" = 0 ] || [ "$revision" = "$WD_REV" ] || die "the lane moved after the user's words were read (${WD_REV:0:7} → ${revision:0:7}): nothing written — the user says them again"
  if ! same_path "$WT" "$droot"; then   # documents externes : leur révision aussi est celle essayée, fiches du couloir propres
    while IFS= read -r path; do [ -n "$path" ] && paths+=("$path"); done < <(lane_doc_paths "$WT")
    dirty="$(git -C "$droot" -c core.quotePath=false status --porcelain --untracked-files=all -- "${paths[@]+"${paths[@]}"}" | cut -c4- | sync_join)"
    [ -z "$dirty" ] || die "lane batch files not committed in $droot ($dirty): lab next $P_NAME $SLUG commits them when opening the acceptance; try again afterwards"
    docs_revision="$(git -C "$droot" rev-parse HEAD)"
  fi
  for p in "${proofs[@]+"${proofs[@]}"}"; do proofs_line="${proofs_line:+$proofs_line ; }$p"; done
  [ -n "$proofs_line" ] || proofs_line="$retours"
  lang="$(lang_doc_of "$lot")"   # la section suit la langue de la fiche, jamais l'inverse
  [ -n "$proofs_line" ] || proofs_line="$(if [ "$lang" = en ]; then echo 'explicit refusal by the user'; else echo "refus explicite de l’utilisateur"; fi)"
  recette_write "$lot" "$(
    printf '## %s\n\n**%s** : %s\n**Date** : %s\n**%s** : %s\n' "$(lang_word "$lang" 'Recette du couloir')" "$(lang_word "$lang" Décision)" "$(lang_value "$lang" "$decision")" "$(rdv_now | cut -c1-10)" "$(lang_word "$lang" 'Révision essayée')" "$revision"
    [ -z "$docs_revision" ] || printf '**%s** : %s\n' "$(lang_word "$lang" 'Révision des documents')" "$docs_revision"
    printf '**%s** : %s\n' "$(lang_word "$lang" Preuves)" "$proofs_line"
    [ -z "$validated" ] || printf '**%s** : %s\n' "$(lang_word "$lang" 'Validé par')" "$validated"
    printf '\n### %s\n\n' "$(if [ "$lang" = en ]; then echo 'Tried paths and feedback'; else echo 'Parcours essayés et retours'; fi)"
    for p in "${proofs[@]+"${proofs[@]}"}"; do printf -- '- %s\n' "$p"; done
    [ -z "$retours" ] || printf -- '- %s : %s\n' "$(if [ "$lang" = en ]; then echo Feedback; else echo Retours; fi)" "$retours")"
  nn="$(lot_number_of "$lot")"
  git_commit_paths "$droot" "docs(acceptance): $SLUG — acceptance $decision${nn:+ (lot-$nn)}" "$rel"
  [ "$COMMIT_RESULT" != failed ] || die "acceptance written but not committed — git: $COMMIT_REASON; fix it, then rerun lab acceptance $P_NAME $SLUG"
  status="$(recette_status "$WT" "$lot")"
  case "$decision:$status" in
    accepted:valid|rejected:rejected) ;;
    *) die "acceptance committed but read back as \"$status\": $(recette_incomplete_detail "$WT" "$lot")" ;;
  esac
  # lot 09 : l'accord gardé hors du couloir, lié à la révision essayée — seul il autorise la tour à fermer sans question
  case "$role" in tower|lane-agent) p="$role" ;; *) p=user ;; esac
  if [ "$words" = 1 ]; then   # lot 10 : l'accord est celui de l'utilisateur, par ses mots, qui valent l'ordre de fermer ; mots consommés
    agreement_write "$SLUG" "$decision" "$revision" "$docs_revision" user "$(basename "$lot" .md)" words yes "$WD_SAID" \
      || die "acceptance committed but its agreement not recorded in $(agreement_file "$SLUG"): fix the folder, then rerun lab acceptance $P_NAME $SLUG"
    words_clear "$SLUG"
  else
    agreement_write "$SLUG" "$decision" "$revision" "$docs_revision" "$p" "$(basename "$lot" .md)" \
      || die "acceptance committed but its agreement not recorded in $(agreement_file "$SLUG"): fix the folder, then rerun lab acceptance $P_NAME $SLUG"
  fi
  # la PR doit porter la révision qui contient la recette : la branche déjà publiée avance d'un commit, jamais forcée
  branch="$(branch_name "$WT")"
  if same_path "$WT" "$droot" && [ -n "$branch" ] && [ -n "${P_REMOTE:-}" ] \
    && git -C "$WT" ls-remote --exit-code "$P_REMOTE" "refs/heads/$branch" >/dev/null 2>&1; then
    if git -C "$WT" push -q "$P_REMOTE" "HEAD:refs/heads/$branch" 2>/dev/null; then push=ok
    else push=failed; warn "acceptance committed but not pushed to $P_REMOTE/$branch: push the branch before lab close"; fi
  fi
  # la recette est écrite : l'annonce « recette prête » et un check rouge passé ne bloquent plus le couloir
  case "$(waits_get "$WT" kind):$(waits_get "$WT" why)" in acceptance:*|"blocked:acceptance check"*) waits_clear "$WT" ;; esac
  [ -z "$validated" ] || kv VALIDATED_BY "$validated"
  kv ACCEPTANCE "$status"; kv REVISION "$revision"; [ -z "$docs_revision" ] || kv DOCS_REVISION "$docs_revision"
  kv COMMIT "$COMMIT_RESULT"; kv PUSH "$push"
  if [ "$words" = 1 ]; then log "acceptance accepted on the user's words, committed in $rel; their words are also the order: lab close $P_NAME $SLUG now, without --confirm"
  else log "acceptance $(lang_en "$decision") committed in $rel; lab close $P_NAME $SLUG --dry-run lists what would remain before closing"; fi
}

# recette=production (clé écrite à la main dans la config du projet, lot 02 de close-apres-fusion) : la production est la CI qui
# déploie la base, aucune cible deploy. ne sert le couloir avant fusion — le résultat ne s'essaie qu'après la fusion de la PR.
# Après load_project (deploy_targets lit P_NAME) ; toute autre valeur, ou une cible déclarée, garde le silence.
recette_production() {
  [ "$(config_get "$P_NAME" recette 2>/dev/null || true)" = production ] && [ "$(deploy_targets)" = none ]
}
# recette_production_note : texte unique, une ligne de moins de 80 colonnes par étape — lab next les journalise une à une, le
# prompt de la session de recette les recolle en une phrase. La branche nommée est celle que vise la PR (pr_base : staging si elle
# existe, sinon la base), jamais « main » en dur (revue du lot 02)
recette_production_note() {
  printf '%s\n' 'Acceptance in production (recette=production, no deploy. target):' \
    '1. merge the PR yourself (gh pr merge or GitHub);' \
    "2. wait for the deployment of $(pr_base), then try in production;" \
    '3. lab acceptance --accept, then lab close (summary via a dedicated PR).'
}
