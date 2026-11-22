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
lang_fr() { # <terme anglais> → terme interne français ; rc 1 si le terme n'est pas dans la table
  case "$1" in
    Goal) echo Objectif ;; 'Exit criteria') echo 'Critères de fin' ;; Steps) echo Étapes ;; Waiting) echo 'En attente' ;; Log) echo Journal ;; Handoff) echo Reprise ;;
    'Lane acceptance') echo 'Recette du couloir' ;; Batches) echo Lots ;; Batch) echo Lot ;;
    State) echo État ;; Execution) echo Exécution ;; 'Next batch') echo 'Prochain lot' ;; Intent) echo Intention ;; Branch) echo Branche ;; Created) echo Créé ;;
    Decision) echo Décision ;; Date) echo Date ;; 'Tried revision') echo 'Révision essayée' ;; 'Docs revision') echo 'Révision des documents' ;;
    Evidence) echo Preuves ;; 'Validated by') echo 'Validé par' ;; 'Tests removed') echo 'Tests retirés' ;; 'Night red agreement') echo 'Accord nuit rouge' ;;
    planned) echo planifié ;; 'in progress') echo 'en cours' ;; waiting) echo 'en attente' ;; closed) echo clos ;; none) echo aucun ;;
    accepted) echo validée ;; rejected) echo refusée ;;
    *) return 1 ;;
  esac
}
# lang_en <terme interne> → sa forme anglaise (le terme lui-même s'il n'est pas dans la table)
lang_en() {
  local t; local IFS='|'
  for t in $LANG_SECTIONS_EN Batch $LANG_FIELDS_EN $LANG_VALUES_EN; do [ "$(lang_fr "$t")" != "$1" ] || { printf '%s\n' "$t"; return 0; }; done
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
# lang_pairs <liste anglaise> → « anglais<TAB>français » par ligne, pour awk ; calculées une fois au chargement (revue : ~25
# sous-shells par lecture de fiche sinon)
lang_pairs() { local t; local IFS='|'; for t in $1; do printf '%s\t%s\n' "$t" "$(lang_fr "$t")"; done; }
LANG_PAIRS_S="$(lang_pairs "$LANG_SECTIONS_EN")"; LANG_PAIRS_F="$(lang_pairs "$LANG_FIELDS_EN")"; LANG_PAIRS_V="$(lang_pairs "$LANG_VALUES_EN")"

# lang_norm [norm|detect] : document sur stdin. norm (défaut) recopie chaque ligne, marqueurs anglais ramenés à la valeur interne
# (« ## Handoff » → « ## Reprise », « **State** : closed » → « **État** : clos », « # Batch 3 — » → « # Lot 3 — ») ; le nombre
# de lignes ne change jamais. detect imprime la langue du premier marqueur reconnu — en ou fr, fr sans marqueur.
# Champs en gras, casse et puce tolérées ; sans gras, seuls État et Tests retirés (leurs lecteurs le toléraient déjà) : une ligne
# de journal « - Branch: … » reste du texte.
lang_norm() {   # un lecteur qui sort tôt (awk exit, head) ferme le tube : SIGPIPE (141) n'est pas une panne sous pipefail
  local rc=0
  LC_ALL=C LANG_S="$LANG_PAIRS_S" LANG_F="$LANG_PAIRS_F" LANG_V="$LANG_PAIRS_V" \
  awk -v mode="${1:-norm}" '
    function load(s, M, R,   n, i, a, kv) { n = split(s, a, "\n"); for (i = 1; i <= n; i++) if (split(a[i], kv, "\t") == 2) { M[kv[1]] = kv[2]; R[kv[2]] = 1 } }
    function lower(s) { return tolower(s) }
    function nbsp(s) { gsub(/\302\240|\342\200\257|\342\200\211/, " ", s); return s }
    function found(l) { if (mode == "detect") { print l; done = 1; exit } }
    BEGIN {
      load(ENVIRON["LANG_S"], S, SF); load(ENVIRON["LANG_F"], F0, FF); load(ENVIRON["LANG_V"], V0, VF)
      for (k in F0) F[lower(k)] = F0[k]; for (k in FF) FFL[lower(k)] = 1; for (k in V0) V[lower(k)] = V0[k]
    }
    {
      line = $0
      if (match(line, /^## +/)) {
        pre = substr(line, 1, RLENGTH); rest = substr(line, RLENGTH + 1)
        for (k in S) if (index(rest, k) == 1 && substr(rest, length(k) + 1, 1) !~ /[A-Za-z]/) { found("en"); line = pre S[k] substr(rest, length(k) + 1); break }
        for (k in SF) if (index(rest, k) == 1 && substr(rest, length(k) + 1, 1) !~ /[A-Za-z]/) found("fr")
      } else if (match(line, /^# Batch [0-9]/)) { found("en"); line = "# Lot " substr(line, 9) }
      else if (line ~ /^# Lot [0-9]/) found("fr")
      else if (match(sp = nbsp(line), /^[ \t]*([-*+][ \t]+)?(\*\*|__)?[^*_:]+(\*\*|__)?[ \t]*:/)) {
        head = substr(sp, 1, RLENGTH); tail = substr(sp, RLENGTH + 1)   # espaces insécables lus comme espaces (lot_state_check)
        word = head; sub(/^[ \t]*([-*+][ \t]+)?(\*\*|__)?/, "", word); sub(/(\*\*|__)?[ \t]*:$/, "", word); sub(/[ \t]+$/, "", word)
        lw = lower(word); bold = (head ~ /^[ \t]*([-*+][ \t]+)?(\*\*|__)/)
        if ((lw in F) && !bold && lw != "state" && lw != "tests removed") lw = ""   # sans gras : seuls État et Tests retirés sont des champs
        if (lw in F) {
          # la ligne lue ne perd que le mot du champ et la valeur : ses espaces, insécables compris, restent
          found("en"); fr = F[lw]; p = index(line, word); line = substr(line, 1, p - 1) fr substr(line, p + length(word))
          if (fr == "\303\211tat" || fr == "D\303\251cision" || fr == "Prochain lot") {
            match(tail, /^[ \t]*(\*\*|__)?[ \t]*/); v = substr(tail, RLENGTH + 1)
            # waiting : valeur du seul champ État ; un slug waiting-list du Prochain lot reste tel quel (revue, lot 02 autonomie-tours)
            for (k in V) if ((k != "waiting" || fr == "\303\211tat") && index(lower(v), k) == 1 && substr(v, length(k) + 1, 1) !~ /[A-Za-z0-9]/) {
              q = p + length(fr); rest = substr(line, q); r = index(lower(rest), k)
              if (r) line = substr(line, 1, q + r - 2) V[k] substr(rest, r + length(k))
              break
            }
          }
        } else if (lw in FFL || lw == "\303\251tat" || lw == "etat" || lw == "\303\211tat") found("fr")
      }
      # champ en gras en milieu de ligne, ainsi « **Created** » après « · » : seul le marqueur change
      if (mode != "detect" && index(line, "**")) for (k in F0) while ((p = index(line, "**" k "**")) > 0) line = substr(line, 1, p + 1) F0[k] substr(line, p + 2 + length(k))
      if (mode != "detect") print line
    }
    END { if (mode == "detect" && !done) print "fr" }' || rc=$?
  [ "$rc" -ne 141 ] || rc=0; return "$rc"
}
# ---------- table unique des valeurs KEY=value : ancien mot français → mot anglais (lot 09 du couloir anglais) ----------
# bin/lab et lib/ n'écrivent plus que la colonne anglaise, sur stdout comme sur disque. Un état posé par un lab d'avant le lot 09
# porte encore la colonne française : lang_code la traduit à la lecture (veilleur, marqueur Cloud, échéances, registre en ligne,
# .lab/correction, état de fiche). Ni migration ni double écriture : la colonne française n'est jamais réécrite, seulement lue.
# Un mot absent de la table ressort tel quel : lang_code se pose sans risque sur une valeur déjà anglaise ou sur une donnée libre.
lang_code() {
  case "$1" in
    'armé'|'armée') echo armed ;;
    'attente'|'en attente') echo waiting ;;
    'mort') echo dead ;;
    'vivant'|'vivante') echo alive ;;
    'incertain') echo uncertain ;;
    'libre') echo free ;;
    'fini') echo finished ;;
    'attente-pause') echo idle-paused ;;
    'repris') echo resumed ;;
    'relance') echo restarted ;;
    'fusionné'|'fusionnée'|'mergée') echo merged ;;
    'non fusionnée'|'non mergée') echo not-merged ;;
    'fermé') echo closed ;;
    'clos') echo closed ;;
    'rouge') echo red ;;
    'conflit') echo conflict ;;
    'sync-conflit') echo sync-conflict ;;
    'stack-conflit') echo stack-conflict ;;
    'changée') echo changed ;;
    'échec') echo failed ;;
    'retiré'|'retirée') echo removed ;;
    'ajouté') echo added ;;
    'lancé') echo started ;;
    'libérée') echo released ;;
    'prête') echo ready ;;
    'en file') echo queued ;;
    'à-jour') echo up-to-date ;;
    'ignorée') echo ignored ;;
    'bloquée') echo blocked ;;
    'présentation') echo preview ;;
    'rien'|'aucun'|'aucune') echo none ;;
    'non vérifiable') echo not-checkable ;;
    'vérifiable') echo checkable ;;
    'planifié') echo planned ;;
    'en cours') echo 'in progress' ;;
    'prévu'|'à venir') echo upcoming ;;
    'retard') echo late ;;
    'à clarifier') echo 'to clarify' ;;
    'travail') echo work ;;
    'en recette') echo 'in acceptance' ;;
    'recette validée') echo 'acceptance passed' ;;
    'HEAD-détachée') echo detached-HEAD ;;
    'déjà') echo already ;;
    'nouveau') echo new ;;
    'inconnu') echo unknown ;;
    'oui') echo yes ;;
    'non') echo no ;;
    'sans commit') echo 'no commit' ;;
    'rangé') echo stored ;;
    'déjà-importé') echo already-imported ;;
    'à-importer') echo to-import ;;
    'défaut') echo default ;;
    'référence') echo reference ;;
    'nom') echo name ;;
    'épuisé') echo exhausted ;;
    'semé') echo seeded ;;
    'valable') echo valid ;;
    'périmée') echo expired ;;
    'inscrite') echo recorded ;;
    'déployée') echo deployed ;;
    'ouverte') echo open ;;
    'faite') echo 'done' ;;
    'annulée') echo cancelled ;;
    'redatée') echo rescheduled ;;
    'validée') echo accepted ;;
    'refusée') echo rejected ;;
    'hors-couloir') echo outside-lane ;;
    'checkout-principal') echo main-checkout ;;
    'copie') echo copy ;;   # manifeste de preuves d'avant le lot 09
    *) printf '%s\n' "$1" ;;
  esac
}
# lang_code_prefix <valeur> : lang_code sur le premier mot d'une valeur suffixée (« fusionnée : lab deploy x » → « merged : lab
# deploy x ») ; sans préfixe connu, la valeur entière passe par lang_code.
LANG_CODE_PREFIXES="non fusionnée|non mergée|en cours|en attente|en file|à clarifier|à venir|sans commit|non vérifiable|fusionnée|planifié|validée|refusée|ouverte|faite|annulée|armé|armée|échec|clos|retard"
lang_code_prefix() {
  local w; local IFS='|'
  for w in $LANG_CODE_PREFIXES; do
    case "$1" in "$w"[!A-Za-z]*) printf '%s%s\n' "$(lang_code "$w")" "${1#"$w"}"; return 0 ;; esac
  done
  lang_code "$1"
}
# lang_doc_of <fichier> → en | fr : la langue lue sur les marqueurs du document ; fr pour un document absent ou sans marqueur
lang_doc_of() { if [ -f "${1:-}" ] && [ -r "$1" ]; then lang_norm detect <"$1"; else printf 'fr\n'; fi; }
# lang_section_re <titre interne> → « titre|forme anglaise », pour un écrivain qui cherche la section dans le texte brut
lang_section_re() { local en; en="$(lang_en "$1")"; if [ "$en" = "$1" ]; then printf '%s\n' "$1"; else printf '%s|%s\n' "$1" "$en"; fi; }
