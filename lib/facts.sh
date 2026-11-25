# shellcheck shell=bash
# shellcheck disable=SC2034 # DOC_FACT et les faits lus servent lib/docs.sh, lib/waiting.sh et lib/recette.sh
# facts.sh — les faits des fiches et des treeplans, lus en une fois (lot 02 de charge-processeur). Chaque valeur lue dans une fiche
# coûtait un à trois programmes, et lab plan en lançait plus de mille ; un seul awk lit maintenant tous les documents demandés.
# DOC_AWK : les règles de lecture, une seule copie — la lecture groupée d'ici et les lecteurs d'une seule fiche (lib/docs.sh,
# lib/waiting.sh, lib/recette.sh) passent par les mêmes fonctions awk, à la suite de lang_line (lib/lang.sh).
# Les faits ne survivent jamais à une lecture : hors de facts_begin … facts_end, chaque demande relit son document.
declare -F lang_norm >/dev/null || . "${BASH_SOURCE[0]%/*}/lang.sh"
[ -n "${RDV_AWK:-}" ] || . "${BASH_SOURCE[0]%/*}/rdv.sh"

# Toutes les lignes données à ces fonctions sont déjà passées par lang_line (marqueurs ramenés à la valeur interne française)
# lot_state_scan(ligne, n°) → 1 quand l'État est tranché : ST_VERDICT (ok | variante | inconnue | absente), ST_N, ST_V (valeur), ST_RAW
# wait_scan(ligne) → « Cn<TAB>date<TAB>motif<TAB>reports<TAB>measured<TAB>reopened » pour une ligne d'attente, vide sinon
# recette_scan(ligne) → 2 titre de la section de recette (RC_COUNT), 1 borne d'un bloc de code, 0 ligne ordinaire ; RC_IN, RC_FENCE
# recette_field_scan(ligne, clé) → 1 et RF_V, la valeur, pour la ligne du champ « **clé** »
#   espaces de la recette : [[:space:]] et l'insécable U+00A0, comme l'awk du Mac en UTF-8 — toujours lues sous LC_ALL=C (CI de #239)
# reprise_scan(ligne) → 1 dans la section Reprise ; plan_scan(ligne) → 1 pour une ligne de la section Lots du treeplan
# plan_complete_scan(ligne), puis plan_complete() → 1 si la liste des lots se lit en entier
# shellcheck disable=SC2016 # programme awk, rien à développer
DOC_AWK='
function lot_state_reset() { ST_FENCE = 0; ST_VERDICT = "absente"; ST_N = ""; ST_V = ""; ST_RAW = "" }
function lot_state_scan(line, nr,   l, v, t) {
  sub(/\r$/, "", line)
  if (line ~ /^[ \t]*(```|~~~)/) { ST_FENCE = !ST_FENCE; return 0 }
  if (ST_FENCE) return 0
  if (line ~ /^## +(Objectif|Journal|Reprise)/) return 1
  l = line; gsub(/\302\240|\342\200\257|\342\200\211|\t/, " ", l)
  if (!match(l, /^ *([-*+] +)?(\*\*|__)?(\303\211|\303\251|E|e)[Tt][Aa][Tt] *(\*\*|__)? *: *(\*\*|__)? */)) return 0
  v = substr(l, RSTART + RLENGTH); sub(/ +$/, "", v)
  t = v; if (gsub(/\*\*/, "", t) % 2) sub(/ *\*\*$/, "", v)
  t = v; if (gsub(/__/, "", t) % 2) sub(/ *__$/, "", v)
  if (v !~ /^(planifi\303\251|en cours|en attente|clos)([^A-Za-z0-9\200-\377]|$)/) ST_VERDICT = "inconnue"
  else if (line == "**\303\211tat** : " v) ST_VERDICT = "ok"
  else ST_VERDICT = "variante"
  ST_N = nr; ST_V = v; ST_RAW = line
  return 1
}
function wait_reset() { WT_FENCE = 0; WT_IN = 0 }
function wait_scan(line,   n, a, id, rep, meas, reo, i) {
  sub(/\r$/, "", line)
  if (line ~ /^[ \t]*(```|~~~)/) { WT_FENCE = !WT_FENCE; return "" }
  if (WT_FENCE) return ""
  if (line ~ /^## /) { WT_IN = (line ~ /^## +En attente[ \t]*$/); return "" }
  if (!WT_IN || line !~ /^- C[0-9]+ \302\267 /) return ""
  n = split(line, a, / \302\267 /); id = substr(a[1], 3); rep = 0; meas = ""; reo = ""
  for (i = 4; i <= n; i++) {
    if (a[i] ~ /^reports [0-9]+$/) rep = substr(a[i], 9) + 0
    else if (a[i] ~ /^measured /) meas = substr(a[i], 10)
    else if (a[i] ~ /^reopened /) reo = substr(a[i], 10)
  }
  return sprintf("%s\t%s\t%s\t%d\t%s\t%s", id, a[2], a[3], rep, meas, reo)
}
function recette_reset() { RC_FENCE = 0; RC_IN = 0; RC_COUNT = 0 }
function recette_scan(line) {
  if (line ~ /^([[:space:]]|\302\240)*(```|~~~)/) { RC_FENCE = !RC_FENCE; return 1 }
  if (!RC_FENCE && line ~ /^## Recette du couloir([[:space:]]|\302\240)*$/) { RC_IN = 1; RC_COUNT++; return 2 }
  if (!RC_FENCE && line ~ /^## /) RC_IN = 0
  return 0
}
function recette_field_scan(line, key,   v) {
  if (index(line, key) != 1) return 0
  v = substr(line, length(key) + 1)
  if (v !~ /^([[:space:]]|\302\240)*:/) return 0
  sub(/^([[:space:]]|\302\240)*:([[:space:]]|\302\240)*/, "", v); sub(/([[:space:]]|\302\240)*$/, "", v)
  RF_V = v
  return 1
}
function reprise_reset() { RP_IN = 0; RP_END = 0 }
function reprise_scan(line) {
  if (RP_END) return 0
  if (line ~ /^## Reprise/) RP_IN = 1
  if (RP_IN && line ~ /^## / && line !~ /^## Reprise/) { RP_END = 1; return 0 }
  return RP_IN
}
function plan_reset() { PL_IN = 0; PL_END = 0; PC_IN = 0; PC_SECTIONS = 0; PC_BAD = 0 }
function plan_scan(line) {
  if (PL_END) return 0
  if (line ~ /^## Lots([[:space:]]|$)/) { PL_IN = 1; return 0 }
  if (PL_IN && line ~ /^## /) { PL_END = 1; return 0 }
  return PL_IN
}
function plan_complete_scan(line) {
  if (line ~ /^## Lots([[:space:]]|$)/) { PC_IN = 1; PC_SECTIONS++; return }
  if (PC_IN && line ~ /^## /) PC_IN = 0
  if (PC_IN && line ~ /^[[:space:]]*([-*+][[:space:]]|[0-9]+[.)][[:space:]])/ && line !~ /^- \[lot-[0-9]+-[a-z0-9][a-z0-9._-]*\]\([^)]*\)/) PC_BAD = 1
}
function plan_complete() { return (PC_SECTIONS == 1 && !PC_BAD) }
'
# FACTS_AWK : un enregistrement par document demandé (« F<TAB>fiche », « S<TAB>fiche » ou « T<TAB>treeplan » sur l'entrée), champs
# séparés par 0x1F, plusieurs valeurs d'un champ par 0x1E. S : la fiche jusqu'à son État seulement, son titre s'il est plus haut. Fiche : F, chemin, valeur de l'État, suites de la ligne de titre « # Lot NN », section Reprise
# présente (1|0), ligne « Prochain lot », attentes ouvertes (epoch, Cn, date, motif, reports, reopened), nombre de sections de
# recette, puis ses champs lisibles une seule fois : Décision, Date, Révision essayée, Preuves, Révision des documents.
# Treeplan : T, chemin, lignes de lots, intention, liste lisible en entier (1|0)
# shellcheck disable=SC2016 # programme awk, rien à développer
FACTS_AWK='
function add(list, v) { return (list == "" ? v : list "\036" v) }
function fhead(f,   raw, n, l, sdone, title) {
  lot_state_reset(); n = 0; sdone = 0; title = ""
  while (!sdone && (getline raw < f) > 0) {
    n++; l = lang_line(raw, 0); sdone = lot_state_scan(l, n)
    if (match(l, /^# Lot [0-9][0-9]*/)) title = add(title, substr(l, RLENGTH + 1))
  }
  close(f)
  printf "S\037%s\037%s\037%s\n", f, ST_V, title
}
function fiche(f,   raw, n, l, sdone, title, rep, next_, nseen, waits, w, c, e, i, key, cnt, val) {
  lot_state_reset(); wait_reset(); recette_reset(); reprise_reset(); n = 0; sdone = 0; title = ""; rep = 0; next_ = ""; nseen = 0; waits = ""
  for (i = 1; i <= NK; i++) { cnt[i] = 0; val[i] = "" }
  while ((getline raw < f) > 0) {
    n++; l = lang_line(raw, 0)
    if (!sdone) sdone = lot_state_scan(l, n)
    if (match(l, /^# Lot [0-9][0-9]*/)) title = add(title, substr(l, RLENGTH + 1))
    if (reprise_scan(l)) {
      rep = 1
      if (!nseen) { w = lang_line(l, 0); if (match(w, /^\*\*Prochain lot\*\* *: */)) { next_ = substr(w, RLENGTH + 1); nseen = 1 } }
    }
    w = wait_scan(l)
    if (w != "") { split(w, c, "\t"); if (c[5] == "") { e = epoch(c[2]); if (e != "invalide") waits = add(waits, sprintf("%.0f\t%s\t%s\t%s\t%s\t%s", e, c[1], c[2], c[3], c[4], c[6])) } }
    if (recette_scan(l) == 0 && RC_IN && !RC_FENCE) for (i = 1; i <= NK; i++) if (recette_field_scan(l, KEY[i])) { cnt[i]++; val[i] = RF_V }
  }
  close(f)
  printf "F\037%s\037%s\037%s\037%d\037%s\037%s\037%d", f, ST_V, title, rep, next_, waits, RC_COUNT
  for (i = 1; i <= NK; i++) printf "\037%s", (cnt[i] == 1 ? val[i] : "")
  printf "\n"
}
function treeplan(f,   raw, l, lots, intent, iseen) {
  plan_reset(); lots = ""; intent = ""; iseen = 0
  while ((getline raw < f) > 0) {
    l = lang_line(raw, 0)
    if (plan_scan(l) && index(l, "- [lot-") == 1) lots = add(lots, l)
    plan_complete_scan(l)
    if (!iseen && match(l, /^\*\*Intention\*\* *: */)) { intent = substr(l, RLENGTH + 1); iseen = 1 }
  }
  close(f)
  if (index(intent, "<!--") == 1) intent = ""
  printf "T\037%s\037%s\037%s\037%d\n", f, lots, intent, plan_complete()
}
BEGIN {
  lang_init(); NK = split("Décision|Date|Révision essayée|Preuves|Révision des documents", KEY, "|")
  for (i = 1; i <= NK; i++) KEY[i] = "**" KEY[i] "**"
}
{ k = substr($0, 1, 2); if (k == "T\t") treeplan(substr($0, 3)); else if (k == "F\t") fiche(substr($0, 3)); else if (k == "S\t") fhead(substr($0, 3)) }'

# ---------- faits lus : un rang par document, une variable par fait (DF_<fait>_<rang>) ----------
DF_N=0 DF_CUR=0 DF_CURT=0 FACTS_DEPTH=0   # jamais hérités de l'environnement
# facts_begin : les documents lus d'ici à facts_end ne sont lus qu'une fois — le temps d'une lecture, jamais d'une commande qui écrit
facts_begin() { [ "$FACTS_DEPTH" != 0 ] || facts_forget; FACTS_DEPTH=$((FACTS_DEPTH + 1)); }
facts_end() { FACTS_DEPTH=$((FACTS_DEPTH - 1)); [ "$FACTS_DEPTH" != 0 ] || facts_forget; }
facts_forget() { DF_N=0; DF_CUR=0; DF_CURT=0; WL_FOR=''; WF_FOR=''; }
FACTS_LOT_RE='^- \[(lot-[0-9][0-9]*[^]]*)\]\([^)]*\)[[:space:]]*—*[[:space:]]*(.*)$'
# facts_load <liste> : lignes « F<TAB>fiche », « S<TAB>fiche » et « T<TAB>treeplan » (documents lisibles) → leurs faits, un seul awk. Les motifs qui
# dépendent de la langue du terminal (espaces, tiret long) sont lus par le shell, comme sed les lisait
facts_load() {
  local out kind f a b c d e g h i j k l line n="$DF_N" lots
  [ -n "$1" ] || return 0
  out="$(LC_ALL=C LANG_S="$LANG_PAIRS_S" LANG_F="$LANG_PAIRS_F" LANG_V="$LANG_PAIRS_V" exec awk "$LANG_AWK$RDV_AWK$DOC_AWK$FACTS_AWK" <<<"$1")" || return 1
  while IFS=$'\037' read -r kind f a b c d e g h i j k l; do
    case "$kind" in
      S)
        printf -v "DF_F_$n" '%s' "$f"; printf -v "DF_KIND_$n" '%s' S; printf -v "DF_STATE_$n" '%s' "$a"; printf -v "DF_TITLE_$n" '%s' "${b//$'\036'/$'\n'}"
        n=$((n + 1)) ;;
      F)
        printf -v "DF_F_$n" '%s' "$f"; printf -v "DF_KIND_$n" '%s' F; printf -v "DF_STATE_$n" '%s' "$a"; printf -v "DF_TITLE_$n" '%s' "${b//$'\036'/$'\n'}"; printf -v "DF_REPRISE_$n" '%s' "$c"
        printf -v "DF_NEXT_$n" '%s' "$d"; printf -v "DF_WAITS_$n" '%s' "${e//$'\036'/$'\n'}"; printf -v "DF_RECETTES_$n" '%s' "$g"
        printf -v "DF_DECISION_$n" '%s' "$h"; printf -v "DF_DATE_$n" '%s' "$i"; printf -v "DF_REVISION_$n" '%s' "$j"; printf -v "DF_PREUVES_$n" '%s' "$k"; printf -v "DF_DOCS_$n" '%s' "$l"
        n=$((n + 1)) ;;
      T)
        lots=''
        if [ -n "$a" ]; then
          a="$a"$'\036'
          while [ -n "$a" ]; do
            line="${a%%$'\036'*}"; a="${a#*$'\036'}"
            if [[ "$line" =~ $FACTS_LOT_RE ]]; then lots="$lots${lots:+$'\n'}${BASH_REMATCH[1]}"$'\t'"${BASH_REMATCH[2]}"; fi
          done
        fi
        printf -v "DF_F_$n" '%s' "$f"; printf -v "DF_KIND_$n" '%s' T; printf -v "DF_LOTS_$n" '%s' "$lots"; printf -v "DF_INTENT_$n" '%s' "$b"; printf -v "DF_COMPLETE_$n" '%s' "$c"
        n=$((n + 1)) ;;
    esac
  done <<<"$out"
  DF_N="$n"
}
# doc_find <document> [T] : DOC_I, son rang, et DOC_KIND ; rc 1 s'il n'est pas lu. La recherche part du dernier trouvé — un pour les
# fiches, un pour les treeplans —, dans les deux sens : les lectures se suivent
doc_find() {
  local d=1 i j cur="$DF_CUR" v
  [ "$DF_N" -gt 0 ] || return 1
  [ "${2:-}" != T ] || cur="$DF_CURT"
  j="$cur"; v="DF_F_$j"
  if [ "${!v}" != "$1" ]; then
    while :; do
      i=$((cur + d)); j=$((cur - d))
      if [ "$i" -lt "$DF_N" ]; then v="DF_F_$i"; if [ "${!v}" = "$1" ]; then j="$i"; break; fi
      elif [ "$j" -lt 0 ]; then return 1; fi
      if [ "$j" -ge 0 ]; then v="DF_F_$j"; [ "${!v}" != "$1" ] || break; fi
      d=$((d + 1))
    done
    if [ "${2:-}" = T ]; then DF_CURT="$j"; else DF_CUR="$j"; fi
  fi
  DOC_I="$j"; v="DF_KIND_$j"; DOC_KIND="${!v}"
}
# doc_need <document> <F|S|T> : DOC_I, son rang ; lu seul s'il ne l'a pas été. Un début de fiche (S) ne suffit pas à qui veut tout (F).
# rc 1 pour un document absent ou illisible
doc_need() {
  [ -f "$1" ] && [ -r "$1" ] || return 1
  if [ "$FACTS_DEPTH" = 0 ]; then DF_N=0; DF_CUR=0; DF_CURT=0
  elif doc_find "$1" "$2"; then
    case "$DOC_KIND$2" in SF) printf -v "DF_F_$DOC_I" '%s' '' ;; *) return 0 ;; esac
  fi
  facts_load "$2"$'\t'"$1" && doc_find "$1" "$2"
}
doc_fact() { local v="DF_$1_$DOC_I"; DOC_FACT="${!v}"; }   # <fait> : DOC_FACT, le fait du document DOC_I
