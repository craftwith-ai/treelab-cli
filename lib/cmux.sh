# shellcheck shell=bash
# cmux.sh — groupe + workspace d'ancrage = projet ; surface = couloir (tour comprise) ou accueil d'un projet neuf.
# Tout est optionnel : sans cmux, lab imprime la commande à lancer.
# l'app pilotée — cmux, ou le fork de terminal_app= (lot 02 d'app-treelab) : lib/terminal.sh ; des tests chargent ce fichier seul
declare -F terminal_resolve >/dev/null || . "${BASH_SOURCE[0]%/*}/terminal.sh"

has_cmux() {
  [ "${LAB_NO_CMUX:-0}" != 1 ] || return 1
  terminal_resolve
  [ "$TA_OK" = 1 ] || { terminal_warn; return 1; }
}
# cmx <arguments de cmux…> : la commande de l'app pilotée ; dans le terminal d'une autre app, sans ses variables de socket ni d'onglet
# (terminal_socket= posé s'il existe) ; app nommée injoignable : échec, aucun appel. Même nombre de processus qu'avant (env s'exécute
# à la place de la commande)
cmx() {
  local -a pre=(); local v
  terminal_resolve
  case "$TA_SOURCE" in project|global|fork) [ "$TA_OK" = 1 ] || return 1 ;; esac
  # shellcheck disable=SC2086 # liste de noms de variables
  # terminal d'une autre app : aucune de ses variables CMUX_ (sockets, onglet, port, identifiant), CMUX_QUIET seule posée par lab
  if [ "$TA_FOREIGN" = 1 ]; then pre=(env); for v in ${!CMUX_*}; do [ "$v" = CMUX_QUIET ] || pre+=(-u "$v"); done; fi
  if [ -n "$TA_SOCKET" ]; then [ "${#pre[@]}" != 0 ] || pre=(env); pre+=("CMUX_SOCKET_PATH=$TA_SOCKET"); fi
  CMUX_QUIET=1 with_timeout 10 "${pre[@]+"${pre[@]}"}" "${TA_CLI:-cmux}" "$@"
}

cmux_group_json() {
  cmx workspace-group list --json 2>/dev/null | jq -c --arg n "$1" '.groups[]? | select(.name==$n)' | head -1
}
cmux_group_ref() { cmux_group_json "$1" | jq -r '.ref // empty'; }
cmux_group_anchor() {
  cmux_group_json "$1" | jq -r '.anchor_workspace_id // .anchor_workspace_ref // .anchorWorkspaceId // .anchorWorkspaceID // empty'
}
cmux_ensure_group() { # <nom> <cwd-ancre> → ref<TAB>« new » si cet appel a créé le groupe : une lecture manquée n'est pas une création
  local ref made=""; ref="$(cmux_group_ref "$1")"
  if [ -z "$ref" ]; then
    ! cmx workspace-group create --name "$1" --cwd "$2" >/dev/null 2>&1 || made=new
    ref="$(cmux_group_ref "$1")"
  fi
  printf '%s\t%s\n' "$ref" "$made"
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

# cmux_only_surface <workspace> → « <référence>⇥<identifiant> » de son onglet s'il est seul, vide sinon (lecture manquée comprise)
cmux_only_surface() {
  cmx tree --workspace "$1" --json --id-format both 2>/dev/null | jq -r '
    [.. | objects | select((.ref? // "") | startswith("surface:"))] | unique_by(.ref)
    | if length == 1 then .[0] | "\(.ref)\t\(.id // "")" else empty end' 2>/dev/null || true
}

cmux_create_surface() { # <workspace> <nom> <cwd> [focus] → référence de surface
  local out ref resolved end
  out="$(cmx new-surface --type terminal --workspace "$1" --working-directory "$3" --focus "${4:-true}" 2>&1)" || { warn "cmux: $out"; return 1; }
  ref="$(printf '%s' "$out" | sed -n 's/.*\(surface:[0-9][0-9]*\).*/\1/p')"
  [ -n "$ref" ] || { warn "cmux: no surface reference in: $out"; return 1; }
  # dans un espace créé à l'instant, cmux ne liste l'onglet neuf qu'après quelques lectures (la sixième, mesuré le 2026-11-22) ; borne en
  # secondes : une lecture lente peut en durer dix
  end=$((SECONDS + ${LAB_CMUX_TAB_WAIT:-20}))
  while :; do
    resolved="$(cmux_surface_ref "$1" "$ref")"
    if [ -n "$resolved" ] || [ "$SECONDS" -ge "$end" ]; then break; fi
    sleep 0.1
  done
  [ -n "$resolved" ] || { warn "cmux: surface $ref not found after its creation"; return 1; }
  cmx rename-tab --workspace "$1" --surface "$resolved" --title "$2" >/dev/null 2>&1 || true
  printf '%s\n' "$resolved"
}

cmux_create_project_workspace() { # <groupe> <projet> <main-checkout> → UUID du nouveau workspace d'ancrage<TAB>son terminal initial
  local out ref workspace initial i
  out="$(cmx new-workspace --name "$2" --cwd "$3" --focus false --group "$1" --group-placement top 2>&1)" \
    || { warn "cmux: $out"; return 1; }
  ref="$(printf '%s' "$out" | sed -n 's/.*\(workspace:[0-9][0-9]*\).*/\1/p')"
  [ -n "$ref" ] || { warn "cmux: no workspace reference in: $out"; return 1; }
  workspace=""; i=0
  while [ "$i" -lt 3 ]; do i=$((i + 1)); workspace="$(cmux_ws_uuid "$ref")"; [ -n "$workspace" ] && break; done
  [ -n "$workspace" ] || { warn "cmux: workspace $ref not found after its creation"; return 1; }
  initial="$(cmux_first_surface "$workspace")"; [ -n "$initial" ] || return 1
  cmx workspace-group set-anchor --group "$1" --workspace "$workspace" >/dev/null 2>&1 || return 1
  printf '%s\t%s\n' "$workspace" "$initial"
}

# cmux_prepare_project <projet> <main-checkout> → groupe<TAB>workspace-ancre<TAB>terminal initial créé par cet appel, vide sinon.
# Aucun onglet n'est nommé ni épinglé ici (lot 01 d'onglet-tower) : l'appelant ouvre le sien, puis rend ce terminal (cmux_drop_initial).
cmux_prepare_project() {
  local group workspace initial="" created=0
  group="$(cmux_group_ref "$1")"
  if [ -z "$group" ]; then
    group="$(cmux_ensure_group "$1" "$2")"
    [ "${group#*$'\t'}" != new ] || created=1
    group="${group%%$'\t'*}"
  fi
  [ -n "$group" ] || return 1
  workspace="$(cmux_group_anchor "$1")"; [ -n "$workspace" ] || return 1
  workspace="$(cmux_ws_uuid "$workspace")"; [ -n "$workspace" ] || return 1
  if [ "$created" = 1 ]; then initial="$(cmux_only_surface "$workspace")"; initial="${initial%%$'\t'*}"
  elif [ "$(cmux_ws_title "$workspace")" != "$1" ]; then
    workspace="$(cmux_create_project_workspace "$group" "$1" "$2")" || return 1
    initial="${workspace#*$'\t'}"; workspace="${workspace%%$'\t'*}"
  fi
  printf '%s\t%s\t%s\n' "$group" "$workspace" "$initial"
}
# cmux_drop_initial <workspace> <terminal initial> <onglet ouvert> <projet> : ferme, par sa référence, le terminal né avec l'espace une
# fois le vrai onglet ouvert — jamais s'il est le dernier, jamais de force (un programme qui y vivrait le protège) ; refus : il reste
cmux_drop_initial() {
  [ -n "$2" ] && [ "$2" != "$3" ] || return 0
  # l'onglet ouvert, par sa référence ou son identifiant (celui du terminal d'une VM) : le vrai cmux tait les identifiants sans --id-format
  cmx tree --workspace "$1" --json --id-format both 2>/dev/null | jq -e --arg s "$3" 'any(.. | objects; .ref? == $s or .id? == $s)' >/dev/null 2>&1 || return 0
  cmx close-surface --workspace "$1" --surface "$2" >/dev/null 2>&1 \
    || warn "cmux: the first terminal of $4 stays open (cmux did not close it): close it yourself"
}
# cmux_spare_tab <workspace> <onglet à fermer> <dossier> : cmux ne ferme jamais le dernier onglet d'un espace, même de force. Sans onglet
# main ni tour, celui du couloir peut être seul : un terminal ordinaire (ni nommé, ni épinglé, sans prendre le focus) s'ouvre d'abord à
# côté — fermeture acceptée aussitôt (mesuré le 2026-11-22)
cmux_spare_tab() {
  local only; only="$(cmux_only_surface "$1")"; [ -n "$only" ] || return 0
  [ "${only%%$'\t'*}" = "$2" ] || [ "${only#*$'\t'}" = "$2" ] || return 0
  cmx new-surface --type terminal --workspace "$1" --working-directory "$3" --focus false >/dev/null 2>&1 || true
}
# cmux_pin_first <workspace> <surface> : épinglé, puis placé en tête — dans cet ordre, un onglet non épinglé ne passe jamais devant un
# onglet épinglé. Placer sélectionne l'onglet dans son espace, même avec --focus false : avant le focus (mesuré sur 0.65.2)
cmux_pin_first() {
  cmx tab-action --workspace "$1" --surface "$2" --action pin >/dev/null 2>&1 \
    && cmx reorder-surface --workspace "$1" --surface "$2" --index 0 --focus false >/dev/null 2>&1
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
  terminal_resolve; [ "$TA_FOREIGN" != 1 ] || return 0   # dans le terminal d'une autre app : jamais un onglet de l'app pilotée
  cmx identify 2>/dev/null \
    | jq -r '.caller // {} | if (.surface_ref // "") == "" then empty else "\(.workspace_ref // "")\t\(.surface_ref)" end' 2>/dev/null \
    | head -1 || true
}
# cmux_is_current_surface <workspace> <surface> : vrai seulement si lab tourne déjà dans cet onglet-là.
# Strict par construction (exec remplace le shell de l'onglet) : sans identification sûre, on répond non.
cmux_is_current_surface() {
  local id here surface target
  terminal_resolve; [ "$TA_FOREIGN" != 1 ] || return 1   # lot 02 d'app-treelab : le terminal d'une autre app n'est jamais l'onglet
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
# cmux_terminals → « <onglet>⇥<workspace>⇥<surface>⇥<terminal> » de chaque onglet de l'app dont le vrai terminal se prouve. Le champ tty de
# cmux ne suffit pas : nul pour la moitié des onglets, il reste parfois celui d'un autre (5 sur 138 mesurés le 2026-11-22 sur 0.65.2).
# La preuve : le premier processus du terminal (son parent, cmux, n'a pas de terminal) est né à la seconde où cmux dit l'avoir créé, ou à
# la suivante. Un candidat dont un processus se dit d'un autre onglet (CMUX_SURFACE_ID, hérité de cmux ; macOS cache l'environnement de
# ses propres shells) est écarté, celui qui se dit de cet onglet l'emporte ; sans candidat unique, pour un onglet qui se dit ailleurs, ou
# si deux onglets ont le même terminal : rien. Lecture manquée : échec. Numéro du terminal (tdev), jamais son nom : dix fois moins cher.
cmux_terminals() (
  set -o pipefail
  tabs="$(cmx rpc debug.terminals '{}' 2>/dev/null | jq -r '.terminals[]
    | select(.runtime_surface_ready == true and (.runtime_surface_created_at // "") != "")
    | ["T", .surface_id, (.workspace_id // .last_known_workspace_id), .surface_ref, .runtime_surface_created_at] | @tsv' 2>/dev/null)" || exit 1
  { printf '%s\n' "$tabs"; LC_ALL=C TZ=UTC ps -axwwE -o pid=,ppid=,tdev=,lstart=,command= 2>/dev/null; } | LC_ALL=C awk '
    function secs(y, mo, d, h, mi, s) {   # secondes depuis une origine fixe, calendrier grégorien
      if (mo <= 2) { y--; mo += 12 }
      return (365 * y + int(y / 4) - int(y / 100) + int(y / 400) + int((153 * (mo - 3) + 2) / 5) + d) * 86400 + h * 3600 + mi * 60 + s
    }
    BEGIN { split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", m, " "); for (k in m) MON[m[k]] = k + 0 }
    /^T\t/ { split($0, x, "\t"); n++; ID[n] = x[2]; WS[n] = x[3]; REF[n] = x[4]; t = x[5]
      AT[n] = secs(substr(t, 1, 4) + 0, substr(t, 6, 2) + 0, substr(t, 9, 2) + 0, substr(t, 12, 2) + 0, substr(t, 15, 2) + 0, substr(t, 18, 2) + 0); next }
    $3 !~ /^16\/[0-9]+$/ { OFF[$1] = 1; next }
    {
      split($3, d, "/"); t = sprintf("ttys%03d", d[2]); split($7, h, ":")
      PP[$1] = $2; ON[$1] = t; AGE[$1] = secs($8 + 0, MON[$5], $6 + 0, h[1] + 0, h[2] + 0, h[3] + 0)
      s = $0; v = ""; while (match(s, /CMUX_SURFACE_ID=[^ ]+/)) { v = substr(s, RSTART + 16, RLENGTH - 16); s = substr(s, RSTART + RLENGTH) }
      if (v != "") { OWN[t, v] = 1; SAID[t] = 1; CLAIM[v] = 1 }
    }
    END {
      for (p in ON) if (PP[p] != 1 && (PP[p] in OFF) && (!(ON[p] in BORN) || AGE[p] < BORN[ON[p]])) BORN[ON[p]] = AGE[p]
      for (i = 1; i <= n; i++) {
        mine = 0; free = 0; sure = ""; pick = ""
        for (t in BORN) if (BORN[t] == AT[i] || BORN[t] == AT[i] + 1) {
          if ((t, ID[i]) in OWN) { mine++; sure = t } else if (!(t in SAID)) { free++; pick = t }
        }
        if (mine == 1) GOT[i] = sure; else if (mine == 0 && free == 1 && !(ID[i] in CLAIM)) GOT[i] = pick
        if (i in GOT) USED[GOT[i]]++
      }
      for (i = 1; i <= n; i++) if ((i in GOT) && USED[GOT[i]] == 1) print ID[i] "\t" WS[i] "\t" REF[i] "\t" GOT[i]
    }'
)
# cmux_tab_pids <onglet, référence ou identifiant> → les pid de son vrai terminal, prouvé par l'heure de sa naissance (cmux_terminals),
# un par ligne ; le champ tty de cmux n'y compte pas : nul, partagé avec un autre onglet ou périmé, il laissait illisible un onglet
# dont le terminal se prouve (main jetable du lot 02 d'onglet-tower : ttys005 donné aussi à un onglet d'un autre espace) ; échec
# si le terminal ne se prouve pas ou n'a aucun processus
cmux_tab_pids() {
  local terminals tty pids
  terminals="$(cmux_terminals)" || return 1
  tty="$(printf '%s\n' "$terminals" | awk -F'\t' -v s="$1" '$1 == s || $3 == s { print $4; exit }')"; [ -n "$tty" ] || return 1
  pids="$(ps -t "$tty" -o pid= 2>/dev/null | tr -d ' ')" || return 1
  [ -n "$pids" ] && printf '%s\n' "$pids"
}
# cmux_pid_tab <pid> → « <workspace>⇥<surface> » de l'onglet dont le vrai terminal est celui de ce processus ; échec sinon
cmux_pid_tab() {
  local tty terminals tab
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] || return 1
  tty="$(ps -o tty= -p "$1" 2>/dev/null | tr -d ' ')"
  case "$tty" in ''|*'?'*) return 1 ;; esac
  terminals="$(cmux_terminals)" || return 1
  tab="$(printf '%s\n' "$terminals" | awk -F'\t' -v t="$tty" '$4 == t { print $2 "\t" $3 }')"
  [ -n "$tab" ] && printf '%s\n' "$tab"
}
# cmux_own_pids <onglet> <pid>… → ceux qui sont de cet onglet, parmi les processus que cmux range sous son terminal sans les lui attribuer
# (unattributed_tty_process_pids) : ceux de son vrai terminal, ou, s'il ne se prouve pas, ceux qui ne sont pas sur le terminal prouvé
# d'un autre onglet (cmux_terminals) ; table illisible : échec
cmux_own_pids() {
  local tab="$1" terminals list; shift
  terminals="$(cmux_terminals)" || return 1
  list="$(printf '%s,' "$@")"
  { printf '%s\n' "$terminals"; ps -o pid=,tty= -p "${list%,}" 2>/dev/null || true; } | awk -F'\t' -v s="$tab" '
    NF == 4 { if ($1 == s || $3 == s) own = $4; else other[$4] = 1; next }
    { split($0, a, " "); if (a[1] != "" && (own != "" ? a[2] == own : !(a[2] in other))) print a[1] }'
}
# cmux_surface_pids <workspace> <surface> → les pid rattachés à cet onglet (terminal, racines, arbre), un par ligne. Une lecture
# en échec, un onglet introuvable ou sans processus rendent un échec : un doute, jamais une absence (lot 10). Un terminal réutilisé
# (tty-collision, mesuré le 2026-11-05 sur cmux) laisse les listes habituelles vides et range les processus de son terminal dans
# unattributed_tty_process_pids : ils comptent aussi (lot 06 de comptes-complets), s'ils sont bien de cet onglet (cmux_own_pids — ceux de
# main de treelab étaient d'un autre, lot 01 d'onglet-tower). Rien : les pid du vrai terminal de l'onglet, prouvé par sa naissance
# (cmux_tab_pids — cmux 0.65.2 taisait les quatre onglets mesurés ; son champ tty n'est plus lu, lot 02 d'onglet-tower).
cmux_surface_pids() {
  local out read_ pids near
  out="$(cmx top --all --workspace "$1" --processes --json 2>/dev/null)" || return 1
  read_="$(printf '%s' "$out" | jq -r --arg s "$2" '
    [.. | objects | select(has("tty_process_pids") and (.ref? == $s or .id? == $s))]
    | if length == 0 then error("tab missing") else . end
    | ([.[] | (.tty_process_pids // []), (.root_pids // []), (.cmux_process_pids // []), (.top_level_pids // []),
        [(.processes // []) | .. | objects | .pid? // empty]] | flatten | unique) as $u
    | ($u[] | "pid \(.)"), (([.[] | .unattributed_tty_process_pids // []] | flatten | unique) - $u | .[] | "near \(.)")' 2>/dev/null)" || return 1
  pids="$(printf '%s\n' "$read_" | sed -n 's/^pid //p')"; near="$(printf '%s\n' "$read_" | sed -n 's/^near //p')"
  # shellcheck disable=SC2086 # un pid par mot
  if [ -n "$near" ]; then near="$(cmux_own_pids "$2" $near)" || near=""; fi
  if [ -n "$pids$near" ]; then printf '%s\n%s\n' "$pids" "$near" | sed '/^$/d' | sort -un; return 0; fi
  cmux_tab_pids "$2"
}
# cmux_clear_line <workspace> <surface> : vide la ligne de saisie (ctrl+u) — une ligne laissée prête sans Entrée (leave_ready) ou
# un reste non envoyé se collait devant la suivante : « --agent claudecd '…' && lab launch … » (mesuré le 2026-11-22)
cmux_clear_line() { cmx send-key --workspace "$1" --surface "$2" ctrl+u >/dev/null; }
cmux_submit() { # <workspace> <surface> <ligne> : ligne vidée, collage puis vraie touche Entrée
  cmux_clear_line "$1" "$2" && cmux_send "$1" "$2" "$3" && cmx send-key --workspace "$1" --surface "$2" Return >/dev/null
}
