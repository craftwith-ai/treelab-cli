# shellcheck shell=bash
# cmux.sh — groupe + workspace d'ancrage = projet ; surface = main ou couloir.
# Tout est optionnel : sans cmux, lab imprime la commande à lancer.
has_cmux() { [ "${LAB_NO_CMUX:-0}" != 1 ] && command -v cmux >/dev/null 2>&1; }
cmx() { CMUX_QUIET=1 with_timeout 10 cmux "$@"; }

cmux_group_json() {
  cmx workspace-group list --json 2>/dev/null | jq -c --arg n "$1" '.groups[]? | select(.name==$n)' | head -1
}
cmux_group_ref() { cmux_group_json "$1" | jq -r '.ref // empty'; }
cmux_group_anchor() {
  cmux_group_json "$1" | jq -r '.anchor_workspace_id // .anchor_workspace_ref // .anchorWorkspaceId // .anchorWorkspaceID // empty'
}
cmux_ensure_group() { # <nom> <cwd-ancre> → ref
  local ref; ref="$(cmux_group_ref "$1")"
  [ -n "$ref" ] || { cmx workspace-group create --name "$1" --cwd "$2" >/dev/null 2>&1; ref="$(cmux_group_ref "$1")"; }
  printf '%s\n' "$ref"
}

cmux_ws_uuid() {
  cmx workspace list --json 2>/dev/null | jq -r --arg r "$1" '.workspaces[]? | select(.ref==$r or .id==$r) | .id' | head -1
}
cmux_ws_exists() { [ -n "$1" ] && [ -n "$(cmux_ws_uuid "$1")" ]; }
cmux_ws_title() {
  cmx workspace list --json 2>/dev/null | jq -r --arg r "$1" '.workspaces[]? | select(.ref==$r or .id==$r) | .title // empty' | head -1
}
cmux_same_workspace() { # <workspace-a> <workspace-b>
  local a b
  a="$(cmux_ws_uuid "$1")"; b="$(cmux_ws_uuid "$2")"
  [ -n "$a" ] && [ "$a" = "$b" ]
}
cmux_project_workspace_matches() { # <projet> <workspace> — vrai seulement si le workspace est encore l'ancre du groupe
  local anchor workspace
  anchor="$(cmux_group_anchor "$1")"; workspace="$(cmux_ws_uuid "$2")"
  [ -n "$anchor" ] && [ -n "$workspace" ] && [ "$(cmux_ws_uuid "$anchor")" = "$workspace" ]
}
cmux_surface_ref() { # <workspace> <uuid-ou-ref> → référence de surface reconnue par cmux
  cmx tree --workspace "$1" --json 2>/dev/null | jq -r --arg s "$2" \
    '.. | objects | select((.id? == $s or .ref? == $s) and ((.ref? // "") | startswith("surface:"))) | (.ref // .id)' | head -1
}
cmux_surface_exists() { [ -n "$2" ] && [ -n "$(cmux_surface_ref "$1" "$2")" ]; }
cmux_surface_title() { # <workspace> <surface> → titre visible
  cmx tree --workspace "$1" --json 2>/dev/null | jq -r --arg s "$2" \
    '.. | objects | select(.id? == $s or .ref? == $s) | .title // empty' | head -1
}
cmux_named_surface() { # <workspace> <titre> → référence de la première surface qui porte ce titre
  cmx tree --workspace "$1" --json 2>/dev/null | jq -r --arg title "$2" \
    '.. | objects | select(((.ref? // "") | startswith("surface:")) and .title? == $title) | (.ref // .id)' | head -1
}
cmux_named_surfaces() { # <workspace> <titre> → références de toutes les surfaces qui portent exactement ce titre, une par ligne
  cmx tree --workspace "$1" --json 2>/dev/null | jq -r --arg title "$2" \
    '.. | objects | select(((.ref? // "") | startswith("surface:")) and .title? == $title) | (.ref // .id)' | awk '!seen[$0]++'
}
# cmux_lane_tab <workspace> <surface> <nom> → « <workspace>⇥<surface>⇥<voie> » : l'onglet d'un couloir du projet $P_NAME.
# reference : la référence enregistrée répond encore, dans l'ancre du projet, sous ce nom (comportement d'avant) ;
# name : sinon, si une référence est enregistrée, un seul onglet porte exactement ce nom dans le workspace d'ancrage actuel du projet
# (cmux renumérote ses références : surface:247 → surface:10, retour 3 du lot 01) ; absent : aucun ; ambiguous : plusieurs, références
# séparées par une espace. Jamais de repli sans référence enregistrée (un ancien onglet du même nom n'appartient pas à un couloir neuf),
# pour main, hors de l'ancre du groupe du projet, ni dans une ancre héritée qui ne porte pas son nom (lot 06).
cmux_lane_tab() {
  local ws="$1" surface="$2" name="$3" anchor refs
  if [ -n "$ws" ] && [ -n "$surface" ] && cmux_project_workspace_matches "$P_NAME" "$ws" \
    && [ "$(cmux_surface_title "$ws" "$surface")" = "$name" ]; then
    ws="$(cmux_ws_uuid "$ws")"
    printf '%s\t%s\treference\n' "$ws" "$(cmux_surface_ref "$ws" "$surface")"; return 0
  fi
  [ -n "$surface" ] || { printf '\t\tabsent\n'; return 0; }
  anchor="$(cmux_group_anchor "$P_NAME")"; [ -z "$anchor" ] || anchor="$(cmux_ws_uuid "$anchor")"
  if [ -z "$anchor" ] || [ -z "$name" ] || [ "$name" = main ] || [ "$(cmux_ws_title "$anchor")" != "$P_NAME" ]; then
    printf '%s\t\tabsent\n' "$anchor"; return 0
  fi
  refs="$(cmux_named_surfaces "$anchor" "$name")"
  case "$(printf '%s\n' "$refs" | awk 'NF {n++} END {print n + 0}')" in
    0) printf '%s\t\tabsent\n' "$anchor" ;;
    1) printf '%s\t%s\tname\n' "$anchor" "$refs" ;;
    *) printf '%s\t%s\tambiguous\n' "$anchor" "$(printf '%s' "$refs" | tr '\n' ' ')" ;;
  esac
}
# cmux_tab_field <résultat de cmux_lane_tab> <workspace|surface|way> : découpage à la main — la tabulation est un blanc pour read,
# qui avalerait la surface vide d'un onglet absent
cmux_tab_field() {
  case "$2" in
    workspace) printf '%s\n' "${1%%$'\t'*}" ;;
    way) printf '%s\n' "${1##*$'\t'}" ;;
    surface) local rest="${1#*$'\t'}"; printf '%s\n' "${rest%$'\t'*}" ;;
  esac
}
cmux_first_surface() { # <workspace> → référence de la première surface
  cmx tree --workspace "$1" --json 2>/dev/null | jq -r \
    '.. | objects | select(((.ref? // "") | startswith("surface:"))) | (.ref // .id)' | head -1
}

cmux_create_surface() { # <workspace> <nom> <cwd> [focus] → référence de surface
  local out ref resolved i
  out="$(cmx new-surface --type terminal --workspace "$1" --working-directory "$3" --focus "${4:-true}" 2>&1)" || { warn "cmux: $out"; return 1; }
  ref="$(printf '%s' "$out" | sed -n 's/.*\(surface:[0-9][0-9]*\).*/\1/p')"
  [ -n "$ref" ] || { warn "cmux: no surface reference in: $out"; return 1; }
  resolved=""; i=0
  while [ "$i" -lt 3 ]; do i=$((i + 1)); resolved="$(cmux_surface_ref "$1" "$ref")"; [ -n "$resolved" ] && break; done
  [ -n "$resolved" ] || { warn "cmux: surface $ref not found after its creation"; return 1; }
  cmx rename-tab --workspace "$1" --surface "$resolved" --title "$2" >/dev/null 2>&1 || true
  printf '%s\n' "$resolved"
}

cmux_create_project_workspace() { # <groupe> <projet> <main-checkout> → UUID du nouveau workspace d'ancrage
  local out ref workspace main i
  out="$(cmx new-workspace --name "$2" --cwd "$3" --focus false --group "$1" --group-placement top 2>&1)" \
    || { warn "cmux: $out"; return 1; }
  ref="$(printf '%s' "$out" | sed -n 's/.*\(workspace:[0-9][0-9]*\).*/\1/p')"
  [ -n "$ref" ] || { warn "cmux: no workspace reference in: $out"; return 1; }
  workspace=""; i=0
  while [ "$i" -lt 3 ]; do i=$((i + 1)); workspace="$(cmux_ws_uuid "$ref")"; [ -n "$workspace" ] && break; done
  [ -n "$workspace" ] || { warn "cmux: workspace $ref not found after its creation"; return 1; }
  main="$(cmux_first_surface "$workspace")"; [ -n "$main" ] || return 1
  cmx rename-tab --workspace "$workspace" --surface "$main" --title main >/dev/null 2>&1 || return 1
  cmx tab-action --workspace "$workspace" --surface "$main" --action pin >/dev/null 2>&1 || true
  cmx workspace-group set-anchor --group "$1" --workspace "$workspace" >/dev/null 2>&1 || return 1
  printf '%s\n' "$workspace"
}

cmux_prepare_project() { # <projet> <main-checkout> → groupe<TAB>workspace-ancre
  local group workspace main created=0
  group="$(cmux_group_ref "$1")"
  if [ -z "$group" ]; then group="$(cmux_ensure_group "$1" "$2")"; created=1; fi
  [ -n "$group" ] || return 1
  workspace="$(cmux_group_anchor "$1")"; [ -n "$workspace" ] || return 1
  workspace="$(cmux_ws_uuid "$workspace")"; [ -n "$workspace" ] || return 1
  if [ "$created" = 0 ] && [ "$(cmux_ws_title "$workspace")" != "$1" ]; then
    workspace="$(cmux_create_project_workspace "$group" "$1" "$2")" || return 1
    main="$(cmux_named_surface "$workspace" main)"
  elif [ "$created" = 1 ]; then
    main="$(cmux_first_surface "$workspace")"
  else
    main="$(cmux_named_surface "$workspace" main)"
  fi
  [ -n "$main" ] || main="$(cmux_create_surface "$workspace" main "$2" false)" || return 1
  cmx rename-tab --workspace "$workspace" --surface "$main" --title main >/dev/null 2>&1 || true
  cmx tab-action --workspace "$workspace" --surface "$main" --action pin >/dev/null 2>&1 || true
  printf '%s\t%s\n' "$group" "$workspace"
}

cmux_focus() { # <workspace> [surface]
  cmx select-workspace --workspace "$1" >/dev/null 2>&1 || return 1
  [ -z "${2:-}" ] || cmx focus-panel --workspace "$1" --panel "$2" >/dev/null 2>&1
}
cmux_send() { # <workspace> <surface> <texte>
  cmx send --workspace "$1" --surface "$2" -- "$3" >/dev/null
}
cmux_close_workspace() { cmux_ws_exists "$1" && cmx close-workspace --workspace "$1" >/dev/null 2>&1 || true; }
cmux_close_surface() {
  cmux_surface_exists "$1" "$2" && cmx close-surface --workspace "$1" --surface "$2" >/dev/null 2>&1 || true
}
cmux_close_named_surface() { # <workspace> <surface> <nom-attendu> — ne ferme jamais une référence réattribuée
  [ -n "$2" ] && [ "$(cmux_surface_title "$1" "$2")" = "$3" ] || return 1
  cmx close-surface --workspace "$1" --surface "$2" >/dev/null 2>&1
}
cmux_color() { cmx workspace-action --action set-color --workspace "$1" --color "$2" >/dev/null 2>&1 || true; }
cmux_notify() { # <titre> <corps> [workspace] [surface]
  has_cmux || return 0
  if [ -n "${4:-}" ]; then cmx notify --title "$1" --body "$2" --workspace "$3" --surface "$4" >/dev/null 2>&1 || true
  elif [ -n "${3:-}" ]; then cmx notify --title "$1" --body "$2" --workspace "$3" >/dev/null 2>&1 || true
  else cmx notify --title "$1" --body "$2" >/dev/null 2>&1 || true; fi
}
agent_color() { case "$1" in claude) echo Amber ;; codex) echo Teal ;; *) echo Charcoal ;; esac; }

# cmux_identify → « workspace-ref<TAB>surface-ref » de la surface où lab s'exécute ; vide hors de cmux
# ou si la version installée n'expose pas « identify » (le lancement retombe alors sur la frappe).
cmux_identify() {
  cmx identify 2>/dev/null \
    | jq -r '.caller // {} | if (.surface_ref // "") == "" then empty else "\(.workspace_ref // "")\t\(.surface_ref)" end' 2>/dev/null \
    | head -1 || true
}
# cmux_is_current_surface <workspace> <surface> : vrai seulement si lab tourne déjà dans cet onglet-là.
# Strict par construction (exec remplace le shell de l'onglet) : sans identification sûre, on répond non.
cmux_is_current_surface() {
  local id here surface target
  id="$(cmux_identify)"; [ -n "$id" ] || return 1
  # découpage à la main : la tabulation est un blanc IFS, « read » avalerait celle de tête et décalerait les champs
  here="${id%%$'\t'*}"; surface="${id#*$'\t'}"
  [ -n "$surface" ] || return 1
  target="$(cmux_surface_ref "$1" "$2")"; [ -n "$target" ] || return 1
  [ "$(cmux_surface_ref "$1" "$surface")" = "$target" ] || return 1
  here="${here:-${CMUX_WORKSPACE_ID:-}}"
  [ -n "$here" ] || return 1   # workspace inconnu : une même référence de surface peut exister ailleurs — on répond non
  cmux_same_workspace "$here" "$1"
}

# Un repère par couloir, recalculé à l’ouverture. cmux colore les workspaces,
# pas chaque onglet : une pastille nommée évite de recolorer les autres couloirs.
cmux_lane_indicator() { # <workspace> <couloir> <phase> <dernier yes|no|unknown>
  local label color
  case "$3" in
    'in acceptance') label='To try together'; color='#D97706' ;;
    'acceptance passed') label='Acceptance passed'; color='#16A34A' ;;
    'to clarify') label='To clarify'; color='#D97706' ;;
    permanent) label='Permanent lane'; color='#0D9488' ;;
    *)
      if [ "$4" = yes ]; then label='Last planned batch'; color='#D97706'
      else label='Work in progress'; color='#0D9488'; fi ;;
  esac
  # Certains layouts cmux masquent les métadonnées du workspace d’ancrage.
  # Le même repère reste donc visible dans le terminal, sans modifier l’onglet.
  if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    printf '\033[38;2;%d;%d;%dm●\033[0m %s · %s\n' \
      "$((16#${color:1:2}))" "$((16#${color:3:2}))" "$((16#${color:5:2}))" "$2" "$label" >&2
  else
    printf '● %s · %s\n' "$2" "$label" >&2
  fi
  cmx set-status "lab-lane-$2" "$2 · $label" --workspace "$1" --icon circle.fill --color "$color" >/dev/null 2>&1
}
cmux_restart_session() { # <workspace> <surface> <commande courte>
  cmx respawn-pane --workspace "$1" --surface "$2" --command "$3" >/dev/null
}
# cmux_surface_pids <workspace> <surface> → les pid rattachés à cet onglet (terminal, racines, arbre), un par ligne. Une lecture
# en échec, un onglet introuvable ou sans processus rendent un échec : un doute, jamais une absence (lot 10). Un terminal réutilisé
# (tty-collision, mesuré le 2026-11-05 sur cmux) laisse les listes habituelles vides et range les processus de son terminal dans
# unattributed_tty_process_pids : ils comptent aussi (lot 06 de comptes-complets).
cmux_surface_pids() {
  local out
  out="$(cmx top --all --workspace "$1" --processes --json 2>/dev/null)" || return 1
  printf '%s' "$out" | jq -er --arg s "$2" '
    [.. | objects | select(has("tty_process_pids") and (.ref? == $s or .id? == $s))]
    | if length == 0 then error("tab missing") else . end
    | [.[] | (.tty_process_pids // []), (.root_pids // []), (.cmux_process_pids // []), (.top_level_pids // []),
        (.unattributed_tty_process_pids // []),
        [(.processes // []) | .. | objects | .pid? // empty]] | flatten | unique
    | if length == 0 then error("no process") else .[] end' 2>/dev/null
}
cmux_submit() { # <workspace> <surface> <ligne> : collage puis vraie touche Entrée
  cmux_send "$1" "$2" "$3" && cmx send-key --workspace "$1" --surface "$2" Return >/dev/null
}
