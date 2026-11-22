# shellcheck shell=bash
# codex.sh — Codex côté user : trust par dossier (config.toml [projects."<path>"]), hooks (définition et approbation), ~/.codex surchargeable.
# Dépend de real_path (lib/git.sh, à sourcer avant). CODEX_HOME est la variable de Codex lui-même ; LAB_CODEX_HOME sert aux tests.
codex_home()   { printf '%s\n' "${LAB_CODEX_HOME:-${CODEX_HOME:-$HOME/.codex}}"; }
claude_home()  { printf '%s\n' "${LAB_CLAUDE_HOME:-$HOME/.claude}"; }
agents_home()  { printf '%s\n' "${LAB_AGENTS_HOME:-$HOME/.agents}"; }
codex_config() { printf '%s\n' "${LAB_CODEX_CONFIG:-$(codex_home)/config.toml}"; }
codex_hooks_file() { printf '%s/hooks.json\n' "$(codex_home)"; }
# codex_notification_defaults <dossier de sauvegarde> : valeurs de première installation.
# Ne touche ni aux choix explicites, ni à notify, ni à la politique d'approbation.
codex_notification_defaults() (
  set -e
  local f tmp source snapshot
  f="$(codex_config)"; source="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
  if [ -L "$f" ] || { [ -e "$f" ] && [ ! -f "$f" ]; }; then
    printf 'install: Codex notifications unchanged: configuration is a link or not a regular file; see docs/codex-notifications.md.\n' >&2
    return 0
  fi
  mkdir -p "$(dirname "$f")" || return 1
  tmp="$(mktemp "${f}.notifications.XXXXXX")" || return 1
  snapshot="$(mktemp "${f}.before.XXXXXX")" || { rm -f "$tmp"; return 1; }
  trap 'rm -f "$tmp" "$snapshot"' EXIT
  if [ -f "$f" ]; then cp -p "$f" "$snapshot" && cp -p "$f" "$tmp" || return 1; fi
  if ! awk -f "$source/scripts/codex-notification-defaults.awk" "$snapshot" >"$tmp"; then
    printf 'install: Codex notifications unchanged: unsupported TOML notation; see docs/codex-notifications.md.\n' >&2
    return 0
  fi
  if [ -f "$f" ]; then
    cmp -s "$f" "$tmp" && return 0
    if ! cmp -s "$f" "$snapshot"; then
      printf "install: Codex configuration changed while being read; run the installation again.\n" >&2
      return 1
    fi
    mkdir -p "$1" && cp -p "$snapshot" "$1/codex-config.toml" || return 1
  elif [ -e "$f" ] || [ -L "$f" ]; then
    printf "install: Codex configuration appeared while being read; run the installation again.\n" >&2
    return 1
  fi
  mv "$tmp" "$f" || return 1
  printf 'install: Codex notifications: missing values added, existing choices kept.\n'
)
codex_trusted() { [ -f "$(codex_config)" ] && grep -Fq "[projects.\"$1\"]" "$(codex_config)"; }
codex_trust_add() {
  local f; f="$(codex_config)"; [ -f "$f" ] || return 0
  codex_trusted "$1" && return 0
  printf '\n[projects."%s"]\ntrust_level = "trusted"\n' "$1" >>"$f"
}
codex_trust_remove() (
  local f tmp section
  f="$(codex_config)"; [ -f "$f" ] || return 0
  section="$(jq -rn --arg p "$1" '"projects." + ($p|tojson)')" || return
  tmp="$(mktemp)" || return
  trap 'rm -f "$tmp"' EXIT
  toml_section_remove "$f" "$section" >"$tmp" || return
  cmp -s "$f" "$tmp" && return 0
  # Les appels historiques ne sont pas des installations ; conserver lien et mode.
  cat "$tmp" >"$f"
)
# codex_hooks_json <dossier des hooks> : la définition des trois hooks (même trio, mêmes scripts que Claude Code). Une seule source :
# install.sh l'écrit dans ~/.codex/hooks.json, les tests la relisent. Codex approuve chaque hook par le hash de sa définition
# ([hooks.state] de config.toml) : tant que ce JSON ne change pas, l'approbation donnée une fois par /hooks tient.
# SessionEnd : timeout 3 — Codex ramène tout SessionEnd à 3 s et l'annonce (« clamping SessionEnd hook timeout to 3s », mesuré le 2026-09-03).
codex_hooks_json() {
  jq -n --arg h "$1" 'def shellpath: if test("^[A-Za-z0-9_./-]+$") then . else @sh end; {
    description: "LAB: worktree context, session lock, Bash guard and context writes (same scripts as Claude Code).",
    hooks: {
      SessionStart: [{matcher:"startup|resume|clear", hooks:[{type:"command", command:($h+"/session-start.sh"|shellpath), statusMessage:"LAB context", timeout:5, additionalContextLimit:800}]}],
      SessionEnd:   [{hooks:[{type:"command", command:($h+"/session-end.sh"|shellpath), timeout:3}]}],
      PreToolUse:   [{matcher:"Bash|apply_patch", hooks:[{type:"command", command:($h+"/guard-tool.sh"|shellpath), statusMessage:"LAB guard", timeout:5}]}]
    }}'
}
# codex_trusted_hash <hooks.json> <event>:<groupe>:<index> → trusted_hash de [hooks.state."<hooks.json>:<event>:<groupe>:<index>"] ;
# lecture seule, vide si la table ou la clé manque. Codex garde ce hash par position : lab ne le calcule ni ne l'écrit jamais.
codex_trusted_hash() {
  local cfg header
  cfg="$(codex_config)"; [ -f "$cfg" ] || return 0
  header="$(jq -rn --arg p "$1:$2" '"[hooks.state." + ($p|tojson) + "]"')" || return 0
  LC_ALL=C awk -v h="$header" '
    /^[[:space:]]*\[/ { s = $0; sub(/[[:space:]]*(#.*)?$/, "", s); sub(/^[[:space:]]*/, "", s); inside = (s == h); next }
    inside && /^[[:space:]]*trusted_hash[[:space:]]*=[[:space:]]*"[^"]*"/ { v = $0; sub(/^[^"]*"/, "", v); sub(/".*$/, "", v); print v; exit }
  ' "$cfg"
}
# codex_hooks_reapproval <ancien hooks.json> <nouveau hooks.json> <hooks.json publié> : hooks treelab dont la définition change à
# une position déjà approuvée (lot 05 du couloir anglais : statusMessage traduit). Codex garde l'ancien hash et n'exécutera plus ces
# hooks avant une nouvelle approbation par /hooks. Une ligne par hook : <event>:<groupe>:<index><TAB><trusted_hash><TAB><sha du
# nouvel objet> ; le doctor la lit tant que hash et objet n'ont pas bougé.
codex_hooks_reapproval() {
  local old="$1" new="$2" path="$3" real event e pos hash sum candidate
  [ -f "$old" ] && [ -f "$new" ] || return 0
  real="$(resolve_file "$path" 2>/dev/null || printf '%s\n' "$path")"
  for event in session_start pre_tool_use session_end; do
    case "$event" in session_start) e=SessionStart ;; pre_tool_use) e=PreToolUse ;; *) e=SessionEnd ;; esac
    while IFS=$'\t' read -r pos sum; do
      [ -n "$pos" ] || continue
      for candidate in "$path" "$real"; do
        hash="$(codex_trusted_hash "$candidate" "$event:$pos")"
        [ -z "$hash" ] || { printf '%s:%s\t%s\t%s\n' "$event" "$pos" "$hash" "$sum"; break; }
      done
    done < <(jq -r --arg e "$e" --slurpfile o "$old" '
      (.hooks[$e] // []) | to_entries[] | .key as $g | (.value.hooks // []) | to_entries[]
      | select(.value.type == "command" and ((.value.command // "") | test("/hooks/(session-start|session-end|guard-tool)\\.sh\u0027?$")))
      | select(($o[0].hooks[$e][$g].hooks[.key]? // null) != .value)
      | "\($g):\(.key)\t\(.value | tojson)"' "$new" 2>/dev/null | while IFS=$'\t' read -r pos obj; do
        printf '%s\t%s\n' "$pos" "$(printf '%s' "$obj" | shasum -a 256 | cut -d' ' -f1)"
      done)
  done
}
# codex_hooks_outdated <racine> → événements dont hooks.json garde une définition treelab ancienne (même commande, autre objet :
# statusMessage d'avant le lot 05 du couloir anglais) — une montée calcule son plan avec le code quitté et réécrit l'ancienne
# définition ; treelab setup --reapply, lancé par la version installée, l'écrit à jour.
codex_hooks_outdated() {
  local f event e expected out=''
  f="$(codex_hooks_file)"; [ -f "$f" ] || return 0
  for event in session_start pre_tool_use session_end; do
    case "$event" in session_start) e=SessionStart ;; pre_tool_use) e=PreToolUse ;; *) e=SessionEnd ;; esac
    expected="$(codex_hooks_json "${1%/}/hooks" | jq -c --arg e "$e" '.hooks[$e][0].hooks[0]')" || continue
    if jq -e --arg e "$e" --argjson x "$expected" '[.hooks[$e][]?.hooks[]? | select(type == "object" and .command == $x.command and . != $x)] | length > 0' "$f" >/dev/null 2>&1; then
      out="$out $event"
    fi
  done
  printf '%s\n' "${out# }"
}
# codex_hooks_reapproval_pending → événements dont la réapprobation notée par codex_hooks_reapproval attend encore : même hash
# approuvé, même définition à la même position. Vide sinon (réapprouvé, réécrit ou rien noté).
codex_hooks_reapproval_pending() {
  local mark="$LAB_STATE/codex-hooks-reapproval" f real key hash sum event e g k obj cur candidate out=''
  [ -f "$mark" ] || return 0
  f="$(codex_hooks_file)"; [ -f "$f" ] || return 0
  real="$(resolve_file "$f" 2>/dev/null || printf '%s\n' "$f")"
  while IFS=$'\t' read -r key hash sum; do
    [ -n "$key" ] || continue
    event="${key%%:*}"; g="${key#*:}"; k="${g#*:}"; g="${g%%:*}"
    case "$event" in session_start) e=SessionStart ;; pre_tool_use) e=PreToolUse ;; session_end) e=SessionEnd ;; *) continue ;; esac
    [[ "$g:$k" =~ ^[0-9]+:[0-9]+$ ]] || continue
    obj="$(jq -c --arg e "$e" --argjson g "$g" --argjson k "$k" '.hooks[$e][$g].hooks[$k] // empty' "$f" 2>/dev/null)" || continue
    [ -n "$obj" ] && [ "$(printf '%s' "$obj" | shasum -a 256 | cut -d' ' -f1)" = "$sum" ] || continue
    for candidate in "$f" "$real"; do
      cur="$(codex_trusted_hash "$candidate" "$key")"
      if [ -n "$cur" ] && [ "$cur" = "$hash" ]; then out="$out $event"; break; fi
    done
  done <"$mark"
  printf '%s\n' "${out# }"
}
# codex_hook_trusted <event> [racine] : lecture de la position réelle, jamais d’approbation.
# L'entrée déclare une approbation ; seul Codex valide son hash privé.
codex_hook_trusted() {
  local f cfg real root event expected positions index candidate section source
  f="$(codex_hooks_file)"; cfg="$(codex_config)"
  [ -f "$cfg" ] && [ -f "$f" ] || return 1
  root="${2:-${LAB_INSTALL_ROOT:-}}"
  if [ -z "$root" ]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)" || return 1
    if [ -f "$root/.release" ]; then root="$HOME/.lab/current"
    else root="$(main_root "$root" 2>/dev/null || printf '%s\n' "$root")"; fi
  fi
  case "$1" in session_start) event=SessionStart ;; session_end) event=SessionEnd ;; pre_tool_use) event=PreToolUse ;; *) return 1 ;; esac
  expected="$(codex_hooks_json "${root%/}/hooks" | jq -c --arg e "$event" '.hooks[$e][0].hooks[0]')" || return 1
  positions="$(jq -er --arg e "$event" --argjson expected "$expected" '
    .hooks[$e] | if type == "array" then . else error("invalid event") end
    | [to_entries[] | .key as $g | .value.hooks
       | if type == "array" then . else error("invalid group") end
       | to_entries[] | select(.value == $expected) | "\($g):\(.key)"]
    | if length == 1 then .[0] else error("hook missing or ambiguous") end
  ' "$f" 2>/dev/null)" || return 1
  real="$(resolve_file "$f")" || return 1
  source="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)" || return 1
  index="$1:$positions"
  for candidate in "$f" "$real"; do
    section="$(jq -rn --arg p "$candidate:$index" '"hooks.state." + ($p|tojson)')" || return 1
    # Le lecteur exige une déclaration unique et non vide dans la vraie table.
    if LC_ALL=C LAB_TOML_SECTION="$section" awk -v mode=approved \
      -f "$source/scripts/toml-section-remove.awk" "$cfg" >/dev/null 2>&1; then return 0; fi
  done
  return 1
}

# codex_agent_toml <Markdown> : métadonnées scalaires non citées, corps littéral LF.
# Pas de sortie partielle : jq valide tout avant de produire le document.
codex_agent_toml() {
  local result
  if ! jq -Rsj . -- "$1" | cmp -s "$1" -; then
    printf 'lab: Agent not generated: %s. Text is not UTF-8; convert a copy to UTF-8 before trying again.\n' "$1" >&2
    return 2
  fi
  if ! result="$(jq -Rsj --arg quotes "'''" '
    gsub("\r\n"; "\n")
    | if contains("\r") or test("[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]") then error("control characters") else . end
    | split("\n") as $lines
    | if $lines[0] != "---" then error("header missing") else . end
    | ([$lines|to_entries[]|select(.key>0 and .value=="---")|.key][0]) as $end
    | if $end == null then error("header incomplete") else . end
    | (reduce $lines[1:$end][] as $line ({};
        ($line|capture("^(?<key>name|description|tools|model): +(?<value>[^ ].*)$")) as $m
        | if has($m.key) or ($m.value|test("^[\"\u0027|>{\\[]")) then error("ambiguous metadata") else .[$m.key]=$m.value end)) as $meta
    | if ($meta.name // "" | length)>0 and ($meta.description // "" | length)>0 and ($lines[1:$end]|length)==($meta|length)
      then . else error("name or description missing or ambiguous") end
    | ($lines[$end+1:]|join("\n")) as $body
    | if $body|contains($quotes) then error("triple apostrophe in the body") else . end
    | "name = " + ($meta.name|tojson) + "\ndescription = " + ($meta.description|tojson)
      + "\nmodel_reasoning_effort = \"medium\"\nsandbox_mode = \"read-only\"\ndeveloper_instructions = " + $quotes + "\n" + $body + $quotes + "\n"
  ' "$1")" || [ -z "$result" ]; then
    printf 'lab: Agent not generated: %s. Metadata missing or ambiguous, forbidden character or triple apostrophe; fix the Markdown before trying again.\n' "$1" >&2
    return 2
  fi
  printf '%s\n' "$result"
}
# toml_section_remove <fichier> <nom TOML sans crochets> : générateur pur.
# Sous-ensemble conservateur : refus des noms échappés et tableaux de tables.
toml_section_remove() {
  local source
  source="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)" || return
  if { [ -s "$1" ] && [ "$(tail -c 1 "$1" | od -An -tu1 | tr -d ' ')" != 10 ]; } ||
     ! LC_ALL=C LAB_TOML_SECTION="$2" awk -f "$source/scripts/toml-section-remove.awk" "$1"; then
    printf 'lab: TOML not modified: %s. Unsupported or ambiguous syntax; use simple tables without escaped names and uniform line endings before trying again.\n' "$1" >&2
    return 2
  fi
}
