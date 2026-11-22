# shellcheck shell=bash
# shellcheck disable=SC2034 # DOC_DONE est lu par le trap de dispatch dans bin/lab.
# doctor.sh — mesure le contexte réellement chargé, vérifie le câblage, compare à la baseline (cliquet).
# Sortie : blocs KEY=value (CHECK, STATUS, VALUE, LIMIT, NOTE) ; résumé humain sur stderr ; exit 1 si un RED.
DOC_RED=0; DOC_METRICS=""; DOC_REPORT="${DOC_REPORT:-0}"; DOC_PROJECT=''; DOC_PROJECT_INDEX=0
BASELINE="${LAB_BASELINE:-$LAB_STATE/baseline.json}"
DOC_ROOT_EXPLICIT="${LAB_INSTALL_ROOT:+yes}"
if [ -z "${LAB_INSTALL_ROOT:-}" ] && [ -f "$LAB_ROOT/.release" ]; then LAB_INSTALL_ROOT="$LAB_ROOT"; fi
if [ -z "${LAB_INSTALL_ROOT:-}" ]; then
  LAB_INSTALL_ROOT="$LAB_ROOT"
  if [ -e "$LAB_ROOT/.git" ]; then LAB_INSTALL_ROOT="$(main_root "$LAB_ROOT" 2>/dev/null || printf '%s\n' "$LAB_ROOT")"; fi
fi
LAB_INSTALL_ROOT="$(real_path "$LAB_INSTALL_ROOT")"   # l'installation globale pointe le checkout principal stable, jamais un worktree éphémère
SKILLS_DIR="${LAB_SKILLS_DIR:-$LAB_INSTALL_ROOT/skills}"   # surchargeable pour les tests ; par défaut, mesure ce qui est réellement installé
# doctor_old_name <nom> → le nom français d'une mesure avant le lot 09 du couloir anglais : une baseline gelée avant reste lue sous
# cet ancien nom, jamais réécrite (--freeze ajoute le nom anglais à côté). Sans ancien nom : le nom tel quel.
doctor_old_name() {
  case "$1" in
    *.claude_md.lines_outside_import) printf '%s\n' "${1%.claude_md.lines_outside_import}.claude_md.lines_hors_import" ;;
    *.rules.without_paths) printf '%s\n' "${1%.rules.without_paths}.rules.sans_paths" ;;
    *.tracked.mechanical) printf '%s\n' "${1%.tracked.mechanical}.tracked.mecanique" ;;
    *.worktrees.outside_layout) printf '%s\n' "${1%.worktrees.outside_layout}.worktrees.hors_layout" ;;
    *.hooks.broken) printf '%s\n' "${1%.hooks.broken}.hooks.casses" ;;
    global.skills.codex.duplicates) echo global.skills.codex.doublons ;;
    *) printf '%s\n' "$1" ;;
  esac
}
check() { # check <nom> <valeur> <limite|-> <ok|warn|red> [note] [sans-cliquet|cliquet-au-dela]   (statut calculé si limite numérique ;
  # cliquet-au-dela : la baseline ne rougit qu'au-delà de la limite, pour une mesure qui fluctue sous elle)
  local name="$1" value="$2" limit="$3" sev="$4" note="${5:-}" ratchet="${6:-}" status=OK base=""
  if [ "$ratchet" != sans-cliquet ] && [ -n "$DOC_BASE_JSON" ]; then
    base="$(printf '%s' "$DOC_BASE_JSON" | jq -r --arg k "$name" --arg o "$(doctor_old_name "$name")" '.[$k] // .[$o] // empty')"
  fi
  if [ "$limit" != "-" ] && [[ "$value" =~ ^[0-9]+$ ]] && doctor_greater "$value" "$limit"; then status="$(printf '%s' "$sev" | tr '[:lower:]' '[:upper:]')"; note="${note:+$note; }above the limit $limit"; fi
  if [ "$ratchet" = cliquet-au-dela ] && [ "$status" = OK ]; then base=""; fi
  if [ -n "$base" ] && [[ "$value" =~ ^[0-9]+$ ]] && doctor_greater "$value" "$base"; then status=RED; note="${note:+$note; }went up: baseline $base"; fi
  [ "$status" = RED ] && DOC_RED=1
  [ "$ratchet" = sans-cliquet ] || { [[ "$value" =~ ^[0-9]+$ ]] && DOC_METRICS="$DOC_METRICS$name=$value"$'\n'; }
  doctor_emit "$name" "$status" "$value" "$limit" "$note" "$base"
}
flag() { # flag <nom> <ok|warn|red> <valeur> [note] : contrôle booléen
  local st; st="$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')"; [ "$st" = RED ] && DOC_RED=1
  doctor_emit "$1" "$st" "$3" - "${4:-}" '' "${5:-}"
}
. "$LAB_ROOT/lib/doctor_report.sh"
. "$LAB_ROOT/lib/doctor_product.sh"
. "$LAB_ROOT/lib/tests_guard.sh"
. "$LAB_ROOT/lib/mcp.sh"
lines_of() { [ -f "$1" ] && wc -l <"$1" | tr -d ' ' || echo 0; }
bytes_of() { [ -f "$1" ] && wc -c <"$1" | tr -d ' ' || echo 0; }
# octets réellement chargés d'un dossier de skills : name + description de chaque SKILL.md
skills_desc_bytes() { local d f t=0; for f in "$1"/*/SKILL.md; do [ -f "$f" ] || continue; d="$(awk '/^---/{c++; next} c==1 && /^(name|description):/' "$f" | wc -c)"; t=$((t + d)); done; echo "$t"; }
skills_count() { local n=0 f; for f in "$1"/*/SKILL.md; do [ -f "$f" ] && n=$((n + 1)); done; echo "$n"; }
skill_header() { awk -v k="$2" '/^---/{c++; next} c==1 && index($0, k":")==1 {sub("^"k": *", ""); print; exit}' "$1"; }   # <SKILL.md> <name|description> : champ de l'en-tête, lu par Claude et Codex
rules_without_paths() { local n=0 f; for f in "$1"/.claude/rules/*.md; do [ -f "$f" ] || continue; grep -q '^paths:' "$f" || n=$((n + 1)); done; echo "$n"; }
expected_link() { # <chemin> <cible> → flag
  if [ -L "$1" ] && [ "$1" -ef "$2" ]; then flag "link.$3" ok "$1 → $2"; else flag "link.$3" red "$(readlink "$1" 2>/dev/null || echo missing)" "expected → $2 (treelab setup)"; fi
}
doctor_install_context() { doctor_product_context; }
doctor_instruction() {
  local path="$1" kind="$2" name="$3" expected actual
  if [ ! -f "$LAB_INSTALL_ROOT/templates/global-instructions.md" ]; then
    flag "link.$name" red "$path" "Source missing: $LAB_INSTALL_ROOT/templates/global-instructions.md; restore the complete copy of the program."; return
  fi
  if [ -L "$path" ] && [ "$path" -ef "$LAB_INSTALL_ROOT/templates/global-instructions.md" ]; then
    expected_link "$path" "$LAB_INSTALL_ROOT/templates/global-instructions.md" "$name"; return
  fi
  if [ "$kind" = claude ]; then expected="@$DOC_HOOK_ROOT/templates/global-instructions.md"
  else expected="$(cat "$LAB_INSTALL_ROOT/templates/global-instructions.md")"; fi
  if [ -f "$path" ] && actual="$(awk '
    {sub(/\r$/, "")}
    $0=="<!-- BEGIN TREELAB -->" {b++; inside=1; next}
    $0=="<!-- END TREELAB -->" {e++; if (!inside) bad=1; inside=0; next}
    inside {print}
    END {if (b!=1 || e!=1 || inside || bad) exit 1}
  ' "$path")" && [ "$actual" = "$expected" ]; then
    flag "link.$name" ok "block loaded: $path"
  else flag "link.$name" red "$path" 'Treelab block missing or changed; run treelab setup again.'; fi
}
doctor_discovery() {
  local path="$1" source="$2" name="$3" mode="${4:-links}" item entry target bad='' collisions=''
  if [ ! -d "$source" ]; then flag "link.$name" red "$source" 'Link source missing; restore the complete copy of the program.'; return; fi
  if [ -L "$path" ] && [ "$mode" = links ]; then expected_link "$path" "$source" "$name"; return; fi
  for item in "$source"/*; do
    [ -e "$item" ] || continue
    entry="${item##*/}"; target="$item"
    # Même exception que setup : aucune adaptation concurrente au natif Claude.
    if [ "$name" = claude-skills ] && [ "$entry" = visual-artifacts ]; then continue; fi
    if [ "$mode" = codex ]; then
      [ -f "$item" ] || continue
      case "$entry" in *.md) entry="${entry%.md}.toml" ;; *) continue ;; esac
      target="$LAB_STATE/generated/codex-agents/$entry"
    fi
    if [ -L "$path/$entry" ] && [ "$path/$entry" -ef "$target" ]; then :
    elif [ "$DOC_INSTALLED" = yes ] && _txn_exists "$path/$entry" && doctor_collision "$path/$entry"; then
      collisions="$collisions $entry"
      case "$name" in *-skills) DOC_COLLISIONS=$((DOC_COLLISIONS + 1)) ;; esac
    else bad="$bad $entry"; fi
  done
  if [ -d "$path" ] && [ -z "$bad" ]; then
    if [ -n "$collisions" ]; then flag "link.$name" warn "name collisions, yours kept:$collisions"
    else flag "link.$name" ok "individual links: $path"; fi
  else flag "link.$name" red "$path$bad" 'Links missing or broken; run treelab setup again.'; fi
}
doctor_collision() {
  local line found=no
  [ -e "$1" ] || return 1
  while IFS= read -r line; do
    [ "$line" != $'treelab-install\t1' ] || continue
    _txn_parse "$line" || return 1
    [ "${LAB_TXN_FIELDS[3]}" = "$1" ] || continue
    found=no
    if [ "${LAB_TXN_FIELDS[0]}" = "$DOC_SETUP_TXN" ] && [ "${LAB_TXN_FIELDS[2]}" = skip ]; then
      case "${LAB_TXN_FIELDS[8]}" in [Cc]ollision*) found=yes ;; esac
    fi
  done <"$LAB_TXN_MANIFEST"
  [ "$found" = yes ]
}
doctor_hook_count() {
  local definition
  if [ "$2" = claude ]; then definition="$(claude_hooks_json "$DOC_HOOK_ROOT/hooks")"
  else definition="$(codex_hooks_json "$DOC_HOOK_ROOT/hooks")"; fi
  jq -r --argjson expected "$definition" --arg mode "$3" '
    if $mode == "write" then
      $expected.hooks.PreToolUse[0] as $group |
      [.hooks.PreToolUse[]? | select(.matcher==$group.matcher) | .hooks[]? |
       select(.command==$group.hooks[0].command)] | length
    else
      [$expected.hooks[][]?.hooks[]?.command] as $commands |
      [.hooks[][]?.hooks[]?.command | select(. as $command | $commands | index($command))] | length
    end
  ' "$1" 2>/dev/null || printf '0\n'
}
# doctor_statusline_record <réglages Claude> : avec des comptes rangés, la statusline doit envoyer son JSON à lab account record —
# seule source de l'usage réel par compte (couloir comptes-complets, lot 01). La statusline appartient à l'utilisateur : lab ne la
# réécrit jamais, il donne la ligne à ajouter.
doctor_statusline_record() {
  local cmd w script="" ok=0
  cmd="$(jq -r '.statusLine.command // empty' "$1" 2>/dev/null || true)"
  if printf '%s' "$cmd" | grep -q 'account record'; then ok=1; fi
  # chaque mot qui désigne un fichier (« bash ~/x.sh », « $HOME/x.sh ») : le script n'est pas toujours le premier mot (revue du lot 01)
  for w in $cmd; do
    case "$w" in \~/*) w="$HOME/${w#\~/}" ;; "\$HOME/"*) w="$HOME/${w#\$HOME/}" ;; esac
    [ -f "$w" ] || continue; [ -n "$script" ] || script="$w"
    if grep -q 'account record' "$w" 2>/dev/null; then ok=1; fi
  done
  if [ "$ok" = 1 ]; then flag global.accounts.statusline ok "lab account record"
  else
    flag global.accounts.statusline warn missing "account usage unknown: add after input=\$(cat) in ${script:-your status line script}: printf '%s' \"\$input\" | lab account record"
  fi
}
doctor_global() {
  local f n b s names bad stale
  printf '\n== global ==\n' >&2
  doctor_install_context
  if [ "$DOC_CLAUDE" = yes ]; then
    doctor_instruction "$(claude_home)/CLAUDE.md" claude claude-md
    doctor_discovery "$(claude_home)/skills" "$LAB_INSTALL_ROOT/skills" claude-skills
    doctor_discovery "$(claude_home)/agents" "$LAB_INSTALL_ROOT/agents" claude-agents
  fi
  if [ "$DOC_CODEX" = yes ]; then
    doctor_instruction "$(codex_home)/AGENTS.md" codex agents-md
    doctor_discovery "$(agents_home)/skills" "$LAB_INSTALL_ROOT/skills" agents-skills
    if [ "$DOC_INSTALLED" = yes ]; then doctor_discovery "$(codex_home)/agents" "$LAB_INSTALL_ROOT/agents" codex-agents codex; fi
  fi
  if [ "$DOC_COLLISIONS" -gt 0 ]; then flag install.skills.collisions warn "$DOC_COLLISIONS" 'Your own items with the same names were kept; choose the names to keep before a new installation.' COLLISIONS
  else flag install.skills.collisions ok 0 'No skill collision recorded for the active installation.'; fi
  # lien treelab périmé (table LAB_LEGACY_*) que le manifeste attribue à treelab : pose faite par un code plus ancien, ou lien modifié
  names=''; while IFS= read -r f; do { [ -L "$f" ] && install_legacy_known "$f"; } || continue; names="$names $f"; done < <(LAB_SETUP_CLAUDE="$DOC_CLAUDE" LAB_SETUP_CODEX="$DOC_CODEX" install_legacy_paths)
  if [ -n "$names" ]; then flag install.legacy warn "${names# }" "Outdated Treelab links; treelab setup removes the intact ones; remove a changed link yourself if it is no longer used."
  else flag install.legacy ok 0 "No outdated Treelab link."; fi
  f="$LAB_INSTALL_ROOT/templates/global-instructions.md"
  check global.instructions.lines "$(lines_of "$f")" 40 red; check global.instructions.bytes "$(bytes_of "$f")" - -
  check global.skills.count "$(skills_count "$SKILLS_DIR")" "${LAB_DOCTOR_SKILLS_WARN_LIMIT:--}" warn 'Number of skills; adjust the chosen limit if this selection is intended.' sans-cliquet
  check global.skills.desc_bytes "$(skills_desc_bytes "$SKILLS_DIR")" - - '' sans-cliquet
  # Codex lit ~/.agents/skills (→ _lab/skills, prouvé par link.agents-skills) ET ~/.codex/skills : un skill présent aux deux endroits est vu deux fois
  n=0; names=""; for f in "$SKILLS_DIR"/*/; do [ "$DOC_CODEX" = yes ] && [ -f "$f/SKILL.md" ] || continue; s="$(basename "$f")"; if [ -f "$(codex_home)/skills/$s/SKILL.md" ]; then n=$((n + 1)); names="$names $s"; fi; done
  check global.skills.codex.duplicates "$n" 0 red "${names:+Codex would see the skill twice ($(codex_home)/skills and ~/.agents/skills):$names}"
  # en-têtes : name = dossier, description non vide — c'est tout ce que les deux outils chargent avant d'ouvrir un skill (tous les skills, pas une liste)
  n=0; bad=""; for f in "$SKILLS_DIR"/*/SKILL.md; do
    [ -f "$f" ] || continue; s="$(basename "$(dirname "$f")")"; n=$((n + 1))
    if [ "$(skill_header "$f" name)" != "$s" ] || [ -z "$(skill_header "$f" description)" ]; then bad="$bad $s"; fi
  done
  if [ -z "$bad" ]; then flag global.skills.headers ok "$n/$n"; else flag global.skills.headers red "$bad" "name: = folder and a non-empty description: (read by Claude and Codex)"; fi
  # skills réservés à l'utilisateur = ceux qui portent disable-model-invocation: true (en-tête Claude) ; Codex ignore cet en-tête et les
  # déclencherait seul sur leur description : il lui faut agents/openai.yaml avec policy.allow_implicit_invocation: false (review du lot 10 :
  # une liste codée en dur restait verte pour un troisième skill réservé)
  n=0; bad=""; for f in "$SKILLS_DIR"/*/SKILL.md; do
    grep -q '^disable-model-invocation: true' "$f" 2>/dev/null || continue; s="$(basename "$(dirname "$f")")"; n=$((n + 1))
    grep -Eq '^[[:space:]]*allow_implicit_invocation:[[:space:]]*false[[:space:]]*$' "$(dirname "$f")/agents/openai.yaml" 2>/dev/null || bad="$bad $s"
  done
  if [ -z "$bad" ]; then flag global.skills.reserved.codex ok "$n/$n"; else flag global.skills.reserved.codex red "$bad" "agents/openai.yaml with policy.allow_implicit_invocation: false (otherwise Codex triggers them on its own)"; fi
  n=0; for f in "$(codex_home)"/agents/*.toml; do [ -f "$f" ] && n=$((n + 1)); done; check global.codex.agents.count "$n" - - '' sans-cliquet
  f="${LAB_CLAUDE_SETTINGS:-$(claude_home)/settings.json}"
  if [ "$DOC_CLAUDE" = yes ]; then
  if [ -f "$f" ]; then
    if n="$(jq '.mcpServers // {} | length' "$f" 2>/dev/null)"; then
      check global.settings.mcp.count "$n" - - '' sans-cliquet
    else flag global.settings red invalid 'Repair the JSON of the Claude settings, then run treelab doctor again.'; fi
    # nos hooks se reconnaissent par le dossier d'installation réel (jamais par le nom d'un dépôt : le produit vit sous un autre nom — lot 16)
    # le nombre attendu se lit dans la définition posée (StopFailure s'y est ajouté au lot 02 de cmux-pro)
    b="$(doctor_hook_count "$f" claude all)"; n="$(claude_hooks_json "$DOC_HOOK_ROOT/hooks" | jq '[.hooks[][].hooks[]] | length')"
    if [ "$b" -eq "$n" ]; then flag global.hooks.claude ok "$b armed"; else flag global.hooks.claude red "$b/$n" "treelab setup"; fi
    n="$(doctor_hook_count "$f" claude write)"
    if [ "$n" -eq 1 ]; then flag global.hooks.claude.write ok "Bash|Write|Edit → guard-tool.sh"; else flag global.hooks.claude.write red "$n/1" "treelab setup: one PreToolUse group Bash|Write|Edit to guard-tool.sh"; fi
    if comptes_actifs; then doctor_statusline_record "$f"; fi
  else flag global.settings red missing 'Claude settings missing; run treelab setup again.'; flag global.hooks.claude.write red missing "treelab setup"; fi
  fi
  # hooks Codex : le trio doit être posé (install.sh) ET approuvé une fois par l'utilisateur (/hooks : hash de la définition dans
  # [hooks.state] de config.toml). Sans approbation, Codex charge le fichier mais n'exécute rien — la garde Git et la libération du
  # verrou étaient inertes alors que ce contrôle comptait des commandes et restait vert (mesuré le 2026-09-03). lab n'écrit jamais
  # [hooks.state] : c'est la revue voulue par Codex, et son hash n'est pas reproduit.
  f="$(codex_hooks_file)"
  if [ "$DOC_CODEX" = yes ]; then
  if [ -f "$f" ]; then
    b="$(doctor_hook_count "$f" codex all)"
    if [ "$b" -eq 3 ]; then flag global.hooks.codex ok "$b armed"; else flag global.hooks.codex red "$b/3" "treelab setup"; fi
    n="$(doctor_hook_count "$f" codex write)"
    if [ "$n" -eq 1 ]; then flag global.hooks.codex.write ok "Bash|apply_patch → guard-tool.sh"; else flag global.hooks.codex.write red "$n/1" "treelab setup: one PreToolUse group Bash|apply_patch to guard-tool.sh"; fi
    n=0; names=""; for s in session_start pre_tool_use session_end; do if codex_hook_trusted "$s" "$DOC_HOOK_ROOT"; then n=$((n + 1)); else names="$names $s"; fi; done
    # définition changée sous une approbation existante (lab update, lot 05 du couloir anglais) : Codex ne les exécute plus avant /hooks
    [ -n "$names" ] || names="$(codex_hooks_reapproval_pending 2>/dev/null || true)"; [ -z "$names" ] || names=" ${names# }"
    stale="$(codex_hooks_outdated "$DOC_HOOK_ROOT" 2>/dev/null || true)"
    if [ -n "$stale" ]; then flag global.hooks.codex.trust red "outdated" "Treelab hooks written by an older version: $stale. Run treelab setup --reapply, then open a Codex session, /hooks, and approve them once."
    elif [ -z "$names" ]; then flag global.hooks.codex.trust ok "$n/3 approved"
    elif [ "$n" -eq 3 ]; then flag global.hooks.codex.trust red "reapproval" "Treelab hooks changed since your approval: open a Codex session, /hooks, approve them once:$names"
    else flag global.hooks.codex.trust red "$n/3" "open a Codex session, /hooks, approve:$names"; fi
  else flag global.hooks.codex red missing "treelab setup"; flag global.hooks.codex.write red missing "treelab setup"; flag global.hooks.codex.trust red missing "treelab setup, then /hooks in Codex"; fi
  fi
  f="$(codex_config)"
  if [ "$DOC_CODEX" = yes ] && [ -f "$f" ]; then
    # TOML lu à la main : en-tête de table sans espaces ni commentaire, clé = valeur avec espaces ou tabulations ; allow_managed_hooks_only
    # ne compte qu'à la racine (avant la première table) — review du lot 10 : `[features] # …` passait vert, une clé sous [projects] rougissait
    if awk '/^[[:space:]]*\[/{s=$0; sub(/[[:space:]]*(#.*)?$/, "", s); sub(/^[[:space:]]*/, "", s)} s=="[features]" && /^[[:space:]]*hooks[[:space:]]*=[[:space:]]*false([[:space:]]|#|$)/{f=1} END{exit !f}' "$f"; then flag global.hooks.codex.enabled red "features.hooks=false" "remove hooks = false from [features] ($f)"
    elif awk '/^[[:space:]]*\[/{exit} /^[[:space:]]*allow_managed_hooks_only[[:space:]]*=[[:space:]]*true([[:space:]]|#|$)/{f=1} END{exit !f}' "$f"; then flag global.hooks.codex.enabled red "allow_managed_hooks_only=true" "$(codex_hooks_file) would no longer be read ($f)"
    else flag global.hooks.codex.enabled ok yes; fi
    if grep -Fq "[projects.\"$HOME\"]" "$f"; then flag global.codex.trust.home red "trusted" "Codex trust on the whole \$HOME"; else flag global.codex.trust.home ok no; fi
    n="$(grep -Ec '^[[:space:]]*\[mcp_servers\.("[^"]+"|[A-Za-z0-9_-]+)\][[:space:]]*(#.*)?$' "$f" || true)"; check global.codex.mcp.count "$n" - - '' sans-cliquet
  fi
  mcp_doctor   # serveurs d'outils : mémoire au-delà du seuil, versions non figées (lib/mcp.sh) ; avertissements seulement
  doctor_ginkgo
}
# doctor_ginkgo (lot 04 de pilotage-voix) : une ligne toujours, hors baseline ; la clé absente n'est qu'une information. Rouge
# seulement si l'app livrée par la release installée manque ou si sa signature est cassée ; un checkout la fabrique au premier
# lancement. Comme les autres contrôles globaux, l'installation (LAB_INSTALL_ROOT, DOC_RELEASE), jamais la copie qui s'exécute (revue).
doctor_ginkgo() {
  . "$LAB_ROOT/lib/ginkgo.sh"
  local app key=absent note
  ! ginkgo_key_present || key=present
  note="OpenAI key $key"; [ "$key" = present ] || note="$note (lab ginkgo key openai, or asked at the first lab ginkgo)"
  if [ "${DOC_RELEASE:-no}" != yes ]; then flag global.ginkgo ok checkout "Ginkgo.app is built from the sources at the first lab ginkgo; $note"; return 0; fi
  app="$LAB_INSTALL_ROOT/apps/Ginkgo.app"
  if [ ! -d "$app" ]; then
    flag global.ginkgo red missing "Ginkgo.app missing from this version ($app): the next treelab update brings it; the rest of treelab works"
  elif ! codesign --verify --strict "$app" >/dev/null 2>&1; then
    flag global.ginkgo red damaged "Ginkgo.app damaged, its signature is refused ($app): the next treelab update brings a new one; the rest of treelab works"
  else
    [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] || note="$note; Apple Silicon only: lab ginkgo refuses on this Mac"
    flag global.ginkgo ok "$(ginkgo_app_version "$app" | grep . || echo unknown)" "$note"
  fi
}
# doctor_permanent <projet> (lot 01 d'autonomie-tours) : couloirs permanents nommés, jamais candidats au retrait ; rien sans eux
doctor_permanent() {
  local wt names="" n=0
  for wt in "$P_ROOT"/.worktrees/*/; do
    if [ ! -d "$wt" ] || ! lane_permanent "${wt%/}"; then continue; fi
    n=$((n + 1)); names="$names${names:+, }$(basename "$wt")"
  done
  [ "$n" = 0 ] || check "$1.lanes.permanent" "$n" - ok "permanent lanes, never proposed for removal: $names" sans-cliquet
}
# doctor_tower <projet> (lot 04 d'autonomie-tours) : la tour du projet, en information — toujours OK, jamais jaune ni rouge, hors
# baseline (un flag ne compte aucune mesure) ; chaque état porte son remède. Statut lu par lock_status, sa note sur stderr tue.
doctor_tower() {
  local wt; wt="$(worktree_path "$TOWER_LANE")"
  if [ ! -d "$wt" ]; then flag "$1.tower" ok absent "no tower in this project: lab tower $1 creates it"; return 0; fi
  if ! lane_is_tower "$wt"; then flag "$1.tower" ok absent "the lane $TOWER_LANE is not a tower: lab tower $1 says how to replace it"; return 0; fi
  case "$(lock_status "$wt" 2>/dev/null)" in
    alive*) flag "$1.tower" ok alive "the tower session runs" ;;
    uncertain*) flag "$1.tower" ok unknown "tower session undeterminable from here (sandbox?)" ;;
    *) flag "$1.tower" ok 'no session' "lab wake restarts it within the hour, or lab next $1 $TOWER_LANE now" ;;
  esac
}
# doctor_permissions <projet> <racine mesurée> (lot 06 d'autonomie-tours) : un deny de push ou de fusion dans le .claude/settings.json
# suivi d'un projet doté d'une tour fait demander à l'utilisateur des commandes git ; la garde de lab le remplace. Orange, jamais rouge,
# hors baseline ; projet sans tour, fichier non suivi ou sans règle : OK.
doctor_permissions() {
  local f="$2/.claude/settings.json" rules rc=0 ans
  deploy_tower_project || { flag "$1.permissions" ok 'no tower'; return 0; }
  git -C "$2" ls-files --error-unmatch -- .claude/settings.json >/dev/null 2>&1 || { flag "$1.permissions" ok none 'no shared .claude/settings.json'; return 0; }
  rules="$(deny_rules "$f")" || rc=$?
  if [ "$rc" != 0 ]; then flag "$1.permissions" warn unreadable "$f is not valid JSON: push and merge deny rules not checked"; return 0; fi
  [ -n "$rules" ] || { flag "$1.permissions" ok none; return 0; }
  ans="$(config_get "$1" deny_lift)"
  flag "$1.permissions" warn "deny $(printf '%s\n' "$rules" | paste -sd' ' -)" \
    "$f forbids agents to push or merge, so they ask the user for commands; the lab guard replaces these rules — remedy: lab tower $1 --lift-deny${ans:+ (answered: $ans)}"
}
# doctor_leftovers <projet> (lot 02 de fermeture-propre) : sessions de couloir retiré et orphelins d'un dossier de couloir
# (lane_leftovers, lib/close.sh), chacun nommé ; jaune, jamais rouge, hors baseline ; doctor n'arrête rien, lab top le fait
doctor_leftovers() {
  local rows k pid nm age lane names="" n=0
  rows="$(lane_leftovers "$P_ROOT")" || { flag "$1.lanes.leftovers" warn unreadable "process table or lsof unreadable: lane processes not checked"; return 0; }
  while IFS=$'\t' read -r k pid nm age lane; do
    [ -n "$pid" ] || continue; n=$((n + 1))
    names="$names; pid $pid $nm, $age, lane $lane ($([ "$k" = session ] && echo 'folder removed' || echo orphan))"
  done <<<"$rows"
  check "$1.lanes.leftovers" "$n" 0 warn "Sessions of removed lanes and orphan processes in lane folders; lab top stops them$names" sans-cliquet
}
# doctor_unlocked <projet> (lot 01 de reprise-apres-migration) : session vivante dans un couloir dont le verrou est libre ou mort —
# lab next pourrait y ouvrir une seconde session ; jaune, hors baseline, l'agent appelant exclu ; table illisible : « not checked »
doctor_unlocked() {
  local wt names="" n=0 rc
  for wt in "$P_ROOT"/.worktrees/*/; do
    [ -d "$wt" ] || continue; wt="${wt%/}"
    rc=0; lane_unlocked_live "$wt" || rc=$?
    case "$rc" in
      0) n=$((n + 1)); names="$names; lane $(basename "$wt"): pid ${UNLOCKED_LIVE%%:*} ${UNLOCKED_LIVE#*:}" ;;
      2) flag "$1.lanes.unlocked" warn "not checked" "process table or lsof unreadable: sessions without lock not checked"; return 0 ;;
    esac
  done
  check "$1.lanes.unlocked" "$n" 0 warn "Live sessions in a lane without lock (lab next could open a second one)$names${names:+ — use a tool in that session, or close it}" sans-cliquet
}
# doctor_services <projet> (lot 02 de services-couloir) : services des couloirs fermés que nomme scripts/lab-services list, chaque
# couloir avec sa commande de ménage ; jaune, jamais rouge, hors baseline ; doctor n'arrête rien. Sans crochet : rien (sortie
# d'avant) ; échec ou délai : jaune « not checked », jamais un faux zéro. LAB_DOCTOR_NO_SERVICES=1 (garde de livraison) : sauté.
doctor_services() {
  local lane n names="" k=0
  [ "${LAB_DOCTOR_NO_SERVICES:-}" != 1 ] || return 0
  [ -n "$(services_hook "$P_ROOT")" ] || return 0
  if ! services_list; then
    flag "$1.lanes.services" warn "not checked" "Services of closed lanes not checked: $(services_list_why)"; return 0
  fi
  while IFS=$'\t' read -r lane n; do
    [ -n "$lane" ] || continue; k=$((k + 1))
    names="$names; lane $lane: $n (lab services $1 stop $lane)"
  done < <(services_orphans)
  [ "$k" -lt 2 ] || names="$names; all of them: lab services $1 stop --orphans"
  check "$1.lanes.services" "$k" 0 warn "Services of closed lanes, still listed by $SERVICES_HOOK_REL list$names" sans-cliquet
}
doctor_project() {
  local p="$1" root f n b ctx ctx_wt others o dead=0 legacy=0 prunable=0 flags path others_warn="" line event cmdline broken
  load_project "$p"; root="${2:-$P_ROOT}"
  { printf '\n'; doctor_say "== project $(doctor_text "$p") ($(doctor_text "$root")) =="; } >&2
  local sev=warn; [ "$P_DOCS" = repo ] && sev=red   # le layout vit dans le dépôt : son contexte est tenu au budget ; sinon il n'est pas à nous
  if [ -f "$root/AGENTS.md" ]; then
    check "$p.agents_md.lines" "$(lines_of "$root/AGENTS.md")" 80 "$sev"
    n="$(grep -cv '^@' "$root/CLAUDE.md" 2>/dev/null || echo 0)"; check "$p.claude_md.lines_outside_import" "$n" 20 "$sev"
    if grep -q '^@AGENTS.md' "$root/CLAUDE.md" 2>/dev/null; then flag "$p.claude_md.imports_agents" ok yes; else flag "$p.claude_md.imports_agents" "$sev" no "CLAUDE.md must start with @AGENTS.md"; fi
  else
    check "$p.claude_md.lines" "$(lines_of "$root/CLAUDE.md")" 80 "$sev" "no AGENTS.md: Codex reads nothing"
  fi
  check "$p.context.bytes" "$(( $(bytes_of "$root/CLAUDE.md") + $(bytes_of "$root/AGENTS.md") ))" - -
  check "$p.rules.without_paths" "$(rules_without_paths "$root")" 0 "$sev" "a rule without paths: always loads"
  check "$p.skills.count" "$(skills_count "$root/.claude/skills")" 6 "$sev"
  f="$(memory_file "$root")"; check "$p.memory.lines" "$(lines_of "$f")" 200 warn "beyond that, the rest no longer loads" sans-cliquet
  # Le cliquet suit la part stable à la racine du projet. La taille reçue dans le couloir reste publiée :
  # son chemin, sa branche et son lot varient normalement sans signifier que le contexte durable a grossi.
  ctx="$(printf '{"cwd":"%s"}' "$P_ROOT" | LAB_DRY=1 LAB_NO_SWEEP=1 "$LAB_ROOT/bin/lab" hook session-start 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null || true)"
  ctx_wt="$(printf '{"cwd":"%s"}' "$root" | LAB_DRY=1 LAB_NO_SWEEP=1 "$LAB_ROOT/bin/lab" hook session-start 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null || true)"
  check "$p.sessionstart.chars" "${#ctx}" 800 red "measured at the root; a worktree session receives ${#ctx_wt}"
  check "$p.notes.lines" "$(lines_of "$(project_dir "$p")/notes.md")" 21 warn
  # fichiers de mécanique versionnés par erreur
  n="$(git -C "$root" ls-files .lab .worktrees .codex-local 2>/dev/null | wc -l | tr -d ' ')"; check "$p.tracked.mechanical" "$n" 0 red ".lab/.worktrees must never be tracked"
  # worktrees : hérités hors .worktrees/, prunables, verrous morts
  while IFS=$'\t' read -r path _ flags; do
    [ -n "$path" ] || continue
    same_path "$path" "$P_ROOT" && continue
    case "$flags" in *prunable*) prunable=$((prunable + 1)); continue ;; esac
    case "$path" in "$P_ROOT"/.worktrees/*) ;; *) legacy=$((legacy + 1)) ;; esac
    f="$path/.lab/session.lock"; [ -f "$f" ] && lock_dead "$f" && dead=$((dead + 1))
  done < <(worktree_list "$P_ROOT")
  f="$P_ROOT/.lab/session.lock"; [ -f "$f" ] && lock_dead "$f" && dead=$((dead + 1))
  check "$p.worktrees.prunables" "$prunable" 0 warn "git worktree prune"
  check "$p.worktrees.outside_layout" "$legacy" 0 warn "worktrees outside .worktrees/ (inherited)"
  # sans cliquet (lot 21) : le verrou mort d'un autre couloir rendait rouge le bilan et bloquait lab merge d'un couloir sain
  check "$p.locks.dead" "$dead" 0 warn "processes proven dead; lab status removes nothing, lab next, launch or open remove them" sans-cliquet
  doctor_leftovers "$p"
  doctor_unlocked "$p"
  doctor_services "$p"
  doctor_permanent "$p"
  doctor_tower "$p"
  doctor_permissions "$p" "$root"
  # hermétisme : aucun autre projet nommé dans les fichiers de contexte — sauf les noms de `hermetisme_allow=` (config du projet,
  # séparés par des espaces) : une marque ou un mot courant peut être l'homonyme d'un projet (lot 6 : deux paires de projets réels, la marque citée par l'un portait le nom de l'autre)
  others=""
  for o in $(hermetism_forbidden_names "$p"); do
    for f in "$root/AGENTS.md" "$root/CLAUDE.md" "$(project_dir "$p")/notes.md" "$(memory_file "$root")" "$root"/.claude/rules/*.md; do
      [ -f "$f" ] || continue
      if project_name_in_file "$o" "$f"; then
        if [ "$P_OWNER" = other ] && case "$f" in "$root"/*) git -C "$root" ls-files --error-unmatch -- "${f#"$root"/}" >/dev/null 2>&1 ;; *) false ;; esac; then
          others_warn="$others_warn $o($(basename "$f"))"
        else
          others="$others $o($(basename "$f"))"
        fi
      fi
    done
  done
  if [ -n "$others" ]; then
    flag "$p.isolation" red "$others${others_warn:+ ; tracked:$others_warn}" "a project never names another project"
  elif [ -n "$others_warn" ]; then
    flag "$p.isolation" warn "$others_warn" "file I do not maintain"
  else
    flag "$p.isolation" ok none
  fi
  # hooks projet cassés (commande absente) : chacun nommé — fichier, événement (clé sous hooks, sinon chemin JSON), commande ;
  # cinq au plus, le compte reste celui d'avant (A7 du brief, lot 06 de lab-enhancement)
  b=0; broken=""
  for f in "$root/.claude/settings.json" "$root/.claude/settings.local.json" "$root/.codex/hooks.json"; do
    [ -f "$f" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      event="${line%%$'\t'*}"; cmdline="${line#*$'\t'}"
      path="$(printf '%s' "$cmdline" | sed -E "s/^(node|bash|sh|python3) +//; s/^'//; s/'.*$//; s/ .*$//")"
      case "$path" in
        /*) [ ! -e "$path" ] || continue ;;
        .*|[a-z]*/*) [ ! -e "$root/$path" ] && [ ! -e "$root/${path#./}" ] || continue ;;
        *) continue ;;
      esac
      b=$((b + 1)); [ "$b" -gt 5 ] || broken="$broken${broken:+ ; }${f#"$root"/} : $event → $cmdline"
    done < <(jq -r 'paths(type == "object" and ((.command? | type) == "string")) as $p
      | [(if $p[0] == "hooks" and ($p | length) > 1 then $p[1] else ($p | map(tostring) | join(".")) end), getpath($p).command]
      | map(tostring | gsub("[\t\n\r]"; " ")) | join("\t")' "$f" 2>/dev/null)
  done
  [ "$b" -le 5 ] || broken="$broken … and $((b - 5)) more"
  check "$p.hooks.broken" "$b" 0 warn "${broken:+hook command not found: $broken}"
  doctor_lot_sizes "$p" "$(docs_dir "$root")"
  doctor_tests_weakened "$p" "$root"
  doctor_criteria_proofs "$p" "$root"
  doctor_waiting "$p" "$root"
  doctor_ci_workflows "$p" "$root"
  doctor_ci_measures "$p"
  doctor_conflicts "$p"
  doctor_targets "$p" "$root"
  doctor_cloud_image "$p"
}
# doctor_cloud_image <projet> (lot 01 de cloud-racine) : image Cloud du projet plus vieille que son outillage (empreinte de
# scripts/cloud-image.sh et des fichiers qu'il cite, dans la base) ; jaune, remède nommé ; projet sans image : rien
doctor_cloud_image() {
  [ -n "$(cloud_image_get snapshot)" ] || return 0
  if cloud_image_stale; then
    flag "$1.cloud.image" warn stale "scripts/cloud-image.sh changed since the image of $(cloud_image_get at): rebuilt at the next Cloud restore, or now: lab cloud $1 image"
  else flag "$1.cloud.image" ok current; fi
}
# doctor_conflicts <projet> : <projet>.conflicts.repeated, avertissement seulement — un même fichier en conflit avec la base au moins deux
# fois en 30 jours (épisodes distincts : couple tête du couloir, révision de la base) (journal de lab sync) et que generated= + regen= ne couvrent pas : le déclarer régénéré éviterait la reprise à la main
DOC_CONFLICT_DAYS=30
doctor_conflicts() {
  local p="$1" log f n out="" since
  log="$LAB_STATE/$p/conflits"
  since=$(( $(date -u +%s) - DOC_CONFLICT_DAYS * 86400 ))
  while IFS=$'\t' read -r n f; do
    [ -n "$f" ] || continue
    if [ -n "${P_REGEN:-}" ] && sync_generated "$f"; then continue; fi
    out="${out:+$out ; }$f ($n times)"
  done < <([ -f "$log" ] && awk -F '\t' -v s="$since" '$1 + 0 >= s && $4 != "" && !seen[$4 SUBSEP $5 SUBSEP $6]++ { c[$4]++ } END { for (f in c) if (c[f] >= 2) printf "%d\t%s\n", c[f], f }' "$log" | LC_ALL=C sort -t "$(printf '\t')" -k1,1nr -k2,2)
  if [ -z "$out" ]; then flag "$p.conflicts.repeated" ok none; return; fi
  flag "$p.conflicts.repeated" warn "$out" "in repeated conflict over the last $DOC_CONFLICT_DAYS days; if a command produces this file, declare it in $(project_dir "$p")/config: generated=<pattern> and regen=<command that rebuilds it> — lab sync will rebuild it instead of stopping"
}
# doctor_targets <projet> <root> : cibles de mise en ligne (lot 04 de mise-en-ligne), quatre avertissements jamais rouges, lus sur le
# registre et la config : cible sans sonde ; workflow .github qui déploie pendant qu'une cible sert un couloir non fusionné (une fusion
# le déclencherait et l'effacerait) ; couloir non fusionné servi depuis plus de 2 jours ; sonde ≠ registre (sonde lancée au plus
# LAB_DOCTOR_PROBE_TIMEOUT secondes depuis le checkout principal ; muette, en échec ou hors ligne : ignorée en silence)
DOC_SERVED_DAYS=2
doctor_targets() {
  local p="$1" root="$2" t nop="" old="" s0 wf="" diff="" probe got rev reg i ep lanes="" w; local -a l=() h=() m=() sn=()
  [ "$(deploy_targets)" != none ] || [ -n "$(deploy_registries)" ] || return 0
  for t in $(deploy_targets); do [ "$t" = none ] || [ -n "$(deploy_cfg probe "$t")" ] || nop="${nop:+$nop }$t"; done
  for t in $(deploy_registries); do
    reg="$(deploy_dir)/$t"; ep="$(state_field "$reg" epoch)"
    read -r -a l <<<"$(state_field "$reg" lanes)" || true
    read -r -a h <<<"$(state_field "$reg" heads)" || true
    read -r -a m <<<"$(state_field "$reg" merged)" || true
    read -r -a sn <<<"$(state_field "$reg" since)" || true   # première mise en ligne de chaque couloir (absente : registre d'avant)
    for i in "${!l[@]}"; do
      in_words "${l[$i]}" "${m[@]+"${m[@]}"}" && continue
      deploy_head_merged "${h[$i]:-}" "" 2>/dev/null && continue
      lanes="${lanes:+$lanes ; }$t serves ${l[$i]}"
      s0="${sn[$i]:-$ep}"; [[ "$s0" =~ ^[0-9]+$ ]] || s0="$ep"
      if [[ "$s0" =~ ^[0-9]+$ ]] && [ $(( $(date -u +%s) - s0 )) -gt $(( DOC_SERVED_DAYS * 86400 )) ]; then
        old="${old:+$old ; }$t serves ${l[$i]} since $(date -u -r "$s0" +%Y-%m-%d)"
      fi
    done
    probe="$(deploy_cfg probe "$t")"; rev="$(state_field "$reg" rev)"
    if [ -n "$probe" ] && [[ "$rev" =~ ^[0-9a-f]{7,40}$ ]]; then
      got="$( (cd "$P_ROOT" && LAB_DEPLOY_TARGET="$t" with_timeout "${LAB_DOCTOR_PROBE_TIMEOUT:-15}" bash -c "$probe") </dev/null 2>/dev/null | grep -oE '[0-9a-f]{7,40}' | head -1 || true)"
      case "$rev" in "${got:-$rev}"*) ;; *) diff="${diff:+$diff ; }$t serves ${got:0:7}, register ${rev:0:7}" ;; esac
    fi
  done
  if [ -n "$lanes" ] && compgen -G "$root/.github/workflows/*.y*ml" >/dev/null; then
    for w in "$root"/.github/workflows/*.y*ml; do
      grep -qE 'wrangler (deploy|publish)|gcloud (run|app|functions) deploy|vercel .*--prod|netlify deploy|fly(ctl)? deploy|firebase deploy|rsync .*[^ ]+:' "$w" 2>/dev/null \
        && wf="${wf:+$wf, }$(basename "$w")"
    done
  fi
  if [ -n "$nop" ]; then flag "$p.targets.probe" warn "$nop" "no probe.<target>=: the served revision is never checked; lab deploy --add writes a probe from a template"
  else flag "$p.targets.probe" ok all; fi
  if [ -n "$wf" ]; then flag "$p.targets.workflow" warn "$wf" "this workflow deploys while $lanes, not merged: a merge would trigger it and erase that lane — make the workflow deploy through lab deploy, or merge the lane first"
  else flag "$p.targets.workflow" ok none; fi
  if [ -n "$old" ]; then flag "$p.targets.old_lane" warn "$old" "unmerged lane served for more than $DOC_SERVED_DAYS days: merge it, or withdraw it (lab deploy <target> --retire <lane>)"
  else flag "$p.targets.old_lane" ok none; fi
  if [ -n "$diff" ]; then flag "$p.targets.probe_registry" warn "$diff" "the target no longer serves the recorded revision: did a deployment outside lab replace it? check it, then lab deploy <target>"
  else flag "$p.targets.probe_registry" ok "matching or not read"; fi
}
# doctor_ci_workflows <projet> <root> : <projet>.ci.workflows, avertissement seulement (lab n'écrase jamais un workflow ; lab new pose le gabarit dans un projet sans workflow, lot 04 de ci-sobre ;
# décisions 6 et 7 du lot 13 de lab-enhancement). Par workflow : déclenché sur pull_request sans aucun job gardé contre les brouillons,
# sans concurrency (une révision neuve n'annule pas l'ancienne), ou sur push de toute branche (chaque push paie, PR ou non).
# Garde brouillon sans ready_for_review dans les types : avertie aussi (couloir veilleur-saute).
doctor_ci_workflows() {
  local p="$1" root="$2" out n
  compgen -G "$root/.github/workflows/*.y*ml" >/dev/null || { flag "$p.ci.workflows" ok "no workflow"; return; }
  command -v ruby >/dev/null 2>&1 || { flag "$p.ci.workflows" warn "not read" "ruby not found: CI guards not checked"; return; }
  out="$(ruby -Ku -ryaml -e '
    ARGV.each do |file|
      w = (YAML.safe_load(File.read(file), aliases: true) rescue nil)
      unless w.is_a?(Hash) then puts "#{File.basename(file)}: unreadable"; next end
      on = w.key?("on") ? w["on"] : w[true]
      on = { on => nil } if on.is_a?(String)
      on = on.to_h { |e| [e, nil] } if on.is_a?(Array)
      on = {} unless on.is_a?(Hash)
      miss = []
      text = File.read(file)
      if on.key?("pull_request") && !text.include?("pull_request.draft")
        miss << "draft guard missing (if: github.event.pull_request.draft == false on costly jobs)"
      end
      # garde brouillon sans ready_for_review dans les types (absents : opened, synchronize, reopened) : le passage « prête »
      # ne lance aucune exécution, le job gardé reste sauté et lab merge finit rouge (couloir veilleur-saute)
      pr = on["pull_request"]
      if on.key?("pull_request") && text.include?("pull_request.draft") && !(pr.is_a?(Hash) && Array(pr["types"]).map(&:to_s).include?("ready_for_review"))
        miss << "ready_for_review missing from pull_request types while a draft guard exists (marking the PR ready starts no run)"
      end
      push = on["push"].is_a?(Hash) ? on["push"] : {}
      br = Array(push["branches"])
      tags_only = push.key?("tags") && !push.key?("branches") && !push.key?("branches-ignore")
      # un push limité aux tags (release) garde sa file : cancel-in-progress y annulerait une release en cours
      if (on.key?("pull_request") || (on.key?("push") && !tags_only)) && !text.match?(/^concurrency:|^\s+concurrency:/)
        miss << "concurrency missing (cancel-in-progress: true)"
      end
      all = push.key?("branches-ignore") || (br.empty? && !push.key?("tags")) || br.any? { |b| b.to_s.start_with?("*") }
      miss << "push on every branch (limit to branches: [main])" if on.key?("push") && all
      puts "#{File.basename(file)}: #{miss.join(", ")}" unless miss.empty?
    end' "$root"/.github/workflows/*.y*ml 2>/dev/null)" || out="reading the workflows failed"
  n="$(printf '%s' "$out" | grep -c . || true)"
  if [ "$n" = 0 ]; then flag "$p.ci.workflows" ok "guarded"; return; fi
  flag "$p.ci.workflows" warn "$(printf '%s' "$out" | paste -sd ';' - | sed 's/;/ ; /g')" \
    "fix: start again from the lab template templates/project/ci.yml (draft, concurrency, Linux first); lab never overwrites a workflow"
}
# doctor_ci_measures <projet> : les minutes de CI des 7 derniers jours (lot 04 de ci-sobre), lues dans le cache que lab next et lab close
# rafraîchissent (lib/ci_measure.sh), jamais gh. Sans cache ou mesure de plus de 7 jours : not measured, jamais rouge. Au-delà du seuil :
# avertissement ; au-delà du seuil et de la baseline : rouge (--freeze recale).
doctor_ci_measures() {
  local p="$1" v
  if ! ci_fresh "$p" "$CI_WINDOW_DAYS"; then flag "$p.ci.measures" ok "not measured" "lab next and lab close measure the CI minutes once a day (gh)"; return; fi
  v="$(ci_get "$p" MINUTES_WEEK)"; check "$p.ci.minutes_week" "${v:-?}" 1500 warn "equivalent minutes over $(ci_get "$p" PERIOD) (macOS × 10)" cliquet-au-dela
  v="$(ci_get "$p" RUNS_PER_PR)"; check "$p.ci.runs_per_pr" "${v:-?}" 3 warn "CI runs per pull request; drafts and concurrency cancel the useless ones" cliquet-au-dela
  v="$(ci_get "$p" HEAVY_PR_JOBS)"; check "$p.ci.heavy_pr_jobs" "${v:-?}" 0 warn "pull request jobs over 15 min outside full-suite: run targeted tests, the full suite once per lane" cliquet-au-dela
  v="$(ci_get "$p" NIGHT_RED_DAYS)"; check "$p.ci.night_red_days" "${v:-?}" 2 warn "red nights of the base over 7 days: fix them in a fix/ lane" cliquet-au-dela
}
# doctor_lot_sizes <projet> <docs> : <projet>.batch_files.size, sans cliquet (une fiche grossit pendant son lot) — octets de la plus lourde
# des lot-[0-9]*.md placées sous lots/ et lots/<couloir>/ ; preuves/, briefs et CHANGELOG n'en sont pas. Au-delà de 30 000 octets :
# avertissement ; au-delà de 60 000, rouge si la ligne **Créé** date du 2026-09-16 ou après, avertissement pour une fiche antérieure ou
# sans date lisible (une fiche de 193 Ko dont seule la Reprise servait, sans signal avant : constat 1 et A7 du brief, lot 06).
DOC_LOT_WARN=30000; DOC_LOT_RED=60000; DOC_LOT_RULE=2026-09-16
doctor_lot_sizes() {
  local p="$1" docs="$2" f summary max n_warn n_red n_old top sev=warn note=""
  summary="$(
    for f in "$docs"/lots/lot-[0-9]*.md "$docs"/lots/*/lot-[0-9]*.md; do
      [ -f "$f" ] || continue
      [ "${f#"$docs"/lots/preuves/}" = "$f" ] || continue   # pas de case dans $( ) : bash 3.2 lit mal sa parenthèse
      printf '%s\t%s\t%s\n' "$(wc -c <"$f" | tr -d ' ')" \
        "$(lang_norm <"$f" | sed -n 's/.*\*\*Créé\*\* *: *\([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\).*/\1/p' | head -1)" "${f#"$docs"/lots/}"
    done | LC_ALL=C sort -t "$(printf '\t')" -k1,1nr -k3,3 | LC_ALL=C awk -F '\t' -v w="$DOC_LOT_WARN" -v r="$DOC_LOT_RED" -v rule="$DOC_LOT_RULE" '
      NR == 1 { max = $1 }
      $1 + 0 > w + 0 { nw++; if (nw <= 3) top = top (nw > 1 ? ", " : "") $3 " (" $1 ")" }
      $1 + 0 > r + 0 { if ($2 != "" && ($2 "") >= (rule "")) nr++; else no++ }
      END { printf "%d\t%d\t%d\t%d\t%s\n", max, nw, nr, no, top }'
  )"
  max="${summary%%$'\t'*}"; summary="${summary#*$'\t'}"; n_warn="${summary%%$'\t'*}"; summary="${summary#*$'\t'}"
  n_red="${summary%%$'\t'*}"; summary="${summary#*$'\t'}"; n_old="${summary%%$'\t'*}"; top="${summary#*$'\t'}"
  [ "$n_red" = 0 ] || sev=red
  if [ "$n_warn" != 0 ]; then
    note="above $DOC_LOT_WARN bytes: $n_warn — $top"
    [ "$n_warn" -le 3 ] || note="$note … and $((n_warn - 3)) more"
    [ "$n_red" = 0 ] || note="$note; above $DOC_LOT_RED bytes, created on or after $DOC_LOT_RULE: $n_red, red"
    [ "$n_old" = 0 ] || note="$note; above $DOC_LOT_RED bytes, created before $DOC_LOT_RULE: warning only ($n_old)"
    note="$note; fix: move the log story to lots/<lane>/preuves/lot-NN-<slug>.md and keep the link"
  fi
  check "$p.batch_files.size" "$max" "$DOC_LOT_WARN" "$sev" "$note" sans-cliquet
}
# doctor_tests_weakened <projet> <root> : <projet>.tests.weakened, dans un couloir seulement, sans cliquet —
# rouge si le lot retire plus d'assertions qu'il n'en ajoute ou ajoute un skip ; un motif écrit dans la fiche le ramène à WARN
doctor_tests_weakened() {
  local p="$1" root="$2" base out added removed skips reason value
  [ -f "$root/.lab/meta" ] && is_worktree "$root" 2>/dev/null || return 0
  base="$(tests_lot_base "$root")"; [ -n "$base" ] || return 0
  out="$(tests_weakened "$root" "$base" "$(config_get "$p" tests_files)" "$(config_get "$p" tests_assert)" "$(config_get "$p" tests_skip)")" || true   # motif invalide : awk échoue, le compte vide est signalé plus bas
  added="$(printf '%s\n' "$out" | sed -n 's/^TESTS_ASSERT_ADDED=//p')"; removed="$(printf '%s\n' "$out" | sed -n 's/^TESTS_ASSERT_REMOVED=//p')"
  skips="$(printf '%s\n' "$out" | sed -n 's/^TESTS_SKIP_ADDED=//p')"; value="-$removed +$added skip $skips"
  if ! [[ "$added:$removed:$skips" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]]; then flag "$p.tests.weakened" warn unreadable "cannot count; check tests_files=, tests_assert= and tests_skip= (ERE) in the config"; return 0; fi
  if [ "$removed" -le "$added" ] && [ "$skips" = 0 ]; then flag "$p.tests.weakened" ok "$value"; return 0; fi
  reason="$(tests_reason "$(wt_lot_file "$root")")"
  if [ -n "$reason" ]; then flag "$p.tests.weakened" warn "$value" "reason: $reason"
  else flag "$p.tests.weakened" red "$value" "restore the test; otherwise write 'Tests removed: <reason>' in the batch file"; fi
}
# doctor_criteria_proofs <projet> <root> : <projet>.criteria.evidence, dans un couloir seulement, sans cliquet —
# chaque critère « - [ ] Cn … » de la fiche est cité en mot entier au journal ou dans preuves/<fiche> ; WARN en cours, RED clos
doctor_criteria_proofs() {
  local p="$1" root="$2" f lines ids id proofs n=0 total=0 bare missing="" sev=warn
  [ -f "$root/.lab/meta" ] && is_worktree "$root" 2>/dev/null || return 0
  f="$(wt_lot_file "$root")"; [ -f "$f" ] || return 0
  lines="$(lot_section_lines "$f" 'Critères de fin' | sed -n 's/^- \[[ xX]\][[:space:]]*//p' | grep '[^[:space:]]' || true)"
  [ -n "$lines" ] || return 0
  ids="$(printf '%s\n' "$lines" | sed -nE 's/^[*_`]*(C[0-9]+)([^0-9A-Za-z_].*)?$/\1/p')"
  if [ -z "$ids" ]; then flag "$p.criteria.evidence" warn "not numbered" "number them C1, C2… under the exit criteria"; return 0; fi
  proofs="$(lot_section_lines "$f" Journal; cat "$(dirname "$f")/preuves/$(basename "$f")" 2>/dev/null || true)"
  local waiting; waiting=" $(wait_open_lines "$f" | cut -f1 | paste -sd' ' -) "   # en attente de sa date : pas encore à citer (lot 02 d'autonomie-tours)
  local held=0
  for id in $ids; do
    case "$waiting" in *" $id "*) held=$((held + 1)); continue ;; esac
    total=$((total + 1))   # here-string, jamais un tube : grep -q fermerait le tube et pipefail compterait un critère cité comme absent (revue)
    if grep -Eq "(^|[^0-9A-Za-z_])$id([^0-9A-Za-z_]|\$)" <<<"$proofs"; then n=$((n + 1)); else missing="$missing $id"; fi
  done
  bare=$(( $(printf '%s\n' "$lines" | wc -l) - total - held ))
  if [ -z "$missing" ] && [ "$bare" -gt 0 ]; then flag "$p.criteria.evidence" warn "$n/$total" "not numbered: $bare"; return 0; fi
  if [ -z "$missing" ]; then flag "$p.criteria.evidence" ok "$n/$total"; return 0; fi
  case "$(lot_state "$f")" in closed*) sev=red ;; esac
  flag "$p.criteria.evidence" "$sev" "$n/$total" "not cited:$missing"
}
# doctor_waiting <projet> <root> (lot 02 d'autonomie-tours) : <projet>.batch.waiting, dans un couloir — rouge pour une fiche close
# qui garde une attente ouverte (la mesure serait perdue : remettre l'État en attente, ou la marquer mesurée) ; ok qui nomme la
# prochaine attente ; rien sans attente
doctor_waiting() {
  local p="$1" root="$2" f bad="" w
  [ -f "$root/.lab/meta" ] && is_worktree "$root" 2>/dev/null || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$(lot_state "$f")" in closed*) wait_has_open "$f" && bad="$bad${bad:+, }$(basename "$f" .md) ($(wait_open_lines "$f" | cut -f1 | paste -sd' ' -))" ;; esac
  done < <(wait_lane_files "$root")
  if [ -n "$bad" ]; then flag "$p.batch.waiting" red "closed with open waiting" "$bad: set the State back to waiting, or lab batch wait --done <Cn> once measured"; return 0; fi
  w="$(wait_lane_first "$root")"; [ -z "$w" ] || flag "$p.batch.waiting" ok "$(wait_summary "$w")"
}
cmd_doctor() {
  local freeze=0 project_only=0 p root="" root_project="" arg baseline_bad=0; local -a ps=()
  [ "$DOC_REPORT" != 1 ] || { kv REPORT_VERSION 1; sep; }
  for arg in "$@"; do
    if [[ "$arg" =~ [[:cntrl:]] ]]; then doctor_error OPTIONS; return 2; fi
  done
  case "${LAB_DOCTOR_SKILLS_WARN_LIMIT:-}" in
    '') ;;
    *) if ! [[ "$LAB_DOCTOR_SKILLS_WARN_LIMIT" =~ ^[0-9]+$ ]]; then doctor_error SKILLS_LIMIT; return 2; fi ;;
  esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --report) shift ;;
      --freeze) freeze=1; shift ;;
      --project-only) project_only=1; shift ;;
      --root) [ "$#" -ge 2 ] && [ -n "$2" ] || { doctor_error ROOT; return 2; }; root="$2"; shift 2 ;;
      -*) doctor_error OPTIONS; return 2 ;;
      *) p="$(resolve_project "$1" 2>/dev/null)" || { doctor_error PROJECT; return 2; }; ps+=("$p"); shift ;;
    esac
  done
  if [ "$DOC_REPORT:$freeze" = 1:1 ]; then doctor_error FREEZE_REPORT; return 2; fi
  if [ -n "$root" ]; then
    root="$(repo_root "$root" 2>/dev/null)" || { doctor_error ROOT; return 2; }
    root="$(real_path "$root")"
    root_project="$(project_from_cwd "$root" 2>/dev/null)" || { doctor_error ROOT; return 2; }
    [ "${#ps[@]}" -le 1 ] || { doctor_error ROOT; return 2; }
    if [ "${#ps[@]}" -eq 0 ]; then ps=("$root_project")
    elif [ "${ps[0]}" != "$root_project" ]; then doctor_error ROOT; return 2
    fi
  fi
  DOC_BASE_JSON=""
  if [ -e "$BASELINE" ] || [ -L "$BASELINE" ]; then
    if DOC_BASE_JSON="$(jq -cse 'if length==1 and (.[0] | type=="object" and all(.[]; type=="number" and .>=0 and floor==.)) then .[0] else error("invalid baseline") end' "$BASELINE" 2>/dev/null)"; then :
    else DOC_BASE_JSON=''; baseline_bad=1; fi
  fi
  if [ "$baseline_bad:$project_only" = 1:0 ]; then flag global.baseline red unreadable 'Baseline unreadable or invalid; restore the chosen file without recalibrating it.'; fi
  [ "$project_only" = 1 ] || doctor_global
  if [ "${#ps[@]}" -eq 0 ]; then
    if p="$(project_from_cwd 2>/dev/null)"; then ps=("$p"); else while IFS= read -r p; do ps+=("$p"); done < <(project_names); fi
  fi
  if [ "${#ps[@]}" -eq 0 ]; then
    if [ "$DOC_REPORT" = 1 ]; then doctor_say 'No registered project to check.' >&3
    else doctor_say 'No registered project to check.' >&2; fi
  fi
  for p in "${ps[@]+"${ps[@]}"}"; do
    DOC_PROJECT="$p"; DOC_PROJECT_INDEX=$((DOC_PROJECT_INDEX + 1))
    if [[ "$p" =~ [[:cntrl:]] ]] || ! (load_project "$p") 2>/dev/null; then doctor_error PROJECT; return 2; fi
    if [ "$baseline_bad:$project_only" = 1:1 ]; then flag "$p.baseline" red unreadable 'Baseline unreadable or invalid; restore the chosen file without recalibrating it.'; fi
    doctor_project "$p" "$root"
  done
  if [ "$freeze:$baseline_bad" = 1:0 ]; then
    mkdir -p "$(dirname "$BASELINE")"
    { [ -n "$DOC_BASE_JSON" ] && printf '%s\n' "$DOC_BASE_JSON" || echo '{}'; } >"$BASELINE.old"
    printf '%s' "$DOC_METRICS" | jq -Rs 'split("\n") | map(select(length>0) | capture("^(?<k>.+)=(?<v>[0-9]+)$") | {(.k): (.v|tonumber)}) | add // {}' \
      | jq -s '.[0] * .[1]' "$BASELINE.old" - >"$BASELINE.new" && mv "$BASELINE.new" "$BASELINE"; rm -f "$BASELINE.old"
    doctor_say "lab: baseline frozen: $BASELINE ($(jq 'length' "$BASELINE") measurements)" >&2
  fi
  DOC_DONE=yes
  if [ "$DOC_REPORT" = 1 ]; then
    if [ "$DOC_RED" = 1 ]; then printf 'RED: at least one check is red.\n' >&3; return 1; fi
    printf 'OK: no red.\n' >&3
  else
    if [ "$DOC_RED" = 1 ]; then log "RED: at least one check is red"; return 1; fi
    log "OK: no red"
  fi
}
