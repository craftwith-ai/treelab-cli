# shellcheck shell=bash
# waiting.sh — lots non bloquants (lot 02 d'autonomie-tours). Un critère de fin qui attend une mesure à une date ne bloque plus le
# couloir : la fiche porte une section « ## Waiting » (« ## En attente » dans une fiche française), une ligne par critère
#   - C4 · 2026-11-18 · <motif> · reports 0[ · reopened <horodatage>][ · measured <horodatage> <sha>]
# et son État devient « waiting » (« en attente ») tant qu'une ligne reste ouverte (sans « measured »). lab next livre et enchaîne ;
# à la date, il rouvre la fiche sur chore/<slug>.c<N> pour ce seul critère, avant le lot suivant ; la recette et lab close attendent
# que toutes les lignes du couloir soient mesurées. lab wake, lancé par un LaunchAgent toutes les heures, appelle lab next à la date.
# Aucun état caché : tout se relit dans les fiches, la date se juge contre rdv_now (LAB_NOW en test).

# Autonome : lu aussi par lib/recette.sh hors CLI (lane_phase), il charge lui-même ses dépendances (dates de lib/rdv.sh, table de lib/lang.sh).
declare -F rdv_epoch >/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/rdv.sh"
declare -F lang_norm >/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lang.sh"
WAIT_SECTION='En attente'
WAIT_DOT=' · '   # séparateur des champs d'une ligne ; un « · » tapé dans le motif devient « - »
WAIT_REPORTS_MAX=1
WAIT_LABEL="${LAB_WAKE_LABEL:-dev.treelab.wake}"

# wait_lines <fiche> → une ligne par critère lisible : Cn<TAB>date<TAB>motif<TAB>reports<TAB>measured<TAB>reopened
# Seule la section compte (titre lu par lang_norm, blocs de code ignorés) ; les champs vides restent vides : lire avec cut, jamais read.
wait_lines() {
  [ -f "${1:-}" ] && [ -r "$1" ] || return 0
  lang_norm <"$1" | LC_ALL=C awk '
    { sub(/\r$/, "") }
    /^[ \t]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    /^## / { inside = ($0 ~ /^## +En attente[ \t]*$/); next }
    !inside { next }
    /^- C[0-9]+ \302\267 / {
      n = split($0, a, / \302\267 /); id = substr(a[1], 3); rep = 0; meas = ""; reo = ""
      for (i = 4; i <= n; i++) {
        if (a[i] ~ /^reports [0-9]+$/) rep = substr(a[i], 9) + 0
        else if (a[i] ~ /^measured /) meas = substr(a[i], 10)
        else if (a[i] ~ /^reopened /) reo = substr(a[i], 10)
      }
      printf "%s\t%s\t%s\t%d\t%s\t%s\n", id, a[2], a[3], rep, meas, reo
    }'
}
wait_line_of() { wait_lines "$1" | awk -F'\t' -v id="$2" '$1 == id { print; exit }'; }   # <fiche> <Cn>
wait_open_lines() { wait_lines "$1" | awk -F'\t' '$5 == ""'; }                         # <fiche> : lignes non mesurées
wait_has_open() { [ -n "$(wait_open_lines "$1")" ]; }
# wait_line_text <Cn> <date> <motif> <reports> [reopened] [measured] → la ligne écrite dans la fiche
wait_line_text() {
  local t="- $1$WAIT_DOT$2$WAIT_DOT$3${WAIT_DOT}reports $4"
  [ -z "${5:-}" ] || t="$t${WAIT_DOT}reopened $5"
  [ -z "${6:-}" ] || t="$t${WAIT_DOT}measured $6"
  printf '%s\n' "$t"
}
# wait_write <fiche> <Cn> <ligne> : remplace la ligne du critère dans la section, sinon l'ajoute à sa fin ; sans section, la crée
# avant le journal (ou la Reprise), à défaut à la fin. Blocs de code ignorés ; le reste de la fiche est recopié à l'identique.
wait_write() {
  local tmp sec; sec="$(lang_word "$(lang_doc_of "$1")" "$WAIT_SECTION")"; tmp="$(mktemp "$1.XXXXXX")"
  W_ID="$2" W_LINE="$3" W_SEC="$sec" LC_ALL=C awk '
    { L[++n] = $0 }
    END {
      id = ENVIRON["W_ID"]; nl = ENVIRON["W_LINE"]
      for (i = 1; i <= n; i++) {
        if (L[i] ~ /^[ \t]*(```|~~~)/) { fence = !fence; continue }
        if (fence) continue
        if (L[i] ~ /^## /) {
          if (s && !e) e = i
          if (!s && L[i] ~ /^## +(En attente|Waiting)[ \t]*$/) s = i
          else if (!anchor && L[i] ~ /^## +(Journal|Log|Reprise|Handoff)([^A-Za-z]|$)/) anchor = i
          continue
        }
        if (s && !e && index(L[i], "- " id " \302\267 ") == 1) hit = i
      }
      if (s && !e) e = n + 1
      if (hit) { L[hit] = nl; for (i = 1; i <= n; i++) print L[i]; exit }
      if (s) {
        last = s; for (i = s + 1; i < e; i++) if (L[i] ~ /[^ \t]/) last = i
        for (i = 1; i <= n; i++) { print L[i]; if (i == last) { if (last == s) print ""; print nl } }
        exit
      }
      if (anchor) {
        for (i = 1; i <= n; i++) { if (i == anchor) { print "## " ENVIRON["W_SEC"]; print ""; print nl; print "" } print L[i] }
        exit
      }
      for (i = 1; i <= n; i++) print L[i]
      if (n && L[n] ~ /[^ \t]/) print ""
      print "## " ENVIRON["W_SEC"]; print ""; print nl
    }' "$1" >"$tmp" && mv "$tmp" "$1"
}
# wait_criteria <fiche> → identifiants Cn des critères de fin (« - [ ] C4: … »)
wait_criteria() { lot_section_lines "$1" 'Critères de fin' | sed -nE 's/^- \[[ xX]\][[:space:]]*[*_`]*(C[0-9]+)([^0-9A-Za-z_].*)?$/\1/p'; }
# wait_date_plus <AAAA-MM-JJ> <N> → la date N jours plus tard (jours civils, algorithme de H. Hinnant, awk pur)
wait_date_plus() {
  LC_ALL=C awk -v s="$1" -v n="$2" "$RDV_AWK"'BEGIN {
    z = int(epoch(s) / 86400) + n + 719468; era = int((z >= 0 ? z : z - 146096) / 146097); doe = z - era * 146097
    yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365); y = yoe + era * 400
    doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100)); mp = int((5 * doy + 2) / 153)
    d = doy - int((153 * mp + 2) / 5) + 1; m = mp < 10 ? mp + 3 : mp - 9; y += (m <= 2)
    printf "%04d-%02d-%02d\n", y, m, d }'
}
WAIT_DATE_FORMS='expected YYYY-MM-DD, YYYY-MM-DDTHH:MM:SSZ (UTC) or +Nd (N days from today, 1 to 999)'
# wait_resolve_date <date tapée> <maintenant> → date ou instant retenu ; refus nommé si illisible ou passé
wait_resolve_date() {
  local d="$1" now="$2" today
  today="${now%%T*}"
  case "$d" in
    +[0-9]d|+[0-9][0-9]d|+[0-9][0-9][0-9]d) d="${d#+}"; d="${d%d}"; [ "$((10#$d))" -ge 1 ] || die "date \"$1\" refused: $WAIT_DATE_FORMS"; wait_date_plus "$today" "$((10#$d))"; return ;;
  esac
  rdv_epoch "$d" >/dev/null 2>&1 || die "date \"$1\" unreadable: $WAIT_DATE_FORMS"
  case "$d" in
    *T*) [ "$(rdv_epoch "$d")" -gt "$(rdv_epoch "$now")" ] || die "date \"$1\" already past (now $now): a measure waits for a future date" ;;
    *) [ "$(rdv_epoch "$d")" -ge "$(rdv_epoch "$today")" ] || die "date \"$1\" already past (today $today): a measure waits for a future date" ;;
  esac
  printf '%s\n' "$d"
}

# ---------- lecture du couloir ----------
# wait_lane_files <wt> → les fiches du couloir, par numéro
# shellcheck disable=SC2012 # noms lot-NN-<slug> : lettres, chiffres, tirets, points
wait_lane_files() { ls "$(lots_dir "$(docs_dir "$1")" "$(wt_lane "$1")")"/lot-[0-9]*.md 2>/dev/null | sort || true; }
# wait_lane_open <wt> → lignes ouvertes du couloir, la plus ancienne date d'abord :
#   epoch<TAB>fiche<TAB>Cn<TAB>date<TAB>motif<TAB>reports<TAB>reopened
# Champs relus par awk : un read à IFS tabulation fusionnerait les champs vides (measured), et « reopened » serait perdu (revue).
wait_lane_open() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    wait_open_lines "$f" | LC_ALL=C awk -F'\t' -v f="$f" "$RDV_AWK"'{ e = epoch($2); if (e == "invalide") next; printf "%.0f\t%s\t%s\t%s\t%s\t%s\t%s\n", e, f, $1, $2, $3, $4, $6 }'
  done < <(wait_lane_files "$1") | sort -t "$(printf '\t')" -k1,1n -k2,2 -k3,3 || true
}
# wait_lane_due <wt> → la première ligne due (date atteinte, pas encore rouverte pour cette date), au format de wait_lane_open
wait_lane_due() {
  local now; now="$(rdv_now)" || die "$(rdv_now_refusal)"
  wait_lane_open "$1" | awk -F'\t' -v now="$(rdv_epoch "$now")" '$1 <= now && $7 == "" { print; exit }'
}
# wait_lane_first <wt> → la première ligne ouverte (la plus proche), au format de wait_lane_open ; vide si aucune
wait_lane_first() { wait_lane_open "$1" | head -1; }
# wait_summary <ligne de wait_lane_open> → « lot-02-x C4 2026-11-18 — <motif> »
wait_summary() { printf '%s' "$1" | awk -F'\t' '{ n = $2; sub(/.*\//, "", n); sub(/\.md$/, "", n); printf "%s %s %s — %s\n", n, $3, $4, $5 }'; }
# wait_block <wt> : refus de la recette ou de la fermeture tant qu'une attente du couloir reste ouverte ; rc 0 sans attente
wait_block() {
  local w; w="$(wait_lane_first "$1")"; [ -n "$w" ] || return 0
  die "lane $(wt_lane "$1") waits for a measure: $(wait_summary "$w") — lab next $P_NAME $(wt_lane "$1") reopens that batch at its date; acceptance and closing come after"
}

# ---------- lab batch wait ----------
# cmd_batch_wait <Cn> <date|instant|+Nd> <motif> | --done <Cn> : depuis le dossier du couloir, sur sa fiche courante
cmd_batch_wait() {
  local root lot st id date motif now line cur rep reo n
  root="$(repo_root)" || die "not in a repository"
  PROJECT="$(project_from_cwd)" || die "unknown project for $root"; load_project "$PROJECT"
  lot="$(wt_lot_file "$root")"; ! reopen_branch_of "$root" >/dev/null || lot="$(wt_own_lot_file "$root")"   # la fiche rouverte, quel que soit son État
  [ -n "$lot" ] || die "no batch file for this lane: lab batch current"
  now="$(rdv_now)" || die "$(rdv_now_refusal)"
  if [ "${1:-}" = --done ]; then
    [ "$#" -eq 2 ] || usage
    id="$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')"
    cur="$(wait_line_of "$lot" "$id")"; [ -n "$cur" ] || die "$id does not wait in $(basename "$lot" .md): nothing to mark measured"
    [ -z "$(printf '%s' "$cur" | cut -f5)" ] || die "$id already measured in $(basename "$lot" .md) ($(printf '%s' "$cur" | cut -f5))"
    line="$(wait_line_text "$id" "$(printf '%s' "$cur" | cut -f2)" "$(printf '%s' "$cur" | cut -f3)" "$(printf '%s' "$cur" | cut -f4)" \
      "$(printf '%s' "$cur" | cut -f6)" "$now $(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo none)")"
    wait_write "$lot" "$id" "$line"
    n="$(wait_open_lines "$lot" | awk 'END { print NR }')"
    st="$(lot_state "$lot")"
    case "$st" in waiting*) [ "$n" != 0 ] || lot_set_state "$lot" closed ;; esac
    kv BATCH "$lot"; kv CRITERION "$id"; kv MEASURED "$now"; kv WAITING_LEFT "$n"; kv STATE "$(lot_state "$lot")"
    return 0
  fi
  [ "$#" -eq 3 ] || usage
  id="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"; motif="$3"
  [[ "$id" =~ ^C[0-9]+$ ]] || die "criterion \"$1\" refused: expected C<number>, as in the exit criteria"
  wait_criteria "$lot" | grep -qx "$id" || die "unknown criterion $id: not among the exit criteria of $(basename "$lot" .md) ($(wait_criteria "$lot" | paste -sd' ' -))"
  rdv_check_text reason "$motif"
  motif="$(printf '%s' "$motif" | sed 's/·/-/g')"
  st="$(lot_state "$lot")"
  case "$st" in 'in progress'*|waiting*) ;; *) die "batch $(basename "$lot" .md) \"${st:-without state}\": a criterion waits only from a batch in progress" ;; esac
  date="$(wait_resolve_date "$2" "$now")"
  cur="$(wait_line_of "$lot" "$id")"; rep=0; reo=""
  if [ -n "$cur" ]; then
    [ -z "$(printf '%s' "$cur" | cut -f5)" ] || die "$id already measured in $(basename "$lot" .md) ($(printf '%s' "$cur" | cut -f5)): nothing left to wait for"
    rep="$(printf '%s' "$cur" | cut -f4)"
    [ "$rep" -lt "$WAIT_REPORTS_MAX" ] || die "$id already postponed $rep time(s) (was due $(printf '%s' "$cur" | cut -f2)): a second postponement is refused — measure it now, or write why it cannot be measured in the log and drop the criterion with the user"
    rep=$((rep + 1))
  fi
  wait_write "$lot" "$id" "$(wait_line_text "$id" "$date" "$motif" "$rep" "$reo")"
  lot_set_state "$lot" waiting
  kv BATCH "$lot"; kv CRITERION "$id"; kv DUE "$date"; kv REPORTS "$rep"; kv STATE "$(lot_state "$lot")"
  if [ "$rep" = 0 ]; then log_wrap "$id waits until $date: the batch is delivered as usual, lab next opens the next one and reopens this batch for $id at that date."
  else log_wrap "$id postponed to $date (last postponement allowed)."; fi
  wake_install alarm || true
}

# ---------- réouverture (lab next) ----------
# wait_reopen_prompt <fiche> <Cn> → le complément du Goal d'une session de réouverture, relu dans la fiche (jamais transporté)
wait_reopen_prompt() {
  local l; l="$(wait_line_of "$1" "$2")"
  printf 'Reopened for %s only, due %s: %s. Measure %s and put its evidence in the log, then lab batch wait --done %s (or, once, lab batch wait %s <date> "<reason>" if the measure is not ready); change nothing else, then apply batch-end: delivered like any batch, never in acceptance.' \
    "$2" "$(printf '%s' "$l" | cut -f2)" "$(printf '%s' "$l" | cut -f3)" "$2" "$2" "$2"
}
# wait_reopen_mark <fiche> <Cn> <horodatage> : la ligne retient sa réouverture (une seule par date) et la fiche repasse en cours
wait_reopen_mark() {
  local l; l="$(wait_line_of "$1" "$2")"
  wait_write "$1" "$2" "$(wait_line_text "$2" "$(printf '%s' "$l" | cut -f2)" "$(printf '%s' "$l" | cut -f3)" "$(printf '%s' "$l" | cut -f4)" "$3")"
  lot_set_state "$1" 'in progress'
}

# ---------- lab wake : l'alarme macOS ----------
# wake_program → le lab que l'alarme lance : pour une release, le lien stable « current » (une mise à jour garde l'alarme sur la
# nouvelle version), sinon ce programme lui-même (checkout de développement)
wake_program() {
  if [ -f "$LAB_ROOT/.release" ] && [ -x "$LAB_HOME/current/bin/lab" ]; then printf '%s\n' "$LAB_HOME/current/bin/lab"
  else printf '%s\n' "$LAB_ROOT/bin/lab"; fi
}
wake_agents_dir() { printf '%s\n' "${LAB_LAUNCH_AGENTS:-$HOME/Library/LaunchAgents}"; }
wake_plist() { printf '%s/%s.plist\n' "$(wake_agents_dir)" "$WAIT_LABEL"; }
wake_launchctl() { "${LAB_LAUNCHCTL:-launchctl}" "$@"; }
wake_log_file() { printf '%s/wake.log\n' "$LAB_STATE"; }
wake_log() { mkdir -p "$LAB_STATE"; printf '%s %s\n' "$(rdv_now 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$(wake_log_file)"; }
wake_has_launchctl() { command -v "${LAB_LAUNCHCTL:-launchctl}" >/dev/null 2>&1; }
# wake_env_xml → les clés d'environnement du registre de ce processus qui s'écartent du défaut du programme (comme launch_registry) :
# sous launchd, un lab de checkout prendrait sinon son propre dossier pour LAB_HOME
wake_env_xml() {
  [ "$LAB_HOME" = "$(lab_home_default "$LAB_ROOT")" ] || printf '<key>LAB_HOME</key><string>%s</string>' "$LAB_HOME"
  [ -z "${LAB_PROJECTS_DIR:-}" ] || printf '<key>LAB_PROJECTS_DIR</key><string>%s</string>' "$LAB_PROJECTS_DIR"
  [ -z "${LAB_STATE_DIR:-}" ] || printf '<key>LAB_STATE_DIR</key><string>%s</string>' "$LAB_STATE_DIR"
}
# wake_plist_text <lab> <PATH> → le LaunchAgent : lab wake toutes les heures, au chargement compris (rattrapage après une veille)
wake_plist_text() {
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$WAIT_LABEL</string>
  <key>ProgramArguments</key><array><string>$1</string><string>wake</string></array>
  <key>StartInterval</key><integer>3600</integer>
  <key>RunAtLoad</key><true/>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>$2</string>$(wake_env_xml)</dict>
  <key>StandardOutPath</key><string>$LAB_STATE/wake.out</string>
  <key>StandardErrorPath</key><string>$LAB_STATE/wake.out</string>
</dict>
</plist>
PLIST
}
# wake_install [alarm] : écrit le plist (s'il change) puis le charge (s'il n'est pas chargé) ; idempotent. alarm : appelé par
# lab batch wait, une ligne ALARM= au lieu des clés détaillées, jamais un refus.
wake_install() {
  local mode="${1:-}" plist text lab p pathv dir loaded=0 wrote=0
  if ! wake_has_launchctl; then
    if [ "$mode" = alarm ]; then kv ALARM "unavailable (no launchctl: lab next reopens it at its date)"; return 0; fi
    die "launchctl not found: lab wake --install needs macOS"
  fi
  lab="$(wake_program)"; pathv="$(dirname "$lab")"
  case "$LAB_ROOT/" in */.worktrees/*) warn "alarm set from the lane checkout $LAB_ROOT: it stops working when that lane is closed — set it again with the installed lab (lab wake --install)" ;; esac
  # dossiers du PATH du plist déjà posé gardés : un lancement depuis un shell sans cmux ne l'en retire pas (revue)
  for dir in $(sed -n 's:.*<key>PATH</key><string>\([^<]*\)</string>.*:\1:p' "$(wake_plist)" 2>/dev/null | tr ':' ' '); do
    case ":$pathv:" in *":$dir:"*) ;; *) pathv="$pathv:$dir" ;; esac
  done
  for p in cmux claude codex git gh; do
    dir="$(command -v "$p" 2>/dev/null || true)"; [ -n "$dir" ] || continue; dir="$(dirname "$dir")"
    case ":$pathv:" in *":$dir:"*) ;; *) pathv="$pathv:$dir" ;; esac
  done
  for dir in /usr/bin /bin /usr/sbin /sbin; do case ":$pathv:" in *":$dir:"*) ;; *) pathv="$pathv:$dir" ;; esac; done
  plist="$(wake_plist)"; text="$(wake_plist_text "$lab" "$pathv")"
  mkdir -p "$(wake_agents_dir)"
  if [ ! -f "$plist" ] || [ "$(cat "$plist")" != "$text" ]; then printf '%s\n' "$text" >"$plist"; wrote=1; fi
  if wake_launchctl print "gui/$(id -u)/$WAIT_LABEL" >/dev/null 2>&1; then loaded=1; fi
  if [ "$loaded" = 1 ] && [ "$wrote" = 1 ]; then wake_launchctl bootout "gui/$(id -u)/$WAIT_LABEL" >/dev/null 2>&1 || true; loaded=0; fi
  if [ "$loaded" = 0 ]; then
    wake_launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1 || {
      if [ "$mode" = alarm ]; then kv ALARM "unavailable (launchctl bootstrap refused: lab next reopens it at its date)"; return 0; fi
      die "launchctl bootstrap gui/$(id -u) $plist refused"; }
  fi
  if [ "$mode" = alarm ]; then kv ALARM "$WAIT_LABEL"; return 0; fi
  wake_socket_say
  kv WAKE installed; kv LABEL "$WAIT_LABEL"; kv PLIST "$plist"; kv LOADED "$([ "$loaded" = 1 ] && echo already || echo now)"
  log_wrap "Alarm $WAIT_LABEL: lab wake every hour and at login; it runs lab next for each lane whose waiting batch is due."
}
# wake_socket_say : le mode d'accès du socket cmux (mesuré au lot 02 : « cmuxOnly » refuse un processus lancé par launchd) — dit,
# jamais changé : c'est un réglage de sécurité de l'utilisateur
wake_socket_say() {
  local m; has_cmux || return 0
  m="$(cmx socket-status --json 2>/dev/null | jq -r '.effective_mode // empty' 2>/dev/null || true)"; [ -n "$m" ] || return 0
  kv CMUX_SOCKET "$m"
  [ "$m" != cmuxOnly ] || warn_wrap "cmux accepts only the processes it started (socket mode cmuxOnly): under launchd, lab wake only logs a due lane and the next lab next reopens it. For the alarm to open the session itself, choose a socket mode with a password in the cmux settings — your choice, lab never changes it."
}
wake_remove() {
  local plist; plist="$(wake_plist)"
  if wake_has_launchctl; then wake_launchctl bootout "gui/$(id -u)/$WAIT_LABEL" >/dev/null 2>&1 || true; fi
  rm -f "$plist"
  kv WAKE removed; kv LABEL "$WAIT_LABEL"
}
wake_status() {
  local loaded=no l
  if wake_has_launchctl && wake_launchctl print "gui/$(id -u)/$WAIT_LABEL" >/dev/null 2>&1; then loaded=yes; fi
  kv LABEL "$WAIT_LABEL"; kv PLIST "$([ -f "$(wake_plist)" ] && wake_plist || echo none)"; kv LOADED "$loaded"
  l="$(tail -1 "$(wake_log_file)" 2>/dev/null || true)"; kv LAST_RUN "${l:-none}"
}
# wake_run : chaque couloir des projets inscrits dont une attente est due, sans session vivante et dont la fiche courante est close
# ou en attente, reçoit lab next ; la tour d'un projet sans session vivante aussi (lot 04) ; le reste est noté au journal, jamais touché.
wake_run() {
  local p wt lane due lock st cmux=absent n=0 rc
  if has_cmux && cmx tree --json >/dev/null 2>&1; then cmux=reachable; fi
  wake_log "start CMUX=$cmux"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    # load_project meurt (exit) sur un projet illisible : essayé à part, il ne coupe jamais le passage des autres (revue)
    ( load_project "$p" ) >/dev/null 2>&1 || { wake_log "$p: unreadable project, skipped"; kv SKIPPED "$p unreadable project"; continue; }
    load_project "$p"
    for wt in "$P_ROOT"/.worktrees/*/; do
      [ -d "$wt" ] || continue; wt="${wt%/}"; lane="$(wt_lane "$wt")"
      # lot 04 d'autonomie-tours : la tour (role=tower et sa marque) sans session vivante est relancée par lab next, cmux joignable ;
      # aucun autre couloir n'est relancé sans attente due
      if declare -F lane_is_tower >/dev/null && lane_is_tower "$wt"; then
        lock="$(lock_status "$wt" 2>/dev/null || true)"
        case "$lock" in alive*|uncertain*) wake_log "$p/$lane: tower, live session: skipped"; kv SKIPPED "$p/$lane live session"; continue ;; esac
        if [ "$cmux" != reachable ]; then wake_log "$p/$lane: tower without session, cmux unreachable: restarted at the next lab wake"; kv PENDING "$p/$lane tower without session"; continue; fi
        wake_log "$p/$lane: tower without session: lab next $p $lane"
        rc=0; (cd "$wt" && LAB_UNATTENDED=1 "$LAB_ROOT/bin/lab" next "$p" "$lane") >>"$(wake_log_file)" 2>&1 || rc=$?
        wake_log "$p/$lane lab next rc=$rc"; kv WOKEN "$p/$lane rc=$rc"; n=$((n + 1)); continue
      fi
      due="$(wait_lane_due "$wt" 2>/dev/null || true)"; [ -n "$due" ] || continue
      lock="$(lock_status "$wt" 2>/dev/null || true)"
      case "$lock" in alive*|uncertain*) wake_log "$p/$lane due ($(wait_summary "$due")), live session: skipped"; kv SKIPPED "$p/$lane live session"; continue ;; esac
      st="$(lot_state "$(wt_lot_file "$wt")")"
      case "$st" in closed*|waiting*) ;; *) wake_log "$p/$lane due ($(wait_summary "$due")), batch $st: reopened after it"; kv SKIPPED "$p/$lane batch $st"; continue ;; esac
      # sans cmux joignable, lab next rouvrirait la fiche sans ouvrir de session : rien n'est touché, le prochain lab next la rouvre (C7)
      if [ "$cmux" != reachable ]; then wake_log "$p/$lane due ($(wait_summary "$due")), cmux unreachable: reopened at the next lab next"; kv PENDING "$p/$lane $(wait_summary "$due")"; continue; fi
      wake_log "$p/$lane due ($(wait_summary "$due")): lab next $p $lane"
      rc=0; (cd "$wt" && LAB_UNATTENDED=1 "$LAB_ROOT/bin/lab" next "$p" "$lane") >>"$(wake_log_file)" 2>&1 || rc=$?
      wake_log "$p/$lane lab next rc=$rc"; kv WOKEN "$p/$lane rc=$rc"; n=$((n + 1))
    done
  done < <(project_names)
  [ "$n" -gt 0 ] || wake_log "nothing due"
  kv CMUX "$cmux"; kv WOKEN_COUNT "$n"
}
cmd_wake() {
  case "${1:-}" in
    '') [ "$#" -eq 0 ] || usage; wake_run ;;
    --install) [ "$#" -eq 1 ] || usage; wake_install ;;
    --remove) [ "$#" -eq 1 ] || usage; wake_remove ;;
    --status) [ "$#" -eq 1 ] || usage; wake_status ;;
    *) usage ;;
  esac
}
