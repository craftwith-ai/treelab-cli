# shellcheck shell=bash
# git.sh — primitives git partagées par la CLI et les hooks.
repo_root() { git -C "${1:-$PWD}" rev-parse --show-toplevel 2>/dev/null; }
# git_places <dossier> : GP_TOP, racine du worktree, GP_COMMON, dossier git commun (absolu), et GP_MAIN, le checkout principal — un
# seul git pour les trois (lot 01 de charge-processeur) ; rc 1 hors dépôt. La garde, qui vit le temps d'un outil, pose GP_MEMO=1 :
# le dossier déjà lu ne relance pas git. Une commande longue ne le pose jamais : le dépôt peut y changer
git_places() {
  local out dir="$1"
  if [ "${GP_MEMO:-0}" = 1 ] && [ "${GP_FOR:-}" = "$dir" ]; then return "$GP_RC"; fi
  GP_FOR="$dir"; GP_RC=1; GP_TOP=''; GP_COMMON=''; GP_MAIN=''
  out="$(exec git -C "$dir" rev-parse --show-toplevel --git-common-dir 2>/dev/null)" || return 1
  GP_TOP="${out%%$'\n'*}"; GP_COMMON="${out#*$'\n'}"
  case "$GP_COMMON" in *$'\n'*)   # un nom de dossier qui porte un retour à la ligne : chaque réponse à part
    GP_TOP="$(exec git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || { GP_TOP=''; GP_COMMON=''; return 1; }
    GP_COMMON="$(exec git -C "$dir" rev-parse --git-common-dir 2>/dev/null)" || { GP_TOP=''; GP_COMMON=''; return 1; } ;;
  esac
  case "$GP_COMMON" in
    /*) ;;
    # relatif au dossier lu : le .git du checkout principal. Jamais un cd dans ce shell (dossier de départ retiré), ni un nom que
    # CDPATH irait chercher ailleurs (revue du lot 01 de charge-processeur)
    *) if [ ! -L "$GP_TOP/.git" ] && [ "$GP_TOP/.git" -ef "$dir/$GP_COMMON" ]; then GP_COMMON="$GP_TOP/.git"
       else GP_COMMON="$(CDPATH=''; cd "$dir" && cd -P "./$GP_COMMON" && printf '%s\n' "$PWD")" || { GP_TOP=''; GP_COMMON=''; return 1; }; fi ;;
  esac
  GP_MAIN="${GP_COMMON%/*}"; GP_MAIN="${GP_MAIN:-/}"; GP_RC=0
}
common_git_dir() { git_places "${1:-$PWD}" || return 1; printf '%s\n' "$GP_COMMON"; }
# Checkout principal (celui qui possède le .git) du dépôt contenant $1.
main_root() { git_places "${1:-$PWD}" || return 1; printf '%s\n' "$GP_MAIN"; }
# real_path <chemin> : liens résolus ET casse réelle du disque. Sur macOS (FS insensible à la casse), `pwd -P` de bash 3.2 garde la casse
# du cwd : lancé depuis le chemin du dépôt tapé en minuscules, install.sh posait liens et hooks Codex en minuscules (hash d'approbation changé — lot 10, 2026-09-03).
# `stat -f %R` (BSD) rend la casse réelle ; GNU stat (coreutils) prend %R pour un fichier et imprime un bloc statfs sur stdout en
# échouant : sa sortie n'est gardée que si c'est le même dossier. Un chemin qui n'existe pas est rendu tel quel.
real_path() {
  local p r; p="$(cd "$1" 2>/dev/null && pwd -P)" || p="$1"
  r="$(exec stat -f %R "$p" 2>/dev/null)" || r=''
  if [ -n "$r" ] && [ -d "$r" ] && [ "$r" -ef "$p" ]; then printf '%s\n' "$r"; else printf '%s\n' "$p"; fi
}
# real_path_set <chemin> : REAL_PATH = real_path, sans sous-shell — un seul processus (stat) ; le dossier courant est rendu. Pour la
# garde seule, qui vit le temps d'un outil (guard_main vide CDPATH) : un dossier de départ retiré ne se retrouve pas
real_path_set() {
  local here="$PWD" r
  if cd "$1" >/dev/null 2>&1; then
    cd -P . >/dev/null 2>&1 || true
    REAL_PATH="$PWD"; cd "$here" >/dev/null 2>&1 || true
  else REAL_PATH="$1"; fi
  r="$(exec stat -f %R "$REAL_PATH" 2>/dev/null)" || r=''
  if [ -n "$r" ] && [ -d "$r" ] && [ "$r" -ef "$REAL_PATH" ]; then REAL_PATH="$r"; fi
}
# same_path <a> <b> : même texte, ou même dossier (liens et casse du disque compris), sans processus. Deux fichiers ne se comparent
# que par leur texte, et un chemin vide vaut le dossier courant, comme real_path
same_path() {
  local a="${1:-.}" b="${2:-.}"
  [ "$a" = "$b" ] || { [ -d "$a" ] && [ -d "$b" ] && [ "$a" -ef "$b" ]; }
}
# resolve_file <chemin> : cible absolue, éventuellement absente si son parent existe.
# Parcours composant par composant : le plafond de 40 inclut les liens des parents.
# Aucun chemin n'est imprimé avant le succès ; aucune écriture, même sur lien cassé.
resolve_file() {
  local pending="${1:-}" resolved part rest more candidate target links=0
  [ -n "$pending" ] || return 1
  case "$pending" in /*) resolved=/ ;; *) resolved="$(pwd -P)" || return 1 ;; esac
  while [ -n "$pending" ]; do
    case "$pending" in
      */*) part="${pending%%/*}"; rest="${pending#*/}"; more=1 ;;
      *) part="$pending"; rest=""; more=0 ;;
    esac
    pending="$rest"
    case "$part" in
      ''|.) continue ;;
      ..) resolved="${resolved%/*}"; resolved="${resolved:-/}"; continue ;;
    esac
    candidate="${resolved%/}/$part"
    if [ -L "$candidate" ]; then
      links=$((links + 1)); [ "$links" -le 40 ] || return 1
      target="$(readlink "$candidate")" || return 1
      [ -n "$target" ] || return 1
      case "$target" in /*) resolved=/ ;; esac
      pending="$target"; [ "$more" -eq 0 ] || pending="$pending/$rest"
    elif [ "$more" -eq 1 ]; then
      resolved="$(cd "$candidate" 2>/dev/null && pwd -P)" || return 1
    else
      resolved="$candidate"
    fi
  done
  [ ! -d "$resolved" ] || return 1
  printf '%s\n' "$resolved"
}
is_worktree() { git_places "$1" && ! same_path "$GP_TOP" "$GP_MAIN"; }
branch_name() { git -C "${1:-$PWD}" branch --show-current 2>/dev/null || true; }
is_clean() { [ -z "$(git -C "$1" status --porcelain --untracked-files=all)" ]; }
# shellcheck disable=SC2034 # DIRTY_LIST est lu par lib/close.sh et bin/lab
# dirty_report <wt> : pose DIRTY_TRACKED (suivis modifiés ou indexés) et DIRTY_UNTRACKED (non suivis), un chemin par ligne, et
# DIRTY_LIST (les deux, « a, b, c ») ; rc 1 si un fichier suivi est modifié — lui seul bloque (lot 17)
dirty_report() {
  local st; st="$(git -C "$1" status --porcelain --untracked-files=all 2>/dev/null || true)"
  DIRTY_TRACKED="$(printf '%s\n' "$st" | awk 'NF && substr($0, 1, 2) != "??" {print substr($0, 4)}')"
  DIRTY_UNTRACKED="$(printf '%s\n' "$st" | awk 'substr($0, 1, 2) == "??" {print substr($0, 4)}')"
  DIRTY_LIST="$(printf '%s\n%s\n' "$DIRTY_TRACKED" "$DIRTY_UNTRACKED" | awk 'NF { printf "%s%s", (n++ ? ", " : ""), $0 } END { if (n) printf "\n" }')"
  [ -z "$DIRTY_TRACKED" ]
}
# untracked_warn <wt> <suite> : avertissement nommé si des fichiers non suivis restent, la commande continue ; rc 1 (et rien dit)
# si un fichier suivi est modifié — à l'appelant de refuser en nommant DIRTY_TRACKED
untracked_warn() {
  dirty_report "$1" || return 1
  [ -z "$DIRTY_UNTRACKED" ] || warn "untracked file(s) left in $1: $(printf '%s\n' "$DIRTY_UNTRACKED" | paste -sd, - | sed 's/,/, /g') — $2"
  return 0
}
# untracked_clash <wt> <réf> → « a, b » : fichiers non suivis du couloir que l'arrivée de <réf> écraserait (git refuserait merge ou rebase)
untracked_clash() {
  local u; u="$(git -C "$1" ls-files --others --exclude-standard 2>/dev/null)"; [ -n "$u" ] || return 0
  comm -12 <(printf '%s\n' "$u" | sort -u) <(git -C "$1" diff --name-only HEAD "$2" 2>/dev/null | sort -u) \
    | awk 'NF { printf "%s%s", (n++ ? ", " : ""), $0 } END { if (n) printf "\n" }'
}
dirty_tracked_list() { printf '%s\n' "$DIRTY_TRACKED" | paste -sd, - | sed 's/,/, /g'; }
valid_slug() { [[ "${1:-}" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; }
normalize_slug() {
  valid_slug "$1" || die "invalid slug \"$1\": lowercase letters, digits, hyphens, dots, underscores"
  printf '%s\n' "$1"
}
remote_name() { if git -C "$1" remote 2>/dev/null | grep -qx origin; then printf 'origin\n'; else git -C "$1" remote 2>/dev/null | head -1; fi; }
# sous lab sweep, lues dans les références mémorisées du dépôt (sweep_has_ref, rc 2 sans mémo)
has_remote_branch() { local rc=2; ! command -v sweep_has_ref >/dev/null || { sweep_has_ref "$1" "refs/remotes/${3:-origin}/$2"; rc=$?; }
  [ "$rc" = 2 ] || return "$rc"; git -C "$1" show-ref --verify --quiet "refs/remotes/${3:-origin}/$2"; }
has_local_branch() { local rc=2; ! command -v sweep_has_ref >/dev/null || { sweep_has_ref "$1" "refs/heads/$2"; rc=$?; }
  [ "$rc" = 2 ] || return "$rc"; git -C "$1" show-ref --verify --quiet "refs/heads/$2"; }
default_base() {
  local root="$1" c
  c="$(git -C "$root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"; c="${c#origin/}"
  if [ -n "$c" ]; then printf '%s\n' "$c"; return; fi
  for c in main master production; do
    if has_local_branch "$root" "$c" || has_remote_branch "$root" "$c"; then printf '%s\n' "$c"; return; fi
  done
  return 1
}
ensure_local_ignores() {
  local gitdir exclude entry
  gitdir="$(common_git_dir "$1")" || return 1
  exclude="$gitdir/info/exclude"; mkdir -p "$(dirname "$exclude")"; touch "$exclude"
  # mécanique LAB + config locale des agents (jamais versionnée) ; .mcp.json seulement s'il n'est pas déjà suivi
  local root; root="$(repo_root "$1")"
  for entry in '/.worktrees/' '/.lab/' '/.codex/config.toml' '/.claude/settings.local.json' '/.codex-local/'; do
    grep -Fqx "$entry" "$exclude" || printf '%s\n' "$entry" >>"$exclude"
  done
  if ! git -C "$root" ls-files --error-unmatch .mcp.json >/dev/null 2>&1; then
    grep -Fqx '/.mcp.json' "$exclude" || printf '/.mcp.json\n' >>"$exclude"
  fi
}
# Liste les worktrees : chemin<TAB>branche<TAB>drapeaux (prunable, locked, detached)
worktree_list() {
  git -C "$1" worktree list --porcelain | awk '
    /^worktree /{ if (p) print p "\t" b "\t" f; p=substr($0,10); b=""; f="" }
    /^branch /{ b=substr($0,8); sub("refs/heads/","",b) }
    /^detached/{ f=f "detached," }
    /^prunable/{ f=f "prunable," }
    /^locked/{ f=f "locked," }
    END{ if (p) print p "\t" b "\t" f }'
}
# Dépôt GitHub owner/repo depuis l'URL du remote (git@, https, alias ssh).
repo_slug() {
  local url; url="$(git -C "$1" remote get-url "${2:-origin}" 2>/dev/null)" || return 1
  url="${url%.git}"; url="${url%/}"
  case "$url" in
    https://github.com/*) printf '%s\n' "${url#https://github.com/}" ;;
    *github.com:*) printf '%s\n' "${url#*github.com:}" ;;
    *:*/*) printf '%s\n' "${url#*:}" ;;   # alias ssh « github-perso:owner/repo »
    *) return 1 ;;
  esac
}
# Nombre de commits de $2 absents de $3 (patch-id) ; 0 = tout est déjà en amont.
cherry_count() { git -C "$1" cherry "$3" "$2" 2>/dev/null | grep -c '^+' || true; }
