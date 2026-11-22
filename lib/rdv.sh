# shellcheck shell=bash
# rdv.sh — horodatage UTC strict (lab now) et échéances d'un projet (lab rdv), lot 05 de lab-enhancement.
# Portable par construction : date -u au format POSIX pour lire l'horloge, toute arithmétique de dates en awk pur (jours depuis
# l'époque, années bissextiles) — aucune option de date propre à BSD ou GNU : les nanosecondes de GNU date n'existent pas sur macOS (A5 du brief).

# Fonctions awk partagées. epoch(s) : secondes depuis l'époque d'une date AAAA-MM-JJ (début du jour UTC) ou d'un instant
# AAAA-MM-JJTHH:MM:SSZ ; « invalide » hors de ces deux formes ou hors calendrier. limit(s) : dernier instant à l'heure —
# la fin du jour pour une date, l'instant lui-même sinon. Jours depuis l'époque : algorithme civil de H. Hinnant.
RDV_AWK='
function rdv_leap(y) { return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }
function rdv_mdays(y, m) { return m == 2 ? 28 + rdv_leap(y) : (m == 4 || m == 6 || m == 9 || m == 11 ? 30 : 31) }
function epoch(s,   y, m, d, h, mi, se, yy, era, yoe, doy) {
  if (s ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) { h = 0; mi = 0; se = 0 }
  else if (s ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/) {
    h = substr(s, 12, 2) + 0; mi = substr(s, 15, 2) + 0; se = substr(s, 18, 2) + 0
  } else return "invalide"
  y = substr(s, 1, 4) + 0; m = substr(s, 6, 2) + 0; d = substr(s, 9, 2) + 0
  if (m < 1 || m > 12 || d < 1 || d > rdv_mdays(y, m) || h > 23 || mi > 59 || se > 59) return "invalide"
  yy = y - (m <= 2); era = int((yy >= 0 ? yy : yy - 399) / 400); yoe = yy - era * 400
  doy = int((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5) + d - 1
  return ((era * 146097 + yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy - 719468) * 86400) + h * 3600 + mi * 60 + se
}
function limit(s,   e) { e = epoch(s); if (e == "invalide") return e; return length(s) == 10 ? e + 86399 : e }
'
RDV_STAMP_FORMAT='YYYY-MM-DDTHH:MM:SSZ'

# rdv_epoch <date|instant> → secondes depuis l'époque ; rc 1 hors des deux formes ou hors calendrier
rdv_epoch() { LC_ALL=C awk -v s="${1:-}" "$RDV_AWK"'BEGIN { e = epoch(s); if (e == "invalide") exit 1; printf "%.0f\n", e }'; }
rdv_is_stamp() { case "${1:-}" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) rdv_epoch "$1" >/dev/null ;; *) return 1 ;; esac; }
# rdv_now → l'horodatage UTC strict ; LAB_NOW le fixe (tests, reproduction), rc 1 s'il est mal formé — l'appelant cite rdv_now_refusal
rdv_now() {
  if [ -n "${LAB_NOW:-}" ]; then rdv_is_stamp "$LAB_NOW" || return 1; printf '%s\n' "$LAB_NOW"; return 0; fi
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}
rdv_now_refusal() { printf 'invalid LAB_NOW: "%s" — expected format %s (UTC, calendar date), e.g. 2026-09-16T08:30:00Z\n' "${LAB_NOW:-}" "$RDV_STAMP_FORMAT"; }

cmd_now() {
  local now
  [ "$#" -eq 0 ] || usage
  now="$(rdv_now)" || die "$(rdv_now_refusal)"
  if [ "$JSON" = 1 ]; then kv NOW "$now"; else printf '%s\n' "$now"; fi
}

# ---------- lab rdv : registre des échéances du projet, format v1 ----------
# $LAB_PROJECTS/<projet>/echeances, un fichier pour tous les couloirs, écrit par lab rdv seul. Première ligne : l'en-tête v1, qui porte
# aussi le dernier id donné (un id n'est jamais redonné, même après une ligne retirée à la main) ; puis une ligne par échéance, cinq
# champs tabulés : id, échéance (AAAA-MM-JJ : due jusqu'à la fin de ce jour UTC ; AAAA-MM-JJTHH:MM:SSZ : jusqu'à cet instant),
# état (open, done, cancelled), objet, décision (vide, « done <horodatage> <sha> », « cancelled <horodatage> <motif> »,
# « rescheduled <horodatage> from <échéance> »). Une ligne illisible est nommée par son numéro et recopiée telle quelle, jamais
# effacée. Un registre écrit par un lab d'avant le lot 09 porte ouverte|faite|annulée : rdv_scan les relit sans les réécrire.
RDV_US=$'\037'   # séparateur interne des enregistrements : jamais un blanc, read garde les champs vides (une décision vide)
RDV_DUE_FORMS="expected YYYY-MM-DD (due until the end of that UTC day) or $RDV_STAMP_FORMAT (due until that instant), calendar date"
rdv_file() { printf '%s/echeances\n' "$(project_dir "$1")"; }
# En-tête écrit en anglais depuis le lot 09 ; l'ancien en-tête français reste reconnu à la lecture (rdv_scan, rdv_write).
RDV_HEADER_OLD='# \303\251ch\303\251ances de '   # « # échéances de », en octets : LC_ALL=C awk compare des octets
rdv_header() { printf '# due dates of %s — treelab v1: id⇥due⇥state⇥subject⇥decision ; written by lab due ; last id %s\n' "$1" "$2"; }
rdv_limit() { LC_ALL=C awk -v s="${1:-}" "$RDV_AWK"'BEGIN { e = limit(s); if (e == "invalide") exit 1; printf "%.0f\n", e }'; }
rdv_check_due() { rdv_limit "${1:-}" >/dev/null || die "due date \"${1:-}\" refused: $RDV_DUE_FORMS"; }
# rdv_check_text <nom> <texte> : une ligne de texte, non vide — un objet ou un motif tient dans un seul champ. Tout caractère de contrôle
# est refusé : tabulation et retour à la ligne découperaient le registre, 0x1F les enregistrements internes (revue, lot 05).
rdv_check_text() {
  [ "$(printf '%s' "$2" | LC_ALL=C tr -d '[:cntrl:]')" = "$2" ] ||
    die "$1 refused: it contains a control character (tab, line break…) — a due date fits on one line of text"
  [ -n "$(printf '%s' "$2" | LC_ALL=C tr -d '[:space:]')" ] || die "empty $1"
}

# rdv_scan <registre> <maintenant en secondes> → un enregistrement par ligne, champs séparés par RDV_US :
#   E <n° de ligne> <id> <échéance> <état canonique anglais> <objet> <décision> <limite en secondes> <statut : late | 48h | upcoming | ->
#   X <n° de ligne> <raison>   — ligne illisible
#   M <plus grand id jamais donné : compteur de l'en-tête ou id lu, même sur une ligne illisible>
# Retard : maintenant après la limite ; sous 48 h : pas en retard et limite ≤ maintenant + 48 h. Registre absent : « M 0 ».
rdv_scan() {
  [ -f "$1" ] || { printf 'M%s0\n' "$RDV_US"; return 0; }
  LC_ALL=C awk -F '\t' -v now="$2" -v us="$RDV_US" -v old="$RDV_HEADER_OLD" "$RDV_AWK"'
    function bad(r) { printf "X%s%d%s%s\n", us, NR, us, r }
    NR == 1 && (index($0, "# due dates of ") == 1 || index($0, old) == 1) {
      if (match($0, /(last|dernier) id [0-9]+$/)) { v = substr($0, RSTART); sub(/^[^0-9]*/, "", v); v = v + 0; if (v > max) max = v }
      next
    }
    /^[[:space:]]*$/ { next }
    {
      if ($1 ~ /^[1-9][0-9]*$/ && $1 + 0 > max) max = $1 + 0
      if (index($0, us)) { bad("control character 0x1F"); next }
      if (NF != 5) { bad(NF " field(s) instead of 5"); next }
      if ($1 !~ /^[1-9][0-9]*$/) { bad("id \"" $1 "\": integer expected"); next }
      if (($1 + 0) in seen) { bad("id " $1 " already read on line " seen[$1 + 0]); next }
      l = limit($2)
      if (l == "invalide") { bad("due date \"" $2 "\" outside the YYYY-MM-DD and YYYY-MM-DDTHH:MM:SSZ forms or off the calendar"); next }
      state = $3
      if (state == "ouverte") state = "open"; else if (state == "faite") state = "done"; else if (state == "annul\303\251e") state = "cancelled"
      if (state != "open" && state != "done" && state != "cancelled") { bad("state \"" $3 "\": open, done or cancelled expected"); next }
      if ($4 ~ /^[[:space:]]*$/) { bad("empty subject"); next }
      seen[$1 + 0] = NR
      st = "-"; if (state == "open") st = (now + 0 > l ? "late" : (l <= now + 172800 ? "48h" : "upcoming"))
      printf "E%s%d%s%d%s%s%s%s%s%s%s%s%s%.0f%s%s\n", us, NR, us, $1, us, $2, us, state, us, $4, us, $5, us, l, us, st
    }
    END { printf "M%s%d\n", us, max }' "$1"
}
rdv_max_id() { printf '%s\n' "$1" | awk -F "$RDV_US" '$1 == "M" { print $2 }'; }
rdv_open() { printf '%s\n' "$1" | LC_ALL=C awk -F "$RDV_US" '$1 == "E" && $5 == "open"' | LC_ALL=C sort -t "$RDV_US" -k8,8n -k3,3n; }   # retards, 48 h, à venir
rdv_warn_illegible() { # <registre> <scan>
  local kind ln reason
  while IFS="$RDV_US" read -r kind ln reason; do
    [ "$kind" = X ] && warn "line $ln unreadable in $1, kept as is: $reason"
  done <<<"$2"
  return 0
}
# rdv_write <registre> <projet> <dernier id> <n° de ligne à remplacer | 0> <ligne de remplacement> <ligne à ajouter | vide> :
# réécriture atomique (fichier temporaire du même dossier, puis mv) ; l'en-tête est régénéré, toute autre ligne recopiée telle quelle.
rdv_write() {
  local reg="$1" tmp
  tmp="$(mktemp "$(dirname "$reg")/.echeances.XXXXXX")" || return 1
  if {
    rdv_header "$2" "$3"
    if [ -f "$reg" ]; then
      RDV_AT="$4" RDV_LINE="$5" LC_ALL=C awk -v old="$RDV_HEADER_OLD" 'NR == 1 && (index($0, "# due dates of ") == 1 || index($0, old) == 1) { next }
        NR == ENVIRON["RDV_AT"] + 0 { print ENVIRON["RDV_LINE"]; next } { print }' "$reg"
    fi
    if [ -n "$6" ]; then printf '%s\n' "$6"; fi
  } >"$tmp" && mv "$tmp" "$reg"; then return 0; fi
  rm -f "$tmp"; return 1
}

cmd_rdv() {
  local p="" now nowe reg sub
  if [ "$#" -ge 1 ] && project_exists "$1"; then p="$1"; shift
  else
    case "${1:-}" in
      ''|add|done|reschedule|cancel|fait|redater|annuler) ;;
      -*) usage ;;
      *) die "unknown project: $1 (lab due [project] [add|done|reschedule|cancel …])" ;;
    esac
  fi
  p="$(resolve_project "$p")"; load_project "$p"
  now="$(rdv_now)" || die "$(rdv_now_refusal)"; nowe="$(rdv_epoch "$now")"
  reg="$(rdv_file "$p")"
  if [ -e "$reg" ] && [ ! -r "$reg" ]; then die "due-date registry unreadable: $reg"; fi
  sub="${1:-}"; [ "$#" -eq 0 ] || shift
  case "$sub" in fait) sub='done' ;; redater) sub=reschedule ;; annuler) sub=cancel ;; esac   # alias français muets
  case "$sub" in
    '') rdv_list "$p" "$reg" "$nowe" ;;
    add) registry_locked "$p" rdv_add "$p" "$reg" "$now" "$nowe" "$@" ;;   # lecture, nouvel id et écriture d'un seul tenant (lot-01 de sans-perte)
    done|reschedule|cancel) registry_locked "$p" rdv_decide "$sub" "$p" "$reg" "$now" "$nowe" "$@" ;;
    *) die "unknown action: $sub (add, done, reschedule, cancel)" ;;
  esac
}
rdv_list() { # <projet> <registre> <maintenant en secondes>
  local p="$1" reg="$2" scan open kind id due obj statut
  scan="$(rdv_scan "$reg" "$3")"; rdv_warn_illegible "$reg" "$scan"
  open="$(rdv_open "$scan")"
  kv DUE_LATE "$(printf '%s\n' "$open" | awk -F "$RDV_US" '$9 == "late"' | grep -c . || true)"
  kv DUE_48H "$(printf '%s\n' "$open" | awk -F "$RDV_US" '$9 == "48h"' | grep -c . || true)"
  kv DUE_OPEN "$(printf '%s\n' "$open" | grep -c . || true)"
  [ -n "$open" ] || { onboard_say "no open due date — registry:"; printf '    %s\n' "$reg" >&2; }   # chemin seul, en retrait : jamais coupé
  while IFS="$RDV_US" read -r kind _ id due _ obj _ _ statut; do
    [ "$kind" = E ] || continue
    sep; kv DUE_ID "$id"; kv DUE_DATE "$due"; kv DUE_STATUS "$statut"; kv DUE_SUBJECT "$obj"
    case "$statut" in
      late)
        onboard_say "#$id — overdue (due $due): $obj"
        printf '    lab due %s done %s <sha>\n    lab due %s reschedule %s <due-date>\n    lab due %s cancel %s <reason>\n' "$p" "$id" "$p" "$id" "$p" "$id" \
          | onboard_wrap "$(onboard_cols)" >&2 ;;
      48h) onboard_say "#$id — within 48 h (due $due): $obj" ;;
      *) onboard_say "#$id — upcoming (due $due): $obj" ;;
    esac
  done <<<"$open"
}
rdv_add() { # <projet> <registre> <maintenant> <maintenant en secondes> <échéance> <objet…>
  local p="$1" reg="$2" now="$3" nowe="$4" due="${5:-}" obj scan id
  shift 4; [ "$#" -eq 0 ] || shift; obj="$*"
  rdv_check_due "$due"; rdv_check_text "subject" "$obj"
  scan="$(rdv_scan "$reg" "$nowe")"; rdv_warn_illegible "$reg" "$scan"; id=$(($(rdv_max_id "$scan") + 1))
  rdv_write "$reg" "$p" "$id" 0 "" "$(printf '%s\t%s\topen\t%s\t' "$id" "$due" "$obj")" || die "due-date registry not written: $reg"
  [ "$nowe" -le "$(rdv_limit "$due")" ] || warn "due date #$id already overdue ($due; lab now: $now): recorded as is, lab due $p settles it"
  kv DUE_ID "$id"
  rdv_record "$p" "$reg" "add $id"
}
# rdv_record <projet> <registre> <action id> : enregistre ce seul fichier dans son dépôt git, par la mécanique de docs_commit
# (git_commit_paths) — jamais dans le checkout du code (mode dev : LAB_HOME = LAB_ROOT) ni dans le dépôt d'un projet enregistré
# (aucun commit sur un checkout principal). DUE_COMMIT=<sha>, none ou failed, avec DUE_REASON ; l'écriture est déjà faite, rc 0.
rdv_record() {
  local p="$1" dir root code o r rel
  dir="$(real_path "$(dirname "$2")")"
  if ! root="$(repo_root "$dir")"; then kv DUE_COMMIT none; kv DUE_REASON "registry in no git repository: $dir"; return 0; fi
  root="$(real_path "$root")"
  # mode dev seulement : une copie release vit sous ~/.lab/releases, dans le dépôt même du registre (revue, lot 05)
  code=""; [ -f "$LAB_ROOT/.release" ] || code="$(real_path "$(repo_root "$LAB_ROOT" || printf '%s' "$LAB_ROOT")")"
  if [ "$root" = "$code" ]; then
    kv DUE_COMMIT none; kv DUE_REASON "registry in the treelab code checkout ($root): never a commit here"; return 0
  fi
  for o in $(project_names); do
    r="$(config_get "$o" root)"; [ -d "$r" ] || continue
    r="$(repo_root "$r")" || continue
    if [ "$(real_path "$r")" = "$root" ]; then
      kv DUE_COMMIT none; kv DUE_REASON "registry in the repository of registered project $o ($root): no commit on its main checkout"; return 0
    fi
  done
  case "$dir" in "$root") rel=echeances ;; *) rel="${dir#"$root"/}/echeances" ;; esac
  git_commit_paths "$root" "docs($p): due dates — $3" "$rel"
  kv DUE_COMMIT "$COMMIT_RESULT"
  case "$COMMIT_RESULT" in
    none) kv DUE_REASON "$COMMIT_REASON" ;;
    failed) kv DUE_REASON "$COMMIT_REASON"; warn "due-date registry not recorded in $root — git: $COMMIT_REASON" ;;
    *) log "due-date registry recorded: $COMMIT_RESULT in $root" ;;
  esac
}
# rdv_commit_repos → les dépôts où chercher le commit d'une échéance faite : celui du projet, puis celui des fiches (docs=local), sans doublon
rdv_commit_repos() {
  local d r out=""
  if r="$(repo_root "$P_ROOT")"; then out="$(real_path "$r")"; fi
  if [ "$P_DOCS" != repo ]; then
    d="$(docs_dir -)"; [ -d "$d" ] || d="$(project_dir "$P_NAME")"
    if r="$(repo_root "$d")"; then r="$(real_path "$r")"; [ "$r" = "$out" ] || out="$out${out:+$'\n'}$r"; fi
  fi
  printf '%s\n' "$out"
}
# rdv_commit_of <valeur> → sha complet d'un commit des dépôts cherchés ; rc 1 si absent, préfixe ambigu ou deux commits différents
rdv_commit_of() {
  local v="$1" repo full found=""
  [[ "$v" =~ ^[0-9a-f]{4,64}$ ]] || return 1
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    full="$(git -C "$repo" rev-parse --verify --quiet "$v^{commit}" 2>/dev/null)" || continue
    if [ -n "$found" ] && [ "$found" != "$full" ]; then return 1; fi
    found="$full"
  done <<<"$(rdv_commit_repos)"
  [ -n "$found" ] && printf '%s\n' "$found"
}
rdv_decide() { # <done|reschedule|cancel> <projet> <registre> <maintenant> <maintenant en secondes> <id> <argument…>
  local act="$1" p="$2" reg="$3" now="$4" nowe="$5" id="${6:-}" scan rec ln due st obj dec new_due new_st new_dec said sha="" open
  shift 5; [ "$#" -eq 0 ] || shift
  scan="$(rdv_scan "$reg" "$nowe")"; rdv_warn_illegible "$reg" "$scan"
  rec=""; [[ "$id" =~ ^[1-9][0-9]*$ ]] && rec="$(printf '%s\n' "$scan" | awk -F "$RDV_US" -v id="$id" '$1 == "E" && $3 == id')"
  if [ -z "$rec" ]; then
    open="$(rdv_open "$scan" | cut -d "$RDV_US" -f3 | sort -n | paste -sd, - | sed 's/,/, /g')"
    die "due date \"$id\" unknown in $reg; open: ${open:-none}"
  fi
  IFS="$RDV_US" read -r _ ln _ due st obj dec _ _ <<<"$rec"
  case "$st" in open) ;; done) die "due date #$id already done ($dec): nothing to settle" ;; *) die "due date #$id already cancelled ($dec): nothing to settle" ;; esac
  new_due="$due"
  case "$act" in
    done)
      sha="$(rdv_commit_of "${1:-}")" ||
        die "commit \"${1:-}\" not found or ambiguous prefix in: $(rdv_commit_repos | paste -sd, - | sed 's/,/, /g') — give the sha of a commit from these repositories"
      new_st='done'; new_dec="done $now $sha"; said="done with commit $sha" ;;
    reschedule)
      rdv_check_due "${1:-}"
      [ "$(rdv_limit "$1")" -gt "$nowe" ] || die "new due date \"$1\" already past (lab now: $now): it must be in the future"
      new_due="$1"; new_st=open; new_dec="rescheduled $now from $due"; said="rescheduled from $due to $1" ;;
    cancel)
      rdv_check_text "reason" "$*"
      new_st=cancelled; new_dec="cancelled $now $*"; said="cancelled: $*" ;;
  esac
  rdv_write "$reg" "$p" "$(rdv_max_id "$scan")" "$ln" "$(printf '%s\t%s\t%s\t%s\t%s' "$id" "$new_due" "$new_st" "$obj" "$new_dec")" "" ||
    die "due-date registry not written: $reg"
  kv DUE_ID "$id"; kv DUE_STATE "$new_st"; kv DUE_DATE "$new_due"
  [ -z "$sha" ] || kv DUE_SHA "$sha"
  log "due date #$id $said"
  rdv_record "$p" "$reg" "$act $id"
}
