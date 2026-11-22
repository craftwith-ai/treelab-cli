# shellcheck shell=bash
# git.sh — primitives git partagées par la CLI et les hooks.
repo_root() { git -C "${1:-$PWD}" rev-parse --show-toplevel 2>/dev/null; }
common_git_dir() {
  local root raw
  root="$(repo_root "${1:-$PWD}")" || return 1
  raw="$(git -C "$root" rev-parse --git-common-dir)"
  case "$raw" in /*) printf '%s\n' "$raw" ;; *) (cd "$root/$raw" && pwd -P) ;; esac
}
# Checkout principal (celui qui possède le .git) du dépôt contenant $1.
main_root() { local c; c="$(common_git_dir "${1:-$PWD}")" || return 1; dirname "$c"; }
# real_path <chemin> : liens résolus ET casse réelle du disque. Sur macOS (FS insensible à la casse), `pwd -P` de bash 3.2 garde la casse
# du cwd : lancé depuis le chemin du dépôt tapé en minuscules, install.sh posait liens et hooks Codex en minuscules (hash d'approbation changé — lot 10, 2026-09-03).
# `stat -f %R` (BSD) rend la casse réelle ; GNU stat (coreutils) prend %R pour un fichier et imprime un bloc statfs sur stdout en
# échouant : sa sortie n'est gardée que si c'est le même dossier. Un chemin qui n'existe pas est rendu tel quel.
real_path() {
  local p r; p="$( (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1")"
  r="$(stat -f %R "$p" 2>/dev/null || true)"
  if [ -n "$r" ] && [ -d "$r" ] && [ "$r" -ef "$p" ]; then printf '%s\n' "$r"; else printf '%s\n' "$p"; fi
}
same_path() { [ "$(real_path "$1")" = "$(real_path "$2")" ]; }
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
is_worktree() { [ "$(real_path "$(repo_root "$1")")" != "$(real_path "$(main_root "$1")")" ]; }
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
