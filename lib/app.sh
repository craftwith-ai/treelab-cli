# shellcheck shell=bash
# app.sh — lab app : ce que Treelab.app lit et fait faire à lab (lot 01 d'app-treelab). L'app affiche, lab décide : ce qu'attend
# chaque couloir (tower_waits_for, la vue de la tour), ce qui est l'affaire de l'utilisateur (tower_yours), et les chemins dont un
# changement peut changer cette réponse. L'app s'abonne à ces chemins (FSEvents) et ne relance lab que sur l'un d'eux, jamais par
# minuterie ; elle relit le seul couloir touché, ou le projet quand un couloir s'ouvre ou part. Lecture seule : sans réseau, sans tour
# créée, sans fichier écrit (GIT_OPTIONAL_LOCKS=0 : git status ne réécrit pas l'index). Une lecture coûte surtout par couloir (vue de
# la tour : 0,4 s pour dix couloirs, 7 s pour 47, mesuré le 2026-11-24) : d'où la relecture d'un seul couloir.

# app_lang → en | fr : la langue des textes de l'app, celle que lab annonce à l'agent (lab_lang_detect) ; toute autre langue : en
app_lang() { case "$(lab_lang_detect)" in fr) echo fr ;; *) echo en ;; esac; }

# app_lane_kv <wt> : le bloc d'un couloir hors tour du projet chargé, avec ses chemins — WATCH : un fichier ou un dossier dont un
# changement peut changer sa réponse ; WATCH_ENTRIES : un dossier dont seules les entrées comptent (une fiche de lot neuve), jamais
# le contenu (les preuves). APP_YOURS : 1 s'il attend l'utilisateur
# shellcheck disable=SC2153 # LAB_STATE et LAB_PROJECTS sont posés par lib/project.sh
app_lane_kv() {
  local wt="$1" lane batch f
  wt_lane_set "$wt"; lane="$WT_LANE"
  tower_waits_for "$wt"
  wt_lot_set "$wt"; batch=""; LOT_STATE=""
  if [ -n "$WT_LOT" ]; then batch="${WT_LOT##*/}"; batch="${batch%.md}"; lot_state_set "$WT_LOT"; fi
  # LANE : le dossier sous .worktrees, le nom que lab app lanes <projet> <couloir> et lab app focus reçoivent (la méta d'un
  # ancien couloir peut porter un autre nom : il nomme encore ses fiches et son état, revue du lot 01)
  kv PROJECT "$P_NAME"; kv LANE "${wt##*/}"; kv WAITS_FOR "$TW_WAITS"; kv WHY "$TW_WHY"; kv SESSION "$TW_SESSION"
  kv BATCH "$batch"; kv BATCH_STATE "$LOT_STATE"
  if tower_yours; then kv FOR_YOU yes; APP_YOURS=1; else kv FOR_YOU no; APP_YOURS=0; fi
  docs_dir_set "$wt"
  # verrou de session, attente et réglages du couloir ; ses fiches et son treeplan ; ce que la vue lit sous l'état du projet
  # dans .lab, les seuls fichiers que tower_waits_for lit (verrou de session, attente déclarée, accord) : jamais le dossier, où la
  # transcription et les fichiers temporaires d'une session active changent sans cesse (8 relectures en 72 s, vrai Mac 2026-11-24)
  for f in session.lock waits-for meta; do kv WATCH "$wt/.lab/$f"; done
  for f in "$DOCS_DIR/lots/$lane"/lot-[0-9]*.md; do [ ! -f "$f" ] || kv WATCH "$f"; done
  kv WATCH "$DOCS_DIR/treeplans/$lane.md"
  kv WATCH "$LAB_STATE/$P_NAME/merge-queue/$lane"; kv WATCH "$LAB_STATE/$P_NAME/agreements/$lane"
  kv WATCH "$LAB_STATE/$P_NAME/words/$lane"; kv WATCH "$LAB_STATE/watch/$P_NAME/$lane"
  app_entries "$DOCS_DIR/lots/$lane"
  app_lane_unseen "$wt" "$lane"
  sep
}

# app_lane_unseen <wt> <couloir de .lab/meta> : ce qu'aucun fichier ne dit (lot 03). WATCH_PID : un processus dont la fin change la
# réponse (session vivante, veilleur armé ou en attente) ; WAKE_AT : la première date (epoch) où elle peut changer sans qu'un fichier
# bouge (critère garé, mots de l'utilisateur qui expirent). En recette, la tête git du couloir est guettée comme un document (un commit
# change la révision des mots et les fichiers touchés). WRITTEN : les chemins de WATCH que les points d'écriture de lab tiennent eux-
# mêmes à jour dans l'instantané (lib/snapshot.sh) — l'app qui lit l'instantané ne les guette pas.
app_lane_unseen() {
  local wt="$1" lane="$2" f wake='' e
  if [ "$TW_SESSION" = live ] && kv_value "$wt/.lab/session.lock" pid; then kv WATCH_PID "$KV_VALUE"; fi
  for f in "$LAB_STATE/watch/$P_NAME/$lane"/*; do
    [ -f "$f" ] || continue; case "$f" in *.log|*.records|*.body|*.tmp.*) continue ;; esac
    watch_state_set "$f"
    case "$WATCH_STATE" in armed|waiting) if kv_value "$f" pid; then kv WATCH_PID "$KV_VALUE"; fi ;; esac
  done
  if [ "$LANE_PHASE" = waiting ]; then wait_first_set "$wt"; wake="${WAIT_FIRST%%$'\t'*}"; fi
  if [ "$TW_EVIDENCE" = words ] && e="$(rdv_epoch "$WD_AT" 2>/dev/null)"; then
    e=$((e + $(words_ttl) + 1)); if [ -z "$wake" ] || [ "$e" -lt "$wake" ]; then wake="$e"; fi
  fi
  case "$wake" in ''|*[!0-9]*) ;; *) kv WAKE_AT "$wake" ;; esac
  case "$LANE_PHASE" in 'in acceptance'|'acceptance passed') app_head_watch "$wt" ;; esac
  kv WRITTEN "$wt/.lab/session.lock"; kv WRITTEN "$wt/.lab/waits-for"
  kv WRITTEN "$LAB_STATE/$P_NAME/merge-queue/$lane"; kv WRITTEN "$LAB_STATE/$P_NAME/agreements/$lane"
  kv WRITTEN "$LAB_STATE/$P_NAME/words/$lane"; kv WRITTEN "$LAB_STATE/watch/$P_NAME/$lane"
}

# app_head_watch <wt> : WATCH du HEAD du couloir et de la référence de sa branche, lus sans git (fichier .git, commondir)
app_head_watch() {
  local wt="$1" line='' g='' c='' rel
  if [ -d "$wt/.git" ]; then g="$wt/.git"
  elif [ -f "$wt/.git" ]; then
    { IFS= read -r line <"$wt/.git"; } 2>/dev/null || true
    case "$line" in 'gitdir: /'*) g="${line#gitdir: }" ;; 'gitdir: '?*) g="$wt/${line#gitdir: }" ;; esac
  fi
  [ -n "$g" ] || return 0
  kv WATCH "$g/HEAD"
  c="$g"
  if { IFS= read -r rel <"$g/commondir"; } 2>/dev/null && [ -n "$rel" ]; then
    case "$rel" in
      /*) c="$rel" ;;
      *) while :; do case "$rel" in ..) c="${c%/*}"; rel='' ;; ../*) c="${c%/*}"; rel="${rel#../}" ;; *) break ;; esac; done
         [ -z "$rel" ] || c="$c/$rel" ;;
    esac
  fi
  head_branch_set "$wt"
  [ -z "$HEAD_BRANCH" ] || kv WATCH "${c%/}/refs/heads/$HEAD_BRANCH"
}

app_listed() { local x="$1" y; shift; for y in "$@"; do [ "$y" != "$x" ] || return 0; done; return 1; }   # <nom> <liste…>

# app_entries <dossier> : WATCH_ENTRIES du dossier, ou de son parent existant le plus proche s'il manque encore (.worktrees avant
# le premier lab new, le registre avant le premier projet) : sa création change les entrées du parent, l'app relit et surveille
# alors le dossier lui-même (revue du lot 01)
app_entries() {
  local d="${1%/}"
  while [ -n "$d" ] && [ ! -d "$d" ]; do d="${d%/*}"; done
  kv WATCH_ENTRIES "${d:-/}"
}

# app_project_kv [couloir…] : les couloirs hors tour du projet chargé, puis le bloc du projet (PROJECT, ROOT, LANES, WAITING, ses
# chemins : config, marque de la tour, entrées de .worktrees) ; avec des couloirs, leurs seuls blocs. APP_WAITING : le nombre lu
# qui attend l'utilisateur
app_project_kv() {
  local wt n=0 one=""
  APP_WAITING=0
  [ "$#" != 1 ] || one="$1"
  reads_open local "$one"
  for wt in "$P_ROOT"/.worktrees/*/; do
    [ -d "$wt" ] || continue; wt="${wt%/}"
    [ "$#" = 0 ] || app_listed "${wt##*/}" "$@" || continue
    ! lane_is_tower "$wt" || continue
    n=$((n + 1)); app_lane_kv "$wt"; APP_WAITING=$((APP_WAITING + APP_YOURS))
  done
  reads_close
  [ "$#" = 0 ] || return 0
  kv PROJECT "$P_NAME"; kv ROOT "$P_ROOT"; kv LANES "$n"; kv WAITING "$APP_WAITING"
  # lot 02 : l'app de terminal pilotée pour ce projet et d'où vient ce choix (project|global|cmux|fork|none) ; une ligne qui nomme une
  # app absente est dite sur stderr (fichier et clé)
  terminal_resolve; terminal_warn
  if [ -n "$TA_APP" ]; then kv TERMINAL_APP "$TA_APP"
  else kv TERMINAL_APP "${TA_BUNDLE:-$TA_CMDPATH}"; fi
  kv TERMINAL_SOURCE "$TA_SOURCE"
  case "$TA_SOURCE" in project|global|fork) [ "$TA_OK" != 1 ] || log_wrap "$P_NAME: lanes open in $TA_APP ($TA_SOURCE)." ;; esac
  # acceptance_check= de la config décide si une recette attend l'utilisateur ; la marque de la tour, quel couloir est la tour
  kv WATCH "$LAB_PROJECTS/$P_NAME/config"; kv WATCH "$LAB_STATE/$P_NAME/tower"
  app_entries "$P_ROOT/.worktrees"
  sep
}

# lab app lanes [projet [couloir…]] : tous les projets inscrits, ce seul projet, ou ces seuls couloirs (l'app relit ce qu'un
# changement a touché, en un lancement) ; puis WAITING_FOR_YOU (le nombre lu qui attend l'utilisateur), LANG, IGNORE (motifs de
# noms de fichiers dont un changement ne compte jamais : journaux et fichiers temporaires des veilleurs) et, pour la lecture de tous,
# les entrées du registre (projet inscrit ou retiré). Un projet illisible (checkout absent) est sauté dans la lecture de tous, nommé
# sur stderr ; un couloir inconnu, retiré ou la tour : refus nommé (l'app relit alors le projet)
app_lanes() {
  local p total=0 names="" d found lane all=0; local -a ps=() lanes=()
  export GIT_OPTIONAL_LOCKS=0
  if [ "$#" -ge 1 ]; then
    project_exists "$1" || die "unknown project: $1 — lab app lanes lists the registered projects"
    ps=("$1"); shift; lanes=("$@")
  else
    all=1
    while IFS= read -r p; do [ -z "$p" ] || ps+=("$p"); done < <(project_names)
  fi
  if [ "${#lanes[@]}" -gt 0 ]; then
    load_project "${ps[0]}"
    for lane in "${lanes[@]}"; do
      found=0
      case "$lane" in ''|.*|*/*) ;; *) for d in "$P_ROOT/.worktrees"/*; do [ "${d##*/}" != "$lane" ] || found=1; done ;; esac
      if [ "$found" != 1 ] || [ ! -d "$P_ROOT/.worktrees/$lane/.lab" ] || lane_is_tower "$P_ROOT/.worktrees/$lane"; then
        die "no lane $lane in ${ps[0]} — lab app lanes ${ps[0]} lists its lanes"
      fi
    done
  fi
  for p in "${ps[@]+"${ps[@]}"}"; do
    if [ "$all" = 1 ] && [ ! -d "$(config_get "$p" root)" ]; then warn "project $p skipped: main checkout not found"; continue; fi
    load_project "$p"; app_project_kv "${lanes[@]+"${lanes[@]}"}"
    total=$((total + APP_WAITING)); [ "$APP_WAITING" = 0 ] || names="${names:+$names, }$p ($APP_WAITING)"
  done
  kv WAITING_FOR_YOU "$total"; kv LANG "$(app_lang)"
  terminal_found_set
  while IFS= read -r d; do [ -z "$d" ] || kv TERMINAL_FOUND "$d"; done <<<"$TERMINAL_FOUND"
  [ "$all" = 0 ] || app_entries "$LAB_PROJECTS"
  kv IGNORE '*.log'; kv IGNORE '*.records'; kv IGNORE '*.body'; kv IGNORE '*.tmp.*'; kv IGNORE '.DS_Store'
  if [ "$total" = 0 ]; then log_wrap "Nothing waits for you."; else log_wrap "Waiting for you: $names."; fi
}

# ---------- instantané (lot 03 d'app-treelab) ----------
# Sous $LAB_STATE/app-snapshot (SNAP_DIR, lib/snapshot.sh) : projects/<projet>/lanes/<couloir>, le bloc de lab app lanes <projet>
# <couloir> ; projects/<projet>/project, le bloc du projet de lab app lanes <projet> ; total, le dernier bloc de lab app lanes ; version, la version du lab
# qui l'a écrit en entier (un autre lab le réécrit en entier) ; reader, le pid du lecteur ; pending et lock, la file et le verrou de
# l'écrivain ; measure, s'il existe, le journal de mesure (une ligne par écrivain : sorte, processeur en ms, fichiers écrits). Un
# fichier n'est réécrit (mv atomique) que si son contenu change : même inode et même date sinon. LANES, WAITING et WAITING_FOR_YOU
# suivent les couloirs réécrits : les mêmes comptes que lab app lanes, sur les fichiers des couloirs.
APP_SNAP_WROTE=0 APP_SNAP_SAME=0 APP_SNAP_GONE=0 APP_SNAP_KEPT=$'\n'

# app_snap_put <fichier> <contenu> : écrit seulement si le contenu diffère
app_snap_put() {
  local f="$1" old=''
  APP_SNAP_KEPT="$APP_SNAP_KEPT$f"$'\n'
  { IFS= read -r -d '' old <"$f"; } 2>/dev/null || true
  if [ -f "$f" ] && [ "$old" = "$2" ]; then APP_SNAP_SAME=$((APP_SNAP_SAME + 1)); return 0; fi
  [ -d "${f%/*}" ] || mkdir -p "${f%/*}"
  printf '%s' "$2" >"${f%/*}/.${f##*/}.tmp.$$" && mv -f "${f%/*}/.${f##*/}.tmp.$$" "$f"   # caché : l'app ne le lit jamais
  APP_SNAP_WROTE=$((APP_SNAP_WROTE + 1))
}
app_snap_drop() { [ -e "$1" ] || [ -L "$1" ] || return 0; rm -f "$1"; APP_SNAP_GONE=$((APP_SNAP_GONE + 1)); }
app_snap_name_ok() { case "$1" in ''|.*|*/*|*$'\n'*) return 1 ;; esac; }

# app_snap_set <fichier> <clé> <valeur> [<clé> <valeur>…] : ces lignes remplacées, le reste intact ; fichier absent : rien
app_snap_set() {
  local f="$1" c='' out='' line i; shift
  local -a kvs=("$@")
  [ -f "$f" ] || return 0
  { IFS= read -r -d '' c <"$f"; } 2>/dev/null || true
  while [ -n "$c" ]; do
    case "$c" in *$'\n'*) line="${c%%$'\n'*}"; c="${c#*$'\n'}" ;; *) line="$c"; c='' ;; esac
    for ((i = 0; i + 1 < ${#kvs[@]}; i += 2)); do
      case "$line" in "${kvs[$i]}="*) line="${kvs[$i]}=${kvs[$((i + 1))]}" ;; esac
    done
    out="$out$line"$'\n'
  done
  app_snap_put "$f" "$out"
}

# app_snap_counts <projet> : LANES et WAITING de son fichier sur les fichiers de ses couloirs, puis WAITING_FOR_YOU du total
app_snap_counts() {
  local f c n=0 w=0 t=0
  for f in "$SNAP_DIR/projects/$1/lanes"/*; do
    [ -f "$f" ] || continue; n=$((n + 1)); c=''
    { IFS= read -r -d '' c <"$f"; } 2>/dev/null || true
    case "$c" in *$'\n'FOR_YOU=yes$'\n'*) w=$((w + 1)) ;; esac
  done
  app_snap_set "$SNAP_DIR/projects/$1/project" LANES "$n" WAITING "$w"
  for f in "$SNAP_DIR"/projects/*/project; do
    [ -f "$f" ] || continue; c=''
    { IFS= read -r -d '' c <"$f"; } 2>/dev/null || true
    case "$c" in *$'\n'WAITING=*) c="${c#*$'\n'WAITING=}"; c="${c%%$'\n'*}" ;; *) c='' ;; esac
    case "$c" in ''|*[!0-9]*) ;; *) t=$((t + c)) ;; esac
  done
  app_snap_set "$SNAP_DIR/total" WAITING_FOR_YOU "$t"
}

# app_snap_lane <wt> : le fichier du couloir du projet chargé — retiré si le couloir est parti ou s'il est la tour
app_snap_lane() {
  local wt="$1" f
  app_snap_name_ok "${wt##*/}" || return 0
  f="$SNAP_DIR/projects/$P_NAME/lanes/${wt##*/}"
  if [ ! -d "$wt" ] || lane_is_tower "$wt"; then app_snap_drop "$f"; rm -f "$SNAP_DIR/.acceptance/$P_NAME/${wt##*/}"; return 0; fi
  app_snap_put "$f" "$(app_lane_kv "$wt")"$'\n'
}

# app_snap_blocks <fichier de sortie de lab app lanes> [total] : chaque bloc rangé dans son fichier (couloir, projet ; le total
# seulement avec « total », la lecture de tous)
app_snap_blocks() {
  local line block='' with_total="${2:-}"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$line" ]; then block="$block$line"$'\n'; continue; fi
    app_snap_block "$block" "$with_total"; block=''
  done <"$1"
  app_snap_block "$block" "$with_total"
}
app_snap_block() {
  local b="$1" p l
  case "$b" in
    PROJECT=*)
      p="${b#PROJECT=}"; p="${p%%$'\n'*}"; app_snap_name_ok "$p" || return 0
      case "$b" in
        *$'\n'LANE=*) l="${b#*$'\n'LANE=}"; l="${l%%$'\n'*}"; app_snap_name_ok "$l" || return 0
          app_snap_put "$SNAP_DIR/projects/$p/lanes/$l" "$b" ;;
        *$'\n'ROOT=*) app_snap_put "$SNAP_DIR/projects/$p/project" "$b" ;;
      esac ;;
    *WAITING_FOR_YOU=*) [ -z "$2" ] || app_snap_put "$SNAP_DIR/total" "$b" ;;
  esac
}

# app_snap_lock : rc 0 quand ce processus tient le verrou de l'écrivain ; un verrou dont le pid est mort est repris
app_snap_lock() {
  local pid n got
  for n in 1 2; do
    set -C
    if { printf '%s\n' "$$" >"$SNAP_DIR/lock"; } 2>/dev/null; then set +C; return 0; fi
    set +C
    pid=''; { IFS= read -r pid <"$SNAP_DIR/lock"; } 2>/dev/null || true
    [ -n "$pid" ] || return 1                     # en train d'être posé : son écrivain est vivant
    ! snap_pid_alive "$pid" || return 1            # tenu : son écrivain relira pending avant de le rendre
    [ "$n" = 1 ] || return 1
    # reprise d'un verrou mort, déplacé sous un nom à soi puis relu : un verrou neuf pris entre la lecture et le déplacement est
    # remis en place, jamais retiré (deux écrivains ensemble ; revue du lot 03)
    mv -f "$SNAP_DIR/lock" "$SNAP_DIR/.lock.$$" 2>/dev/null || continue
    got=''; { IFS= read -r got <"$SNAP_DIR/.lock.$$"; } 2>/dev/null || true
    if [ "$got" != "$pid" ]; then mv -n "$SNAP_DIR/.lock.$$" "$SNAP_DIR/lock" 2>/dev/null || true; rm -f "$SNAP_DIR/.lock.$$"; return 1; fi
    rm -f "$SNAP_DIR/.lock.$$"
  done
  return 1
}
# app_snap_lock_wait : le verrou, en attendant jusqu'à 5 s un écrivain vivant (demande de l'app) ; rc 1 au-delà
app_snap_lock_wait() {
  local n=0
  until app_snap_lock; do n=$((n + 1)); [ "$n" -lt 50 ] || return 1; sleep 0.1; done
}
# app_snap_unlock : rendu par son seul titulaire (revue du lot 03)
app_snap_unlock() { local pid=''; { IFS= read -r pid <"$SNAP_DIR/lock"; } 2>/dev/null || return 0; [ "$pid" != "$$" ] || rm -f "$SNAP_DIR/lock"; }

app_snap_version() { local v=''; { IFS= read -r v <"$LAB_ROOT/VERSION"; } 2>/dev/null || true; printf '%s\n' "${v:-unknown}"; }
app_snap_current() { local v=''; { IFS= read -r v <"$SNAP_DIR/version"; } 2>/dev/null || true; [ -n "$v" ] && [ "$v" = "$(app_snap_version)" ]; }

# app_snap_full : tout réécrit depuis lab app lanes ; les fichiers d'un couloir ou d'un projet absents de la lecture retirés
app_snap_full() {
  local f out="$SNAP_DIR/.full.work"
  app_lanes >"$out" 2>/dev/null
  app_snap_blocks "$out" total
  for f in "$SNAP_DIR"/projects/*/lanes/* "$SNAP_DIR"/projects/*/project; do
    [ -f "$f" ] || continue
    case "$APP_SNAP_KEPT" in *$'\n'"$f"$'\n'*) ;; *) app_snap_drop "$f" ;; esac
  done
  for f in "$SNAP_DIR"/projects/*/lanes "$SNAP_DIR"/projects/*/; do rmdir "${f%/}" 2>/dev/null || true; done
  app_snap_put "$SNAP_DIR/version" "$(app_snap_version)"$'\n'
}

# app_snap_project <projet> : ses couloirs et son bloc depuis lab app lanes <projet> ; projet retiré ou illisible : ses fichiers partent
app_snap_project() {
  local p="$1" f out="$SNAP_DIR/.project.work"
  app_snap_name_ok "$p" || return 0
  if project_exists "$p" && [ -d "$(config_get "$p" root)" ]; then
    app_lanes "$p" >"$out" 2>/dev/null
    app_snap_blocks "$out"
  fi
  for f in "$SNAP_DIR/projects/$p"/lanes/* "$SNAP_DIR/projects/$p/project"; do
    [ -f "$f" ] || continue
    case "$APP_SNAP_KEPT" in *$'\n'"$f"$'\n'*) ;; *) app_snap_drop "$f" ;; esac
  done
  rmdir "$SNAP_DIR/projects/$p/lanes" "$SNAP_DIR/projects/$p" 2>/dev/null || true
  app_snap_counts "$p"
}

# app_snap_work <fichier pending> : chaque couloir noté (W <dossier>, L <projet> <couloir de .lab/meta>) réécrit une fois, projet par
# projet, puis ses comptes
app_snap_work() {
  local line kind a b root p wt d seen=$'\n' projs=$'\n' rest; local -a items=()
  while IFS= read -r line || [ -n "$line" ]; do
    kind="${line%%$'\t'*}"; rest="${line#*$'\t'}"; a="${rest%%$'\t'*}"; b="${rest#*$'\t'}"
    p=''; wt=''
    case "$kind" in
      W) root="${a%/.worktrees/*}"; [ "$root" != "$a" ] || continue
         project_by_root_set "$root" || continue; p="$FOUND_PROJECT"; wt="$a"
         # le chemin du crochet garde la casse tapée (cd -P) : le dossier du couloir tel que le disque le nomme, sous la racine du
         # registre, pour des WATCH égaux à ceux de lab app lanes (revue du lot 03)
         if kv_value "$LAB_PROJECTS/$p/config" root; then
           for d in "$KV_VALUE"/.worktrees/*/; do d="${d%/}"; if [ "$d" -ef "$a" ]; then wt="$d"; break; fi; done
         fi ;;
      L) if ! app_snap_name_ok "$a" || ! app_snap_name_ok "$b" || ! project_exists "$a"; then continue; fi
         p="$a"; kv_value "$LAB_PROJECTS/$p/config" root || continue; root="$KV_VALUE"
         wt="$root/.worktrees/$b"; wt_lane_set "$wt"
         if [ ! -d "$wt" ] || [ "$WT_LANE" != "$b" ]; then
           wt=''; for d in "$root"/.worktrees/*/; do d="${d%/}"; wt_lane_set "$d"; [ "$WT_LANE" != "$b" ] || { wt="$d"; break; }; done
           [ -n "$wt" ] || wt="$root/.worktrees/$b"
         fi ;;
      *) continue ;;
    esac
    case "$seen" in *$'\n'"$p"$'\t'"$wt"$'\n'*) continue ;; esac
    seen="$seen$p"$'\t'"$wt"$'\n'; items+=("$p"$'\t'"$wt")
    case "$projs" in *$'\n'"$p"$'\n'*) ;; *) projs="$projs$p"$'\n' ;; esac
  done <"$1"
  projs="${projs#$'\n'}"
  while [ -n "$projs" ]; do
    p="${projs%%$'\n'*}"; projs="${projs#*$'\n'}"
    project_exists "$p" && [ -d "$(config_get "$p" root)" ] || continue
    load_project "$p"
    for line in "${items[@]+"${items[@]}"}"; do [ "${line%%$'\t'*}" != "$p" ] || app_snap_lane "${line#*$'\t'}"; done
    app_snap_counts "$p"
  done
}

# app_snap_measure <sorte> : une ligne au journal de mesure, s'il existe — le processeur de ce processus et de ses enfants (times,
# lu dans ce processus : un sous-shell compterait le sien)
app_snap_measure() {
  [ -f "$SNAP_DIR/measure" ] || return 0
  local a='' b='' c='' d='' x m s f ms=0
  times >"$SNAP_DIR/.measure.times" 2>/dev/null || return 0
  { read -r a b; read -r c d; } <"$SNAP_DIR/.measure.times" 2>/dev/null || true
  for x in "$a" "$b" "$c" "$d"; do
    case "$x" in *m*s) ;; *) continue ;; esac
    m="${x%%m*}"; s="${x#*m}"; s="${s%s}"; s="${s/,/.}"
    case "$s" in *.*) f="${s#*.}000" ;; *) f=000 ;; esac
    ms=$((ms + 10#$m * 60000 + 10#${s%%.*} * 1000 + 10#${f:0:3}))
  done
  printf '%s\t%s\t%s\t%s\n' "$1" "$ms" "$APP_SNAP_WROTE" "$APP_SNAP_GONE" >>"$SNAP_DIR/measure" 2>/dev/null || true
}

# app_snap_pending : l'écrivain lancé par un point d'écriture — sans lecteur vivant rien ; sous le verrou, pending vidé couloir par
# couloir jusqu'à ce qu'il reste vide ; un instantané d'une autre version : tout réécrit (lab complet)
# Revue du lot 03 : une ligne au journal de mesure à chaque sortie (un écrivain sans verrou coûte aussi) ; les notes d'un écrivain mort
# entre son déplacement et sa relecture (.pending.work non vide) sont reprises d'abord ; pending impossible à déplacer : il rend la main
app_snap_pending() {
  snap_reader || { app_snap_measure pending; return 0; }
  if ! app_snap_current; then
    [ "${APP_SNAP_FULL_LAB:-0}" = 1 ] || LAB_SNAP_FULL=1 exec "$LAB_ROOT/bin/lab" app snapshot --pending
    app_snap_lock || { app_snap_measure pending; return 0; }
    rm -f "$SNAP_DIR/pending"; : >"$SNAP_DIR/.pending.work"; app_snap_full; app_snap_unlock
  fi
  while :; do
    app_snap_lock || break
    [ ! -s "$SNAP_DIR/.pending.work" ] || { app_snap_work "$SNAP_DIR/.pending.work"; : >"$SNAP_DIR/.pending.work"; }
    while [ -s "$SNAP_DIR/pending" ]; do
      mv -f "$SNAP_DIR/pending" "$SNAP_DIR/.pending.work" 2>/dev/null || { app_snap_unlock; app_snap_measure pending; return 0; }
      app_snap_work "$SNAP_DIR/.pending.work"; : >"$SNAP_DIR/.pending.work"
    done
    app_snap_unlock
    [ -s "$SNAP_DIR/pending" ] || break
  done
  app_snap_measure pending
}

# lab app snapshot [--reader <pid>] [projet [couloir…]] : l'instantané réécrit à la demande de l'app — tout, ce projet, ou ces
# couloirs (un document changé, la fin d'un processus, une date atteinte). --reader pose la marque du lecteur (le pid de l'app, vivant)
# avant d'écrire. Sans lecteur vivant : rien d'écrit (READER=none). SNAPSHOT=, WRITTEN=, UNCHANGED=, REMOVED=.
app_snapshot() {
  local reader='' p lane wt
  # l'état de recette gardé sous l'instantané (lib/recette.sh, RECETTE_CACHE_DIR) : l'écrivain seul, jamais lab app lanes
  [ "${1:-}" != --pending ] || { umask 077; export GIT_OPTIONAL_LOCKS=0; snap_dir_set; RECETTE_CACHE_DIR="$SNAP_DIR/.acceptance"; app_snap_pending; return 0; }
  snap_dir_set
  # tout ou un projet entier (lab app lanes) demande le lab complet, comme un instantané d'une autre version : le chemin court de
  # bin/lab (couloirs nommés seulement) s'y remplace
  if [ "${APP_SNAP_FULL_LAB:-0}" != 1 ]; then
    if { [ "${1:-}" = --reader ] && [ "$#" -lt 4 ]; } || { [ "${1:-}" != --reader ] && [ "$#" -lt 2 ]; } || ! app_snap_current; then
      LAB_SNAP_FULL=1 exec "$LAB_ROOT/bin/lab" app snapshot "$@"
    fi
  fi
  if [ "${1:-}" = --reader ]; then
    reader="${2:-}"; shift 2 || usage
    snap_pid_alive "$reader" || die "--reader $reader: no live process with this pid — nothing written"
  fi
  umask 077; export GIT_OPTIONAL_LOCKS=0; snap_dir_set
  # shellcheck disable=SC2034 # RECETTE_CACHE_DIR est lu par recette_status (lib/recette.sh)
  RECETTE_CACHE_DIR="$SNAP_DIR/.acceptance"
  [ -d "$SNAP_DIR" ] || mkdir -p "$SNAP_DIR"
  if [ -n "$reader" ]; then
    local was=''; { IFS= read -r was <"$SNAP_DIR/reader"; } 2>/dev/null || true
    [ "$was" = "$reader" ] || printf '%s\n' "$reader" >"$SNAP_DIR/reader"
    [ ! -e "$SNAP_DIR/.dead.$reader" ] || rm -f "$SNAP_DIR/.dead.$reader"   # pid recyclé : le lecteur vit de nouveau
  fi
  kv SNAPSHOT "$SNAP_DIR"
  if ! snap_reader; then
    kv READER none; kv WRITTEN 0
    # le chemin court de bin/lab ne charge pas onboard.sh : son repli au mot, chargé pour ce seul message (vrai terminal, 40 colonnes)
    declare -F onboard_wrap >/dev/null || . "$LAB_ROOT/lib/onboard.sh"
    log_wrap "No live reader (Treelab.app is not running): nothing written."
    return 0
  fi
  # un nom devient un chemin sous l'instantané : jamais « .. », « / » ni vide (revue de sécurité du lot 03)
  if [ "$#" -ge 1 ]; then
    app_snap_name_ok "$1" || die "project name refused: $1 — nothing written"
    project_exists "$1" || [ "$#" = 1 ] || die "unknown project: $1 — nothing written"
  fi
  for lane in "${@:2}"; do app_snap_name_ok "$lane" || die "lane name refused: $lane — nothing written"; done
  app_snap_lock_wait || die "snapshot writer busy for 5 s: nothing written, the next change rewrites it"
  if [ "$#" = 0 ] || ! app_snap_current; then
    rm -f "$SNAP_DIR/pending"; app_snap_full
  elif [ "$#" = 1 ]; then
    app_snap_project "$1"
  else
    p="$1"; shift; load_project "$p"
    for lane in "$@"; do app_snap_lane "$P_ROOT/.worktrees/$lane"; done
    app_snap_counts "$p"
  fi
  app_snap_unlock
  kv WRITTEN "$APP_SNAP_WROTE"; kv UNCHANGED "$APP_SNAP_SAME"; kv REMOVED "$APP_SNAP_GONE"
  app_snap_measure app
  [ ! -s "$SNAP_DIR/pending" ] || snap_spawn
}

# app_cmux_app → le paquet .app de l'app pilotée (terminal_app=, ou le fork trouvé), sinon celui de la commande cmux
# (…/cmux.app/Contents/Resources/bin/cmux → …/cmux.app), vide hors d'un paquet : l'app le passe au premier plan après lab app focus
app_cmux_app() { terminal_resolve; [ -z "$TA_BUNDLE" ] || printf '%s\n' "$TA_BUNDLE"; }
# app_applescript_target → le spécificateur AppleScript de l'app pilotée : son paquet par son chemin (lot 02 d'app-treelab), jamais
# par son seul identifiant (Treelab.app du lot 01 et le fork peuvent partager le leur), ou application "cmux" sans ligne (comportement
# d'avant) ; rc 1 si le chemin porte un guillemet ou une barre oblique inverse (un texte AppleScript ne les porte pas tels quels)
app_applescript_target() {
  terminal_resolve
  [ -n "$TA_APP" ] || { printf 'application "cmux"\n'; return 0; }
  case "$TA_APP" in *\"*|*\\*) return 1 ;; esac
  printf 'application "%s"\n' "$TA_APP"
}

# APP_FOCUS_SCRIPT : la voie AppleScript de lab app focus, quand le socket de cmux refuse ce programme (mode cmuxOnly : Treelab.app
# n'est pas lancée par cmux). Arguments : l'espace enregistré du couloir (vide s'il n'en a pas), son dossier, le nom du projet.
# cmux fermé : « notrunning », sans le lancer (« running » se lit sans ouvrir l'app, revue du lot 01). Sinon le terminal de l'espace
# dont le dossier est celui du couloir (focus), sinon l'espace (select tab), sinon un terminal du couloir
# dans n'importe quel espace, sinon l'espace qui porte le nom du projet ; réponse tab, workspace ou absent. Le dictionnaire de cmux
# (cmux.sdef) : tab = espace (id stable, celui de .lab/cmux), terminal = panneau (working directory) — mesuré le 2026-11-24. Le
# script ne tape, n'ouvre ni ne ferme jamais rien. TARGET : l'app pilotée (app_applescript_target), écrite dans le texte avant la
# compilation — le vocabulaire de cmux se résout à la compilation, jamais depuis un argument.
APP_FOCUS_SCRIPT='on run argv
  set ws to item 1 of argv
  set wt to item 2 of argv
  set pn to item 3 of argv
  if TARGET is not running then return "notrunning"
  tell TARGET
    if ws is not "" then
      repeat with w in windows
        set ts to (tabs of w whose id is ws)
        if ts is not {} then
          set t to item 1 of ts
          set xs to (terminals of t whose working directory is wt)
          if xs is not {} then
            focus (item 1 of xs)
            return "tab"
          end if
          select tab t
          activate window w
          return "workspace"
        end if
      end repeat
    end if
    repeat with w in windows
      repeat with t in tabs of w
        set xs to (terminals of t whose working directory is wt)
        if xs is not {} then
          focus (item 1 of xs)
          return "tab"
        end if
      end repeat
    end repeat
    repeat with w in windows
      set ts to (tabs of w whose name is pn)
      if ts is not {} then
        select tab (item 1 of ts)
        activate window w
        return "workspace"
      end if
    end repeat
  end tell
  return "absent"
end run'

# app_focus_applescript <projet> <couloir> <wt> : la voie AppleScript ; ACTION=, WAY=applescript, ou un refus qui nomme la cause
app_focus_applescript() {
  local out rc=0 ws target script done_part
  ws="$(wt_ws "$3" || true)"
  target="$(app_applescript_target)" || die "terminal_app=$TA_APP: a quote or a backslash in this path cannot be written in AppleScript — lane $2 of $1 not brought to the front"
  # TARGET remplacé par concaténation : ${texte//motif/$cible} réécrirait un « & » de la cible sous bash ≥ 5.2 (patsub_replacement)
  script="$APP_FOCUS_SCRIPT"; done_part=""
  while :; do case "$script" in *TARGET*) done_part="$done_part${script%%TARGET*}$target"; script="${script#*TARGET}" ;; *) break ;; esac; done
  out="$(printf '%s\n' "$done_part$script" | osascript - "$ws" "$3" "$1" 2>&1)" || rc=$?
  if [ "$rc" != 0 ]; then
    case "$out" in
      *-1743*) die "macOS did not let Treelab control cmux (System Settings, Privacy & Security, Automation): nothing brought to the front" ;;
      *) die "cmux AppleScript failed: $(head -1 <<<"$out") — nothing brought to the front" ;;
    esac
  fi
  case "$out" in
    tab|workspace) kv WORKSPACE "$ws"; kv SURFACE ""; kv ACTION "$out"; kv WAY applescript; kv APP "$(app_cmux_app)" ;;
    notrunning) die "cmux is not running: lane $2 of $1 stays where it is — nothing brought to the front, nothing launched" ;;
    *) die "no cmux tab nor workspace for $2 in $1: lab next $1 $2 opens the lane — nothing launched" ;;
  esac
}

# lab app focus <projet> <couloir> : l'onglet du couloir amené devant (ACTION=tab), sinon l'espace cmux du projet (ACTION=workspace),
# WAY= (socket, ou applescript quand cmux refuse ce programme) et APP=, le paquet de cmux. Jamais d'agent, de session ni d'onglet
# lancé : lab next ouvre un couloir. Le nom du couloir est un dossier exact de .worktrees.
app_focus() {
  [ "$#" = 2 ] || usage
  local p="$1" lane="$2" wt d found=0 name tab ws surface
  project_exists "$p" || die "unknown project: $p — nothing brought to the front (lab app lanes lists the projects)"
  load_project "$p"
  case "$lane" in ''|.*|*/*) ;; *) for d in "$P_ROOT/.worktrees"/*; do [ "${d##*/}" != "$lane" ] || found=1; done ;; esac
  wt="$(worktree_path "$lane")"
  [ "$found" = 1 ] && [ -d "$wt/.lab" ] || die "no lane $lane in $p — nothing brought to the front (lab app lanes $p lists its lanes)"
  has_cmux || die "cmux unreachable: lane $lane of $p cannot be brought to the front"
  kv PROJECT "$p"; kv LANE "$lane"
  # le socket refuse un programme que cmux n'a pas lancé (mode cmuxOnly, réglage de l'utilisateur, jamais changé par lab)
  if ! cmx workspace list --json >/dev/null 2>&1; then app_focus_applescript "$p" "$lane" "$wt"; return 0; fi
  name="$(wt_cmux_value "$wt" name || true)"
  tab="$(cmux_lane_tab "$(wt_ws "$wt" || true)" "$(wt_surface "$wt" || true)" "${name:-$lane}")"
  ws="$(cmux_tab_field "$tab" workspace)"; surface="$(cmux_tab_field "$tab" surface)"
  case "$(cmux_tab_field "$tab" way)" in
    reference|name)
      cmux_focus "$ws" "$surface" || die "cmux: selecting the tab $lane of $p failed"
      kv WORKSPACE "$ws"; kv SURFACE "$surface"; kv ACTION tab; kv WAY socket; kv APP "$(app_cmux_app)"; return 0 ;;
  esac
  [ -n "$ws" ] || ws="$(wt_ws "$wt" || true)"
  if [ -z "$ws" ] || ! cmux_ws_exists "$ws"; then ws="$(cmux_group_anchor "$p" || true)"; fi
  [ -n "$ws" ] && ws="$(cmux_ws_uuid "$ws" || true)" && [ -n "$ws" ] \
    || die "no cmux workspace for $p: lab next $p $lane opens the lane — nothing launched"
  cmux_focus "$ws" || die "cmux: selecting the workspace of $p failed"
  kv WORKSPACE "$ws"; kv SURFACE ""; kv ACTION workspace; kv WAY socket; kv APP "$(app_cmux_app)"
}

# ---------- compte et réglages (lot 01 de compte-app) ----------
# Contrat « compte et réglages » v1.1, tenu par le couloir de l'app : l'app lit l'état que lab écrit et agit par ses commandes. Un refus
# du contrat rend le code 2, REASON= sur la sortie et le texte sur stderr ; lecture sans réseau ni écriture.
APP_PROTOCOL=1
APP_TRIAL_DAYS=14   # TRIAL_SECONDS de api/src/trial.ts (tests/app_account.bats les compare)

# app_refuse <raison> <texte> : REASON= sur la sortie, le texte sur stderr, code 2
app_refuse() { kv REASON "$1"; log_wrap "$2"; exit 2; }

# app_amount <centimes> → l'euro sans décimale s'il est rond, sinon deux décimales (3950 → 39.50)
app_amount() { if [ $(($1 % 100)) = 0 ]; then printf '%s\n' "$(($1 / 100))"; else printf '%s.%02d\n' "$(($1 / 100))" "$(($1 % 100))"; fi; }

# app_offer_kv : OFFER_* depuis le fichier d'offre du serveur (api/src/offer.json, livré dans la release), jamais écrit dans l'app ;
# fichier absent ou hors forme : aucune clé OFFER_, rien d'autre ne change
app_offer_kv() {
  local f="${LAB_OFFER_FILE:-$LAB_ROOT/api/src/offer.json}" row month year cur pct from
  row="$(jq -er 'def n: type=="number" and floor==. and .>0; .subscription | select((.month|n) and (.year|n) and (.currency|type=="string")
    and (.team_percent_off|n) and (.team_seats|n)) | [.month, .year, (.currency|ascii_upcase), .team_percent_off, .team_seats] | @tsv' \
    "$f" 2>/dev/null)" || return 0
  IFS=$'\t' read -r month year cur pct from <<<"$row"
  kv OFFER_TRIAL_DAYS "$APP_TRIAL_DAYS"; kv OFFER_MONTH "$(app_amount "$month")"; kv OFFER_YEAR "$(app_amount "$year")"
  kv OFFER_CURRENCY "$cur"; kv OFFER_TAX included; kv OFFER_DISCOUNT_PCT "$pct"; kv OFFER_DISCOUNT_FROM "$from"
}

# app_license_present : la licence de ce Mac, sans la lire (elle porte le jeton d'activation) — la règle du doctor : fichier ordinaire,
# non vide, lisible, pas un lien, droits 0600
app_license_present() {
  local f="$LAB_HOME/license"
  [ -f "$f" ] && [ ! -L "$f" ] && [ -s "$f" ] && [ -r "$f" ] && [ "$(stat -f %Lp "$f" 2>/dev/null)" = 600 ]
}

# lab app account : le compte de ce Mac. Avant les comptes (lots 03 et suivants) : SIGNED_IN=no, ACTIVATION=key|none, droits lus du
# cache qu'écrivent lab update et lab subscribe (lib/entitlement.sh) — EMAIL, PERIOD, SEATS et ROLE vides. RENEWS : la fin payée, que
# le serveur prolonge de 24 h tant que l'abonnement se renouvelle (api/contracts/subscription-v1.md, règle des droits)
# shellcheck disable=SC2153 # ENT_* sont posés par entitlement_state (lib/entitlement.sh, chargé ici)
app_account() {
  [ "$#" = 0 ] || app_refuse usage "usage: lab app account (read only, no option)"
  local plan=none state=none days='' renews='' ends='' checked='' activation=none now
  . "$LAB_ROOT/lib/entitlement.sh"
  if app_license_present; then
    activation=key; plan=unknown; state=unknown
    now="$(entitlement_now 2>/dev/null)" || now=''
    ENT_PLAN='' ENT_UNTIL='' ENT_RENEWS='' ENT_CHECKED=''   # horloge illisible : entitlement_state rend sans lire le cache
    entitlement_state "$now"
    [ -z "$ENT_CHECKED" ] || checked="$(entitlement_instant "$ENT_CHECKED")"
    if [ -n "$ENT_PLAN" ] && [ -z "$ENT_UNTIL" ]; then plan=lifetime; state=active
    elif [ -n "$ENT_PLAN" ]; then
      plan="$ENT_PLAN"
      case "$ENT_STATE" in
        ended) state=ended; ends="$(entitlement_day "$ENT_UNTIL")" ;;
        active|ending)
          if [ "$plan" = trial ]; then state=trial; days=$(( (ENT_UNTIL - now + 86399) / 86400 )); else state=active; fi
          if [ "$ENT_RENEWS" = true ]; then renews="$(entitlement_day "$((ENT_UNTIL - 86400))")"; else ends="$(entitlement_day "$ENT_UNTIL")"; fi ;;
      esac
    fi
  fi
  kv PROTOCOL "$APP_PROTOCOL"; kv SIGNED_IN no; kv ACTIVATION "$activation"; kv EMAIL ''; kv ROLE ''
  kv PLAN "$plan"; kv PERIOD ''; kv STATE "$state"; kv TRIAL_DAYS_LEFT "$days"; kv RENEWS "$renews"; kv ENDS "$ends"
  kv SEATS ''; kv CHECKED "$checked"; kv WATCH "$(entitlement_file)"
  app_offer_kv
}

# app_quiet_norm <HH:MM-HH:MM|off> → la plage écrite à deux chiffres, ou off ; rc 1 pour une plage illisible ou vide (début = fin)
app_quiet_norm() {
  local s e
  [ "$1" != off ] || { printf 'off\n'; return 0; }
  [ "${1#*-}" != "$1" ] && ginkgo_minute_set "${1%%-*}" && s="$GINKGO_MINUTE" && ginkgo_minute_set "${1#*-}" && e="$GINKGO_MINUTE" &&
    [ "$s" != "$e" ] || return 1
  printf '%02d:%02d-%02d:%02d\n' $((s / 60)) $((s % 60)) $((e / 60)) $((e % 60))
}

# app_ginkgo_write <clé> <valeur> : ginkgo_config_write, dont le refus (lien, verrou tenu, dossier non inscriptible, vus avant tout
# changement) devient celui du contrat : code 2, REASON=unwritable, son texte sur stderr
app_ginkgo_write() {
  local err
  err="$(ginkgo_config_write "$1" "$2" 2>&1)" || app_refuse unwritable "${err#"$DIE_PREFIX"}"
}

# lab app ginkgo [--listen command|key|name] [--speak always|conversation|never] [--quiet HH:MM-HH:MM|off] : les réglages de Ginkgo de
# ~/.lab/config (ginkgo_listen=, ginkgo_speak=, ginkgo_quiet=), lus ou écrits (tout est vérifié avant la première écriture). Parole et
# heures calmes valent tout de suite (lab les relit à chaque annonce) ; l'écoute, dès que --listen est donné, à la prochaine
# ouverture de Ginkgo (APPLIES=next-open). Aucun événement n'est envoyé à Ginkgo.
app_ginkgo() {
  local listen='' speak='' quiet='' q
  . "$LAB_ROOT/lib/ginkgo.sh"
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] && [ -n "$2" ] || app_refuse usage "usage: lab app ginkgo [--listen <mode>] [--speak <mode>] [--quiet <HH:MM-HH:MM|off>]"
    case "$1" in
      --listen) case "$2" in command|key|name) listen="$2" ;; *) app_refuse invalid "unknown listen mode: $2 (command, key or name): nothing changed" ;; esac ;;
      --speak) case "$2" in always|conversation|never) speak="$2" ;; *) app_refuse invalid "unknown speak mode: $2 (always, conversation or never): nothing changed" ;; esac ;;
      --quiet) quiet="$(app_quiet_norm "$2")" || app_refuse invalid "quiet hours $2 are not HH:MM-HH:MM (two different times) or off: nothing changed" ;;
      *) app_refuse usage "usage: lab app ginkgo [--listen <mode>] [--speak <mode>] [--quiet <HH:MM-HH:MM|off>]" ;;
    esac
    shift 2
  done
  [ -z "$listen" ] || app_ginkgo_write ginkgo_listen "$listen"
  [ -z "$speak" ] || app_ginkgo_write ginkgo_speak "$speak"
  [ -z "$quiet" ] || app_ginkgo_write ginkgo_quiet "$quiet"
  ginkgo_listen_mode >/dev/null; kv LISTEN "$GINKGO_LISTEN"
  ginkgo_speak_mode_set; kv SPEAK "$GINKGO_SPEAK"
  ginkgo_config_set ginkgo_quiet; q="$(app_quiet_norm "${GINKGO_CONF:-$GINKGO_QUIET_DEFAULT}")" || { ginkgo_quiet_range_set; q="$GINKGO_QUIET_DEFAULT"; }
  kv QUIET "$q"
  [ -z "$listen$speak$quiet" ] || if [ -n "$listen" ]; then kv APPLIES next-open; else kv APPLIES now; fi
}

# lab app signin --email <adresse> · lab app signout --everywhere : la forme du contrat, refusée en code 2 (REASON=unsupported) tant
# que les comptes n'existent pas au serveur (lots 03 et 04) ; rien n'est envoyé
app_signin() {
  [ "$#" = 2 ] && [ "$1" = --email ] && [ -n "$2" ] || app_refuse usage "usage: lab app signin --email <address>"
  app_refuse unsupported "Signing in by email arrives with a later version of lab: nothing sent. lab subscribe and the OpenAI key already work."
}
app_signout() {
  [ "$#" = 1 ] && [ "$1" = --everywhere ] || app_refuse usage "usage: lab app signout --everywhere"
  app_refuse unsupported "Signing out everywhere arrives with a later version of lab: nothing changed."
}

# ---------- lab app data (lot 02 de compte-app) : export lisible sans secret, effacement en deux temps ----------
APP_DATA_USAGE="usage: lab app data --export <folder> | --erase [--confirm <token>]"
APP_ERASE_TTL=120
# APP_SECRET_PERL : APP_SECRET_MODE=redact (entrée standard → sortie) remplace chaque motif de secret connu par [secret removed], la
# clé d'un clé=valeur gardée (espaces autour du signe égal compris ; une valeur entre guillemets jusqu'au guillemet fermant, ou
# jusqu'à la fin de la ligne s'il manque), comme le préfixe d'un lien de facturation ou de caisse (?link= ou ?claim=,
# lib/subscribe.sh) ; scan (chemins en arguments) rend 1 au premier motif restant, dans un chemin (un nom de fichier n'est jamais
# filtré) ou dans le texte d'un fichier — une valeur qui commence par un guillemet comprise —, 0 sinon
# shellcheck disable=SC2016 # du perl : ses $ ne sont jamais développés par le shell
APP_SECRET_PERL='
my $v = qr{tl_key_[A-Za-z0-9_-]+|\bsk-[A-Za-z0-9_-]{16,}|\bek_[A-Za-z0-9_-]{16,}|(?i:bearer)[ \t]+[A-Za-z0-9._~+/=-]{16,}|[?&](?i:link|claim)=\K[0-9A-Fa-f]{32,}};
my $k = qr{(?i:token|secret|password|passwd|api_key|apikey|access_key)[ \t]*=[ \t]*};
my $q = qr{"[^"\n]*"?|\x27[^\x27\n]*\x27?|[^\s&"\x27<>]+};
my $r = "[secret removed]";
my $left = sub { $_[0] =~ $v || $_[0] =~ /$k(?!\Q$r\E)[^\s&<>]/ };
if (($ENV{APP_SECRET_MODE} // "") eq "scan") {
  for my $f (@ARGV) {
    exit 1 if $left->($f);
    next unless -f $f;
    open(my $h, "<", $f) or exit 1;
    while (<$h>) { exit 1 if $left->($_) }
  }
  exit 0;
}
while (<STDIN>) { s/$v/$r/g; s/($k)(?!\Q$r\E)(?:$q)/$1$r/g; print }'
app_data_put() { APP_SECRET_MODE=redact perl -e "$APP_SECRET_PERL" >"$1"; }   # <fichier> : l'entrée standard filtrée
# app_data_copy <source> <destination> : un fichier ordinaire (jamais un lien) filtré ; rien pour un absent
app_data_copy() { [ -f "$1" ] && [ ! -L "$1" ] || return 0; mkdir -p "${2%/*}" && app_data_put "$2" <"$1"; }
app_data_clean() {   # depuis le dossier de l'export : rc 0 sans motif de secret, ni dans les chemins ni dans les textes
  local f; local -a fs=()
  while IFS= read -r -d '' f; do fs+=("$f"); done < <(find . -mindepth 1 -print0)
  [ "${#fs[@]}" = 0 ] || APP_SECRET_MODE=scan perl -e "$APP_SECRET_PERL" "${fs[@]}"
}
app_data_readme() {   # <horodatage>
  cat <<EOF
Treelab data export of this Mac — $1 (UTC), lab $(app_snap_version)

What this folder holds, as readable text:
- account.txt: the account of this Mac (lab app account).
- settings.txt: the Ginkgo settings (lab app ginkgo) and the lab settings (~/.lab/config).
- lanes.txt: your projects and lanes with their state (lab app lanes).
- ginkgo/: the Ginkgo log, its news for all projects (news-all) and, per project, its news; the precisions you told Ginkgo
  (precisions: ignore, only, even at night), kept as a setting when the data are erased.
- agreements/ and words/: per project and lane, the agreements and the words lab recorded.

No secret: the licence of this Mac, the OpenAI key (macOS keychain) and the confirmation tokens are never copied. Texts in the
known shapes of a key or a token (sk-, ek_, tl_key_ and Bearer keys, the values of token, secret and password settings, the
billing and checkout links) are replaced by [secret removed]; a text of another shape stays as written, so read this folder before you share it. Your code and
your batch files stay in your repositories.
EOF
}
# app_data_fill <dossier> <horodatage> : chaque fichier de l'export, filtré ; rc 1 au premier échec (set -e est sans effet ici)
app_data_fill() {
  local d="$1" f p k
  app_data_readme "$2" >"$d/README.txt" || return 1
  ( app_account ) 2>/dev/null | app_data_put "$d/account.txt" || return 1
  { printf '# Ginkgo settings (lab app ginkgo)\n'; ( app_ginkgo ) 2>/dev/null
    printf '\n# lab settings (~/.lab/config)\n'; [ ! -f "$LAB_HOME/config" ] || cat "$LAB_HOME/config"; } | app_data_put "$d/settings.txt" || return 1
  { ( app_lanes ) 2>/dev/null || printf 'LANES=unreadable\n'; } | app_data_put "$d/lanes.txt" || return 1
  mkdir -p "$d/ginkgo/news" "$d/agreements" "$d/words" || return 1
  for f in "$(ginkgo_dir)"/ginkgo.log*; do app_data_copy "$f" "$d/ginkgo/${f##*/}" || return 1; done
  app_data_copy "$(ginkgo_dir)/news" "$d/ginkgo/news-all" || return 1   # lab ginkgo news --all, le mode de Ginkgo.app
  for f in "$LAB_STATE"/*/ginkgo/news; do p="${f%/ginkgo/news}"; app_data_copy "$f" "$d/ginkgo/news/${p##*/}" || return 1; done
  app_data_copy "$(ginkgo_dir)/precisions" "$d/ginkgo/precisions" || return 1   # ce que la personne a dit à Ginkgo : un réglage, gardé à l'effacement
  for k in agreements words; do
    for f in "$LAB_STATE"/*/"$k"/*; do p="${f%/"$k"/*}"; app_data_copy "$f" "$d/$k/${p##*/}/${f##*/}" || return 1; done
  done
}
# lab app data --export <dossier> : un dossier neuf treelab-export-<AAAAMMJJ-HHMMSS>[-N] (700) dans <dossier>, jamais réécrit ; sans
# réseau, aucune source écrite, ni la licence ni le trousseau lus ; un motif de secret resté après le filtre retire l'export
app_data_export() {
  local dest now stamp base dir i=1
  dest="$(cd "$1" 2>/dev/null && pwd)" && [ -w "$dest" ] \
    || app_refuse unwritable "cannot export into $1: not an existing folder this user can write — nothing written"
  now="$(entitlement_now)" || now="$(date +%s)"
  stamp="$(date -u -r "$now" +%Y%m%d-%H%M%S)"
  base="${dest%/}/treelab-export-$stamp"; dir="$base"
  until ( umask 077; mkdir "$dir" ) 2>/dev/null; do
    i=$((i + 1)); [ "$i" -le 99 ] || app_refuse unwritable "cannot create a new folder in $dest — nothing written"
    dir="$base-$i"
  done
  if ! ( umask 077; app_data_fill "$dir" "$stamp" ); then
    rm -R "$dir" 2>/dev/null || true
    app_refuse unwritable "the export into $dir failed: nothing exported"
  fi
  if ! ( cd "$dir" && app_data_clean ); then
    rm -R "$dir" 2>/dev/null || true
    app_refuse secret "a text shaped like a key or a token stayed in the export (a file name, the name of a lane?): nothing exported"
  fi
  kv EXPORTED "$dir"
}

app_erase_pending() { printf '%s/app-erase-pending\n' "$LAB_STATE"; }
# app_erase_rm <nom> <chemin>… : retire chaque chemin ; un chemin resté ajoute <nom> à APP_LEFT
app_erase_rm() {
  local n="$1" f; shift
  for f in "$@"; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    rm -R "$f" 2>/dev/null || true
    if [ -e "$f" ] || [ -L "$f" ]; then case " $APP_LEFT " in *" $n "*) ;; *) APP_LEFT="${APP_LEFT:+$APP_LEFT }$n" ;; esac; fi
  done
}
# lab app data --erase [--confirm <jeton>] : geste de la personne, refusé à un agent aux deux temps ; d'abord la relecture (READBACK,
# TOKEN, EXPIRES_IN, rien effacé), puis, jeton juste dans le délai (un seul essai) : Ginkgo arrêté s'il tourne, son journal et ses
# nouvelles, l'instantané de l'app (la marque du lecteur et le verrou de l'écrivain gardés), le cache des droits et la clé OpenAI
# effacés. Restent lab, ~/.lab/config (réglages de Ginkgo compris), la licence, projets, couloirs, fiches, accords et mots.
app_data_erase() {
  local token='' f now at ptoken d e
  case "$#" in
    0) ;;
    2) [ "$1" = --confirm ] && [ -n "$2" ] || app_refuse usage "$APP_DATA_USAGE"; token="$2" ;;
    *) app_refuse usage "$APP_DATA_USAGE" ;;
  esac
  [ "$(caller_role)" = human ] \
    || app_refuse agent "Erasing the data of this Mac is a gesture of the person (Treelab or their terminal): refused to an agent, nothing erased."
  f="$(app_erase_pending)"; now="$(entitlement_now)" || now="$(date +%s)"
  if [ -z "$token" ]; then
    token="$(LC_ALL=C od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
    { mkdir -p "$LAB_STATE" && ( umask 077; printf 'token=%s\nat=%s\n' "$token" "$now" >"$f.tmp.$$" && mv "$f.tmp.$$" "$f" ); } 2>/dev/null \
      || app_refuse unwritable "cannot write $f: nothing to confirm"
    kv READBACK "Erase the data of Treelab on this Mac: Ginkgo stops if it runs; its log and its news, what lab keeps for the app, the account cache and the OpenAI key (macOS keychain) leave this Mac. Kept: lab, your projects, lanes, batch files, agreements and words, your account and licence, the Ginkgo settings. Confirm with the token within $APP_ERASE_TTL s."
    kv TOKEN "$token"; kv EXPIRES_IN "$APP_ERASE_TTL"
    return 0
  fi
  [ -s "$f" ] && [ ! -L "$f" ] || app_refuse token "no erase read back: nothing erased — run lab app data --erase first"
  ptoken="$(sed -n 's/^token=//p' "$f")"; at="$(sed -n 's/^at=//p' "$f")"
  rm -f "$f" 2>/dev/null || app_refuse unwritable "cannot consume the read-back $f: nothing erased"   # un seul essai
  [ -n "$ptoken" ] && [ "$token" = "$ptoken" ] || app_refuse token "wrong confirmation token: nothing erased — read it back again (lab app data --erase)"
  case "$at" in ''|*[!0-9]*) app_refuse token "unreadable read-back: nothing erased — read it back again" ;; esac
  [ "$((now - at))" -ge 0 ] && [ "$((now - at))" -le "$APP_ERASE_TTL" ] \
    || app_refuse token "the read-back is older than $APP_ERASE_TTL s: nothing erased — read it back again (lab app data --erase)"
  . "$LAB_ROOT/lib/ginkgo.sh"
  if pgrep -x Ginkgo >/dev/null 2>&1 && ! ginkgo_stop; then
    app_refuse busy "Ginkgo did not stop: quit it from its menu bar icon, then erase again — nothing erased"
  fi
  APP_LEFT=''
  app_erase_rm ginkgo-log "$(ginkgo_dir)"/ginkgo.log*
  app_erase_rm ginkgo-news "$(ginkgo_dir)/news" "$LAB_STATE"/*/ginkgo/news
  d="$LAB_STATE/app-snapshot"
  if [ -d "$d" ] && [ ! -L "$d" ]; then
    for e in "$d"/* "$d"/.[!.]*; do case "${e##*/}" in reader|lock) ;; *) app_erase_rm app-snapshot "$e" ;; esac; done
  fi
  app_erase_rm account-cache "$(entitlement_file)"
  if ginkgo_key_present; then
    security delete-generic-password -s "$GINKGO_SERVICE" -a "$GINKGO_ACCOUNT" >/dev/null 2>&1 || true
    ! ginkgo_key_present || APP_LEFT="${APP_LEFT:+$APP_LEFT }keychain"
  fi
  if [ -z "$APP_LEFT" ]; then kv ERASED yes; return 0; fi
  kv ERASED partial; kv LEFT "$APP_LEFT"
  app_refuse partial "Some data stayed on this Mac ($APP_LEFT): remove it by hand (the OpenAI key in Keychain Access, service $GINKGO_SERVICE)."
}
app_data() {
  case "${1:-}" in
    --export) [ "$#" = 2 ] && [ -n "$2" ] || app_refuse usage "$APP_DATA_USAGE"; . "$LAB_ROOT/lib/ginkgo.sh"; app_data_export "$2" ;;
    --erase) shift; app_data_erase "$@" ;;
    *) app_refuse usage "$APP_DATA_USAGE" ;;
  esac
}

cmd_app() {
  [ "$#" -ge 1 ] || usage
  local sub="$1"; shift
  case "$sub" in
    lanes) app_lanes "$@" ;;
    focus) app_focus "$@" ;;
    snapshot) APP_SNAP_FULL_LAB=1; unset LAB_SNAP_FULL; app_snapshot "$@" ;;
    account) app_account "$@" ;;
    ginkgo) app_ginkgo "$@" ;;
    signin) app_signin "$@" ;;
    signout) app_signout "$@" ;;
    data) app_data "$@" ;;
    *) usage ;;
  esac
}
