# shellcheck shell=bash
# docs.sh — masterplan (le pourquoi, sans avancement), treeplan d'un couloir (docs/treeplans/<couloir>.md : ordre et
# intention de ses lots), fiches (docs/lots/<couloir>/lot-NN-<slug>.md), CHANGELOG, section « Reprise ».
# Aucun avancement n'est écrit nulle part : l'état d'un lot vit dans sa seule fiche, lab plan le recalcule (lot 02, 2026-09-06).
# Lecture : le nouvel emplacement d'abord, l'ancien (docs/lots/lot-NN-<slug>.md) à défaut — jamais réécrit.
# Fiches françaises ou anglaises : chaque lecteur passe par lang_norm (lib/lang.sh), chaque écrivain suit la langue du document.
. "$(dirname "${BASH_SOURCE[0]}")/lang.sh"
lots_dir() { if [ -n "${2:-}" ]; then printf '%s/lots/%s\n' "$1" "$2"; else printf '%s/lots\n' "$1"; fi; }
# next_lot_number <docs> <couloir> [plancher] : max des chiffres de tête de lots/<couloir>/lot-*.md + 1
# (lot-88.md, lot-60d-g.md, lot-03-x.md → 89). La numérotation repart à 01 dans un couloir neuf : chaque couloir a la sienne.
# Le plancher est le numéro du lot précédent du couloir : avec docs=repo, sa fiche manque du dossier tant que sa PR n'est pas mergée (lot 9).
next_lot_number() {
  local max="${3:-0}" f n; max=$((10#${max:-0}))
  for f in "$(lots_dir "$1" "$2")"/lot-[0-9]*.md; do
    [ -e "$f" ] || continue
    n="$(basename "$f" | sed -n 's/^lot-\([0-9][0-9]*\).*/\1/p')"; [ -n "$n" ] || continue; n=$((10#$n))
    [ "$n" -gt "$max" ] && max=$n
  done
  printf '%02d\n' $((max + 1))
}
# current_lot_file <docs> <slug> [couloir] → dernier lot-NN-<slug>.md (vide si aucun).
# Le dossier du couloir gagne ; sans lui, l'ancien emplacement commun est lu (projets d'avant le lot 02).
# shellcheck disable=SC2012
current_lot_file() {
  local f=""
  [ -n "${3:-}" ] && f="$(ls "$(lots_dir "$1" "$3")"/lot-[0-9]*-"$2".md 2>/dev/null | sort | tail -1)"
  [ -n "$f" ] || f="$(ls "$(lots_dir "$1")"/lot-[0-9]*-"$2".md 2>/dev/null | sort | tail -1)"
  printf '%s\n' "$f"
}
lot_number_of() { basename "$1" | sed -n 's/^lot-\([0-9][0-9]*\).*/\1/p'; }
# lot_slug_of <wt> : slug du lot = celui de la branche <kind>/<slug> (une branche par lot, 2026-09-02), sinon le nom du dossier.
# Une branche de réouverture chore/<slug>.c<N>[.r<report>] (lot 02 d'autonomie-tours) rend le slug du lot rouvert, suffixe retiré.
lot_slug_of() {
  local br; br="$(branch_name "$1")"
  case "$br" in
    */*) local bare; br="${br#*/}"   # BASH_REMATCH lu avant reopen_branch_of, qui le réécrit
         if [[ "$br" =~ ^(.+)\.c[0-9]+(\.r[0-9]+)?$ ]]; then bare="${BASH_REMATCH[1]}"; ! reopen_branch_of "$1" >/dev/null || br="$bare"; fi
         printf '%s\n' "$br" ;;
    *) local slug; slug="$(wt_meta "$1" lot)"; if [ -n "$slug" ]; then printf '%s\n' "$slug"; else basename "$1"; fi ;;
  esac
}
# reopen_branch_of <wt> → « C<N> » si la branche est une réouverture chore/<slug>.c<N>, ou chore/<slug>.c<N>.r<k> après le k-ième
# report, rc 1 sinon. Un slug de lot qui finit ainsi est refusé à sa création (lot_slug_reserved) : le suffixe n'est jamais ambigu.
reopen_branch_of() {
  local br; br="$(branch_name "$1")"
  [[ "$br" =~ ^chore/.+\.c([0-9]+)(\.r[0-9]+)?$ ]] || return 1
  printf 'C%s\n' "${BASH_REMATCH[1]}"
}
lot_slug_reserved() { [[ "${1:-}" =~ \.c[0-9]+(\.r[0-9]+)?$ ]]; }
# wt_own_lot_file <wt> → la fiche nommée par la branche, sans repli sur la fiche de tête (lab batch wait, sur une réouverture)
wt_own_lot_file() { current_lot_file "$(docs_dir "$1")" "$(lot_slug_of "$1")" "$(wt_lane "$1")"; }
# lane_head_lot <docs> <couloir> → fiche de plus grand numéro du couloir (vide si aucune)
# shellcheck disable=SC2012
lane_head_lot() { ls "$(lots_dir "$1" "$2")"/lot-[0-9]*.md 2>/dev/null | awk '{ n = $0; sub(/.*\/lot-/, "", n); sub(/[^0-9].*/, "", n); print n + 0 "\t" $0 }' | sort -n | tail -1 | cut -f2-; }
# wt_lot_file <wt> → fiche du lot courant du couloir : lot-NN-<slug de la branche>.md, sinon lot-NN-<nom du couloir>.md
# (couloirs d'avant le lot 9 : le worktree 60d-g sur feat/60d-h garde sa fiche lot-97-60d-g). Vide si aucune.
# Sur une branche de réouverture, la fiche rouverte tant qu'elle est planifiée ou en cours ; close ou de nouveau en attente, le
# couloir reprend sa fiche de tête (plus grand numéro) : lab next, la recette et lab status repartent d'où le couloir en était.
wt_lot_file() {
  local docs lane f h; docs="$(docs_dir "$1")"; lane="$(wt_lane "$1")"
  f="$(current_lot_file "$docs" "$(lot_slug_of "$1")" "$lane")"
  [ -n "$f" ] || f="$(current_lot_file "$docs" "$(basename "$1")" "$lane")"
  if [ -n "$f" ] && reopen_branch_of "$1" >/dev/null; then
    case "$(lot_state "$f")" in planned*|'in progress'*) ;; *) h="$(lane_head_lot "$docs" "$lane")"; [ -z "$h" ] || f="$h" ;; esac
  fi
  printf '%s\n' "$f"
}
# lot_state_check <fiche> → <verdict><TAB><n° de ligne><TAB><valeur><TAB><ligne brute>, verdict ok | variante | inconnue | absente.
# Lecture tolérante (lot 12) : une ligne « État » écrite à la main — casse, puce - * +, deux-points dans ou hors du gras, gras absent,
# espaces insécables — arrêtait lab next sur « état inconnu : absent ». Seul l'en-tête compte : la première ligne d'État hors bloc
# de code, avant « ## Objectif », « ## Journal » ou « ## Reprise » (un « - état : … » du journal n'est jamais lu). La valeur reste
# stricte : planifié, en cours, en attente (lot 02 d'autonomie-tours) ou clos, suivis d'un suffixe éventuel ; toute autre valeur est « inconnue », jamais devinée.
LOT_STATE_EXPECTED='"**State** : planned", "in progress", "waiting" or "closed" (French batch file: "**État** : planifié", "en cours", "en attente" or "clos"), optionally followed by a suffix'
lot_state_check() {
  [ -f "${1:-}" ] && [ -r "$1" ] || { printf 'absente\t\t\t\n'; return 0; }
  lang_norm <"$1" | LC_ALL=C awk '
    { sub(/\r$/, "") }
    /^[ \t]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    /^## +(Objectif|Journal|Reprise)/ { exit }
    {
      l = $0; gsub(/\302\240|\342\200\257|\342\200\211|\t/, " ", l)
      if (!match(l, /^ *([-*+] +)?(\*\*|__)?(\303\211|\303\251|E|e)[Tt][Aa][Tt] *(\*\*|__)? *: *(\*\*|__)? */)) next
      v = substr(l, RSTART + RLENGTH); sub(/ +$/, "", v)
      t = v; if (gsub(/\*\*/, "", t) % 2) sub(/ *\*\*$/, "", v)
      t = v; if (gsub(/__/, "", t) % 2) sub(/ *__$/, "", v)
      if (v !~ /^(planifi\303\251|en cours|en attente|clos)([^A-Za-z0-9\200-\377]|$)/) verdict = "inconnue"
      else if ($0 == "**\303\211tat** : " v) verdict = "ok"
      else verdict = "variante"
      printf "%s\t%d\t%s\t%s\n", verdict, NR, v, $0; found = 1; exit
    }
    END { if (!found) printf "absente\t\t\t\n" }'
}
# lot_state <fiche> → état anglais : planned | in progress | closed, suffixe conservé (vide si pas de fiche ; jamais rc≠0 : appelé en `st="$(lot_state …)"` sous set -e, un rc=1 tuait la CLI en silence — review du lot 9)
lot_state() { lang_code_prefix "$(lot_state_check "${1:-}" | cut -f3)"; }   # toujours anglais, quelle que soit la langue de la fiche
# lot_set_state <fiche> <état anglais> : la ligne d'État de l'en-tête, quelle que soit sa forme, devient « **État** : <état> » ; rien sans ligne.
# Une ligne anglaise reste anglaise : « **State** : <valeur anglaise> » (la langue est celle de la ligne elle-même).
lot_set_state() {
  local n tmp lang; n="$(lot_state_check "$1" | cut -f2)"; [ -n "$n" ] || return 0
  lang="$(sed -n "${n}p" "$1" | lang_norm detect)"
  tmp="$(mktemp)"; LAB_STATE_LINE="**$(lang_word "$lang" État)** : $(lang_value "$lang" "$2")" awk -v n="$n" 'NR == n { print ENVIRON["LAB_STATE_LINE"]; next } { print }' "$1" >"$tmp" && mv "$tmp" "$1"
}
# lot_state_canon <fiche> : une variante lisible est réécrite en forme canonique (rc 0) ; ok, inconnue ou absente : rien (rc 1)
lot_state_canon() {
  local check; check="$(lot_state_check "$1")"
  [ "$(printf '%s' "$check" | cut -f1)" = variante ] || return 1
  lot_set_state "$1" "$(lang_code_prefix "$(printf '%s' "$check" | cut -f3)")"
  log "line $(printf '%s' "$check" | cut -f2) of $(basename "$1") rewritten: \"$(printf '%s' "$check" | cut -f4)\" → \"$(sed -n "$(printf '%s' "$check" | cut -f2)p" "$1")\""
}
# lot_state_problem <fiche> → message nommé pour une ligne d'État absente ou inconnue ; vide si elle est lisible
lot_state_problem() {
  local check verdict; check="$(lot_state_check "$1")"; verdict="$(printf '%s' "$check" | cut -f1)"
  case "$verdict" in
    absente) printf 'no State line in the header of %s (before "## Goal"); expected: %s\n' "$1" "$LOT_STATE_EXPECTED" ;;
    inconnue) printf 'line %s of %s: "%s" — value read "%s", unknown; expected: %s\n' "$(printf '%s' "$check" | cut -f2)" "$1" "$(printf '%s' "$check" | cut -f4)" "$(printf '%s' "$check" | cut -f3)" "$LOT_STATE_EXPECTED" ;;
  esac
}
# ---------- ligne Execution : où tourne la session d'exécution du lot (lot 01 d'aiguillage-cloud) ----------
# Besoins qui imposent le Mac, liste fermée écrite par batch-plan : « **Execution** : mac — <besoin>: <détail> ».
# shellcheck disable=SC2034 # lu par cloud_execution_line (lib/cloud.sh)
LOT_EXECUTION_NEEDS='secret deploy mac-tool human resource live'
# awk : une ligne sans ses commentaires HTML, ouverts sur plusieurs lignes compris (cm garde l'état d'une ligne à l'autre)
LOT_AWK_UNCOMMENT='function uncomment(l,   p, q) {
  if (cm) { p = index(l, "-->"); if (!p) return ""; l = substr(l, p + 3); cm = 0 }
  while ((p = index(l, "<!--")) > 0) {
    q = index(substr(l, p + 4), "-->")
    if (q) l = substr(l, 1, p - 1) substr(l, p + q + 6); else { l = substr(l, 1, p - 1); cm = 1 }
  }
  return l
}'
# awk : line() → la ligne courante lisible, sans commentaires ; vide dans un bloc de code ou un commentaire — un « ## » ou un bloc
# de code écrits dans un commentaire, ou un « ## » dans un bloc de code, ne ferment ni n'ouvrent de section (revue du lot 01)
# shellcheck disable=SC2016 # programme awk, rien à développer
LOT_AWK_LINE='
function line(   l) {
  sub(/\r$/, "")
  if (fence) { if ($0 ~ /^[ \t]*(```|~~~)/) fence = 0; return "" }
  l = uncomment($0)
  if (l ~ /^[ \t]*(```|~~~)/) { fence = 1; return "" }
  return l
}'
# lot_execution <fiche> → <mode><TAB><besoin><TAB><détail><TAB><n° de ligne><TAB><ligne brute>, mode cloud | mac | absent | unreadable.
# Lecture tolérante, sur le modèle de lot_state_check : casse, puce, deux-points dans ou hors du gras, gras absent, espaces insécables,
# tiret long, court ou simple. Seul l'en-tête compte (avant le premier « ## ») ; commentaires HTML et blocs de code ignorés. « cloud »
# peut porter un détail (« cloud — code seul ») ; « mac — <besoin>: <détail> » nomme son besoin, que cloud_decide juge contre
# LOT_EXECUTION_NEEDS. Toute autre valeur, vide comprise, est « unreadable » (détail = valeur lue), jamais devinée.
lot_execution() {
  local r n
  [ -f "${1:-}" ] && [ -r "$1" ] || { printf 'absent\t\t\t\t\n'; return 0; }
  r="$(lang_norm <"$1" | LC_ALL=C awk "$LOT_AWK_UNCOMMENT$LOT_AWK_LINE"'
    !(l = line()) { next }
    l ~ /^## / { exit }
    {
      gsub(/\302\240|\342\200\257|\342\200\211|\t/, " ", l)
      if (!match(l, /^ *([-*+] +)?(\*\*|__)?(\303\211|\303\251|E|e)[Xx](\303\211|\303\251|E|e)[Cc][Uu][Tt][Ii][Oo][Nn] *(\*\*|__)? *: *(\*\*|__)? */)) next
      v = substr(l, RSTART + RLENGTH); sub(/ +$/, "", v)
      t = v; if (gsub(/\*\*/, "", t) % 2) sub(/ *\*\*$/, "", v)
      t = v; if (gsub(/__/, "", t) % 2) sub(/ *__$/, "", v)
      mode = "unreadable"; need = ""; detail = v
      if (match(tolower(v), /^(cloud|mac)([^a-z0-9-]|$)/)) {
        mode = (tolower(substr(v, 1, 3)) == "mac") ? "mac" : "cloud"
        detail = substr(v, length(mode) + 1); sub(/^ *(\342\200\224|\342\200\223|-|:)? */, "", detail)
        if (mode == "mac" && match(detail, /^[A-Za-z][A-Za-z0-9-]*/)) {
          need = tolower(substr(detail, 1, RLENGTH)); detail = substr(detail, RLENGTH + 1); sub(/^ *:? */, "", detail)
        }
      }
      printf "%s\t%s\t%s\t%d\n", mode, need, detail, NR; exit
    }')"
  n="$(printf '%s' "$r" | cut -f4)"
  if [ -n "$n" ]; then printf '%s\t%s\n' "$r" "$(sed -n "${n}p" "$1" | tr -d '\r')"; else printf 'absent\t\t\t\t\n'; fi   # la ligne telle qu'écrite
}
# lot_mac_signal <fiche> → <besoin><TAB><commande><TAB><n° de ligne> du premier signal dur des étapes : `lab deploy…` → deploy,
# `lab lock…` → resource ; rien sinon. Seule la section Steps (Étapes) compte : la même commande citée dans Scope, Out of scope,
# Risks, le journal ou un commentaire HTML n'est pas une étape du lot.
lot_mac_signal() {
  [ -f "${1:-}" ] && [ -r "$1" ] || return 0
  lang_norm <"$1" | LC_ALL=C awk "$LOT_AWK_UNCOMMENT$LOT_AWK_LINE"'
    !(l = line()) { next }
    l ~ /^## / { if (steps) exit; steps = (l ~ /^## +\303\211tapes([^A-Za-z]|$)/); next }
    steps && match(l, /`lab (deploy|lock)( [^`]*)?`/) {
      c = substr(l, RSTART, RLENGTH)
      printf "%s\t%s\t%d\n", (c ~ /^`lab deploy/) ? "deploy" : "resource", c, NR; exit
    }'
}
# lot_title_of <fiche> → titre du lot lu dans son titre de premier niveau « # Lot NN — <titre> » (vide si illisible)
lot_title_of() { [ -f "${1:-}" ] && [ -r "$1" ] || return 0; lang_norm <"$1" | sed -n 's/^# Lot [0-9][0-9]*[[:space:]]*—[[:space:]]*//p' | head -1; }
# create_lot <docs> <couloir> <slug> <titre> [projet] [branche] [plancher] → chemin
# Une fiche semée — même slug, « planifié », numéro au-dessus du plancher — est reprise telle quelle, jamais renumérotée (lot 26).
# shellcheck disable=SC2012
create_lot() {
  local docs="$1" lane="$2" slug="$3" title="$4" project="${5:-}" branch="${6:-$3}" nn f
  mkdir -p "$(lots_dir "$docs" "$lane")"
  # nom exact : le joker * de lot-[0-9]*-<slug> attraperait aussi lot-05-autre-<slug> (revue du lot 26)
  f="$(ls "$(lots_dir "$docs" "$lane")"/lot-[0-9]*-"$slug".md 2>/dev/null | awk -v s="$slug" '{ n = $0; sub(/.*\//, "", n); sub(/^lot-[0-9]+-/, "", n) } n == s ".md"' | sort | tail -1)"
  if [ -n "$f" ] && [ "$(lot_state "$f")" = planned ]; then
    nn="$(basename "$f" | sed -n 's/^lot-\([0-9][0-9]*\).*/\1/p')"
    [ "$((10#$nn))" -gt "$((10#${7:-0}))" ] && { printf '%s\n' "$f"; return 0; }
  fi
  nn="$(next_lot_number "$docs" "$lane" "${7:-0}")"; f="$(lots_dir "$docs" "$lane")/lot-$nn-$slug.md"
  sed -e "s/{{NN}}/$nn/g" -e "s/{{SLUG}}/$slug/g" -e "s/{{TITLE}}/$(printf '%s' "$title" | sed 's/[&|]/\\&/g')/g" \
      -e "s/{{DATE}}/$(date +%Y-%m-%d)/g" -e "s/{{PROJECT}}/$project/g" -e "s|{{BRANCH}}|$branch|g" "$LAB_ROOT/templates/project/lot.md" >"$f"
  printf '%s\n' "$f"
}
# ---------- fiches externes dans leur dépôt git (lot 03 de lab-enhancement) ----------
# docs_repo_root <wt> : racine git du dossier des fiches externes, casse et liens résolus ; vide avec docs=repo ou sans dépôt.
docs_repo_root() {
  local r
  [ "$P_DOCS" != repo ] || return 0
  r="$(repo_root "$(docs_dir "$1")" 2>/dev/null || true)"; [ -n "$r" ] || return 0
  real_path "$r"
}
# lane_doc_paths <wt> : les chemins du couloir dans le dépôt des fiches, relatifs à sa racine — lots/<couloir> et
# treeplans/<couloir>.md, quel que soit l'emplacement de docs/ dans ce dépôt ; rien sans dépôt. Le masterplan, le CHANGELOG racine
# et les autres couloirs n'en font jamais partie : c'est la frontière que docs_commit et recette_status respectent.
lane_doc_paths() {
  local droot docs rel lane lot
  droot="$(docs_repo_root "$1")"; [ -n "$droot" ] || return 0
  docs="$(real_path "$(docs_dir "$1")")"; lane="$(wt_lane "$1")"
  case "$docs" in "$droot") rel="" ;; "$droot"/*) rel="${docs#"$droot"/}/" ;; *) return 0 ;; esac
  printf '%s\n' "${rel}lots/$lane" "${rel}treeplans/$lane.md"
  # ancien layout : la fiche courante vit à plat dans lots/ (couloirs d'avant le lot 9) — elle appartient au couloir (revue, lot 03)
  lot="$(wt_lot_file "$1")"; [ -n "$lot" ] || return 0
  lot="$(real_path "$(dirname "$lot")")/$(basename "$lot")"
  case "$lot" in "$docs/lots/$lane/"*) ;; "$droot"/*) printf '%s\n' "${lot#"$droot"/}" ;; esac
}
# docs_commit <wt> <résumé> : enregistre les seuls chemins du couloir dans le dépôt des fiches externes — git add -A puis
# commit « docs(<projet>): <couloir> — <résumé> » limité à ces chemins ; un fichier hors du couloir (autre couloir, autre projet,
# masterplan) n'est jamais emporté, même déjà indexé. Imprime DOCS_COMMIT=<sha>, none (DOCS_REASON : docs dans le dépôt du projet,
# dépôt des fiches absent, rien à enregistrer) ou échec (DOCS_REASON : message git — identité absente, hook), puis DOCS_PENDING.
# Pose DOCS_COMMIT_RESULT et DOCS_COMMIT_REASON ; ne s'arrête jamais : la commande appelante décide (constat 3 du brief, lot 03).
docs_commit() {
  local wt="$1" summary="$2" droot lane path
  local -a paths=()
  DOCS_COMMIT_RESULT=none; DOCS_COMMIT_REASON=""
  if [ "$P_DOCS" = repo ]; then
    DOCS_COMMIT_REASON="docs in the project repository"; kv DOCS_COMMIT none; kv DOCS_REASON "$DOCS_COMMIT_REASON"; return 0
  fi
  droot="$(docs_repo_root "$wt")"
  if [ -z "$droot" ]; then
    DOCS_COMMIT_REASON="batch files repository missing: $(docs_dir "$wt") is in no git repository"; kv DOCS_COMMIT none; kv DOCS_REASON "$DOCS_COMMIT_REASON"; return 0
  fi
  lane="$(wt_lane "$wt")"
  while IFS= read -r path; do [ -n "$path" ] && paths+=("$path"); done < <(lane_doc_paths "$wt")
  git_commit_paths "$droot" "docs($P_NAME): $lane — $summary" "${paths[@]+"${paths[@]}"}"
  DOCS_COMMIT_RESULT="$COMMIT_RESULT"; DOCS_COMMIT_REASON="$COMMIT_REASON"
  kv DOCS_COMMIT "$DOCS_COMMIT_RESULT"
  case "$DOCS_COMMIT_RESULT" in
    none) kv DOCS_REASON "$DOCS_COMMIT_REASON" ;;
    failed) kv DOCS_REASON "$DOCS_COMMIT_REASON"; warn "batch files of lane $lane not recorded in $droot — git: $DOCS_COMMIT_REASON" ;;
    *) log "batch files of lane $lane recorded: $DOCS_COMMIT_RESULT in $droot" ;;
  esac
  docs_pending "$droot" "${paths[@]+"${paths[@]}"}"
}
# git_commit_paths <dépôt> <message> <chemins…> : la mécanique commune de docs_commit et de lab rdv (lot 05) — git add -A puis commit
# limités aux chemins connus (sur le disque ou dans l'index : git refuse un chemin absent des deux) ; un autre fichier, même déjà
# indexé, n'est jamais emporté. Pose COMMIT_RESULT (<sha> | none | échec) et COMMIT_REASON (« rien à enregistrer » ou le message git
# sur une ligne) ; n'imprime rien et ne s'arrête jamais. Un git add ou un git commit refusé (verrou d'index d'un autre lab, identité
# absente, hook) est un échec cité, jamais « rien à enregistrer ».
git_commit_paths() {
  local droot="$1" msg="$2" path out; shift 2
  local -a known=()
  COMMIT_RESULT=none; COMMIT_REASON=""
  for path in "$@"; do
    if [ -e "$droot/$path" ] || [ -n "$(git -C "$droot" ls-files -- "$path")" ]; then known+=("$path"); fi
  done
  if [ "${#known[@]}" -eq 0 ]; then COMMIT_REASON="nothing to record"
  elif ! out="$(git -C "$droot" add -A -- "${known[@]}" 2>&1)"; then COMMIT_RESULT=failed; COMMIT_REASON="$(git_one_line "$out")"
  elif git -C "$droot" diff --cached --quiet -- "${known[@]}"; then COMMIT_REASON="nothing to record"
  elif out="$(git -C "$droot" commit -q -m "$msg" -- "${known[@]}" 2>&1)"; then COMMIT_RESULT="$(git -C "$droot" rev-parse HEAD)"
  else COMMIT_RESULT=failed; COMMIT_REASON="$(git_one_line "$out")"
  fi
}
git_one_line() { printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | tr '\n' ' ' | sed 's/[[:space:]]*$//'; }   # un message git multiligne, sur une ligne
# docs_pending <dépôt> <chemins du couloir…> : DOCS_PENDING=<n> fichiers sales hors du couloir dans le dépôt des fiches, les dix premiers
# nommés sur stderr — jamais enregistrés par lab (autres couloirs, autres projets, masterplan, CHANGELOG racine).
docs_pending() {
  # Un seul passage awk : la boucle bash d'origine recopiait la liste des noms à chaque ligne (coût quadratique) — 18 583 fichiers
  # hors du couloir dans le dépôt des fiches la faisaient tourner ~15 min et bloquaient lab next (2026-09-24). Le message ne nomme
  # plus que les 10 premiers : la liste entière faisait plus d'un mégaoctet sur stderr.
  local droot="$1" out n names; shift
  out="$( { git -C "$droot" -c core.quotePath=false status --porcelain --untracked-files=all || true; } | LAB_LANE_PATHS="$(printf '%s\n' "$@")" awk '
    BEGIN { np = split(ENVIRON["LAB_LANE_PATHS"], P, "\n") }
    length($0) > 0 {
      path = substr($0, 4)
      while ((i = index(path, " -> ")) > 0) path = substr(path, i + 4)
      for (k = 1; k <= np; k++) if (P[k] != "" && (path == P[k] || index(path, P[k] "/") == 1)) next
      n++; if (n <= 10) shown[n] = path
    }
    END {
      print n + 0
      for (i = 1; i <= n && i <= 10; i++) printf "%s%s", (i > 1 ? ", " : ""), shown[i]
      if (n > 10) printf " … and %d more", n - 10
      printf "\n"
    }')"
  n="$(printf '%s\n' "$out" | sed -n 1p)"; names="$(printf '%s\n' "$out" | sed -n 2p)"
  kv DOCS_PENDING "${n:-0}"
  [ "${n:-0}" = 0 ] || log "not recorded, outside the lane ($droot): $names"
}
ensure_masterplan() { # <docs> <projet>
  [ -f "$1/masterplan.md" ] && return 0
  mkdir -p "$1"; sed -e "s/{{PROJECT}}/$2/g" -e "s/{{DATE}}/$(date +%Y-%m-%d)/g" "$LAB_ROOT/templates/project/masterplan.md" >"$1/masterplan.md"
}
treeplans_dir() { printf '%s/treeplans\n' "$1"; }
treeplan_file() { printf '%s/treeplans/%s.md\n' "$1" "$2"; }   # <docs> <couloir>
# ensure_treeplan <docs> <couloir> [projet] : sème le treeplan du couloir s'il manque ; un fichier déjà là n'est jamais écrasé
# (les couloirs à venir ont leur feuille de route écrite d'avance ; à l'ouverture, lab new la trouve et la respecte).
ensure_treeplan() {
  local f; f="$(treeplan_file "$1" "$2")"
  [ -f "$f" ] && return 0
  mkdir -p "$(dirname "$f")"
  sed -e "s/{{PROJECT}}/${3:-}/g" -e "s/{{LANE}}/$2/g" -e "s/{{DATE}}/$(date +%Y-%m-%d)/g" "$LAB_ROOT/templates/project/treeplan.md" >"$f"
}
# treeplan_add <docs> <couloir> <fiche> <titre> : ajoute « - [lot-NN-slug](../lots/<couloir>/…) — titre » sous « ## Lots » (« ## Batches »
# dans un treeplan anglais) si absent.
# Aucun symbole d'avancement : la ligne dit l'ordre et l'intention, jamais l'état.
treeplan_add() {
  local tp name line tmp lots
  tp="$(treeplan_file "$1" "$2")"; [ -f "$tp" ] || return 0
  lots="$(lang_word "$(lang_doc_of "$tp")" Lots)"
  name="$(basename "$3" .md)"
  treeplan_lots "$tp" | cut -f1 | grep -Fxq "$name" && return 0
  line="- [$name](../lots/$2/$name.md) — $4"
  tmp="$(mktemp)"
  # insère à la fin de la section « ## Lots » (avant l'en-tête suivant), en gardant une ligne vide autour
  awk -v l="$line" -v re="^## ($(lang_section_re Lots))([[:space:]]|$)" '
    $0 ~ re { print; insec=1; blank=0; next }
    insec && /^$/ { blank++; next }
    insec && /^## / { if (blank == 0) print ""; while (blank > 0) { print ""; blank-- }; print l; print ""; insec=0; done=1 }
    insec { while (blank > 0) { print ""; blank-- } }
    { print }
    END { if (insec && !done) { if (blank == 0) print ""; print l } }' "$tp" >"$tmp"
  treeplan_lots "$tmp" | cut -f1 | grep -Fxq "$name" || printf '\n## %s\n\n%s\n' "$lots" "$line" >>"$tmp"
  mv "$tmp" "$tp"
}
# treeplan_lots <treeplan> → « nom du lot<TAB>intention » pour chaque ligne de la section « ## Lots », dans l'ordre du fichier.
treeplan_lots() {
  [ -f "${1:-}" ] && [ -r "$1" ] || return 0
  lang_norm <"$1" | awk '/^## Lots([[:space:]]|$)/ {inside=1; next} inside && /^## / {exit} inside {print}' |
    sed -n 's/^- \[\(lot-[0-9][0-9]*[^]]*\)\]([^)]*)[[:space:]]*—*[[:space:]]*\(.*\)$/\1	\2/p'
}
# treeplan_intent <treeplan> → la ligne « **Intention** : … » (vide si absente ou encore à écrire)
treeplan_intent() {
  local i
  [ -f "${1:-}" ] && [ -r "$1" ] || return 0
  i="$(lang_norm <"$1" | sed -n 's/^\*\*Intention\*\* *: *//p' | head -1)"
  case "$i" in '<!--'*) i="" ;; esac
  printf '%s\n' "$i"
}
ensure_changelog() { [ -f "$1/CHANGELOG.md" ] || cp "$LAB_ROOT/templates/project/CHANGELOG.md" "$1/CHANGELOG.md"; }
# changelog_add <fichier> <ligne> : insère sous « ## Unreleased ».
changelog_add() {
  local tmp; tmp="$(mktemp)"
  awk -v l="$2" 'BEGIN{done=0} {print} /^## Unreleased/ && !done { print ""; print l; done=1 }' "$1" >"$tmp" && mv "$tmp" "$1"
}
# extract_reprise <fiche> → la section « ## Reprise » (« ## Handoff »), marqueurs ramenés à la valeur interne
extract_reprise() { [ -f "${1:-}" ] && [ -r "$1" ] || return 0; lang_norm <"$1" | awk '/^## Reprise/{p=1} p && /^## / && !/^## Reprise/{exit} p'; }
# lot_bare_slug <nom> → le slug sans son préfixe « lot-NN- » : « lot-02-foo » et « foo » désignent le même lot
# (seul point de normalisation : Reprise et treeplan se comparent par lui, la branche créée ne s'appelle jamais feat/lot-02-…).
lot_bare_slug() { printf '%s\n' "$1" | sed 's/^lot-[0-9][0-9]*-//'; }
# reprise_next_lot <texte de la reprise> → « slug<TAB>titre » depuis la ligne « **Prochain lot** : <slug> — <titre> » ; « aucun » ;
# vide si absente ou si le slug n'en est pas un (le placeholder « <slug> » du gabarit ne doit jamais passer pour un lot suivant).
# Le slug est rendu nu : une fiche qui écrit « lot-02-foo » est formellement juste (constat 4 du brief, 2026-09-15).
reprise_next_lot() {
  local l slug title; l="$(printf '%s\n' "$1" | lang_norm | sed -n 's/^\*\*Prochain lot\*\* *: *//p' | head -1)"
  [ -n "$l" ] || return 0
  case "$l" in [aA]ucun*|[nN]one*) echo none; return 0 ;; esac   # « aucun » : Reprise d'une fiche française
  slug="$(lot_bare_slug "$(printf '%s' "$l" | sed 's/[[:space:]].*$//; s/—.*$//; s/`//g')")"
  valid_slug "$slug" || return 0
  title="$(printf '%s' "${l#"${l%%[[:space:]—]*}"}" | sed 's/^[[:space:]]*—*[[:space:]]*//; s/^-[[:space:]]*//; s/[[:space:]]*$//')"
  printf '%s\t%s\n' "$slug" "$title"
}
# ---------- démarrage d'un couloir (lot 18 de lab-enhancement) ----------
# lane_brief <docs> <couloir> → le brief le plus récent du couloir (lots/<couloir>/brief-*.md, rangé par lab new --brief), ou rien
# shellcheck disable=SC2012
lane_brief() { ls -t "$(lots_dir "$1" "$2")"/brief-*.md 2>/dev/null | head -1 || true; }
# brief_store <docs> <couloir> <fichier> → chemin du brief copié tel quel : brief-<date>.md, suffixé -2, -3… si ce nom est déjà pris
brief_store() {
  local dir day f n=1; dir="$(lots_dir "$1" "$2")"; day="$(date +%Y-%m-%d)"; f="$dir/brief-$day.md"
  mkdir -p "$dir"
  while [ -e "$f" ]; do n=$((n + 1)); f="$dir/brief-$day-$n.md"; done
  cp "$3" "$f" && printf '%s\n' "$f"
}
# topic_words : texte sur stdin → mots significatifs, un par ligne, triés et uniques : accents retirés et minuscules (« État » et
# « état » se recoupent), 4 lettres au moins, hors mots vides — le recoupement d'un couloir neuf avec les fiches à plat ne doit pas
# tirer sur « avec », « pour », « été » ou « projet » (revue du lot 18 : les octets d'un accent comptaient comme des lettres)
TOPIC_STOP_WORDS=' avec dans pour plus sans sous etre fait faire cette comme tout tous toute toutes leur leurs elle elles nous vous sont mais donc alors aussi entre depuis apres avant chaque encore meme tres peut lots fiche fiches couloir couloirs projet projets brief objectif titre that this with from into have will your '
topic_words() {
  # une substitution par caractère, jamais une classe entre crochets : en locale C, [é] comparerait des octets
  LC_ALL=C sed 's/à/a/g;s/â/a/g;s/ä/a/g;s/á/a/g;s/ã/a/g;s/À/a/g;s/Â/a/g;s/Ä/a/g;s/Á/a/g;s/Ã/a/g;s/ç/c/g;s/Ç/c/g;s/é/e/g;s/è/e/g;s/ê/e/g;s/ë/e/g;s/É/e/g;s/È/e/g;s/Ê/e/g;s/Ë/e/g;s/î/i/g;s/ï/i/g;s/í/i/g;s/Î/i/g;s/Ï/i/g;s/Í/i/g;s/ô/o/g;s/ö/o/g;s/ó/o/g;s/õ/o/g;s/Ô/o/g;s/Ö/o/g;s/Ó/o/g;s/Õ/o/g;s/ù/u/g;s/û/u/g;s/ü/u/g;s/ú/u/g;s/Ù/u/g;s/Û/u/g;s/Ü/u/g;s/Ú/u/g;s/ÿ/y/g;s/Ÿ/y/g;s/ñ/n/g;s/Ñ/n/g;s/œ/oe/g;s/Œ/oe/g;s/æ/ae/g;s/Æ/ae/g' |
  LC_ALL=C awk -v stop="$TOPIC_STOP_WORDS" '
    { l = tolower($0); gsub(/[^a-z0-9]+/, " ", l); n = split(l, w, " ")
      for (i = 1; i <= n; i++) if (length(w[i]) >= 4 && index(stop, " " w[i] " ") == 0) print w[i] }' | LC_ALL=C sort -u
}
# flat_lots_overlap <docs> <texte du sujet> → fiches à plat (lots/lot-NN-*.md, ancien emplacement) dont le slug ou le titre partage
# un mot significatif avec le sujet ; une par ligne, nom seul. Rien n'est déplacé : l'agent qui planifie les lit (décision 4, lot 18).
flat_lots_overlap() {
  local words f own
  words="$(printf '%s\n' "$2" | topic_words)"; [ -n "$words" ] || return 0
  for f in "$(lots_dir "$1")"/lot-[0-9]*.md; do
    [ -f "$f" ] || continue
    own="$( { basename "$f" .md | sed 's/^lot-[0-9]*-//; s/[-_.]/ /g'; lot_title_of "$f"; } | topic_words)"
    [ -z "$(LC_ALL=C comm -12 <(printf '%s\n' "$words") <(printf '%s\n' "$own"))" ] || basename "$f"
  done
  return 0
}
# lane_topic <wt> [titre] → le sujet d'un couloir : son nom, le titre de sa première fiche (ou celui donné) et son brief
# shellcheck disable=SC2012
lane_topic() {
  local docs lane first brief
  docs="$(docs_dir "$1")"; lane="$(wt_lane "$1")"
  printf '%s\n' "$lane" | tr '-' ' '
  if [ -n "${2:-}" ]; then printf '%s\n' "$2"
  else first="$(ls "$(lots_dir "$docs" "$lane")"/lot-[0-9]*.md 2>/dev/null | sort | head -1 || true)"; [ -z "$first" ] || lot_title_of "$first"; fi
  brief="$(lane_brief "$docs" "$lane")"; [ -z "$brief" ] || cat "$brief"
}
