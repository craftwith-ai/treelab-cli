# shellcheck shell=bash
# widget.sh — lab widget (lot 03 du couloir tableau-de-bord) : greffon SwiftBar de la barre de menus, alimenté par lab top.
# render lit une passe --fast (top_snapshot, aucun geste) et écrit le format SwiftBar : titre, état machine, « à couper » avec un
# sous-menu par proposition (impact, puis le clic), projets, familles hors Treelab. Chaque clic appelle lab widget act suivi des
# mots exacts de l'ACTION ou de l'EXPLAIN du bloc (bash= et paramN=, aucun shell intermédiaire) ; act lance ce geste, notifie
# son résultat et relaie son code. install pose l'enveloppe lab.60s.sh dans le dossier de greffons de SwiftBar et son ouverture à
# la connexion ; remove les retire et laisse les préférences de l'utilisateur. SwiftBar lui-même n'est jamais installé par lab.
# Mesuré sur SwiftBar 2.1.1 (2026-10-23) : préférence PluginDirectory du domaine com.ameba.SwiftBar, titre ANSI (ansi=true),
# URL swiftbar://refreshallplugins.

WIDGET_DOMAIN=com.ameba.SwiftBar
WIDGET_PLUGIN=lab.60s.sh
WIDGET_BREW='brew reinstall --cask swiftbar'
WIDGET_WRAP=60   # largeur d'une ligne d'impact dans un sous-menu
# Modules système (lot 04), dans l'ordre d'affichage à droite de la pastille ; temp exige macmon (posé par install)
WIDGET_MODULES='cpu mem disk net battery temp'
WIDGET_MACMON_BREW='brew install macmon'
WIDGET_SYSMON_TTL=8   # secondes : au-delà, un greffon rafraîchit le cache ; en deçà, il lit le cache de la passe précédente
# Position mémorisée par macOS pour l'élément du greffon (distance au bord droit, en points) : sans elle, un nouvel élément se pose
# à gauche des autres, sous l'encoche d'une barre pleine, invisible et impossible à glisser (vrai poste, 2026-10-24). Lot 06 : ce
# sont des distances, pas des rangs — chaque élément commence où finit le précédent (largeurs mesurées à l'espacement 16 du
# système), sinon les empans se chevauchent et macOS les départage à la création (CPU et pastille inversés, vrai poste, 2026-10-25).
WIDGET_POSITION_BASE=140   # bord droit du module le plus à droite : la place de l'horloge, du Centre de contrôle et du Wi-Fi
WIDGET_MODULE_WIDTHS='cpu 70 mem 63 disk 63 net 96 battery 74 temp 43'
# shellcheck disable=SC2034 # lu par lib/menubar.sh (position du séparateur)
WIDGET_DOT_WIDTH=75
WIDGET_POSITION=549        # la pastille : WIDGET_POSITION_BASE + les six modules
widget_position_key() { printf 'NSStatusItem Preferred Position %s\n' "$1"; }

widget_state() { printf '%s/widget\n' "$LAB_STATE"; }
# widget_app → chemin de SwiftBar.app, vide s'il manque ; LAB_SWIFTBAR_APP impose le chemin (tests, installation ailleurs)
widget_app() {
  local a
  if [ -n "${LAB_SWIFTBAR_APP:-}" ]; then [ -d "$LAB_SWIFTBAR_APP" ] && printf '%s\n' "$LAB_SWIFTBAR_APP"; return 0; fi
  for a in /Applications/SwiftBar.app "$HOME/Applications/SwiftBar.app"; do [ -d "$a" ] && { printf '%s\n' "$a"; return 0; }; done
  return 0
}
# widget_lab → le lab que le greffon appelle : le lien stable d'une installation (LAB_HOME/current survit à lab update), sinon le
# programme qui tourne
widget_lab() {
  if [ -f "$LAB_ROOT/.release" ] && [ -e "$LAB_HOME/current/bin/lab" ] && [ "$(real_path "$LAB_HOME/current")" = "$LAB_ROOT" ]; then
    printf '%s\n' "$LAB_HOME/current/bin/lab"
  else printf '%s\n' "$LAB_ROOT/bin/lab"; fi
}

# ---------- render ----------
# widget_render : le menu SwiftBar sur stdout, toujours rc 0 (une passe en échec devient un titre « ? » et sa raison) ; le dernier
# résultat d'un clic (state/widget/last) est rappelé en tête pendant 10 minutes, repli quand macOS refuse la notification.
widget_render() {
  local blocks last="" lab
  # sous SwiftBar, les clics passent par l'enveloppe posée : SwiftBar lance une action sans l'environnement du greffon (LAB_HOME,
  # PATH figés), et un lab sans LAB_HOME écrivait son état ailleurs (vrai poste, 2026-10-24)
  lab="$(widget_lab)"; [ ! -x "${SWIFTBAR_PLUGIN_PATH:-}" ] || lab="$SWIFTBAR_PLUGIN_PATH"
  [ -z "$(find "$(widget_state)/last" -mmin -10 2>/dev/null)" ] || last="$(head -1 "$(widget_state)/last")"
  . "$LAB_ROOT/lib/top.sh"
  blocks="$(top_snapshot 1 2>/dev/null)" || blocks=""
  printf '%s\n' "$blocks" | LC_ALL=C awk -v lab="$lab" -v last="$last" -v wrapw="$WIDGET_WRAP" '
    BEGIN { RS = ""; FS = "\n" }
    function val(k,   i) { for (i = 1; i <= NF; i++) if (index($i, k "=") == 1) return substr($i, length(k) + 2); return "" }
    function size(m) { m += 0; return (m >= 1024) ? sprintf("%.1fG", m / 1024) : int(m) "M" }
    function dur(s) { if (s == "" || s == "unknown") return "?"; s += 0; return (s >= 172800) ? int(s / 86400) "d" : (s >= 3600) ? int(s / 3600) "h" : int(s / 60) "m" }
    # txt : texte sûr pour une ligne SwiftBar ; « | » sépare les paramètres, un tiret en tête ouvrirait un sous-menu
    function txt(s) { gsub(/\|/, "/", s); if (s ~ /^-/) s = "  " s; return s }
    function q(s) { return (s ~ /[ "]/) ? "\"" s "\"" : s }
    # click <mots de lab après « lab »> : lab widget act suivi de ces mots, un paramètre chacun
    function click(cmd,   w, n, i, s) {
      n = split(cmd, w, " "); s = "bash=" q(lab) " param1=widget param2=act"
      for (i = 1; i <= n; i++) s = s " param" (i + 2) "=" w[i]
      return s " terminal=false refresh=true"
    }
    function wrap(s, ind,   w, n, i, cur, out) {
      n = split(s, w, " "); cur = ""; out = ""
      for (i = 1; i <= n; i++) {
        if (cur == "") cur = w[i]; else if (length(cur) + 1 + length(w[i]) <= wrapw) cur = cur " " w[i]
        else { out = out ind txt(cur) "\n"; cur = w[i] }
      }
      if (cur != "") out = out ind txt(cur) "\n"
      return out
    }
    $1 == "BLOCK=MACHINE" { M = 1; pressure = val("PRESSURE"); free = val("FREE_PCT"); ram = val("RAM_MB"); comp = val("COMPRESSED_MB")
      swu = val("SWAP_USED_MB"); swt = val("SWAP_TOTAL_MB"); load = val("LOAD_1"); therm = val("THERMAL"); nsess = val("SESSIONS"); ncut = val("CUTS") }
    $1 == "BLOCK=CUT" { nc++; CR[nc] = val("REASON"); CG[nc] = val("GESTURE"); CT[nc] = val("TARGET"); CD[nc] = val("DETAIL"); CI[nc] = val("IMPACT")
      CA[nc] = val("ACTION"); CE[nc] = val("EXPLAIN"); CM[nc] = val("MEM"); if (CG[nc] == "hibernate") nidle++ }
    $1 == "BLOCK=SESSION" { p = val("PROJECT"); l = val("LANE"); if (p == "none") p = "outside projects"; if (l == "main") l = "main checkout"; else if (l == "none") l = "no lane"
      if (!(p in PS)) { np++; PN[np] = p; PS[p] = 0 } PS[p]++
      k = p SUBSEP l; if (!(k in LS)) { LS[k] = 0; LN[p] = LN[p] SUBSEP l } LS[k]++
      st = val("STATUS"); ph = val("PHASE")
      SL[k] = SL[k] "------" txt(val("AGENT") " " val("PID") " · " size(val("MEM")) " · idle " dur(val("IDLE")) ((st != "unknown" && st != "") ? " · " st : "") ((ph != "" && ph != "work") ? " · " ph : "")) "\n" }
    $1 == "BLOCK=FAMILY" { nf++; FL[nf] = txt(val("FAMILY") " · " val("PROCESSES") " procs · " size(val("MEM")) " · " val("CPU") "% CPU · largest " val("LARGEST")) }
    END {
      if (!M) {
        print "● ? | ansi=false"; print "---"; print "lab top gave no snapshot: open lab top to see why"
        print "Refresh | refresh=true"; print "Open lab top | bash=" q(lab) " param1=top terminal=true"; exit
      }
      # parent de sous-menu : toujours une action. SwiftBar 2.1.1 (#534, corrigé en 2.1.2 bêta) rend mort un parent sans action dont
      # le texte change d une passe à l autre (chiffres, tri) : grisé, sous-menu fermé ; refresh=true le garde actif, un clic rafraîchit
      par = " | refresh=true"
      col = (pressure == "normal") ? "32" : (pressure == "warning") ? "33" : (pressure == "critical") ? "31" : "90"
      # lot 05 : chiffres en chasse fixe (Menlo 12), comme les modules ; le point garde la couleur de la pression mémoire. Lot 06 :
      # forme courte « ●7 ✂5 » (≈ 15 pt gagnés hors encoche, maquette validée) ; le détail reste dans l infobulle et le menu
      printf "\033[%sm●\033[0m%d ✂%d | ansi=true font=Menlo size=12 tooltip=\"%d sessions · %d to cut · memory pressure %s\"\n", col, nsess, ncut, nsess, ncut, pressure
      print "---"
      if (last != "") print "Last click: " txt(last)
      print "Memory pressure " pressure ", " free "% free"
      print "RAM " size(ram) " · compressed " size(comp) " · swap " size(swu) " of " size(swt)
      print "Load " load " · thermal " therm
      print "---"
      if (nc == 0) print "Nothing to cut"
      else {
        print "To cut (" nc ")" par
        for (i = 1; i <= nc; i++) {
          print "--" txt(CT[i] " · " CR[i] " · " size(CM[i])) par
          printf "%s", wrap(CD[i], "----")
          printf "%s", wrap("Impact: " CI[i], "----")
          if (CG[i] != "explain") print "----Cut: " CG[i] " | " click(substr(CA[i], 5))
          print "----Explain | " click(substr(CE[i], 5))
        }
        if (nidle > 0) print "Put all idle sessions to sleep (" nidle ") | " click("top --cut idle")
      }
      print "---"
      print "Projects (" np + 0 ")" ((np > 0) ? par : "")
      for (i = 1; i <= np; i++) for (j = i + 1; j <= np; j++) if (PN[j] < PN[i]) { t = PN[i]; PN[i] = PN[j]; PN[j] = t }
      for (i = 1; i <= np; i++) {
        p = PN[i]; print "--" txt(p) " (" PS[p] ")" par
        n = split(substr(LN[p], 2), L, SUBSEP)
        for (a = 1; a <= n; a++) for (b = a + 1; b <= n; b++) if (L[b] < L[a]) { t = L[a]; L[a] = L[b]; L[b] = t }
        for (a = 1; a <= n; a++) { k = p SUBSEP L[a]; print "----" txt(L[a]) " (" LS[k] ")" par; printf "%s", SL[k] }
      }
      print "Others (" nf + 0 ")" ((nf > 0) ? par : "")
      for (i = 1; i <= nf; i++) print "--" FL[i]
      print "---"
      print "Refresh | refresh=true"
      print "Open lab top | bash=" q(lab) " param1=top terminal=true"
    }'
}

# ---------- modules système (lots 04 et 05) ----------
# widget_module_render <module> <blocs KEY=value> [historique] : le texte SwiftBar d un module, au style des maquettes validées du
# lot 05 (variante A). L élément de barre est une seule image PDF (lib/sysmon.sh) : étiquette empilée sur la valeur, petit
# graphique de la dernière minute (6 points) ou camembert, teinté vert → ambre → rouge selon le niveau ; le menu ouvre sur un
# graphique de 10 min (60 points), puis un tableau en chasse fixe aligné sur WIDGET_COLS colonnes, titres de section discrets,
# libellés et nombres dans la langue du Mac (WIDGET_LANG, table FR/EN ci-dessous). Un menu de module ne porte aucun clic
# destructif : rien que des chiffres, qui consomme, et Actualiser. Apparences : WIDGET_BAR (texte de la barre, sombre
# depuis le lot 06) et WIDGET_MENU (menus, celle du système) ; light par défaut.
WIDGET_COLS=34
widget_module_render() {
  printf '%s\n' "$2" | LC_ALL=C awk -v m="$1" -v hist="${3:-}" -v lang="${WIDGET_LANG:-en}" -v bar="${WIDGET_BAR:-light}" \
    -v menu="${WIDGET_MENU:-light}" -v cols="$WIDGET_COLS" -v bp="$SYSMON_BAR_POINTS" -v macmonbrew="$WIDGET_MACMON_BREW" "$SYSMON_PDF_AWK"'
    BEGIN { RS = ""; FS = "\n"; pdf_init(); tr_init() }
    function d(k, f, e) { FR[k] = f; EN[k] = e }
    function t(k) { return (lang == "fr") ? FR[k] : EN[k] }
    function tr_init() {
      d("cpu_t", "Processeur · 10 min", "Processor · 10 min"); d("usage", "Utilisation", "Usage"); d("cores", "Cœurs E / P", "E / P cores")
      d("power", "Puissance", "Power"); d("load", "Charge système (1 min)", "System load (1 min)"); d("chip", "Puce", "Chip"); d("ncores", "cœurs", "cores")
      d("top", "Plus gros consommateurs (% d\342\200\231un cœur)", "Top consumers (% of one core)"); d("topm", "Plus gros consommateurs", "Top consumers"); d("refresh", "Actualiser", "Refresh")
      d("mem_t", "Mémoire · 10 min", "Memory · 10 min"); d("used_f", "Utilisée", "Used"); d("used", "Utilisé", "Used")
      d("pressure", "Pression", "Pressure"); d("pressure_l", "pression", "pressure"); d("normal", "normale", "normal"); d("warning", "avertissement", "warning")
      d("critical", "critique", "critical"); d("unknown", "inconnue", "unknown"); d("apps", "Applications", "Apps")
      d("wired", "Réservée", "Wired"); d("comp", "Compressée", "Compressed"); d("swap", "Swap", "Swap")
      d("disk_t", "activité 10 min", "activity 10 min"); d("free", "Libre", "Free"); d("total", "Total", "Total")
      d("activity", "Activité", "Activity"); d("ops", "Opérations", "Operations")
      d("net_t", "Réseau", "Network"); d("rx", "↓ Réception", "↓ Download"); d("tx", "↑ Envoi", "↑ Upload")
      d("rxt", "Reçu (total)", "Received (total)"); d("txt", "Envoyé (total)", "Sent (total)"); d("iface", "Interface", "Interface")
      d("bat_t", "Batterie", "Battery"); d("state", "État", "State"); d("discharging", "en décharge", "discharging")
      d("charging", "en charge", "charging"); d("charged", "chargée", "charged"); d("ac", "sur secteur", "on AC power")
      d("bunknown", "inconnu", "unknown"); d("remaining", "Restant", "Remaining"); d("left", "restantes", "left")
      d("cycles", "Cycles", "Cycles"); d("health", "Santé", "Health"); d("temperature", "Température", "Temperature")
      d("charge_t", "Charge · 10 min", "Charge · 10 min"); d("nobat", "Aucune batterie sur ce Mac", "No battery on this Mac")
      d("temp_t", "Températures · 10 min", "Temperatures · 10 min"); d("fan", "Ventilateur", "Fan"); d("rpm", "tr/min", "rpm")
      d("needmac", "Il faut macmon : ", "needs macmon: run "); d("now", "maintenant", "now")
      d("lg_net", "réception : surface · envoi : trait", "received: area · sent: line"); d("lg_temp", "0–100 °C", "0–100 °C")
      d("mem_l", "MÉM", "MEM"); d("G", "Go", "GB"); d("M", "Mo", "MB"); d("K", "Ko", "KB")
    }
    function val(k,   i) { for (i = 1; i <= NF; i++) if (index($i, k "=") == 1) return substr($i, length(k) + 2); return "" }
    # nombres : virgule décimale et espace avant % en français ; milliers séparés par une espace (fr) ou une virgule (en)
    function dec(x, n,   s) { s = sprintf("%." n "f", x + 0); if (lang == "fr") sub(/\./, ",", s); return s }
    function pc(x) { return x ((lang == "fr") ? " %" : "%") }
    function thou(x,   s, r) { s = int(x + 0) ""; r = ""; while (length(s) > 3) { r = ((lang == "fr") ? " " : ",") substr(s, length(s) - 2) r; s = substr(s, 1, length(s) - 3) } return s r }
    function gb(mb) { return dec(mb / 1024, 1) " " t("G") }
    function gbi(mb) { return int(mb / 1024 + 0.5) " " t("G") }
    # rate : au plus 8 caractères (« 999 Ko/s », « 9,9 Mo/s ») ; dès 1 000 Ko/s en Mo/s, sinon le texte mord sur le mini-graphique
    function rate(b) { b += 0; return (b >= 10485760) ? int(b / 1048576 + 0.5) " " t("M") "/s" : (b >= 1024000) ? dec(b / 1048576, 1) " " t("M") "/s" : int(b / 1024 + 0.5) " " t("K") "/s" }
    # niveaux : vert, ambre, rouge selon les seuils validés (CPU < 50 / 50–80 / > 80 ; disque < 75 / 75–90 / > 90 ; pression macOS ;
    # batterie neutre, ambre ≤ 20, rouge ≤ 10)
    # p += 0 : une valeur lue par val() est une chaîne, comparée en texte « 9 » > « 80 » (revue du lot 05)
    function lvl_cpu(p) { if (p == "") return "mute"; p += 0; return (p > 80) ? "crit" : (p >= 50) ? "warn" : "ok" }
    function lvl_disk(p) { if (p == "") return "mute"; p += 0; return (p > 90) ? "crit" : (p >= 75) ? "warn" : "ok" }
    function lvl_mem(s) { return (s == "normal") ? "ok" : (s == "warning") ? "warn" : (s == "critical") ? "crit" : "mute" }
    function lvl_batt(p) { return (p <= 10) ? "crit" : (p <= 20) ? "warn" : "fg" }
    # ulen : caractères (et non octets) d une chaîne UTF-8 ; cut : la tronque à n caractères, « … » compris
    function ulen(s,   i, n, o) { n = 0; for (i = 1; i <= length(s); i++) { o = ORD[substr(s, i, 1)]; if (o < 128 || o >= 192) n++ } return n }
    function cut(s, n,   i, k, o, r) {
      if (ulen(s) <= n) return s
      k = 0; r = ""
      for (i = 1; i <= length(s); i++) { o = ORD[substr(s, i, 1)]; if (o < 128 || o >= 192) { k++; if (k > n - 1) break } r = r substr(s, i, 1) }
      return r "…"
    }
    function sp(n,   r) { r = ""; while (n-- > 0) r = r " "; return r }
    # clean : texte sûr pour une ligne SwiftBar — « | » sépare les paramètres (un nom de processus piégé injecterait sinon un
    # bash=), un tiret en tête ouvrirait un sous-menu, les caractères de contrôle cassent la ligne (comme txt() de widget_render)
    function clean(s) { gsub(/\|/, "/", s); gsub(/[\001-\037]/, " ", s); sub(/^-+/, " &", s); return s }
    function line(s) { body = body s "\n" }
    # row : une ligne du tableau, libellé à gauche, valeur calée à droite sur cols colonnes, police à chasse fixe. refresh=true (clic
    # inoffensif) : macOS grise une ligne sans action, et une paire de couleurs « clair,sombre » est figée par SwiftBar 2.1.1 tant que
    # le texte ne change pas (illisible après un changement d apparence, vrai poste, 2026-10-24) ; la couleur du système suit seule
    function row(l, v, tip,   w) {
      l = clean(l); v = clean(v); w = cols - ulen(v) - 1; l = cut(l, w)
      line(l sp(cols - ulen(l) - ulen(v)) v " | refresh=true font=Menlo size=12" ((tip == "") ? "" : " tooltip=\"" qclean(tip) "\""))
    }
    # qclean : texte sûr dans un paramètre entre guillemets — « " » le refermerait, et un « = » y ferait lire un paramètre (bash=…)
    # à un découpage qui ignorerait les guillemets : il devient « ＝ » (signe égal pleine chasse, U+FF1D)
    function qclean(s) { s = clean(s); gsub(/"/, "'"'"'", s); gsub(/=/, "\357\274\235", s); return s }
    # titre de section : plus petit, sans couleur figée (SwiftBar fige une paire « clair,sombre », macOS grise une ligne sans action)
    function title(s) { line(clean(s) " | refresh=true size=11") }
    function sep() { line("---") }
    # H[i] : les points de l historique (colonnes : epoch cpu mem pression io down up batt temp) ; col(k, n) : les n derniers de la colonne k
    function load_hist(   l) { NH = 0; if (hist == "") return; RS = "\n"; while ((getline l < hist) > 0) if (l != "") H[++NH] = l; close(hist); RS = "" }
    function col(k, n,   i, s, F) { s = ""; for (i = (NH > n) ? NH - n + 1 : 1; i <= NH; i++) { split(H[i], F, " "); s = s " " F[k] } return substr(s, 2) }
    function colmax(k, n, floor,   i, F, mx) { mx = floor; for (i = (NH > n) ? NH - n + 1 : 1; i <= NH; i++) { split(H[i], F, " "); if (F[k] != "-" && F[k] + 0 > mx) mx = F[k] + 0 } return mx }
    # ---------- élément de barre ----------
    # stack : étiquette (Helvetica-Bold 8, discrète) empilée sur la valeur (Menlo 11), calées à droite sur x
    function stack(x, lab, v) { pdf_rtext(x, 8, 2, 8, bar, "label", lab, 0.32); pdf_rtext(x, 19, 1, 11, bar, "fg", v, 0) }
    function track_disc(cx, cy, r, app) { pdf_push(); pdf_alpha((app == "dark") ? 22 : 18); pdf_fill(app, "ink"); pdf_disc(cx, cy, r); pdf_pop() }
    function track_rect(x, y, w, h, app) { pdf_push(); pdf_alpha((app == "dark") ? 22 : 18); pdf_fill(app, "ink"); pdf_rect(x, y, w, h); pdf_pop() }
    function bar_out(tip) { BAR = "| image=" pdf_end() " tooltip=\"" tip "\" ansi=false" }
    # bars6(x0, k, color) : 6 barres de la dernière minute (colonne k de l historique), les plus récentes à droite
    function bars6(x0, k, color,   V, n, i, h) {
      n = split(col(k, bp), V, " "); track_rect(x0, 18.5, 23, 0.5, bar); pdf_fill(bar, color)
      for (i = 1; i <= n; i++) { if (V[i] == "-") continue; h = V[i] / 100 * 15; if (h < 1) h = 1; pdf_rect(x0 + (bp - n + i - 1) * 4, 18.5 - h, 3, h) }
    }
    # ---------- menu ----------
    # graph(k, max, color, pie, pct, pcolor) : image du menu, 266 × 56 pt — courbe de 10 min, camembert à gauche si pie
    # legend : « −10 min », la légende, « maintenant » sous la courbe (x, w), en Menlo 10 discret, dans l image ; une légende trop
    # longue pour tenir entre les deux repères passe sur une deuxième ligne (GH = 82 au lieu de 70)
    function legend(x, w, mid) {
      pdf_text(x, 67, 1, 10, menu, "mute", "−10 min", 0); pdf_rtext(x + w, 67, 1, 10, menu, "mute", t("now"), 0)
      if (mid == "") return
      if (GH > 70) pdf_text(x, 79, 1, 10, menu, "mute", mid, 0)
      else pdf_text(x + (w - pdf_tw(mid, 1, 10, 0)) / 2, 67, 1, 10, menu, "mute", mid, 0)
    }
    function graph(k, max, color, pie, pct, pcolor, k2, color2, mid,   x, w) {
      x = (pie) ? 66 : 0; w = 266 - x
      GH = (mid != "" && pdf_tw(mid, 1, 10, 0) + pdf_tw("−10 min", 1, 10, 0) + pdf_tw(t("now"), 1, 10, 0) + 16 > w) ? 82 : 70
      pdf_begin(266, GH); x = 0; w = 266
      if (pie) { track_disc(28, 28, 26.25, menu); pdf_fill(menu, pcolor); pdf_wedge(28, 28, 26.25, pct); x = 66; w = 200 }
      pdf_push(); pdf_alpha(12); pdf_fill(menu, "ink"); pdf_rrect(x, 0, w, 56, 3, "f"); pdf_pop()
      pdf_series(x, 0, w, 56, col(k, 60), (NH > 60) ? 60 : NH, max, menu, color, 1)
      if (k2) pdf_series(x, 0, w, 56, col(k2, 60), (NH > 60) ? 60 : NH, max, menu, color2, 0)
      legend(x, w, mid)
      # taille explicite : sans elle, SwiftBar 2.1.1 réduit l image d un menu à la hauteur d une ligne (vrai poste, 2026-10-24)
      line("| image=" pdf_end() " width=266 height=" GH)
    }
    $1 == "BLOCK=CPU" { for (i = 1; i <= NF; i++) { k = $i; sub(/=.*/, "", k); C[k] = val(k) } next }
    $1 == "BLOCK=MEM" { for (i = 1; i <= NF; i++) { k = $i; sub(/=.*/, "", k); MM[k] = val(k) } next }
    $1 == "BLOCK=DISK" { for (i = 1; i <= NF; i++) { k = $i; sub(/=.*/, "", k); D[k] = val(k) } next }
    $1 == "BLOCK=NET" { for (i = 1; i <= NF; i++) { k = $i; sub(/=.*/, "", k); N[k] = val(k) } next }
    $1 == "BLOCK=BATTERY" { for (i = 1; i <= NF; i++) { k = $i; sub(/=.*/, "", k); B[k] = val(k) } next }
    $1 == "BLOCK=TEMP" { for (i = 1; i <= NF; i++) { k = $i; sub(/=.*/, "", k); T[k] = val(k) } TEMP = 1; next }
    $1 == "BLOCK=PROC" {
      kind = val("KIND"); w = val("NAME") ((val("WHERE") == "") ? "" : " " val("WHERE")); l = sprintf("%-5s ", val("PID")) w
      if (kind == "cpu") { PCL[++ncpu] = l; PCV[ncpu] = pc(dec(val("CPU"), 1)); PCT[ncpu] = val("PID") " " w } else { PML[++nmem] = l; PMV[nmem] = gb(val("MEM_MB")); PMT[nmem] = val("PID") " " w }
      next
    }
    END {
      load_hist(); SW = 4 * 0.602 * 11   # largeur de « 100% » en Menlo 11 : la pile garde sa place, la barre ne bouge pas
      if (m == "cpu") {
        u = C["USAGE_PCT"]; lv = lvl_cpu(u)
        pdf_begin(54, 22); stack(SW, "CPU", (u == "") ? "?" : u "%"); bars6(SW + 4, 2, lv); bar_out("CPU " ((u == "") ? "?" : u "%"))
        title(t("cpu_t")); graph(2, 100, lv)
        row(t("usage"), (u == "") ? "?" : pc(u))
        if (C["SOURCE"] == "macmon") { row(t("cores"), pc(C["E_PCT"]) " / " pc(C["P_PCT"])); row("GPU", pc(C["GPU_PCT"])); row(t("power"), dec(C["POWER_W"], 1) " W") }
        row(t("load"), dec(C["LOAD_1"], 2))
        chip = C["CHIP"]; sub(/^Apple /, "", chip); row(t("chip"), chip ((chip == "") ? "" : " · ") C["CORES"] " " t("ncores"))
        sep(); title(t("top")); for (i = 1; i <= ncpu; i++) row(PCL[i], PCV[i], PCT[i])
      } else if (m == "mem") {
        u = MM["USED_PCT"]; lv = lvl_mem(MM["PRESSURE"])
        pdf_begin(47, 22); track_disc(8, 11, 7.5, bar); pdf_fill(bar, lv); pdf_wedge(8, 11, 7.5, u + 0); stack(20 + SW, t("mem_l"), (u == "") ? "?" : u "%")
        bar_out(t("mem_l") " " ((u == "") ? "?" : u "%") " · " t("pressure_l") " " ((MM["PRESSURE"] in FR) ? t(MM["PRESSURE"]) : t("unknown")))
        title(t("mem_t")); graph(3, 100, lv, 1, u + 0, lv)
        row(t("used_f"), dec(MM["USED_MB"] / 1024, 1) " / " gb(MM["TOTAL_MB"]))
        row(t("pressure"), (MM["PRESSURE"] in FR) ? t(MM["PRESSURE"]) : t("unknown"))
        row(t("apps"), gb(MM["APP_MB"])); row(t("wired"), gb(MM["WIRED_MB"])); row(t("comp"), gb(MM["COMPRESSED_MB"]))
        row(t("swap"), dec(MM["SWAP_USED_MB"] / 1024, 1) " / " gb(MM["SWAP_TOTAL_MB"]))
        sep(); title(t("topm")); for (i = 1; i <= nmem; i++) row(PML[i], PMV[i], PMT[i])
      } else if (m == "disk") {
        u = D["USED_PCT"]; lv = lvl_disk(u)
        pdf_begin(47, 22); track_disc(8, 11, 7.5, bar); pdf_fill(bar, lv); pdf_wedge(8, 11, 7.5, u + 0); stack(20 + SW, "SSD", (u == "") ? "?" : u "%")
        bar_out("SSD " ((u == "") ? "?" : u "%"))
        title(((D["VOLUME"] == "") ? "?" : D["VOLUME"]) " · " t("disk_t")); graph(5, colmax(5, 60, 1), lv, 1, u + 0, lv, "", "", t("M") "/s")
        row(t("used"), gbi(D["USED_MB"]) " · " pc(u)); row(t("free"), gbi(D["FREE_MB"])); row(t("total"), gbi(D["TOTAL_MB"]))
        row(t("activity"), dec(D["IO_MBS"], 1) " " t("M") "/s"); row(t("ops"), thou(D["IO_TPS"] + 0.5) " op/s")
      } else if (m == "net") {
        pdf_begin(80, 22); mx = colmax(6, bp, 10240); mx = colmax(7, bp, mx)
        track_rect(0, 10.75, 23, 0.5, bar)
        n = split(col(7, bp), V, " "); pdf_fill(bar, "up")
        for (i = 1; i <= n; i++) if (V[i] != "-") { h = V[i] / mx * 7.5; if (h < 0.5) h = 0.5; pdf_rect((bp - n + i - 1) * 4, 10.75 - h, 3, h) }
        n = split(col(6, bp), V, " "); pdf_fill(bar, "down")
        for (i = 1; i <= n; i++) if (V[i] != "-") { h = V[i] / mx * 7.5; if (h < 0.5) h = 0.5; pdf_rect((bp - n + i - 1) * 4, 11.25, 3, h) }
        pdf_rtext(72, 9, 1, 9.5, bar, "fg", rate(N["UP_BPS"]), 0); pdf_rtext(72, 19, 1, 9.5, bar, "fg", rate(N["DOWN_BPS"]), 0)
        pdf_fill(bar, "fg"); pdf_arrow(74, 2, 5, 7, 1); pdf_arrow(74, 12, 5, 7, -1)
        bar_out("↑ " rate(N["UP_BPS"]) " ↓ " rate(N["DOWN_BPS"]))
        title(t("net_t") " · " ((N["IFACE"] == "") ? "?" : N["IFACE"]) " · 10 min")
        nx = colmax(6, 60, 10240); nx = colmax(7, 60, nx); graph(6, nx, "down", 0, 0, "", 7, "up", t("lg_net"))
        row(t("rx"), rate(N["DOWN_BPS"])); row(t("tx"), rate(N["UP_BPS"]))
        row(t("rxt"), gb(N["DOWN_TOTAL_MB"])); row(t("txt"), gb(N["UP_TOTAL_MB"])); row(t("iface"), (N["IFACE"] == "") ? "?" : N["IFACE"])
      } else if (m == "battery") {
        has = (B["PRESENT"] == "yes"); p = B["PERCENT"] + 0; lv = lvl_batt(p)
        pdf_begin(58, 22); pdf_push(); pdf_stroke(bar, "mute"); PC = PC "1 w\n"; pdf_rrect(0.5, 5.5, 21, 11, 3, "S"); pdf_pop()
        pdf_fill(bar, "mute"); pdf_rrect(22.5, 9, 1.8, 4, 0.9, "f")
        if (has) { pdf_fill(bar, lv); if (p > 0) pdf_rrect(2, 7, 18 * p / 100, 8, 1.6, "f") }
        pdf_rtext(25 + 4 + 4 * 0.602 * 12, 15.5, 1, 12, bar, "fg", has ? p "%" : "—", 0); bar_out(t("bat_t") " " (has ? p "%" : "—"))
        title(t("bat_t"))
        if (!has) line(t("nobat"))
        else {
          pdf_begin(58, 28); pdf_push(); pdf_stroke(menu, "mute"); PC = PC "1.5 w\n"; pdf_rrect(1, 1, 50, 26, 6, "S"); pdf_pop()
          pdf_fill(menu, "mute"); pdf_rrect(53, 9, 3.5, 10, 1.7, "f"); pdf_fill(menu, lv); if (p > 0) pdf_rrect(4, 4, 44 * p / 100, 20, 3.5, "f")
          line(pc(p) " | image=" pdf_end() " width=58 height=28 refresh=true font=Menlo size=20")
          # « 0:00 remaining » de pmset (chargée, sur secteur, ou temps en calcul) n est pas un temps restant
          bt = (B["TIME"] == "0:00") ? "" : B["TIME"]
          st = B["STATE"]; stt = (st == "discharging" || st == "charging" || st == "charged" || st == "ac") ? t(st) : t("bunknown")
          if (bt != "") line(stt " · " bt " " t("left") " | refresh=true size=11")
          row(t("state"), stt); row(t("remaining"), (bt == "") ? "—" : bt); row(t("cycles"), thou(B["CYCLES"]))
          row(t("health"), (B["HEALTH_PCT"] == "") ? "?" : pc(B["HEALTH_PCT"]))
          if (B["TEMP_C"] != "") row(t("temperature"), dec(B["TEMP_C"], 1) " °C")
          sep(); title(t("charge_t")); graph(8, 100, "mute")
        }
      } else if (m == "temp") {
        ct = T["CPU_C"]
        pdf_begin(27, 22); stack(SW, "CPU", (!TEMP || ct == "") ? "—" : int(ct + 0.5) "°"); bar_out("CPU " ((!TEMP || ct == "") ? "—" : int(ct + 0.5) "°C"))
        title(t("temp_t"))
        if (!TEMP) line(t("needmac") macmonbrew)
        else {
          graph(9, 100, "mute", 0, 0, "", 0, "", t("lg_temp"))
          row("CPU", dec(ct, 0) " °C"); row("GPU", dec(T["GPU_C"], 0) " °C")
          if (B["TEMP_C"] != "") row(t("bat_t"), dec(B["TEMP_C"], 1) " °C")
          for (i = 1; i <= T["FANS"] + 0 && i <= 2; i++) row(t("fan") " " i, thou(T["FAN" i "_RPM"]) " " t("rpm"))
        }
      }
      print BAR
      print "---"
      printf "%s", body
      print "---"
      print t("refresh") " | refresh=true"
    }'
}

# widget_sysmon_dir → dossier du cache des modules (blocs collectés + un fichier pré-rendu par module)
widget_sysmon_dir() { printf '%s/sysmon\n' "$(widget_state)"; }
# widget_modules_file → la liste des modules actifs (un par ligne) ; absente = tous actifs (état posé par install)
widget_modules_file() { printf '%s/modules\n' "$(widget_state)"; }
# widget_modules_enabled → les modules actifs, dans l ordre canonique de WIDGET_MODULES
# widget_modules_all → la liste complète des modules, un par ligne (ordre canonique)
# shellcheck disable=SC2086 # WIDGET_MODULES est une liste contrôlée, séparée par des espaces : le découpage est voulu
widget_modules_all() { printf '%s\n' $WIDGET_MODULES; }
widget_modules_enabled() {
  local f m; f="$(widget_modules_file)"
  if [ ! -f "$f" ]; then widget_modules_all; return; fi
  for m in $(widget_modules_all); do grep -qxF "$m" "$f" && printf '%s\n' "$m"; done
}
widget_module_known() { case " $WIDGET_MODULES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# Apparences. Barre (lot 06) : une seule palette sombre — macOS 26 dessine la barre transparente, son texte suit le fond d'écran, et
# le fond d'écran foncé est gardé (décision du grill-me) ; la sonde d'apparence du lot 05 est retirée. Menus : l'apparence du
# système (OS_APPEARANCE, que SwiftBar passe aux greffons). LAB_WIDGET_BAR / LAB_WIDGET_MENU imposent (tests, captures).
WIDGET_CACHE_TTL=5   # minutes : langue du Mac gardée en cache par le collecteur
# widget_menu_appearance → light|dark : celle du système
widget_menu_appearance() {
  [ -z "${LAB_WIDGET_MENU:-}" ] || { printf '%s\n' "$LAB_WIDGET_MENU"; return; }
  case "${OS_APPEARANCE:-}" in
    Dark) echo dark ;; Light) echo light ;;
    *) if [ "$(defaults read -g AppleInterfaceStyle 2>/dev/null)" = Dark ]; then echo dark; else echo light; fi ;;
  esac
}
# widget_bar_appearance → dark (palette unique), sauf LAB_WIDGET_BAR posé
widget_bar_appearance() { printf '%s\n' "${LAB_WIDGET_BAR:-dark}"; }

# widget_lang → fr|en… : la langue des menus, celle du Mac (lab_lang_detect) gardée WIDGET_CACHE_TTL minutes — sa lecture par defaults
# coûte ≈ 0,02 s, payée une fois par fenêtre et non à chaque passe (budget C6) ; LAB_LANG posé l'emporte sans cache
widget_lang() {
  local f l
  [ -z "${LAB_LANG:-}" ] || { lab_lang_detect; return; }
  f="$(widget_sysmon_dir)/lang"
  if [ -n "$(find "$f" -mmin "-$WIDGET_CACHE_TTL" 2>/dev/null)" ] && l="$(cat "$f" 2>/dev/null)" && [ -n "$l" ]; then printf '%s\n' "$l"; return; fi
  l="$(lab_lang_detect)"; printf '%s\n' "$l" >"$f" 2>/dev/null || true
  printf '%s\n' "$l"
}

# widget_collect : une passe de collecte, son point dans l'historique (10 min), puis un fichier SwiftBar pré-rendu par module actif
# (écritures atomiques). Appelé une fois par cycle par le greffon qui tient le verrou ; les cinq autres lisent le cache. Toujours
# rc 0 (une passe en échec laisse le cache précédent). Un seul lab par cycle (budget mesuré, rapport de preuves).
widget_collect() {
  local dir blocks m
  . "$LAB_ROOT/lib/top.sh"; . "$LAB_ROOT/lib/sysmon.sh"
  dir="$(widget_sysmon_dir)"; mkdir -p "$dir" || return 0
  blocks="$(sysmon_collect 2>/dev/null)" || blocks=""
  [ -n "$blocks" ] || return 0
  printf '%s\n' "$blocks" >"$dir/.blocks.$$" && mv "$dir/.blocks.$$" "$dir/blocks"
  sysmon_history_push "$dir/history" "$blocks" 2>/dev/null || true
  WIDGET_LANG="$(widget_lang)"; WIDGET_BAR="$(widget_bar_appearance)"; WIDGET_MENU="$(widget_menu_appearance)"
  for m in $(widget_modules_enabled); do
    widget_module_render "$m" "$blocks" "$dir/history" >"$dir/.module-$m.$$" 2>/dev/null && mv "$dir/.module-$m.$$" "$dir/module-$m.txt"
  done
}

# widget_render_module <module> : le texte SwiftBar d un module, collecte fraîche à l appui, historique lu sans être écrit. Pour
# l inspection et les tests ; les greffons posés passent par le cache (widget_collect).
widget_render_module() {
  local blocks
  widget_module_known "$1" || usage
  . "$LAB_ROOT/lib/top.sh"; . "$LAB_ROOT/lib/sysmon.sh"
  blocks="$(sysmon_collect 2>/dev/null)" || blocks=""
  WIDGET_LANG="$(lab_lang_detect)"; WIDGET_BAR="$(widget_bar_appearance)"; WIDGET_MENU="$(widget_menu_appearance)"
  widget_module_render "$1" "$blocks" "$(widget_sysmon_dir)/history"
}

# widget_modules list|on <m>|off <m> : les modules de barre actifs, persistés dans widget_modules_file. off retire l élément (son
# greffon est retiré si la barre est posée), on le remet ; l ordre d affichage reste celui de WIDGET_MODULES.
widget_modules() {
  local action="${1:-list}" m f state
  f="$(widget_modules_file)"; state="$(widget_state)"
  case "$action" in
    list) : ;;
    on|off)
      [ "$#" -eq 2 ] || usage; m="$2"; widget_module_known "$m" || usage
      mkdir -p "$state"
      [ -f "$f" ] || widget_modules_all >"$f"
      if [ "$action" = off ]; then
        # retirer le dernier module laisse une liste vide : grep ne trouve plus rien (rc 1), || true l'absorbe, le mv reste fait
        { grep -vxF "$m" "$f" || true; } >"$f.tmp"; mv "$f.tmp" "$f"
        widget_module_plugin_remove "$m"
      else
        grep -qxF "$m" "$f" || printf '%s\n' "$m" >>"$f"
        widget_module_plugin_write "$m" 2>/dev/null || true
      fi ;;
    *) usage ;;
  esac
  kv MODULES "$(widget_modules_enabled | paste -sd, -)"
}

# ---------- act ----------
# widget_notify <titre> <texte> : notification macOS courte, texte passé en argument (jamais interprété par AppleScript) ; rc 1
# si macOS la refuse
widget_notify() {
  osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' "$1" "$2" >/dev/null 2>&1
}
# widget_act top --cut|--wake|--explain <cible> : les mots exacts d'une ACTION ou d'un EXPLAIN de lab top ; le geste est lancé
# sans shell, son résultat notifié et gardé pour le prochain rendu, son code relayé.
widget_act() {
  local out rc=0 msg title res state
  case "${1:-}" in sep|order|tidy) widget_act_bar "$@"; return ;; esac
  [ "$#" -eq 3 ] && [ "$1" = top ] || usage
  case "$2" in --cut|--wake|--explain) ;; *) usage ;; esac
  title="lab top $2 $3"
  out="$("$LAB_ROOT/bin/lab" top "$2" "$3" 2>/dev/null)" || rc=$?
  msg="$(printf '%s\n' "$out" | awk 'BEGIN { RS = ""; FS = "\n" }
    function val(k,   i) { for (i = 1; i <= NF; i++) if (index($i, k "=") == 1) return substr($i, length(k) + 2); return "" }
    function size(m) { m += 0; return (m >= 1024) ? sprintf("%.1fG", m / 1024) : int(m) "M" }
    $1 == "BLOCK=RESULT" { n++; a = val("ACTION"); if (a == "refused") { nr++; if (!r) r = "refused (" val("REFUSAL") "): " val("DETAIL") }
      else { nd++; if (!d) d = a ((val("TARGET") != "") ? " " val("TARGET") : "") ": " val("DETAIL") } }
    $1 == "BLOCK=TOTAL" { tf = val("FREED") }
    END {
      if (!n) { print "no result: lab top gave nothing to read"; exit }
      if (n == 1) { s = nd ? d : r } else s = "done " nd + 0 ", refused " nr + 0 " of " n
      if (tf != "" && tf != "0") s = s "; frees about " size(tf)
      print s
    }')"
  state="$(widget_state)"; mkdir -p "$state"; printf '%s: %s\n' "$title" "$msg" >"$state/last"
  res=yes; widget_notify "$title" "$msg" || res=no
  kv WIDGET_ACT "$2 $3"; kv RC "$rc"; kv NOTIFIED "$res"; kv MESSAGE "$msg"
  [ "$res" = yes ] || warn "macOS refused the notification: the result stays at the top of the menu (Last click)"
  return "$rc"
}

# widget_act_bar sep show|hide | order save|apply | order stow <nom> | tidy spacing|duplicates|istat : les clics du séparateur (lot
# 06). Le clic vaut confirmation : apply et stow relancent (--relaunch), tidy agit (--confirm) ; le menu a d'abord dit ce que le geste
# implique. Même retour que act top : notification, rappel en tête du menu, code relayé.
widget_act_bar() {
  local out rc=0 msg title res state
  case "$1:${2:-}:$#" in
    sep:show:2|sep:hide:2|order:save:2) set -- "$@" ;;
    order:apply:2) set -- order apply --relaunch ;;
    order:stow:3) set -- order stow "$3" --relaunch ;;
    tidy:spacing:2|tidy:duplicates:2|tidy:istat:2) set -- tidy --confirm "$2" ;;
    *) usage ;;
  esac
  title="lab widget $*"
  out="$("$LAB_ROOT/bin/lab" widget "$@" 2>"$(widget_state)/.act-err.$$")" || rc=$?
  msg="$(printf '%s\n' "$out" | sed -n 's/^MESSAGE=//p' | head -1)"
  [ -n "$msg" ] || msg="failed: $(tail -1 "$(widget_state)/.act-err.$$" 2>/dev/null | sed -E -e "s/^$DIE_READ//" -e 's/^lab: //')"
  rm -f "$(widget_state)/.act-err.$$"
  state="$(widget_state)"; mkdir -p "$state"; printf '%s: %s\n' "$title" "$msg" >"$state/last"
  res=yes; widget_notify "$title" "$msg" || res=no
  kv WIDGET_ACT "$*"; kv RC "$rc"; kv NOTIFIED "$res"; kv MESSAGE "$msg"
  return "$rc"
}

# ---------- install / remove ----------
# widget_brew → chemin de brew, vide s'il manque. LAB_BREW impose (tests) ; posé mais non exécutable = brew absent.
widget_brew() {
  if [ "${LAB_BREW+set}" = set ]; then [ -x "$LAB_BREW" ] && printf '%s\n' "$LAB_BREW"; return 0; fi
  command -v brew 2>/dev/null || true
}
# widget_module_plugin_name <module> → nom de fichier SwiftBar du module (rafraîchi toutes les 10 s)
widget_module_plugin_name() { printf 'lab-%s.10s.sh\n' "$1"; }
# widget_module_position <module> → position mémorisée (distance au bord droit) ; les modules groupés juste à droite de la pastille,
# dans l'ordre de WIDGET_MODULES : le dernier à WIDGET_POSITION_BASE, chacun des autres au bord gauche de son voisin de droite
widget_module_position() {
  printf '%s\n' "$WIDGET_MODULE_WIDTHS" | awk -v m="$1" -v base="$WIDGET_POSITION_BASE" -v order="$WIDGET_MODULES" '
    { n = split($0, F, " "); for (i = 1; i < n; i += 2) W[F[i]] = F[i + 1]; k = split(order, O, " ")
      p = base; for (i = k; i >= 1; i--) { if (O[i] == m) { print p; exit } p += W[O[i]] } print base }'
}
# widget_plugin_ctx → écrit le contexte des greffons modules (dossier, lab, PATH, env) lu par widget_module_plugin_write, à la pose
# comme à un modules on ultérieur ; lignes KEY=value, une valeur par ligne
widget_plugin_ctx_file() { printf '%s/plugin-ctx\n' "$(widget_state)"; }
widget_plugin_ctx_get() { sed -n "s/^$1=//p" "$(widget_plugin_ctx_file)" 2>/dev/null | head -1; }

# widget_module_plugin_write <module> : écrit (ou réécrit) le greffon SwiftBar d'un module dans le dossier posé, en bash pur — il
# ne relance lab que pour collecter, sous un verrou (un seul lab par cycle, le budget mesuré l'exige), et lit sinon le cache
# pré-rendu. Pose aussi sa position si l'utilisateur ne l'a pas déjà choisie. Sans contexte posé (barre non installée) : ne fait rien.
widget_module_plugin_write() {
  local m="$1" dir lab env path sysdir plugin ttl posk pos
  dir="$(widget_plugin_ctx_get dir)"; [ -n "$dir" ] && [ -d "$dir" ] || return 0
  lab="$(widget_plugin_ctx_get lab)"; env="$(widget_plugin_ctx_get env)"; path="$(widget_plugin_ctx_get path)"
  sysdir="$(widget_sysmon_dir)"; ttl="$WIDGET_SYSMON_TTL"
  plugin="$dir/$(widget_module_plugin_name "$m")"
  mkdir -p "$sysdir" 2>/dev/null || true
  # shellcheck disable=SC2016 # corps du greffon généré : $D, $blk, $TTL… doivent rester littéraux (développés à l'exécution du greffon)
  {
    printf '#!/bin/bash\n# Treelab system module (%s), written by lab widget install; lab widget remove takes it away.\n' "$m"
    printf '# <swiftbar.hideAbout>true</swiftbar.hideAbout>\n# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>\n'
    printf '# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>\n# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>\n'
    printf 'export PATH=%s\n' "$(shell_quote "$path")"
    printf 'D=%s; M=%s; TTL=%s; f="$D/module-$M.txt"; blk="$D/blocks"; now=$(date +%%s)\n' "$(shell_quote "$sysdir")" "$(shell_quote "$m")" "$ttl"
    # un seul collecteur par cycle : le premier greffon dont le cache est périmé prend le verrou et lance « lab widget collect » ;
    # les autres attendent qu'il finisse (≤ 2 s) puis lisent le cache ; un verrou bloqué plus de 30 s est volé
    printf 'need=1; if [ -f "$blk" ]; then a=$(( now - $(stat -f %%m "$blk" 2>/dev/null || echo 0) )); [ "$a" -ge "$TTL" ] || need=0; fi\n'
    printf 'if [ "$need" = 1 ]; then got=0\n'
    printf '  if mkdir "$D/lock" 2>/dev/null; then got=1\n'
    printf '  else la=$(( now - $(stat -f %%m "$D/lock" 2>/dev/null || echo "$now") )); [ "$la" -lt 30 ] || { rmdir "$D/lock" 2>/dev/null || true; mkdir "$D/lock" 2>/dev/null && got=1; }\n  fi\n'
    printf '  if [ "$got" = 1 ]; then env %s %s widget collect >/dev/null 2>&1 || true; rmdir "$D/lock" 2>/dev/null || true\n' "$env" "$(shell_quote "$lab")"
    printf '  else i=0; while [ -d "$D/lock" ] && [ "$i" -lt 20 ]; do sleep 0.1; i=$((i + 1)); done; fi\nfi\n'
    printf 'cat "$f" 2>/dev/null || printf "%%s … | ansi=false\\n" "$M"\n'
  } >"$plugin.tmp" || return 0
  if ! chmod 755 "$plugin.tmp" || ! mv "$plugin.tmp" "$plugin"; then rm -f "$plugin.tmp"; return 0; fi
  posk="$(widget_position_key "$plugin")"; pos="$(widget_module_position "$m")"
  if ! defaults read "$WIDGET_DOMAIN" "$posk" >/dev/null 2>&1; then
    defaults write "$WIDGET_DOMAIN" "$posk" -float "$pos" >/dev/null 2>&1 && printf '%s\n' "$plugin" >>"$(widget_state)/module-positions"
  fi
}
# widget_module_plugin_remove <module> : retire le greffon d'un module (s'il est de lab) et la position que lab avait posée
widget_module_plugin_remove() {
  local m="$1" dir plugin
  dir="$(widget_plugin_ctx_get dir)"; [ -n "$dir" ] || return 0
  plugin="$dir/$(widget_module_plugin_name "$m")"
  [ ! -f "$plugin" ] || ! grep -q 'Treelab system module' "$plugin" || rm -f "$plugin"
  if [ -f "$(widget_state)/module-positions" ] && grep -qxF "$plugin" "$(widget_state)/module-positions" 2>/dev/null; then
    defaults delete "$WIDGET_DOMAIN" "$(widget_position_key "$plugin")" >/dev/null 2>&1 || true
    grep -vxF "$plugin" "$(widget_state)/module-positions" >"$(widget_state)/module-positions.tmp" 2>/dev/null || true
    mv "$(widget_state)/module-positions.tmp" "$(widget_state)/module-positions" 2>/dev/null || true
  fi
}

# widget_login_has → rc 0 si SwiftBar ouvre déjà à la connexion (élément d'ouverture de System Events)
widget_login_has() {
  local names
  names="$(osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null)" || return 2
  case ", $names, " in *", SwiftBar, "*) return 0 ;; *) return 1 ;; esac
}
widget_install() {
  local app dir src lab plugin state login position env v macmon brew m sep
  . "$LAB_ROOT/lib/sysmon.sh"   # macmon_bin pour la pose de macmon
  app="$(widget_app)"
  if [ -z "$app" ]; then
    kv WIDGET missing; kv INSTALL_COMMAND "$WIDGET_BREW"
    die "SwiftBar is not installed: run $WIDGET_BREW, then lab widget install again (lab never installs it)"
  fi
  state="$(widget_state)"
  dir="$(defaults read "$WIDGET_DOMAIN" PluginDirectory 2>/dev/null)" || dir=""
  if [ -n "$dir" ]; then src=swiftbar; else src=lab; dir="$state/plugins"; fi
  mkdir -p "$dir" "$state" || die "plugin folder not writable: $dir"
  if [ "$src" = lab ]; then
    defaults write "$WIDGET_DOMAIN" PluginDirectory "$dir" || die "SwiftBar preference not written: defaults write $WIDGET_DOMAIN PluginDirectory $dir"
    : >"$state/dir-added"   # inscrit par lab : remove le retire si le dossier est vide
  fi
  lab="$(widget_lab)"; plugin="$dir/$WIDGET_PLUGIN"
  env="LAB_HOME=$(shell_quote "$LAB_HOME")"
  for v in LAB_PROJECTS_DIR LAB_STATE_DIR; do [ -z "${!v:-}" ] || env="$env $v=$(shell_quote "${!v}")"; done
  if ! {
    printf '#!/bin/bash\n# Treelab menu bar plugin, written by lab widget install; lab widget remove takes it away.\n'
    printf '# <swiftbar.hideAbout>true</swiftbar.hideAbout>\n# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>\n'
    printf '# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>\n'
    printf 'export PATH=%s\n' "$(shell_quote "$PATH")"
    printf '[ "$#" -gt 0 ] || set -- widget render   # no argument: the menu for SwiftBar; a click: its words, passed as they are\n'
    printf 'exec env %s %s "$@"\n' "$env" "$(shell_quote "$lab")"
  } >"$plugin.tmp" || ! chmod 755 "$plugin.tmp" || ! mv "$plugin.tmp" "$plugin"; then die "plugin not written: $plugin"; fi
  # position : celle que l'utilisateur a choisie (glissée) reste ; sinon près du bord droit, retirée par remove
  if defaults read "$WIDGET_DOMAIN" "$(widget_position_key "$plugin")" >/dev/null 2>&1; then position=kept
  elif defaults write "$WIDGET_DOMAIN" "$(widget_position_key "$plugin")" -float "$WIDGET_POSITION"; then position='set'; : >"$state/position-added"
  else position=refused; fi
  # l'ouverture à la connexion n'est retirée par remove que si lab l'a posée
  if widget_login_has; then login=present
  elif osascript -e 'on run argv' -e 'tell application "System Events" to make login item at end with properties {path:(item 2 of argv), hidden:true, name:(item 1 of argv)}' -e 'end run' SwiftBar "$app" >/dev/null 2>&1; then
    login=added; : >"$state/login-added"
  else login=refused; warn "SwiftBar not added to the login items (System Events refused): add it in System Settings, General, Login Items"; fi
  printf 'plugin=%s\n' "$plugin" >"$state/installed"
  # contexte des greffons modules : dossier posé, lab, PATH et env ; lus pour (ré)écrire un module, à la pose comme à un modules on
  {
    printf 'dir=%s\n' "$dir"; printf 'lab=%s\n' "$lab"; printf 'path=%s\n' "$PATH"; printf 'env=%s\n' "$env"
  } >"$(widget_plugin_ctx_file)"
  # six modules actifs par défaut (décision 2) ; une pose ultérieure respecte la liste déjà choisie
  [ -f "$(widget_modules_file)" ] || widget_modules_all >"$(widget_modules_file)"
  mkdir -p "$(widget_sysmon_dir)"
  for m in $(widget_modules_enabled); do widget_module_plugin_write "$m"; done
  # séparateur (lot 06) : juste à gauche de la pastille ; tout ce qui est à sa gauche se range derrière lui
  if menubar_sep_install "$dir" "$env" "$lab" "$PATH"; then sep=installed; else sep=failed; warn "menu bar separator not written in $dir"; fi
  # macmon pour les modules températures et puissance : lab le pose par brew s'il manque (décision 3), jamais autrement ; sans brew,
  # la commande est affichée, la pose n'est pas bloquée (modules natifs seuls) ; remove laisse macmon
  if [ -n "$(macmon_bin)" ]; then macmon=present
  else
    brew="$(widget_brew)"
    if [ -n "$brew" ]; then
      if "$brew" install macmon >/dev/null 2>&1; then macmon=installed
      else macmon=failed; warn "brew install macmon failed: temperatures and power stay hidden until macmon is installed"; fi
    else macmon=absent; kv MACMON_COMMAND "$WIDGET_MACMON_BREW"; warn "macmon not installed and brew not found: run $WIDGET_MACMON_BREW for temperatures and power (the native modules work without it)"; fi
  fi
  # SwiftBar déjà lancé : jamais « open -a », auquel 2.1.1 répond par une boîte modale « already running » qui grise tout le menu
  # (vrai poste, 2026-10-24) ; le rafraîchissement suffit
  pgrep -x SwiftBar >/dev/null 2>&1 || open -g -a "$app" >/dev/null 2>&1 || true
  open -g 'swiftbar://refreshallplugins' >/dev/null 2>&1 || true
  # posé depuis un checkout : le greffon appelle ce checkout, qui disparaît avec son couloir (lab close)
  [ -f "$LAB_ROOT/.release" ] || warn "the plugin calls the lab of a checkout ($lab): run lab widget install again with the installed lab before this checkout goes away"
  kv WIDGET installed; kv PLUGIN "$plugin"; kv PLUGIN_DIR "$dir"; kv PLUGIN_DIR_SOURCE "$src"; kv LOGIN_ITEM "$login"; kv POSITION "$position"; kv LAB "$lab"
  kv MODULES "$(widget_modules_enabled | paste -sd, -)"; kv MACMON "$macmon"; kv SEPARATOR "$sep"
  log "menu bar plugin installed: $plugin and $(widget_modules_enabled | paste -sd, -) refreshed every 10 s; lab widget remove takes them away"
}
widget_remove() {
  local state rec="" plugin="" login=kept m pdir
  state="$(widget_state)"
  # séparateur et rangement (lot 06) : greffon, sa position, espacement, doublons et iStat rétablis, état de la barre oublié
  pdir="$(widget_plugin_ctx_get dir)"; [ -n "$pdir" ] || pdir="$(defaults read "$WIDGET_DOMAIN" PluginDirectory 2>/dev/null)" || pdir=""
  menubar_remove "$pdir"
  # modules (lot 04) : les six greffons et les positions que lab avait posées sortent ; macmon et les préférences de l'utilisateur restent
  for m in $WIDGET_MODULES; do widget_module_plugin_remove "$m"; done
  local sysdir; sysdir="$(widget_sysmon_dir)"
  rm -f "$sysdir"/blocks "$sysdir"/module-*.txt "$sysdir"/.blocks.* "$sysdir"/.module-* "$sysdir"/history "$sysdir"/history.* \
    "$sysdir"/bar-appearance "$sysdir"/lang 2>/dev/null || true   # historique et caches du lot 05 (bar-appearance : pose antérieure)
  rmdir "$sysdir/lock" "$sysdir" 2>/dev/null || true
  rm -f "$(widget_plugin_ctx_file)" "$(widget_modules_file)" "$state/module-positions" "$state/net-raw"
  [ ! -f "$state/installed" ] || rec="$(sed -n 's/^plugin=//p' "$state/installed" | head -1)"
  [ -n "$rec" ] || { rec="$(defaults read "$WIDGET_DOMAIN" PluginDirectory 2>/dev/null)/$WIDGET_PLUGIN" || rec=""; }
  if [ -n "$rec" ] && [ -f "$rec" ] && grep -q 'lab widget install' "$rec"; then rm -f "$rec"; plugin="$rec"; fi
  # ce que lab a écrit dans les préférences sort avec lui, même si le fichier a déjà disparu ; jamais ce qu'avait l'utilisateur
  if [ -n "$rec" ] && [ -f "$state/position-added" ]; then defaults delete "$WIDGET_DOMAIN" "$(widget_position_key "$rec")" >/dev/null 2>&1 || true; fi
  if [ -n "$rec" ] && [ -f "$state/dir-added" ] && [ -z "$(ls -A "$(dirname "$rec")" 2>/dev/null)" ]; then
    defaults delete "$WIDGET_DOMAIN" PluginDirectory >/dev/null 2>&1 || true; rm -f "$state/dir-added"
  fi
  rm -f "$state/position-added"
  if [ -f "$state/login-added" ]; then
    if osascript -e 'on run argv' -e 'tell application "System Events" to delete login item (item 1 of argv)' -e 'end run' SwiftBar >/dev/null 2>&1; then login=removed; rm -f "$state/login-added"
    else login=refused; warn "SwiftBar login item not removed (System Events refused): remove it in System Settings, General, Login Items"; fi
  fi
  rm -f "$state/installed" "$state/last"
  open -g 'swiftbar://refreshallplugins' >/dev/null 2>&1 || true
  kv WIDGET removed; kv PLUGIN "${plugin:-none}"; kv LOGIN_ITEM "$login"
  log "menu bar plugin removed; SwiftBar and its preferences stay as they are"
}
