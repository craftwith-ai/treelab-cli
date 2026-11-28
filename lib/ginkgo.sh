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
# lot 06 : le canal de l'app Treelab — le contrat que parle l'app (clé GinkgoProtocol de son Info.plist, vide avant le canal) et son
# socket (<état de lab>/ginkgo/app.sock, 103 octets au plus : sun_path, jamais tronqué)
GINKGO_SOCKET_MAX=103
# Info.plist absent ou illisible : rien, jamais un échec (sed rc 2 sous pipefail arrêtait lab ginkgo status, revue du lot 06)
ginkgo_app_protocol() { { sed -n 's:.*<key>GinkgoProtocol</key><integer>\([0-9][0-9]*\)</integer>.*:\1:p' "$1/Contents/Info.plist" 2>/dev/null || true; } | head -1; }
ginkgo_socket() { printf '%s/app.sock\n' "$(ginkgo_dir)"; }
ginkgo_app_version() { sed -n 's:.*<key>CFBundleShortVersionString</key><string>\([^<]*\)</string>.*:\1:p' "$1/Contents/Info.plist" 2>/dev/null | head -1; }
# ginkgo_stop : SIGTERM, le départ propre de l'app (annonces rendues à lab, 5 s au plus, notification 2 s, bye au canal) attendu
# 8 s, puis SIGKILL ; rc 0 arrêtée, 1 encore là (revue du lot 06 : 3 s ne suffisaient pas, la relance se perdait)
GINKGO_STOP_TENTHS=80
ginkgo_stop() {
  local i=0
  pkill -x Ginkgo >/dev/null 2>&1 || true
  while pgrep -x Ginkgo >/dev/null 2>&1; do
    [ "$i" -ne "$GINKGO_STOP_TENTHS" ] || pkill -KILL -x Ginkgo >/dev/null 2>&1 || true   # au-delà de l'adieu : arrêt forcé
    [ "$i" -lt $((GINKGO_STOP_TENTHS + 20)) ] || return 1                                  # puis 2 s au plus
    sleep 0.1; i=$((i + 1))
  done
}
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

# ---------- les modes d'écoute (lot 05) ----------
# ginkgo_listen= de ~/.lab/config : command (par défaut : la conversation s'ouvre au lancement, parole libre), key (⌥ Espace tenue),
# name (« Ginkgo » entendu sur le Mac seul). Une valeur illisible : command, avertie sur stderr.
GINKGO_HOTKEY_DEFAULT=option+space
# ginkgo_listen_read : GINKGO_LISTEN = command, key ou name, vide pour une valeur illisible ; GINKGO_LISTEN_RAW, la valeur lue sans blanc
# ni majuscule. Sans processus (ginkgo_config_set), sauf une majuscule à baisser : le doctor tient son budget (tests/charge.bats)
ginkgo_listen_read() {
  ginkgo_config_set ginkgo_listen; GINKGO_LISTEN_RAW="$GINKGO_CONF"
  case "$GINKGO_LISTEN_RAW" in
    *[ABCDEFGHIJKLMNOPQRSTUVWXYZ]*) GINKGO_LISTEN_RAW="$(printf '%s' "$GINKGO_LISTEN_RAW" | tr '[:upper:]' '[:lower:]')" ;;
  esac
  case "$GINKGO_LISTEN_RAW" in ''|command) GINKGO_LISTEN='command' ;; key|name) GINKGO_LISTEN="$GINKGO_LISTEN_RAW" ;; *) GINKGO_LISTEN="" ;; esac
}
ginkgo_listen_mode() {
  ginkgo_listen_read
  [ -n "$GINKGO_LISTEN" ] || { log_wrap "ginkgo_listen=$GINKGO_LISTEN_RAW in ~/.lab/config is not command, key or name: command is used."; GINKGO_LISTEN='command'; }
  echo "$GINKGO_LISTEN"
}
# ginkgo_hotkey_value : ginkgo_hotkey= en forme canonique « ctrl+option+shift+cmd+<touche> » — la grammaire de Hotkey.parse de l'app :
# ⌃ ⌥ ⌘ ⇧ (ou ctrl, option, alt, cmd, shift) joints par + ou - ; l'espace ou une lettre demandent ⌃, ⌥ ou ⌘, une touche F1 à F20 peut
# être seule. Illisible : option+space, averti sur stderr.
ginkgo_hotkey_value() {
  local raw t key="" ctrl=0 opt=0 shift=0 cmd=0 fn=0 bad=0 out=""; local -a toks=()
  raw="$(global_config_get ginkgo_hotkey)"
  [ -n "$(printf '%s' "$raw" | tr -d '[:space:]')" ] || { echo "$GINKGO_HOTKEY_DEFAULT"; return 0; }
  # read -a ne développe aucun motif (une valeur « option+* » reste un mot)
  read -ra toks <<<"$(printf '%s' "$raw" | LC_ALL=C sed 's/⌃/ ctrl /g; s/⌥/ option /g; s/⌘/ cmd /g; s/⇧/ shift /g' | LC_ALL=C tr 'A-Z+-' 'a-z  ')"
  for t in "${toks[@]+"${toks[@]}"}"; do
    case "$t" in
      ctrl|control) ctrl=1 ;; opt|option|alt) opt=1 ;; cmd|command) cmd=1 ;; shift) shift=1 ;;
      *) if [ -n "$key" ]; then bad=1; break; fi
         case "$t" in
           space|[abcdefghijklmnopqrstuvwxyz]) key="$t" ;;
           f[123456789]|f1[0123456789]|f20) key="$t"; fn=1 ;;
           *) bad=1; break ;;
         esac ;;
    esac
  done
  if [ "$bad" = 1 ] || [ -z "$key" ] || { [ "$fn" = 0 ] && [ "$ctrl$opt$cmd" = 000 ]; }; then
    log_wrap "ginkgo_hotkey=$raw in ~/.lab/config is not ctrl, option or cmd with space or a letter, or a key F1 to F20: $GINKGO_HOTKEY_DEFAULT is used."
    echo "$GINKGO_HOTKEY_DEFAULT"; return 0
  fi
  [ "$ctrl" = 0 ] || out="${out}ctrl+"; [ "$opt" = 0 ] || out="${out}option+"; [ "$shift" = 0 ] || out="${out}shift+"; [ "$cmd" = 0 ] || out="${out}cmd+"
  echo "$out$key"
}
# ginkgo_hotkey_display <canonique> → « ⌥ Space », « ⌃⌥ G », « ⇧⌘ F5 », « F13 » (l'affichage de l'app, ordre d'Apple ⌃ ⌥ ⇧ ⌘)
ginkgo_hotkey_display() {
  local m="" k="${1##*+}"
  case "+$1+" in *+ctrl+*) m="${m}⌃" ;; esac; case "+$1+" in *+option+*) m="${m}⌥" ;; esac
  case "+$1+" in *+shift+*) m="${m}⇧" ;; esac; case "+$1+" in *+cmd+*) m="${m}⌘" ;; esac
  case "$k" in space) k=Space ;; *) k="$(printf '%s' "$k" | tr '[:lower:]' '[:upper:]')" ;; esac
  if [ -n "$m" ]; then printf '%s %s\n' "$m" "$k"; else printf '%s\n' "$k"; fi
}
# ginkgo_listen_phrase <mode> [touche canonique] : GINKGO_PHRASE, comment Ginkgo démarre, en quelques mots (doctor) ; sans processus
# hors du mode touche
ginkgo_listen_phrase() {
  # shellcheck disable=SC2034 # GINKGO_PHRASE est lu par doctor_ginkgo (lib/doctor.sh)
  case "$1" in
    key) GINKGO_PHRASE="starts while $(ginkgo_hotkey_display "$2") is held" ;;
    name) GINKGO_PHRASE='starts on its name, heard on this Mac only' ;;
    *) GINKGO_PHRASE='starts on command' ;;
  esac
}

# ginkgo_lock <dossier> : verrou mkdir, LAB_CONFIG_LOCK_TRIES essais de 0,1 s (50), chaque passage compté ; repris seulement d'un
# processus prouvé mort (pid_dead de lib/lock.sh : kill -0 seul échoue sur un vivant sous bac à sable), ou sans pid depuis plus de
# 5 s (tué entre mkdir et le pid). rc 1 : tenu par un autre ; rc 2 : le dossier ne peut pas être créé (état non inscriptible), sans
# boucle (revue du lot 05)
ginkgo_lock() {
  local d="$1" i=0 p
  until mkdir "$d" 2>/dev/null; do
    if [ ! -d "$d" ]; then mkdir "$d" 2>/dev/null && break; return 2; fi   # relâché entre-temps : une seconde chance, puis refus
    p="$(cat "$d/pid" 2>/dev/null)" || p=""
    if { [ -n "$p" ] && pid_dead "$p"; } || { [ -z "$p" ] && [ "$(perl -e 'print time - (stat shift)[9]' "$d" 2>/dev/null || echo 0)" -gt 5 ]; }; then
      rm -f "$d/pid"; rmdir "$d" 2>/dev/null || true
    fi
    i=$((i + 1)); [ "$i" -lt "${LAB_CONFIG_LOCK_TRIES:-50}" ] || return 1; sleep 0.1
  done
  printf '%s\n' "$$" >"$d/pid"
}
ginkgo_unlock() { rm -f "$1/pid"; rmdir "$1" 2>/dev/null || true; }
# ginkgo_config_write <clé> <valeur> : la première écriture de ~/.lab/config par lab (lot 05). Sous verrou ($LAB_STATE/config.lock),
# dans un fichier temporaire du même dossier, puis mv : les autres lignes restent telles quelles et à leur place, la clé est remplacée
# à la sienne (ses doublons retirés) ou ajoutée à la fin, les droits du fichier sont gardés. Le dépôt git de ~/.lab suit config mais
# lab n'y commite que des chemins nommés (docs_commit) : l'écriture reste une modification de la copie de travail.
ginkgo_config_write() {
  local k="$1" v="$2" f="$LAB_HOME/config" lock="$LAB_STATE/config.lock" tmp mode=644
  [ ! -L "$f" ] || die "$f is a symbolic link: write $k=$v in it by hand"
  mkdir -p "$LAB_HOME" "$LAB_STATE"
  local rc=0; ginkgo_lock "$lock" || rc=$?
  case "$rc" in
    0) ;;
    2) die "cannot take the lock $lock ($LAB_STATE is not writable): nothing changed" ;;
    *) die "another lab is writing $f: nothing changed, try again in a moment" ;;
  esac
  if ! tmp="$(mktemp "$LAB_HOME/.config.tmp.XXXXXXXX")"; then ginkgo_unlock "$lock"; die "cannot write in $LAB_HOME: nothing changed"; fi
  [ ! -f "$f" ] || mode="$(stat -f %Lp "$f" 2>/dev/null || echo 644)"
  if [ -f "$f" ]; then
    awk -v k="$k" -v v="$v" 'index($0, k "=") == 1 { if (!done) print k "=" v; done = 1; next } { print } END { if (!done) print k "=" v }' "$f" >"$tmp"
  else printf '%s=%s\n' "$k" "$v" >"$tmp"; fi
  if ! { chmod "$mode" "$tmp" && mv -f "$tmp" "$f"; }; then rm -f "$tmp"; ginkgo_unlock "$lock"; die "cannot write $f: nothing changed"; fi
  ginkgo_unlock "$lock"
}

# ---------- lab ginkgo listen [command|key|name] ----------
ginkgo_listen() {
  [ "$#" -le 1 ] || usage
  [ "$#" = 1 ] || { kv LISTEN "$(ginkgo_listen_mode)"; return 0; }
  case "$1" in command|key|name) ;; *) die "unknown listen mode: $1 (command, key or name)" ;; esac
  ginkgo_config_write ginkgo_listen "$1"
  kv LISTEN "$1"
  case "$1" in
    command) log_wrap "Ginkgo now starts on command: lab ginkgo <project> opens the conversation, then speak freely." ;;
    key) log_wrap "Ginkgo now listens only while you hold $(ginkgo_hotkey_display "$(ginkgo_hotkey_value)"); the microphone is off otherwise." ;;
    name) log_wrap "Ginkgo now waits for its name, heard on this Mac only: nothing leaves it before it hears \"Ginkgo\"." ;;
  esac
  log_wrap "A running Ginkgo keeps its mode until lab ginkgo <project> opens it again; its menu bar icon changes it at once."
}

# ---------- lab ginkgo status ----------
ginkgo_status() {
  local app; app="$(ginkgo_app)"
  kv PROVIDER "$(ginkgo_provider)"
  if ginkgo_key_present; then kv KEY present; else kv KEY absent; fi
  if [ -d "$app" ]; then kv APP "$app"; else kv APP absent; fi
  kv SOURCE "$(ginkgo_source)"
  kv LISTEN "$(ginkgo_listen_mode)"
  kv HOTKEY "$(ginkgo_hotkey_value)"
  # contrat v1.1 (lot 06) : l'app Treelab lit PROTOCOL= avant tout lancement — sans la ligne, « mise à jour de Ginkgo nécessaire »
  local proto=""; [ ! -d "$app" ] || proto="$(ginkgo_app_protocol "$app")"
  [ -z "$proto" ] || kv PROTOCOL "$proto"
  kv SOCKET "$(ginkgo_socket)"
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
  [ "${1:-}" != --all ] || { ginkgo_state_all; return 0; }
  local p wt; p="$(resolve_project "${1:-}")"; load_project "$p"
  wt="$(worktree_path "$TOWER_LANE")"
  kv PROJECT "$p"
  if [ -d "$wt" ] && lane_is_tower "$wt"; then kv TOWER present; sep; tower_view; return 0; fi
  kv TOWER absent
  log_wrap "No tower in $p: nothing read, nothing created (lab tower $p creates it)."
}

# ---------- lab ginkgo state --all : le poste (lot 07) ----------
# Ginkgo est au-dessus de toutes les conversations : ce qui attend l'utilisateur dans chaque projet du registre. La vue complète de la
# tour (contexte de chaque session, file de prod) coûtait 22 s pour 15 projets sur le Mac d'Alex (14 s pour 51 couloirs) : ici, ce
# qu'un couloir attend seulement (tower_waits_for), les couloirs qui attendent l'utilisateur seuls écrits, un projet par processus.
# ginkgo_state_project <projet> : un bloc PROJECT=, TOWER=present|absent, puis LANE=/WAITS_FOR=/WHY=/EVIDENCE= des couloirs à lui,
# LANES=, WAITING_FOR_YOU= ; rc ≠ 0 si le projet est illisible (config, checkout disparu)
ginkgo_state_project() {
  local wt lane yours="" n=0 aside=""
  load_project "$1"
  kv PROJECT "$1"
  wt="$P_ROOT/.worktrees/$TOWER_LANE"   # worktree_path, sans sous-shell (lot 08)
  if [ ! -d "$wt" ] || ! lane_is_tower "$wt"; then kv TOWER absent; return 0; fi
  kv TOWER present
  for wt in "$P_ROOT"/.worktrees/*/; do
    [ -d "$wt" ] || continue; wt="${wt%/}"
    ! lane_is_tower "$wt" || continue
    n=$((n + 1)); ginkgo_lane_set "$wt" state
    [ "$GK_YOURS" = 1 ] || continue
    wt_lane_set "$wt"; lane="$WT_LANE"; yours="${yours:+$yours }$lane"
    kv LANE "$lane"; kv WAITS_FOR "$TW_WAITS"; kv WHY "$TW_WHY"; [ -z "$TW_EVIDENCE" ] || kv EVIDENCE "$TW_EVIDENCE"
    # lot 09 : les couloirs que les précisions de la personne mettent de côté, tus dans un résumé (une boîte capturée : question)
    if [ "${GP_N:-0}" -gt 0 ]; then
      ginkgo_kind_set "$wt"
      case "$GK_KIND" in question|permission) [ ! -s "$wt/.lab/waits-question.json" ] || GK_KIND=question ;; esac
      ginkgo_prec_match "$1" "$lane" "$GK_KIND"; [ "$GK_ASIDE" = 0 ] || aside="${aside:+$aside }$lane"
    fi
  done
  kv LANES "$n"; kv WAITING_FOR_YOU "$yours"; [ "${GP_N:-0}" = 0 ] || kv SET_ASIDE "$aside"
}
# ginkgo_state_all : chaque projet dans son processus (sortie dans un fichier), attendu par son pid, puis les blocs dans l'ordre du
# registre ; un projet illisible donne TOWER=unreadable sans cacher les autres ; rien n'est créé (aucune tour, aucun onglet)
ginkgo_state_all() {
  local d p i=0 n=0; local -a pids=()
  ginkgo_feed_set; ginkgo_prec_load   # lot 09 : lues une fois, héritées par chaque projet
  d="$(mktemp -d "${TMPDIR:-/tmp}/lab-ginkgo-all.XXXXXXXX")" || die "cannot create a temporary folder: nothing read"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    # die sort du sous-shell qui l'appelle : la lecture a le sien, le repli « illisible » reste dans celui du projet
    ( ( ginkgo_state_project "$p" ) >"$d/$n" 2>/dev/null || printf 'PROJECT=%s\nTOWER=unreadable\n' "$p" >"$d/$n" ) &
    pids+=("$!"); n=$((n + 1))
  done <<<"$(project_names)"
  for p in "${pids[@]+"${pids[@]}"}"; do wait "$p" || true; done
  while [ "$i" -lt "$n" ]; do cat "$d/$i"; sep; i=$((i + 1)); done
  rm -f "$d"/*; rmdir "$d" 2>/dev/null || true
  kv PROJECTS "$n"; ginkgo_feed_kv; ginkgo_prec_kv
}

# ---------- le fil de l'app Treelab (lot 08) ----------
# L'instantané des couloirs ($LAB_STATE/app-snapshot, lib/snapshot.sh et lib/app.sh, couloir app-treelab) est le résumé que lab tient
# à jour à chaque point d'écriture tant que l'app Treelab en est le lecteur vivant : WAITS_FOR=, WHY=, FOR_YOU= de chaque couloir.
# Lire un bloc coûte un fichier ; le calculer, la phase du couloir (25 s de processeur pour 17 projets sur le Mac d'Alex, 2026-11-27).
# Ginkgo le lit seulement : jamais de marque de lecteur, ni de .dead.<pid>, ni d'écrivain lancé.
# ginkgo_feed_set : GK_FEED, le dossier du fil s'il a un lecteur vivant et la version de ce lab (un autre lab écrit d'autres blocs),
# sinon vide
ginkgo_feed_set() {
  local pid='' v='' mine=''
  GK_FEED=''
  declare -F snap_dir_set >/dev/null || . "$LAB_ROOT/lib/snapshot.sh"
  snap_dir_set
  { IFS= read -r pid <"$SNAP_DIR/reader"; } 2>/dev/null || return 0
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  [ ! -e "$SNAP_DIR/.dead.$pid" ] && snap_pid_alive "$pid" || return 0
  { IFS= read -r v <"$SNAP_DIR/version"; } 2>/dev/null || true
  { IFS= read -r mine <"$LAB_ROOT/VERSION"; } 2>/dev/null || true
  [ -n "$v" ] && [ "$v" = "${mine:-unknown}" ] || return 0
  # revue du lot 08 : le lecteur inscrit après la dernière réécriture complète (app relancée) lirait le fil figé à l'arrêt de la
  # précédente ; même seconde acceptée, reader est écrit avant app_snap_full (lib/app.sh)
  [ -e "$SNAP_DIR/.full.work" ] && [ ! "$SNAP_DIR/reader" -nt "$SNAP_DIR/.full.work" ] || return 0
  GK_FEED="$SNAP_DIR"
}
ginkgo_feed_kv() { if [ -n "${GK_FEED:-}" ]; then kv SOURCE feed; else kv SOURCE computed; fi; }   # SOURCE=feed|computed
# ginkgo_lane_set <wt> <news|state> : TW_WAITS, TW_WHY, TW_EVIDENCE, TW_PHASE et GK_YOURS (1 : l'affaire de la personne) du couloir
# du projet chargé — son bloc dans le fil s'il y est, sinon calculés. Le fil ne dit ni preuve ni phase : une recette se lit dans
# WAITS_FOR=acceptance, une recette passée qui attend la personne dans « closing: » (la vue de la tour les écrit ainsi), et FOR_YOU
# vaut tower_yours. Calculé, news garde son filtre du lot 03 (une recette sur check: seul est l'affaire de la tour), state tower_yours.
ginkgo_lane_set() {
  local f='' line yours='' settled=0
  [ -z "${GK_FEED:-}" ] || f="$GK_FEED/projects/$P_NAME/lanes/${1##*/}"
  if [ -n "$f" ] && [ -f "$f" ]; then
    TW_WAITS=nothing; TW_WHY=''; TW_EVIDENCE=''; TW_PHASE=''
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in WAITS_FOR=*) TW_WAITS="${line#WAITS_FOR=}" ;; WHY=*) TW_WHY="${line#WHY=}" ;; FOR_YOU=*) yours="${line#FOR_YOU=}" ;; esac
    done <"$f"
    # revue du lot 08 : une attente déclarée (waits_label, lib/tower.sh) que le couloir a réglée depuis, le bloc pas encore réécrit
    # par l'écrivain : le couloir calculé, jamais une fausse annonce de blocage
    case "$TW_WHY" in
      'question waiting: '*|'permission requested: '*|'lane blocked: '*)
        kv_value "$1/.lab/waits-for" kind || true; [ -n "$KV_VALUE" ] || settled=1 ;;
    esac
    if [ "$settled" = 0 ]; then
      case "$TW_WAITS:$TW_WHY" in acceptance:*) TW_PHASE='in acceptance' ;; you:closing:*) TW_PHASE='acceptance passed' ;; esac
      GK_YOURS=0; [ "$yours" != yes ] || GK_YOURS=1
      return 0
    fi
  fi
  tower_waits_for "$1" --no-session
  GK_YOURS=0
  if [ "$2" = news ]; then
    case "$TW_WAITS:$TW_EVIDENCE" in acceptance:check) ;; you:*|acceptance:*) GK_YOURS=1 ;; esac
  elif tower_yours; then GK_YOURS=1; fi
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
  local p="$1" lane="$2" qid="" text="" has_text=0 cur=0 qmax=0 qf n i screen; shift 2
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
  { screen="$(cmx read-screen --workspace "$GK_WS" --surface "$GK_SURFACE" 2>/dev/null)" && grep -q 'Type something' <<<"$screen"; } \
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
  local folded
  folded="$(words_fold)" && LC_ALL=C grep -Eq '(^|[^a-z])(ferm[a-z]*|clos[a-z]*|clore|clotur[a-z]*|abandon[a-z]*|retir[a-z]*|supprim[a-z]*|enlev[a-z]*|delete[a-z]*|remov[a-z]*|discard[a-z]*)([^a-z]|$)' <<<"$folded"
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
  local p="$1" text folded; shift; text="$*"
  ginkgo_tower "$p"
  ginkgo_human order
  text="$(printf '%s' "$text" | words_clean "$GINKGO_TELL_MAX")"
  [ -n "${text// /}" ] || die "empty order — nothing sent"
  ! ginkgo_is_close "$text" || die "closing a lane is never a free order: lab ginkgo close $p <lane> reads it back first — nothing sent"
  # la formule de la fermeture confirmée n'appartient qu'à lab ginkgo close (revue de sécurité du lot)
  ! { folded="$(printf '%s' "$text" | words_fold)" && LC_ALL=C grep -Eq 'confirm[a-z]*[^a-z]*(aloud|out[^a-z]*loud)|voix haute' <<<"$folded"; } \
    || die "\"confirmed aloud\" is written by only lab ginkgo close, after a read-back — nothing sent"
  ginkgo_tower_send "$p" "$text"
  kv ORDERED yes
  log_wrap "Order typed in the tower of $p; lab ginkgo reply $p --since <SINCE> reads its answer."
}

# ginkgo_close_tower_box <projet> <couloir> : la tour demande elle-même « je ferme <couloir> ? » (essai réel du 2026-11-19) — la
# fermeture relue et confirmée à voix haute répond à sa place : Échap ferme la boîte (sans PostToolUse : l'entrée est retirée ici),
# puis l'ordre confirmé est tapé ; toute autre boîte de la tour reste un refus de ginkgo_tower_send
ginkgo_close_tower_box() {
  local qf texts screen; qf="$(waits_question_file "$GK_WT")"
  ginkgo_box "$GK_WT" >/dev/null || return 0
  jq -r '.questions[] | .question, .header, .options[].label' "$qf" | ginkgo_closing || return 0
  texts="$(jq -r '.questions[] | .question, .header' "$qf")" && grep -qF -- "$2" <<<"$texts" || return 0
  GK_LANE="$TOWER_LANE"; ginkgo_tab "$GK_WT" "$TOWER_LANE"
  ginkgo_send_key escape
  ! { screen="$(cmx read-screen --workspace "$GK_WS" --surface "$GK_SURFACE" 2>/dev/null)" && grep -q 'Type something' <<<"$screen"; } \
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
# Ginkgo.app relit toutes les 30 s et ne fait que dire ou notifier. Lecture seule, sauf son fichier $LAB_STATE/<projet>/ginkgo/news
# (told=<clé> dit ou vu, held=<clé> retenu) ; clé = couloir|sorte|empreinte du QID de la boîte, sinon de at=, sinon du motif : une attente qui change
# (nouvelle question, nouvelle date) est annoncée de nouveau, une clé disparue est oubliée. --forget <clé> : une annonce vocale que
# l'app n'a pas pu dire (conversation fermée avant) redevient nouvelle, et la même relecture décide de nouveau (revue du lot).
GINKGO_QUIET_DEFAULT=21:00-08:00
GINKGO_NEWS_TEXT_MAX=200   # octets de NEW_n_TEXT, comme WHY= de lab ginkgo question
# Réglages et heure lus sans sous-shell, une valeur par variable (lot 04 de charge-processeur : lab ginkgo news, toutes les 30 s) ;
# les formes qui impriment restent pour la lecture humaine et les tests
# ginkgo_config_set <clé> : GINKGO_CONF, sa valeur dans ~/.lab/config sans aucun blanc (comme global_config_get | tr -d '[:space:]')
ginkgo_config_set() { GINKGO_CONF=""; ! kv_value "$LAB_HOME/config" "$1" || GINKGO_CONF="${KV_VALUE//[[:space:]]/}"; }
ginkgo_speak_mode() { ginkgo_speak_mode_set; printf '%s\n' "$GINKGO_SPEAK"; }
ginkgo_speak_mode_set() { # GINKGO_SPEAK
  ginkgo_config_set ginkgo_speak
  case "$GINKGO_CONF" in
    ''|always) GINKGO_SPEAK=always ;; conversation|never) GINKGO_SPEAK="$GINKGO_CONF" ;;
    *) log_wrap "ginkgo_speak=$GINKGO_CONF in ~/.lab/config is not always, conversation or never: always is used."; GINKGO_SPEAK=always ;;
  esac
}
ginkgo_minute() { ginkgo_minute_set "$1" && printf '%s\n' "$GINKGO_MINUTE"; }
ginkgo_minute_set() { # <HH:MM> : GINKGO_MINUTE, les minutes du jour ; rc 1 pour une heure illisible
  case "$1" in [0-9]:[0-5][0-9]|[01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) GINKGO_MINUTE=$(( 10#${1%%:*} * 60 + 10#${1#*:} )) ;; *) return 1 ;; esac
}
# ginkgo_quiet_range → « <début> <fin> » en minutes du jour, ou off ; une valeur illisible : la plage par défaut, avertie sur stderr
ginkgo_quiet_range() { ginkgo_quiet_range_set; printf '%s\n' "$GINKGO_RANGE"; }
ginkgo_quiet_range_set() { # GINKGO_RANGE
  local v s e
  ginkgo_config_set ginkgo_quiet; v="${GINKGO_CONF:-$GINKGO_QUIET_DEFAULT}"
  if [ "$v" = off ]; then GINKGO_RANGE=off; return 0; fi
  if [ "${v#*-}" != "$v" ] && ginkgo_minute_set "${v%%-*}" && s="$GINKGO_MINUTE" && ginkgo_minute_set "${v#*-}" && e="$GINKGO_MINUTE" \
    && [ "$s" != "$e" ]; then GINKGO_RANGE="$s $e"; return 0; fi
  log_wrap "ginkgo_quiet=$v in ~/.lab/config is not HH:MM-HH:MM or off: $GINKGO_QUIET_DEFAULT is used."
  ginkgo_minute_set "${GINKGO_QUIET_DEFAULT%-*}"; s="$GINKGO_MINUTE"; ginkgo_minute_set "${GINKGO_QUIET_DEFAULT#*-}"; GINKGO_RANGE="$s $GINKGO_MINUTE"
}
# ginkgo_quiet_now <début fin|off> → yes|no à l'heure locale du Mac (TZ) ; début compris, fin exclue ; une plage passe minuit ou non
ginkgo_quiet_now() { ginkgo_quiet_now_set "$1"; printf '%s\n' "$GINKGO_QUIET"; }
ginkgo_quiet_now_set() { # <début fin|off> : GINKGO_QUIET, un seul date (l'heure de LAB_NOW_EPOCH, sinon celle du moment)
  GINKGO_QUIET=no; [ "$1" != off ] || return 0
  local s="${1% *}" e="${1#* }" t m
  if [ -n "${LAB_NOW_EPOCH:-}" ]; then t="$(exec date -r "$LAB_NOW_EPOCH" +%H:%M)"; else t="$(exec date +%H:%M)"; fi
  m=$(( 10#${t%%:*} * 60 + 10#${t#*:} ))
  if [ "$s" -lt "$e" ]; then
    if [ "$m" -ge "$s" ] && [ "$m" -lt "$e" ]; then GINKGO_QUIET=yes; fi
  elif [ "$m" -ge "$s" ] || [ "$m" -lt "$e" ]; then GINKGO_QUIET=yes; fi
}
# ginkgo_waits : une ligne par attente de la personne, « <clé>\t<couloir>\t<sorte>\t<texte> », dans l'ordre des couloirs — ce que la
# vue de la tour range dans WAITING_FOR_YOU (une recette sur check: seul est l'affaire de la tour), plus question|permission de la tour
# Lot 04 de charge-processeur : couloir, attente et motif lus sans sous-shell, verrou de session non lu — mêmes lignes.
# Lot 08 : un seul programme par lecture, quel que soit le nombre de couloirs — ginkgo_waits_raw écrit les champs de chaque attente
# (séparés par NUL), ginkgo_waits_finish (un perl) en tire empreintes, QID et question des boîtes, mêmes clés que printf | shasum -a 256
# | cut -c1-16 ; le texte reste brut sur une ligne, nettoyé par words_clean à l'annonce seule (NEW_n_TEXT). Mesuré sur le Mac d'Alex le
# 2026-11-27 : une dizaine de programmes par couloir, 8 s de processeur par lecture pour 103 attentes, relue toutes les 30 s.
ginkgo_waits() { ginkgo_waits_raw | ginkgo_waits_finish; }
# ginkgo_kind_set <wt> : GK_KIND, la sorte d'attente d'un couloir à toi, après ginkgo_lane_set — celle que déclare .lab/waits-for
# (question, permission, blocked : GK_DECLARED=1), sinon celle de sa phase (recette, fermeture, blocage) ; la même pour news et pour
# les précisions de state --all (lot 09)
ginkgo_kind_set() {
  kv_value "$1/.lab/waits-for" kind || true; GK_KIND="$KV_VALUE"; GK_DECLARED=1
  case "$GK_KIND" in question|permission|blocked) return 0 ;; esac
  GK_DECLARED=0
  case "$TW_PHASE" in 'in acceptance') GK_KIND=acceptance ;; 'acceptance passed') GK_KIND=closing ;; *) GK_KIND=blocked ;; esac
}
# ginkgo_waits_raw : par attente, six champs terminés par NUL — <préfixe><couloir>, couloir, sorte, jeton, texte, boîte (fichier de la
# question capturée, vide sans elle)
ginkgo_waits_raw() {
  local wt lane kind tok text q
  for wt in "$P_ROOT"/.worktrees/*/; do
    [ -d "$wt" ] || continue; wt="${wt%/}"; wt_lane_set "$wt"; lane="$WT_LANE"
    case "$lane" in ''|.*|*[!A-Za-z0-9._-]*) continue ;; esac
    # l'adieu (--only-forgotten) : les seuls couloirs des attentes rendues, tour comprise
    if [ -n "${GK_ONLY:-}" ] && ! ginkgo_has "$GK_ONLY" "${GK_KEY_PREFIX:-}$lane"; then continue; fi
    kv_value "$wt/.lab/waits-for" kind || true; kind="$KV_VALUE"
    if lane_is_tower "$wt"; then
      case "$kind" in question|permission) ;; *) continue ;; esac
      kv_value "$wt/.lab/waits-for" at || true; tok="at=$KV_VALUE"; kv_value "$wt/.lab/waits-for" why || true; text="$KV_VALUE"
    else
      ginkgo_lane_set "$wt" news   # lot 08 : le bloc du fil s'il est vivant, sinon calculé
      [ "$GK_YOURS" = 1 ] || continue
      ginkgo_kind_set "$wt"; kind="$GK_KIND"
      if [ "$GK_DECLARED" = 1 ]; then
        kv_value "$wt/.lab/waits-for" at || true; tok="at=$KV_VALUE"; kv_value "$wt/.lab/waits-for" why || true; text="$KV_VALUE"
      else tok="why=$TW_WHY"; text=""; fi   # la phase seule : son motif, sans date, fait l'empreinte ; le texte de la sorte est dit par Ginkgo
    fi
    # une boîte capturée (lot 02) a pour clé son QID : la Notification d'autorisation que Claude Code envoie pendant la boîte
    # réécrit l'attente (permission, nouvelle date) sans en faire une nouvelle (essai réel du 2026-11-20 : annoncée deux fois)
    q=''; case "$kind" in question|permission) q="$wt/.lab/waits-question.json"; [ -s "$q" ] || q='' ;; esac
    printf '%s\0%s\0%s\0%s\0%s\0%s\0' "${GK_KEY_PREFIX:-}$lane" "$lane" "$kind" "$tok" "$text" "$q"
  done
}
# ginkgo_waits_finish : les champs de ginkgo_waits_raw → « <préfixe><couloir>|<sorte>|<empreinte>\t<couloir>\t<sorte>\t<texte> ».
# Une boîte dont .questions est une liste non vide (celle que lab écrit, tower.sh) : sorte question, jeton qid=<16 premiers hex du
# sha256 du fichier> (ginkgo_qid), texte sa première question, fins de ligne finales retirées comme $(jq -r …) ; sinon la sorte, le
# jeton et le texte de l'attente. Empreinte : 16 premiers hex du sha256 du jeton, en octets. Retours à la ligne, retours chariot et
# tabulations du texte rendus en espaces, le premier pas de words_clean.
# shellcheck disable=SC2016 # du perl : ses $ ne sont pas du shell
GINKGO_WAITS_PL='use strict; no warnings; use Digest::SHA qw(sha256_hex); use JSON::PP ();
my $js = JSON::PP->new->utf8; $/ = "\0";
while (1) {
  my @f; for (1 .. 6) { my $x = <STDIN>; last unless defined $x; chomp $x; push @f, $x; }
  last unless @f == 6;
  my ($head, $lane, $kind, $tok, $text, $box) = @f;
  if ($box ne "" && open(my $fh, "<:raw", $box)) {
    my $raw = do { local $/; <$fh> }; close $fh;
    my $d = eval { $js->decode($raw) };
    if (ref $d eq "HASH" && ref $d->{questions} eq "ARRAY" && @{$d->{questions}}) {
      my $q = $d->{questions}[0]; $q = ref $q eq "HASH" ? $q->{question} : undef;
      $kind = "question"; $tok = "qid=" . substr(sha256_hex($raw), 0, 16);
      $text = (defined $q && !ref $q) ? $q : ""; utf8::encode($text); $text =~ s/\n+\z//;
    }
  }
  $text =~ tr/\n\r\t/   /;
  print "$head|$kind|", substr(sha256_hex($tok), 0, 16), "\t$lane\t$kind\t$text\n";
}'
ginkgo_waits_finish() { perl -e "$GINKGO_WAITS_PL" 2>/dev/null || true; }
# ginkgo_waits_all : les attentes de tout le poste (lot 08), la clé préfixée de son projet (<projet>|<couloir>|<sorte>|<empreinte>),
# chaque projet dans son processus comme state --all ; un projet illisible n'en donne aucune et ne cache pas les autres ; un seul
# ginkgo_waits_finish pour tout le poste, sur les champs des projets dans l'ordre du registre
ginkgo_waits_all() {
  local d p n=0; local -a pids=() files=()
  d="$(mktemp -d "${TMPDIR:-/tmp}/lab-ginkgo-news.XXXXXXXX")" || die "cannot create a temporary folder: nothing read"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -n "${GK_ONLY:-}" ]; then case $'\n'"$GK_ONLY" in *$'\n'"$p|"*) ;; *) continue ;; esac; fi   # --only-forgotten
    ( ( load_project "$p"; GK_KEY_PREFIX="$p|"; ginkgo_waits_raw ) >"$d/$n" 2>/dev/null || : >"$d/$n" ) &
    pids+=("$!"); files+=("$d/$n"); n=$((n + 1))
  done <<<"$(project_names)"
  for p in "${pids[@]+"${pids[@]}"}"; do wait "$p" || true; done
  [ "$n" = 0 ] || cat "${files[@]}" | ginkgo_waits_finish
  rm -f "$d"/*; rmdir "$d" 2>/dev/null || true
}
ginkgo_has() { case $'\n'"$1"$'\n' in *$'\n'"$2"$'\n'*) return 0 ;; esac; return 1; }   # <liste, une par ligne> <élément>
ginkgo_drop() { local k; while IFS= read -r k; do if [ -n "$k" ] && ! ginkgo_has "$2" "$k"; then printf '%s\n' "$k"; fi; done <<<"$1"; }
ginkgo_news() {
  [ "$#" -ge 2 ] || usage
  local p="$1" open="" base=0 forget="" only=0; shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --open) [ "$#" -ge 2 ] || usage; case "$2" in yes|no) open="$2" ;; *) usage ;; esac; shift 2 ;;
      --baseline) base=1; shift ;;
      --forget) [ "$#" -ge 2 ] || usage; case "$2" in ''|*[!A-Za-z0-9._\|-]*) usage ;; esac; forget="$forget$2"$'\n'; shift 2 ;;
      --only-forgotten) only=1; shift ;;
      *) usage ;;
    esac
  done
  if [ "$base" = 1 ]; then [ -z "$open" ] && [ -z "$forget" ] || usage; else [ -n "$open" ] || usage; fi
  # revue du lot 08 : l'adieu de Ginkgo (--only-forgotten) ne relit que les couloirs des annonces non dites, GK_ONLY leurs paires
  # <projet>|<couloir> ; avec --all, --open et au moins un --forget seulement
  GK_ONLY=''
  if [ "$only" = 1 ]; then
    [ "$p" = --all ] && [ -n "$open" ] && [ -n "$forget" ] || usage
    local fk
    while IFS= read -r fk; do
      if [ -n "$fk" ] && ! ginkgo_has "$GK_ONLY" "${fk%|*|*}"; then GK_ONLY="$GK_ONLY${fk%|*|*}"$'\n'; fi
    done <<<"$forget"
  fi
  # lot 08 : --all, tout le poste — mémoire du poste ($LAB_STATE/ginkgo/news), clés préfixées du projet, NEW_n_PROJECT=, SOURCE= ;
  # news <projet> garde sa mémoire et sa sortie du lot 03
  local all_mode=0 where="in $p"
  if [ "$p" = --all ]; then all_mode=1; where="on this computer"
  else project_exists "$p" || die "unknown project: $p"; load_project "$p"; fi
  # la mémoire de ce qui a été dit à la personne : un agent qui la viderait ferait taire une attente (revue de sécurité du lot)
  ginkgo_human news
  local speak range quiet f cur told="" held="" line key all="" fresh="" kept="" say="" recap="" channel=none keep_held=""
  ginkgo_speak_mode_set; speak="$GINKGO_SPEAK"; ginkgo_quiet_range_set; range="$GINKGO_RANGE"; ginkgo_quiet_now_set "$range"; quiet="$GINKGO_QUIET"
  ginkgo_feed_set
  if [ "$all_mode" = 1 ]; then f="$(ginkgo_dir)/news"; else f="$LAB_STATE/$p/ginkgo/news"; fi
  # sa mémoire en une lecture du shell, les valeurs comme sed -n 's/^told=//p' les rendait (fins de ligne finales retirées)
  if [ -f "$f" ] && [ -r "$f" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in told=*) told="$told${line#told=}"$'\n' ;; held=*) held="$held${line#held=}"$'\n' ;; esac
    done <"$f"
    while [ "${told%$'\n'}" != "$told" ]; do told="${told%$'\n'}"; done
    while [ "${held%$'\n'}" != "$held" ]; do held="${held%$'\n'}"; done
  fi
  [ -z "$forget" ] || { told="$(ginkgo_drop "$told" "$forget")"; held="$(ginkgo_drop "$held" "$forget")"; }
  if [ "$all_mode" = 1 ]; then cur="$(ginkgo_waits_all)"; else cur="$(ginkgo_waits)"; fi
  # lot 09 : les précisions de la personne — une attente mise de côté n'est ni dite ni retenue, ni notée vue (annoncée une fois la
  # précision levée ou échue ; déjà dite, elle le reste) ; même la nuit : dite pendant les heures calmes (_n), le reste retenu (_d)
  local aside=0 rest wl wk wp kept_n="" kept_d="" fresh_n="" fresh_d=""
  ginkgo_prec_load
  # chaque attente présente : déjà dite ou vue, retenue cette nuit, ou nouvelle ; les clés absentes sont oubliées
  while IFS= read -r line; do
    [ -n "$line" ] || continue; key="${line%%$'\t'*}"
    GK_ASIDE=0; GK_NIGHT=0
    if [ "$GP_N" -gt 0 ]; then
      rest="${line#*$'\t'}"; wl="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"; wk="${rest%%$'\t'*}"
      wp="$p"; [ "$all_mode" = 0 ] || wp="${key%%|*}"
      ginkgo_prec_match "$wp" "$wl" "$wk"
    fi
    if [ "$GK_ASIDE" = 1 ]; then
      if ginkgo_has "$told" "$key"; then all="$all$key"$'\n'; else aside=$((aside + 1)); fi
      continue
    fi
    all="$all$key"$'\n'
    if ginkgo_has "$told" "$key"; then continue; fi
    if ginkgo_has "$held" "$key"; then
      kept="$kept$line"$'\n'; if [ "$GK_NIGHT" = 1 ]; then kept_n="$kept_n$line"$'\n'; else kept_d="$kept_d$line"$'\n'; fi
    elif [ "$base" = 0 ]; then
      fresh="$fresh$line"$'\n'; if [ "$GK_NIGHT" = 1 ]; then fresh_n="$fresh_n$line"$'\n'; else fresh_d="$fresh_d$line"$'\n'; fi
    fi
  done <<<"$cur"
  if [ "$base" = 1 ]; then keep_held="$kept"   # une relance de nuit garde ce qui attend le récapitulatif (revue du lot)
  elif [ "$speak" = never ]; then :
  elif [ "$open" = yes ]; then say="$kept$fresh"; [ -z "$say" ] || channel=voice   # heures calmes comprises : la personne a ouvert
  elif [ "$speak" = conversation ]; then :   # vue conversation fermée : jamais annoncée plus tard
  elif [ "$quiet" = yes ] && [ -n "$kept_n$fresh_n" ]; then say="$kept_n$fresh_n"; keep_held="$kept_d$fresh_d"; channel=notify   # même la nuit
  elif [ "$quiet" = yes ]; then say="$fresh"; keep_held="$kept$fresh"; [ -z "$fresh" ] || channel=hold
  elif [ -n "$kept" ]; then recap="$kept$fresh"; channel=notify   # premier passage après la plage : un seul récapitulatif
  else say="$fresh"; [ -z "$fresh" ] || channel=notify; fi
  # mémoire : tout ce qui est présent est dit ou vu, sauf ce qui reste retenu ; les clés retenues (1re colonne) relevées une fois
  local out="" k held_keys=""
  while IFS= read -r line; do [ -z "$line" ] || held_keys="$held_keys${line%%$'\t'*}"$'\n'; done <<<"$keep_held"
  held_keys="${held_keys%$'\n'}"
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    if ginkgo_has "$held_keys" "$k"; then out="${out}held=$k"$'\n'; else out="${out}told=$k"$'\n'; fi
  done <<<"$all"
  # --only-forgotten : les couloirs non relus gardent leur mémoire telle quelle
  if [ -n "$GK_ONLY" ]; then
    while IFS= read -r k; do
      if [ -n "$k" ] && ! ginkgo_has "$GK_ONLY" "${k%|*|*}"; then out="${out}told=$k"$'\n'; fi
    done <<<"$told"
    while IFS= read -r k; do
      if [ -n "$k" ] && ! ginkgo_has "$GK_ONLY" "${k%|*|*}"; then out="${out}held=$k"$'\n'; fi
    done <<<"$held"
  fi
  [ -d "${f%/*}" ] || mkdir -p "${f%/*}"
  ( umask 077; printf '%s' "$out" >"$f.tmp.$$" && mv "$f.tmp.$$" "$f" ) || die "cannot write $f: nothing announced"
  kv SPEAK "$speak"; kv QUIET "$quiet"; kv CHANNEL "$channel"
  [ "$all_mode" = 0 ] || ginkgo_feed_kv
  [ "$GP_N" = 0 ] || kv ASIDE "$aside"   # lot 09 : les attentes que les précisions taisent (jamais dites avant)
  local n=0 r=0 i lane kind text
  # les lignes non vides, comme grep -c . (chaque ligne porte au moins sa clé)
  while IFS= read -r line; do [ -z "$line" ] || n=$((n + 1)); done <<<"$say"
  while IFS= read -r line; do [ -z "$line" ] || r=$((r + 1)); done <<<"$recap"
  kv NEW "$n"; i=0
  while IFS=$'\t' read -r key lane kind text; do
    [ -n "$key" ] || continue; i=$((i + 1))
    [ "$all_mode" = 0 ] || kv "NEW_${i}_PROJECT" "${key%%|*}"
    # le texte brut de ginkgo_waits, nettoyé ici seulement : une annonce, pas chaque couloir à chaque lecture (lot 08)
    kv "NEW_${i}_LANE" "$lane"; kv "NEW_${i}_KIND" "$kind"
    kv "NEW_${i}_TEXT" "$(printf '%s' "$text" | words_clean "$GINKGO_NEWS_TEXT_MAX")"; kv "NEW_${i}_KEY" "$key"
  done <<<"$say"
  kv RECAP "$r"; i=0
  while IFS=$'\t' read -r key lane kind text; do
    [ -n "$key" ] || continue; i=$((i + 1)); [ "$all_mode" = 0 ] || kv "RECAP_${i}_PROJECT" "${key%%|*}"; kv "RECAP_${i}_LANE" "$lane"; kv "RECAP_${i}_KEY" "$key"
  done <<<"$recap"
  case "$channel" in
    voice) log_wrap "$n new for you $where: Ginkgo says it out loud." ;;
    notify) if [ "$r" -gt 0 ]; then log_wrap "Quiet hours over: $r still wait for you $where, in one notification."
            else log_wrap "$n new for you $where: a Ginkgo notification."; fi ;;
    hold) log_wrap "$n new for you $where, held for the end of the quiet hours." ;;
    *) [ "$base" = 0 ] || log_wrap "What waits now $where is seen: only what comes next is announced." ;;
  esac
}

# ---------- lab ginkgo precision : les précisions de la personne (lot 09) ----------
# Ce qu'Alex dit à Ginkgo — « ignore X », « seulement X », « même la nuit pour X » — rangé à un seul endroit, $LAB_STATE/ginkgo/
# precisions, une ligne par précision : <id> <sorte> <projet> <couloir> <attente> <échéance epoch|never> <mots dits>,
# séparés par des tabulations, « - » pour un champ vide (read fond les tabulations voisines). Une précision couvre une attente quand
# chacun de ses champs posés (projet, couloir, sorte d'attente) est le sien ; news l'applique aux annonces, state --all aux réponses.
# Grill-me du 2026-11-28 : rangée tout de suite et redite par Ginkgo ; jusqu'à contre-ordre sans durée ; écrite par la personne seule.
GINKGO_PREC_SAID_MAX=200   # octets des mots dits gardés avec une précision
# shellcheck disable=SC2016 # du perl : ses $ ne sont pas du shell
GINKGO_PREC_TIME_PL='use POSIX (); my ($y, $mo, $d, $h, $mi) = $ARGV[0] =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d)$/ or exit 1;
my $e = POSIX::mktime(0, $mi, $h, $d, $mo - 1, $y - 1900, 0, 0, -1); defined $e or exit 1;
POSIX::strftime("%Y-%m-%dT%H:%M", localtime $e) eq $ARGV[0] or exit 1; print "$e\n";'
# ginkgo_prec_load : GP_N et les tableaux GP_ID, GP_KIND, GP_PROJ, GP_LANE, GP_WAIT, GP_UNTIL, GP_SAID des précisions en
# cours — une échue (échéance atteinte) ou une ligne illisible est sautée ; GP_NOW, l'heure de la lecture (LAB_NOW_EPOCH en test)
ginkgo_prec_load() {
  local f id kind pj ln wt un said
  GP_N=0; GP_ID=(); GP_KIND=(); GP_PROJ=(); GP_LANE=(); GP_WAIT=(); GP_UNTIL=(); GP_SAID=()
  GP_NOW="${LAB_NOW_EPOCH:-}"; [ -n "$GP_NOW" ] || GP_NOW="$(exec date +%s)"
  f="$(ginkgo_dir)/precisions"
  [ -f "$f" ] && [ -r "$f" ] || return 0
  while IFS=$'\t' read -r id kind pj ln wt un said || [ -n "$id" ]; do
    case "$id" in ''|*[!0-9]*) continue ;; esac
    case "$kind" in ignore|only|night) ;; *) continue ;; esac
    case "$un" in never) ;; ''|*[!0-9]*) continue ;; *) [ "$un" -gt "$GP_NOW" ] || continue ;; esac
    [ "$pj" != - ] || pj=''; [ "$ln" != - ] || ln=''; [ "$wt" != - ] || wt=''; [ "${said:--}" != - ] || said=''
    GP_ID[GP_N]="$id"; GP_KIND[GP_N]="$kind"; GP_PROJ[GP_N]="$pj"; GP_LANE[GP_N]="$ln"; GP_WAIT[GP_N]="$wt"
    GP_UNTIL[GP_N]="$un"; GP_SAID[GP_N]="$said"; GP_N=$((GP_N + 1))
  done <"$f"
}
# ginkgo_prec_match <projet> <couloir> <sorte> : GK_ASIDE=1 quand les précisions mettent l'attente de côté (un ignore la couvre, ou
# des only existent et aucun ne la couvre : plusieurs only s'ajoutent), GK_NIGHT=1 quand un night la couvre et qu'elle n'est pas de
# côté (ignore l'emporte) ; sans sous-shell, appelée pour chaque attente de chaque lecture
ginkgo_prec_match() {
  local i=0 only=0 in_only=0 night=0
  GK_ASIDE=0; GK_NIGHT=0
  while [ "$i" -lt "$GP_N" ]; do
    [ "${GP_KIND[i]}" != only ] || only=1
    if { [ -z "${GP_PROJ[i]}" ] || [ "${GP_PROJ[i]}" = "$1" ]; } && { [ -z "${GP_LANE[i]}" ] || [ "${GP_LANE[i]}" = "$2" ]; } \
      && { [ -z "${GP_WAIT[i]}" ] || [ "${GP_WAIT[i]}" = "$3" ]; }; then
      case "${GP_KIND[i]}" in ignore) GK_ASIDE=1 ;; only) in_only=1 ;; night) night=1 ;; esac
    fi
    i=$((i + 1))
  done
  if [ "$only" = 1 ] && [ "$in_only" = 0 ]; then GK_ASIDE=1; fi
  if [ "$GK_ASIDE" = 0 ] && [ "$night" = 1 ]; then GK_NIGHT=1; fi
}
# ginkgo_prec_write : les précisions chargées réécrites d'un coup, sauf celles dont la sorte vaut « - » (retirées) ; échues et lignes
# illisibles, jamais chargées, disparaissent du fichier
ginkgo_prec_write() {
  local f i=0 out=""
  f="$(ginkgo_dir)/precisions"
  while [ "$i" -lt "$GP_N" ]; do
    if [ "${GP_KIND[i]}" != - ]; then
      out="$out${GP_ID[i]}"$'\t'"${GP_KIND[i]}"$'\t'"${GP_PROJ[i]:--}"$'\t'"${GP_LANE[i]:--}"$'\t'"${GP_WAIT[i]:--}"
      out="$out"$'\t'"${GP_UNTIL[i]}"$'\t'"${GP_SAID[i]:--}"$'\n'
    fi
    i=$((i + 1))
  done
  [ -d "${f%/*}" ] || mkdir -p "${f%/*}"
  ( umask 077; printf '%s' "$out" >"$f.tmp.$$" && mv "$f.tmp.$$" "$f" ) || die "cannot write $f: nothing stored"
}
ginkgo_prec_time() { if [ "$1" = never ]; then echo never; else date -r "$1" +%Y-%m-%dT%H:%M; fi; }   # heure locale du Mac (TZ)
# ginkgo_prec_kv : NOW= et WEEKDAY= (heure locale, pour « jusqu'à demain matin »), PRECISIONS=, puis par précision
# PRECISION_n_ID=, _KIND=, _PROJECT=, _LANE=, _WAIT= (les champs posés seuls), _UNTIL=<AAAA-MM-JJTHH:MM>|never, _SAID=
ginkgo_prec_kv() {
  local i=0 n
  kv NOW "$(ginkgo_prec_time "$GP_NOW")"; kv WEEKDAY "$(LC_ALL=C exec date -r "$GP_NOW" +%A)"; kv PRECISIONS "$GP_N"
  while [ "$i" -lt "$GP_N" ]; do
    n=$((i + 1))
    kv "PRECISION_${n}_ID" "${GP_ID[i]}"; kv "PRECISION_${n}_KIND" "${GP_KIND[i]}"
    [ -z "${GP_PROJ[i]}" ] || kv "PRECISION_${n}_PROJECT" "${GP_PROJ[i]}"
    [ -z "${GP_LANE[i]}" ] || kv "PRECISION_${n}_LANE" "${GP_LANE[i]}"
    [ -z "${GP_WAIT[i]}" ] || kv "PRECISION_${n}_WAIT" "${GP_WAIT[i]}"
    kv "PRECISION_${n}_UNTIL" "$(ginkgo_prec_time "${GP_UNTIL[i]}")"
    [ -z "${GP_SAID[i]}" ] || kv "PRECISION_${n}_SAID" "${GP_SAID[i]}"
    i=$((i + 1))
  done
}
ginkgo_precision() {
  [ "$#" -ge 1 ] || usage
  local sub="$1"; shift
  case "$sub" in
    list) [ "$#" = 0 ] || usage; ginkgo_prec_load; ginkgo_prec_kv ;;
    set) ginkgo_prec_set "$@" ;;
    remove) ginkgo_prec_remove "$@" ;;
    *) usage ;;
  esac
}
# ginkgo_prec_set <ignore|only|night> [--project p] [--lane l] [--wait w] [--for <N>m|h|d | --until <AAAA-MM-JJTHH:MM>]
# [--said <mots>] [--id <n>] : ID=, CHANGED=added|updated, la précision rangée ; même sorte et même cible : mise à jour
ginkgo_prec_set() {
  [ "$#" -ge 1 ] || usage
  local kind="$1" pj='' ln='' wt='' dur='' until='' said='' id='' un=never n i hit=-1 max=0 changed=added
  case "$kind" in ignore|only|night) ;; *) usage ;; esac
  shift
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || usage
    case "$1" in
      --project) pj="$2" ;; --lane) ln="$2" ;; --wait) wt="$2" ;; --for) dur="$2" ;; --until) until="$2" ;; --said) said="$2" ;;
      --id) id="$2" ;;
      *) usage ;;
    esac
    shift 2
  done
  [ -z "$dur" ] || [ -z "$until" ] || usage
  # une précision fait taire des annonces : la voix de la personne seule, jamais l'agent d'un couloir (comme la mémoire de news)
  ginkgo_human precision
  [ -z "$ln" ] || [ -n "$pj" ] || die "a lane needs its project (--project): nothing stored"
  [ -n "$pj$wt" ] || die "a precision needs a project, a lane or a kind of wait (--project, --lane, --wait): nothing stored"
  if [ -n "$pj" ]; then project_exists "$pj" || die "unknown project: $pj — nothing stored"; fi
  [ -z "$ln" ] || ginkgo_lane "$pj" "$ln" "nothing stored"
  case "$wt" in ''|question|permission|blocked|acceptance|closing) ;;
    *) die "unknown kind of wait: $wt — question, permission, blocked, acceptance or closing; nothing stored" ;; esac
  case "$id" in ''|[1-9]|[1-9][0-9]|[1-9][0-9][0-9]) ;; *) die "no precision $id: lab ginkgo precision list gives their ID=" ;; esac
  ginkgo_prec_load
  if [ -n "$dur" ]; then
    n="${dur%[mhd]}"
    case "$n:${#n}" in [1-9]*:[1-6]) case "$n" in *[!0-9]*) n='' ;; esac ;; *) n='' ;; esac
    [ -n "$n" ] && [ "$n" != "$dur" ] \
      || die "--for $dur: a number of minutes (m), hours (h) or days (d), as 30m, 2h or 3d — nothing stored"
    case "$dur" in *m) un=$((GP_NOW + n * 60)) ;; *h) un=$((GP_NOW + n * 3600)) ;; *) un=$((GP_NOW + n * 86400)) ;; esac
  elif [ -n "$until" ]; then
    un="$(perl -e "$GINKGO_PREC_TIME_PL" "$until" 2>/dev/null)" && [ -n "$un" ] \
      || die "--until $until: a local time YYYY-MM-DDTHH:MM, as 2026-11-29T09:00 — nothing stored"
    [ "$un" -gt "$GP_NOW" ] || die "--until $until is already past (now $(ginkgo_prec_time "$GP_NOW")): nothing stored"
  fi
  said="$(printf '%s' "$said" | words_clean "$GINKGO_PREC_SAID_MAX" | tr -s ' ')"; said="${said# }"; said="${said% }"
  i=0
  while [ "$i" -lt "$GP_N" ]; do
    [ "${GP_ID[i]}" -le "$max" ] || max="${GP_ID[i]}"
    if [ -n "$id" ]; then [ "${GP_ID[i]}" != "$id" ] || hit="$i"
    elif [ "${GP_KIND[i]}:${GP_PROJ[i]}:${GP_LANE[i]}:${GP_WAIT[i]}" = "$kind:$pj:$ln:$wt" ]; then hit="$i"; fi
    i=$((i + 1))
  done
  [ -z "$id" ] || [ "$hit" -ge 0 ] || die "no precision $id: lab ginkgo precision list gives their ID="
  if [ "$hit" -ge 0 ]; then changed=updated; id="${GP_ID[hit]}"; else hit="$GP_N"; id=$((max + 1)); GP_N=$((GP_N + 1)); fi
  GP_ID[hit]="$id"; GP_KIND[hit]="$kind"; GP_PROJ[hit]="$pj"; GP_LANE[hit]="$ln"; GP_WAIT[hit]="$wt"; GP_UNTIL[hit]="$un"
  GP_SAID[hit]="$said"
  ginkgo_prec_write
  kv ID "$id"; kv CHANGED "$changed"; kv KIND "$kind"
  [ -z "$pj" ] || kv PROJECT "$pj"; [ -z "$ln" ] || kv LANE "$ln"; [ -z "$wt" ] || kv WAIT "$wt"
  kv UNTIL "$(ginkgo_prec_time "$un")"
  log_wrap "Precision $id $changed: Ginkgo applies it to what it announces and to its answers."
}
# ginkgo_prec_remove <id>|--all : REMOVED=<nombre> ; une précision inconnue est refusée, rien de retiré
ginkgo_prec_remove() {
  [ "$#" = 1 ] || usage
  local i=0 n=0
  case "$1" in --all|[1-9]|[1-9][0-9]|[1-9][0-9][0-9]) ;; -*) usage ;; *) die "no precision $1: lab ginkgo precision list gives their ID=" ;; esac
  ginkgo_human precision
  ginkgo_prec_load
  while [ "$i" -lt "$GP_N" ]; do
    if [ "$1" = --all ] || [ "${GP_ID[i]}" = "$1" ]; then GP_KIND[i]=-; n=$((n + 1)); fi
    i=$((i + 1))
  done
  [ "$1" = --all ] || [ "$n" -gt 0 ] || die "no precision $1: lab ginkgo precision list gives their ID="
  ginkgo_prec_write
  kv REMOVED "$n"
  log_wrap "$n precision(s) removed: Ginkgo announces again what they set aside."
}

# ---------- lab ginkgo [projet] : lance l'app sur ce projet ----------
ginkgo_build() {
  local b="${LAB_GINKGO_BUILD:-$LAB_ROOT/scripts/ginkgo-build.sh}"
  [ -x "$b" ] || die "Ginkgo.app is missing and cannot be built here ($b): lab update brings it"
  log_wrap "Building Ginkgo.app (Swift), about one minute the first time…"
  "$b" --output "${LAB_GINKGO_APP_DIR:-$(ginkgo_dir)}" --scratch "$(ginkgo_dir)/build" >&2 || die "Ginkgo.app build failed: see the output above"
}
ginkgo_launch() {
  # --background (lot 06) : lancé sans conversation ni micro en mode commande (l'écoute du nom en mode nom), pour l'app Treelab
  local bg=0 a; local -a rest=()
  for a in "$@"; do case "$a" in --background) bg=1 ;; -*) usage ;; *) rest+=("$a") ;; esac; done
  [ "${#rest[@]}" -le 1 ] || usage
  set -- "${rest[@]+"${rest[@]}"}"
  # lot 07 : Ginkgo est au-dessus de toutes les conversations — un projet (argument, ou le dossier courant) n'est que son point de
  # départ (FOCUS=) ; hors de tout projet, il part de tout le poste (--project vide, FOCUS=none)
  local p="" app hash sock where
  if [ -n "${1:-}" ]; then p="$(resolve_project "$1")"; load_project "$p"
  elif project_from_cwd_set "$PWD"; then p="$FOUND_PROJECT"; load_project "$p"; fi
  where="${p:-all projects}"
  sock="$(ginkgo_socket)"
  if [ "$(byte_len "$sock")" -gt "$GINKGO_SOCKET_MAX" ]; then
    local why; why="socket path of $(byte_len "$sock") bytes, beyond $GINKGO_SOCKET_MAX (sun_path): $sock — never truncated; set a shorter LAB_STATE_DIR"
    [ "$bg" = 0 ] || die "$why: nothing launched"
    warn "$why: Ginkgo starts without the channel of the Treelab app"
  fi
  ginkgo_platform
  if ! ginkgo_key_present; then
    # premier lancement (lot 04) : dans un terminal, la clé est demandée masquée et rangée, puis l'app s'ouvre ; ailleurs, refus
    [ -t 0 ] || die "no OpenAI key in the keychain: lab ginkgo key openai stores it once, then lab ginkgo${p:+ $p}"
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
  # une seule app à la fois : celle d'un autre projet se ferme (micro et connexion fermés avec elle) ; sinon macOS réactive l'ancienne
  ginkgo_stop || die "the running Ginkgo did not stop, even forced: nothing launched; quit it from its menu bar icon"
  # lot 05 : le mode d'écoute et la touche, lus une fois (un seul avertissement pour une valeur illisible)
  local listen hotkey; listen="$(ginkgo_listen_mode)"; hotkey="$(ginkgo_hotkey_value)"
  # l'app relance lab : même registre, même état que cette commande (comme launch_registry et l'alarme de lab wake)
  local -a env=(--env "PATH=$PATH" --env "LAB_HOME=$LAB_HOME")
  [ -z "${LAB_PROJECTS_DIR:-}" ] || env+=(--env "LAB_PROJECTS_DIR=$LAB_PROJECTS_DIR")
  [ -z "${LAB_STATE_DIR:-}" ] || env+=(--env "LAB_STATE_DIR=$LAB_STATE_DIR")
  [ -z "${CMUX_SOCKET_PATH:-}" ] || env+=(--env "CMUX_SOCKET_PATH=$CMUX_SOCKET_PATH")
  [ -z "${CMUX_SOCKET:-}" ] || env+=(--env "CMUX_SOCKET=$CMUX_SOCKET")
  local -a extra=(); [ "$bg" = 0 ] || extra+=(--background)
  open "${env[@]}" -a "$app" --args --project "$p" --lab "$(ginkgo_lab)" --log "$(ginkgo_dir)/ginkgo.log" \
    --model "$(global_config_get ginkgo_model)" --lang "$(lab_lang_detect)" --listen "$listen" --hotkey "$hotkey" \
    --socket "$sock" "${extra[@]+"${extra[@]}"}" >/dev/null 2>&1 \
    || die "macOS refused to open $app"
  [ -z "$p" ] || kv PROJECT "$p"
  kv FOCUS "${p:-none}"; kv APP "$app"; kv LAUNCHED yes; kv LOG "$(ginkgo_dir)/ginkgo.log"; kv LISTEN "$listen"; kv SOCKET "$sock"
  if [ "$bg" = 1 ]; then
    kv BACKGROUND yes
    case "$listen" in
      command) log_wrap "Ginkgo runs in the background for $where: no conversation and no microphone until the Treelab app opens it (lab ginkgo${p:+ $p} opens it too)." ;;
      key) log_wrap "Ginkgo runs in the background for $where: hold $(ginkgo_hotkey_display "$hotkey") while you speak; the microphone is off otherwise." ;;
      name) log_wrap "Ginkgo runs in the background for $where and waits for its name, heard on this Mac only: nothing leaves it before." ;;
    esac
    return 0
  fi
  case "$listen" in
    key) log_wrap "Ginkgo is ready for $where: hold $(ginkgo_hotkey_display "$hotkey") while you speak, release it for the answer; the microphone is off otherwise." ;;
    name) log_wrap "Ginkgo waits for its name in $where: say \"Ginkgo, …\" in one breath. This Mac alone hears the name: nothing leaves it before." ;;
    *) log_wrap "Ginkgo is listening for $where: speak freely; say stop (or use its menu bar icon) to close the microphone." ;;
  esac
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
  printf 'speech\tForget the speech recognition permission of Ginkgo (tccutil reset SpeechRecognition %s).\n' "$GINKGO_BUNDLE"
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
        if ginkgo_stop; then log_wrap 'Ginkgo stopped.'; else log_wrap 'Ginkgo did not stop: quit it from its menu bar icon.'; fi ;;
      microphone)   # sans entrée connue de macOS, tccutil répond non nul : rien à oublier
        if tccutil reset Microphone "$GINKGO_BUNDLE" >/dev/null 2>&1; then log_wrap 'Microphone permission of Ginkgo forgotten.'
        else log_wrap 'Microphone permission of Ginkgo: nothing to forget (tccutil found no entry).'; fi ;;
      speech)   # lot 05 : le mode nom (reconnaissance vocale d'Apple sur le Mac seul)
        if tccutil reset SpeechRecognition "$GINKGO_BUNDLE" >/dev/null 2>&1; then log_wrap 'Speech recognition permission of Ginkgo forgotten.'
        else log_wrap 'Speech recognition permission of Ginkgo: nothing to forget (tccutil found no entry).'; fi ;;
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
    listen) shift; ginkgo_listen "$@" ;;
    key) shift; ginkgo_key "$@" ;;
    state) shift; ginkgo_state "$@" ;;
    tell) shift; ginkgo_tell "$@" ;;
    question) shift; ginkgo_question "$@" ;;
    answer) shift; ginkgo_answer "$@" ;;
    order) shift; ginkgo_order "$@" ;;
    close) shift; ginkgo_close "$@" ;;
    reply) shift; ginkgo_reply "$@" ;;
    news) shift; ginkgo_news "$@" ;;
    precision) shift; ginkgo_precision "$@" ;;
    --background) ginkgo_launch "$@" ;;
    -*) usage ;;
    *) ginkgo_launch "$@" ;;
  esac
}
