# shellcheck shell=bash
# docker.sh — la machine Docker et les restes d'un projet (lot 01 de docker-menage) : lab docker [clean|prepare] [projet].
# Invariant : rien n'est retiré sans l'étiquette sh.treelab.project égale, chaîne pour chaîne, au projet courant (treelab n'est
# pas treelab-x) ; une ressource sans étiquette est comptée, jamais touchée. Retrait par identifiant, sans --force ni filtre de
# Docker ; le cache se vide sur le seul constructeur lab-<projet>, jamais sur celui par défaut.
# Chaque appel à Docker est borné (with_timeout de lib/log.sh) : Docker absent → DOCKER=missing, muet → DOCKER=down, rc 0.
# Chargé par la commande lab docker (comme ginkgo et app), et par la garde à la demande (section garde, lot 02) : les autres
# commandes ne paient rien.

DOCKER_LABEL_PROJECT=sh.treelab.project
DOCKER_LABEL_LANE=sh.treelab.lane
# place libre : df -Pk / dans un conteneur jetable, 0,2 s mesuré au lot 01 (colima ssh : 0,5 s, et propre à Colima) ; image jamais
# téléchargée par une lecture (--pull never), lab docker prepare la va chercher
DOCKER_PROBE_IMAGE=alpine:3
DOCKER_PROBE_WAIT=2   # 2 s pour Docker : lab docker répond DOCKER=down en moins de 3 s, démarrage de lab compris
DOCKER_LIST_WAIT=10
# retrait (rm, rmi, démarrage et arrêt du constructeur) : 60 s par appel ; au premier silence, clean s'arrête (DOCKER=down)
DOCKER_REMOVE_WAIT="${LAB_DOCKER_REMOVE_WAIT:-60}"
DOCKER_MIN_FREE_GB=10
DOCKER_MAX_USED_PCT=85

docker_bin_set() { DK="${LAB_DOCKER:-docker}"; }   # LAB_DOCKER : le faux docker des tests, jamais le vrai dans bats
# docker_labels <projet> [couloir] : les options d'étiquette, sur une ligne
docker_labels() {
  printf -- '--label %s=%s' "$DOCKER_LABEL_PROJECT" "$1"
  [ -z "${2:-}" ] || printf -- ' --label %s=%s' "$DOCKER_LABEL_LANE" "$2"
  printf '\n'
}
# docker_builder <projet> : lab-<projet> en minuscules, tout autre caractère que [a-z0-9_.-] devenu « - » (nom accepté par buildx)
docker_builder() {
  local n
  n="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  n="${n//[!abcdefghijklmnopqrstuvwxyz0123456789_.-]/-}"
  printf 'lab-%s\n' "$n"
}
# docker_days_set : DOCKER_DAYS = LAB_DOCKER_IMAGE_DAYS (7 par défaut), âge au-delà duquel une image et le cache du constructeur
# partent. Sans sous-shell : une valeur illisible arrête le processus avant toute lecture, même sous « || » (revue du lot 01 :
# dans $( ), le refus ne sortait que du sous-shell et l'âge vide valait 0 jour).
docker_days_set() {
  local d="${LAB_DOCKER_IMAGE_DAYS:-7}"
  case "$d" in ''|*[!0-9]*) die "LAB_DOCKER_IMAGE_DAYS must be a whole number of days (got \"$d\"): nothing read, nothing removed" ;; esac
  DOCKER_DAYS="$((10#$d))"
}
# docker_short <identifiant> : les 12 premiers chiffres, comme docker images ; les phrases restent sous 40 colonnes
docker_short() { local i="${1#sha256:}"; printf '%s' "${i:0:12}"; }
# docker_first_error <fichier> <identifiant> : première ligne d'erreur de Docker, identifiant raccourci
docker_first_error() {
  local m; m="$(awk 'NF { print; exit }' "$1")"
  [ -z "${2:-}" ] || { m="${m//$2/$(docker_short "$2")}"; m="${m//${2#sha256:}/$(docker_short "$2")}"; }
  printf '%s' "$m"
}

# docker_room_set <projet> : DOCKER_STATE (ok|missing|down), FREE_GB, USED_PCT, ROOM (ok|short|unknown), DOCKER_WHY ; n'écrit rien.
# FREE_GB en Go de 10^9 octets, arrondi en dessous, comme USED_PCT : short ⇔ FREE_GB < 10 ou USED_PCT ≥ 85, sans écart d'arrondi.
docker_room_set() {
  local p="$1" out err rc=0 line
  DOCKER_STATE=missing FREE_GB=unknown USED_PCT=unknown ROOM=unknown DOCKER_WHY=''
  docker_bin_set
  command -v "$DK" >/dev/null 2>&1 || return 0
  err="$(mktemp)"
  # --sig-proxy=false : au délai, TERM arrête le client docker lui-même ; relayé au df du conteneur (PID 1), il serait ignoré et
  # seul KILL, une seconde plus tard, rendrait la main (revue du lot 01)
  out="$(with_timeout "$DOCKER_PROBE_WAIT" "$DK" run --rm --pull never --network none --sig-proxy=false --label "$DOCKER_LABEL_PROJECT=$p" \
    "$DOCKER_PROBE_IMAGE" df -Pk / 2>"$err")" || rc=$?
  if [ "$rc" -eq 0 ]; then
    DOCKER_STATE=ok
    line="$(printf '%s\n' "$out" | LC_ALL=C awk -v min="$DOCKER_MIN_FREE_GB" -v max="$DOCKER_MAX_USED_PCT" '
      NR == 2 && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ {
        used = $3 + 0; avail = $4 + 0; total = used + avail
        pct = total > 0 ? int(used * 100 / total) : 100
        gb = int(avail * 1024 / 1000000000)
        print gb, pct, ((gb < min || pct >= max) ? "short" : "ok")
      }')"
    if [ -n "$line" ]; then read -r FREE_GB USED_PCT ROOM <<<"$line"
    else DOCKER_WHY="unreadable df output"; fi
  elif [ "$rc" -eq 124 ]; then DOCKER_STATE=down DOCKER_WHY="no answer within ${DOCKER_PROBE_WAIT} s"
  elif grep -qi 'no space left on device' "$err"; then DOCKER_STATE=ok FREE_GB=0 USED_PCT=100 ROOM=short DOCKER_WHY="no space left on device"
  elif grep -Eqi 'no such image|unable to find image' "$err"; then DOCKER_STATE=ok DOCKER_WHY=probe-missing
  else DOCKER_STATE=down DOCKER_WHY="$(awk 'NF { print; exit }' "$err")"; fi
  rm -f "$err"
}

# Âge d'une image : date de construction de docker image inspect (RFC 3339, fraction et décalage facultatifs) → secondes depuis
# l'époque, par epoch() de RDV_AWK (lib/rdv.sh) ; -1 si illisible (l'image est alors gardée). Aucune option de date propre à BSD ou
# GNU ; même résultat sous awk, gawk et mawk. Comparaisons en chaînes (x "" == p "") : « 01 » n'est jamais le projet « 1 ».
DOCKER_AWK='
function created(s,   base, rest, e, off) {
  base = substr(s, 1, 19); rest = substr(s, 20)
  e = epoch(base "Z"); if (e == "invalide") return -1
  sub(/^\.[0-9]+/, "", rest)
  if (rest == "Z") return e
  if (rest ~ /^[+-][0-9][0-9]:[0-9][0-9]$/) {
    off = substr(rest, 2, 2) * 3600 + substr(rest, 5, 2) * 60
    return substr(rest, 1, 1) == "+" ? e - off : e + off
  }
  return -1
}
'

# docker_leftovers_set <projet> [couloir] : DL_CONTAINERS et DL_IMAGES (identifiants à retirer, un par ligne), DL_NC, DL_NI,
# DL_UNREADABLE (images du projet à date illisible, gardées), DL_UNLABELED, DL_BUILDER, DL_BUILDER_STATE (running|stopped|
# inactive|absent), DL_CACHE (taille lue par buildx du, 0B sans cache, none sans constructeur, unknown s'il n'est pas lu).
# rc 1 si Docker ne répond plus pour lister conteneurs ou images ; un cache illisible n'est jamais un Docker muet.
# Étiquettes des conteneurs lues en JSON (| json) et comparées à la forme JSON du projet : une valeur qui porte un saut de ligne
# ou une tabulation reste un seul champ et ne forge jamais une ligne (revue du lot 01) ; les images passent par jq @tsv.
docker_leftovers_set() {
  local p="$1" lane="${2:-}" days now ps all labeled ids json rows out pq lq
  DL_CONTAINERS='' DL_IMAGES='' DL_NC=0 DL_NI=0 DL_UNREADABLE='' DL_UNLABELED=0 DL_CACHE=none DL_BUILDER_STATE=absent
  DL_BUILDER="$(docker_builder "$p")"
  docker_days_set; days="$DOCKER_DAYS"
  pq="$(jq -cn --arg v "$p" '$v')"; lq="$(jq -cn --arg v "$lane" '$v')"
  docker_bin_set
  ps="$(with_timeout "$DOCKER_LIST_WAIT" "$DK" ps -a --no-trunc \
    --format "{{.ID}}\t{{.State}}\t{{.Label \"$DOCKER_LABEL_PROJECT\" | json}}\t{{.Label \"$DOCKER_LABEL_LANE\" | json}}" 2>/dev/null)" || return 1
  all="$(with_timeout "$DOCKER_LIST_WAIT" "$DK" images --no-trunc --format '{{.ID}}' 2>/dev/null)" || return 1
  labeled="$(with_timeout "$DOCKER_LIST_WAIT" "$DK" images --no-trunc --filter "label=$DOCKER_LABEL_PROJECT" --format '{{.ID}}' 2>/dev/null)" || return 1
  DL_CONTAINERS="$(printf '%s\n' "$ps" | LC_ALL=C awk -F '\t' -v pq="$pq" -v l="$lane" -v lq="$lq" '
    NF == 4 && $3 "" == pq "" && (l == "" || $4 "" == lq "") && ($2 == "exited" || $2 == "created" || $2 == "dead") { print $1 }')"
  # sans étiquette : conteneurs, puis images (une ligne par nom d'image chez Docker : identifiants dédoublonnés)
  DL_UNLABELED="$( { printf '%s\n' "$ps" | awk -F '\t' 'NF == 4 && $3 == "\"\"" { print "C\t" $1 }'
      printf '%s\n' "$all" | awk 'NF { print "A\t" $1 }'; printf '%s\n' "$labeled" | awk 'NF { print "L\t" $1 }'; } \
    | LC_ALL=C awk -F '\t' '$1 == "C" { n++; next } $1 == "A" { a[$2] = 1; next } { l[$2] = 1 }
        END { for (i in a) if (!(i in l)) n++; print n + 0 }')"
  ids="$(printf '%s\n' "$labeled" | LC_ALL=C awk 'NF && !seen[$1]++')"
  if [ -n "$ids" ]; then
    # shellcheck disable=SC2086 # identifiants d'image, sans espace : un argument chacun
    json="$(with_timeout "$DOCKER_LIST_WAIT" "$DK" image inspect $ids 2>/dev/null)" || [ "$?" -ne 124 ] || return 1
    rows="$(printf '%s' "$json" | jq -r --arg kp "$DOCKER_LABEL_PROJECT" --arg kl "$DOCKER_LABEL_LANE" '.[] | ((.Config.Labels // {}) as $l
      | [.Id, (.Created // ""), ($l[$kp] // ""), ($l[$kl] // "")]) | @tsv' 2>/dev/null)" || return 1
    now="$(rdv_now)" || die "$(rdv_now_refusal)"
    out="$(printf '%s\n' "$rows" | LC_ALL=C awk -F '\t' -v p="$p" -v l="$lane" -v now="$now" -v days="$days" "$RDV_AWK$DOCKER_AWK"'
      BEGIN { n = epoch(now) }
      NF >= 3 && $3 "" == p "" && (l == "" || $4 "" == l "") {
        e = created($2)
        if (e < 0) print "U\t" $1
        else if (n - e > days * 86400) print "I\t" $1
      }')"
    DL_IMAGES="$(printf '%s\n' "$out" | awk -F '\t' '$1 == "I" { print $2 }')"
    DL_UNREADABLE="$(printf '%s\n' "$out" | awk -F '\t' '$1 == "U" { print $2 }')"
  fi
  DL_NC="$(printf '%s\n' "$DL_CONTAINERS" | grep -c . || true)"
  DL_NI="$(printf '%s\n' "$DL_IMAGES" | grep -c . || true)"
  docker_builder_state_set "$DL_BUILDER"
  case "$DL_BUILDER_STATE" in
    absent) ;;
    # inactif : jamais démarré, ou conteneur buildkit retiré alors que son volume d'état garde le cache ; jamais démarré par une
    # lecture (premier démarrage : téléchargement de buildkit, 40 s mesurées), donc jamais annoncé vide (revue du lot 01)
    inactive) DL_CACHE=unknown ;;
    running)
      if out="$(docker_cache_read "$DL_BUILDER")"; then
        DL_CACHE="$(printf '%s\n' "$out" | awk '$1 == "Total:" { v = $2 } END { print (v == "" ? "0B" : v) }')"
      else DL_CACHE=unknown; fi ;;
    # arrêté (docker stop, buildx stop : sa politique unless-stopped le relance sinon) : buildx du répond « driver not running »
    # (mesuré au lot 01) ; une lecture ne le démarre jamais, clean le démarre puis l'arrête de nouveau
    *) DL_CACHE=unknown ;;
  esac
}
# docker_cache_read <constructeur> : sortie de buildx du sur ce seul constructeur, bornée
docker_cache_read() { with_timeout "$DOCKER_LIST_WAIT" "$DK" buildx du --builder "$1" 2>/dev/null; }
# docker_builder_state_set <nom> : DL_BUILDER_STATE, l'état du nœud lu par buildx inspect (sans --bootstrap) ; absent s'il n'existe pas
docker_builder_state_set() {
  local out
  DL_BUILDER_STATE=absent
  out="$(with_timeout "$DOCKER_LIST_WAIT" "$DK" buildx inspect "$1" 2>/dev/null)" || return 0
  DL_BUILDER_STATE="$(printf '%s\n' "$out" | awk '/^Nodes:/ { n = 1 } n && $1 == "Status:" { s = $2 } END { print (s == "" ? "unknown" : s) }')"
}

# docker_unanswered : DOCKER=missing|down avec sa phrase ; rc 0 si Docker répond (la suite peut lire)
docker_unanswered() {
  case "$DOCKER_STATE" in
    missing) kv DOCKER missing; onboard_say "Docker is not installed here: nothing to read, nothing removed."; return 0 ;;
    down) kv DOCKER down; onboard_say "Docker does not answer ($DOCKER_WHY): nothing read, nothing removed. Start Docker, then run the command again."; return 0 ;;
  esac
  return 1
}
docker_room_kv() { kv FREE_GB "$FREE_GB"; kv USED_PCT "$USED_PCT"; kv ROOM "$ROOM"; }
docker_room_say() { # <projet> <préfixe>
  local rule="at least $DOCKER_MIN_FREE_GB GB free and under $DOCKER_MAX_USED_PCT% used"
  case "$ROOM" in
    ok) onboard_say "$2: $FREE_GB GB free, $USED_PCT% used — room ok ($rule)." ;;
    short) onboard_say "$2: $FREE_GB GB free, $USED_PCT% used — room short (needs $rule): lab docker clean $1 removes the leftovers of $1." ;;
    *) if [ "$DOCKER_WHY" = probe-missing ]; then onboard_say "$2: free space not read, image $DOCKER_PROBE_IMAGE missing — lab docker prepare $1 fetches it."
       else onboard_say "$2: free space not read ($DOCKER_WHY)."; fi ;;
  esac
}
docker_failed_listing() { kv DOCKER down; onboard_say "Docker stopped answering while listing: nothing removed. Run the command again."; }

# docker_show <projet> : lab docker — lecture seule
docker_show() {
  local p="$1" days cache unlabeled short="" a
  docker_days_set; days="$DOCKER_DAYS"
  docker_room_set "$p"
  ! docker_unanswered || return 0
  docker_leftovers_set "$p" || { docker_failed_listing; return 0; }
  kv DOCKER ok; docker_room_kv
  kv CONTAINERS "$DL_NC"; kv IMAGES "$DL_NI"; kv CACHE "$DL_CACHE"; kv UNLABELED "$DL_UNLABELED"; kv BUILDER "$DL_BUILDER"
  docker_room_say "$p" "Docker machine"
  case "$DL_BUILDER_STATE:$DL_CACHE" in
    absent:*) cache="build cache: no builder $DL_BUILDER yet (lab docker prepare $p creates it)" ;;
    stopped:*) cache="build cache: not read, builder $DL_BUILDER stopped (lab docker clean $p starts it, empties its old cache and stops it again)" ;;
    *:unknown) cache="build cache: not read (builder $DL_BUILDER, $DL_BUILDER_STATE)" ;;
    *) cache="build cache: $DL_CACHE (builder $DL_BUILDER)" ;;
  esac
  onboard_say "Leftovers of $p: stopped containers: $DL_NC · images older than $days days: $DL_NI · $cache."
  if [ -n "$DL_UNREADABLE" ]; then
    while IFS= read -r a; do [ -z "$a" ] || short="$short $(docker_short "$a")"; done <<<"$DL_UNREADABLE"
    onboard_say "Images of $p with an unreadable build date, kept:$short"
  fi
  unlabeled="$DL_UNLABELED containers and images without a Treelab label: counted, never touched."
  onboard_say "$unlabeled"
  [ "$((DL_NC + DL_NI))" -eq 0 ] || onboard_say "To remove the leftovers of $p: lab docker clean $p"
}

# docker_clean <projet> [couloir] : lab docker clean — conteneurs arrêtés, images trop vieilles, vieux cache du constructeur dédié.
# Au premier appel de retrait resté sans réponse (rc 124), plus rien n'est tenté : DOCKER=down, le reste attend le prochain passage.
# Un constructeur trouvé arrêté est démarré le temps du vidage (0,4 s mesurée, image buildkit déjà là), puis arrêté de nouveau,
# que le vidage réussisse ou non — laissé comme trouvé.
docker_clean() {
  local p="$1" lane="${2:-}" days err out id containers=0 removed=0 kept=0 freed=none stalled=0 started=0 rc
  local -a ids=()
  docker_days_set; days="$DOCKER_DAYS"
  docker_room_set "$p"
  ! docker_unanswered || return 0
  docker_leftovers_set "$p" "$lane" || { docker_failed_listing; return 0; }
  err="$(mktemp)"
  if [ -n "$DL_CONTAINERS" ]; then
    while IFS= read -r id; do [ -z "$id" ] || ids+=("$id"); done <<<"$DL_CONTAINERS"
    rc=0; out="$(with_timeout "$DOCKER_REMOVE_WAIT" "$DK" rm "${ids[@]}" 2>"$err")" || rc=$?
    if [ "$rc" -eq 124 ]; then stalled=1
    elif [ "$rc" -ne 0 ]; then warn_wrap "docker rm: $(docker_first_error "$err")"; fi
    containers="$(printf '%s\n' "$out" | LC_ALL=C awk 'NR == FNR { want[$1] = 1; next } ($1 in want) { n++ } END { print n + 0 }' <(printf '%s\n' "${ids[@]}") -)"
  fi
  while [ "$stalled" = 0 ] && IFS= read -r id; do
    [ -n "$id" ] || continue
    rc=0; with_timeout "$DOCKER_REMOVE_WAIT" "$DK" rmi "$id" >/dev/null 2>"$err" || rc=$?
    case "$rc" in
      0) removed=$((removed + 1)) ;;
      124) stalled=1 ;;
      *) kept=$((kept + 1)); warn_wrap "image $(docker_short "$id") kept: $(docker_first_error "$err" "$id")" ;;
    esac
  done <<<"$DL_IMAGES"
  case "$stalled:$DL_BUILDER_STATE" in
    0:running|0:stopped)
      rc=0
      if [ "$DL_BUILDER_STATE" = stopped ]; then
        with_timeout "$DOCKER_REMOVE_WAIT" "$DK" buildx inspect --bootstrap "$DL_BUILDER" >/dev/null 2>"$err" || rc=$?
        if [ "$rc" -eq 0 ]; then started=1
        elif [ "$rc" -eq 124 ]; then stalled=1
        else freed=failed; warn_wrap "builder $DL_BUILDER not started, its cache stays: $(docker_first_error "$err")"; fi
      fi
      if [ "$stalled" = 0 ] && [ "$freed" != failed ]; then
        rc=0; out="$(with_timeout 300 "$DK" buildx prune --builder "$DL_BUILDER" --filter "until=$((days * 24))h" -f 2>"$err")" || rc=$?
        case "$rc" in
          0) freed="$(printf '%s\n' "$out" | awk '$1 == "Total:" { v = $2 } END { print (v == "" ? "0B" : v) }')" ;;
          124) stalled=1 ;;
          *) freed=failed; warn_wrap "build cache of $DL_BUILDER not emptied: $(docker_first_error "$err")" ;;
        esac
      fi
      if [ "$started" = 1 ] && [ "$stalled" = 0 ]; then
        with_timeout "$DOCKER_REMOVE_WAIT" "$DK" buildx stop "$DL_BUILDER" >/dev/null 2>&1 || warn_wrap "builder $DL_BUILDER left running after the cleaning"
      fi ;;
  esac
  rm -f "$err"
  if [ "$stalled" = 1 ]; then kv DOCKER down; else kv DOCKER ok; fi
  kv CONTAINERS_REMOVED "$containers"; kv IMAGES_REMOVED "$removed"; kv IMAGES_KEPT "$kept"; kv CACHE_FREED "$freed"
  onboard_say "Removed for $p: stopped containers: $containers · images older than $days days: $removed · build cache freed: $freed. Nothing of another project nor without a label was touched."
  if [ "$stalled" = 1 ]; then
    onboard_say "Docker stopped answering during the cleaning (no answer within $DOCKER_REMOVE_WAIT s): the rest waits for the next lab docker clean $p."
    return 0
  fi
  docker_room_set "$p"
  # la garde lit cette place et l'heure de ce nettoyage : encore court juste après, le reste n'est pas au projet (lot 02)
  docker_now_set; docker_room_save "$p"
  if [ "$DOCKER_STATE" = ok ]; then docker_room_kv; docker_room_say "$p" "Docker machine now"; fi
}

# docker_prepare <projet> : lab docker prepare — constructeur lab-<projet> créé une fois, image de mesure présente
docker_prepare() {
  local p="$1" b state probe=present
  docker_room_set "$p"
  ! docker_unanswered || return 0
  b="$(docker_builder "$p")"
  docker_builder_state_set "$b"; state="$DL_BUILDER_STATE"
  if [ "$state" = absent ]; then
    with_timeout 60 "$DK" buildx create --name "$b" --driver docker-container >/dev/null 2>&1 \
      || die "builder $b not created: docker buildx create --name $b --driver docker-container failed"
    state=created
  fi
  if ! with_timeout "$DOCKER_LIST_WAIT" "$DK" image inspect "$DOCKER_PROBE_IMAGE" >/dev/null 2>&1; then
    if with_timeout 300 "$DK" pull "$DOCKER_PROBE_IMAGE" >/dev/null 2>&1; then probe=pulled; else probe=failed; fi
  fi
  kv DOCKER ok; kv BUILDER "$b"; kv BUILDER_STATE "$state"; kv PROBE "$probe"
  case "$state" in
    created) onboard_say "Builder $b created for $p: its build cache stays apart from other projects. It starts at its first build." ;;
    *) onboard_say "Builder $b already there ($state): nothing created." ;;
  esac
  case "$probe" in
    pulled) onboard_say "Image $DOCKER_PROBE_IMAGE fetched: lab docker reads the free space with it." ;;
    failed) warn_wrap "image $DOCKER_PROBE_IMAGE not fetched: lab docker cannot read the free space until docker pull $DOCKER_PROBE_IMAGE works" ;;
  esac
}

# ---------- garde (lot 02 de docker-menage) ----------
# Chargée par la garde (lib/hooks.sh) seulement quand une commande est docker, préfixes et substitutions compris (docker_prefix_count,
# docker_subst_hint), dans un projet enregistré : sa fermeture est
# contrôlée par tests/hooks.bats. Un conteneur part à sa fin (--rm, ou --restart autre que no) et porte les étiquettes du projet et
# du couloir ; une construction passe par le constructeur lab-<projet>, sort son image (--load, --push, --output) et l'étiquette ;
# une purge large se limite au projet ; une commande qui crée vérifie la place. Chaque refus donne la ligne exacte à lancer, bâtie
# sur la commande brute (morceaux recollés à l'octet près, options insérées après le mot de sous-commande) : elle repasse la garde.
# Projet et couloir : ceux du dossier de la session (un cd de la commande ne les change pas). Hors de portée : docker lancé par un
# script ou dans bash -c "…", une commande trop longue à lire dans le délai du crochet (DOCKER_TOKENS_BUDGET).
DOCKER_ROOM_TTL=60        # place lue au plus une fois par minute, pour toutes les sessions
DOCKER_CLEAN_RECENT=600   # un nettoyage du projet de moins de 10 min : la place qui manque encore n'est pas au projet
DOCKER_RUN_BOOLS=' --rm --detach --interactive --tty --init --privileged --publish-all --read-only --no-healthcheck --oom-kill-disable --disable-content-trust --quiet --sig-proxy --help --use-api-socket --no-TTY --no-deps --service-ports --use-aliases --build --remove-orphans --quiet-pull '

# docker_now_set : DOCKER_NOW, l'heure en secondes depuis l'époque (EPOCHSECONDS de bash 5, sinon un seul date)
docker_now_set() { DOCKER_NOW="${EPOCHSECONDS:-}"; [ -n "$DOCKER_NOW" ] || DOCKER_NOW="$(exec date +%s)"; }
# docker_room_save [projet nettoyé] : la place lue (DOCKER_STATE, ROOM, FREE_GB, USED_PCT) écrite au cache commun
# $LAB_STATE/docker-room à l'heure DOCKER_NOW ; les nettoyages des autres projets restent, celui du projet donné est posé. Sans
# processus (hors mkdir d'un état absent) ; une écriture impossible, ou un état inconnu (bibliothèque chargée sans lib/project.sh),
# n'arrête rien
docker_room_save() {
  [ -n "${LAB_STATE:-}" ] || return 0
  local f="$LAB_STATE/docker-room" line keep=''
  if [ -f "$f" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in "CLEAN.${1:-}="*) ;; CLEAN.*=*) keep="$keep$line"$'\n' ;; esac
    done <"$f" 2>/dev/null || true
  fi
  [ -z "${1:-}" ] || keep="${keep}CLEAN.$1=$DOCKER_NOW"$'\n'
  [ -d "$LAB_STATE" ] || mkdir -p "$LAB_STATE" 2>/dev/null || return 0
  printf 'AT=%s\nDOCKER=%s\nROOM=%s\nFREE_GB=%s\nUSED_PCT=%s\n%s' "$DOCKER_NOW" "$DOCKER_STATE" "$ROOM" "$FREE_GB" "$USED_PCT" "$keep" \
    >"$f" 2>/dev/null || true
}
# docker_room_cached <projet> : DOCKER_STATE, ROOM, FREE_GB, USED_PCT lus au cache, DOCKER_CLEANED (heure du dernier nettoyage du
# projet, vide sans) ; rc 0 si la lecture a moins de DOCKER_ROOM_TTL secondes (DOCKER_NOW posé)
docker_room_cached() {
  local f="${LAB_STATE:-}/docker-room" line at=''
  DOCKER_STATE=missing FREE_GB=unknown USED_PCT=unknown ROOM=unknown DOCKER_CLEANED=''
  [ -n "${LAB_STATE:-}" ] || return 1
  [ -f "$f" ] && [ -r "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      AT=*) at="${line#*=}" ;; DOCKER=*) DOCKER_STATE="${line#*=}" ;; ROOM=*) ROOM="${line#*=}" ;;
      FREE_GB=*) FREE_GB="${line#*=}" ;; USED_PCT=*) USED_PCT="${line#*=}" ;; "CLEAN.$1="*) DOCKER_CLEANED="${line#*=}" ;;
    esac
  done <"$f"
  case "$DOCKER_CLEANED" in ''|*[!0-9]*) DOCKER_CLEANED='' ;; *) DOCKER_CLEANED="$((10#$DOCKER_CLEANED))" ;; esac
  case "$at" in ''|*[!0-9]*) return 1 ;; esac
  at="$((DOCKER_NOW - 10#$at))"
  [ "$at" -ge 0 ] && [ "$at" -lt "$DOCKER_ROOM_TTL" ]
}
# docker_room_guard <projet> : la place pour la garde — le cache de moins d'une minute, sinon une lecture bornée (DOCKER_PROBE_WAIT)
# écrite au cache ; la minute est retenue avant la lecture (ROOM=unknown), pour que les crochets lancés pendant ce temps passent sans
# relire. Docker absent : rien n'est lu ni écrit
docker_room_guard() {
  local cleaned
  docker_now_set
  ! docker_room_cached "$1" || return 0
  cleaned="$DOCKER_CLEANED"
  docker_bin_set
  if ! command -v "$DK" >/dev/null 2>&1; then DOCKER_STATE=missing ROOM=unknown; return 0; fi
  DOCKER_STATE=reading ROOM=unknown FREE_GB=unknown USED_PCT=unknown; docker_room_save
  docker_room_set "$1"; docker_room_save
  DOCKER_CLEANED="$cleaned"
}

# docker_plain <mot brut> : DP, sa valeur une fois les guillemets et les échappements retirés ; DP_OK=0 si elle dépend d'une
# expansion ($VAR, $(…), `…`) ou d'une chaîne non refermée — le texte de l'expansion reste alors dans DP, tel quel
docker_plain() {
  local w="$1" out='' c rest
  DP_OK=1
  while [ -n "$w" ]; do
    case "$w" in
      "'"*) rest="${w:1}"
        case "$rest" in *"'"*) out="$out${rest%%"'"*}"; w="${rest#*"'"}" ;; *) DP_OK=0; out="$out$rest"; w='' ;; esac ;;
      '"'*) rest="${w:1}"
        case "$rest" in
          *'"'*) c="${rest%%'"'*}"; case "$c" in *[\$\`\\]*) DP_OK=0 ;; esac; out="$out$c"; w="${rest#*'"'}" ;;
          *) DP_OK=0; out="$out$rest"; w='' ;;
        esac ;;
      "\\"$'\n'*) w="${w:2}" ;;   # continuation de ligne au milieu du mot : retirée, comme bash
      \\*) out="$out${w:1:1}"; w="${w:2}" ;;
      ['$`']*) DP_OK=0; out="$out${w:0:1}"; w="${w:1}" ;;
      *) c="${w%%[\'\"\\\$\`]*}"; out="$out$c"; w="${w#"$c"}" ;;
    esac
  done
  DP="$out"
}
# docker_quoted_set <texte> : DQ, la chaîne citée ('…', ou "…" avec ses échappements et ses $(…), où un " ouvre une chaîne neuve,
# comme bash) ou l'échappement (\x) qui ouvre le texte ; non refermée, tout le texte
docker_quoted_set() {
  local r c out
  case "$1" in
    "'"*) r="${1:1}"; case "$r" in *"'"*) DQ="'${r%%"'"*}'" ;; *) DQ="$1" ;; esac ;;
    '"'*) out='"'; r="${1:1}"
      while [ -n "$r" ]; do
        c="${r%%[\"\\\$]*}"; out="$out$c"; r="${r:${#c}}"
        case "$r" in
          \\*) out="$out${r:0:2}"; r="${r:2}" ;;
          \$\(*) docker_subst_text_set "$r"; out="$out$DSUB"; r="${r:${#DSUB}}" ;;
          \$*) out="$out\$"; r="${r:1}" ;;
          '"'*) out="$out\""; break ;;
        esac
      done
      DQ="$out" ;;
    *) DQ="${1:0:2}" ;;
  esac
}
# docker_subst_text_set <texte qui commence par $(> : DSUB, la substitution jusqu'à sa parenthèse — chaînes citées, échappements et
# parenthèses imbriquées compris ; non refermée, tout le texte
docker_subst_text_set() {
  local s="${1:2}" out="\$(" c depth=1
  while [ -n "$s" ] && [ "$depth" -gt 0 ]; do
    c="${s%%[()\'\"\\]*}"; out="$out$c"; s="${s:${#c}}"
    case "$s" in
      [\'\"\\]*) docker_quoted_set "$s"; out="$out$DQ"; s="${s:${#DQ}}"; continue ;;
      '('*) depth=$((depth + 1)) ;; ')'*) depth=$((depth - 1)) ;;
    esac
    [ -z "$s" ] || { out="$out${s:0:1}"; s="${s:1}"; }
  done
  DSUB="$out"
}
# docker_tokens <commande brute> : DT_TEXT, ses morceaux dans l'ordre — leur concaténation redonne la commande à l'octet près — et
# DT_KIND, la sorte de chacun : w mot (chaînes citées, échappements, $(…), `…` et redirections >&, &> compris), s blancs (\ suivi
# d'un retour à la ligne compris, comme bash), o fin de segment (&&, ||, ;, |, & seul, retour à la ligne), p parenthèse de sous-shell,
# h corps d'un here-doc ou commentaire, jamais jugés. Sans processus ; chaque morceau relit la suite de la commande : au-delà de
# DOCKER_TOKENS_BUDGET octets relus en tout, DT_OVER=1 et rien de plus n'est lu (un corps de here-doc ne compte que pour un morceau).
DOCKER_TOKENS_BUDGET=4000000   # ≈ 0,1 s sur un Mac, cinq fois plus sur la CI Linux (20 M : 3,7 s, #264) ; script de 5 Ko : lu
docker_tokens() {
  # octets, pas caractères : tous les délimiteurs sont ASCII, et une chaîne UTF-8 n'est plus reconvertie à chaque morceau
  local LC_ALL=C
  local s="$1" w c rest depth delim dash line nl=$'\n' stop=$' \t\n;&|()\'"\\$`' next='' cost=0
  local -a pend=()
  DT_TEXT=(); DT_KIND=(); DT_OVER=0
  while [ -n "$s" ]; do
    cost=$((cost + ${#s})); if [ "$cost" -gt "$DOCKER_TOKENS_BUDGET" ]; then DT_OVER=1; return 0; fi
    case "$s" in
      [$' \t']*) w="${s%%[!$' \t']*}"; DT_TEXT+=("$w"); DT_KIND+=(s); s="${s#"$w"}"; continue ;;
      "\\$nl"*) DT_TEXT+=("\\$nl"); DT_KIND+=(s); s="${s:2}"; continue ;;
      '#'*) w="${s%%"$nl"*}"; DT_TEXT+=("$w"); DT_KIND+=(h); s="${s#"$w"}"; continue ;;   # commentaire, jusqu'au retour à la ligne
      '&&'*|'||'*) DT_TEXT+=("${s:0:2}"); DT_KIND+=(o); s="${s:2}"; continue ;;
      '&>'*) ;;
      "$nl"*)
        DT_TEXT+=("$nl"); DT_KIND+=(o); s="${s:1}"
        # corps des here-docs ouverts sur la ligne, chacun jusqu'à la ligne de son délimiteur comprise ; sans tabulations à retirer
        # (<<), d'un seul bloc : ligne à ligne, un corps de 80 Ko recopiait la suite 2 000 fois (revue du lot)
        for delim in "${pend[@]+"${pend[@]}"}"; do
          dash="${delim%%:*}"; delim="${delim#*:}"; w=''
          if [ "$dash" = 0 ]; then
            case "$s" in
              "$delim"|"$delim$nl"*) w="$delim" ;;
              *"$nl$delim$nl"*) w="${s%%"$nl$delim$nl"*}$nl$delim" ;;
              *) w="$s" ;;
            esac
            s="${s:${#w}}"   # par longueur : ${s#"$w"} essaie chaque préfixe, quadratique sur un corps de 80 Ko
          else
            while [ -n "$s" ]; do
              case "$s" in *"$nl"*) line="${s%%"$nl"*}" ;; *) line="$s" ;; esac
              w="$w$line"; s="${s:${#line}}"; c="${line#"${line%%[!$'\t']*}"}"
              [ "$c" != "$delim" ] || break
              case "$s" in "$nl"*) w="$w$nl"; s="${s:1}" ;; esac
            done
          fi
          [ -z "$w" ] || { DT_TEXT+=("$w"); DT_KIND+=(h); }
        done
        pend=(); continue ;;
      [';|&']*) DT_TEXT+=("${s:0:1}"); DT_KIND+=(o); s="${s:1}"; continue ;;
      ['()']*) DT_TEXT+=("${s:0:1}"); DT_KIND+=(p); s="${s:1}"; continue ;;
    esac
    w=''
    while [ -n "$s" ]; do
      case "$s" in
        [$' \t\n;|()']*) break ;;   # \ puis retour : blanc entre deux mots (plus haut), dans un mot il le continue (\\* ci-dessous)
        '&'*) case "$w" in ''|*'>'|*'<') w="$w&"; s="${s:1}" ;; *) break ;; esac ;;
        [\'\"]*) docker_quoted_set "$s"; w="$w$DQ"; s="${s:${#DQ}}" ;;
        \\*) w="$w${s:0:2}"; s="${s:2}" ;;
        \$\(*) docker_subst_text_set "$s"; w="$w$DSUB"; s="${s:${#DSUB}}" ;;   # chaînes citées et échappements sautés
        '`'*) rest="${s:1}"
          case "$rest" in *'`'*) c="${rest%%'`'*}"; w="$w\`$c\`"; s="${rest#*'`'}" ;; *) w="$w$s"; s='' ;; esac ;;
        *) c="${s%%["$stop"]*}"
          if [ -n "$c" ]; then w="$w$c"; s="${s#"$c"}"; else w="$w${s:0:1}"; s="${s:1}"; fi ;;
      esac
    done
    DT_TEXT+=("$w"); DT_KIND+=(w)
    # here-doc : << ou <<- hors chaîne citée, délimiteur collé ou mot suivant ; <<< est une chaîne, pas un here-doc
    if [ -n "$next" ]; then docker_plain "$w"; pend+=("$next:$DP"); next=''; continue; fi
    case "$w" in *'<<<'*) continue ;; *'<<'*) ;; *) continue ;; esac
    case "${w%%<<*}" in *[\'\"]*) continue ;; esac
    delim="${w##*<<}"; dash=0
    case "$delim" in -*) dash=1; delim="${delim#-}" ;; esac
    if [ -z "$delim" ]; then next="$dash"; else docker_plain "$delim"; pend+=("$dash:$DP"); fi
  done
}

# docker_drop <premier morceau> <dernier morceau> : retirés de la ligne corrigée, avec les blancs qui les précèdent
docker_drop() {
  local k="$1"
  [ "$k" -eq 0 ] || [ "${DT_KIND[$((k - 1))]}" != s ] || DG_DROP[k - 1]=1
  while [ "$k" -le "$2" ]; do DG_DROP[k]=1; k=$((k + 1)); done
}
docker_why() { case "$DG_WHY" in *"$1"*) ;; '') DG_WHY="$1" ;; *) DG_WHY="$DG_WHY; $1" ;; esac; }
# docker_shown <texte> : le texte tel qu'écrit dans une raison, coupé à 60 caractères
docker_shown() { DS="$1"; [ "${#DS}" -le 60 ] || DS="${DS:0:59}…"; }
# docker_label <mot de l'option> <mot de la valeur> : juge une étiquette (SW, SP, SOK : mots du segment) ; celle du projet ou du
# couloir, juste, pose S_OKP ou S_OKL ; fausse, ou illisible quand sa clé peut être la nôtre, elle est retirée de la ligne
docker_label() {
  local v="${SP[$2]:-}" ok="${SOK[$2]:-0}" key val
  key="${v%%=*}"; val="${v#*=}"; [ "$key" != "$v" ] || val=''
  case "$key" in *['$`']*) ok=key ;; esac
  case "$key" in
    "$DOCKER_LABEL_PROJECT") if [ "$ok" = 1 ] && [ "$val" = "$DG_P" ]; then S_OKP=1; return 0; fi ;;
    "$DOCKER_LABEL_LANE")
      [ -n "$DG_LANE" ] || return 0
      if [ "$ok" = 1 ] && [ "$val" = "$DG_LANE" ]; then S_OKL=1; return 0; fi ;;
    *) [ "$ok" = key ] || return 0 ;;
  esac
  docker_drop "${SW[$1]}" "${SW[$2]}"
  if [ "$ok" = 1 ]; then
    case "$key" in
      "$DOCKER_LABEL_PROJECT") docker_why "label $v is not $DG_P's" ;;
      *) docker_why "label $v is not lane $DG_LANE's" ;;
    esac
  else
    docker_shown "${DT_TEXT[${SW[$2]}]}"; docker_why "label $DS cannot be read here (variable or command): written in clear"
  fi
  S_CHANGED=1
}
# docker_needs_room : une commande qui crée ; DG_BARE compte celles qu'aucun lab docker clean du projet ne précède
docker_needs_room() { DG_ROOM=$((DG_ROOM + 1)); [ "$DG_CLEANED" = 1 ] || DG_BARE=$((DG_BARE + 1)); }
# docker_value_is <mot de la valeur> <attendu> : rc 0 si la valeur se lit et vaut l'attendu
docker_value_is() { [ "${SOK[$1]:-0}" = 1 ] && [ "${SP[$1]:-}" = "$2" ]; }
# docker_labels_needed <indice du mot de sous-commande> : étiquettes manquantes ajoutées après lui
docker_labels_needed() {
  local add='' miss='' what=label
  if [ "$S_OKP" = 0 ]; then add="--label $DOCKER_LABEL_PROJECT=$DG_P"; miss="$DOCKER_LABEL_PROJECT=$DG_P"; fi
  if [ -n "$DG_LANE" ] && [ "$S_OKL" = 0 ]; then
    [ -z "$add" ] || what=labels
    add="${add:+$add }--label $DOCKER_LABEL_LANE=$DG_LANE"; miss="${miss:+$miss and }$DOCKER_LABEL_LANE=$DG_LANE"
  fi
  [ -n "$add" ] || return 0
  S_ADD="${S_ADD:+$S_ADD }$add"
  docker_why "without the $what $miss, lab docker clean $DG_P cannot find it"
}

# docker_segment <premier mot> <dernier mot> : juge le segment dont DG_W porte les morceaux de mots (indices dans DT_TEXT)
docker_segment() {
  local -a SW=() SP=() SOK=()
  local k n i j sub sub2='' cls='' ins scan forced=0 w rm=0 durable=0 okb=0 out=0 okf=0 b
  for k in "${DG_W[@]}"; do docker_plain "${DT_TEXT[$k]}"; SW+=("$k"); SP+=("$DP"); SOK+=("$DP_OK"); done
  n="${#SW[@]}"
  docker_prefix_count "${SP[@]}"; i="$PREFIX_N"; forced="$PREFIX_FORCED"   # lib/hooks.sh : la liste du pré-filtre
  [ "$i" -lt "$n" ] || return 0
  base_set "${SP[$i]}"
  case "$BASE" in
    lab)   # lab docker clean|prepare [projet], sans option : la place ou le constructeur des segments suivants est pris en charge
      [ "${SP[$((i + 1))]:-}" = docker ] || return 0
      j=$((i + 2)); w=''; b=''
      while [ "$j" -lt "$n" ]; do case "${SP[$j]}" in clean|prepare) w="${SP[$j]}" ;; -*) return 0 ;; *) b="${SP[$j]}" ;; esac; j=$((j + 1)); done
      [ -z "$b" ] || [ "$b" = "$DG_P" ] || return 0
      case "$w" in clean) DG_CLEANED=1 ;; prepare) DG_PREPARED=1 ;; esac
      return 0 ;;
    docker|docker-compose) ;;
    *) return 0 ;;
  esac
  [ "$forced" = 0 ] && [ "${LAB_FORCE:-0}" != 1 ] || return 0
  j=$((i + 1))
  if [ "$BASE" = docker-compose ]; then sub=compose
  else
    while [ "$j" -lt "$n" ]; do
      case "${SP[$j]}" in
        -H|--host|-c|--context|--config|-l|--log-level|--tlscacert|--tlscert|--tlskey) j=$((j + 2)) ;;
        -*) j=$((j + 1)) ;; *) break ;;
      esac
    done
    [ "$j" -lt "$n" ] || return 0
    sub="${SP[$j]}"; ins="$j"; j=$((j + 1))
  fi
  scan="$j"
  case "$sub" in
    run|create) cls=run ;;
    build) cls=build ;;
    pull) cls=room ;;
    container|image|buildx|builder|system|volume|compose)
      while [ "$j" -lt "$n" ]; do
        case "${SP[$j]}" in
          --builder|-f|--file|-p|--project-name|--profile|--env-file|--project-directory|--ansi|--progress|--parallel) j=$((j + 2)) ;;
          -*) j=$((j + 1)) ;; *) break ;;
        esac
      done
      [ "$j" -lt "$n" ] || return 0
      sub2="${SP[$j]}"; ins="$j"; j=$((j + 1))
      case "$sub:$sub2" in
        container:run|container:create|compose:run) cls=run ;;
        image:build|buildx:build|buildx:b|builder:build) cls=build ;;
        image:pull|compose:up) cls=room ;;
        container:prune|image:prune|system:prune|volume:prune) cls=prune ;;
        builder:prune|buildx:prune) cls=bprune ;;
        *) return 0 ;;
      esac ;;
    *) return 0 ;;
  esac
  S_OKP=0 S_OKL=0 S_ADD='' S_CHANGED=0 S_BBAD=0
  b="lab-$DG_P"; valid_slug "$DG_P" || b="$(docker_builder "$DG_P")"
  case "$cls" in
    run)   # options jusqu'au premier mot qui n'en est pas une (l'image, le service) : la suite est au conteneur
      k="$j"
      while [ "$k" -lt "$n" ]; do
        w="${SP[$k]}"
        case "$w" in
          --) break ;;
          --rm) rm=1 ;;
          --rm=*)   # Docker garde la dernière valeur : --rm=false après --rm laisserait le conteneur, retiré de la ligne
            case "${SOK[$k]}:${w#--rm=}" in
              1:1|1:t|1:T|1:true|1:TRUE|1:True) rm=1 ;;
              *) docker_drop "${SW[$k]}" "${SW[$k]}"; S_CHANGED=1; docker_shown "${DT_TEXT[${SW[$k]}]}"; docker_why "$DS keeps the container after it ends" ;;
            esac ;;
          --restart|--restart=*)
            if [ "$w" = --restart ]; then k=$((k + 1)); j="$((k - 1))"; else SP[k]="${w#--restart=}"; j="$k"; fi
            if [ "${SOK[$k]:-0}" = 1 ]; then case "${SP[$k]:-no}" in no|'') ;; *) durable=1 ;; esac
            elif [ "$k" -lt "$n" ]; then   # illisible : retirée, --rm la remplace (ligne en clair, décision 7)
              docker_drop "${SW[$j]}" "${SW[$k]}"; S_CHANGED=1; docker_shown "${DT_TEXT[${SW[$k]}]}"
              docker_why "restart policy $DS cannot be read here (variable or command): written in clear"
            fi ;;
          --label|-l) k=$((k + 1)); [ "$k" -ge "$n" ] || docker_label "$((k - 1))" "$k" ;;
          --label=*) SP[k]="${w#--label=}"; docker_label "$k" "$k" ;;
          -l?*) SP[k]="${w#-l}"; SP[k]="${SP[$k]#=}"; docker_label "$k" "$k" ;;   # -l<valeur>, -l=<valeur>
          --*=*|-?*=*) ;;
          --*) case "$DOCKER_RUN_BOOLS" in *" $w "*) ;; *) k=$((k + 1)) ;; esac ;;
          -[ditPqT]) ;;
          -?) k=$((k + 1)) ;;
          -[ditPqT]*[a-zA-Z])   # groupe de lettres : la dernière prend une valeur (-dp 8080:80, -itv /a:/b), sauf si toutes sont seules
            case "${w#-}" in
              *[!ditPqT]*[a-zA-Z]|*[!a-zA-Z]*) ;;   # une lettre à valeur au milieu, ou une valeur collée : rien de plus à lire
              *[ditPqT]) ;;
              *l) k=$((k + 1)); [ "$k" -ge "$n" ] || docker_label "$((k - 1))" "$k" ;;
              *) k=$((k + 1)) ;;
            esac ;;
          -*) ;;   # valeur collée (-p8080:80)
          *) break ;;
        esac
        k=$((k + 1))
      done
      if [ "$rm" = 0 ] && [ "$durable" = 0 ]; then S_ADD="--rm"; docker_why "the container would stay after it ends (neither --rm nor a --restart policy)"; fi
      docker_labels_needed
      docker_needs_room ;;
    build)   # options et contexte se mêlent : tous les mots après la sous-commande
      k="$scan"
      while [ "$k" -lt "$n" ]; do
        w="${SP[$k]}"
        case "$w" in
          --builder) k=$((k + 1))
            if [ "$k" -lt "$n" ] && docker_value_is "$k" "$b"; then okb=1
            elif [ "$k" -lt "$n" ]; then
              docker_drop "${SW[$((k - 1))]}" "${SW[$k]}"; S_CHANGED=1 S_BBAD=1; docker_shown "${DT_TEXT[${SW[$k]}]}"
              docker_why "builder $DS is not the dedicated builder $b, whose cache stays apart from other projects"
            fi ;;
          --builder=*) SP[k]="${w#--builder=}"
            if docker_value_is "$k" "$b"; then okb=1
            else docker_drop "${SW[$k]}" "${SW[$k]}"; S_CHANGED=1 S_BBAD=1; docker_shown "${DT_TEXT[${SW[$k]}]}"; docker_why "builder ${DS#--builder=} is not the dedicated builder $b, whose cache stays apart from other projects"; fi ;;
          --load|--push|--load=true|--push=true|--output=*|-o?*) out=1 ;;
          --output|-o) out=1; k=$((k + 1)) ;;
          --label) k=$((k + 1)); [ "$k" -ge "$n" ] || docker_label "$((k - 1))" "$k" ;;
          --label=*) SP[k]="${w#--label=}"; docker_label "$k" "$k" ;;
        esac
        k=$((k + 1))
      done
      if [ "$okb" = 0 ]; then
        S_ADD="--builder $b"
        [ "$S_BBAD" = 1 ] || docker_why "it would build with the default builder, whose cache every project shares (the dedicated builder $b keeps it apart)"
      fi
      if [ "$out" = 0 ]; then S_ADD="${S_ADD:+$S_ADD }--load"; docker_why "with builder $b the image would stay in its cache (--load puts it in Docker)"; fi
      docker_labels_needed
      if [ "$DG_PREPARED" = 0 ] && [ ! -e "${DOCKER_CONFIG:-$HOME/.docker}/buildx/instances/$b" ]; then
        DG_PREPARE=1; docker_why "builder $b does not exist yet (lab docker prepare $DG_P creates it)"
      fi
      docker_needs_room ;;
    room) docker_needs_room ;;
    prune|bprune)
      k="$scan"
      while [ "$k" -lt "$n" ]; do
        w="${SP[$k]}"
        case "$cls:$w" in
          prune:--filter) k=$((k + 1)); if [ "$k" -lt "$n" ] && docker_value_is "$k" "label=$DOCKER_LABEL_PROJECT=$DG_P"; then okf=1; fi ;;
          prune:--filter=*) SP[k]="${w#--filter=}"; if docker_value_is "$k" "label=$DOCKER_LABEL_PROJECT=$DG_P"; then okf=1; fi ;;
          bprune:--builder) k=$((k + 1)); if [ "$k" -lt "$n" ] && docker_value_is "$k" "$b"; then okf=1; fi ;;
          bprune:--builder=*) SP[k]="${w#--builder=}"; if docker_value_is "$k" "$b"; then okf=1; fi ;;
        esac
        k=$((k + 1))
      done
      [ "$okf" = 0 ] || return 0
      if [ "$cls" = prune ]; then docker_why "docker $sub $sub2 removes the resources of every project, not only $DG_P's (only --filter label=$DOCKER_LABEL_PROJECT=$DG_P keeps it to $DG_P)"
      else docker_why "docker $sub $sub2 empties the build cache of every project, not only $DG_P's (only --builder $b keeps it to $DG_P)"; fi
      # le segment entier devient lab docker clean <projet>, préfixes compris ; les blancs qui l'entourent restent
      k="${SW[0]}"; while [ "$k" -le "${SW[$((n - 1))]}" ]; do DG_DROP[k]=1; k=$((k + 1)); done
      k="${SW[0]}"; DG_BEFORE[k]="lab docker clean $DG_P"; DG_BAD=1
      return 0 ;;
  esac
  if [ -n "$S_ADD" ]; then DG_AFTER[${SW[$ins]}]=" $S_ADD"; DG_BAD=1; fi
  [ "$S_CHANGED" = 0 ] || DG_BAD=1
}

# docker_subst_set <mot brut> : SUBS, le texte de chaque substitution $(…) et `…` du mot, hors chaîne entre apostrophes et hors
# échappement ; entre guillemets doubles, l'apostrophe est un caractère
docker_subst_set() {
  local s="$1" c rest inner dq=0
  SUBS=()
  while [ -n "$s" ]; do
    c="${s%%[\'\"\\\$\`]*}"; s="${s:${#c}}"
    case "$dq:$s" in
      0:"'"*) rest="${s:1}"; case "$rest" in *"'"*) s="${rest#*"'"}" ;; *) s='' ;; esac ;;
      ?:'"'*) dq=$((1 - dq)); s="${s:1}" ;;
      ?:\\*) s="${s:2}" ;;
      ?:\$\(*) docker_subst_text_set "$s"; s="${s:${#DSUB}}"; inner="${DSUB:2}"; inner="${inner%)}"; SUBS+=("$inner") ;;
      ?:'`'*) rest="${s:1}"; case "$rest" in *'`'*) SUBS+=("${rest%%'`'*}"); s="${rest#*'`'}" ;; *) s='' ;; esac ;;
      ?:?*) s="${s:1}" ;;   # un $ qui n'ouvre pas de substitution, une apostrophe entre guillemets doubles
    esac
  done
}

# docker_guard_command <commande brute> <projet> [couloir] [inner] : rc 0 si elle passe ; sinon DENY_REASON — la raison, puis la ligne
# exacte à lancer (« Run instead: »), sauf quand la place manque encore juste après un nettoyage du projet. inner : une substitution
# jugée pour la commande qui la porte — ni place ni raison écrite, DG_LINE (sa ligne corrigée), DG_WHY, DG_BAD, DG_ROOM, DG_BARE et
# DG_PREPARE pour elle. Une commande trop longue à lire (DOCKER_TOKENS_BUDGET) n'est pas jugée, comme un script ou bash -c
docker_guard_command() {
  local cmd="$1" mode="${4:-}" k nt x line='' prefix='' where ago why bad room bare prep clean_at prep_at rep t head
  local -a piece=() texts=() kinds=() subs=()
  DG_P="$2" DG_LANE="${3:-}" DG_WHY='' DG_BAD=0 DG_ROOM=0 DG_BARE=0 DG_CLEANED=0 DG_PREPARED=0 DG_PREPARE=0 DG_LINE="$1"
  DG_DROP=(); DG_AFTER=(); DG_BEFORE=(); DG_W=()
  docker_tokens "$cmd"; [ "$DT_OVER" = 0 ] || return 0
  nt="${#DT_TEXT[@]}"; clean_at="$nt"; prep_at="$nt"
  k=0
  while [ "$k" -le "$nt" ]; do
    if [ "$k" -eq "$nt" ] || [ "${DT_KIND[$k]}" = o ]; then
      [ "${#DG_W[@]}" = 0 ] || docker_segment
      DG_W=()
      if [ "$DG_CLEANED" = 1 ] && [ "$clean_at" -eq "$nt" ]; then clean_at="$k"; fi
      if [ "$DG_PREPARED" = 1 ] && [ "$prep_at" -eq "$nt" ]; then prep_at="$k"; fi
    elif [ "${DT_KIND[$k]}" = w ]; then DG_W+=("$k"); fi
    k=$((k + 1))
  done
  # morceaux de la ligne corrigée, avant toute substitution jugée : elle réécrit DT_* et DG_*
  k=0
  while [ "$k" -lt "$nt" ]; do
    piece[k]="${DG_BEFORE[$k]:-}"; [ "${DG_DROP[$k]:-0}" = 1 ] || piece[k]="${piece[$k]}${DT_TEXT[$k]}"; piece[k]="${piece[$k]}${DG_AFTER[$k]:-}"
    k=$((k + 1))
  done
  # substitutions $(…) et `…` qui portent docker : jugées comme des commandes, chacune à sa place dans la ligne
  case "$cmd" in
    *\$\(*|*\`*)   # jamais *$(*docker* sur la commande entière : quadratique quand docker n'y suit aucun $(
      texts=("${DT_TEXT[@]}"); kinds=("${DT_KIND[@]}")
      why="$DG_WHY" bad="$DG_BAD" room="$DG_ROOM" bare="$DG_BARE" prep="$DG_PREPARE"
      k=0
      while [ "$k" -lt "$nt" ]; do
        case "${kinds[$k]}:${texts[$k]}" in
          w:*\$\(*docker*|w:*\`*docker*)
            docker_subst_set "${texts[$k]}"; subs=("${SUBS[@]+"${SUBS[@]}"}")
            head='' t="${piece[$k]}"   # chaque substitution corrigée à sa place, dans l'ordre ; absente du morceau (mot retiré) : rien
            for x in "${subs[@]+"${subs[@]}"}"; do
              case "$x" in *docker*) ;; *) continue ;; esac
              docker_guard_command "$x" "$2" "${3:-}" inner || true
              room=$((room + DG_ROOM))
              [ "$k" -gt "$clean_at" ] || bare=$((bare + DG_BARE))
              if [ "$DG_PREPARE" = 1 ] && [ "$k" -lt "$prep_at" ]; then prep=1; fi
              rep="$x"
              if [ "$DG_BAD" = 1 ]; then bad=1; why="${why:+$why; }$DG_WHY"; rep="$DG_LINE"; fi
              case "$t" in *"$x"*) head="$head${t%%"$x"*}$rep"; t="${t#*"$x"}" ;; esac
            done
            piece[k]="$head$t" ;;
        esac
        k=$((k + 1))
      done
      DG_P="$2" DG_LANE="${3:-}" DG_WHY="$why" DG_BAD="$bad" DG_ROOM="$room" DG_BARE="$bare" DG_PREPARE="$prep" ;;
  esac
  k=0; while [ "$k" -lt "$nt" ]; do line="$line${piece[$k]}"; k=$((k + 1)); done
  if [ "$mode" = inner ]; then DG_LINE="$line"; return 0; fi
  # place : une commande qui crée ; lue même après lab docker clean du projet, pour dire qu'un nettoyage récent n'a pas suffi
  if [ "$DG_ROOM" -gt 0 ]; then
    docker_room_guard "$DG_P"
    if [ "$ROOM" = short ]; then
      if [ -n "$DOCKER_CLEANED" ] && [ "$((DOCKER_NOW - DOCKER_CLEANED))" -ge 0 ] && [ "$((DOCKER_NOW - DOCKER_CLEANED))" -lt "$DOCKER_CLEAN_RECENT" ]; then
        ago="$(((DOCKER_NOW - DOCKER_CLEANED) / 60))"
        DENY_REASON="Docker is still short of room ($FREE_GB GB free, $USED_PCT% used; needs at least $DOCKER_MIN_FREE_GB GB free and under $DOCKER_MAX_USED_PCT% used) after lab docker clean $DG_P $ago min ago: the rest is not $DG_P's. lab docker $DG_P shows what remains; free room by hand (another project's leftovers, unlabeled resources) or enlarge the Docker disk."
        return 1
      fi
      if [ "$DG_BARE" -gt 0 ]; then
        prefix="lab docker clean $DG_P && "
        docker_why "Docker is short of room: $FREE_GB GB free, $USED_PCT% used (needs at least $DOCKER_MIN_FREE_GB GB free and under $DOCKER_MAX_USED_PCT% used); lab docker clean $DG_P removes $DG_P's leftovers first"
      fi
    fi
  fi
  [ "$DG_BAD" = 1 ] || [ "$DG_PREPARE" = 1 ] || [ -n "$prefix" ] || return 0
  [ "$DG_PREPARE" = 0 ] || prefix="${prefix}lab docker prepare $DG_P && "
  if [ -n "$DG_LANE" ]; then where="$DG_P (lane $DG_LANE)"; else where="$DG_P (main checkout)"; fi
  # shellcheck disable=SC2034 # lu par hook_guard_bash_payload (lib/hooks.sh)
  DENY_REASON="Docker command refused in $where: $DG_WHY."$'\n'"Run instead:"$'\n'"$prefix$line"
  return 1
}
# guard_docker <commande brute> : la garde Docker depuis le dossier de la session (HOOK_CWD) ; hors projet enregistré, rien n'est
# jugé ni lancé. rc 0 si elle passe ; sinon DENY_REASON, rc 1
guard_docker() {
  local lane=''
  project_from_cwd_set "$HOOK_CWD" 2>/dev/null && [ -n "$FOUND_PROJECT" ] || return 0
  if ! same_path "$GP_TOP" "$GP_MAIN"; then wt_lane_set "$GP_TOP"; lane="$WT_LANE"; fi
  docker_guard_command "$1" "$FOUND_PROJECT" "$lane"
}

# cmd_docker [clean|prepare] [projet] : le verbe et le projet dans n'importe quel ordre ; sans projet, celui du dossier courant
cmd_docker() {
  local verb="" p="" a
  for a in "$@"; do
    case "$a" in
      clean|prepare) [ -z "$verb" ] || usage; verb="$a" ;;
      -*) usage ;;
      *) [ -z "$p" ] || usage; p="$a" ;;
    esac
  done
  p="$(resolve_project "$p")"; load_project "$p"
  case "$verb" in
    '') docker_show "$p" ;;
    clean) docker_clean "$p" ;;
    prepare) docker_prepare "$p" ;;
  esac
}
