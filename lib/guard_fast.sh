# shellcheck shell=bash
# guard_fast.sh — le chemin court de la garde et de notify (lot 01 de charge-processeur). Chaque outil d'un agent passe par ici : la
# garde complète créait 281 processus pour un « ls » et 3 033 pour un Edit (15 projets, 160 couloirs). Le chemin court ne sait
# qu'autoriser, sans rien écrire, et seulement ce que le chemin complet (lib/hooks.sh) autorise sans rien écrire ; il ne connaît
# aucune règle : les pré-filtres qu'il applique sont ceux du chemin complet, définis ici une seule fois pour les deux. Au moindre
# doute (charge illisible, verrou d'une autre session, attente posée, mot d'une règle, cible protégée) : chemin complet, dans ce
# même processus. Tout se lit par le shell seul, hormis deux processus : cat (l'entrée) et jq (ses champs).
# Chargé par hooks/*.sh avec LAB_ROOT posé ; lib/hooks.sh le charge aussi.
QUOTED=$'\x1f'        # une chaîne entre guillemets, neutralisée (segments, lib/hooks.sh)
GUARD_FIELDS=''       # ok : PAYLOAD et HF_* sont lus ; refused : PAYLOAD seul ; slow : HF_* lus champ par champ (guard_read, lib/hooks.sh)
GUARD_LOCK=''         # ok : le verrou de session est contrôlé, hook_lock_resume n'a plus rien à faire
HOOK_HERE="$PWD"      # dossier du crochet : le dossier de travail d'une charge sans .cwd, rendu après chaque cd
# shellcheck disable=SC2034 # lus par git_places (lib/git.sh)
GP_MEMO=0 GP_FOR=''   # sa mémoire : celle d'un seul crochet, jamais héritée de l'environnement

# ---------- primitives sans processus ----------
# lexical_set <chemin> : LEXICAL, le chemin normalisé (sans exiger son existence)
lexical_set() {
  local p="$1" out="" seg
  local IFS='/'
  for seg in $p; do
    case "$seg" in ''|.) ;; ..) out="${out%/*}" ;; *) out="$out/$seg" ;; esac
  done
  LEXICAL="${out:-/}"
}
# base_set <mot> : BASE = basename du mot ; vide pour un mot que basename refuserait (une option)
base_set() {
  BASE="$1"
  # plusieurs barres finales : le vrai basename — les retirer une à une recopierait le mot à chaque tour (12 000 barres : 22 s)
  case "$BASE" in -?*) BASE=''; return 0 ;; *//) BASE="$(exec basename -- "$BASE")" || BASE=''; return 0 ;; ?*/) BASE="${BASE%/}" ;; esac
  case "$BASE" in /) ;; *) BASE="${BASE##*/}" ;; esac
}
# words_split <texte> : WORDS, ses mots (espaces, tabulations), sans développement de noms de fichiers ni fichier temporaire (un
# « read -a <<< » en écrit un à chaque fois)
words_split() {
  set -f
  # shellcheck disable=SC2206 # découpe en mots voulue
  WORDS=($1)
  set +f
}
# segments_line <ligne> : SEG_LINE, ses segments (&&, ||, ;, |, & seul), un par ligne, chaînes citées neutralisées — même découpe,
# à l'octet près, que l'awk de segments_set (lib/hooks.sh), comparée par tests/hooks.bats
segments_line() {
  local s="$1" a pre q nl=$'\n'
  for q in "'" '"'; do
    a=''
    while :; do
      case "$s" in *"$q"*"$q"*) ;; *) break ;; esac
      a="$a${s%%"$q"*}$QUOTED"; s="${s#*"$q"}"; s="${s#*"$q"}"
    done
    s="$a$s"
  done
  s="${s//&&/$nl}"; s="${s//||/$nl}"; s="${s//;/$nl}"; s="${s//|/$nl}"
  a=''
  while :; do   # & seul : segment ; >&, <& et &> restent dans le leur (>& l'emporte sur &>)
    case "$s" in *'&'*) ;; *) break ;; esac
    pre="${s%%&*}"; s="${s#*&}"
    case "$pre" in *'>'|*'<') a="$a$pre&"; continue ;; esac
    case "$s" in '>&'*) a="$a$pre$nl" ;; '>'*) a="$a$pre&" ;; *) a="$a$pre$nl" ;; esac
  done
  SEG_LINE="$a$s"
}

# ---------- cibles de mise en ligne déclarées (garde des déploiements, lot 02 de mise-en-ligne) ----------
# deploy_words_set <segment> : DEPLOY_WORDS, ses mots sans parenthèses de sous-shell ni préfixes VAR=…, sudo, env, nohup, command, exec, time
deploy_words_set() {
  local i=0
  words_split "${1//[()]/ }"
  while [ "$i" -lt "${#WORDS[@]}" ]; do case "${WORDS[$i]}" in *=*|sudo|env|nohup|command|exec|time) i=$((i+1)) ;; *) break ;; esac; done
  if [ "$i" -lt "${#WORDS[@]}" ]; then DEPLOY_WORDS="${WORDS[*]:$i}"; else DEPLOY_WORDS=''; fi
}
# deploy_plain_set <mots> : DEPLOY_PLAIN, sans les options (-x, --long) : « npx --yes wrangler deploy » et « npx wrangler deploy » se valent
deploy_plain_set() {
  local w out=""
  words_split "$1"
  for w in "${WORDS[@]+"${WORDS[@]}"}"; do case "$w" in -*) ;; *) out="${out:+$out }$w" ;; esac; done
  DEPLOY_PLAIN="$out"
}
deploy_builtin() { # <mots> → 0 si c'est une commande de déploiement connue
  local a dest=""
  case " $1 " in
    *" wrangler deploy "*|*" wrangler publish "*|*" wrangler pages deploy "*) return 0 ;;
    *" gcloud run deploy "*|*" gcloud app deploy "*|*" gcloud functions deploy "*) return 0 ;;
    *" trigger deploy "*|*" trigger.dev"*" deploy "*|*" vercel "*"--prod"*|*" netlify deploy "*"--prod"*) return 0 ;;
    *" fly deploy "*|*" flyctl deploy "*|*" firebase deploy "*|*" supabase functions deploy "*) return 0 ;;
    *rsync*) ;;
    *) return 1 ;;
  esac
  words_split "$1"
  base_set "${WORDS[0]:-x}"; [ "$BASE" = rsync ] || return 1
  for a in "${WORDS[@]:1}"; do case "$a" in -*) ;; *) dest="$a" ;; esac; done
  case "$dest" in *:*) return 0 ;; esac   # destination (dernier argument) distante hôte:chemin ; une source distante passe
  return 1
}
# deploy_signature_set <commande deploy.<cible>> : DEPLOY_SIG, son début : le segment qui est un déploiement connu (wrangler deploy…)
# s'il y en a un — un modèle de lab deploy --add installe et prépare avant (npm ci, npm run …), jamais signature ; sinon le premier
# segment hors cd et hors installation des dépendances (npm ci, pnpm/yarn/bun install…) : les mots avant la première option (trois au
# plus) s'ils sont deux ou forment un chemin (./scripts/x.sh), sinon trois mots hors options — npx, npm ou bash seuls refuseraient
# toutes leurs commandes (revue) ; rien si le segment n'a qu'un programme nu
deploy_signature_set() {
  local seg rest w before="" n; local -a t=()
  DEPLOY_SIG=''
  segments_line "$1"
  rest="$SEG_LINE"$'\n'
  while [ -n "$rest" ]; do
    seg="${rest%%$'\n'*}"; rest="${rest#*$'\n'}"
    deploy_words_set "$seg"
    if [ -z "$DEPLOY_WORDS" ] || ! deploy_builtin "$DEPLOY_WORDS"; then continue; fi
    deploy_plain_set "$DEPLOY_WORDS"; words_split "$DEPLOY_PLAIN"
    DEPLOY_SIG="${WORDS[*]:0:3}"; return 0
  done
  rest="$SEG_LINE"$'\n'
  while [ -n "$rest" ]; do
    seg="${rest%%$'\n'*}"; rest="${rest#*$'\n'}"
    deploy_words_set "$seg"; words_split "$DEPLOY_WORDS"; t=("${WORDS[@]+"${WORDS[@]}"}")
    if [ "${#t[@]}" = 0 ] || [ "${t[0]}" = cd ]; then continue; fi
    deploy_plain_set "${t[*]}"
    case " $DEPLOY_PLAIN " in " npm ci "*|" npm install "*|" pnpm install "*|" yarn install "*|" bun install "*|" uv sync "*) continue ;; esac
    for w in "${t[@]}"; do case "$w" in -*) break ;; esac; before="${before:+$before }$w"; done
    words_split "$before"; n="${#WORDS[@]}"
    if [ "$n" -gt 0 ]; then before="${WORDS[*]:0:3}"; else before=""; fi
    case "$n:$before" in 1:*/*|[2-9]:*) DEPLOY_SIG="$before"; return 0 ;; esac
    words_split "$DEPLOY_PLAIN"
    if [ "${#WORDS[@]}" -ge 2 ]; then DEPLOY_SIG="${WORDS[*]:0:3}"; fi
    return 0
  done
}
# deploy_sigs_set : DEPLOY_SIGS, « projet<TAB>cible<TAB>début » par deploy.<cible>= déclarée, un projet enregistré après l'autre
deploy_sigs_set() {
  local f line p
  DEPLOY_SIGS=''
  for f in "$LAB_PROJECTS"/*/config; do
    [ -f "$f" ] && [ -r "$f" ] || continue
    p="${f%/config}"; p="${p##*/}"
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in deploy.*) ;; *) continue ;; esac
      deploy_signature_set "${line#*=}"; line="${line%%=*}"
      [ -z "$DEPLOY_SIG" ] || DEPLOY_SIGS="$DEPLOY_SIGS$p"$'\t'"${line#deploy.}"$'\t'"$DEPLOY_SIG"$'\n'
    done <"$f"
  done
}
# deploy_sig_hint <commande> : rc 0 si elle porte le premier mot d'un début déclaré (DEPLOY_SIGS posé)
deploy_sig_hint() {
  local rest="$DEPLOY_SIGS" s
  while [ -n "$rest" ]; do
    s="${rest%%$'\n'*}"; rest="${rest#*$'\n'}"; s="${s#*$'\t'}"; s="${s#*$'\t'}"
    [ -n "$s" ] || continue
    case "$1" in *"${s%% *}"*) return 0 ;; esac
  done
  return 1
}

# ---------- charge du crochet ----------
# guard_fields : PAYLOAD (l'entrée entière) et ses champs HF_CWD, HF_TOOL, HF_PATH, HF_CMD (des chaînes, ou vides), lus par un seul
# jq ; HOOK_CWD. rc 1 si l'entrée n'est pas un objet JSON unique aux champs attendus, ou porte un octet nul (@sh l'écrit « \0 », une
# substitution de commande l'efface) : guard_read (lib/hooks.sh) la lit champ par champ, comme avant
guard_fields() {
  local out
  case "$GUARD_FIELDS" in refused) return 1 ;; ?*) return 0 ;; esac
  PAYLOAD="$(exec cat 2>/dev/null)" || true
  GUARD_FIELDS=refused   # l'entrée ne se lit qu'une fois : le chemin complet repart de PAYLOAD, jamais d'un cat vide qui autoriserait tout
  # shellcheck disable=SC2016 # programme jq littéral
  out="$(exec jq -rs 'def s: if type == "string" then (if explode | index(0) then error("nul") else . end) elif . == null or . == false then "" else error("type") end;
    (if length == 1 then .[0] else error("stream") end) | (.tool_input // {}) as $i
    | @sh "HF_CWD=\(.cwd | s) HF_TOOL=\(.tool_name | s) HF_PATH=\($i.file_path | s) HF_CMD=\($i.command | s)"' <<<"$PAYLOAD" 2>/dev/null)" || return 1
  case "$out" in HF_CWD=*) ;; *) return 1 ;; esac
  eval "$out"   # @sh met chaque valeur entre guillemets simples
  chomp HF_CWD; chomp HF_TOOL; chomp HF_PATH; chomp HF_CMD
  HOOK_CWD="${HF_CWD:-$HOOK_HERE}"; GUARD_FIELDS=ok
}
chomp() { # <variable> : sans ses retours à la ligne finaux, comme une substitution de commande — qui les retire dès qu'il y en a plus
  # d'un (un à un, 10 000 retours recopieraient la valeur 10 000 fois : 7 s, au-delà du délai du crochet)
  local v="${!1}"
  case "$v" in *$'\n\n') v="$(printf '%s' "$v")" ;; *$'\n') v="${v%$'\n'}" ;; *) return 0 ;; esac
  printf -v "$1" '%s' "$v"
}

# ---------- verrou de session ----------
# guard_fast_root <dossier> : GF_ROOT, la racine de son dépôt (dossier physique), vide hors dépôt ; rc 1 au moindre doute sur ce que
# git répondrait (variables de git, dossier illisible, intérieur d'un .git)
guard_fast_root() {
  local d
  GF_ROOT=''
  [ -z "${GIT_DIR:-}${GIT_WORK_TREE:-}${GIT_COMMON_DIR:-}${GIT_CEILING_DIRECTORIES:-}" ] || return 1
  case "$1" in /*) ;; *) return 1 ;; esac
  cd -P "$1" >/dev/null 2>&1 || return 1
  d="$PWD"; cd "$HOOK_HERE" >/dev/null 2>&1 || true
  case "$d/" in *.git/*) return 1 ;; esac
  while :; do
    if [ -f "$d/.git" ] || [ -f "$d/.git/HEAD" ] || [ -L "$d/.git/HEAD" ]; then GF_ROOT="$d"; return 0; fi
    if [ -e "$d/.git" ] || [ -L "$d/.git" ]; then return 1; fi   # ni fichier gitdir ni dossier git : git seul saurait
    [ -n "$d" ] && [ "$d" != / ] || return 0
    d="${d%/*}"
  done
}
# guard_fast_lock <outil> : rc 0 si hook_lock_resume (lib/hooks.sh) n'aurait rien à faire ni à refuser — hors dépôt, verrou tenu par
# l'agent qui lance ce crochet (son parent direct ; un seul ps si un shell s'interpose), ou, pour Bash que le verrou ne refuse jamais,
# tenu par un processus vivant ; aucune question ni autorisation en attente à effacer
guard_fast_lock() {
  local held parent
  [ "${LAB_DRY:-0}" != 1 ] || return 1
  guard_fast_root "${CLAUDE_PROJECT_DIR:-$HOOK_CWD}" || return 1
  [ -n "$GF_ROOT" ] || return 0
  kv_value "$GF_ROOT/.lab/waits-for" kind || true
  case "$KV_VALUE" in question|permission) return 1 ;; esac
  kv_value "$GF_ROOT/.lab/session.lock" pid || return 1
  held="$KV_VALUE"
  case "$held" in ''|0*|*[!0123456789]*) return 1 ;; esac
  [ "$held" != "$PPID" ] || return 0
  if [ "$1" = Bash ] && kill -0 "$held" 2>/dev/null; then return 0; fi
  parent="$(exec ps -o ppid= -p "$PPID" 2>/dev/null)" || return 1
  [ "${parent// /}" = "$held" ]
}

# ---------- pré-filtres, communs aux deux chemins ----------
# guard_bash_ordinary <commande> : rc 0 si aucune règle ne peut la viser — ni git, ni rm, ni mise en ligne, ni migration, ni fusion,
# ni envoi cmux, ni Docker (lot 02 de docker-menage), ni le premier mot d'une deploy.<cible> déclarée. Pose DEPLOY_SIGS
guard_bash_ordinary() {
  deploy_sigs_set
  case "$1" in
    *git*|*rm*|*deploy*|*publish*|*rsync*|*vercel*|*migrations*|*supabase*|*"pr merge"*|*/merge*|*mergePullRequest*|*LAB_AGENT_SCAN*|*cmux*|*cmx*|*docker*) return 1 ;;
    # lot 02 du couloir app-treelab : la commande du fork peut porter un autre nom — tout envoi de texte passe par le chemin complet
    *send*|*paste*|*set-buffer*) return 1 ;;
  esac
  ! deploy_sig_hint "$1"
}
# guard_target_path <cible> : GT_PATH, son chemin absolu normalisé ; rc 1 s'il dépend d'un « .. » (un lien avant lui change le sens)
guard_target_path() {
  local full="$1"
  case "$full" in /*) ;; *) full="$HOOK_CWD/$full" ;; esac
  case "/$full/" in */../*) return 1 ;; esac
  case "/$HOOK_CWD/" in */../*) return 1 ;; esac
  case "$full" in /*) ;; *) return 1 ;; esac
  lexical_set "$full"; GT_PATH="$LEXICAL"
}
# target_off_context <cible> : rc 0 si son nom n'est celui d'aucun fichier de contexte protégé (AGENTS.md, CLAUDE.md, MEMORY.md,
# notes.md, .claude/rules/*.md) — context_target (lib/hooks.sh) n'a rien à chercher dans les projets. rc 1 au moindre doute
target_off_context() {
  local d
  guard_target_path "$1" || return 1
  case "$GT_PATH" in */AGENTS.md|*/CLAUDE.md|*/MEMORY.md|*/notes.md) return 1 ;; esac
  case "$GT_PATH" in *.[mM][dD]) ;; *) return 0 ;; esac
  # une règle : son dossier s'appelle rules, tel qu'écrit ou tel que le dossier de travail le résout (lien, casse du disque)
  d="${GT_PATH%/*}"
  case "$d" in */[rR][uU][lL][eE][sS]) return 1 ;; esac
  cd -P "$HOOK_CWD" >/dev/null 2>&1 || return 1
  d="$PWD"; cd "$HOOK_HERE" >/dev/null 2>&1 || true
  case "$d" in */[rR][uU][lL][eE][sS]) return 1 ;; esac
  return 0
}
# target_off_state <cible> : rc 0 si elle ne peut pas être sous l'état de lab ($LAB_STATE), seul refus de guard_state_target
# (lib/hooks.sh) : ni son chemin écrit, ni aucun de ses dossiers parents, écrits ou réels, n'est l'état. rc 1 au moindre doute
# (lien final, dossier, état absent)
target_off_state() {
  local d x
  [ -n "${LAB_STATE:-}" ] || return 0
  [ -d "$LAB_STATE" ] || return 1
  guard_target_path "$1" || return 1
  lexical_set "$LAB_STATE"
  case "$GT_PATH" in "$LEXICAL"|"$LEXICAL"/*) return 1 ;; esac
  [ ! -L "$GT_PATH" ] && [ ! -d "$GT_PATH" ] || return 1
  d="${GT_PATH%/*}"
  while [ -n "$d" ] && [ ! -d "$d" ]; do d="${d%/*}"; done
  x="$d"; while [ -n "$x" ]; do [ ! "$x" -ef "$LAB_STATE" ] || return 1; x="${x%/*}"; done
  cd -P "${d:-/}" >/dev/null 2>&1 || return 1
  x="$PWD"; cd "$HOOK_HERE" >/dev/null 2>&1 || true
  while [ -n "$x" ] && [ "$x" != / ]; do [ ! "$x" -ef "$LAB_STATE" ] || return 1; x="${x%/*}"; done
  [ ! / -ef "$LAB_STATE" ]
}

# ---------- les deux chemins ----------
guard_load() { local f; for f in "$@"; do . "$LAB_ROOT/lib/$f.sh"; done; }
# guard_ordinary <guard-tool|guard-bash> : rc 0 si le chemin complet autoriserait sans rien écrire
guard_ordinary() {
  if [ "$1" = guard-tool ]; then
    guard_fast_lock "$HF_TOOL" || return 1
    # shellcheck disable=SC2034 # lu par hook_guard_tool (lib/hooks.sh)
    GUARD_LOCK=ok
    case "$HF_TOOL" in
      Bash) ;;
      Write|Edit)
        [ "${LAB_FORCE:-0}" != 1 ] && [ -n "$HF_PATH" ] || return 0
        target_off_state "$HF_PATH" && target_off_context "$HF_PATH"; return ;;
      apply_patch) return 1 ;;
      *) return 0 ;;
    esac
  fi
  [ -n "$HF_CMD" ] || return 0
  guard_bash_ordinary "$HF_CMD"
}
# guard_main <guard-tool|guard-bash> : le crochet entier. Le chemin complet continue dans ce processus, avec les seules bibliothèques
# que la garde utilise (leur fermeture est contrôlée par tests/hooks.bats) ; set -e et set -u comme bin/lab, dont il reprend le rôle
guard_main() {
  CDPATH=''   # comme hooks/*.sh, pour « lab hook » lancé à la main
  guard_load kv
  if [ -z "${LAB_HOME:-}" ] && [ ! -f "$LAB_ROOT/.release" ]; then   # checkout : LAB_HOME est la racine, dans sa casse réelle (bin/lab)
    guard_load git; real_path_set "$LAB_ROOT"; LAB_ROOT="$REAL_PATH"
  fi
  guard_load project
  if guard_fields && guard_ordinary "$1"; then exit 0; fi
  set -euo pipefail
  guard_load log git lock codex words tower terminal hooks
  # shellcheck disable=SC2034 # lu par git_places (lib/git.sh)
  GP_MEMO=1
  cmd_hook "$1"
}

# session_main : le crochet de démarrage, avec les seules bibliothèques qu'il utilise (leur fermeture est contrôlée par tests/hooks.bats) ;
# les mêmes en mode mesure (LAB_DRY=1) : une bibliothèque absente change la réponse sans un mot (la recette lit sync_ref, revue du lot 02)
session_main() {
  CDPATH=''
  guard_load kv
  if [ -z "${LAB_HOME:-}" ] && [ ! -f "$LAB_ROOT/.release" ]; then guard_load git; real_path_set "$LAB_ROOT"; LAB_ROOT="$REAL_PATH"; fi   # comme guard_main
  export LAB_ROOT
  set -euo pipefail
  guard_load log git project lock docs recette merge watch tower cmux cloud sync migrations ressource deploy night entitlement hooks
  # [pid du crochet] : hooks/session-start.sh passe le sien — les ancêtres se lisent depuis lui, comme depuis « bin/lab hook », son
  # enfant avant #239 : sans agent, le verrou est au crochet, mort à la fin, pas à son lanceur vivant (nuit rouge du 2026-11-24) ;
  # « bin/lab hook session-start » n'en passe pas : $PPID, son lanceur, comme avant. Non exportée : lib/lock.sh l'a retirée de
  # l'environnement à son chargement
  # shellcheck disable=SC2034 # lu par agent_pid_found (lib/lock.sh)
  LAB_AGENT_FROM="${1:-}"
  cmd_hook session-start
}

# ---------- notify (prompt envoyé, fin de tour) ----------
# notify_fields : PAYLOAD, HN_EVENT, HN_TRANSCRIPT, HN_PROMPT, HOOK_CWD et HN_WORDS (no : un prompt en ASCII sans aucun des mots de
# words_maybe ; perl : lui seul peut dire), par un seul jq ; rc 1 si la charge n'est pas celle attendue
notify_fields() {
  local out
  PAYLOAD="$(exec cat 2>/dev/null)" || true
  # shellcheck disable=SC2016 # programme jq littéral
  out="$(exec jq -rs 'def s: if type == "string" then (if explode | index(0) then error("nul") else . end) elif . == null or . == false then "" else error("type") end;
    (if length == 1 then .[0] else error("stream") end) | (.prompt | s) as $p
    | (if ($p | explode | any(.[]; . > 127 or . < 9)) or ($p | ascii_downcase | . as $l | any(("ferm", "clo", "recett", "accept", "approuv", "approve", "valide"); . as $w | $l | contains($w)))
       then "perl" else "no" end) as $w
    | @sh "HN_EVENT=\(.hook_event_name | s) HN_CWD=\(.cwd | s) HN_TRANSCRIPT=\(.transcript_path | s) HN_PROMPT=\($p) HN_WORDS=\($w)"' \
    <<<"$PAYLOAD" 2>/dev/null)" || return 1
  case "$out" in HN_EVENT=*) ;; *) return 1 ;; esac
  eval "$out"
  chomp HN_EVENT; chomp HN_CWD; chomp HN_TRANSCRIPT; chomp HN_PROMPT
  HOOK_CWD="${HN_CWD:-$HOOK_HERE}"
}
# notify_ordinary : rc 0 après avoir fait ce que hook_notify (lib/hooks.sh) fait d'un prompt qui ne parle ni de recette ni de
# fermeture, ou d'une fin de tour : transcript rangé, attente effacée. rc 1 sans rien écrire pour tout autre événement, ou un doute
notify_ordinary() {
  case "$HN_EVENT" in UserPromptSubmit|Stop) ;; *) return 1 ;; esac
  guard_fast_root "${CLAUDE_PROJECT_DIR:-$HOOK_CWD}" || return 1
  [ -n "$GF_ROOT" ] || return 0
  [ -d "$GF_ROOT/.lab" ] || return 1
  guard_load tower
  if [ "$HN_EVENT" = UserPromptSubmit ] && [ "$HN_WORDS" != no ]; then
    guard_load words
    ! words_maybe "$HN_PROMPT" || return 1
  fi
  transcript_note "$GF_ROOT" "$HN_TRANSCRIPT" 2>/dev/null || true
  if [ "$HN_EVENT" = Stop ]; then waits_clear_answered "$GF_ROOT" 2>/dev/null || true
  else waits_clear "$GF_ROOT" 2>/dev/null || true; fi
}
# notify_main : le crochet entier ; sur stdout, la seule ligne JSON hookSpecificOutput du chemin complet
notify_main() {
  local out line
  guard_load kv
  if notify_fields && notify_ordinary; then return 0; fi
  out="$(printf '%s' "$PAYLOAD" | "$LAB_ROOT/bin/lab" hook notify 2>/dev/null)" || true
  while IFS= read -r line; do
    case "$line" in '{"hookSpecificOutput":'*) printf '%s\n' "$line"; return 0 ;; esac
  done <<<"$out"
  return 0
}
