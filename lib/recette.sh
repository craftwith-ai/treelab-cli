# shellcheck shell=bash
# Recette du couloir : décisions relues dans les fiches, jamais de fichier d’état.
# Dépend de git.sh, project.sh, docs.sh et deploy.sh ; charge lui-même waiting.sh (phase « waiting », lot 02 d'autonomie-tours).
declare -F wait_lane_first >/dev/null || . "${BASH_SOURCE[0]%/*}/waiting.sh"

# recette_filter <body|strip|count> : section exacte sur stdin, hors blocs de code.
recette_filter() {
  lang_norm | awk -v mode="$1" '
    /^[[:space:]]*(```|~~~)/ {
      fence=!fence
      if (mode == "strip" && !inside) print
      next
    }
    !fence && /^## Recette du couloir[[:space:]]*$/ {inside=1; count++; next}
    !fence && /^## / {inside=0}
    mode == "strip" && !inside {print; next}
    mode == "body" && inside && !fence {print}
    END {if (mode == "count") print count+0}'
}
# recette_validated_by <fiche> : la ligne Validated by de la recette, fiche française ou anglaise (recette_field lit les noms
# internes français) ; le nom reste ici, jamais dans le code qui l'appelle (tests/livre_anglais.bats, CI Linux du 2026-11-21)
recette_validated_by() { local lang=fr; recette_field "$1" "$(lang_word "$lang" 'Validé par')"; }
recette_field() { # <fiche> <champ> : un seul champ, sinon vide
  recette_filter body <"$1" | awk -v key="**$2**" '
    index($0,key)==1 {
      v=substr($0,length(key)+1)
      if (v !~ /^[[:space:]]*:/) next
      sub(/^[[:space:]]*:[[:space:]]*/,"",v); sub(/[[:space:]]*$/,"",v)
      value=v; n++
    }
    END {if (n == 1) print value}'
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
  case "$2" in
    Décision) [ "$(lang_code "$value")" = accepted ] ;;
    Date) [ -n "$(recette_date_of "$value")" ] ;;
    'Révision essayée'|'Révision des documents') [ -n "$(recette_revision_of "$value")" ] ;;
    Preuves) case "$value" in ''|'<'*|TODO*|'à compléter'*) false ;; *) true ;; esac ;;
    *) false ;;
  esac && return 0
  printf '%s\n' "$value"; return 1
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
lane_plan_names() { treeplan_lots "$(treeplan_file "$(docs_dir "$1")" "$(wt_lane "$1")")" | cut -f1; }
# Refuser une liste partiellement lisible : une entrée ignorée ne vaut pas absence.
lane_plan_complete() { # <treeplan>
  lang_norm <"$1" | awk '
    /^## Lots([[:space:]]|$)/ {inside=1; sections++; next}
    inside && /^## / {inside=0}
    inside && /^[[:space:]]*([-*+][[:space:]]|[0-9]+[.)][[:space:]])/ {
      if ($0 !~ /^- \[lot-[0-9]+-[a-z0-9][a-z0-9._-]*\]\([^)]*\)/) bad=1
    }
    END {exit (sections != 1 || bad)}'
}
lane_last_lot() { # <wt> [fiche] → yes | no | unknown
  ! lane_permanent "$1" || { printf 'no\n'; return; }   # un couloir permanent n'a jamais de dernier lot, treeplan à jour ou non
  lane_plan_last "$@"
}
# lane_plan_last <wt> [fiche] → yes | no | unknown, lu sur le seul treeplan : lab next y cherche la vraie cause d'un désaccord, même
# dans un couloir permanent (revue du lot 01 d'autonomie-tours)
lane_plan_last() {
  local lot="${2:-}" docs tp names name count
  [ -n "$lot" ] || lot="$(wt_lot_file "$1")"
  [ -n "$lot" ] || { printf 'unknown\n'; return; }
  docs="$(docs_dir "$1")"; tp="$(treeplan_file "$docs" "$(wt_lane "$1")")"
  if [ ! -d "$(treeplans_dir "$docs")" ]; then
    case "$(reprise_next_lot "$(extract_reprise "$lot")")" in
      none) printf 'yes\n' ;; '') printf 'unknown\n' ;; *) printf 'no\n' ;;
    esac
    return
  fi
  if [ ! -r "$tp" ] || ! lane_plan_complete "$tp"; then printf 'unknown\n'; return; fi
  if lane_unplanned "$1" "$lot"; then printf 'unknown\n'; return; fi
  names="$(lane_plan_names "$1")"; name="$(basename "$lot" .md)"
  count="$(printf '%s\n' "$names" | grep -Fxc "$name" || true)"
  [ "$count" = 1 ] || { printf 'unknown\n'; return; }
  if [ "$(printf '%s\n' "$names" | tail -1)" = "$name" ]; then printf 'yes\n'; else printf 'no\n'; fi
}
lane_next_slug() { # <wt> <fiche> : entrée immédiatement suivante du treeplan, slug nu (vide si la fiche est la dernière)
  lot_bare_slug "$(lane_plan_names "$1" | awk -v name="$(basename "$2" .md)" 'found {print; exit} $0 == name {found=1}')"
}
# lane_next_values <wt> <fiche> : pose LANE_NEXT_REPRISE (slug annoncé par la Reprise, « aucun », ou vide) et LANE_NEXT_TREEPLAN
# (entrée suivante du treeplan), tous deux nus — lane_phase les compare, lab next les nomme quand ils divergent.
lane_next_values() {
  local next; next="$(reprise_next_lot "$(extract_reprise "$2")")"
  LANE_NEXT_REPRISE="${next%%$'\t'*}"; LANE_NEXT_TREEPLAN="$(lane_next_slug "$1" "$2")"
}
lane_lots_closed() { # <wt> <fiche courante> : toutes les fiches prévues existent et sont closes
  local docs lane name file names
  docs="$(docs_dir "$1")"; lane="$(wt_lane "$1")"
  [ -d "$(treeplans_dir "$docs")" ] || { case "$(lot_state "$2")" in closed*) return 0 ;; *) return 1 ;; esac; }
  lane_plan_complete "$(treeplan_file "$docs" "$lane")" || return 1
  names="$(lane_plan_names "$1")"; [ -n "$names" ] || return 1
  [ -z "$(printf '%s\n' "$names" | sort | uniq -d)" ] || return 1
  while IFS= read -r name; do
    [[ "$name" =~ ^lot-[0-9]+-[a-z0-9][a-z0-9._-]*$ ]] || return 1
    file="$(lots_dir "$docs" "$lane")/$name.md"
    [ -f "$file" ] || file="$(lots_dir "$docs")/$name.md"
    case "$(lot_state "$file")" in clos*) ;; *) return 1 ;; esac
  done <<<"$names"
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
# recette_status <wt> <fiche> : résultat stable, toujours rc=0, aucun fichier créé.
# La validation est un document Git lié à une révision du résultat ; un nouveau
# commit n’est admis que s’il modifie la seule section de recette de cette fiche.
recette_status() {
  local wt="$1" lot="$2" count field revision droot rel changes before after docs_revision
  [ -r "$lot" ] || { printf 'absent\n'; return; }
  count="$(recette_filter count <"$lot")"
  [ "$count" != 0 ] || { printf 'absent\n'; return; }
  [ "$count" = 1 ] || { printf 'incomplete\n'; return; }
  [ "$(lang_code "$(recette_field "$lot" Décision)")" != rejected ] || { printf 'rejected\n'; return; }
  for field in Décision Date 'Révision essayée' Preuves; do
    recette_field_check "$lot" "$field" >/dev/null || { printf 'incomplete\n'; return; }
  done
  revision="$(recette_revision_of "$(recette_field "$lot" 'Révision essayée')")"
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
    [ -z "$changes" ] || { printf 'expired\n'; return; }
    docs_revision="$(recette_revision_of "$(recette_field "$lot" 'Révision des documents')")"
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
  if [ "$changes" != "$rel" ]; then printf 'expired\n'; return; fi
  # Le document doit déjà exister à la révision essayée ; seule sa section de
  # recette est ajoutée ensuite. Une exemption sur tout docs/ serait trop large.
  git -C "$wt" cat-file -e "$revision:$rel" 2>/dev/null || { printf 'expired\n'; return; }
  before="$(git -C "$wt" show "$revision:$rel" | recette_filter strip)"
  after="$(git -C "$wt" show "HEAD:$rel" | recette_filter strip)"
  if [ "$before" = "$after" ]; then printf 'valid\n'; else printf 'expired\n'; fi
}

lane_phase() { # <wt> [fiche état] → work | in acceptance | acceptance passed | to clarify | permanent | waiting ; expose LANE_NEXT_REPRISE et LANE_NEXT_TREEPLAN
  local lot state next last docs
  if [ "$#" -ge 3 ]; then lot="$2"; state="$3"; else lot="$(wt_lot_file "$1")"; state="$(lot_state "$lot")"; fi   # fiche déjà lue (lab sweep)
  case "$state" in
    planned*|'in progress'*) printf 'work\n'; return ;;
    closed*|waiting*) ;;   # en attente : livré comme un lot clos (lot 02 d'autonomie-tours)
    *) printf 'to clarify\n'; return ;;
  esac
  lane_next_values "$1" "$lot"; next="$LANE_NEXT_REPRISE"; last="$(lane_last_lot "$1" "$lot")"; docs="$(docs_dir "$1")"
  if [ "$next" != none ]; then
    if [ -n "$next" ] && { [ ! -d "$(treeplans_dir "$docs")" ] \
      || { [ "$last" = no ] && [ "$next" = "$LANE_NEXT_TREEPLAN" ]; }; }; then printf 'work\n'
    else printf 'to clarify\n'; fi
    return
  fi
  # couloir permanent sans lot restant : ni recette ni fermeture, lab next y ouvre la session libre (lot 01 d'autonomie-tours)
  if lane_permanent "$1"; then printf 'permanent\n'; return; fi
  # dernier lot fini, une mesure du couloir attend sa date : ni recette ni fermeture avant elle (lot 02 d'autonomie-tours)
  if [ "$last" = yes ] && [ -n "$(wait_lane_first "$1")" ]; then printf 'waiting\n'; return; fi
  if [ "$last" != yes ] || ! lane_lots_closed "$1" "$lot"; then printf 'to clarify\n'; return; fi
  if [ "$(recette_status "$1" "$lot")" = valid ]; then printf 'acceptance passed\n'; else printf 'in acceptance\n'; fi
}

# lane_unplanned <wt> [fiche] : couloir neuf pas encore planifié (lot 18) — treeplan sans intention, un seul lot, aucune Reprise dans
# la fiche. Ce seul lot n'est pas « le dernier prévu » : personne n'a encore fixé la suite (le grill-me et batch-plan la fixeront).
lane_unplanned() {
  local lot="${2:-}" tp
  [ -n "$lot" ] || lot="$(wt_lot_file "$1")"
  tp="$(treeplan_file "$(docs_dir "$1")" "$(wt_lane "$1")")"
  [ -r "$tp" ] && [ -z "$(treeplan_intent "$tp")" ] || return 1
  [ "$(lane_plan_names "$1" | awk 'NF {n++} END {print n + 0}')" = 1 ] || return 1
  [ -z "$(extract_reprise "$lot")" ]
}
last_lot_notice() { # <wt> [fiche] : indication dérivée, avant et après planification
  case "$(lane_last_lot "$1" "${2:-}")" in
    yes) printf '%s' 'Last planned batch — a check together will follow.' ;;
    unknown) if lane_unplanned "$1" "${2:-}"; then printf '%s' 'Next batches: unknown — planning will set them.'; fi ;;
  esac
  return 0
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
  if printf '%s\n' "$spec" | grep -qx unknown; then echo unknown; return 0; fi
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
agreement_get() { [ -f "$1" ] || return 0; sed -n "s/^$2=//p" "$1" | head -1; }   # <fichier> <champ>
# agreement_write <couloir> <décision> <révision> <révision des documents> <rôle> <lot> [via] [close] [mots] : réécriture atomique
agreement_write() {
  local f; f="$(agreement_file "$1")"
  ( umask 077; mkdir -p "$(dirname "$f")" && rm -f "$f.tmp.$$" \
    && { printf 'decision=%s\nrev=%s\ndocs_rev=%s\nrole=%s\nbatch=%s\nat=%s\n' "$2" "$3" "$4" "$5" "$6" "$(rdv_now)"
         [ -z "${7:-}" ] || printf 'via=%s\nclose=%s\nsaid=%s\n' "$7" "${8:-no}" "${9:-}"; } >"$f.tmp.$$" \
    && mv "$f.tmp.$$" "$f" )
}
agreement_clear() { rm -f "$(agreement_file "$1")"; }
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
