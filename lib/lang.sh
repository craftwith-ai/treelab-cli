# shellcheck shell=bash
# lang.sh — langue de l'agent et lecture bilingue des documents (lot 01 du couloir anglais).
# Les fiches, Reprises, treeplans et recettes s'écrivent en français ou en anglais. Une seule table ci-dessous : à la lecture,
# lang_norm ramène les marqueurs anglais (titres de section, champs, valeurs) à la valeur interne française, si bien qu'aucune
# comparaison existante ne change et qu'aucun lecteur ne code ses propres alternatives. À l'écriture, la langue se lit sur les
# marqueurs du document lui-même (lang_doc_of) : aucun état caché, un document n'est jamais converti.

# lab_lang_detect → code ISO à deux lettres : LAB_LANG, puis la première langue du Mac (defaults read -g AppleLanguages), puis
# LC_ALL, LC_MESSAGES, LANG ; « en » sans aucune source. defaults absent ou en échec : repli silencieux. Toujours rc 0.
# Une valeur ne compte que si elle commence par deux lettres suivies de _ . @ - ou de rien : « C » et « POSIX » ne sont pas des langues.
lab_lang_detect() {
  local v code
  for v in "${LAB_LANG:-}" \
    "$( { defaults read -g AppleLanguages 2>/dev/null || true; } | sed -n 's/^[[:space:]]*"\{0,1\}\([A-Za-z][A-Za-z]\).*/\1/p' | head -1)" \
    "${LC_ALL:-}" "${LC_MESSAGES:-}" "${LANG:-}"; do
    case "$v" in [A-Za-z][A-Za-z]|[A-Za-z][A-Za-z][_.@-]*) ;; *) continue ;; esac
    code="$(printf '%s' "$v" | cut -c1-2 | tr '[:upper:]' '[:lower:]')"
    printf '%s\n' "$code"; return 0
  done
  printf 'en\n'
}

# ---------- table unique : forme anglaise → valeur interne française ----------
LANG_SECTIONS_EN='Goal|Exit criteria|Steps|Waiting|Log|Handoff|Lane acceptance|Batches'
LANG_FIELDS_EN='State|Execution|Next batch|Intent|Branch|Created|Decision|Tried revision|Docs revision|Evidence|Validated by|Tests removed|Night red agreement'
LANG_VALUES_EN='planned|in progress|waiting|closed|none|accepted|rejected'
lang_fr_set() { # <terme anglais> : LANG_FR, le terme interne français, sans sous-shell ; rc 1, vide, si le terme n'est pas dans la table
  case "$1" in
    Goal) LANG_FR=Objectif ;; 'Exit criteria') LANG_FR='Critères de fin' ;; Steps) LANG_FR=Étapes ;; Waiting) LANG_FR='En attente' ;; Log) LANG_FR=Journal ;; Handoff) LANG_FR=Reprise ;;
    'Lane acceptance') LANG_FR='Recette du couloir' ;; Batches) LANG_FR=Lots ;; Batch) LANG_FR=Lot ;;
    State) LANG_FR=État ;; Execution) LANG_FR=Exécution ;; 'Next batch') LANG_FR='Prochain lot' ;; Intent) LANG_FR=Intention ;; Branch) LANG_FR=Branche ;; Created) LANG_FR=Créé ;;
    Decision) LANG_FR=Décision ;; Date) LANG_FR=Date ;; 'Tried revision') LANG_FR='Révision essayée' ;; 'Docs revision') LANG_FR='Révision des documents' ;;
    Evidence) LANG_FR=Preuves ;; 'Validated by') LANG_FR='Validé par' ;; 'Tests removed') LANG_FR='Tests retirés' ;; 'Night red agreement') LANG_FR='Accord nuit rouge' ;;
    planned) LANG_FR=planifié ;; 'in progress') LANG_FR='en cours' ;; waiting) LANG_FR='en attente' ;; closed) LANG_FR=clos ;; none) LANG_FR=aucun ;;
    accepted) LANG_FR=validée ;; rejected) LANG_FR=refusée ;;
    *) LANG_FR=''; return 1 ;;
  esac
}
lang_fr() { lang_fr_set "$1" && printf '%s\n' "$LANG_FR"; }   # le même terme, sur stdout
# lang_en <terme interne> → sa forme anglaise (le terme lui-même s'il n'est pas dans la table)
lang_en() {
  local t; local IFS='|'
  for t in $LANG_SECTIONS_EN Batch $LANG_FIELDS_EN $LANG_VALUES_EN; do lang_fr_set "$t" || true; [ "$LANG_FR" != "$1" ] || { printf '%s\n' "$t"; return 0; }; done
  printf '%s\n' "$1"
}
# lang_word <langue> <terme interne> → le terme dans la langue d'un document (en ou fr)
lang_word() { if [ "$1" = en ]; then lang_en "$2"; else printf '%s\n' "$2"; fi; }
# lang_value <langue> <valeur canonique anglaise> : la valeur écrite dans un document, suffixe conservé (« closed (2026-10-13) »
# → « clos (2026-10-13) » dans une fiche française). Depuis le lot 09, les valeurs que lab manipule sont anglaises : seule
# l'écriture dans une fiche française repasse par la colonne française de la table.
lang_value() {
  local w
  [ "$1" = fr ] || { printf '%s\n' "$2"; return 0; }
  for w in 'in progress' planned waiting closed none accepted rejected; do
    case "$2" in "$w"|"$w"[!A-Za-z0-9]*) printf '%s%s\n' "$(lang_fr "$w")" "${2#"$w"}"; return 0 ;; esac
  done
  printf '%s\n' "$2"
}
# lang_pairs_set <liste anglaise> : LANG_PAIRS, « anglais<TAB>français » par ligne, pour awk ; calculées une fois au chargement, sans
# sous-shell — ce fichier est chargé à chaque commande lab, la trentaine d'alors s'y payait à chaque fois (lot 01 de charge-processeur)
lang_pairs_set() {
  local t; local IFS='|'
  LANG_PAIRS=''
  for t in $1; do lang_fr_set "$t" || true; LANG_PAIRS="$LANG_PAIRS${LANG_PAIRS:+$'\n'}$t"$'\t'"$LANG_FR"; done
}
lang_pairs() { lang_pairs_set "$1"; printf '%s\n' "$LANG_PAIRS"; }
lang_pairs_set "$LANG_SECTIONS_EN"; LANG_PAIRS_S="$LANG_PAIRS"
lang_pairs_set "$LANG_FIELDS_EN"; LANG_PAIRS_F="$LANG_PAIRS"
lang_pairs_set "$LANG_VALUES_EN"; LANG_PAIRS_V="$LANG_PAIRS"

# lang_norm [norm|detect] : document sur stdin. norm (défaut) recopie chaque ligne, marqueurs anglais ramenés à la valeur interne
# (« ## Handoff » → « ## Reprise », « **State** : closed » → « **État** : clos », « # Batch 3 — » → « # Lot 3 — ») ; le nombre
# de lignes ne change jamais. detect imprime la langue du premier marqueur reconnu — en ou fr, fr sans marqueur.
# Champs en gras, casse et puce tolérées ; sans gras, seuls État et Tests retirés (leurs lecteurs le toléraient déjà) : une ligne
# de journal « - Branch: … » reste du texte.
# LANG_AWK : les règles elles-mêmes, en fonctions awk (lang_init, puis lang_line pour chaque ligne) — une seule copie, pour lang_norm et
# pour la lecture groupée des fiches (lib/reads.sh). lang_line rend la ligne lue et pose LANG_HIT (en ou fr, vide sans marqueur) ;
# detect=1 : la langue seule compte, les champs en milieu de ligne ne sont pas ramenés
# shellcheck disable=SC2016 # programme awk, rien à développer
LANG_AWK='
function lang_load(s, M, R,   n, i, a, kv) { n = split(s, a, "\n"); for (i = 1; i <= n; i++) if (split(a[i], kv, "\t") == 2) { M[kv[1]] = kv[2]; R[kv[2]] = 1 } }
function lang_init(   k) {
  lang_load(ENVIRON["LANG_S"], LG_S, LG_SF); lang_load(ENVIRON["LANG_F"], LG_F0, LG_FF); lang_load(ENVIRON["LANG_V"], LG_V0, LG_VF)
  for (k in LG_F0) LG_F[tolower(k)] = LG_F0[k]; for (k in LG_FF) LG_FFL[tolower(k)] = 1; for (k in LG_V0) LG_V[tolower(k)] = LG_V0[k]
}
function lang_nbsp(s) { gsub(/\302\240|\342\200\257|\342\200\211/, " ", s); return s }
function lang_found(l) { if (LANG_HIT == "") LANG_HIT = l }
function lang_line(line, detect,   pre, rest, k, sp, head, tail, word, lw, bold, fr, p, v, q, r) {
  LANG_HIT = ""
  if (match(line, /^## +/)) {
    pre = substr(line, 1, RLENGTH); rest = substr(line, RLENGTH + 1)
    for (k in LG_S) if (index(rest, k) == 1 && substr(rest, length(k) + 1, 1) !~ /[A-Za-z]/) { lang_found("en"); line = pre LG_S[k] substr(rest, length(k) + 1); break }
    for (k in LG_SF) if (index(rest, k) == 1 && substr(rest, length(k) + 1, 1) !~ /[A-Za-z]/) lang_found("fr")
  } else if (match(line, /^# Batch [0-9]/)) { lang_found("en"); line = "# Lot " substr(line, 9) }
  else if (line ~ /^# Lot [0-9]/) lang_found("fr")
  else if (match(sp = lang_nbsp(line), /^[ \t]*([-*+][ \t]+)?(\*\*|__)?[^*_:]+(\*\*|__)?[ \t]*:/)) {
    head = substr(sp, 1, RLENGTH); tail = substr(sp, RLENGTH + 1)   # espaces insécables lus comme espaces (lot_state_check)
    word = head; sub(/^[ \t]*([-*+][ \t]+)?(\*\*|__)?/, "", word); sub(/(\*\*|__)?[ \t]*:$/, "", word); sub(/[ \t]+$/, "", word)
    lw = tolower(word); bold = (head ~ /^[ \t]*([-*+][ \t]+)?(\*\*|__)/)
    if ((lw in LG_F) && !bold && lw != "state" && lw != "tests removed") lw = ""   # sans gras : seuls État et Tests retirés sont des champs
    if (lw in LG_F) {
      # la ligne lue ne perd que le mot du champ et la valeur : ses espaces, insécables compris, restent
      lang_found("en"); fr = LG_F[lw]; p = index(line, word); line = substr(line, 1, p - 1) fr substr(line, p + length(word))
      if (fr == "\303\211tat" || fr == "D\303\251cision" || fr == "Prochain lot") {
        match(tail, /^[ \t]*(\*\*|__)?[ \t]*/); v = substr(tail, RLENGTH + 1)
        # waiting : valeur du seul champ État ; un slug waiting-list du Prochain lot reste tel quel (revue, lot 02 autonomie-tours)
        for (k in LG_V) if ((k != "waiting" || fr == "\303\211tat") && index(tolower(v), k) == 1 && substr(v, length(k) + 1, 1) !~ /[A-Za-z0-9]/) {
          q = p + length(fr); rest = substr(line, q); r = index(tolower(rest), k)
          if (r) line = substr(line, 1, q + r - 2) LG_V[k] substr(rest, r + length(k))
          break
        }
      }
    } else if (lw in LG_FFL || lw == "\303\251tat" || lw == "etat" || lw == "\303\211tat") lang_found("fr")
  }
  # champ en gras en milieu de ligne, ainsi « **Created** » après « · » : seul le marqueur change
  if (!detect && index(line, "**")) for (k in LG_F0) while ((p = index(line, "**" k "**")) > 0) line = substr(line, 1, p + 1) LG_F0[k] substr(line, p + 2 + length(k))
  return line
}
'
lang_norm() {   # un lecteur qui sort tôt (awk exit, head) ferme le tube : SIGPIPE (141) n'est pas une panne sous pipefail
  local rc=0
  LC_ALL=C LANG_S="$LANG_PAIRS_S" LANG_F="$LANG_PAIRS_F" LANG_V="$LANG_PAIRS_V" \
  awk -v mode="${1:-norm}" "$LANG_AWK"'
    BEGIN { lang_init(); detect = (mode == "detect") }
    {
      line = lang_line($0, detect)
      if (!detect) print line
      else if (LANG_HIT != "") { print LANG_HIT; done = 1; exit }
    }
    END { if (detect && !done) print "fr" }' || rc=$?
  [ "$rc" -ne 141 ] || rc=0; return "$rc"
}
# ---------- table unique des valeurs KEY=value : ancien mot français → mot anglais (lot 09 du couloir anglais) ----------
# bin/lab et lib/ n'écrivent plus que la colonne anglaise, sur stdout comme sur disque. Un état posé par un lab d'avant le lot 09
# porte encore la colonne française : lang_code la traduit à la lecture (veilleur, marqueur Cloud, échéances, registre en ligne,
# .lab/correction, état de fiche). Ni migration ni double écriture : la colonne française n'est jamais réécrite, seulement lue.
# Un mot absent de la table ressort tel quel : lang_code se pose sans risque sur une valeur déjà anglaise ou sur une donnée libre.
lang_code() { lang_code_set "$1"; printf '%s\n' "$LANG_CODE"; }
lang_code_set() { # <valeur> : LANG_CODE, sa forme anglaise, sans processus
  case "$1" in
    'armé'|'armée') LANG_CODE=armed ;;
    'attente'|'en attente') LANG_CODE=waiting ;;
    'mort') LANG_CODE=dead ;;
    'vivant'|'vivante') LANG_CODE=alive ;;
    'incertain') LANG_CODE=uncertain ;;
    'libre') LANG_CODE=free ;;
    'fini') LANG_CODE=finished ;;
    'attente-pause') LANG_CODE=idle-paused ;;
    'repris') LANG_CODE=resumed ;;
    'relance') LANG_CODE=restarted ;;
    'fusionné'|'fusionnée'|'mergée') LANG_CODE=merged ;;
    'non fusionnée'|'non mergée') LANG_CODE=not-merged ;;
    'fermé') LANG_CODE=closed ;;
    'clos') LANG_CODE=closed ;;
    'rouge') LANG_CODE=red ;;
    'conflit') LANG_CODE=conflict ;;
    'sync-conflit') LANG_CODE=sync-conflict ;;
    'stack-conflit') LANG_CODE=stack-conflict ;;
    'changée') LANG_CODE=changed ;;
    'échec') LANG_CODE=failed ;;
    'retiré'|'retirée') LANG_CODE=removed ;;
    'ajouté') LANG_CODE=added ;;
    'lancé') LANG_CODE=started ;;
    'libérée') LANG_CODE=released ;;
    'prête') LANG_CODE=ready ;;
    'en file') LANG_CODE=queued ;;
    'à-jour') LANG_CODE=up-to-date ;;
    'ignorée') LANG_CODE=ignored ;;
    'bloquée') LANG_CODE=blocked ;;
    'présentation') LANG_CODE=preview ;;
    'rien'|'aucun'|'aucune') LANG_CODE=none ;;
    'non vérifiable') LANG_CODE=not-checkable ;;
    'vérifiable') LANG_CODE=checkable ;;
    'planifié') LANG_CODE=planned ;;
    'en cours') LANG_CODE='in progress' ;;
    'prévu'|'à venir') LANG_CODE=upcoming ;;
    'retard') LANG_CODE=late ;;
    'à clarifier') LANG_CODE='to clarify' ;;
    'travail') LANG_CODE=work ;;
    'en recette') LANG_CODE='in acceptance' ;;
    'recette validée') LANG_CODE='acceptance passed' ;;
    'HEAD-détachée') LANG_CODE=detached-HEAD ;;
    'déjà') LANG_CODE=already ;;
    'nouveau') LANG_CODE=new ;;
    'inconnu') LANG_CODE=unknown ;;
    'oui') LANG_CODE=yes ;;
    'non') LANG_CODE=no ;;
    'sans commit') LANG_CODE='no commit' ;;
    'rangé') LANG_CODE=stored ;;
    'déjà-importé') LANG_CODE=already-imported ;;
    'à-importer') LANG_CODE=to-import ;;
    'défaut') LANG_CODE=default ;;
    'référence') LANG_CODE=reference ;;
    'nom') LANG_CODE=name ;;
    'épuisé') LANG_CODE=exhausted ;;
    'semé') LANG_CODE=seeded ;;
    'valable') LANG_CODE=valid ;;
    'périmée') LANG_CODE=expired ;;
    'inscrite') LANG_CODE=recorded ;;
    'déployée') LANG_CODE=deployed ;;
    'ouverte') LANG_CODE=open ;;
    'faite') LANG_CODE='done' ;;
    'annulée') LANG_CODE=cancelled ;;
    'redatée') LANG_CODE=rescheduled ;;
    'validée') LANG_CODE=accepted ;;
    'refusée') LANG_CODE=rejected ;;
    'hors-couloir') LANG_CODE=outside-lane ;;
    'checkout-principal') LANG_CODE=main-checkout ;;
    'copie') LANG_CODE=copy ;;   # manifeste de preuves d'avant le lot 09
    *) LANG_CODE="$1" ;;
  esac
}
# lang_code_prefix <valeur> : lang_code sur le premier mot d'une valeur suffixée (« fusionnée : lab deploy x » → « merged : lab
# deploy x ») ; sans préfixe connu, la valeur entière passe par lang_code.
LANG_CODE_PREFIXES="non fusionnée|non mergée|en cours|en attente|en file|à clarifier|à venir|sans commit|non vérifiable|fusionnée|planifié|validée|refusée|ouverte|faite|annulée|armé|armée|échec|clos|retard"
lang_code_prefix() { lang_code_prefix_set "$1"; printf '%s\n' "$LANG_CODE"; }
lang_code_prefix_set() { # <valeur> : LANG_CODE, la même, sans processus
  local w; local IFS='|'
  for w in $LANG_CODE_PREFIXES; do
    case "$1" in "$w"[!A-Za-z]*) lang_code_set "$w"; LANG_CODE="$LANG_CODE${1#"$w"}"; return 0 ;; esac
  done
  lang_code_set "$1"
}
# lang_doc_of <fichier> → en | fr : la langue lue sur les marqueurs du document ; fr pour un document absent ou sans marqueur
lang_doc_of() { if [ -f "${1:-}" ] && [ -r "$1" ]; then lang_norm detect <"$1"; else printf 'fr\n'; fi; }
# lang_section_re <titre interne> → « titre|forme anglaise », pour un écrivain qui cherche la section dans le texte brut
lang_section_re() { local en; en="$(lang_en "$1")"; if [ "$en" = "$1" ]; then printf '%s\n' "$1"; else printf '%s|%s\n' "$1" "$en"; fi; }
