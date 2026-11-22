# shellcheck shell=bash
# import.sh — lab setup --import <copie> : reprise d'une installation lab antérieure (lot 08 de lab-enhancement).
# Reconnaissance de la copie, données copiées dans LAB_HOME avant la transaction des intégrations (historique git aux mêmes
# révisions, dossier de travail des fiches, préférence d'agent, état), inventaire des références que la pose ne possède pas.
# La copie n'est jamais écrite : lectures, git sans verrou optionnel, copies. Messages sur stderr, KEY=value sur stdout.

_import_git() { GIT_OPTIONAL_LOCKS=0 git -C "$LAB_SETUP_IMPORT" "$@"; }
_import_refuse() { _setup_message "Import refused: $*"; return 1; }
_import_inside() { case "$2/" in "$1/"*) return 0 ;; esac; return 1; }   # <parent> <chemin> : chemin égal ou intérieur
_import_real() { # <chemin> → chemin réel, suffixe absent compris
  local p="$1" suffix=''
  while ! _txn_exists "$p"; do suffix="/${p##*/}$suffix"; p="${p%/*}"; p="${p:-/}"; done
  p="$(real_path "$p")"; printf '%s\n' "${p%/}$suffix"
}
# import_recognize <copie> : pose LAB_SETUP_IMPORT (chemin réel) et LAB_SETUP_IMPORT_GIVEN ; chaque refus nomme l'élément.
import_recognize() {
  local given="$1" real part home
  case "$LAB_HOME" in /*) ;; *) _import_refuse "LAB_HOME ($LAB_HOME) is not an absolute path; give an absolute path outside the program."; return 1 ;; esac
  case "$given" in /*) ;; *) given="$PWD/$given" ;; esac
  while [ "$given" != / ] && [ "${given%/}" != "$given" ]; do given="${given%/}"; done
  [ ! -L "$given" ] || { _import_refuse "$given is a link; give the real folder of the earlier installation."; return 1; }
  [ -d "$given" ] || { _import_refuse "$given is not a folder."; return 1; }
  real="$(real_path "$given")"
  if _import_inside "$real" "$LAB_ROOT" || _import_inside "$LAB_ROOT" "$real"; then
    _import_refuse "$given is the installed root ($LAB_ROOT) or contains it; give the old copy, separate from the installed program."; return 1
  fi
  for part in bin/lab hooks/session-start.sh templates/global-instructions.md projects; do
    _txn_exists "$real/$part" || { _import_refuse "$given does not look like a lab installation: $part missing."; return 1; }
  done
  [ -d "$real/projects" ] || { _import_refuse "$given/projects is not a folder (registry expected)."; return 1; }
  if ! { [ -d "$real/.git" ] && [ "$(GIT_OPTIONAL_LOCKS=0 git -C "$real" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$real" && pwd -P)" ]; }; then
    _import_refuse "$given/.git missing: the batch file history must be a git repository at the root of the copy."; return 1
  fi
  if ! { GIT_OPTIONAL_LOCKS=0 git -C "$real" symbolic-ref -q HEAD >/dev/null && GIT_OPTIONAL_LOCKS=0 git -C "$real" rev-parse -q --verify HEAD >/dev/null; }; then
    _import_refuse "HEAD of $given is detached or has no commit: put the copy on its main branch."; return 1
  fi
  home="$(_import_real "$LAB_HOME")"
  if _import_inside "$LAB_ROOT" "$home"; then
    _import_refuse "LAB_HOME ($LAB_HOME) is inside the installed root ($LAB_ROOT); choose a LAB_HOME outside the program."; return 1
  fi
  if _import_inside "$real" "$home" || _import_inside "$home" "$real"; then
    _import_refuse "LAB_HOME ($LAB_HOME) and the copy contain each other; the copy is never written, choose a separate LAB_HOME."; return 1
  fi
  if [ "$LAB_PROJECTS" != "$LAB_HOME/projects" ] || [ "$LAB_STATE" != "$LAB_HOME/state" ]; then
    _import_refuse "LAB_PROJECTS_DIR or LAB_STATE_DIR redirected; the import writes projects/ and state/ under LAB_HOME ($LAB_HOME)."; return 1
  fi
  LAB_SETUP_IMPORT="$real"; LAB_SETUP_IMPORT_GIVEN="$given"
  export LAB_SETUP_IMPORT LAB_SETUP_IMPORT_GIVEN
}

# Entrées du registre de la copie qui désignent la copie elle-même : jamais importées.
import_self_names() {
  local config root
  for config in "$LAB_SETUP_IMPORT"/projects/*/config; do
    [ -f "$config" ] || continue
    root="$(sed -n 's/^root=//p' "$config" | head -1)"
    [ -n "$root" ] && [ -d "$root" ] || continue
    [ "$(real_path "$root")" != "$LAB_SETUP_IMPORT" ] || basename "$(dirname "$config")"
  done
}
_import_entries() { # <dossier> <noms exclus séparés par |> → entrées de premier niveau, points compris
  local e
  for e in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    _txn_exists "$e" || continue
    case "|$2|" in *"|${e##*/}|"*) continue ;; esac
    printf '%s\n' "$e"
  done
}
_import_count() { # stdin : entrées → « fichiers octets Kio »
  local entries=() e
  while IFS= read -r e; do entries+=("$e"); done
  if [ "${#entries[@]}" -eq 0 ]; then printf '0 0 0\n'; return; fi
  printf '%s %s\n' \
    "$(find "${entries[@]}" -type f -exec stat -f %z {} + | awk '{n++; s+=$1} END {printf "%.0f %.0f", n, s}')" \
    "$(du -sk "${entries[@]}" | awk '{s+=$1} END {printf "%.0f", s}')"
}
_import_free_kb() { # <chemin> → Kio disponibles sur son volume
  local p="$1"
  while ! _txn_exists "$p"; do p="${p%/*}"; p="${p:-/}"; done
  df -Pk "$p" | awk 'NR == 2 {print $4}'
}
# import_status : LAB_IMPORT_STATE = new ou imported ; refus si LAB_HOME porte d'autres données (jamais de fusion de registres).
import_status() {
  local marker="$LAB_STATE/import.json" source p
  if [ -f "$marker" ]; then
    source="$(jq -r '.source // empty' "$marker" 2>/dev/null || true)"
    if [ "$source" = "$LAB_SETUP_IMPORT" ]; then LAB_IMPORT_STATE=imported; return 0; fi
    _import_refuse "$marker points to another copy (${source:-unreadable}); two registries are never merged."; return 1
  fi
  for p in "$LAB_HOME/.git" "$LAB_HOME/projects" "$LAB_HOME/config" "$LAB_HOME/.gitignore" "$LAB_STATE" "$LAB_HOME"/.treelab-import.*; do
    _txn_exists "$p" || continue
    _import_refuse "$p already exists in LAB_HOME without a finished import; the import never merges two registries. Move this item out of LAB_HOME, then run it again."
    return 1
  done
  LAB_IMPORT_STATE=new
}
# _import_measure : IMPORT_M_* (projets, fichiers, octets, état, historique, Kio requis et libres) ; aucune écriture.
_import_measure() {
  local files state
  IMPORT_M_SELF="$(import_self_names | paste -sd '|' -)"
  files="$(_import_entries "$LAB_SETUP_IMPORT/projects" "$IMPORT_M_SELF" | _import_count)"
  state="$(_import_entries "$LAB_SETUP_IMPORT/state" 'backups|install-manifest.tsv' | _import_count)"
  read -r IMPORT_M_FILES IMPORT_M_BYTES IMPORT_M_KB <<<"$files"
  read -r IMPORT_M_STATE_FILES IMPORT_M_STATE_BYTES IMPORT_M_STATE_KB <<<"$state"
  IMPORT_M_GIT_KB="$(du -sk "$LAB_SETUP_IMPORT/.git" | awk '{print $1}')"
  IMPORT_M_NEEDED=$(( IMPORT_M_KB + IMPORT_M_STATE_KB + IMPORT_M_GIT_KB ))
  IMPORT_M_NEEDED=$(( IMPORT_M_NEEDED + IMPORT_M_NEEDED / 10 + 1024 ))
  IMPORT_M_FREE="$(_import_free_kb "$LAB_HOME")"
  IMPORT_M_PROJECTS="$(import_projects_count "$IMPORT_M_SELF")"
}
_import_space() {
  if ! [[ "$IMPORT_M_FREE" =~ ^[0-9]+$ ]] || [ "$IMPORT_M_FREE" -lt "$IMPORT_M_NEEDED" ]; then
    _import_refuse "not enough space for $LAB_HOME: $IMPORT_M_NEEDED KiB needed (margin included), ${IMPORT_M_FREE:-unknown} KiB free. Free some space, then run it again."
    return 1
  fi
}
# import_plan : chiffres des données (KEY=value) et espace vérifié ; aucune écriture.
import_plan() {
  import_status || return
  kv IMPORT_SOURCE "$LAB_SETUP_IMPORT"
  if [ "$LAB_IMPORT_STATE" = imported ]; then
    kv IMPORT_STATUS already-imported
    _setup_message "Data already imported from $LAB_SETUP_IMPORT: nothing will be copied again."; return 0
  fi
  _import_measure
  kv IMPORT_STATUS to-import
  kv IMPORT_PROJECTS "$IMPORT_M_PROJECTS"
  kv IMPORT_FILES "$IMPORT_M_FILES"; kv IMPORT_BYTES "$IMPORT_M_BYTES"
  kv IMPORT_STATE_FILES "$IMPORT_M_STATE_FILES"; kv IMPORT_STATE_BYTES "$IMPORT_M_STATE_BYTES"
  kv IMPORT_BRANCHES "$(_import_git for-each-ref refs/heads | wc -l | tr -d ' ')"
  kv IMPORT_STASH "$(_import_git stash list | wc -l | tr -d ' ')"
  kv IMPORT_NEEDED_KB "$IMPORT_M_NEEDED"; kv IMPORT_FREE_KB "$IMPORT_M_FREE"
  _setup_message "Data copied into $LAB_HOME before the integrations: $IMPORT_M_PROJECTS projects, $IMPORT_M_FILES files ($IMPORT_M_BYTES bytes) in projects/, state $IMPORT_M_STATE_FILES files ($IMPORT_M_STATE_BYTES bytes) without backups/, git history ($IMPORT_M_GIT_KB KiB), each branch at its revision. The copy stays untouched."
  [ -z "$IMPORT_M_SELF" ] || _setup_message "Registry entry pointing to the copy itself, not imported: ${IMPORT_M_SELF//|/, }"
  _import_space
}
import_projects_count() { # <noms exclus>
  local config n=0
  for config in "$LAB_SETUP_IMPORT"/projects/*/config; do
    [ -f "$config" ] || continue
    case "|$1|" in *"|$(basename "$(dirname "$config")")|"*) continue ;; esac
    n=$((n + 1))
  done
  printf '%s\n' "$n"
}

_import_tree_without() { # <noms exclus> ; stdin : ls-tree -z → mêmes entrées sans les exclus (hors de $( ) : bash 3.2 y lit mal case)
  local entry
  while IFS= read -r -d '' entry; do
    case "|$1|" in *"|${entry#*$'\t'}|"*) continue ;; esac
    printf '%s\0' "$entry"
  done
}
_import_stash() { # <dépôt> <staging> : objets des mises de côté plus anciennes (hors références importées) et journal de refs/stash
  local repo="$1" s="$2" sha
  _import_git rev-parse -q --verify refs/stash >/dev/null && [ -f "$LAB_SETUP_IMPORT/.git/logs/refs/stash" ] || return 0
  { _import_git reflog show --format=%H refs/stash | while IFS= read -r sha; do
      if _import_git cat-file -e "$sha^{commit}" 2>/dev/null; then printf '%s\n' "$sha"; fi
    done
    _import_git for-each-ref --format='^%(objectname)'; } >"$s/stash-revs" || return
  _import_git pack-objects --revs --stdout -q <"$s/stash-revs" | git -C "$repo" index-pack --stdin >/dev/null || return
  mkdir -p "$repo/.git/logs/refs" && cp -p "$LAB_SETUP_IMPORT/.git/logs/refs/stash" "$repo/.git/logs/refs/stash"
}
# _import_history <staging> <exclus> : dépôt où chaque branche garde sa révision, commit de tête limité à projects/, config, .gitignore ;
# index = entrées de la copie sous projects/ (modifications indexées comprises), sans l'entrée de la copie elle-même.
_import_history() {
  local s="$1" self="$2" repo="$1/repo" branch old projects tree new name email entry excluded excl=() blob_config blob_ignore
  git init -q "$repo" || return
  # Toutes les références : branches, étiquettes, notes, refs/stash ; puis chaque mise de côté du journal de refs/stash.
  git -C "$repo" fetch -q --update-head-ok "$LAB_SETUP_IMPORT" '+refs/*:refs/*' || return
  _import_stash "$repo" "$s" || return
  branch="$(_import_git symbolic-ref -q --short HEAD)" && old="$(_import_git rev-parse -q --verify HEAD)" || return
  git -C "$repo" symbolic-ref HEAD "refs/heads/$branch" || return
  if [ -f "$LAB_SETUP_IMPORT/.git/info/exclude" ]; then cp -p "$LAB_SETUP_IMPORT/.git/info/exclude" "$repo/.git/info/exclude" || return; fi
  projects=''
  if git -C "$repo" cat-file -e "$old:projects" 2>/dev/null; then
    projects="$(git -C "$repo" ls-tree -z "$old:projects" | _import_tree_without "$self" | git -C "$repo" mktree -z)" || return
  fi
  blob_config="$(git -C "$repo" hash-object -w "$s/config")" && blob_ignore="$(git -C "$repo" hash-object -w "$s/.gitignore")" || return
  tree="$( { printf '100644 blob %s\t.gitignore\n100644 blob %s\tconfig\n' "$blob_ignore" "$blob_config"
    [ -z "$projects" ] || printf '040000 tree %s\tprojects\n' "$projects"; } | git -C "$repo" mktree)" || return
  name="$(git -C "$repo" config user.name 2>/dev/null || printf treelab)"
  email="$(git -C "$repo" config user.email 2>/dev/null || printf treelab)"
  new="$(git -C "$repo" -c user.name="$name" -c user.email="$email" commit-tree "$tree" -p "$old" \
    -m "chore(lab): import of the earlier installation — only projects/, config and .gitignore stay tracked" \
    -m "Copy: $LAB_SETUP_IMPORT; imported revision: $old")" || return
  git -C "$repo" update-ref "refs/heads/$branch" "$new" "$old" || return
  for excluded in ${self//|/ }; do excl+=(":(exclude)projects/$excluded"); done
  # Une modification indexée mais jamais commitée n'existe que dans les objets de la copie : la recopier avant l'index.
  _import_git ls-files -s -- projects ${excl[@]+"${excl[@]}"} | awk '$1 != "160000" {print $2}' | sort -u |
    git -C "$repo" cat-file --batch-check='%(objectname) %(objecttype)' | awk '$2 == "missing" {print $1}' >"$s/missing" || return
  while IFS= read -r entry; do
    [ "$(_import_git cat-file blob "$entry" | git -C "$repo" hash-object -w --stdin)" = "$entry" ] || return 1
  done <"$s/missing"
  _import_git ls-files -s -z -- projects ${excl[@]+"${excl[@]}"} | git -C "$repo" update-index -z --index-info || return
  git -C "$repo" update-index --add --cacheinfo "100644,$blob_ignore,.gitignore" --cacheinfo "100644,$blob_config,config" || return
  LAB_IMPORT_BRANCH="$branch"; LAB_IMPORT_OLD="$old"; LAB_IMPORT_HEAD="$new"
}
_import_build() { # <staging> <exclus>
  local s="$1" self="$2" agent e
  mkdir "$s/projects" "$s/state" || return
  while IFS= read -r e; do cp -pPR "$e" "$s/projects/" || return; done < <(_import_entries "$LAB_SETUP_IMPORT/projects" "$self")
  while IFS= read -r e; do cp -pPR "$e" "$s/state/" || return; done < <(_import_entries "$LAB_SETUP_IMPORT/state" 'backups|install-manifest.tsv')
  agent="$(sed -n 's/^agent=//p' "$LAB_SETUP_IMPORT/preferences" 2>/dev/null | head -1)"
  { if [ -f "$LAB_SETUP_IMPORT/config" ]; then awk -v a="$agent" 'a != "" && /^agent=/ {next} {print}' "$LAB_SETUP_IMPORT/config"; fi
    [ -z "$agent" ] || printf 'agent=%s\n' "$agent"; } >"$s/config" || return
  { if [ -f "$LAB_SETUP_IMPORT/.gitignore" ]; then cat "$LAB_SETUP_IMPORT/.gitignore"; printf '\n'; fi
    printf '# treelab: release code and technical state, never tracked in the batch file repository\n'
    printf '/releases/\n/current\n/previous-release\n/update-pending\n/state/\n/.treelab-*\n'; } >"$s/.gitignore" || return
  _import_history "$s" "$self" || return
  jq -n --arg source "$LAB_SETUP_IMPORT" --arg branch "$LAB_IMPORT_BRANCH" --arg revision "$LAB_IMPORT_OLD" \
    --arg head "$LAB_IMPORT_HEAD" --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{format:1,source:$source,branch:$branch,revision:$revision,head:$head,date:$date}' >"$s/state/import.json"
}
# import_data : copie avant la transaction ; relancé après un import terminé, ne recopie rien.
import_data() {
  local s self
  import_status || return
  if [ "$LAB_IMPORT_STATE" = imported ]; then _setup_message "Data already imported from $LAB_SETUP_IMPORT: no file copied again."; return 0; fi
  _import_measure; _import_space || return
  self="$IMPORT_M_SELF"
  mkdir -p "$LAB_HOME" && s="$(mktemp -d "$LAB_HOME/.treelab-import.XXXXXXXX")" || return
  _setup_message "Importing the data into $LAB_HOME (working copy: $s)…"
  if ! _import_build "$s" "$self"; then
    rm -R "$s"
    _import_refuse "data copy interrupted; LAB_HOME holds no imported data. Fix the shown cause, then run it again."; return 1
  fi
  if ! { mv "$s/config" "$LAB_HOME/config" && mv "$s/.gitignore" "$LAB_HOME/.gitignore" && mv "$s/projects" "$LAB_HOME/projects" &&
    mv "$s/repo/.git" "$LAB_HOME/.git" && mv "$s/state" "$LAB_STATE" && rm -f "$s/missing" "$s/stash-revs" && rmdir "$s/repo" "$s"; }; then
    _import_refuse "data publication interrupted in $LAB_HOME; the items already moved and $s stay in place for review."; return 1
  fi
  git -C "$LAB_HOME" update-index -q --refresh >/dev/null 2>&1 || true
  kv IMPORT_HEAD "$LAB_IMPORT_HEAD"
  _setup_message "Data imported: branch $LAB_IMPORT_BRANCH, revision $LAB_IMPORT_OLD kept, head $LAB_IMPORT_HEAD."
}

# ---------- inventaire : références à la copie que la pose ne possède pas ; lu, jamais modifié ----------
_import_lines() { # stdin → numéros des lignes qui citent la copie comme chemin (suivie d'une fin, d'un / ou d'un séparateur)
  LC_ALL=C awk -v c1="$LAB_SETUP_IMPORT" -v c2="$LAB_SETUP_IMPORT_GIVEN" '
    function cites(line, c,   s, i, nx) {
      s = line
      while ((i = index(s, c)) > 0) {
        nx = substr(s, i + length(c), 1)
        if (nx == "" || nx !~ /[A-Za-z0-9_.-]/) return 1
        s = substr(s, i + 1)
      }
      return 0
    }
    cites($0, c1) || cites($0, c2) { print NR }'
}
_import_json_refs() { # <fichier json> <préfixes retirés par la pose> → « catégorie<TAB>repère jq » ; seuls les hooks retirés sont exclus
  [ -f "$1" ] || return 0
  jq -r --arg c1 "$LAB_SETUP_IMPORT" --arg c2 "$LAB_SETUP_IMPORT_GIVEN" --argjson legacy "${2:-[]}" "$LAB_MERGE_LEGACY_JQ"'
    def esc: gsub("(?<x>[\\\\.^$|?*+()\\[\\]{}])"; "\\\(.x)");
    def cites: . as $s | any([$c1, $c2] | unique[]; . as $c | $s | test(($c | esc) + "([^A-Za-z0-9_.-]|$)"));
    def expr: "." + (map(if type == "number" then "[\(.)]" else "[\(tojson)]" end) | join(""));
    [ (paths(type == "string") as $p | select(getpath($p) | cites)
        | select((($p[0] == "hooks") and ($p[-1] == "command") and (getpath($p) | legacy_cmd)) | not) | $p[0:2]),
      (paths as $p | select(($p[-1] | type) == "string" and ($p[-1] | cites)) | $p) ]
    | unique[]
    | [ (if .[0] == "hooks" then "hook"
         elif (.[0] | IN("extraKnownMarketplaces", "enabledPlugins", "plugins", "marketplaces")) then "plugins"
         elif (.[0] | IN("projects", "permissions", "trust")) then "trust" else "other" end), expr ] | @tsv
  ' "$1" 2>/dev/null || printf 'other\tunreadable JSON, references not checked\n'
}
_import_toml_refs() { # <fichier toml> → « catégorie<TAB>section » (une référence par section, ligne pour la racine)
  [ -f "$1" ] || return 0
  LC_ALL=C awk -v c1="$LAB_SETUP_IMPORT" -v c2="$LAB_SETUP_IMPORT_GIVEN" '
    function cites(line, c,   s, i, nx) {
      s = line
      while ((i = index(s, c)) > 0) {
        nx = substr(s, i + length(c), 1)
        if (nx == "" || nx !~ /[A-Za-z0-9_.-]/) return 1
        s = substr(s, i + 1)
      }
      return 0
    }
    /^[[:space:]]*\[/ { sec = $0; sub(/^[[:space:]]*/, "", sec); sub(/[[:space:]]*(#.*)?$/, "", sec) }
    cites($0, c1) || cites($0, c2) {
      key = (sec == "" ? "line " NR : sec)
      if (key in seen) next
      seen[key] = 1; cat = "other"
      if (sec ~ /^\[\[?projects\./) cat = "trust"
      else if (sec ~ /^\[\[?(marketplaces|plugins)[].]/) cat = "plugins"
      printf "%s\t%s\n", cat, key
    }' "$1"
}
_import_in() { awk -F '\t' -v f="$1" 'BEGIN {OFS = "\t"} {print $1, f, $2}'; }   # <fichier> : insère le fichier entre catégorie et repère
_import_refs() { # toutes les références : « catégorie<TAB>fichier<TAB>repère »
  local f n config root dir e target self settings legacy
  # Les hooks <copie>/hooks/ d'un fichier fusionné par la pose sont retirés, donc hors inventaire ; tout autre hook reste listé.
  settings="${LAB_CLAUDE_SETTINGS:-$(claude_home)/settings.json}"
  legacy='[]'; [ -z "$(_setup_hooks_file claude)" ] || legacy="$(_merge_legacy_prefixes "$settings")"
  _import_json_refs "$settings" "$legacy" | _import_in "$settings"
  legacy='[]'; [ -z "$(_setup_hooks_file codex)" ] || legacy="$(_merge_legacy_prefixes "$(codex_hooks_file)")"
  _import_json_refs "$(codex_hooks_file)" "$legacy" | _import_in "$(codex_hooks_file)"
  _import_json_refs "$HOME/.claude.json" | _import_in "$HOME/.claude.json"
  _import_toml_refs "$(codex_config)" | _import_in "$(codex_config)"
  for f in "$HOME/Library/LaunchAgents"/*.plist; do
    [ -f "$f" ] || continue
    if { plutil -convert xml1 -o - -- "$f" 2>/dev/null || cat "$f"; } | _import_lines | grep -q .; then printf 'scheduled\t%s\tlaunchd job\n' "$f"; fi
  done
  { crontab -l 2>/dev/null || true; } | _import_lines | while IFS= read -r n; do printf 'scheduled\tcrontab\tline %s\n' "$n"; done
  for e in "$LAB_SETUP_IMPORT"/skills/*; do
    [ -d "$e" ] && [ ! -e "$LAB_ROOT/skills/${e##*/}" ] || continue
    target="$(real_path "$e")"
    _import_inside "$LAB_SETUP_IMPORT" "$target" && printf 'skill\t%s\tdiscovery link to %s\n' "$e" "$target"
  done
  self="$(import_self_names | paste -sd '|' -)"
  for config in "$LAB_SETUP_IMPORT"/projects/*/config; do
    [ -f "$config" ] || continue
    case "|$self|" in *"|$(basename "$(dirname "$config")")|"*) continue ;; esac
    root="$(sed -n 's/^root=//p' "$config" | head -1)"; [ -n "$root" ] && [ -d "$root" ] || continue
    for dir in "$root" "$root"/.worktrees/*; do
      [ -d "$dir" ] || continue
      for f in .lab/meta .claude/settings.json .claude/settings.local.json .mcp.json CLAUDE.md AGENTS.md .codex/config.toml; do
        [ -f "$dir/$f" ] || continue
        _import_lines <"$dir/$f" | while IFS= read -r n; do printf 'project\t%s\tline %s\n' "$dir/$f" "$n"; done
      done
    done
  done
}
# import_inventory : une ligne LEFT=<catégorie> <fichier> — <repère> par référence, chaque ligne une fois, rangée par catégorie.
import_inventory() {
  local refs cat n=0 kind file where
  refs="$(_import_refs)"
  for cat in plugins trust hook scheduled skill project other; do
    while IFS=$'\t' read -r kind file where; do
      [ "$kind" = "$cat" ] || continue
      kv LEFT "$kind $file — $where"; n=$((n + 1))
    done < <(printf '%s\n' "$refs" | awk '!seen[$0]++')
  done
  kv LEFT_TOTAL "$n"
  _setup_message "References to the copy outside the installation: $n (LEFT=), never changed; settle them before renaming or removing the copy."
}
