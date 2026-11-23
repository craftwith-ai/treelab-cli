# shellcheck shell=bash
# ginkgo.sh — Ginkgo, la conversation orale avec la tour d'un projet (lot 01 de pilotage-voix). Le bash garde les décisions :
# Ginkgo.app (paquet Swift ginkgo/) n'est qu'oreille et bouche ; ses outils n'appellent que lab ginkgo state et lab ginkgo tell.
# La clé d'API vit au trousseau macOS : elle n'entre que par l'entrée standard (security -i), jamais en argument ni à l'écran.
GINKGO_SERVICE=treelab.ginkgo.openai
GINKGO_ACCOUNT=openai
GINKGO_BUNDLE=dev.treelab.ginkgo   # CFBundleIdentifier de l'app (scripts/ginkgo-build.sh) : l'autorisation du micro lui est attachée
GINKGO_TELL_MAX=2000   # octets d'un message transmis à un couloir
ginkgo_dir() { printf '%s/ginkgo\n' "$LAB_STATE"; }
# Lot 04 : une release apporte l'app compilée et signée ($LAB_ROOT/apps/Ginkgo.app), lancée telle quelle, jamais fabriquée ; un
# checkout la fabrique depuis ses sources dans $LAB_STATE/ginkgo (LAB_GINKGO_APP_DIR : le dossier des tests, checkout seul).
ginkgo_release() { [ -f "$LAB_ROOT/.release" ] && [ ! -L "$LAB_ROOT/.release" ]; }   # même marque que lab update
ginkgo_app() {
  if ginkgo_release; then printf '%s/apps/Ginkgo.app\n' "$LAB_ROOT"
  else printf '%s/Ginkgo.app\n' "${LAB_GINKGO_APP_DIR:-$(ginkgo_dir)}"; fi
}
ginkgo_source() { if ginkgo_release; then echo release; else echo checkout; fi; }
# ginkgo_lab : le lab que l'app relance — le lien current quand ce lab est la version installée (règle de wake_program : une mise à
# jour fait passer ses appels par la nouvelle version), sinon ce programme lui-même (checkout, release essayée hors de current)
ginkgo_lab() {
  declare -F wake_program >/dev/null || . "$LAB_ROOT/lib/waiting.sh"
  if [ "$(cd "$LAB_HOME/current" 2>/dev/null && pwd -P)" = "$LAB_ROOT" ]; then wake_program; else printf '%s/bin/lab\n' "$LAB_ROOT"; fi
}
ginkgo_app_version() { sed -n 's:.*<key>CFBundleShortVersionString</key><string>\([^<]*\)</string>.*:\1:p' "$1/Contents/Info.plist" 2>/dev/null | head -1; }
# ginkgo_platform : Apple Silicon et macOS 14 ou plus (Info.plist : LSMinimumSystemVersion), sinon refus nommé ; le reste de treelab marche
ginkgo_platform() {
  local v; [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] \
    || die "Ginkgo needs a Mac with Apple Silicon (M1 or later); this Mac is not one: the rest of treelab works"
  v="$(sw_vers -productVersion 2>/dev/null || true)"
  case "${v%%.*}" in ''|*[!0-9]*) die "macOS version unreadable (sw_vers): Ginkgo needs macOS 14 or later" ;; esac
  [ "${v%%.*}" -ge 14 ] || die "Ginkgo needs macOS 14 or later; this Mac runs macOS $v: the rest of treelab works"
}
ginkgo_provider() { echo openai; }   # seul moteur de l'app avant le lot 05 (Gemini) : aucun réglage n'annonce un autre moteur
ginkgo_key_present() { security find-generic-password -s "$GINKGO_SERVICE" -a "$GINKGO_ACCOUNT" >/dev/null 2>&1; }
# security -i découpe sa ligne en mots : rien d'autre qu'une clé bien formée n'y entre
ginkgo_key_ok() { (LC_ALL=C; case "$1" in sk-*) ;; *) exit 1 ;; esac; case "$1" in *[!A-Za-z0-9_-]*) exit 1 ;; esac; [ "${#1}" -ge 20 ] && [ "${#1}" -le 400 ]); }
# ginkgo_source_hash : empreinte des sources Swift, une seule formule (scripts/ginkgo-build.sh --hash), recopiée dans l'app à sa
# fabrication — une app plus ancienne que ses sources est refaite au lancement
ginkgo_source_hash() { "$LAB_ROOT/scripts/ginkgo-build.sh" --hash 2>/dev/null || true; }
ginkgo_app_hash() { cat "$(ginkgo_app)/Contents/Resources/source-hash" 2>/dev/null || true; }

# ---------- lab ginkgo status ----------
ginkgo_status() {
  local app; app="$(ginkgo_app)"
  kv PROVIDER "$(ginkgo_provider)"
  if ginkgo_key_present; then kv KEY present; else kv KEY absent; fi
  if [ -d "$app" ]; then kv APP "$app"; else kv APP absent; fi
  kv SOURCE "$(ginkgo_source)"
  ginkgo_key_present || log_wrap "No OpenAI key yet: lab ginkgo key openai stores it in the macOS keychain."
}

# ---------- lab ginkgo key openai ----------
ginkgo_key() {
  [ "$#" = 1 ] && [ "$1" = openai ] || usage
  command -v security >/dev/null 2>&1 || die "macOS keychain not found (security command): no key stored"
  local k=""
  if [ -t 0 ]; then
    printf 'OpenAI API key (hidden, then Enter): ' >&2
    IFS= read -rs k || k=""; printf '\n' >&2
  else IFS= read -r k || true; fi
  k="${k%$'\r'}"; k="${k#"${k%%[![:space:]]*}"}"; k="${k%"${k##*[![:space:]]}"}"   # blancs de bord seulement : un blanc dedans est refusé
  ginkgo_key_ok "$k" || die "this does not look like an OpenAI API key (sk-…, letters, digits, - and _): nothing stored"
  printf 'add-generic-password -U -s %s -a %s -w %s\n' "$GINKGO_SERVICE" "$GINKGO_ACCOUNT" "$k" | security -i >/dev/null 2>&1 \
    || die "the keychain refused the key: nothing stored"
  [ "$(security find-generic-password -s "$GINKGO_SERVICE" -a "$GINKGO_ACCOUNT" -w 2>/dev/null)" = "$k" ] \
    || die "the keychain did not keep the key (security -i answers 0 even on a refusal, the read-back decides): nothing stored"
  kv KEY stored
  log_wrap "OpenAI key stored in the macOS keychain ($GINKGO_SERVICE). It is never displayed."
}

# ---------- lab ginkgo state <projet> : lecture seule, jamais de tour créée ----------
ginkgo_state() {
  [ "$#" -le 1 ] || usage
  local p wt; p="$(resolve_project "${1:-}")"; load_project "$p"
  wt="$(worktree_path "$TOWER_LANE")"
  kv PROJECT "$p"
  if [ -d "$wt" ] && lane_is_tower "$wt"; then kv TOWER present; sep; tower_view; return 0; fi
  kv TOWER absent
  log_wrap "No tower in $p: nothing read, nothing created (lab tower $p creates it)."
}

# ---------- outils communs (lot 02) ----------
# ginkgo_clean et ginkgo_fold : déplacés dans lib/words.sh (words_clean, words_fold), partagés avec les mots de l'utilisateur (lot 10
# d'autonomie-tours)
# ginkgo_human <sous-commande> : order, close et answer sont la voix de l'utilisateur (Ginkgo.app, lancée par open, ou son terminal),
# jamais l'agent d'un couloir ni la tour (revue du lot : l'agent d'un couloir aurait fait fermer un autre couloir)
ginkgo_human() {
  [ "$(caller_role)" = human ] || die "lab ginkgo $1 is the voice of the user (Ginkgo or their terminal): refused to an agent — nothing sent"
}
# ginkgo_lane <projet> <couloir> <suite du refus> : GK_WT, le dossier d'un couloir du projet ; tout autre nom est refusé
ginkgo_lane() {
  project_exists "$1" || die "unknown project: $1"
  load_project "$1"
  case "$2" in ''|.*|*[!A-Za-z0-9._-]*) die "invalid lane name: $2 — $3" ;; esac
  GK_WT="$(worktree_path "$2")"
  # le nom exact d'un dossier de .worktrees : le disque de macOS ignore la casse, « Tower » ouvrirait la tour sous un autre nom (revue)
  local d found=0
  for d in "$P_ROOT/.worktrees"/*; do [ "${d##*/}" != "$2" ] || found=1; done   # le glob rend les noms du disque, casse comprise
  [ "$found" = 1 ] && [ -d "$GK_WT/.lab" ] || die "no lane $2 in $1 — $3 (lab ginkgo state $1 lists the lanes)"
}
# ginkgo_tab <wt> <couloir> : GK_WS, GK_SURFACE, l'onglet du couloir (comme tell) ; aucun onglet sûr : refus
ginkgo_tab() {
  local tab
  has_cmux || die "cmux unreachable: nothing can be typed in $2 — nothing sent"
  tab="$(cmux_lane_tab "$(wt_ws "$1")" "$(wt_surface "$1")" "$2")"
  GK_WS="$(cmux_tab_field "$tab" workspace)"; GK_SURFACE="$(cmux_tab_field "$tab" surface)"
  case "$(cmux_tab_field "$tab" way)" in
    reference|name) ;;
    ambiguous) die "several tabs are named $2 in $P_NAME: nothing sent — lab open $P_NAME $2 names the right one" ;;
    *) die "lane $2 of $P_NAME has no open tab: nothing sent — lab next $P_NAME $2 opens it" ;;
  esac
}
# ginkgo_box <wt> : le fichier de la boîte, s'il est lisible et si le couloir attend encore (question, ou autorisation demandée
# pendant la boîte) ; une boîte sans attente est périmée (réponse arrivée, crochet d'une autre version)
ginkgo_box() {
  local q; q="$(waits_question_file "$1")"
  case "$(waits_get "$1" kind)" in question|permission) ;; *) return 1 ;; esac
  [ -s "$q" ] && jq -e '.questions | length > 0' "$q" >/dev/null 2>&1 && printf '%s\n' "$q"
}
ginkgo_now() { printf '%s\n' "${LAB_NOW_EPOCH:-$(date +%s)}"; }
ginkgo_iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z; }   # forme des horodatages du transcript de Claude Code
ginkgo_qid() { shasum -a 256 <"$1" | cut -c1-16; }
# ginkgo_said <wt> [depuis] : la dernière réponse de l'assistant lue dans le transcript de la session du couloir, en
# « <horodatage>\t<stop_reason>\t<texte> » ; rien si pas de transcript ou pas de réponse après <depuis>
# ginkgo_transcript <wt> : celui rangé par les crochets ; sinon (session lancée avant la mise à jour) le plus récent du dossier
# Claude du couloir — chaque caractère hors lettre et chiffre du chemin y devient « - », les sous-agents sont plus bas
ginkgo_transcript() {
  local t d; t="$(cat "$1/.lab/transcript" 2>/dev/null || true)"
  if [ -n "$t" ] && [ -f "$t" ]; then printf '%s\n' "$t"; return 0; fi
  d="$HOME/.claude/projects/$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')"
  [ -d "$d" ] || return 0
  # shellcheck disable=SC2012 # noms de session sans blanc (uuid)
  t="$(ls -t "$d"/*.jsonl 2>/dev/null | head -1)"; [ -z "$t" ] || printf '%s\n' "$t"
}
ginkgo_said() {
  local t; t="$(ginkgo_transcript "$1")"
  [ -n "$t" ] && [ -f "$t" ] || return 0
  tail -n 400 "$t" | jq -cR 'fromjson? | select(.type == "assistant")' 2>/dev/null | jq -rs --arg since "${2:-}" '
    [.[] | select((.timestamp // "") > $since) | select(any(.message.content[]?; .type == "text"))] | last // empty
    | [(.timestamp // ""), (.message.stop_reason // ""), ([.message.content[] | select(.type == "text") | .text] | join(" "))] | @tsv' 2>/dev/null || true
}
# ginkgo_said_after_order <wt> <depuis> : la réponse à l'ordre lui-même — après le premier prompt préfixé reçu depuis <depuis>, la
# première réponse finie, sinon la dernière en cours ; un point de la tour fini avant de prendre l'ordre n'en est pas la réponse (revue)
ginkgo_said_after_order() {
  local t; t="$(ginkgo_transcript "$1")"
  [ -n "$t" ] && [ -f "$t" ] || return 0
  # un ordre tapé pendant que la tour travaille arrive en pièce jointe du tour en cours (queued_command), pas en entrée « user »
  # (mesuré à l'essai réel du 2026-11-19, Claude Code 2.1.327)
  tail -n 400 "$t" | jq -cR 'fromjson? | select(.type == "assistant" or .type == "user" or (.type == "attachment" and .attachment.type == "queued_command"))' 2>/dev/null \
    | jq -rs --arg since "$2" --arg p "$GINKGO_ORDER_PREFIX" '
    def said: if .type == "attachment" then (.attachment.prompt // "" | tostring)
      else .message.content | if type == "string" then . else ([.[]? | select(.type == "text") | .text] | join(" ")) end end;
    (map(.type != "assistant" and (.timestamp // "") >= $since and (said | contains($p))) | index(true)) as $i
    | if $i == null then empty else
      [.[$i + 1:][] | select(.type == "assistant" and any(.message.content[]?; .type == "text"))] as $a
      | (([$a[] | select(.message.stop_reason == "end_turn")] | first) // ($a | last)) // empty
      | [(.timestamp // ""), (.message.stop_reason // ""), ([.message.content[] | select(.type == "text") | .text] | join(" "))] | @tsv end' 2>/dev/null || true
}
# ginkgo_message <texte tsv> <octets> : la fin du texte, là où est la question, en une ligne (le @tsv de jq échappe \n et \t)
ginkgo_message() {
  printf '%s' "$1" | cut -f3- | sed 's/\\[ntr]/ /g; s/\\\\/\\/g' | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177' \
    | LC_ALL=C tail -c "$2" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null || true
}
# ginkgo_send_text <texte> : collage dans l’onglet du couloir ; ginkgo_send_key <touche> ; --force : la boîte est ouverte (mesure §1)
ginkgo_send_text() {
  cmx send --force --workspace "$GK_WS" --surface "$GK_SURFACE" -- "$1" >/dev/null 2>&1 \
    || die "cmux refused a key in $GK_LANE: the box may be half answered — look at its tab"
  sleep "${LAB_GINKGO_KEY_DELAY:-0.3}"
}
ginkgo_send_key() {
  cmx send-key --force --workspace "$GK_WS" --surface "$GK_SURFACE" "$1" >/dev/null 2>&1 \
    || die "cmux refused a key in $GK_LANE: the box may be half answered — look at its tab"
  sleep "${LAB_GINKGO_KEY_DELAY:-0.3}"
}
# ginkgo_submit <texte> : un reste non envoyé dans la ligne de saisie est d'abord vidé (ctrl+u, mesuré sur Claude Code 2.1.327 :
# l'essai réel du lot 02 a remis « core » + l'ordre à la tour), puis collage et Entrée ; jamais forcé (une boîte ouverte fait refuser cmux)
ginkgo_submit() {
  cmux_submit "$GK_WS" "$GK_SURFACE" "$1" 2>/dev/null   # cmux_submit vide la ligne (ctrl+u) avant de coller
}
# ginkgo_wait_gone <fichier> : l'effacement par le crochet (PostToolUse, UserPromptSubmit) prouve la réponse reçue
ginkgo_wait_gone() {
  local n=0 max; max=$(( ${LAB_GINKGO_ANSWER_WAIT:-8} * 4 ))
  while [ -e "$1" ] && [ "$n" -lt "$max" ]; do sleep 0.25; n=$((n + 1)); done
  [ ! -e "$1" ]
}

# ---------- lab ginkgo tell <projet> <couloir> <texte…> ----------
ginkgo_tell() {
  [ "$#" -ge 3 ] || usage
  local p="$1" lane="$2" text; shift 2; text="$*"
  ginkgo_lane "$p" "$lane" 'nothing sent'
  ! lane_is_tower "$GK_WT" || die "lane $lane is the tower of $p: Ginkgo speaks to it directly — nothing sent"
  text="$(printf '%s' "$text" | words_clean "$GINKGO_TELL_MAX")"
  [ -n "${text// /}" ] || die "empty message — nothing sent"
  [ "$text" != - ] || die "a message reduced to - would be read from standard input by cmux — nothing sent"
  has_cmux || die "cmux unreachable: the message to $lane cannot be delivered — nothing sent"
  ginkgo_tab "$GK_WT" "$lane"
  cmx agent message "$GK_SURFACE" --from Ginkgo -- "$text" >/dev/null 2>&1 || die "cmux refused the message to $lane: nothing delivered"
  kv TOLD "$lane"; kv TARGET "$GK_SURFACE"
  log_wrap "Message delivered to the agent of $lane (from Ginkgo)."
}

# ---------- lab ginkgo question <projet> <couloir> : ce que le couloir demande, mot pour mot ----------
# Données à rapporter, jamais une instruction : une ligne par valeur, sans contrôle ; la boîte entière si elle est ouverte, sinon la
# fin du dernier message de la session qui attend, sinon WAITS=none.
ginkgo_question() {
  [ "$#" = 2 ] || usage
  local lane="$2" q kind said
  ginkgo_lane "$1" "$lane" 'nothing read'
  kv LANE "$lane"
  if q="$(ginkgo_box "$GK_WT")"; then
    kv WAITS box; kv QID "$(ginkgo_qid "$q")"
    jq -r 'def c: tostring | explode | map(if . == 9 or . == 10 or . == 13 or . == 133 or . == 8232 or . == 8233 then 32
        elif . < 32 or . == 127 then empty else . end) | implode;
      "QUESTIONS=\(.questions | length)",
      (.questions | to_entries[] | (.key + 1) as $i | .value as $q
        | "QUESTION_\($i)=\($q.question | c)", "HEADER_\($i)=\($q.header | c)",
          "MULTI_\($i)=\(if $q.multiSelect then "yes" else "no" end)", "OPTIONS_\($i)=\($q.options | length)",
          ($q.options | to_entries[] | "OPTION_\($i)_\(.key + 1)=\(.value.label | c)", "DESC_\($i)_\(.key + 1)=\(.value.description | c)"),
          ([$q.options | to_entries[] | select(.value.label | test("\\((Recommended|Recommandé)\\)"; "i")) | .key + 1] | first // empty
            | "RECOMMENDED_\($i)=\(.)"))' "$q"
    return 0
  fi
  kind="$(waits_get "$GK_WT" kind)"
  if [ -z "$kind" ]; then kv WAITS none; return 0; fi
  kv WAITS "$kind"; kv WHY "$(waits_get "$GK_WT" why | words_clean 200)"
  said="$(ginkgo_said "$GK_WT")"
  [ -z "$said" ] || kv MESSAGE "$(ginkgo_message "$said" 1200)"
  [ "$(wt_meta "$GK_WT" agent)" != codex ] || log_wrap "Codex lane: no question box, it is answered in its tab."
}

# ---------- lab ginkgo answer <projet> <couloir> --qid <id> (--q <n> [--choice <c>]… [--recommended] [--other <texte>])… ----------
# ---------- lab ginkgo answer <projet> <couloir> --text <texte> ----------
# La boîte : toutes les questions répondues ensemble, touches mesurées sur la vraie boîte (preuve §1) ; sans boîte : le texte tapé
# puis Entrée, comme un prompt. Tout est vérifié avant la première touche ; la réponse est prouvée par l'effacement de l'attente.
ginkgo_norm() { printf '%s' "$1" | sed -E 's/[[:space:]]*\((Recommended|Recommandé|recommended|recommandé)\)[[:space:]]*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' | tr '[:upper:]' '[:lower:]'; }
ginkgo_answer() {
  [ "$#" -ge 4 ] || usage
  local p="$1" lane="$2" qid="" text="" has_text=0 cur=0 qmax=0 qf n i; shift 2
  local -a CH=() REC=() OT=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --qid) [ "$#" -ge 2 ] || usage; qid="$2"; shift 2 ;;
      --text) [ "$#" -ge 2 ] || usage; text="$2"; has_text=1; shift 2 ;;
      --q) [ "$#" -ge 2 ] || usage; case "$2" in [1-9]) cur="$2" ;; *) die "--q takes a question number (1 to 9): $2 — nothing sent" ;; esac
        [ "$cur" -le "$qmax" ] || qmax="$cur"; shift 2 ;;
      --choice|--other)
        [ "$#" -ge 2 ] || usage; [ "$cur" -gt 0 ] || die "$1 needs --q <n> before it — nothing sent"
        if [ "$1" = --choice ]; then CH[cur]="${CH[cur]:-}${2}"$'\037'; else OT[cur]="$2"; fi; shift 2 ;;
      --recommended) [ "$cur" -gt 0 ] || die "--recommended needs --q <n> before it — nothing sent"; REC[cur]=1; shift ;;
      *) usage ;;
    esac
  done
  ginkgo_lane "$p" "$lane" 'nothing sent'
  ginkgo_human answer
  GK_LANE="$lane"; qf="$(waits_question_file "$GK_WT")"
  if [ "$has_text" = 1 ]; then
    [ -z "$qid" ] && [ "$cur" = 0 ] || usage
    ginkgo_answer_text "$p" "$lane" "$text" "$qf"; return
  fi
  [ -n "$qid" ] || usage
  ginkgo_box "$GK_WT" >/dev/null || die "lane $lane has no question box open any more (answered or gone): nothing sent — lab ginkgo question $p $lane"
  [ "$(ginkgo_qid "$qf")" = "$qid" ] || die "the question of lane $lane changed since it was read: nothing sent — read it again (lab ginkgo question $p $lane)"
  n="$(jq -r '.questions | length' "$qf")"
  [ "$qmax" -le "$n" ] || die "question $qmax does not exist in the box of $lane ($n questions) — nothing sent"
  # une question de fermeture posée par la tour ne se règle jamais par un choix : la relecture de close s'impose (revue du lot)
  if lane_is_tower "$GK_WT" && jq -r '.questions[] | .question, .header, .options[].label' "$qf" | ginkgo_closing; then
    die "a close asked by the tower is never answered by a choice: lab ginkgo close $p <lane> reads it back first — nothing sent"
  fi
  # résolution de chaque question avant la première touche : PLAN_i = « single <k> », « other <texte> », « multi <k…>|<texte> »
  local -a PLAN=() SENT=()
  local m multi rec labels c k sel other ln lab
  for ((i = 1; i <= n; i++)); do
    m="$(jq -r --argjson i "$i" '.questions[$i - 1].options | length' "$qf")"
    multi="$(jq -r --argjson i "$i" '.questions[$i - 1].multiSelect' "$qf")"
    labels="$(jq -r --argjson i "$i" '.questions[$i - 1].options[].label' "$qf")"
    sel=" "
    while IFS= read -r -d $'\037' c; do
      k=""
      # un numéro, ou la clé lue par question (OPTION_<i>_<k>, donnée par le modèle à l'essai réel) de cette question seulement
      case "$c" in [1-9]) [ "$c" -le "$m" ] && k="$c" ;; "OPTION_${i}_"[1-9]) [ "${c##*_}" -le "$m" ] && k="${c##*_}" ;; esac
      if [ -z "$k" ]; then
        ln=0; while IFS= read -r lab; do ln=$((ln + 1)); [ "$(ginkgo_norm "$lab")" != "$(ginkgo_norm "$c")" ] || { k="$ln"; break; }; done <<<"$labels"
      fi
      [ -n "$k" ] || die "unknown choice \"$c\" for question $i of $lane (choices: $(printf '%s' "$labels" | paste -sd ';' - | sed 's/;/; /g')) — nothing sent"
      case "$sel" in *" $k "*) ;; *) sel="$sel$k " ;; esac
    done <<<"${CH[i]:-}"
    if [ "${REC[i]:-0}" = 1 ]; then
      rec="$(jq -r --argjson i "$i" '[.questions[$i - 1].options | to_entries[] | select(.value.label | test("\\((Recommended|Recommandé)\\)"; "i")) | .key + 1] | first // empty' "$qf")"
      [ -n "$rec" ] || die "question $i of $lane has no recommended choice — nothing sent"
      case "$sel" in *" $rec "*) ;; *) sel="$sel$rec " ;; esac
    fi
    other="$(printf '%s' "${OT[i]:-}" | words_clean 500)"; other="${other#"${other%%[![:space:]]*}"}"
    [ "$other" != - ] || other=""
    # shellcheck disable=SC2086 # les numéros choisis, un par mot
    set -- $sel
    if [ "$multi" != true ]; then
      [ "$#" -le 1 ] || die "question $i of $lane takes one choice, $# given — nothing sent"
      if [ "$#" = 0 ] && [ -z "$other" ]; then die "question $i of $lane is not answered — nothing sent (every question of the box goes together)"; fi
      if [ -n "$other" ]; then
        [ "$#" = 0 ] || other="$(ginkgo_norm_label "$(printf '%s\n' "$labels" | sed -n "${1}p")") — $other"
        PLAN[i]="other $m $other"; SENT[i]="$other"
      else PLAN[i]="single $1"; SENT[i]="$(printf '%s\n' "$labels" | sed -n "${1}p")"; fi
    else
      [ "$#" -gt 0 ] || [ -n "$other" ] || die "question $i of $lane is not answered — nothing sent (every question of the box goes together)"
      PLAN[i]="multi $m $*|$other"
      SENT[i]="$(for k in "$@"; do printf '%s\n' "$labels" | sed -n "${k}p"; done | paste -sd ',' - | sed 's/,/, /g')"
      [ -z "$other" ] || SENT[i]="${SENT[i]:+${SENT[i]}, }$other"
    fi
  done
  # lot 10 d'autonomie-tours (revue) : une réponse que le crochet de lab lirait comme l'accord de l'utilisateur (words_match) ne part
  # jamais d'un choix ni d'un texte libre — la relecture à voix haute de lab ginkgo close s'impose
  # dans la tour, le crochet juge avec tous les couloirs du projet : la garde aussi (revue de sécurité)
  local wl="$lane" wn="$lane"; ! lane_is_tower "$GK_WT" || { wl="$(words_lanes | tr '\n' ' ')"; wn='<lane>'; }
  for ((i = 1; i <= n; i++)); do
    # shellcheck disable=SC2086 # noms de couloir : des mots
    ! words_match "${SENT[i]}" $wl >/dev/null || die "accepting or closing a lane is never a free answer: lab ginkgo close $p $wn reads it back first — nothing sent"
  done
  ginkgo_tab "$GK_WT" "$lane"
  # la boîte doit être à l'écran avant toute touche forcée : fermée par Échap (sans PostToolUse), ses touches deviendraient un prompt
  cmx read-screen --workspace "$GK_WS" --surface "$GK_SURFACE" 2>/dev/null | grep -q 'Type something' \
    || die "the box of $lane is not on screen (closed in its tab?): nothing sent — look at its tab"
  # les touches, question par question (preuve §1)
  local plan keys rest d
  for ((i = 1; i <= n; i++)); do
    plan="${PLAN[i]}"
    case "$plan" in
      single\ *) ginkgo_send_text "${plan#single }" ;;
      other\ *) rest="${plan#other }"; m="${rest%% *}"; ginkgo_send_text "$((m + 1))"; ginkgo_send_text "${rest#* }"; ginkgo_send_key enter ;;
      multi\ *)
        rest="${plan#multi }"; m="${rest%% *}"; rest="${rest#* }"; keys="${rest%%|*}"; other="${rest#*|}"
        for k in $keys; do ginkgo_send_text "$k"; done
        if [ -n "$other" ]; then
          ginkgo_send_text "$((m + 1))"; for ((d = 0; d < m; d++)); do ginkgo_send_key down; done
          ginkgo_send_text "$other"; ginkgo_send_key down
        else for ((d = 0; d <= m; d++)); do ginkgo_send_key down; done; fi
        ginkgo_send_key enter ;;
    esac
  done
  [ "$n" = 1 ] || ginkgo_send_text 1   # l'écran « Review your answers » : 1. Submit answers
  kv LANE "$lane"
  for ((i = 1; i <= n; i++)); do kv "SENT_$i" "${SENT[i]}"; done
  if ginkgo_wait_gone "$qf"; then kv ANSWERED yes; log_wrap "Answer received by $lane."
  else kv ANSWERED unseen; log_wrap "Keys sent, but the box of $lane is still open: look at its tab."; fi
}
ginkgo_norm_label() { printf '%s' "$1" | sed -E 's/[[:space:]]*\((Recommended|Recommandé|recommended|recommandé)\)[[:space:]]*$//'; }
ginkgo_answer_text() { # <projet> <couloir> <texte> <fichier de boîte>
  local wf; wf="$(waits_file "$GK_WT")"
  ! ginkgo_box "$GK_WT" >/dev/null || die "lane $2 has a question box open: answer it with --qid (lab ginkgo question $1 $2) — nothing sent"
  ! lane_is_tower "$GK_WT" || die "lane $2 is the tower of $1: lab ginkgo order types an order in it — nothing sent"
  [ -s "$wf" ] || die "lane $2 waits for nothing: lab ginkgo tell $1 $2 passes a message — nothing sent"
  local text; text="$(printf '%s' "$3" | words_clean "$GINKGO_TELL_MAX")"
  [ -n "${text// /}" ] || die "empty answer — nothing sent"
  [ "$text" != - ] || die "an answer reduced to - would be read from standard input by cmux — nothing sent"
  ! WORDS_BARE=1 words_match "$text" "$2" >/dev/null || die "accepting or closing lane $2 is never a free answer: lab ginkgo close $1 $2 reads it back first — nothing sent"
  ginkgo_tab "$GK_WT" "$2"
  ginkgo_submit "$text" || die "cmux refused to type in $2 (a dialog may be open there): nothing delivered"
  kv LANE "$2"; kv SENT "$text"
  if ginkgo_wait_gone "$wf"; then kv ANSWERED yes; log_wrap "Answer received by $2."
  else kv ANSWERED unseen; log_wrap "Answer typed in $2, not yet seen by its session: look at its tab."; fi
}

# ---------- lab ginkgo order <projet> <texte…> : un ordre dit, tapé dans l'onglet de la tour ----------
GINKGO_ORDER_PREFIX='Ginkgo, voice of the user:'
# ginkgo_is_close <texte> : fermer, abandonner, retirer ou supprimer un couloir ne passe jamais par un ordre libre
ginkgo_closing() {   # sur l'entrée standard, une ligne ou plusieurs
  words_fold | LC_ALL=C grep -Eq '(^|[^a-z])(ferm[a-z]*|clos[a-z]*|clore|clotur[a-z]*|abandon[a-z]*|retir[a-z]*|supprim[a-z]*|enlev[a-z]*|delete[a-z]*|remov[a-z]*|discard[a-z]*)([^a-z]|$)'
}
ginkgo_is_close() { printf '%s' "$1" | ginkgo_closing; }
ginkgo_tower() { # <projet> : GK_WT, le dossier de la tour
  project_exists "$1" || die "unknown project: $1"
  load_project "$1"
  GK_WT="$(worktree_path "$TOWER_LANE")"
  if [ ! -d "$GK_WT" ] || ! lane_is_tower "$GK_WT"; then die "no tower in $1: lab tower $1 creates it — nothing sent"; fi
}
ginkgo_tower_send() { # <projet> <texte déjà assaini> : tapé puis Entrée, jamais forcé (cmux refuse une boîte ouverte)
  ! ginkgo_box "$GK_WT" >/dev/null \
    || die "the tower of $1 has a question box open: answer it first (lab ginkgo question $1 $TOWER_LANE) — nothing sent"
  GK_LANE="$TOWER_LANE"; ginkgo_tab "$GK_WT" "$TOWER_LANE"
  local now; now="$(ginkgo_now)"
  ginkgo_submit "$GINKGO_ORDER_PREFIX $2" \
    || die "cmux refused to type in the tower of $1 (a dialog may be open there): nothing delivered"
  kv TARGET "$GK_SURFACE"; kv SINCE "$(ginkgo_iso "$now")"
}
ginkgo_order() {
  [ "$#" -ge 2 ] || usage
  local p="$1" text; shift; text="$*"
  ginkgo_tower "$p"
  ginkgo_human order
  text="$(printf '%s' "$text" | words_clean "$GINKGO_TELL_MAX")"
  [ -n "${text// /}" ] || die "empty order — nothing sent"
  ! ginkgo_is_close "$text" || die "closing a lane is never a free order: lab ginkgo close $p <lane> reads it back first — nothing sent"
  # la formule de la fermeture confirmée n'appartient qu'à lab ginkgo close (revue de sécurité du lot)
  ! printf '%s' "$text" | words_fold | LC_ALL=C grep -Eq 'confirm[a-z]*[^a-z]*(aloud|out[^a-z]*loud)|voix haute' \
    || die "\"confirmed aloud\" is written by only lab ginkgo close, after a read-back — nothing sent"
  ginkgo_tower_send "$p" "$text"
  kv ORDERED yes
  log_wrap "Order typed in the tower of $p; lab ginkgo reply $p --since <SINCE> reads its answer."
}

# ginkgo_close_tower_box <projet> <couloir> : la tour demande elle-même « je ferme <couloir> ? » (essai réel du 2026-11-19) — la
# fermeture relue et confirmée à voix haute répond à sa place : Échap ferme la boîte (sans PostToolUse : l'entrée est retirée ici),
# puis l'ordre confirmé est tapé ; toute autre boîte de la tour reste un refus de ginkgo_tower_send
ginkgo_close_tower_box() {
  local qf; qf="$(waits_question_file "$GK_WT")"
  ginkgo_box "$GK_WT" >/dev/null || return 0
  jq -r '.questions[] | .question, .header, .options[].label' "$qf" | ginkgo_closing || return 0
  jq -r '.questions[] | .question, .header' "$qf" | grep -qF -- "$2" || return 0
  GK_LANE="$TOWER_LANE"; ginkgo_tab "$GK_WT" "$TOWER_LANE"
  ginkgo_send_key escape
  ! cmx read-screen --workspace "$GK_WS" --surface "$GK_SURFACE" 2>/dev/null | grep -q 'Type something' \
    || die "the close box of the tower stayed open after Escape: nothing closed — look at its tab"
  rm -f "$qf"
}
# ---------- lab ginkgo close <projet> <couloir> [--confirm <jeton>] : relu, puis ordonné à la tour ----------
GINKGO_CLOSE_TTL=120
ginkgo_close() {
  [ "$#" = 2 ] || [ "$#" = 4 ] || usage
  local p="$1" lane="$2" token="" f now at plane ptoken
  if [ "$#" = 4 ]; then [ "$3" = --confirm ] || usage; token="$4"; fi
  ginkgo_lane "$p" "$lane" 'nothing closed'
  ginkgo_human close
  ! lane_is_tower "$GK_WT" || die "lane $lane is the tower of $p: it is never closed by voice — nothing closed"
  f="$LAB_STATE/$p/ginkgo/close-pending"; now="$(ginkgo_now)"
  if [ -z "$token" ]; then
    token="$(LC_ALL=C od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
    mkdir -p "$(dirname "$f")"
    ( umask 077; printf 'lane=%s\ntoken=%s\nat=%s\n' "$lane" "$token" "$now" >"$f.tmp.$$" && mv "$f.tmp.$$" "$f" ) || die "cannot write $f: nothing to confirm"
    kv LANE "$lane"; kv READBACK "Close lane $lane of $p: the tower delivers it, then removes its folder and its branch. Say yes to confirm."
    kv TOKEN "$token"; kv EXPIRES_IN "$GINKGO_CLOSE_TTL"
    return 0
  fi
  [ -s "$f" ] || die "no close read back for $p: nothing closed — lab ginkgo close $p $lane reads it back first"
  plane="$(sed -n 's/^lane=//p' "$f")"; ptoken="$(sed -n 's/^token=//p' "$f")"; at="$(sed -n 's/^at=//p' "$f")"
  rm -f "$f"   # un seul essai : tout refus redemande une relecture
  [ -n "$ptoken" ] && [ "$token" = "$ptoken" ] || die "wrong confirmation token: nothing closed — read it back again (lab ginkgo close $p $lane)"
  [ "$plane" = "$lane" ] || die "the read-back was for lane $plane, not $lane: nothing closed"
  case "$at" in ''|*[!0-9]*) die "unreadable read-back: nothing closed" ;; esac
  [ "$((now - at))" -ge 0 ] && [ "$((now - at))" -le "$GINKGO_CLOSE_TTL" ] \
    || die "the read-back is older than $GINKGO_CLOSE_TTL s: nothing closed — read it back again"
  ginkgo_tower "$p"
  ginkgo_close_tower_box "$p" "$lane"
  # lot 10 d'autonomie-tours : la marque que lit le crochet de la tour (words_ginkgo) — la formule tapée vient de lab, pas d'un agent
  ( umask 077; printf 'lane=%s\nat=%s\n' "$lane" "$now" >"$f.sent.$$" && mv "$f.sent.$$" "$LAB_STATE/$p/ginkgo/close-sent" ) \
    || die "cannot write the close mark in $LAB_STATE/$p/ginkgo: nothing closed"
  ginkgo_tower_send "$p" "close lane $lane of $p (lab close $p $lane), confirmed aloud by the user at $(date -u -r "$now" +%Y-%m-%dT%H:%M:%SZ)."
  kv LANE "$lane"; kv CLOSE ordered
  log_wrap "Close of $lane ordered to the tower of $p, confirmed aloud."
}

# ---------- lab ginkgo reply <projet> [--since <horodatage>] : la réponse de la tour, lue dans son transcript ----------
ginkgo_reply() {
  [ "$#" = 1 ] || [ "$#" = 3 ] || usage
  local p="$1" since="" said
  if [ "$#" = 3 ]; then [ "$2" = --since ] || usage; since="$3"; fi
  case "$since" in *T*Z) case "$since" in *.*) ;; *) since="${since%Z}.000Z" ;; esac ;; '') ;; *) die "--since takes a UTC time like 2026-11-18T09:00:00Z: $since" ;; esac
  ginkgo_tower "$p"
  if [ -n "$since" ]; then said="$(ginkgo_said_after_order "$GK_WT" "$since")"; else said="$(ginkgo_said "$GK_WT")"; fi
  if [ -z "$said" ]; then kv REPLY none; return 0; fi
  kv AT "$(printf '%s' "$said" | cut -f1)"
  if [ "$(printf '%s' "$said" | cut -f2)" = end_turn ]; then kv TURN 'done'; else kv TURN running; fi
  kv REPLY "$(ginkgo_message "$said" 1200)"
}

# ---------- lab ginkgo news <projet> --open yes|no | --baseline : parler de soi-même (lot 03) ----------
# Ce qui attend la personne et ne lui a pas encore été dit, et par où le dire : CHANNEL=voice (conversation ouverte), notify
# (fermée), hold (fermée pendant les heures calmes : retenu, récapitulé au premier passage après elles), none. Le bash décide ;
# Ginkgo.app relit toutes les 10 s et ne fait que dire ou notifier. Lecture seule, sauf son fichier $LAB_STATE/<projet>/ginkgo/news
# (told=<clé> dit ou vu, held=<clé> retenu) ; clé = couloir|sorte|empreinte du QID de la boîte, sinon de at=, sinon du motif : une attente qui change
# (nouvelle question, nouvelle date) est annoncée de nouveau, une clé disparue est oubliée. --forget <clé> : une annonce vocale que
# l'app n'a pas pu dire (conversation fermée avant) redevient nouvelle, et la même relecture décide de nouveau (revue du lot).
GINKGO_QUIET_DEFAULT=21:00-08:00
GINKGO_NEWS_TEXT_MAX=200   # octets de NEW_n_TEXT, comme WHY= de lab ginkgo question
ginkgo_speak_mode() {
  local v; v="$(global_config_get ginkgo_speak | tr -d '[:space:]')"
  case "$v" in
    ''|always) echo always ;; conversation|never) echo "$v" ;;
    *) log_wrap "ginkgo_speak=$v in ~/.lab/config is not always, conversation or never: always is used."; echo always ;;
  esac
}
ginkgo_minute() { case "$1" in [0-9]:[0-5][0-9]|[01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) echo $(( 10#${1%%:*} * 60 + 10#${1#*:} )) ;; *) return 1 ;; esac; }
# ginkgo_quiet_range → « <début> <fin> » en minutes du jour, ou off ; une valeur illisible : la plage par défaut, avertie sur stderr
ginkgo_quiet_range() {
  local v s e; v="$(global_config_get ginkgo_quiet | tr -d '[:space:]')"; v="${v:-$GINKGO_QUIET_DEFAULT}"
  if [ "$v" = off ]; then echo off; return 0; fi
  if [ "${v#*-}" != "$v" ] && s="$(ginkgo_minute "${v%%-*}")" && e="$(ginkgo_minute "${v#*-}")" && [ "$s" != "$e" ]; then
    echo "$s $e"; return 0
  fi
  log_wrap "ginkgo_quiet=$v in ~/.lab/config is not HH:MM-HH:MM or off: $GINKGO_QUIET_DEFAULT is used."
  echo "$(ginkgo_minute "${GINKGO_QUIET_DEFAULT%-*}") $(ginkgo_minute "${GINKGO_QUIET_DEFAULT#*-}")"
}
# ginkgo_quiet_now <début fin|off> → yes|no à l'heure locale du Mac (TZ) ; début compris, fin exclue ; une plage passe minuit ou non
ginkgo_quiet_now() {
  [ "$1" != off ] || { echo no; return 0; }
  local s="${1% *}" e="${1#* }" t m; t="$(date -r "$(ginkgo_now)" +%H:%M)"; m=$(( 10#${t%%:*} * 60 + 10#${t#*:} ))
  if [ "$s" -lt "$e" ]; then
    if [ "$m" -ge "$s" ] && [ "$m" -lt "$e" ]; then echo yes; else echo no; fi
  elif [ "$m" -ge "$s" ] || [ "$m" -lt "$e" ]; then echo yes; else echo no; fi
}
# ginkgo_waits : une ligne par attente de la personne, « <clé>\t<couloir>\t<sorte>\t<texte> », dans l'ordre des couloirs — ce que la
# vue de la tour range dans WAITING_FOR_YOU (une recette sur check: seul est l'affaire de la tour), plus question|permission de la tour
ginkgo_waits() {
  local wt lane kind tok text q
  for wt in "$P_ROOT"/.worktrees/*/; do
    [ -d "$wt" ] || continue; wt="${wt%/}"; lane="$(wt_lane "$wt")"
    case "$lane" in ''|.*|*[!A-Za-z0-9._-]*) continue ;; esac
    kind="$(waits_get "$wt" kind)"
    if lane_is_tower "$wt"; then
      case "$kind" in question|permission) ;; *) continue ;; esac
      tok="at=$(waits_get "$wt" at)"; text="$(waits_get "$wt" why)"
    else
      tower_waits_for "$wt"
      case "$TW_WAITS:$TW_EVIDENCE" in acceptance:check) continue ;; you:*|acceptance:*) ;; *) continue ;; esac
      case "$kind" in
        question|permission|blocked) tok="at=$(waits_get "$wt" at)"; text="$(waits_get "$wt" why)" ;;
        *)   # la phase seule : son motif, sans date, fait l'empreinte ; le texte de la sorte est dit par Ginkgo
          case "$TW_PHASE" in 'in acceptance') kind=acceptance ;; 'acceptance passed') kind=closing ;; *) kind=blocked ;; esac
          tok="why=$TW_WHY"; text="" ;;
      esac
    fi
    # une boîte capturée (lot 02) a pour clé son QID : la Notification d'autorisation que Claude Code envoie pendant la boîte
    # réécrit l'attente (permission, nouvelle date) sans en faire une nouvelle (essai réel du 2026-11-20 : annoncée deux fois)
    case "$kind" in
      question|permission)
        if q="$(ginkgo_box "$wt")"; then
          kind=question; tok="qid=$(ginkgo_qid "$q")"; text="$(jq -r '.questions[0].question // empty' "$q" 2>/dev/null || true)"
        fi ;;
    esac
    printf '%s|%s|%s\t%s\t%s\t%s\n' "$lane" "$kind" "$(printf '%s' "$tok" | shasum -a 256 | cut -c1-16)" "$lane" "$kind" \
      "$(printf '%s' "$text" | words_clean "$GINKGO_NEWS_TEXT_MAX")"
  done
}
ginkgo_has() { case $'\n'"$1"$'\n' in *$'\n'"$2"$'\n'*) return 0 ;; esac; return 1; }   # <liste, une par ligne> <élément>
ginkgo_drop() { local k; while IFS= read -r k; do if [ -n "$k" ] && ! ginkgo_has "$2" "$k"; then printf '%s\n' "$k"; fi; done <<<"$1"; }
ginkgo_news() {
  [ "$#" -ge 2 ] || usage
  local p="$1" open="" base=0 forget=""; shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --open) [ "$#" -ge 2 ] || usage; case "$2" in yes|no) open="$2" ;; *) usage ;; esac; shift 2 ;;
      --baseline) base=1; shift ;;
      --forget) [ "$#" -ge 2 ] || usage; case "$2" in ''|*[!A-Za-z0-9._\|-]*) usage ;; esac; forget="$forget$2"$'\n'; shift 2 ;;
      *) usage ;;
    esac
  done
  if [ "$base" = 1 ]; then [ -z "$open" ] && [ -z "$forget" ] || usage; else [ -n "$open" ] || usage; fi
  project_exists "$p" || die "unknown project: $p"
  load_project "$p"
  # la mémoire de ce qui a été dit à la personne : un agent qui la viderait ferait taire une attente (revue de sécurité du lot)
  ginkgo_human news
  local speak range quiet f cur told held line key all="" fresh="" kept="" say="" recap="" channel=none keep_held=""
  speak="$(ginkgo_speak_mode)"; range="$(ginkgo_quiet_range)"; quiet="$(ginkgo_quiet_now "$range")"
  f="$LAB_STATE/$p/ginkgo/news"
  told="$(sed -n 's/^told=//p' "$f" 2>/dev/null || true)"; held="$(sed -n 's/^held=//p' "$f" 2>/dev/null || true)"
  [ -z "$forget" ] || { told="$(ginkgo_drop "$told" "$forget")"; held="$(ginkgo_drop "$held" "$forget")"; }
  cur="$(ginkgo_waits)"
  # chaque attente présente : déjà dite ou vue, retenue cette nuit, ou nouvelle ; les clés absentes sont oubliées
  while IFS= read -r line; do
    [ -n "$line" ] || continue; key="${line%%$'\t'*}"; all="$all$key"$'\n'
    if ginkgo_has "$told" "$key"; then continue; fi
    if ginkgo_has "$held" "$key"; then kept="$kept$line"$'\n'; elif [ "$base" = 0 ]; then fresh="$fresh$line"$'\n'; fi
  done <<<"$cur"
  if [ "$base" = 1 ]; then keep_held="$kept"   # une relance de nuit garde ce qui attend le récapitulatif (revue du lot)
  elif [ "$speak" = never ]; then :
  elif [ "$open" = yes ]; then say="$kept$fresh"; [ -z "$say" ] || channel=voice   # heures calmes comprises : la personne a ouvert
  elif [ "$speak" = conversation ]; then :   # vue conversation fermée : jamais annoncée plus tard
  elif [ "$quiet" = yes ]; then say="$fresh"; keep_held="$kept$fresh"; [ -z "$fresh" ] || channel=hold
  elif [ -n "$kept" ]; then recap="$kept$fresh"; channel=notify   # premier passage après la plage : un seul récapitulatif
  else say="$fresh"; [ -z "$fresh" ] || channel=notify; fi
  # mémoire : tout ce qui est présent est dit ou vu, sauf ce qui reste retenu
  local out="" k
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    if ginkgo_has "$(printf '%s' "$keep_held" | cut -f1)" "$k"; then out="${out}held=$k"$'\n'; else out="${out}told=$k"$'\n'; fi
  done <<<"$all"
  mkdir -p "$(dirname "$f")"
  ( umask 077; printf '%s' "$out" >"$f.tmp.$$" && mv "$f.tmp.$$" "$f" ) || die "cannot write $f: nothing announced"
  kv SPEAK "$speak"; kv QUIET "$quiet"; kv CHANNEL "$channel"
  local n=0 r=0 i lane kind text
  n="$(printf '%s' "$say" | grep -c . || true)"; r="$(printf '%s' "$recap" | grep -c . || true)"
  kv NEW "$n"; i=0
  while IFS=$'\t' read -r key lane kind text; do
    [ -n "$key" ] || continue; i=$((i + 1))
    kv "NEW_${i}_LANE" "$lane"; kv "NEW_${i}_KIND" "$kind"; kv "NEW_${i}_TEXT" "$text"; kv "NEW_${i}_KEY" "$key"
  done <<<"$say"
  kv RECAP "$r"; i=0
  while IFS=$'\t' read -r key lane kind text; do
    [ -n "$key" ] || continue; i=$((i + 1)); kv "RECAP_${i}_LANE" "$lane"; kv "RECAP_${i}_KEY" "$key"
  done <<<"$recap"
  case "$channel" in
    voice) log_wrap "$n new for you in $p: Ginkgo says it out loud." ;;
    notify) if [ "$r" -gt 0 ]; then log_wrap "Quiet hours over: $r still wait for you in $p, in one notification."
            else log_wrap "$n new for you in $p: a Ginkgo notification."; fi ;;
    hold) log_wrap "$n new for you in $p, held for the end of the quiet hours." ;;
    *) [ "$base" = 0 ] || log_wrap "What waits now in $p is seen: only what comes next is announced." ;;
  esac
}

# ---------- lab ginkgo [projet] : lance l'app sur ce projet ----------
ginkgo_build() {
  local b="${LAB_GINKGO_BUILD:-$LAB_ROOT/scripts/ginkgo-build.sh}"
  [ -x "$b" ] || die "Ginkgo.app is missing and cannot be built here ($b): lab update brings it"
  log_wrap "Building Ginkgo.app (Swift), about one minute the first time…"
  "$b" --output "${LAB_GINKGO_APP_DIR:-$(ginkgo_dir)}" --scratch "$(ginkgo_dir)/build" >&2 || die "Ginkgo.app build failed: see the output above"
}
ginkgo_launch() {
  [ "$#" -le 1 ] || usage
  local p app hash; p="$(resolve_project "${1:-}")"; load_project "$p"
  ginkgo_platform
  if ! ginkgo_key_present; then
    # premier lancement (lot 04) : dans un terminal, la clé est demandée masquée et rangée, puis l'app s'ouvre ; ailleurs, refus
    [ -t 0 ] || die "no OpenAI key in the keychain: lab ginkgo key openai stores it once, then lab ginkgo $p"
    log_wrap "Ginkgo answers with your own OpenAI API key, asked once and stored in the macOS keychain."
    ginkgo_key openai
  fi
  app="$(ginkgo_app)"; mkdir -p "$(ginkgo_dir)"
  if ginkgo_release; then
    [ -d "$app" ] || die "Ginkgo.app is missing from this treelab version ($app): install a version that ships it with treelab update"
  else
    hash="$(ginkgo_source_hash)"
    if [ ! -d "$app" ] || { [ -n "$hash" ] && [ "$hash" != "$(ginkgo_app_hash)" ]; }; then ginkgo_build; kv BUILT yes; fi
    [ -d "$app" ] || die "Ginkgo.app not found after its build: $app"
  fi
  # une seule app à la fois : celle d'un autre projet se ferme (micro et connexion fermés avec elle)
  pkill -x Ginkgo >/dev/null 2>&1 || true
  local i=0; while pgrep -x Ginkgo >/dev/null 2>&1 && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done   # sinon macOS réactive l'ancienne
  # l'app relance lab : même registre, même état que cette commande (comme launch_registry et l'alarme de lab wake)
  local -a env=(--env "PATH=$PATH" --env "LAB_HOME=$LAB_HOME")
  [ -z "${LAB_PROJECTS_DIR:-}" ] || env+=(--env "LAB_PROJECTS_DIR=$LAB_PROJECTS_DIR")
  [ -z "${LAB_STATE_DIR:-}" ] || env+=(--env "LAB_STATE_DIR=$LAB_STATE_DIR")
  [ -z "${CMUX_SOCKET_PATH:-}" ] || env+=(--env "CMUX_SOCKET_PATH=$CMUX_SOCKET_PATH")
  [ -z "${CMUX_SOCKET:-}" ] || env+=(--env "CMUX_SOCKET=$CMUX_SOCKET")
  open "${env[@]}" -a "$app" --args --project "$p" --lab "$(ginkgo_lab)" --log "$(ginkgo_dir)/ginkgo.log" \
    --model "$(global_config_get ginkgo_model)" --lang "$(lab_lang_detect)" >/dev/null 2>&1 || die "macOS refused to open $app"
  kv PROJECT "$p"; kv APP "$app"; kv LAUNCHED yes; kv LOG "$(ginkgo_dir)/ginkgo.log"
  log_wrap "Ginkgo is listening for $p: speak freely; say stop (or use its menu bar icon) to close the microphone."
}

# ---------- lab uninstall : les gestes Ginkgo (lot 04) ----------
# ginkgo_uninstall_plan <keep yes|no> : un geste par ligne, « <geste>\t<phrase> », dans l'ordre où ils se font ; rien si Ginkgo n'a
# laissé aucune trace (app en marche, dossier, clé). --keep-state garde la clé et le dossier : une ligne kept le dit, sans geste.
# Le plan entre au consentement de lab uninstall : un plan changé entre la lecture et l'accord est refusé.
# alone : rien d'autre n'est à désinstaller ; avec --keep-state, seule une app en marche reste alors à faire (revue : sinon chaque
# relance redemanderait l'accord et oublierait le micro de nouveau).
ginkgo_uninstall_plan() {   # <keep yes|no> [alone]
  local keep="$1" running=no dir=no key=no
  ! pgrep -x Ginkgo >/dev/null 2>&1 || running=yes
  [ ! -d "$(ginkgo_dir)" ] || dir=yes
  ! ginkgo_key_present || key=yes
  [ "$running$dir$key" != nonono ] || return 0
  [ "$running$keep${2:-}" != noyesalone ] || return 0
  [ "$running" = no ] || printf 'stop\tStop Ginkgo, running now (its microphone and its connection close with it).\n'
  printf 'microphone\tForget the microphone permission of Ginkgo (tccutil reset Microphone %s).\n' "$GINKGO_BUNDLE"
  if [ "$keep" = yes ]; then
    [ "$dir$key" = nono ] || printf 'kept\tKept with --keep-state: the OpenAI key and %s.\n' "$(ginkgo_dir)"
    return 0
  fi
  [ "$key" = no ] || printf 'key\tRemove the OpenAI key of Ginkgo from the macOS keychain (%s).\n' "$GINKGO_SERVICE"
  [ "$dir" = no ] || printf 'state\tRemove the Ginkgo folder: %s\n' "$(ginkgo_dir)"
}
ginkgo_uninstall_show() { local g m; while IFS=$'\t' read -r g m; do [ -z "$g" ] || log_wrap "Ginkgo: $m"; done <"$1"; }
# ginkgo_uninstall_apply <plan> : après l'accord, chaque geste au mieux, son résultat dit ; un geste raté n'arrête pas la désinstallation
ginkgo_uninstall_apply() {
  local g m i d
  while IFS=$'\t' read -r g m; do
    case "$g" in
      stop)
        pkill -x Ginkgo >/dev/null 2>&1 || true
        i=0; while pgrep -x Ginkgo >/dev/null 2>&1 && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
        if pgrep -x Ginkgo >/dev/null 2>&1; then log_wrap 'Ginkgo did not stop: quit it from its menu bar icon.'; else log_wrap 'Ginkgo stopped.'; fi ;;
      microphone)   # sans entrée connue de macOS, tccutil répond non nul : rien à oublier
        if tccutil reset Microphone "$GINKGO_BUNDLE" >/dev/null 2>&1; then log_wrap 'Microphone permission of Ginkgo forgotten.'
        else log_wrap 'Microphone permission of Ginkgo: nothing to forget (tccutil found no entry).'; fi ;;
      key)
        security delete-generic-password -s "$GINKGO_SERVICE" -a "$GINKGO_ACCOUNT" >/dev/null 2>&1 || true
        if ginkgo_key_present; then log_wrap "The OpenAI key is still in the keychain ($GINKGO_SERVICE): remove it in Keychain Access."
        else log_wrap 'OpenAI key of Ginkgo removed from the keychain.'; fi ;;
      state)
        d="$(ginkgo_dir)"
        if [ -n "${LAB_STATE:-}" ] && [ -d "$d" ] && [ ! -L "$d" ] && rm -R "$d"; then log_wrap "Ginkgo folder removed: $d"
        else log_wrap "Ginkgo folder not removed: $d — remove it by hand."; fi ;;
    esac
  done <"$1"
}

cmd_ginkgo() {
  # Ginkgo.app passe ses arguments par Foundation (Process), décomposés (NFD : « e » + accent combinant) : composés ici (NFC), sinon
  # « Prêt » ne retrouve pas le libellé de la boîte et un complément s'écrirait décomposé dans l'onglet (essai réel du 2026-11-19)
  local a; local -a A=()
  for a in "$@"; do A+=("$(printf '%s' "$a" | perl -CSD -MUnicode::Normalize -pe '$_ = NFC($_)' 2>/dev/null || printf '%s' "$a")"); done
  [ "${#A[@]}" = 0 ] || set -- "${A[@]}"
  case "${1:-}" in
    status) shift; [ "$#" = 0 ] || usage; ginkgo_status ;;
    key) shift; ginkgo_key "$@" ;;
    state) shift; ginkgo_state "$@" ;;
    tell) shift; ginkgo_tell "$@" ;;
    question) shift; ginkgo_question "$@" ;;
    answer) shift; ginkgo_answer "$@" ;;
    order) shift; ginkgo_order "$@" ;;
    close) shift; ginkgo_close "$@" ;;
    reply) shift; ginkgo_reply "$@" ;;
    news) shift; ginkgo_news "$@" ;;
    -*) usage ;;
    *) ginkgo_launch "$@" ;;
  esac
}
