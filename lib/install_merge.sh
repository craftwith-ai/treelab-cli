# shellcheck shell=bash
# Fusions sélectives ; charger git.sh, codex.sh et install.sh avant les mutations.
# txn_begin doit être actif. Les générateurs restent purs ; stdout des mutations est vide.
# Une racine explicite désigne le développement ; sinon utiliser le lien stable de release.
install_source_root() { printf '%s\n' "${1:-$HOME/.lab/current}"; }
claude_hooks_json() {
  jq -n --arg h "$1" 'def shellpath: if test("^[A-Za-z0-9_./-]+$") then . else @sh end; {hooks:{
    SessionStart:[{matcher:"startup|resume|clear",hooks:[{type:"command",command:($h+"/session-start.sh"|shellpath),timeout:5}]}],
    SessionEnd:[{hooks:[{type:"command",command:($h+"/session-end.sh"|shellpath),timeout:5}]}],
    StopFailure:[{matcher:"rate_limit",hooks:[{type:"command",command:($h+"/stop-failure.sh"|shellpath),timeout:5}]}],
    PreToolUse:[{matcher:"Bash|Write|Edit",hooks:[{type:"command",command:($h+"/guard-tool.sh"|shellpath),timeout:5}]},
      {matcher:"AskUserQuestion",hooks:[{type:"command",command:($h+"/notify.sh"|shellpath),timeout:5}]}],
    Notification:[{matcher:"permission_prompt|idle_prompt|elicitation_dialog",hooks:[{type:"command",command:($h+"/notify.sh"|shellpath),timeout:5}]}],
    PostToolUse:[{matcher:"AskUserQuestion",hooks:[{type:"command",command:($h+"/notify.sh"|shellpath),timeout:5}]}],
    Stop:[{hooks:[{type:"command",command:($h+"/notify.sh"|shellpath),timeout:5}]}],
    UserPromptSubmit:[{hooks:[{type:"command",command:($h+"/notify.sh"|shellpath),timeout:5}]}]
  }}'
}
# _merge_say : lab_say (lib/install.sh, repli à la largeur du terminal) quand il est chargé, sinon une ligne « lab: … » brute
_merge_say() { if declare -F lab_say >/dev/null; then lab_say "$*"; else printf 'lab: %s\n' "$*" >&2; fi; }
_merge_error() { _merge_say "Not changed: $1. $2"; return 2; }
_merge_message() { _merge_say "$1: $2"; }
_merge_temp() {
  [ -n "${LAB_TXN_ACTIVE:-}" ] || { _merge_error 'no transaction' 'Call txn_begin before trying again.'; return 2; }
  mktemp "$LAB_TXN_ACTIVE/merge.XXXXXXXX"
}
# Résolution avant préparation : liens de fichiers admis, liens cassés refusés.
# Pour une création, résoudre le premier ancêtre existant sans créer ses enfants.
_merge_target() {
  local input="$1" p suffix='' base
  _txn_field "$input" || { _merge_error "$input" 'Control character forbidden; fix the path.'; return 2; }
  case "$input" in /*) ;; *) _merge_error "$input" 'Use an absolute path.'; return 2 ;; esac
  case "$input/" in *'/../'*|*'/./'*|*'//'*) _merge_error "$input" 'Use a path without dots or double separators.'; return 2 ;; esac
  if _txn_exists "$input"; then
    if ! { LAB_MERGE_TARGET="$(_txn_resolve_modify "$input")" && [ -f "$LAB_MERGE_TARGET" ]; }; then
      _merge_error "$input" 'Invalid target; fix the link or choose a regular file.'; return 2
    fi
  else
    p="$input"
    while ! _txn_exists "$p"; do
      base="${p##*/}"; suffix="/$base$suffix"; p="${p%/*}"; p="${p:-/}"
    done
    if ! { [ -d "$p" ] && p="$(cd "$p" && pwd -P)" && _txn_field "$p"; }; then
      _merge_error "$input" 'Invalid parent; fix the link or the folder before trying again.'; return 2
    fi
    LAB_MERGE_TARGET="${p%/}$suffix"
  fi
  case "$LAB_MERGE_TARGET/" in "$LAB_STATE/"*) _merge_error "$input" 'Path reserved for the log; choose a user file.'; return 2 ;; esac
  case "$LAB_STATE/" in "$LAB_MERGE_TARGET/"*) _merge_error "$input" 'This path contains the log; choose a user file.'; return 2 ;; esac
}
_merge_input() { if [ -f "$1" ]; then cat "$1"; else printf '%s' "$2"; fi; }
_merge_publish() {
  local path="$1" prepared="$2" target
  _merge_target "$path" || return
  target="$LAB_MERGE_TARGET"
  if [ -f "$target" ] && cmp -s "$target" "$prepared"; then
    _merge_message 'Already satisfied, file unchanged' "$path"
  elif [ -f "$target" ]; then
    record_op modify "$path" "$prepared" || return
    _merge_message 'Updated, foreign data kept' "$path"
  else
    [ -d "$(dirname "$target")" ] || record_op mkdir "$(dirname "$target")" || return
    chmod 600 "$prepared" || return
    record_op create "$target" "$prepared" || return
    _merge_message 'Created' "$path"
  fi
  rm -f "$prepared"
}
# setup --import : une commande de hook appartient à l'installation importée si elle commence par un préfixe « <dossier>/hooks/ »
# dont le dossier est la copie sur le disque (-ef : casse et liens compris), brut ou entre apostrophes.
# shellcheck disable=SC2016 # Programme jq, jamais évalué par le shell.
LAB_MERGE_LEGACY_JQ='def legacy_cmd: type == "string" and (. as $c | any($legacy[]; . as $p | ($c | startswith($p)) or ($c | startswith($p | @sh | rtrimstr("\u0027")))));
  def legacy_hook: type == "object" and .type == "command" and (.command | legacy_cmd);'
# _merge_legacy_prefixes <fichier json> → tableau JSON des préfixes de hooks de l'installation importée cités par ce fichier.
_merge_legacy_prefixes() {
  local file="$1" cmd dir prefixes=()
  if [ -z "${LAB_SETUP_IMPORT:-}" ] || [ ! -f "$file" ]; then printf '[]\n'; return 0; fi
  while IFS= read -r cmd; do
    cmd="${cmd#\'}"
    case "$cmd" in /*/hooks/*) ;; *) continue ;; esac
    for dir in "${cmd%%/hooks/*}" "${cmd%/hooks/*}"; do
      if [ -d "$dir" ] && [ "$dir" -ef "$LAB_SETUP_IMPORT" ]; then prefixes+=("$dir/hooks/"); fi
    done
  done < <(jq -r '.hooks // {} | .[]? | .[]? | .hooks? // [] | .[]? | select(type == "object") | .command | strings' "$file" 2>/dev/null || true)
  printf '%s\n' "${LAB_SETUP_IMPORT%/}/hooks/" ${prefixes[@]+"${prefixes[@]}"} | jq -Rsc 'split("\n") | map(select(length > 0)) | unique'
}
# hooks_merge <fichier> claude|codex [racine] ; hooks_remove <fichier> [racine].
hooks_merge() { _hooks_update "$1" "$2" "${3:-}"; }
hooks_remove() { _hooks_update "$1" remove "${2:-}"; }
_hooks_update() {
  local path="$1" kind="$2" root prepared definition input canonical
  _merge_target "$path" || return
  input="$LAB_MERGE_TARGET"; root="$(install_source_root "$3")"
  if [ -f "$input" ] && ! jq -Rsj . -- "$input" | cmp -s "$input" -; then
    _merge_error "$path" 'JSON not in UTF-8; convert a copy to UTF-8 before trying again.'; return 2
  fi
  _txn_field "$root" || { _merge_error "$path" 'Invalid hooks root; fix the path.'; return 2; }
  case "$root" in /*) ;; *) _merge_error "$path" 'Give an absolute hooks root.'; return 2 ;; esac
  case "$kind" in
    claude) definition="$(claude_hooks_json "${root%/}/hooks")" || return ;;
    codex) definition="$(codex_hooks_json "${root%/}/hooks")" || return ;;
    remove) definition='{"hooks":{}}' ;;
    *) _merge_error "$path" 'Choose claude or codex.'; return 2 ;;
  esac
  prepared="$(_merge_temp)" || return
  # setup --import : les hooks de l'installation importée sont retirés dans la même fusion (arguments compris).
  if ! _merge_input "$input" '{}' | jq -s --arg prefix "${root%/}/hooks/" --argjson legacy "$(_merge_legacy_prefixes "$input")" --argjson definition "$definition" "$LAB_MERGE_LEGACY_JQ"'
    def hook_valid: type == "object" and (.type|type == "string") and
      (if .type == "command" then (.command|type == "string") else true end);
    def group_valid: type == "object" and (.hooks|type == "array" and all(.[]; hook_valid));
    def valid: type == "object" and
      (if has("hooks") then (.hooks|type == "object" and all(.[]; type == "array" and all(.[]; group_valid))) else true end);
    def suffix_valid:
      split("/")|all(length>0 and . != "." and . != ".." and
        (explode|all(. == 45 or . == 46 or . == 95 or (.>=48 and .<=57) or (.>=65 and .<=90) or (.>=97 and .<=122))));
    ($prefix|@sh|rtrimstr("\u0027")) as $quoted
    | def owned:
      .type == "command" and (.command as $cmd |
        (if $cmd|startswith($prefix) then ($cmd|ltrimstr($prefix)|suffix_valid) else false end) or
        (if ($cmd|startswith($quoted)) and ($cmd|endswith("\u0027")) then ($cmd|ltrimstr($quoted)|rtrimstr("\u0027")|suffix_valid) else false end) or
        ($cmd | legacy_cmd));
    if length == 1 then .[0] else error("a single JSON document expected") end
    | if valid then . else error("incompatible hooks structure") end
    | if has("hooks") or ($definition.hooks|length)>0 then
      .hooks = ((.hooks // {}) | with_entries(.value |= map(
        .hooks as $before | .hooks |= map(select(owned|not))
        | select((.hooks|length)>0 or ($before|length)==0))))
    | reduce ($definition.hooks|keys[]) as $event (.; .hooks[$event] = ((.hooks[$event] // []) + $definition.hooks[$event]))
    else . end
  ' >"$prepared"; then
    rm -f "$prepared"
    _merge_error "$path" 'Invalid JSON or incompatible hooks; fix the document and try again.'; return 2
  fi
  # L’égalité sémantique ne doit pas réécrire un fichier au seul motif de son format.
  if [ -f "$input" ]; then
    canonical="$(_merge_temp)" || return
    jq -S . "$input" >"$canonical" || return
    if jq -S . "$prepared" | cmp -s "$canonical" -; then
      rm -f "$prepared" "$canonical"
      _merge_message 'Already satisfied, file unchanged' "$path"; return 0
    fi
    rm -f "$canonical"
  elif [ "$kind" = remove ]; then
    rm -f "$prepared"; _merge_message 'No hooks block, file unchanged' "$path"; return 0
  fi
  # hooks Codex dont la définition change sous une approbation existante : notés pour le doctor (une réapprobation /hooks)
  local reapproval=''
  [ "$kind" != codex ] || reapproval="$(codex_hooks_reapproval "$input" "$prepared" "$path" 2>/dev/null || true)"
  _merge_publish "$path" "$prepared" || return
  # pendant un plan de setup (LAB_REAPPROVAL_MARK dans son temporaire), la marque n'est publiée qu'après une pose appliquée
  local mark="${LAB_REAPPROVAL_MARK:-$LAB_STATE/codex-hooks-reapproval}"
  [ -z "$reapproval" ] || { mkdir -p "$(dirname "$mark")" && printf '%s\n' "$reapproval" >"$mark"; } 2>/dev/null || true
}
# block_upsert <fichier> <contenu du bloc> ; block_remove <fichier>.
block_upsert() { _block_update "$1" "$2" upsert; }
block_remove() { _block_update "$1" /dev/null remove; }
shell_block_upsert() { _block_update "$1" "$2" upsert shell; }
shell_block_remove() { _block_update "$1" /dev/null remove shell; }
_block_update() {
  local path="$1" payload="$2" op="$3" prepared input
  _merge_target "$path" || return
  input="$LAB_MERGE_TARGET"
  # jq remplace silencieusement les octets invalides : vérifier l’aller-retour avant toute transformation.
  if { [ -f "$input" ] && ! jq -Rsj . -- "$input" | cmp -s "$input" -; } ||
     ! jq -Rsj . -- "$payload" | cmp -s "$payload" -; then
    _merge_error "$path" 'Text not in UTF-8; convert a copy to UTF-8 before trying again.'; return 2
  fi
  prepared="$(_merge_temp)" || return
  if ! _merge_input "$input" '' | jq -Rsj --rawfile payload "$payload" --arg op "$op" --arg kind "${4:-html}" '
    def lines:
      if . == "" then [] elif endswith("\n") then split("\n")[:-1]
      else error("final line ending missing") end;
    . as $raw | lines as $lines
    | (if ($lines|length)>0 and ($lines[0]|endswith("\r")) then "\r" else "" end) as $cr
    | if ($lines|all(if $cr == "\r" then endswith("\r") and (rtrimstr("\r")|contains("\r")|not) else (contains("\r")|not) end)) then . else error("mixed line endings") end
    | ($lines|map(rtrimstr("\r"))) as $plain
    | (if $kind == "shell" then "# BEGIN TREELAB" else "<!-- BEGIN TREELAB -->" end) as $begin
    | (if $kind == "shell" then "# END TREELAB" else "<!-- END TREELAB -->" end) as $end
    | [$plain|to_entries[]|select(.value==$begin)|.key] as $starts
    | [$plain|to_entries[]|select(.value==$end)|.key] as $ends
    | if (($starts|length)==0 and ($ends|length)==0) or (($starts|length)==1 and ($ends|length)==1 and $starts[0] < $ends[0]) then . else error("ambiguous markers") end
    | ($payload|lines|map(rtrimstr("\r"))) as $body
    | if ($body|any(. == $begin or . == $end or contains("\r"))) then error("ambiguous content") else . end
    | (if $op == "remove" then [] else [$begin] + $body + [$end] end) as $replacement
    | (if ($starts|length)==0 then $plain + $replacement else $plain[:$starts[0]] + $replacement + $plain[$ends[0]+1:] end)
    | map(. + $cr + "\n") | join("")
  ' >"$prepared"; then
    rm -f "$prepared"
    _merge_error "$path" 'Ambiguous block or line endings; restore a single BEGIN/END TREELAB pair and uniform LF or CRLF lines, then try again.'; return 2
  fi
  if [ ! -f "$input" ] && [ "$op" = remove ]; then rm -f "$prepared"; return 0; fi
  _merge_publish "$path" "$prepared"
}
instructions_merge() {
  local root payload
  root="$(install_source_root "${1:-}")"; payload="$(_merge_temp)" || return
  printf '@%s/templates/global-instructions.md\n' "${root%/}" >"$payload" || return
  _instructions_upsert "$(claude_home)/CLAUDE.md" "$payload" "$root/templates/global-instructions.md" || return
  rm -f "$payload"
  _instructions_upsert "$(codex_home)/AGENTS.md" "$root/templates/global-instructions.md" "$root/templates/global-instructions.md"
}
_instructions_upsert() {
  if [ "$1" -ef "$3" ]; then
    record_op skip "$1" 'legacy instructions linked to the program, migration to prepare' || return
    _merge_message 'Kept, instructions linked to the program; prepare their migration before trying again' "$1"
    return 0
  fi
  block_upsert "$1" "$2"
}
instructions_remove() {
  local root path
  root="$(install_source_root "${1:-}")"
  for path in "$(claude_home)/CLAUDE.md" "$(codex_home)/AGENTS.md"; do
    if [ "$path" -ef "$root/templates/global-instructions.md" ]; then
      record_op skip "$path" 'legacy instructions linked to the program, migration to prepare' || return
      _merge_message 'Kept, instructions linked to the program; prepare their migration before trying again' "$path"
    else
      block_remove "$path" || return
    fi
  done
}
# Écriture transactionnelle du générateur de retrait TOML.
config_section_remove() {
  local path="$1" section="$2" prepared
  _merge_target "$path" || return
  [ -f "$LAB_MERGE_TARGET" ] || return 0
  prepared="$(_merge_temp)" || return
  if ! toml_section_remove "$LAB_MERGE_TARGET" "$section" >"$prepared"; then
    rm -f "$prepared"; return 2
  fi
  _merge_publish "$path" "$prepared"
}
# Ne traverse aucun dossier de découverte lié, même si un enfant est encore absent.
# Un lien historique de dossier est conservé pour le préflight du lot 07.
_merge_discovery_dir() {
  local path="$1" p="$1"
  _txn_field "$path" || { _merge_error "$path" 'Control character forbidden; fix the path.'; return 2; }
  case "$path" in /*) ;; *) _merge_error "$path" 'Use an absolute folder.'; return 2 ;; esac
  case "$path/" in *'/../'*|*'/./'*|*'//'*) _merge_error "$path" 'Use a path without dots or double separators.'; return 2 ;; esac
  while [ "$p" != / ]; do
    if [ -L "$p" ] || { [ -e "$p" ] && [ ! -d "$p" ]; }; then
      record_op skip "$p" 'discovery folder linked or taken, migration to prepare' || return
      _merge_message 'Kept, folder linked or taken; prepare its migration before trying again' "$p"
      return 3
    fi
    p="${p%/*}"; p="${p:-/}"
  done
}
# install_link <source> <lien> : collision = skip, jamais remplacement.
install_link() {
  local source="$1" path="$2" rc
  if _merge_discovery_dir "$(dirname "$path")"; then :; else
    rc=$?; [ "$rc" -eq 3 ] && return 0; return "$rc"
  fi
  if ! { _txn_field "$source" && _txn_field "$path"; }; then
    _merge_error "$path" 'Control character forbidden; fix the path.'; return 2
  fi
  if _txn_exists "$path"; then
    if [ -L "$path" ] && { [ "$path" -ef "$source" ] || { _txn_readlink "$path" && [ "$LAB_TXN_LINK" = "$source" ]; }; }; then
      record_op skip "$path" 'equivalent link already present' || return
      _merge_message 'Already satisfied, link kept' "$path"
    else
      record_op skip "$path" 'collision with a user object, kept' || return
      _merge_message 'Kept, name already taken; addition skipped' "$path"
    fi
    return 0
  fi
  [ -d "$(dirname "$path")" ] || record_op mkdir "$(dirname "$path")" || return
  record_op symlink "$path" "$source" || return
  _merge_message 'Link added' "$path"
}
# Dernière mutation validée de cette cible. Les skip ne transfèrent pas la propriété.
_merge_installed_unchanged() {
  local target="$1" required="$2" line found='' d='' n
  _txn_validate_manifest || return 1
  if [ -f "$LAB_TXN_MANIFEST" ]; then
    while IFS= read -r line; do
      [ "$line" != $'treelab-install\t1' ] || continue
      _txn_parse "$line" || return 1
      if [ "${LAB_TXN_FIELDS[3]}" = "$target" ] && [ "${LAB_TXN_FIELDS[2]}" != skip ]; then
        found="$line"; d="$LAB_TXN_BACKUPS/${LAB_TXN_FIELDS[0]}/${LAB_TXN_FIELDS[1]}"
      fi
    done <"$LAB_TXN_MANIFEST"
  fi
  # Une deuxième pose dans la même transaction connaît aussi sa première écriture.
  if [ -n "${LAB_TXN_ACTIVE:-}" ]; then
    n=1
    while [ "$n" -le "$LAB_TXN_SEQ" ]; do
      line="$(cat "$LAB_TXN_ACTIVE/$n/row")" && _txn_parse "$line" || return 1
      if [ "${LAB_TXN_FIELDS[3]}" = "$target" ] && [ "${LAB_TXN_FIELDS[2]}" != skip ]; then
        found="$line"; d="$LAB_TXN_ACTIVE/$n"
      fi
      n=$((n+1))
    done
  fi
  [ -n "$found" ] && _txn_parse "$found" || return 1
  [ ! -f "$d/done" ] && [ -f "$d/after" ] || return 1
  case "$required:${LAB_TXN_FIELDS[2]}" in link:symlink|file:create|file:modify) ;; *) return 1 ;; esac
  [ "$(_txn_fingerprint "$target")" = "$(cat "$d/after")" ]
}
# Appeler avant txn_begin/rejeu dans chaque processus qui compose les retraits.
merge_register_commands() {
  local pair wanted found
  for wanted in '_merge_unlink:_merge_relink' '_merge_unlink:_merge_restore_file'; do
    found=no
    for pair in ${LAB_TXN_COMMANDS[@]+"${LAB_TXN_COMMANDS[@]}"}; do
      [ "$pair" != "$wanted" ] || found=yes
    done
    if [ "$found" = no ]; then LAB_TXN_COMMANDS+=("$wanted"); fi
  done
}
_merge_unlink() { rm "$1"; }
_merge_relink() {
  if [ ! -L "$1" ]; then ln -s "$2" "$1" || return; fi
  chmod -h "$3" "$1"
}
install_link_remove() {
  local path="$1" rc target text mode
  if _merge_discovery_dir "$(dirname "$path")"; then :; else
    rc=$?; [ "$rc" -eq 3 ] && return 0; return "$rc"
  fi
  _txn_exists "$path" || return 0
  _txn_target "$path" || return
  target="$LAB_TXN_TARGET"
  if [ -L "$target" ] && _merge_installed_unchanged "$target" link; then
    _txn_readlink "$target" || return
    text="$LAB_TXN_LINK"; mode="$(stat -f %Lp "$target")" || return
    merge_register_commands
    record_op cmd "$target" _merge_unlink _merge_relink "$text" "$mode" || return
    _merge_message 'Treelab link removed' "$path"
  else
    record_op skip "$target" 'user object or changed link, kept' || return
    _merge_message 'Kept, user object or changed link' "$path"
  fi
}
# Table de nettoyage : anciens noms des skills et agents treelab, renommés en anglais (couloir anglais, lot 02). lab update les
# retire déjà en comparant les releases ; lab setup retire leurs liens treelab intacts, le doctor signale un reste.
LAB_LEGACY_SKILLS='lot-plan lot-run lot-end recette artifacts-visuels'
LAB_LEGACY_AGENTS='reviewer verifier'
# install_legacy_paths → un chemin de découverte d'ancien nom par ligne, pour les intégrations posées
install_legacy_paths() {
  local n
  # visual-artifacts reste à Codex (lib/setup.sh) ; le plan de montée d'une release qui ne connaît que son ancien nom le lie
  # aussi côté Claude
  if [ "${LAB_SETUP_CLAUDE:-yes}" = yes ]; then printf '%s\n' "$(claude_home)/skills/visual-artifacts"; fi
  for n in $LAB_LEGACY_SKILLS; do
    if [ "${LAB_SETUP_CLAUDE:-yes}" = yes ]; then printf '%s\n' "$(claude_home)/skills/$n"; fi
    if [ "${LAB_SETUP_CODEX:-yes}" = yes ]; then printf '%s\n' "$(agents_home)/skills/$n"; fi
  done
  for n in $LAB_LEGACY_AGENTS; do
    if [ "${LAB_SETUP_CLAUDE:-yes}" = yes ]; then printf '%s\n' "$(claude_home)/agents/$n.md"; fi
    if [ "${LAB_SETUP_CODEX:-yes}" = yes ]; then printf '%s\n' "$(codex_home)/agents/$n.toml"; fi
  done
}
# install_legacy_known <chemin> : le manifeste attribue ce chemin à un lien posé par treelab (revue du lot 02 : un lien personnel
# sous un ancien nom, jamais posé par treelab, n'est ni retiré, ni annoncé, ni signalé)
install_legacy_known() {
  local line
  [ -f "${LAB_TXN_MANIFEST:-}" ] && _txn_target "$1" 2>/dev/null || return 1
  while IFS= read -r line; do
    [ "$line" != $'treelab-install\t1' ] || continue
    _txn_parse "$line" || return 1
    if [ "${LAB_TXN_FIELDS[3]}" = "$LAB_TXN_TARGET" ] && [ "${LAB_TXN_FIELDS[2]}" = symlink ]; then return 0; fi
  done <"$LAB_TXN_MANIFEST"
  return 1
}
# install_legacy_remove <chemin> : retire le lien intact d'un ancien nom et, pour un agent Codex, sa génération
install_legacy_remove() {
  install_link_remove "$1" || return
  case "$1" in */agents/*.toml) _merge_generated_remove "$LAB_STATE/generated/codex-agents/${1##*/}" ;; esac
}
# Les répertoires entiers ne sont jamais liés ni remplacés.
install_skills() {
  local root item name
  root="$(install_source_root "${1:-}")"
  for item in "$root"/skills/*; do
    [ -d "$item" ] || continue
    name="${item##*/}"
    install_link "$item" "$(claude_home)/skills/$name" || return
    install_link "$item" "$(agents_home)/skills/$name" || return
  done
}
install_claude_agents() {
  local root item
  root="$(install_source_root "${1:-}")"
  for item in "$root"/agents/*.md; do
    [ -f "$item" ] || continue
    install_link "$item" "$(claude_home)/agents/${item##*/}" || return
  done
}
# Les noms de fichiers viennent des identifiants des sources, jamais du texte TOML.
_merge_agent_name() {
  local name="${1##*/}"; name="${name%.md}"
  if [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then printf '%s\n' "$name"
  else _merge_error "$1" 'Invalid agent file name; use ASCII letters, digits, hyphens or underscores.'; fi
}
install_codex_agents() {
  local root dir md name generated destination prepared rc
  root="$(install_source_root "${1:-}")"; dir="$LAB_STATE/generated/codex-agents"
  for destination in "$(codex_home)/agents" "$dir"; do
    if _merge_discovery_dir "$destination"; then :; else
      rc=$?; [ "$rc" -eq 3 ] && return 0; return "$rc"
    fi
  done
  for md in "$root"/agents/*.md; do
    [ -f "$md" ] || continue
    name="$(_merge_agent_name "$md")" || return
    generated="$dir/$name.toml"; destination="$(codex_home)/agents/$name.toml"
    if [ "${LAB_SETUP_REAPPLY:-no}" = yes ] && _update_client_removed "$destination"; then
      record_op skip "$destination" 'user removal kept' || return
      continue
    fi
    # Un nom de découverte occupé n'entraîne même pas une génération orpheline.
    if _txn_exists "$destination" && ! { [ -L "$destination" ] && [ -f "$generated" ] && [ "$destination" -ef "$generated" ]; } &&
      ! _merge_agent_replaceable "$destination"; then
      record_op skip "$destination" 'collision with a user agent, kept' || return
      _merge_message 'Kept, agent name already taken; addition skipped' "$destination"
      continue
    fi
    prepared="$(_merge_temp)" || return
    if ! codex_agent_toml "$md" >"$prepared"; then rm -f "$prepared"; return 2; fi
    if _txn_exists "$generated"; then
      if [ -f "$generated" ] && [ ! -L "$generated" ] && _merge_installed_unchanged "$generated" file; then
        if cmp -s "$prepared" "$generated"; then
          _merge_message 'Already satisfied, generated agent unchanged' "$generated"
        else
          record_op modify "$generated" "$prepared" || return
          _merge_message 'Generated agent updated' "$generated"
        fi
      else
        record_op skip "$generated" 'user or changed generated agent, kept' || return
        _merge_message 'Kept, user or changed generated agent; addition skipped' "$generated"
        rm -f "$prepared"; continue
      fi
    else
      [ -d "$dir" ] || record_op mkdir "$dir" || return
      chmod 600 "$prepared" || return
      record_op create "$generated" "$prepared" || return
      _merge_message 'Generated agent created' "$generated"
    fi
    rm -f "$prepared"
    install_link "$generated" "$destination" || return
  done
}
# Remplacement d'un agent occupé : jamais hors du plan de setup --import (surchargé par _setup_plan_overrides).
_merge_agent_replaceable() { return 1; }
_merge_restore_file() { _txn_remove "$1" && _txn_copy "$2" "$1"; }
_merge_generated_remove() {
  local path="$1" backup
  _txn_exists "$path" || return 0
  if [ -f "$path" ] && [ ! -L "$path" ] && _merge_installed_unchanged "$path" file; then
    merge_register_commands
    backup="$LAB_TXN_ACTIVE/$((LAB_TXN_SEQ+1))/before"
    record_op cmd "$path" _merge_unlink _merge_restore_file "$backup" || return
    _merge_message 'Generated agent removed' "$path"
  else
    record_op skip "$path" 'user or changed generated agent, kept' || return
    _merge_message 'Kept, user or changed generated agent' "$path"
  fi
}
install_codex_agents_remove() {
  local root md name rc dir="$LAB_STATE/generated/codex-agents"
  root="$(install_source_root "${1:-}")"
  if _merge_discovery_dir "$dir"; then :; else
    rc=$?; [ "$rc" -eq 3 ] && return 0; return "$rc"
  fi
  for md in "$root"/agents/*.md; do
    [ -f "$md" ] || continue
    name="$(_merge_agent_name "$md")" || return
    install_link_remove "$(codex_home)/agents/$name.toml" || return
    _merge_generated_remove "$dir/$name.toml" || return
  done
}
# Scénario interne ; la CLI et le consentement seront branchés au lot 07.
# Appelant : merge_register_commands ; txn_begin ; install_elements [racine] ; txn_commit.
install_elements() {
  local root
  root="$(install_source_root "${1:-}")"
  hooks_merge "${LAB_CLAUDE_SETTINGS:-$(claude_home)/settings.json}" claude "$root" || return
  hooks_merge "$(codex_hooks_file)" codex "$root" || return
  instructions_merge "$root" || return
  install_skills "$root" || return
  install_claude_agents "$root" || return
  install_codex_agents "$root"
}
install_elements_remove() {
  local root item
  root="$(install_source_root "${1:-}")"
  hooks_remove "${LAB_CLAUDE_SETTINGS:-$(claude_home)/settings.json}" "$root" || return
  hooks_remove "$(codex_hooks_file)" "$root" || return
  instructions_remove "$root" || return
  for item in "$root"/skills/*; do
    [ -d "$item" ] || continue
    install_link_remove "$(claude_home)/skills/${item##*/}" || return
    install_link_remove "$(agents_home)/skills/${item##*/}" || return
  done
  for item in "$root"/agents/*.md; do
    [ -f "$item" ] || continue
    install_link_remove "$(claude_home)/agents/${item##*/}" || return
  done
  install_codex_agents_remove "$root"
}
