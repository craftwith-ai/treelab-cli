# shellcheck shell=bash
# project.sh — config par projet : projects/<p>/config (KEY=value), notes.md, include.
declare -F kv_value >/dev/null || . "${BASH_SOURCE[0]%/*}/kv.sh"
# lab_home_default <racine d'un lab> : le LAB_HOME que ce programme prend sans LAB_HOME — une release vit dans ~/.lab, un checkout
# dans son propre dossier
lab_home_default() { if [ -f "$1/.release" ]; then printf '%s\n' "$HOME/.lab"; else printf '%s\n' "$1"; fi; }
# même règle, sans sous-shell : ce fichier est chargé avant chaque outil d'un agent (lib/guard_fast.sh)
if [ -z "${LAB_HOME:-}" ]; then if [ -f "$LAB_ROOT/.release" ]; then LAB_HOME="$HOME/.lab"; else LAB_HOME="$LAB_ROOT"; fi; fi
LAB_PROJECTS="${LAB_PROJECTS_DIR:-$LAB_HOME/projects}"
LAB_STATE="${LAB_STATE_DIR:-$LAB_HOME/state}"
project_dir() { printf '%s/%s\n' "$LAB_PROJECTS" "$1"; }
project_exists() { [ -f "$LAB_PROJECTS/$1/config" ]; }
project_names() { local d; for d in "$LAB_PROJECTS"/*/; do d="${d%/}"; [ -f "$d/config" ] && printf '%s\n' "${d##*/}"; done; }
config_get() { kv_print "$LAB_PROJECTS/$1/config" "$2"; }
memory_file() { printf '%s/projects/%s/memory/MEMORY.md\n' "$(claude_home)" "${1//\//-}"; }
hermetism_forbidden_names() { # <projet> : mêmes exclusions pour le doctor et la garde avant écriture
  local p="$1" o allow
  allow=" $(config_get "$p" hermetisme_allow 2>/dev/null || true) "
  for o in $(project_names); do
    [ "$o" = "$p" ] && continue
    [ "${#o}" -ge 4 ] || continue
    case "$allow" in *" $o "*) continue ;; esac
    printf '%s\n' "$o"
  done
}
project_name_in_text() { # <nom> ; texte sur stdin — littéral, insensible à la casse, borné comme un mot
  LC_ALL=C awk -v needle="$1" '
    BEGIN { needle=tolower(needle); found=0 }
    {
      text=tolower($0); start=1
      while (start <= length(text) && (offset=index(substr(text, start), needle)) > 0) {
        pos=start + offset - 1
        before=(pos == 1 ? "" : substr(text, pos - 1, 1))
        after_pos=pos + length(needle)
        after=(after_pos > length(text) ? "" : substr(text, after_pos, 1))
        if ((before == "" || before !~ /[[:alnum:]_]/) && (after == "" || after !~ /[[:alnum:]_]/)) { found=1; exit }
        start=pos + 1
      }
    }
    END { exit(found ? 0 : 1) }
  '
}
project_name_in_file() { [ -f "$2" ] && project_name_in_text "$1" <"$2"; }
config_set() { registry_locked "$1" config_write "$@"; }   # config_set <p> <key> <value>
config_write() {
  local f; f="$(project_dir "$1")/config"; mkdir -p "$(dirname "$f")"; touch "$f"
  if grep -q "^$2=" "$f"; then
    local tmp; tmp="$(mktemp)"; sed "s|^$2=.*|$2=$3|" "$f" >"$tmp" && mv "$tmp" "$f"
  else printf '%s=%s\n' "$2" "$3" >>"$f"; fi
}
# registry_locked <p> <commande…> (lot-01 de sans-perte) : une écriture du registre d'un projet (config, echeances) relit puis réécrit
# le fichier entier ; deux écritures simultanées gardaient chacune leur copie et la dernière effaçait l'autre. La commande tourne
# dans un sous-shell, sous set -e, pendant que ce lab tient le fichier de registry_lock_file (son pid, operation_try de lib/lock.sh),
# rendu à toute sortie du sous-shell (die compris) ; un détenteur prouvé mort est repris, un vivant attendu LAB_REGISTRY_WAIT
# secondes (10 par défaut), puis refus sans écriture. Verrou dédié : celui des opérations sert à claim, qu'une écriture du registre
# ne retarde jamais. Jamais imbriqué : le même lab attendrait son propre verrou.
registry_locked() {
  local p="$1" file tries rc=0 e=0; shift
  file="$(registry_lock_file "$p" 2>/dev/null)" || die "registry lock unavailable for $p (lib/lock.sh not loaded, or doubtful locks folder): nothing written"
  tries=$(( ${LAB_REGISTRY_WAIT:-10} * 10 ))
  while :; do
    rc=0; operation_try "$file" || rc=$?
    [ "$rc" = 1 ] && [ "$tries" -gt 0 ] || break
    tries=$((tries - 1)); sleep 0.1
  done
  case "$rc" in
    0) ;;
    1) die "registry of $p busy with pid $(cat "$file" 2>/dev/null || printf '?') for more than ${LAB_REGISTRY_WAIT:-10} s ($file): nothing written — run again once it is done" ;;
    *) die "doubtful registry lock: $file (link, other owner or unreadable content) — nothing written; check it, then remove it" ;;
  esac
  case "$-" in *e*) e=1 ;; esac
  set +e; ( set -e; "$@" ); rc=$?; [ "$e" = 0 ] || set -e   # un « || » devant le sous-shell y éteindrait set -e
  [ "$(cat "$file" 2>/dev/null)" != "$$" ] || rm -f "$file"
  return "$rc"
}
# registry_lock_file <p> → le verrou du registre de ce projet : dossier technique des opérations (hors du dépôt des fiches, privé),
# nom dérivé du chemin réel de LAB_PROJECTS — deux lab aux LAB_HOME différents sur le même registre s'excluent aussi
registry_lock_file() {
  local dir key
  operation_paths || return 1
  dir="$LAB_OPERATION_DIRECTORY"; [ ! -L "$dir" ] || return 1
  if [ ! -d "$dir" ]; then (umask 077; mkdir "$dir") 2>/dev/null || [ -d "$dir" ] || return 1; fi
  [ "$(stat -f %u "$dir")" = "$(id -u)" ] && [ "$(stat -f %Lp "$dir")" = 700 ] || return 1
  key="$(printf '%s/%s' "$(real_path "$LAB_PROJECTS")" "$1" | shasum -a 256 | cut -c1-16)" || return 1
  printf '%s/registre.%s\n' "$dir" "$key"
}
# config_into <variable> <clé> : la valeur lue dans $file (load_project), sans processus
config_into() { kv_value "$file" "$2" || true; printf -v "$1" '%s' "$KV_VALUE"; }
# Charge la config dans P_* (valeurs par défaut sûres).
load_project() {
  project_exists "$1" || die "unknown project: $1 (run lab init $1 from its checkout)"
  local file="$LAB_PROJECTS/$1/config"
  P_NAME="$1"
  config_into P_ROOT root
  config_into P_REMOTE remote; P_REMOTE="${P_REMOTE:-origin}"
  config_into P_OWNER owner; P_OWNER="${P_OWNER:-shared}"
  config_into P_BASE base; P_BASE="${P_BASE:-main}"
  config_into P_STAGING staging
  config_into P_MERGE_METHOD merge_method; P_MERGE_METHOD="${P_MERGE_METHOD:-squash}"
  config_into P_INSTALL install
  config_into P_DOCS docs; P_DOCS="${P_DOCS:-local}"
  config_into P_AGENT agent   # valeur de la config du projet seulement : agent_resolve décide du défaut (lot 03)
  config_into P_DEV dev
  config_into P_TEST test
  # déclarations du projet (lot 18) : ressources partagées entre couloirs, motifs de fichiers générés et commande qui les refait
  config_into P_RESOURCES resources; config_into P_GENERATED generated; config_into P_REGEN regen
  config_into P_MIGRATIONS migrations   # dossiers de migrations numérotées (lot 02 de sans-perte) : collisions refusées
  [ -d "$P_ROOT" ] || die "main checkout not found: $P_ROOT"
  export P_NAME P_ROOT P_REMOTE P_OWNER P_BASE P_STAGING P_MERGE_METHOD P_INSTALL P_DOCS P_AGENT P_DEV P_TEST P_RESOURCES P_GENERATED P_REGEN P_MIGRATIONS
}
# Cible unique des PR : staging lorsqu'elle existe, sinon la branche principale.
pr_base() { if [ -n "$P_STAGING" ]; then printf '%s\n' "$P_STAGING"; else printf '%s\n' "$P_BASE"; fi; }
project_by_root() { project_by_root_set "$1" && printf '%s\n' "$FOUND_PROJECT"; } # project_by_root <chemin de checkout principal>
# project_by_root_set <checkout principal> : FOUND_PROJECT, sans processus quel que soit le nombre de projets ; rc 1, vide, si aucun
project_by_root_set() {
  local d
  FOUND_PROJECT=''
  for d in "$LAB_PROJECTS"/*/; do
    d="${d%/}"
    if ! kv_value "$d/config" root || [ -z "$KV_VALUE" ]; then continue; fi
    if same_path "$KV_VALUE" "$1"; then FOUND_PROJECT="${d##*/}"; return 0; fi
  done
  return 1
}
project_from_cwd() { project_from_cwd_set "${1:-$PWD}" && printf '%s\n' "$FOUND_PROJECT"; }
project_from_cwd_set() { FOUND_PROJECT=''; git_places "$1" && project_by_root_set "$GP_MAIN"; }   # même recherche, dans FOUND_PROJECT
# ---------- agent par défaut : une seule règle, option > couloir > projet > global > défaut (constat 5 du brief, lot 03) ----------
# global_config_get <clé> : $LAB_HOME/config, KEY=value comme la config d'un projet ; fichier édité à la main, jamais par lab.
global_config_get() { [ -f "$LAB_HOME/config" ] || return 0; kv_print "$LAB_HOME/config" "$1"; }
# agent_resolve <wt|-> [valeur de --agent] → « <agent><TAB><source> » : option, couloir (.lab/meta), projet (projects/<p>/config),
# global ($LAB_HOME/config) ou défaut (claude). Une lecture ne refuse rien : agent_note dit si la valeur est acceptable.
agent_resolve() { agent_resolve_set "$@"; printf '%s\t%s\n' "$AGENT_NAME" "$AGENT_SOURCE"; }
agent_resolve_set() { # les mêmes arguments : AGENT_NAME et AGENT_SOURCE, sans processus
  local wt="${1:-}"
  AGENT_SOURCE=option; AGENT_NAME="${2:-}"; [ -z "$AGENT_NAME" ] || return 0
  if [ -n "$wt" ] && [ "$wt" != - ]; then kv_value "$wt/.lab/meta" agent || true; AGENT_SOURCE=lane; AGENT_NAME="$KV_VALUE"; [ -z "$AGENT_NAME" ] || return 0; fi
  AGENT_SOURCE=project; AGENT_NAME="${P_AGENT:-}"; [ -z "$AGENT_NAME" ] || return 0
  kv_value "$LAB_HOME/config" agent || true; AGENT_SOURCE=global; AGENT_NAME="$KV_VALUE"; [ -z "$AGENT_NAME" ] || return 0
  AGENT_SOURCE=default; AGENT_NAME=claude
}
agent_source_file() { # <source> <wt|-> → le fichier lu pour cette source (vide pour option et défaut)
  case "$1" in lane) printf '%s/.lab/meta\n' "$2" ;; project) printf '%s/config\n' "$(project_dir "$P_NAME")" ;; global) printf '%s/config\n' "$LAB_HOME" ;; esac
}
# agent_note <agent> <source> <wt|-> → le refus à prononcer si la valeur n'est ni claude ni codex (fichier et valeur nommés), sinon rien
agent_note() {
  case "$1" in claude|codex) return 0 ;; esac
  case "$2" in
    option|default) printf 'unknown agent: %s (expected claude or codex)\n' "$1" ;;
    *) printf 'agent "%s" read in %s: expected claude or codex\n' "$1" "$(agent_source_file "$2" "$3")" ;;
  esac
}
# ---------- règle cloud=yes|no (lot 03 de cmux-pro) : couloir (.lab/meta) > projet > global ($LAB_HOME/config, lu seulement) > yes ----------
# cloud_resolve <p> [<wt>|-] → pose CLOUD, CLOUD_SOURCE (couloir|projet|global|défaut) et CLOUD_FILE (fichier lu, vide pour défaut).
# Une lecture ne refuse rien : cloud_note juge. Aucune réponse n'est attendue (lot 01 d'aiguillage-cloud) : la fiche choisit.
cloud_resolve() {
  local p="$1" wt="${2:--}" v
  if [ "$wt" != - ]; then
    kv_value "$wt/.lab/meta" cloud || true; v="$KV_VALUE"; if [ -n "$v" ]; then CLOUD="$v"; CLOUD_SOURCE=lane; CLOUD_FILE="$wt/.lab/meta"; return; fi
  fi
  kv_value "$LAB_PROJECTS/$p/config" cloud || true; v="$KV_VALUE"; if [ -n "$v" ]; then CLOUD="$v"; CLOUD_SOURCE=project; CLOUD_FILE="$LAB_PROJECTS/$p/config"; return; fi
  kv_value "$LAB_HOME/config" cloud || true; v="$KV_VALUE"; if [ -n "$v" ]; then CLOUD="$v"; CLOUD_SOURCE=global; CLOUD_FILE="$LAB_HOME/config"; return; fi
  CLOUD=yes; CLOUD_SOURCE=default; CLOUD_FILE=""
}
# cloud_note → le refus à prononcer si la valeur résolue n'est ni yes ni no (fichier et valeur nommés), sinon rien
cloud_note() { case "$CLOUD" in yes|no) ;; *) printf 'cloud "%s" read in %s: expected yes or no\n' "$CLOUD" "$CLOUD_FILE" ;; esac; }
# cloud_display <p> [<wt>|-] → « yes (project) », « yes (default) » ; une valeur invalide est nommée sur stderr, sans arrêt
cloud_display() { cloud_display_set "$@"; printf '%s\n' "$CLOUD_DISPLAY"; }
cloud_display_set() { # les mêmes arguments : CLOUD_DISPLAY, sans processus pour une valeur valide
  cloud_resolve "$@"
  case "$CLOUD" in yes|no) ;; *) warn "$(cloud_note)" ;; esac
  CLOUD_DISPLAY="$CLOUD ($CLOUD_SOURCE)"
}
config_unset() { registry_locked "$1" config_drop "$@"; }   # config_unset <p> <key>
config_drop() { local f tmp; f="$(project_dir "$1")/config"; tmp="$(mktemp "$f.XXXXXX")"; grep -v "^$2=" "$f" >"$tmp" || true; mv "$tmp" "$f"; }
# resolve_project [nom] : nom explicite, sinon déduit du dossier courant.
resolve_project() {
  local p="${1:-}"
  if [ -n "$p" ] && project_exists "$p"; then printf '%s\n' "$p"; return; fi
  if [ -z "$p" ] || [ -d "$p" ]; then project_from_cwd "${p:-$PWD}" && return; fi
  die "unknown project: ${p:-<current folder>}"
}
worktree_path() { printf '%s/.worktrees/%s\n' "$P_ROOT" "$1"; }
# .lab/meta du couloir : kind, base, agent, created, project, start, lane, lot (lot 9 : un worktree = un couloir, une branche par lot)
wt_meta() { kv_print "$1/.lab/meta" "$2"; }
meta_set() { # meta_set <wt> <clé> <valeur>
  local f="$1/.lab/meta" tmp; mkdir -p "$1/.lab"; touch "$f"
  if grep -q "^$2=" "$f"; then tmp="$(mktemp)"; sed "s|^$2=.*|$2=$3|" "$f" >"$tmp" && mv "$tmp" "$f"; else printf '%s=%s\n' "$2" "$3" >>"$f"; fi
}
meta_unset() { # meta_unset <wt> <clé>
  local f="$1/.lab/meta" tmp; [ -f "$f" ] || return 0
  tmp="$(mktemp "$f.XXXXXX")"; grep -v "^$2=" "$f" >"$tmp" || true; mv "$tmp" "$f"
}
# lane_permanent <wt> : couloir marqué permanent (lot 01 d'autonomie-tours) — il enchaîne ses lots livrés par PR, n'entre jamais en
# recette, n'est jamais retiré ni fermé ; posé par lab permanent ou lab new --permanent, dans .lab/meta seulement
lane_permanent() { kv_value "$1/.lab/meta" permanent || true; lang_code_set "$KV_VALUE"; [ "$LANG_CODE" = yes ]; }   # « oui » écrit à la main se lit par la table de lib/lang.sh
wt_lane() { wt_lane_set "$1"; printf '%s\n' "$WT_LANE"; }
WL_FOR='' WL_LANE='' FACTS_DEPTH=0   # mémoire d'une lecture groupée (lib/facts.sh), jamais héritée de l'environnement
wt_lane_set() { # <wt> : WT_LANE, lu une fois de suite par couloir dans une lecture groupée
  local d="${1%/}"
  if [ "$FACTS_DEPTH" != 0 ] && [ "$WL_FOR" = "$1" ]; then WT_LANE="$WL_LANE"; return 0; fi
  kv_value "$1/.lab/meta" lane || true; WT_LANE="${KV_VALUE:-${d##*/}}"; WL_FOR="$1"; WL_LANE="$WT_LANE"
}
# docs_dir <worktree> : dans le dépôt (docs=repo, posé par lab new dans le worktree) ou local (_lab/projects/<p>/docs). owner ne décide jamais de docs (lot 8).
docs_dir() { docs_dir_set "$1"; printf '%s\n' "$DOCS_DIR"; }
docs_dir_set() { if [ "$P_DOCS" = repo ]; then DOCS_DIR="$1/docs"; else DOCS_DIR="$LAB_PROJECTS/$P_NAME/docs"; fi; }   # <wt> : DOCS_DIR
state_dir() { local d="$LAB_STATE/${1:-}"; mkdir -p "$d"; printf '%s\n' "$d"; }
