# shellcheck shell=bash
# menubar.sh — rangement de la barre de menus (lot 06 du couloir tableau-de-bord), fait maison, sur SwiftBar.
# Deux greffons, comme Hidden Bar : un écarteur invisible (lab-hide.60s.sh) qui, replié, prend MENUBAR_SEP_WIDE pt et pousse hors
# écran tout ce qui est à sa gauche (mesuré sous macOS 26), et le chevron (lab-sep.60s.sh) juste à sa droite, toujours dessiné — un
# élément surtout hors écran n'est pas dessiné du tout par macOS, il ne peut porter la flèche ; déplié, l'écarteur se réduit à 1 pt
# et se replie seul après MENUBAR_SEP_OPEN_S s. À chaque passe le chevron relève la
# barre (fenêtres de niveau 25, 0,06 s), en dessine la carte et veille : icône lab cachée, app neuve à droite du chevron, ordre qui a
# bougé, doublon ou iStat revenus ; tant que le rangement n'est pas fait, son menu guide les quatre étapes. Ordre : photo des clés
# NSStatusItem Preferred Position de chaque domaine (order save), rétablie par order apply — un greffon SwiftBar par désactiver →
# écrire → réactiver, une autre app par quitter → écrire → rouvrir, jamais cmux, les agents ni SwiftBar, relance annoncée puis
# confirmée (--relaunch, le clic). Rangement (tidy) : espacement, doublons du Centre de contrôle, iStat ; chaque geste garde ce
# qu'il remplace dans l'état de lab, et widget remove le rétablit. Mesures : docs/lots/tableau-de-bord/preuves/lot-06-ordre-barre.md.

MENUBAR_SEP_PLUGIN='lab-sep.60s.sh'
MENUBAR_HIDE_PLUGIN='lab-hide.60s.sh'   # l'écarteur invisible
MENUBAR_HIDE_NAME='lab-hide'
MENUBAR_SEP_WIDTH=20                # largeur de l'élément chevron (image + espacement) : l'écarteur se pose juste au-delà
MENUBAR_SEP_NAME='lab-sep'          # nom SwiftBar du greffon (fichier jusqu'au premier point), pour swiftbar://refreshplugin
MENUBAR_SEP_WIDE=4000               # largeur repliée : au-delà de tout écran
MENUBAR_SEP_GLYPH=14                # largeur dessinée du chevron, au bord droit de l'image
MENUBAR_SEP_OPEN_S=10               # déplié : repli seul après 10 s (jamais de modules poussés sous l'encoche pour longtemps)
MENUBAR_SPACING=6                   # valeur retenue (essais 4, 6, 10 au rapport) ; valeur système d'origine : 16
MENUBAR_SPACING_KEYS='NSStatusItemSpacing NSStatusItemSelectionPadding'
MENUBAR_POS_TTL=5                   # minutes : positions (defaults find, 0,6 s) gardées en cache par le veilleur
MENUBAR_PREFIX='NSStatusItem Preferred Position'
MENUBAR_CC=com.apple.controlcenter
MENUBAR_CC_HIDE=8                   # valeur -currentHost d'un module du Centre de contrôle absent de la barre
# modules du Centre de contrôle : déjà dans son panneau, donc doublons quand ils sont aussi dans la barre ; Wi-Fi gardé (maquette)
MENUBAR_CC_MODULES='WiFi Bluetooth AirDrop Battery FocusModes Sound Display NowPlaying ScreenMirroring KeyboardBrightness AccessibilityShortcuts UserSwitcher StageManager Hearing'
MENUBAR_CC_KEEP='WiFi'
# rangeurs concurrents (noms de processus) : deux rangeurs se battent sur les mêmes clés
MENUBAR_RIVALS='Bartender 6|Bartender 5|Bartender 4|Bartender|Ice|Hidden Bar'
MENUBAR_WAIT="${LAB_MENUBAR_WAIT:-2}"   # secondes laissées à SwiftBar ou à une app entre deux gestes ; 0 dans les tests

menubar_dir() { printf '%s/bar\n' "$(widget_state)"; }
# menubar_say : stdin sur stderr, replié au mot à la largeur du terminal (onboard_wrap, comme l'aide) quand stderr est un terminal
# ou COLUMNS est posé ; annonces lisibles à 80 et 40 colonnes
menubar_say() {
  if [ -t 2 ] || [ -n "${COLUMNS:-}" ]; then
    declare -F onboard_wrap >/dev/null || . "$LAB_ROOT/lib/onboard.sh"
    onboard_wrap "$(onboard_cols)" >&2
  else cat >&2; fi
}
menubar_log() { printf 'lab: %s\n' "$*" | menubar_say; }
menubar_agents_dir() { printf '%s/Library/LaunchAgents\n' "$HOME"; }

# ---------- relevé ----------
# menubar_probe → « SCREEN<TAB>largeur<TAB>bord droit de l'encoche » puis une ligne par élément de barre : x<TAB>largeur<TAB>à l'écran
# (1|0)<TAB>nom. Sous macOS 26 chaque icône est une fenêtre de niveau 25 nommée d'après son autosave ; 0,06 s de CPU (mesuré).
# shellcheck disable=SC2016 # programme JavaScript : ses $ sont ceux du pont ObjC
MENUBAR_PROBE_JS='ObjC.import("AppKit"); ObjC.import("CoreGraphics");
var s = $.NSScreen.mainScreen, f = s.frame, r = s.auxiliaryTopRightArea;
var o = ["SCREEN\t" + Math.round(f.size.width) + "\t" + Math.round(r && r.size.width > 0 ? f.size.width - r.size.width : 0)];
var l = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo(0, 0)));
for (var i = 0; i < l.length; i++) { var w = l[i]; if (w.kCGWindowLayer != 25) continue; var b = w.kCGWindowBounds;
  o.push([Math.round(b.X), Math.round(b.Width), w.kCGWindowIsOnscreen ? 1 : 0, w.kCGWindowName || ""].join("\t")); }
o.join("\n")'
# Sans l'autorisation d'enregistrer l'écran (SwiftBar, mesuré le 2026-10-25), macOS tait le nom des fenêtres : chacune reprend le
# nom de la position mémorisée la plus proche (bord droit à position − 2 pt du bord de l'écran, à 12 pt près) ; sinon, écartée.
menubar_probe() {
  local raw pos
  raw="$(exec osascript -l JavaScript -e "$MENUBAR_PROBE_JS" 2>/dev/null)" || true
  if awk -F '\t' '$1 != "SCREEN" && $4 == "" { f = 1 } END { exit !f }' <<<"$raw"; then
    pos="$(menubar_positions_cached)"
    printf '%s\n' "$raw" | awk -F '\t' -v OFS='\t' -v posf="$pos" '
      BEGIN { while ((getline l < posf) > 0) { split(l, F, "\t"); np++; PN[np] = F[2]; PP[np] = F[3] + 0 } }
      $1 == "SCREEN" { sw = $2; print; next }
      $4 != "" { print; next }
      { d = sw - ($1 + $2) + 2; best = 0; bd = 13
        for (j = 1; j <= np; j++) { e = PP[j] - d; if (e < 0) e = -e; if (e < bd && !(j in USED)) { bd = e; best = j } }
        if (best) { USED[best] = 1; $4 = PN[best]; print } }'
  else printf '%s\n' "$raw"; fi
}

# ---------- positions ----------
# menubar_positions → domaine<TAB>nom<TAB>position, une ligne par clé NSStatusItem Preferred Position de tous les domaines
menubar_positions() {
  defaults find "$MENUBAR_PREFIX" 2>/dev/null | LC_ALL=C awk -v pre="\"$MENUBAR_PREFIX " '
    /^Found [0-9]+ keys in domain / { split($0, q, "\047"); d = q[2]; next }
    { i = index($0, pre); if (!i || d == "") next
      l = substr($0, i + length(pre)); j = index(l, "\" = "); if (!j) next
      n = substr(l, 1, j - 1); v = substr(l, j + 4); sub(/;[ \t]*$/, "", v); printf "%s\t%s\t%s\n", d, n, v }'
}
# menubar_positions_cached → le fichier des positions, relu si plus vieux que MENUBAR_POS_TTL minutes (ou forcé par « fresh »)
menubar_positions_cached() { menubar_positions_cached_set "$@"; printf '%s\n' "$MENUBAR_POSF"; }
# menubar_positions_cached_set [fresh] : MENUBAR_POSF, le même fichier, sans sous-shell (le séparateur, chaque minute)
menubar_positions_cached_set() {
  local d="$LAB_STATE/widget/bar"; MENUBAR_POSF="$d/positions"; [ -d "$d" ] || mkdir -p "$d"
  if [ "${1:-}" = fresh ] || [ -z "$(exec find "$MENUBAR_POSF" -mmin "-$MENUBAR_POS_TTL" 2>/dev/null)" ]; then
    if menubar_positions >"$MENUBAR_POSF.$$" 2>/dev/null; then mv "$MENUBAR_POSF.$$" "$MENUBAR_POSF"; else rm -f "$MENUBAR_POSF.$$"; fi
  fi
}
menubar_order_file() { printf '%s/order\n' "$(menubar_dir)"; }

# menubar_rival → le nom du rangeur concurrent qui tourne (Bartender, Ice, Hidden Bar), rien sinon ; le premier de MENUBAR_RIVALS
# s'il en tourne plusieurs. Un seul pgrep pour tous (motif étendu, nom entier), au lieu d'un par nom : lot 04 de charge-processeur
menubar_rival() {
  local out n IFS='|'
  out="$(exec pgrep -lx "$MENUBAR_RIVALS" 2>/dev/null)" || return 0
  for n in $MENUBAR_RIVALS; do case $'\n'"$out"$'\n' in *[0-9]" $n"$'\n'*) printf '%s\n' "$n"; return 0 ;; esac; done
  return 0
}
menubar_refuse_rival() {
  local r; r="$(menubar_rival)"; [ -z "$r" ] && return 0
  kv "${1:-ORDER}" refused; kv REFUSAL "$r"
  die "$r is running: quit it first, two bar organisers fight over the same positions"
}

# ---------- apps ----------
menubar_running() {
  [ "$(osascript -e 'on run argv' -e 'return application id (item 1 of argv) is running' -e 'end run' "$1" 2>/dev/null)" = true ]
}
# menubar_impact_key <domaine> → clé de la table des textes : ce qu'implique le replacement de ses icônes
menubar_impact_key() {
  # lot 02 du couloir app-treelab : toute app de terminal posée (cmux, le fork) est exclue comme cmux, jamais quittée ni relancée
  local nl=$'\n'; terminal_found_set
  case "$nl$TERMINAL_FOUND_IDS$nl" in *"$nl$1$nl"*) echo imp_excluded; return ;; esac
  case "$1" in
    com.apple.controlcenter|com.apple.systemuiserver) echo imp_cc ;;
    com.ameba.SwiftBar) echo imp_swiftbar ;;
    com.cmuxterm.app|*anthropic*|*claude*|*Claude*|*openai*|*codex*) echo imp_excluded ;;
    com.raycast.macos) echo imp_raycast ;;
    com.google.drivefs) echo imp_drive ;;
    ru.keepcoder.Telegram) echo imp_telegram ;;
    *) echo imp_app ;;
  esac
}
# menubar_text <langue> <clé> [valeur] : une phrase de la table FR/EN (la valeur remplace %s)
menubar_text() { LC_ALL=C awk -v lang="$1" -v k="$2" -v a="${3:-}" "$MENUBAR_TEXT_AWK"' BEGIN { tr_init(); print ts(k, a) }' </dev/null; }

# menubar_write <domaine> <fichier nom<TAB>position> <relaunch 0|1> → une ligne « action » : moved (SwiftBar, sans relance), written
# (app arrêtée), relaunched, planned (relance à confirmer), skipped (exclue ou refus de quitter)
menubar_write() {
  local d="$1" f="$2" relaunch="$3" n p plug i
  case "$(menubar_impact_key "$d")" in
    imp_excluded) echo skipped; return ;;
    imp_swiftbar)
      while IFS="$(printf '\t')" read -r n p; do
        plug="${n##*/}"; plug="${plug%%.*}"
        open -g "swiftbar://disableplugin?name=$plug" >/dev/null 2>&1 || true; sleep "$MENUBAR_WAIT"
        defaults write "$d" "$MENUBAR_PREFIX $n" -float "$p" >/dev/null 2>&1 || true
        open -g "swiftbar://enableplugin?name=$plug" >/dev/null 2>&1 || true
      done <"$f"
      echo moved; return ;;
    imp_cc)
      [ "$relaunch" = 1 ] || { echo planned; return; }
      while IFS="$(printf '\t')" read -r n p; do defaults write "$d" "$MENUBAR_PREFIX $n" -float "$p" >/dev/null 2>&1 || true; done <"$f"
      if [ "$d" = "$MENUBAR_CC" ]; then killall ControlCenter >/dev/null 2>&1 || true; else killall SystemUIServer >/dev/null 2>&1 || true; fi
      echo relaunched; return ;;
  esac
  if ! menubar_running "$d"; then
    while IFS="$(printf '\t')" read -r n p; do defaults write "$d" "$MENUBAR_PREFIX $n" -float "$p" >/dev/null 2>&1 || true; done <"$f"
    echo written; return
  fi
  [ "$relaunch" = 1 ] || { echo planned; return; }
  osascript -e 'on run argv' -e 'tell application id (item 1 of argv) to quit' -e 'end run' "$d" >/dev/null 2>&1 || true
  i=0; while menubar_running "$d" && [ "$i" -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
  menubar_running "$d" && { echo skipped; return; }   # l'app a refusé de quitter (document à enregistrer) : rien n'est forcé
  while IFS="$(printf '\t')" read -r n p; do defaults write "$d" "$MENUBAR_PREFIX $n" -float "$p" >/dev/null 2>&1 || true; done <"$f"
  open -g -b "$d" >/dev/null 2>&1 || true
  echo relaunched
}

# ---------- order ----------
# menubar_moved <photo> <positions> → domaine<TAB>nom<TAB>position enregistrée, pour chaque clé dont la valeur actuelle diffère ;
# replié, macOS ajoute à la position des apps rangées la largeur de l'écarteur (MENUBAR_SEP_WIDE + l'espacement) : ôtée des deux
# côtés, une app qui n'a bougé que de cette largeur est à sa place (MENUBAR_SAME_AWK, partagé avec le chevron)
# shellcheck disable=SC2016 # programme awk
MENUBAR_SAME_AWK='
function unwide(v, h) { return (h > 0 && v > h + wide) ? v - wide : v }
function same(a, ha, b, hb,   x, y, d) { if (a + 0 == b + 0) return 1; x = unwide(a + 0, ha); y = unwide(b + 0, hb)
  if (x == a + 0 && y == b + 0) return 0; d = x - y; if (d < 0) d = -d; return d <= 16 }
'
menubar_moved() {
  awk -F '\t' -v hide="/$MENUBAR_HIDE_PLUGIN" -v wide="$MENUBAR_SEP_WIDE" "$MENUBAR_SAME_AWK"'
    function ish(n) { return substr(n, length(n) - length(hide) + 1) == hide }
    NR == FNR { if ($0 !~ /^#/ && NF == 3) { cur[$1 FS $2] = $3; if (ish($2)) ch = $3 + 0 }; next }
    $0 !~ /^#/ && NF == 3 { n++; K[n] = $1 FS $2; V[n] = $0; P[n] = $3; if (ish($2)) sh = $3 + 0 }
    END { for (i = 1; i <= n; i++) { k = K[i]; if (!(k in cur) || !same(P[i], sh, cur[k], ch)) print V[i] } }' "$2" "$1"
}
menubar_order() {
  local action="${1:-show}" f pos dir tmp d moved n relaunch=0 res written="" relaunched="" planned="" skipped="" name target line max
  dir="$(menubar_dir)"; f="$(menubar_order_file)"; mkdir -p "$dir"; terminal_found_set   # une fois : menubar_impact_key la relit
  case "$action" in
    save)
      [ "$#" -eq 1 ] || usage; menubar_refuse_rival ORDER
      pos="$(menubar_positions_cached fresh)"
      [ -s "$pos" ] || die "no menu bar position found (defaults find $MENUBAR_PREFIX gave nothing)"
      { printf '# saved %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; cat "$pos"; } >"$f.$$" && mv "$f.$$" "$f"
      n="$(grep -vc '^#' "$f")"
      kv ORDER saved; kv ITEMS "$n"; kv SAVED_AT "$(sed -n '1s/^# saved //p' "$f")"; kv MESSAGE "order saved: $n items"
      log "menu bar order saved ($n items); lab widget order apply puts it back" ;;
    show)
      [ "$#" -eq 1 ] || usage
      [ -f "$f" ] || { kv ORDER none; log "no saved order: arrange the bar (Command-drag), then lab widget order save"; return 0; }
      pos="$(menubar_positions_cached fresh)"; moved="$(menubar_moved "$f" "$pos")"
      n=0; [ -z "$moved" ] || n="$(printf '%s\n' "$moved" | wc -l | tr -d ' ')"
      kv ORDER saved; kv SAVED_AT "$(sed -n '1s/^# saved //p' "$f")"; kv ITEMS "$(grep -vc '^#' "$f")"; kv MOVED "$n"
      relaunch=""
      for d in $(printf '%s\n' "$moved" | cut -f1 | sort -u); do
        case "$(menubar_impact_key "$d")" in imp_excluded|imp_swiftbar) continue ;; esac
        relaunch="$relaunch,$d"
      done
      kv RELAUNCH "${relaunch#,}"
      {
        printf 'menu bar order saved %s, %s items, %s moved since\n' "$(sed -n '1s/^# saved //p' "$f")" "$(grep -vc '^#' "$f")" "$n"
        printf '%s\n' "$moved" | awk -F '\t' -v pos="$pos" 'NF == 3 { c = "?"; while ((getline l < pos) > 0) { split(l, P, "\t"); if (P[1] == $1 && P[2] == $2) c = P[3] } close(pos)
          printf "  %s %s: %s -> %s\n", $1, $2, c, $3 }'
        for d in $(printf '%s\n' "$moved" | cut -f1 | sort -u); do printf '  %s: %s\n' "$d" "$(menubar_text en "$(menubar_impact_key "$d")")"; done
        [ "$n" -eq 0 ] || printf 'apply puts them back (never cmux, agents nor SwiftBar relaunched): lab widget order apply --relaunch\n'
      } | menubar_say ;;
    apply|stow)
      if [ "$action" = stow ]; then [ "$#" -ge 2 ] || usage; name="$2"; shift 2; else shift; fi
      [ "${1:-}" != --relaunch ] || { relaunch=1; shift; }
      [ "$#" -eq 0 ] || usage
      menubar_refuse_rival ORDER
      pos="$(menubar_positions_cached fresh)"
      if [ "$action" = stow ]; then
        # ranger <nom> : sa position passe au-delà de toutes les autres (le plus à gauche, donc derrière le chevron), la photo suit
        line="$(awk -F '\t' -v n="$name" '$2 == n' "$pos")"
        [ -n "$line" ] || die "no menu bar item named $name (lab widget order show lists them)"
        if [ "$(printf '%s\n' "$line" | wc -l | tr -d ' ')" -gt 1 ]; then
          for d in $(printf '%s\n' "$line" | cut -f1); do menubar_running "$d" && { target="$d"; break; }; done
          [ -n "${target:-}" ] || die "$name belongs to several apps and none is running: Command-drag it by hand"
          line="$(printf '%s\n' "$line" | awk -F '\t' -v d="$target" '$1 == d')"
        fi
        max="$(awk -F '\t' '{ if ($3 + 0 > m) m = $3 + 0 } END { print int(m) + 10 }' "$pos")"
        moved="$(printf '%s\n' "$line" | awk -F '\t' -v m="$max" '{ printf "%s\t%s\t%s\n", $1, $2, m }')"
      else
        [ -f "$f" ] || die "no saved order: arrange the bar (Command-drag), then lab widget order save"
        moved="$(menubar_moved "$f" "$pos")"
      fi
      n=0; [ -z "$moved" ] || n="$(printf '%s\n' "$moved" | wc -l | tr -d ' ')"
      tmp="$dir/.write.$$"
      for d in $(printf '%s\n' "$moved" | cut -f1 | sort -u); do
        printf '%s\n' "$moved" | awk -F '\t' -v d="$d" '$1 == d { printf "%s\t%s\n", $2, $3 }' >"$tmp"
        res="$(menubar_write "$d" "$tmp" "$relaunch")"
        case "$res" in moved|written) written="$written,$d" ;; relaunched) relaunched="$relaunched,$d" ;; planned) planned="$planned,$d" ;; *) skipped="$skipped,$d" ;; esac
        [ "$res" != planned ] || menubar_log "$d $(menubar_text en "$(menubar_impact_key "$d")")"
        [ "$res" != skipped ] || menubar_log "$d not moved: $(menubar_text en "$(menubar_impact_key "$d")")"
      done
      rm -f "$tmp"
      if [ "$action" = stow ] && [ -f "$f" ] && [ -z "$planned" ] && [ -z "$skipped" ]; then
        # la photo retient le nouveau rangement : order apply ne le défait pas
        awk -F '\t' -v OFS='\t' 'NR == FNR { if (NF == 3) M[$1 FS $2] = $3; next } ($1 FS $2) in M { $3 = M[$1 FS $2] } { print }' \
          <(printf '%s\n' "$moved") "$f" >"$f.$$" && mv "$f.$$" "$f"
      fi
      menubar_positions_cached fresh >/dev/null
      if [ -n "$planned" ]; then kv ORDER planned; elif [ "$action" = stow ]; then kv ORDER stowed; else kv ORDER applied; fi
      kv MOVED "$n"; kv WRITTEN "${written#,}"; kv RELAUNCHED "${relaunched#,}"; kv PLANNED "${planned#,}"; kv SKIPPED "${skipped#,}"
      if [ -n "$planned" ]; then
        kv MESSAGE "${planned#,} must relaunch: confirm with --relaunch"
        menubar_log "nothing relaunched yet: lab widget order $action ${name:+$name }--relaunch confirms"
      elif [ "$action" = stow ]; then kv MESSAGE "$name tucked behind the chevron"
      else kv MESSAGE "order restored: $n items moved"; fi ;;
    *) usage ;;
  esac
}

# ---------- tidy ----------
# menubar_dupes [probe] → les modules du Centre de contrôle présents dans la barre (hors MENUBAR_CC_KEEP), un par ligne
menubar_dupes() {
  printf '%s\n' "$1" | awk -F '\t' -v mods=" $MENUBAR_CC_MODULES " -v keep=" $MENUBAR_CC_KEEP " \
    'NF == 4 && index(mods, " " $4 " ") && !index(keep, " " $4 " ") && !seen[$4]++ { print $4 }'
}
menubar_istat_plists() { ls "$(menubar_agents_dir)"/com.bjango.istatmenus*.plist 2>/dev/null || true; }

# menubar_tidy [--confirm] [spacing|duplicates|istat] : sans --confirm, annonce les gestes et ce qu'ils impliquent, ne touche à rien
menubar_tidy() {
  local confirm=0 steps="" s dir probe dupes istat k v app done_s=""
  dir="$(menubar_dir)"; mkdir -p "$dir"
  while [ "$#" -gt 0 ]; do
    case "$1" in --confirm) confirm=1 ;; spacing|duplicates|istat) steps="$steps $1" ;; *) usage ;; esac; shift
  done
  [ -n "$steps" ] || steps=" spacing duplicates istat"
  probe="$(menubar_probe)"; dupes="$(menubar_dupes "$probe" | paste -sd, -)"
  istat="absent"; [ -z "$(menubar_istat_plists)" ] || istat=present
  [ ! -f "$dir/istat" ] || istat=stopped
  if [ "$confirm" = 0 ]; then
    kv TIDY planned
    case "$steps" in *spacing*) if [ -f "$dir/spacing" ]; then kv SPACING "done"; else kv SPACING "16->$MENUBAR_SPACING"; fi ;; esac
    case "$steps" in *duplicates*) kv DUPLICATES "${dupes:-none}" ;; esac
    case "$steps" in *istat*) kv ISTAT "$istat" ;; esac
    # seules les étapes qui restent sont annoncées et proposées à --confirm ; rien ne reste : on le dit, sans commande
    local left=""
    case "$steps" in *spacing*) [ -f "$dir/spacing" ] || left="$left spacing" ;; esac
    case "$steps" in *duplicates*) [ -z "$dupes" ] || left="$left duplicates" ;; esac
    case "$steps" in *istat*) [ "$istat" != present ] || left="$left istat" ;; esac
    {
      if [ -z "$left" ]; then printf 'nothing left to tidy: each step asked is done or has nothing to change\n'
      else
        printf 'tidy would:\n'
        case "$left" in *spacing*) printf '  spacing  16 -> %s pt, -10 pt per icon; Control Center and SwiftBar relaunch, other apps at their next launch\n' "$MENUBAR_SPACING" ;; esac
        case "$left" in *duplicates*) printf '  hide     %s from the bar (kept in Control Center, which restarts for a second)\n' "$dupes" ;; esac
        case "$left" in *istat*) printf '  iStat    quit iStat Menus, off at login, settings kept (uninstalling it in Setapp is yours)\n' ;; esac
        printf 'each step is undone by lab widget remove; run lab widget tidy --confirm%s\n' "$left"
      fi
    } | menubar_say
    return 0
  fi
  for s in $steps; do
    case "$s" in
      spacing)
        # déjà resserré : rien à refaire, ni Centre de contrôle ni SwiftBar relancés pour rien
        if [ -f "$dir/spacing" ]; then kv SPACING "done"; done_s="$done_s spacing"; continue; fi
        # valeurs d'origine gardées une fois (absente = « - ») : remove les remet exactement
        if [ ! -f "$dir/spacing" ]; then
          for k in $MENUBAR_SPACING_KEYS; do v="$(defaults -currentHost read -g "$k" 2>/dev/null)" || v=-; printf '%s=%s\n' "$k" "$v"; done >"$dir/spacing.$$" && mv "$dir/spacing.$$" "$dir/spacing"
        fi
        for k in $MENUBAR_SPACING_KEYS; do defaults -currentHost write -g "$k" -int "$MENUBAR_SPACING" >/dev/null 2>&1 || true; done
        killall ControlCenter >/dev/null 2>&1 || true
        menubar_swiftbar_relaunch
        kv SPACING "$MENUBAR_SPACING"; done_s="$done_s spacing" ;;
      duplicates)
        touch "$dir/dupes"
        for k in $(printf '%s\n' "$dupes" | tr , ' '); do
          grep -q "^$k$(printf '\t')" "$dir/dupes" || { v="$(defaults -currentHost read "$MENUBAR_CC" "$k" 2>/dev/null)" || v=-; printf '%s\t%s\n' "$k" "$v" >>"$dir/dupes"; }
          defaults -currentHost write "$MENUBAR_CC" "$k" -int "$MENUBAR_CC_HIDE" >/dev/null 2>&1 || true
        done
        [ -z "$dupes" ] || killall ControlCenter >/dev/null 2>&1 || true
        kv DUPLICATES "${dupes:-none}"; done_s="$done_s duplicates" ;;
      istat)
        if [ "$istat" = absent ]; then kv ISTAT absent; continue; fi
        touch "$dir/istat"
        while IFS= read -r v; do
          [ -n "$v" ] || continue; k="$(basename "$v" .plist)"
          grep -q "^$k$(printf '\t')" "$dir/istat" 2>/dev/null || printf '%s\t%s\n' "$k" "$v" >>"$dir/istat"
          launchctl disable "gui/$(id -u)/$k" >/dev/null 2>&1 || true
          launchctl bootout "gui/$(id -u)/$k" >/dev/null 2>&1 || true
          osascript -e 'on run argv' -e 'tell application id (item 1 of argv) to quit' -e 'end run' "$k" >/dev/null 2>&1 || true
        done < <(menubar_istat_plists)
        pkill -f 'iStat Menus (Menubar|Helper)\.app/' >/dev/null 2>&1 || true
        kv ISTAT stopped; done_s="$done_s istat" ;;
    esac
  done
  kv TIDY "done"; kv MESSAGE "bar tidied:$done_s; lab widget remove undoes it"
  open -g "swiftbar://refreshplugin?name=$MENUBAR_SEP_NAME" >/dev/null 2>&1 || true
}
# menubar_swiftbar_relaunch : SwiftBar relit l'espacement à son lancement seulement (mesuré) ; il exécute nos clics, donc la relance
# part détachée, après la fin du geste. LAB_MENUBAR_WAIT=0 (tests) : en ligne.
menubar_swiftbar_relaunch() {
  local app; app="$(widget_app)"; [ -n "$app" ] || return 0
  if [ "$MENUBAR_WAIT" = 0 ]; then
    osascript -e 'quit app "SwiftBar"' >/dev/null 2>&1 || true; open -g -a "$app" >/dev/null 2>&1 || true; return 0
  fi
  # shellcheck disable=SC2016 # $1 est développé par le bash détaché
  nohup /bin/bash -c 'sleep 1; osascript -e "quit app \"SwiftBar\"" >/dev/null 2>&1; sleep 3; open -g -a "$1"' _ "$app" </dev/null >/dev/null 2>&1 &
}
# menubar_untidy : remet ce que tidy a remplacé (espacement, doublons, iStat), puis oublie l'état ; appelé par widget remove
menubar_untidy() {
  local dir k v p cc=0
  dir="$(menubar_dir)"
  if [ -f "$dir/spacing" ]; then
    while IFS='=' read -r k v; do
      [ -n "$k" ] || continue
      if [ "$v" = - ]; then defaults -currentHost delete -g "$k" >/dev/null 2>&1 || true
      else defaults -currentHost write -g "$k" -int "$v" >/dev/null 2>&1 || true; fi
    done <"$dir/spacing"
    rm -f "$dir/spacing"; cc=1
    menubar_swiftbar_relaunch   # l'espacement n'est relu qu'au lancement : sans relance, les icônes lab resteraient serrées
  fi
  if [ -f "$dir/dupes" ]; then
    while IFS="$(printf '\t')" read -r k v; do
      [ -n "$k" ] || continue
      if [ "$v" = - ]; then defaults -currentHost delete "$MENUBAR_CC" "$k" >/dev/null 2>&1 || true
      else defaults -currentHost write "$MENUBAR_CC" "$k" -int "$v" >/dev/null 2>&1 || true; fi
    done <"$dir/dupes"
    rm -f "$dir/dupes"; cc=1
  fi
  [ "$cc" = 0 ] || killall ControlCenter >/dev/null 2>&1 || true
  if [ -f "$dir/istat" ]; then
    while IFS="$(printf '\t')" read -r k p; do
      [ -n "$k" ] || continue
      launchctl enable "gui/$(id -u)/$k" >/dev/null 2>&1 || true
      [ ! -f "$p" ] || launchctl bootstrap "gui/$(id -u)" "$p" >/dev/null 2>&1 || true
    done <"$dir/istat"
    rm -f "$dir/istat"
  fi
}

# ---------- séparateur ----------
menubar_sep_state() { printf '%s/sep\n' "$(menubar_dir)"; }
# menubar_sep show|hide : déplie (repli seul après MENUBAR_SEP_OPEN_S s) ou replie le chevron
menubar_sep() {
  local f; f="$(menubar_sep_state)"; mkdir -p "$(menubar_dir)"
  # replié, macOS réécrit les positions des apps rangées (+ la largeur de l'écarteur) : le cache d'avant le geste ne vaut plus
  rm -f "$(menubar_dir)/positions"
  case "${1:-}" in
    show) printf 'expanded %s\n' "${LAB_NOW_EPOCH:-$(date +%s)}" >"$f"
      # le repli : un rafraîchissement du greffon après le délai, détaché (le clic rend la main tout de suite)
      # shellcheck disable=SC2016 # $1 et $2 sont développés par le bash détaché
      [ "$MENUBAR_WAIT" = 0 ] || nohup /bin/bash -c 'sleep "$1"; open -g "swiftbar://refreshplugin?name=$2"; open -g "swiftbar://refreshplugin?name=$3"' _ "$MENUBAR_SEP_OPEN_S" "$MENUBAR_HIDE_NAME" "$MENUBAR_SEP_NAME" </dev/null >/dev/null 2>&1 &
      kv SEPARATOR expanded; kv MESSAGE "tucked-away apps shown for $MENUBAR_SEP_OPEN_S seconds" ;;
    hide) rm -f "$f"; kv SEPARATOR collapsed; kv MESSAGE "tucked-away apps hidden" ;;
    *) usage ;;
  esac
  open -g "swiftbar://refreshplugin?name=$MENUBAR_HIDE_NAME" >/dev/null 2>&1 || true
  open -g "swiftbar://refreshplugin?name=$MENUBAR_SEP_NAME" >/dev/null 2>&1 || true
}
# menubar_sep_install <dossier> <env> <lab> <PATH> : écrit le chevron et l'écarteur ; leurs positions, si l'utilisateur ne les a
# pas déjà choisies : le chevron juste à gauche de la pastille (sa position + sa largeur : des distances, jamais des empans qui se
# chevauchent), l'écarteur juste à gauche du chevron ; retirées par remove
menubar_sep_install() {
  local dir="$1" env="$2" lab="$3" path="$4" pp
  pp="$(defaults read "$WIDGET_DOMAIN" "$MENUBAR_PREFIX $dir/$WIDGET_PLUGIN" 2>/dev/null)" || pp="$WIDGET_POSITION"
  pp="$(printf '%s\n' "$pp" | awk -v w="$WIDGET_DOT_WIDTH" '{ printf "%d", $1 + w }')"
  menubar_plugin_write "$dir/$MENUBAR_SEP_PLUGIN" render-sep "Treelab menu bar separator" "$env" "$lab" "$path" "$pp" sep || return 1
  # le chevron déjà placé par l'utilisateur : l'écarteur se pose contre lui, où qu'il soit
  pp="$(defaults read "$WIDGET_DOMAIN" "$MENUBAR_PREFIX $dir/$MENUBAR_SEP_PLUGIN" 2>/dev/null | awk '{ printf "%d", $1 }')" || true
  [ -n "$pp" ] || pp="$WIDGET_POSITION"
  menubar_plugin_write "$dir/$MENUBAR_HIDE_PLUGIN" render-hide "Treelab menu bar spacer" "$env" "$lab" "$path" "$((pp + MENUBAR_SEP_WIDTH))" hide
}
# menubar_plugin_write <fichier> <commande> <titre> <env> <lab> <PATH> <position> <étiquette> : un greffon enveloppe et sa position
menubar_plugin_write() {
  local plugin="$1" cmd="$2" title="$3" env="$4" lab="$5" path="$6" pos="$7" tag="$8" key
  # shellcheck disable=SC2016 # corps du greffon généré : "$@" et $# restent littéraux
  {
    printf '#!/bin/bash\n# %s, written by lab widget install; lab widget remove takes it away.\n' "$title"
    printf '# <swiftbar.hideAbout>true</swiftbar.hideAbout>\n# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>\n'
    printf '# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>\n# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>\n'
    printf 'export PATH=%s\n' "$(shell_quote "$path")"
    printf '[ "$#" -gt 0 ] || set -- widget %s   # no argument: the item for SwiftBar; a click: its words, as they are\n' "$cmd"
    printf 'exec env %s %s "$@"\n' "$env" "$(shell_quote "$lab")"
  } >"$plugin.tmp" || return 1
  if ! chmod 755 "$plugin.tmp" || ! mv "$plugin.tmp" "$plugin"; then rm -f "$plugin.tmp"; return 1; fi
  key="$MENUBAR_PREFIX $plugin"
  if ! defaults read "$WIDGET_DOMAIN" "$key" >/dev/null 2>&1; then
    defaults write "$WIDGET_DOMAIN" "$key" -float "$pos" >/dev/null 2>&1 && mkdir -p "$(menubar_dir)" && : >"$(menubar_dir)/$tag-position-added"
  fi
  return 0
}
# menubar_remove <dossier de greffons> : le séparateur, sa position si lab l'a posée, ce que tidy avait remplacé, l'état de la barre
menubar_remove() {
  local dir="$1" plugin d tag
  d="$(menubar_dir)"
  for tag in sep hide; do
    if [ "$tag" = sep ]; then plugin="$dir/$MENUBAR_SEP_PLUGIN"; else plugin="$dir/$MENUBAR_HIDE_PLUGIN"; fi
    [ ! -f "$plugin" ] || ! grep -q 'Treelab menu bar s' "$plugin" || rm -f "$plugin"
    if [ -f "$d/$tag-position-added" ]; then defaults delete "$WIDGET_DOMAIN" "$MENUBAR_PREFIX $plugin" >/dev/null 2>&1 || true; fi
  done
  menubar_untidy
  rm -f "$d/sep-position-added" "$d/hide-position-added" "$d/sep" "$d/order" "$d/positions" "$d/positions".* "$d/order".* "$d/history" "$d/probe" "$d"/.write.* 2>/dev/null || true
  rmdir "$d" 2>/dev/null || true
}

# menubar_sep_open → secondes restantes du dépliage (0 : replié ; l'état périmé est oublié)
menubar_sep_open() { menubar_sep_open_set; printf '%s\n' "$MENUBAR_LEFT"; }
# menubar_sep_open_set [maintenant] : MENUBAR_LEFT, sans sous-shell ; l'état « expanded <epoch> » lu par read, l'heure prise une fois
menubar_sep_open_set() {
  local f="$LAB_STATE/widget/bar/sep" now="${1:-}" w t=""
  MENUBAR_LEFT=0; [ -f "$f" ] || return 0
  [ -n "$now" ] || now="${LAB_NOW_EPOCH:-$(exec date +%s)}"
  read -r w t _ <"$f" || :
  case "$t" in ''|*[!0-9]*) t=0 ;; esac
  MENUBAR_LEFT=$(( MENUBAR_SEP_OPEN_S - (now - 10#$t) )); [ "$MENUBAR_LEFT" -gt 0 ] || { rm -f "$f"; MENUBAR_LEFT=0; }
}
# menubar_render_hide : l'écarteur pour SwiftBar — une image transparente, MENUBAR_SEP_WIDE pt replié, 1 pt déplié ; rien d'autre
menubar_render_hide() {
  local w="$MENUBAR_SEP_WIDE"
  . "$LAB_ROOT/lib/sysmon.sh"
  menubar_sep_open_set; [ "$MENUBAR_LEFT" -eq 0 ] || w=1
  LC_ALL=C awk -v w="$w" "$SYSMON_PDF_AWK"' BEGIN { pdf_init(); pdf_begin(w, 22); print "| image=" pdf_end() " ansi=false" }' </dev/null
}

# menubar_render_sep : le chevron pour SwiftBar (toujours dessiné, à droite de l'écarteur), puis son menu. Toujours rc 0.
menubar_render_sep() {
  local dir exp=0 left now probe pos order lab plugdir hist n week=0 rival istat_inst=0 lang menu f
  . "$LAB_ROOT/lib/sysmon.sh"
  # chemins et lectures sans sous-shell, un processus par programme (lot 04 de charge-processeur) : même menu
  dir="$LAB_STATE/widget/bar"; [ -d "$dir" ] || mkdir -p "$dir"; now="${LAB_NOW_EPOCH:-$(exec date +%s)}"
  menubar_sep_open_set "$now"; left="$MENUBAR_LEFT"; [ "$left" -eq 0 ] || exp=1
  probe="$dir/probe"; menubar_probe >"$probe.$$"; mv "$probe.$$" "$probe"
  menubar_positions_cached_set; pos="$MENUBAR_POSF"; order="$dir/order"
  widget_plugin_dir_set; plugdir="$WIDGET_PLUGIN_DIR"
  if [ -x "${SWIFTBAR_PLUGIN_PATH:-}" ]; then lab="$SWIFTBAR_PLUGIN_PATH"; else lab="$(widget_lab)"; fi
  # apps rangées : compte gardé une fois par heure sur 7 jours, pour dire ce qui s'accumule
  n="$(exec awk -F '\t' -v sep="/$MENUBAR_HIDE_PLUGIN" 'NR > 1 && NF == 4 { X[NR] = $1; W[NR] = $2; N[NR] = $4; if (substr($4, length($4) - length(sep) + 1) == sep) s = NR }
    END { c = 0; if (s) for (i in X) if (i != s && X[i] + W[i] <= X[s] + 1) c++; print c }' "$probe")"
  hist="$dir/history"
  if [ -z "$(exec awk -v t="$now" 'END { if ($1 != "" && t - $1 < 3600) print "fresh" }' "$hist" 2>/dev/null)" ]; then
    printf '%s %s\n' "$now" "$n" >>"$hist"
    awk -v t="$now" 't - $1 <= 604800' "$hist" >"$hist.$$" 2>/dev/null && mv "$hist.$$" "$hist"
  fi
  week="$(exec awk -v n="$n" 'NR == 1 { print n - $2 }' "$hist" 2>/dev/null)"; week="${week:-0}"
  rival="$(menubar_rival)"
  for f in "$HOME/Library/LaunchAgents"/com.bjango.istatmenus*.plist; do [ ! -e "$f" ] || istat_inst=1; break; done   # comme menubar_istat_plists
  widget_lang_set 2>/dev/null; lang="$WIDGET_LANG"; widget_menu_set; menu="$WIDGET_MENU"
  terminal_found_set   # apps de terminal posées (le fork de cmux) : identifiants exclus comme cmux, lot 02 d'app-treelab
  LC_ALL=C awk -F '\t' -v lang="$lang" -v menu="$menu" -v bar="${LAB_WIDGET_BAR:-dark}" -v lab="$lab" -v plugdir="$plugdir" \
    -v sepname="/$MENUBAR_SEP_PLUGIN" -v hidename="/$MENUBAR_HIDE_PLUGIN" -v wide="$MENUBAR_SEP_WIDE" -v opened="$exp" -v left="$left" -v glyph="$MENUBAR_SEP_GLYPH" \
    -v order="$order" -v posf="$pos" -v saved="$([ -f "$order" ] && echo 1 || echo 0)" -v week="$week" -v rival="$rival" \
    -v spacing="$([ -f "$dir/spacing" ] && echo 1 || echo 0)" -v dupesf="$dir/dupes" -v dupes_done="$([ -f "$dir/dupes" ] && echo 1 || echo 0)" \
    -v istat_done="$([ -f "$dir/istat" ] && echo 1 || echo 0)" -v istat_inst="$istat_inst" -v mods=" $MENUBAR_CC_MODULES " -v keep=" $MENUBAR_CC_KEEP " \
    -v ccdom="$MENUBAR_CC" -v openS="$MENUBAR_SEP_OPEN_S" -v SPC="$MENUBAR_SPACING" -v termids=" ${TERMINAL_FOUND_IDS//$'\n'/ } " \
    "$SYSMON_PDF_AWK$MENUBAR_TEXT_AWK$MENUBAR_SAME_AWK$MENUBAR_RENDER_AWK" "$probe"
}

# ---------- table des textes des menus (langue du Mac, FR/EN comme au lot 05) ----------
# shellcheck disable=SC2016 # programme awk
MENUBAR_TEXT_AWK='
function d(k, f, e) { FR[k] = f; EN[k] = e }
function t(k) { return (lang == "fr") ? FR[k] : EN[k] }
function ts(k, a,   s) { s = t(k); gsub(/&/, "\\\\&", a); gsub(/%s/, a, s); return s }
function tr_init() {
      d("ok", "Tout est visible.", "Everything is visible."); d("room", "%s pt de marge avant l\342\200\231encoche", "%s pt of room before the notch")
      d("stowed", "%s apps rangées", "%s apps tucked away"); d("open", "Déplié : les apps rangées sont visibles", "Open: tucked-away apps are showing")
      d("closes", "se replie seul dans %s s", "closes by itself in %s s"); d("hidden", "Caché : %s", "Hidden: %s")
      d("short", "il manque environ %s pt", "about %s pt short"); d("a_hidden", "Une icône lab est cachée", "A lab icon is hidden")
      d("a_new", "Nouvelle icône à droite du chevron : %s", "New icon right of the chevron: %s"); d("stow", "Ranger %s derrière le chevron", "Tuck %s behind the chevron")
      d("stow_go", "Ranger maintenant", "Tuck it away now")
      d("keep", "La garder visible et enregistrer cet ordre", "Keep it visible and save this order")
      d("menus", "Les menus de l\342\200\231app au premier plan prennent la place : rien à ranger.", "The front app\342\200\231s menus take the room: nothing to tuck away.")
      d("steps", "Ranger la barre · %s étapes faites sur 4", "Tidy the bar · %s of 4 steps done")
      d("s1", "Enregistrer l\342\200\231ordre", "Save the order")
      d("s1d", "⌘ + glissez à gauche du chevron ce que vous voulez ranger, à droite ce qui reste visible, puis enregistrez.", "Command-drag left of the chevron what you want tucked away, right of it what stays visible, then save.")
      d("s1c", "lab le remet en place après une mise à jour ou un redémarrage.", "lab puts it back after an update or a restart.")
      d("s1a", "Enregistrer l\342\200\231ordre actuel", "Save the current order"); d("s2", "Resserrer l\342\200\231espacement", "Tighten the spacing")
      d("s2d", "16 → 6 pt : 10 pt gagnés par icône, soit %s pt ici.", "16 → 6 pt: 10 pt saved per icon, %s pt here.")
      d("s2c", "Le Centre de contrôle et SwiftBar se relancent ; les autres apps à leur prochain lancement.", "Control Center and SwiftBar relaunch; other apps at their next launch.")
      d("s2a", "Resserrer à 6 pt", "Tighten to 6 pt"); d("s3", "Masquer les doublons", "Hide the duplicates")
      d("s3d", "%s sont déjà dans le Centre de contrôle : les retirer de la barre libère ", "%s are already in Control Center: taking them off the bar frees ")
      d("s3c", "Le Centre de contrôle redémarre une seconde, rien n\342\200\231est perdu.", "Control Center restarts for a second, nothing is lost.")
      d("s3a", "Masquer %s", "Hide %s"); d("s4", "Couper iStat Menus", "Stop iStat Menus")
      d("s4d", "Nos six modules le remplacent : il est quitté et ne s\342\200\231ouvre plus à la connexion, ses réglages restent.", "Our six modules replace it: it quits and no longer opens at login, its settings stay.")
      d("s4c", "La désinstallation, dans Setapp, reste votre geste ; lab widget remove le rétablit.", "Uninstalling it in Setapp stays yours; lab widget remove brings it back.")
      d("later", "Pas maintenant", "Not now"); d("undo", "Chaque étape se défait par lab widget remove.", "Each step is undone by lab widget remove.")
      d("watch", "Sous surveillance", "Watching"); d("w_mods", "Pastille et six modules visibles", "The dot and six modules visible")
      d("w_spacing", "Espacement resserré à 6 pt", "Spacing tightened to 6 pt"); d("w_dupes", "%s toujours masqués", "%s still hidden")
      d("w_dupes_back", "%s de retour dans la barre", "%s back in the bar"); d("w_again", "Masquer à nouveau", "Hide again")
      d("w_istat", "iStat Menus coupé", "iStat Menus stopped"); d("w_istat_back", "iStat Menus a redémarré", "iStat Menus started again")
      d("w_istat_again", "Le couper à nouveau", "Stop it again"); d("w_order", "Ordre conforme à l\342\200\231enregistrement", "Order matches the saved one")
      d("w_moved", "%s icônes ont bougé depuis l\342\200\231enregistrement", "%s icons moved since the save"); d("w_more", ", %s de plus cette semaine", ", %s more this week")
      d("behind", "Rangées derrière le chevron (%s)", "Behind the chevron (%s)"); d("show10", "Afficher pendant 10 secondes", "Show for 10 seconds")
      d("hide_now", "Replier maintenant", "Close now"); d("order", "Ordre de la barre", "Bar order")
      d("o_saved", "Enregistré le %s", "Saved %s"); d("o_none", "Aucun ordre enregistré", "No saved order")
      d("o_moved", "%s ont bougé depuis", "%s moved since"); d("o_same", "Rien n\342\200\231a bougé", "Nothing moved")
      d("restore", "Rétablir l\342\200\231ordre", "Restore the order"); d("relist", "Rétablir relance ces apps :", "Restoring relaunches these apps:")
      d("redo", "Relancer et rétablir", "Relaunch and restore"); d("never", "Jamais relancés : cmux, agents, SwiftBar", "Never relaunched: cmux, agents, SwiftBar")
      d("help", "Comment ranger une icône", "How to tuck an icon away")
      d("help1", "⌘ + glisser une icône à gauche du chevron : elle est rangée.", "Command-drag an icon left of the chevron: it is tucked away.")
      d("help2", "À droite du chevron : elle reste visible.", "Right of the chevron: it stays visible.")
      d("help3", "Puis Enregistrer l\342\200\231ordre : lab le rétablit après une mise à jour.", "Then Save the order: lab restores it after an update.")
      d("rival", "%s tourne : quittez-le d\342\200\231abord, deux rangeurs se battent", "%s is running: quit it first, two bar organisers fight")
      d("refresh", "Actualiser", "Refresh"); d("notch", "encoche", "notch"); d("marge", "marge", "room"); d("and", " et ", " and ")
      d("l_dot", "pastille", "dot"); d("l_mods", "modules", "modules"); d("l_other", "autres", "others")
      d("imp_cc", "redémarre seul en une seconde", "restarts by itself in a second"); d("imp_raycast", "se relance, rien n\342\200\231est perdu", "relaunches, nothing is lost")
      d("imp_drive", "se relance, la synchro reprend", "relaunches, sync resumes"); d("imp_telegram", "se relance, vos brouillons restent", "relaunches, your drafts stay")
      d("imp_app", "se relance : un document non enregistré peut demander confirmation", "relaunches: an unsaved document may ask first")
      d("imp_swiftbar", "replacé sans relance", "moved without a relaunch"); d("imp_excluded", "jamais relancé par lab : à glisser à la main", "never relaunched by lab: drag it by hand")
      d("n_clock", "Horloge", "Clock"); d("n_cc", "Centre de contrôle", "Control Center"); d("n_dot", "la pastille lab", "the lab dot")
      d("n_mem", "Mémoire", "Memory"); d("n_net", "Réseau", "Network"); d("n_battery", "Batterie", "Battery"); d("n_temp", "Températures", "Temperatures")
}
'

# ---------- rendu du séparateur (awk ; entrée : le relevé, puis photo, positions et doublons lus par getline) ----------
# shellcheck disable=SC2016 # programme awk
MENUBAR_RENDER_AWK='
BEGIN { pdf_init(); tr_init() }
NR == 1 && $1 == "SCREEN" { SW = $2 + 0; NOTCH = $3 + 0; next }
NF == 4 { n++; X[n] = $1 + 0; W[n] = $2 + 0; ON[n] = $3 + 0; NM[n] = $4
  if (substr($4, length($4) - length(hidename) + 1) == hidename) S = n; if (substr($4, length($4) - length(sepname) + 1) == sepname) C = n }
function base(p) { sub(/^.*\//, "", p); return p }
function labid(p,   b) { if (plugdir == "" || index(p, plugdir "/") != 1) return ""; b = base(p); if (b !~ /^lab[.-].*\.sh$/) return ""
  if (b ~ /^lab\./) return "dot"; sub(/^lab-/, "", b); sub(/\..*$/, "", b); return b }
function dom_name(dm,   s) {
  if (dm == "com.google.drivefs") return "Google Drive"; if (dm == "com.cmuxterm.app") return "cmux"; if (dm == "ru.keepcoder.Telegram") return "Telegram"
  if (dm == "com.raycast.macos") return "Raycast"; if (dm ~ /^com\.setapp\./) return "Setapp"; if (dm == ccdom) return t("n_cc")
  s = dm; sub(/^.*\./, "", s); return s }
# fname : le nom lisible d une icône (autosave → app) ; Item-N se lit par les domaines qui portent cette clé
function fname(nm,   id, s, k, c, r) {
  id = labid(nm)
  if (id == "dot") return t("n_dot"); if (id == "sep" || id == "hide") return "Chevron"; if (id == "cpu") return "CPU"; if (id == "mem") return t("n_mem")
  if (id == "disk") return "SSD"; if (id == "net") return t("n_net"); if (id == "battery") return t("n_battery"); if (id == "temp") return t("n_temp")
  if (nm == "Clock") return t("n_clock"); if (nm ~ /^BentoBox/) return t("n_cc"); if (nm == "WiFi") return "Wi-Fi"
  if (nm == "raycastIcon") return "Raycast"; if (nm == "Setapp Main") return "Setapp"; if (nm == "com.apple.menuextra.TimeMachine") return "Time Machine"
  if (nm ~ /^com\.bjango\.istatmenus\./) { s = nm; sub(/^com\.bjango\.istatmenus\./, "", s); return "iStat " s }
  if (index(nm, "/")) { s = base(nm); sub(/\..*$/, "", s); return s }
  if (nm ~ /^Item-[0-9]+$/) { c = 0; for (k = 1; k <= np; k++) if (PNM[k] == nm) RN[++c] = dom_name(PDOM[k])
    for (k = 1; k <= c; k++) for (r = k + 1; r <= c; r++) if (RN[r] < RN[k]) { s = RN[k]; RN[k] = RN[r]; RN[r] = s }
    r = ""; for (k = 1; k <= c; k++) r = r ((k > 1) ? " / " : "") RN[k]; if (r != "") return r }
  return nm }
function txt(s) { gsub(/\|/, "/", s); gsub(/[\001-\037]/, " ", s); sub(/^-+/, " &", s); return s }
function q(s) { return (s ~ /[ "]/) ? "\"" s "\"" : s }
function click(cmd,   w, k, i, s) { k = split(cmd, w, " "); s = "bash=" q(lab) " param1=widget param2=act"; for (i = 1; i <= k; i++) s = s " param" (i + 2) "=" w[i]; return s " terminal=false refresh=true" }
# stowclick : le nom peut porter des espaces (« Setapp Main », chemin de greffon) : un seul paramètre. Un nom de fenêtre est choisi
# par n importe quelle app : seul un nom sûr (lettres, chiffres, espace, . _ / -) devient un paramètre, jamais un « = », un guillemet
# ou un caractère de contrôle qu un découpage de SwiftBar lirait comme un autre paramètre (revue de sécurité du lot 06)
function safe(nm) { return nm ~ /^[A-Za-z0-9 ._\/-]+$/ }
# stowmenu : ranger relance l app de l icône ; son impact est dit d abord, le clic vient dans le sous-menu
function stowmenu(nm,   k) {
  print txt(ts("stow", fname(nm))) " | refresh=true"
  for (k = 1; k <= np; k++) if (PNM[k] == nm) print "--" txt(dom_name(PDOM[k])) " : " txt(t(impkey(PDOM[k]))) " | size=12 refresh=true"
  print "--" txt(t("stow_go")) " | " stowclick(nm) }
function stowclick(nm) { return "bash=" q(lab) " param1=widget param2=act param3=order param4=stow param5=" q(nm) " terminal=false refresh=true" }
# ulen : caractères (et non octets) d une chaîne UTF-8 ; wrap coupe en lignes de w0 caractères, « 71 pt » jamais séparés
function ulen(s,   i, k, o) { k = 0; for (i = 1; i <= length(s); i++) { o = ORD[substr(s, i, 1)]; if (o < 128 || o >= 192) k++ } return k }
function wrap(s, ind, opt, w0,   w, k, i, cur, out) { w0 = (w0 > 0) ? w0 : 50; gsub(/ pt/, "\302\240pt", s); k = split(s, w, " "); cur = ""; out = ""
  for (i = 1; i <= k; i++) { if (cur == "") cur = w[i]; else if (ulen(cur) + 1 + ulen(w[i]) <= w0) cur = cur " " w[i]; else { out = out ind txt(cur) " | " opt "\n"; cur = w[i] } }
  if (cur != "") out = out ind txt(cur) " | " opt "\n"; return out }
function list(A, k,   i, s) { s = ""; for (i = 1; i <= k; i++) s = s ((i == 1) ? "" : (i == k) ? t("and") : ", ") A[i]; return s }
# chevron : pointe à gauche (replié, « ranger ») ou à droite (déplié), trait de 1,8 pt dans la palette de la barre
function chev(x, dir) { pdf_push(); pdf_stroke(bar, "fg"); PC = PC "1.8 w 1 J 1 j\n"
  if (dir < 0) PC = PC n2(x + 7.5) " " py(6) " m " n2(x + 2.5) " " py(11) " l " n2(x + 7.5) " " py(16) " l S\n"
  else PC = PC n2(x + 2.5) " " py(6) " m " n2(x + 7.5) " " py(11) " l " n2(x + 2.5) " " py(16) " l S\n"
  pdf_pop() }
END {
  # photo et positions : saved = position enregistrée de chaque clé ; P = actuelle ; PDOM/PNM : domaine et nom par clé
  if (saved) while ((getline l < order) > 0) { if (l ~ /^#/) { SAVEDAT = substr(l, 9); continue } split(l, F, "\t"); SV[F[1] SUBSEP F[2]] = F[3]; SVN[F[2]] = F[3]; if (substr(F[2], length(F[2]) - length(hidename) + 1) == hidename) SEPPOS = F[3] + 0 }
  close(order)
  while ((getline l < posf) > 0) { split(l, F, "\t"); np++; PDOM[np] = F[1]; PNM[np] = F[2]; PV[np] = F[3]
    if (substr(F[2], length(F[2]) - length(hidename) + 1) == hidename) CURHIDE = F[3] + 0 }
  close(posf)
  while ((getline l < dupesf) > 0) { split(l, F, "\t"); if (F[1] != "") { nmask++; MASK[nmask] = F[1]; ISMASK[F[1]] = 1 } }
  close(dupesf)
  sr = (S) ? X[S] + W[S] : -1e9; vmin = SW
  # classement : à gauche du chevron (rangées), à droite (visibles) ; icônes lab cachées ; nouvelles venues ; doublons ; iStat
  for (i = 1; i <= n; i++) {
    if (i == S || i == C) continue
    id = labid(NM[i]); right = (!S || X[i] >= sr - 1)
    # doublons et iStat comptent où qu ils soient : à gauche, ils reprennent de la place dès que le chevron se déplie
    if (NM[i] ~ /^com\.bjango\.istatmenus\./) istat_now = 1
    if (index(mods, " " NM[i] " ") && !index(keep, " " NM[i] " ")) { if (ISMASK[NM[i]]) { nback++; BACK[nback] = fname(NM[i]) } else if (!SEENDUP[NM[i]]++) { ndup++; DUP[ndup] = fname(NM[i]); DUPW += W[i] } }
    if (!right && !opened) { nleft++; LEFT[nleft] = fname(NM[i]); continue }
    if (!right) { nleft++; LEFT[nleft] = fname(NM[i]) }
    if (id != "" && !ON[i]) { nhid++; HID[nhid] = fname(NM[i]); short += W[i]; HIDX[i] = 1 }
    if (ON[i] && X[i] >= NOTCH && X[i] < vmin) vmin = X[i]
    # nouvelle venue : à droite du chevron sans y avoir été enregistrée (absente de la photo, ou rangée à gauche dans la photo)
    if (right && id == "" && saved && NM[i] != "Clock" && NM[i] !~ /^BentoBox/ && !index(keep, " " NM[i] " ") && !index(mods, " " NM[i] " ") \
      && (!(NM[i] in SVN) || (SEPPOS > 0 && SVN[NM[i]] + 0 > SEPPOS))) { nnew++; NEWN[nnew] = NM[i] }
    if (right) nright++
  }
  # marge : de l encoche à la première icône visible, chevron compris
  if (C && ON[C]) { cx = X[C]; if (cx >= NOTCH && cx < vmin) vmin = cx }
  room = (nhid) ? 0 : int(vmin - NOTCH); if (room < 0) room = 0
  for (k in SV) { split(k, F, SUBSEP); cur = ""; for (j = 1; j <= np; j++) if (PDOM[j] == F[1] && PNM[j] == F[2]) cur = PV[j]
    if (cur == "" || !same(SV[k], SEPPOS, cur, CURHIDE)) { nmoved++; MD[F[1]] = 1 } }
  d1 = saved; d2 = spacing; d3 = dupes_done || ndup == 0; d4 = istat_done || (!istat_inst && !istat_now)
  ndone = d1 + d2 + d3 + d4
  warn_ = (nnew || nback || (istat_done && istat_now) || nmoved)
  # ---------- élément de barre ----------
  if (opened) { pdf_begin(glyph + 4, 22); pdf_push(); pdf_alpha(35); pdf_fill(bar, "fg"); pdf_rect(0.5, 4, 1, 14); pdf_pop(); chev(5, 1); bx = 5 }
  else { pdf_begin(glyph, 22); chev(2, -1); bx = 2 }
  if (nhid) { pdf_fill(bar, "crit"); pdf_disc(bx + 10, 5, 2.5) }
  else if (warn_) { pdf_fill(bar, "warn"); pdf_disc(bx + 10, 5, 2.5) }
  else if (ndone < 4) { pdf_push(); pdf_stroke(bar, "down"); PC = PC "1.2 w\n"; pdf_rrect(bx + 7.5, 2.5, 5, 5, 2.5, "S"); pdf_pop() }
  if (nhid) status = ts("hidden", list(HID, nhid)); else if (opened) status = t("open"); else status = t("ok")
  print "| image=" pdf_end() " tooltip=\"" txt(status) "\" ansi=false"
  print "---"
  if (rival != "") print txt(ts("rival", rival)) " | refresh=true"
  # ---------- alerte ----------
  if (nhid) {
    print "\033[31m●\033[0m " txt(t("a_hidden")) " | ansi=true refresh=true"
    printf "%s", wrap(ts("hidden", list(HID, nhid)) ", " ts("short", int(short + 0.5)) ".", "", "size=12 refresh=true")
    # le plus petit remède : ranger la nouvelle venue, sinon couper iStat ou masquer les doublons qui prennent la place, sinon ranger
    # l icône la plus à gauche, jamais celles gardées visibles par choix (Wi-Fi) ; rien à ranger : ce sont les menus de l app au premier plan
    cand = ""; if (nnew) cand = NEWN[1]
    else for (i = 1; i <= n; i++) if (i != S && i != C && X[i] >= sr - 1 && labid(NM[i]) == "" && ON[i] && NM[i] != "Clock" && NM[i] !~ /^BentoBox/ && !index(keep, " " NM[i] " ")) { if (cand == "" || X[i] < CX) { cand = NM[i]; CX = X[i] } }
    if (!nnew && istat_now && !istat_done) print txt(t("s4")) " | " click("tidy istat")
    else if (!nnew && ndup && !dupes_done) print txt(ts("s3a", list(DUP, ndup))) " | " click("tidy duplicates")
    else if (cand != "" && rival == "" && safe(cand)) stowmenu(cand)
    else printf "%s", wrap(t("menus"), "", "size=12 refresh=true")
    print "---"
  } else if (nnew && rival == "") {
    print "\033[33m●\033[0m " txt(ts("a_new", fname(NEWN[1]))) " | ansi=true refresh=true"
    if (safe(NEWN[1])) stowmenu(NEWN[1])
    print txt(t("keep")) " | " click("order save")
    print "---"
  }
  # ---------- carte ----------
  M = 300; MH = 44; pdf_begin(M, MH); span = SW - NOTCH; if (span <= 0) span = SW; if (span <= 0) span = 1; sc = (M - 42) / span
  pdf_push(); pdf_alpha(12); pdf_fill(menu, "ink"); pdf_rrect(0, 4, M, 22, 4, "f"); pdf_pop()
  pdf_fill(menu, "ink"); pdf_rrect(0, 4, 38, 22, 4, "f"); pdf_text(4, 18.5, 2, 6.5, menu, "mute", t("notch"), 0)
  for (i = 1; i <= n; i++) {
    if (i == S || i == C) continue
    if (X[i] + W[i] <= NOTCH && !HIDX[i]) continue
    id = labid(NM[i]); xm = 40 + (X[i] - NOTCH) * sc; if (xm < 40) xm = 40; wm = W[i] * sc - 1.5; if (wm < 2) wm = 2
    if (HIDX[i]) col = "crit"; else if (id == "dot") col = "ok"; else if (id != "") col = "fg"; else col = "mute"
    for (k = 1; k <= nnew; k++) if (NEWN[k] == NM[i]) col = "warn"
    if (!ON[i] && !HIDX[i]) continue
    pdf_push(); if (col == "mute") pdf_alpha(35); pdf_fill(menu, col); pdf_rrect(xm, 7, wm, 16, 2.5, "f"); pdf_pop()
  }
  if (C) { xm = 40 + (X[C] - NOTCH) * sc; if (xm < 40) xm = 40; pdf_fill(menu, "mute"); pdf_rrect(xm, 7, 2.5, 16, 1.2, "f") }
  if (room > 0) { xm = 40; wm = room * sc - 2; if (wm > 12) { pdf_push(); pdf_stroke(menu, "down"); PC = PC "0.8 w [2 2] 0 d\n"; pdf_rrect(xm, 8, wm, 14, 2.5, "S"); pdf_pop()
    if (wm > 24) pdf_text(xm + 3, 18, 2, 6.5, menu, "down", t("marge"), 0) } }
  # légende : pastille, modules, autres icônes, marge ; en rouge une icône lab cachée, en ambre une nouvelle venue
  lx = 0; split("ok l_dot|fg l_mods|mute l_other|down marge", LG, "|")
  for (k = 1; k <= 4; k++) { split(LG[k], F, " "); if (F[1] == "down" && room <= 0) continue
    pdf_push(); if (F[1] == "mute") pdf_alpha(35); pdf_fill(menu, F[1]); pdf_rrect(lx, 33, 7, 7, 1.5, "f"); pdf_pop()
    pdf_text(lx + 10, 39.5, 2, 7, menu, "mute", t(F[2]), 0); lx += 16 + pdf_tw(t(F[2]), 2, 7, 0) }
  print "| image=" pdf_end() " width=" M " height=" MH " refresh=true"
  if (nhid) print txt(ts("hidden", list(HID, nhid))) " | refresh=true"
  else if (opened) { print txt(t("open")) " | refresh=true"; print txt(ts("closes", left)) " | size=11 refresh=true" }
  else { print txt(t("ok")) " | refresh=true"; print txt(ts("room", room)) " · " txt(ts("stowed", nleft + 0)) " | size=11 refresh=true" }
  print "---"
  # ---------- parcours (tant qu une étape reste) ou surveillance ----------
  if (ndone < 4) {
    print txt(ts("steps", ndone)) " | size=11 refresh=true"
    cur = (!d1) ? 1 : (!d2) ? 2 : (!d3) ? 3 : 4
    for (st = 1; st <= 4; st++) {
      dn = (st == 1) ? d1 : (st == 2) ? d2 : (st == 3) ? d3 : d4
      if (dn) { print txt(t("s" st)) " | checked=true refresh=true"; continue }
      if (st != cur) { print st "   " txt(t("s" st)) " | refresh=true"; continue }
      print st "   " txt(t("s" st)) " | refresh=true"
      if (st == 1) { printf "%s", wrap(t("s1d"), "", "size=12 refresh=true"); printf "%s", wrap(t("s1c"), "", "size=11 refresh=true")
        if (rival == "") print txt(t("s1a")) " | " click("order save") }
      if (st == 2) { printf "%s", wrap(ts("s2d", 10 * (nright + 1)), "", "size=12 refresh=true"); printf "%s", wrap(t("s2c"), "", "size=11 refresh=true")
        print txt(t("s2a")) " | " click("tidy spacing") }
      if (st == 3) { printf "%s", wrap(ts("s3d", list(DUP, ndup)) int(DUPW + 0.5) " pt.", "", "size=12 refresh=true"); printf "%s", wrap(t("s3c"), "", "size=11 refresh=true")
        print txt(ts("s3a", list(DUP, ndup))) " | " click("tidy duplicates") }
      if (st == 4) { printf "%s", wrap(t("s4d"), "", "size=12 refresh=true"); printf "%s", wrap(t("s4c"), "", "size=11 refresh=true")
        print txt(t("s4")) " | " click("tidy istat") }
      print txt(t("later")) " | refresh=true"
    }
    print txt(t("undo")) " | size=11 refresh=true"
  } else {
    print txt(t("watch")) " | size=11 refresh=true"
    if (!nhid) print txt(t("w_mods")) " | checked=true refresh=true"
    print txt(t("w_spacing")) " | checked=true refresh=true"
    if (nback) { print "! " txt(ts("w_dupes_back", list(BACK, nback))) " | refresh=true"; print "--" txt(t("w_again")) " | " click("tidy duplicates") }
    else if (nmask) print txt(ts("w_dupes", list(MASK, nmask))) " | checked=true refresh=true"
    if (istat_done && istat_now) { print "! " txt(t("w_istat_back")) " | refresh=true"; print "--" txt(t("w_istat_again")) " | " click("tidy istat") }
    else if (istat_done) print txt(t("w_istat")) " | checked=true refresh=true"
    if (nmoved) print "! " txt(ts("w_moved", nmoved)) " | refresh=true"; else print txt(t("w_order")) " | checked=true refresh=true"
    if (week > 0) print txt(ts("stowed", nleft + 0)) txt(ts("w_more", week)) " | refresh=true"
  }
  print "---"
  # ---------- apps rangées ----------
  print txt(ts("behind", nleft + 0)) " | size=11 refresh=true"
  for (i = 1; i <= nleft; i++) print "--" txt(LEFT[i]) " | refresh=true"
  if (opened) print txt(t("hide_now")) " | " click("sep hide"); else print txt(t("show10")) " | " click("sep show")
  print "---"
  # ---------- ordre et aide ----------
  print txt(t("order")) " | refresh=true"
  if (rival != "") print "--" txt(ts("rival", rival)) " | refresh=true"
  else {
    if (!saved) print "--" txt(t("o_none")) " | refresh=true"
    else { print "--" txt(ts("o_saved", SAVEDAT)) " | size=11 refresh=true"; print "--" txt((nmoved) ? ts("o_moved", nmoved) : t("o_same")) " | refresh=true" }
    if (nmoved) {
      print "--" txt(t("restore")) " | refresh=true"
      print "----" txt(t("relist")) " | size=11 refresh=true"
      for (dm in MD) print "----" txt(dom_name(dm)) " : " txt(t(impkey(dm))) " | size=12 refresh=true"
      print "----" txt(t("never")) " | size=11 refresh=true"
      print "----" txt(t("redo")) " | " click("order apply")
    }
    print "--" txt(t("s1a")) " | " click("order save")
  }
  print txt(t("help")) " | refresh=true"
  print "--" txt(t("help1")) " | refresh=true"; print "--" txt(t("help2")) " | refresh=true"; print "--" txt(t("help3")) " | refresh=true"
  print "---"
  print txt(t("refresh")) " | refresh=true"
}
function impkey(dm) {
  if (dm == "com.apple.controlcenter" || dm == "com.apple.systemuiserver") return "imp_cc"; if (dm == "com.ameba.SwiftBar") return "imp_swiftbar"
  if (dm == "com.cmuxterm.app" || index(termids, " " dm " ") || dm ~ /anthropic|claude|Claude|openai|codex/) return "imp_excluded"; if (dm == "com.raycast.macos") return "imp_raycast"
  if (dm == "com.google.drivefs") return "imp_drive"; if (dm == "ru.keepcoder.Telegram") return "imp_telegram"; return "imp_app" }
'
