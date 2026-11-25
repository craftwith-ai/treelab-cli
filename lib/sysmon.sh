# shellcheck shell=bash
# sysmon.sh — lab sysmon (lot 04 du couloir tableau-de-bord) : une seule passe de collecte → six blocs KEY=value (CPU, MEM, DISK,
# NET, BATTERY, TEMP) pour les six modules SwiftBar. Un collecteur unique les alimente tous (cache dans LAB_STATE/widget/) ; chaque
# greffon ne fait que lire et formater. Mesuré sur le poste (lot 04, rapport de preuves) : une passe native coûte 0,06 s de CPU,
# macmon un échantillon 0,17 s, top_snapshot --fast 0,69 s — six macmon toutes les 10 s dépasseraient le budget, d'où le collecteur
# unique et les greffons en bash pur qui lisent le cache (un seul lab par cycle).
#
# macmon (macmon pipe, JSON) donne l'usage P/E, le GPU, la puissance, les températures et les ventilateurs ; sans lui, TEMP et la
# puissance sont absents, les autres modules restent entiers depuis les outils natifs (sysctl/vm_stat, df/iostat, netstat -ibn en
# delta, pmset -g batt + ioreg). Le JSON de macmon est lu par des motifs awk sur ses clés (uniques, même imbriquées) : aucune
# dépendance à jq ni à python3. Le top 5 des consommateurs est rattaché au projet/couloir par les verrous de lib/top.sh.

# macmon_bin → chemin de macmon, vide s'il manque. LAB_MACMON impose un chemin (tests, installation ailleurs) ; posé mais non
# exécutable = macmon absent (test « sans macmon »). Non posé : le macmon du PATH (celui que lab widget install pose par brew).
macmon_bin() { macmon_bin_set; [ -z "$MACMON_BIN" ] || printf '%s\n' "$MACMON_BIN"; }
# macmon_bin_set : MACMON_BIN, le même chemin, sans sous-shell
macmon_bin_set() {
  MACMON_BIN=""
  if [ "${LAB_MACMON+set}" = set ]; then [ ! -x "$LAB_MACMON" ] || MACMON_BIN="$LAB_MACMON"; return 0; fi
  MACMON_BIN="$(command -v macmon 2>/dev/null)" || MACMON_BIN=""
}
# sysmon_file_set <fichier> : SYSMON_FILE, son texte comme $(cat <fichier>) le rend (fins de ligne finales retirées), lu sans cat
sysmon_file_set() {
  SYSMON_FILE=""; [ -f "$1" ] || return 0
  IFS= read -r -d '' SYSMON_FILE <"$1" || :
  while [ "${SYSMON_FILE%$'\n'}" != "$SYSMON_FILE" ]; do SYSMON_FILE="${SYSMON_FILE%$'\n'}"; done
}

sysmon_state() { printf '%s/widget\n' "$LAB_STATE"; }

# sysmon_net <sortie de netstat -ibn> → « iface ibytes obytes » de l'interface active (hors lo, plus gros trafic cumulé). La colonne
# d'adresse peut manquer (lignes sans MAC) : on compte les champs à partir du jeton <Link#…> pour ne jamais lire un paquet pour un
# octet. Interfaces de service ignorées (utun, awdl, bridge… : tunnels et liens pair-à-pair, jamais le lien principal).
# shellcheck disable=SC2016 # programme awk
SYSMON_NET_AWK='
    $1 != "lo0" && $1 !~ /^(utun|awdl|llw|gif|stf|ap|p2p|bridge|anpi|en[0-9]+:)/ {
      for (i = 1; i <= NF; i++) if ($i ~ /^<Link#[0-9]+>$/) {
        j = i + 1; if ($j ~ /:/) { ib = $(j + 3); ob = $(j + 6) } else { ib = $(j + 2); ob = $(j + 5) }
        if ((ib + ob) > best && ib ~ /^[0-9]+$/ && ob ~ /^[0-9]+$/) { best = ib + ob; bi = $1; bib = ib; bob = ob }
      }
    }
    END { if (bi != "") print bi " " bib " " bob }'
sysmon_net() { LC_ALL=C awk "$SYSMON_NET_AWK" <<<"$1"; }

# sysmon_collect → les six blocs KEY=value sur stdout. macmon et iostat (chacun ~1 s de délai, ~0 CPU) tournent en parallèle
# des sondes natives ; le delta réseau se lit sur le cache de la passe précédente ($state/net-raw : « epoch iface ibytes obytes »).
# Un processus par sonde (exec dans chaque substitution, fichiers relus sans cat, uid de bash) : lot 04 de charge-processeur.
sysmon_collect() {
  local state mac now macout iostat_out sysctl_out vmstat_out df_out netstat_out batt_out ioreg_out ps_out
  local mtmp itmp netcur netiface netib netob down=0 up=0 pib="" pob="" pt="" pif="" projects layout all
  state="$LAB_STATE/widget"; [ -d "$state" ] || mkdir -p "$state" 2>/dev/null || true
  now="${LAB_NOW_EPOCH:-$(exec date +%s)}"
  macmon_bin_set; mac="$MACMON_BIN"
  mtmp="$state/.macmon.$$"; itmp="$state/.iostat.$$"
  if [ -n "$mac" ]; then "$mac" pipe --samples 1 --interval 200 --soc-info 2>/dev/null | head -1 >"$mtmp" & fi
  LC_ALL=C iostat -c 2 -w 1 2>/dev/null >"$itmp" &
  sysctl_out="$(LC_ALL=C exec sysctl hw.memsize hw.ncpu vm.swapusage vm.loadavg kern.memorystatus_vm_pressure_level kern.memorystatus_level 2>/dev/null)" || :
  vmstat_out="$(LC_ALL=C exec vm_stat 2>/dev/null)" || :
  df_out="$(LC_ALL=C exec df -k /System/Volumes/Data 2>/dev/null)" || :
  # -n : sans traduction des adresses en noms, qui attend 5 s par passe sur un vrai Mac (lot 04 de charge-processeur) ; seules les
  # lignes <Link#…>, identiques, sont lues
  netstat_out="$(LC_ALL=C exec netstat -ibn 2>/dev/null)" || :
  batt_out="$(LC_ALL=C exec pmset -g batt 2>/dev/null)" || :
  ioreg_out="$(LC_ALL=C exec ioreg -r -c AppleSmartBattery 2>/dev/null)" || :
  # même format que lib/top.sh : ps_parse attend pid, ppid, uid, stat, rss, %cpu, etime, args (stat et etime inutilisés ici mais
  # exigés par le motif de ps_parse) ; sous une locale C, ps écrit les octets non ASCII en M-… — UTF-8 garde les dossiers accentués
  ps_out="$(LC_ALL=en_US.UTF-8 exec ps -axww -o pid=,ppid=,uid=,stat=,rss=,%cpu=,etime=,args= 2>/dev/null)" || :
  wait
  macout=""; [ -z "$mac" ] || { sysmon_file_set "$mtmp"; macout="$SYSMON_FILE"; }
  sysmon_file_set "$itmp"; iostat_out="$SYSMON_FILE"; rm -f "$mtmp" "$itmp"
  # delta réseau : octets de l'interface active moins ceux de la passe précédente, par seconde ; compteur remis à zéro (reboot,
  # changement d'interface) → débit 0, la passe sert de nouvelle base
  netcur="$(LC_ALL=C exec awk "$SYSMON_NET_AWK" <<<"$netstat_out")"; netiface="${netcur%% *}"; netib="${netcur#* }"; netib="${netib%% *}"; netob="${netcur##* }"
  if [ -f "$state/net-raw" ]; then read -r pt pif pib pob <"$state/net-raw" 2>/dev/null || true; fi
  if [ -n "$netiface" ] && [ "$pif" = "$netiface" ] && [ -n "$pt" ] && [ "$now" -gt "$pt" ] 2>/dev/null \
     && [ "$netib" -ge "$pib" ] 2>/dev/null && [ "$netob" -ge "$pob" ] 2>/dev/null; then
    down=$(( (netib - pib) / (now - pt) )); up=$(( (netob - pob) / (now - pt) ))
  fi
  [ -z "$netiface" ] || printf '%s %s %s %s\n' "$now" "$netiface" "$netib" "$netob" >"$state/net-raw"
  # projets et verrous (lecture légère, sans lsof) : rattachent les sessions d'agent du top 5 à leur couloir
  projects="$(top_projects)"; layout="$(top_layout "$projects")"
  # les sections en une chaîne (printf -v), lue par awk sans tuyau ; le uid de bash, comme id -u
  printf -v all '#MAC\n%s\n#Y\n%s\n#V\n%s\n#D\n%s\n#IO\n%s\n#NETD\n%s %s %s %s %s\n#BT\n%s\n#BR\n%s\n%s\n#S\n%s' "$macout" \
    "$sysctl_out" "$vmstat_out" "$df_out" "$iostat_out" "$netiface" "$down" "$up" "$netib" "$netob" "$batt_out" "$ioreg_out" "$layout" "$ps_out"
  LC_ALL=C awk -v self="${LAB_SELF:-$$}" -v uid="$UID" "$TOP_AWK_LIB"'
    function mb(x) { return int(x + 0.5) }
    function pct(x) { x += 0; return (x < 0) ? 0 : (x > 100) ? 100 : int(x + 0.5) }
    # jnum(clé) : le nombre qui suit "clé": dans le JSON de macmon (clé unique, imbriquée ou non) ; "" si absente
    function jnum(k,   s) { if (match(J, "\"" k "\": *-?[0-9][0-9.eE+-]*")) { s = substr(J, RSTART, RLENGTH); sub(/^[^:]*: */, "", s); return s + 0 } return "" }
    # jarr2(cle) : le second nombre de "cle":[a,b] (le ratio d usage P/E/GPU) ; "" si absente
    function jarr2(k,   s) { if (match(J, "\"" k "\": *\\[ *[0-9.]+, *[0-9.eE+-]+ *\\]")) { s = substr(J, RSTART, RLENGTH); sub(/.*, */, "", s); sub(/ *\].*/, "", s); return s + 0 } return "" }
    function jarr1(k,   s) { if (match(J, "\"" k "\": *\\[ *[0-9.]+")) { s = substr(J, RSTART, RLENGTH); sub(/.*\[ */, "", s); return s + 0 } return "" }
    function jstr(k,   s) { if (match(J, "\"" k "\": *\"[^\"]*\"")) { s = substr(J, RSTART, RLENGTH); sub(/^[^:]*: *"/, "", s); sub(/"$/, "", s); return s } return "" }
    /^#[A-Z]+$/ { sec = substr($0, 2); next }
    sec == "MAC" { if ($0 ~ /^\{/) J = $0; next }
    sec == "Y" { k = $0; sub(/:.*/, "", k); v = $0; sub(/^[^:]*:[ \t]*/, "", v); SY[k] = v; next }
    sec == "V" {
      if (match($0, /page size of [0-9]+/)) page = substr($0, RSTART + 13, RLENGTH - 13)
      v = $0; sub(/^.*:[ \t]*/, "", v); sub(/\.$/, "", v)
      if ($0 ~ /^Pages free:/) p_free = v; else if ($0 ~ /^Pages active:/) p_active = v
      else if ($0 ~ /^Pages inactive:/) p_inact = v; else if ($0 ~ /^Pages speculative:/) p_spec = v
      else if ($0 ~ /^Pages wired down:/) p_wired = v; else if ($0 ~ /^Pages purgeable:/) p_purge = v
      else if ($0 ~ /^Anonymous pages:/) p_anon = v
      else if ($0 ~ /^Pages stored in compressor:/) p_stored = v; else if ($0 ~ /^Pages occupied by compressor:/) p_occ = v
      next
    }
    sec == "D" { if ($0 ~ /^\/dev\//) { d_total = $2; d_used = $3; d_avail = $4; d_mount = $NF }; next }
    sec == "IO" { if ($0 ~ /^[ \t]*[0-9]/) { io_mbs = $3; io_tps = $2; io_id = $(NF - 3) }; next }  # dernière ligne = intervalle récent
    sec == "NETD" { n_iface = $1; n_down = $2; n_up = $3; n_ib = $4; n_ob = $5; next }
    sec == "BT" {
      if (match($0, /[0-9]+%/)) b_pct = substr($0, RSTART, RLENGTH - 1) + 0
      if ($0 ~ /charging/ && $0 !~ /discharging/) b_state = "charging"
      else if ($0 ~ /discharging/) b_state = "discharging"
      else if ($0 ~ /charged/) b_state = "charged"
      else if ($0 ~ /AC Power/ && b_state == "") b_state = "ac"
      if (match($0, /[0-9]+:[0-9][0-9] remaining/)) { b_time = substr($0, RSTART, RLENGTH - 10); sub(/ *$/, "", b_time) }
      if ($0 ~ /present: *true/) b_present = 1
      next
    }
    sec == "BR" {
      if (match($0, /"CycleCount" = [0-9]+/)) { v = substr($0, RSTART, RLENGTH); sub(/.*= /, "", v); b_cycles = v + 0 }
      if (match($0, /"DesignCapacity" = [0-9]+/)) { v = substr($0, RSTART, RLENGTH); sub(/.*= /, "", v); b_design = v + 0 }
      if (match($0, /"AppleRawMaxCapacity" = [0-9]+/)) { v = substr($0, RSTART, RLENGTH); sub(/.*= /, "", v); b_rawmax = v + 0 }
      if (match($0, /"Temperature" = [0-9]+/)) { v = substr($0, RSTART, RLENGTH); sub(/.*= /, "", v); b_temp = v + 0 }
      next
    }
    sec == "L" { lp[$3] = $1; ll[$3] = $2; next }   # verrou : projet, couloir, pid (section de top_layout)
    sec == "S" {
      if (!ps_parse($0)) next
      # agent_of n est pas calculé ici : sur ~1140 processus il coûterait cher à chaque cycle ; emit_top ne le calcule que pour les
      # dix pid du top (cinq par CPU, cinq par mémoire)
      n++; PID[n] = P_PID; CPU[P_PID] = P_CPU + 0; RSS[P_PID] = P_RSS + 0; ARGS[P_PID] = P_ARGS; UIDP[P_PID] = P_UID
      next
    }
    END {
      # ---------- CPU ----------
      # usage global toujours lu sur l occupation de l ordonnanceur (iostat, 100 - idle) : c est ce que montrent le Moniteur
      # d activité et iStat ; le ratio d activité de macmon diverge de plus de 5 points sous charge. macmon n ajoute que le détail
      # cœurs performance/efficience, GPU, puissance et puce (src = macmon quand ce détail est disponible)
      src = (J != "") ? "macmon" : "native"
      cpu_u = (io_id != "") ? (100 - io_id) : ""
      if (J != "") { e_u = jarr2("ecpu_usage") * 100; p_u = jarr2("pcpu_usage") * 100
        g_u = jarr2("gpu_usage") * 100; e_f = jarr1("ecpu_usage"); p_f = jarr1("pcpu_usage"); g_f = jarr1("gpu_usage")
        pw_all = jnum("all_power"); pw_cpu = jnum("cpu_power"); pw_gpu = jnum("gpu_power"); pw_ane = jnum("ane_power")
        chip = jstr("chip_name"); gcores = jnum("gpu_cores") }
      else { e_u = ""; p_u = ""; g_u = ""; pw_all = ""; pw_cpu = ""; chip = "" }
      ncpu = SY["hw.ncpu"]; split(SY["vm.loadavg"], LA, /[ {}]+/); load1 = LA[2]
      out = out "BLOCK=CPU\nSOURCE=" src "\nUSAGE_PCT=" ((cpu_u == "") ? "" : pct(cpu_u)) "\nE_PCT=" ((e_u == "") ? "" : pct(e_u)) \
        "\nP_PCT=" ((p_u == "") ? "" : pct(p_u)) "\nGPU_PCT=" ((g_u == "") ? "" : pct(g_u)) \
        "\nE_FREQ=" (e_f + 0) "\nP_FREQ=" (p_f + 0) "\nGPU_FREQ=" (g_f + 0) \
        "\nPOWER_W=" fmt1(pw_all) "\nCPU_POWER_W=" fmt1(pw_cpu) "\nGPU_POWER_W=" fmt1(pw_gpu) "\nANE_POWER_W=" fmt1(pw_ane) \
        "\nLOAD_1=" load1 "\nCORES=" (ncpu + 0) "\nCHIP=" chip "\nGPU_CORES=" (gcores + 0) "\n\n"
      # ---------- MEM ----------
      total = SY["hw.memsize"] / 1048576
      ps16 = page + 0
      wired = p_wired * ps16 / 1048576; comp = p_occ * ps16 / 1048576
      app = (p_anon - p_purge) * ps16 / 1048576; if (app < 0) app = 0
      # « utilisée » au sens du Moniteur d activité et d iStat : mémoire applicative + réservée (wired) + compressée, hors pages
      # purgeables et fichiers en cache ; toujours native (macmon ne sert pas la mémoire)
      used = wired + comp + app; msrc = "native"
      free_m = total - used; if (free_m < 0) free_m = 0
      sw = SY["vm.swapusage"]; su = sw; swt = sw; sub(/.*used = /, "", su); sub(/[ M].*/, "", su); sub(/.*total = /, "", swt); sub(/[ M].*/, "", swt)
      lvl = SY["kern.memorystatus_vm_pressure_level"]
      pressure = (lvl == "1") ? "normal" : (lvl == "2") ? "warning" : (lvl == "4") ? "critical" : "unknown"
      out = out "BLOCK=MEM\nSOURCE=" msrc "\nUSED_MB=" mb(used) "\nTOTAL_MB=" mb(total) "\nUSED_PCT=" ((total > 0) ? pct(used * 100 / total) : "") \
        "\nFREE_MB=" mb(free_m) "\nWIRED_MB=" mb(wired) "\nCOMPRESSED_MB=" mb(comp) "\nAPP_MB=" mb(app) \
        "\nSWAP_USED_MB=" mb(su + 0) "\nSWAP_TOTAL_MB=" mb(swt + 0) "\nPRESSURE=" pressure "\nFREE_PCT=" (SY["kern.memorystatus_level"] + 0) "\n\n"
      # ---------- DISK ----------
      d_t = d_total / 1024; d_u = d_used / 1024; d_a = d_avail / 1024   # Ko → Mo
      out = out "BLOCK=DISK\nVOLUME=" ((d_mount == "") ? "" : "Macintosh HD") "\nMOUNT=" d_mount "\nUSED_MB=" mb(d_u) "\nTOTAL_MB=" mb(d_t) \
        "\nFREE_MB=" mb(d_a) "\nUSED_PCT=" (((d_u + d_a) > 0) ? pct(d_u * 100 / (d_u + d_a)) : "") "\nIO_MBS=" (io_mbs + 0) "\nIO_TPS=" (io_tps + 0) "\n\n"
      # ---------- NET ----------
      out = out "BLOCK=NET\nIFACE=" n_iface "\nDOWN_BPS=" (n_down + 0) "\nUP_BPS=" (n_up + 0) \
        "\nDOWN_TOTAL_MB=" mb(n_ib / 1048576) "\nUP_TOTAL_MB=" mb(n_ob / 1048576) "\n\n"
      # ---------- BATTERY ----------
      health = (b_design > 0 && b_rawmax > 0) ? pct(b_rawmax * 100 / b_design) : ""
      out = out "BLOCK=BATTERY\nPRESENT=" (b_present ? "yes" : "no") "\nPERCENT=" (b_pct + 0) "\nSTATE=" ((b_state == "") ? "unknown" : b_state) \
        "\nTIME=" b_time "\nCYCLES=" (b_cycles + 0) "\nHEALTH_PCT=" health "\nDESIGN_MAH=" (b_design + 0) "\nMAX_MAH=" (b_rawmax + 0) \
        "\nTEMP_C=" ((b_temp > 0) ? sprintf("%.1f", b_temp / 100) : "") "\n\n"
      # ---------- TEMP (macmon seulement) ----------
      if (J != "") {
        ct = jnum("cpu_temp_avg"); gt = jnum("gpu_temp_avg"); nf = 0; fsum = 0
        while (match(J, /"rpm":[0-9]+/)) { v = substr(J, RSTART + 6, RLENGTH - 6); nf++; FAN[nf] = v + 0; J = substr(J, RSTART + RLENGTH) }
        out = out "BLOCK=TEMP\nSOURCE=macmon\nCPU_C=" ((ct == "") ? "" : sprintf("%.1f", ct)) "\nGPU_C=" ((gt == "") ? "" : sprintf("%.1f", gt)) \
          "\nFANS=" (nf + 0) "\nFAN1_RPM=" (FAN[1] + 0) "\nFAN2_RPM=" (FAN[2] + 0) "\n\n"
      }
      # ---------- top 5 consommateurs (CPU puis mémoire) ----------
      emit_top("cpu"); emit_top("mem")
      printf "%s", out
    }
    # fmt1 : un nombre à une décimale, ou "" si vide (la puissance absente sans macmon)
    function fmt1(x) { return (x == "") ? "" : sprintf("%.1f", x + 0) }
    # emit_top(kind) : les 5 plus gros par CPU (kind=cpu) ou par mémoire résidente (kind=mem), hors le collecteur lui-même ;
    # une session d agent porte son couloir (verrou), les autres leur nom. Tri par insertion (au plus 5 gardes).
    function emit_top(kind,   i, p, v, r, j, nm, where, lane, ag) {
      for (r = 1; r <= 5; r++) { TK[r] = ""; TV[r] = -1 }
      for (i = 1; i <= n; i++) {
        # hors le collecteur lui-même : fraîchement lancé, son %cpu (temps/âge court) le hisserait en tête à tort
        p = PID[i]; if (UIDP[p] != uid || p == self) continue
        v = (kind == "cpu") ? CPU[p] : RSS[p]
        for (r = 1; r <= 5; r++) if (v > TV[r]) { for (j = 5; j > r; j--) { TV[j] = TV[j-1]; TK[j] = TK[j-1] } TV[r] = v; TK[r] = p; break }
      }
      for (r = 1; r <= 5; r++) {
        p = TK[r]; if (p == "") break
        ag = agent_of(ARGS[p])
        nm = (ag == "claude" || ag == "codex") ? ag : name_of(ARGS[p])
        where = ""
        if ((ag == "claude" || ag == "codex") && (p in lp)) {
          lane = ll[p]; where = (lp[p]) ((lane == "main" || lane == "" || lane == "none") ? " (main)" : "/" lane)
        }
        out = out "BLOCK=PROC\nKIND=" kind "\nRANK=" r "\nPID=" p "\nNAME=" nm "\nAGENT=" ag \
          "\nCPU=" sprintf("%.1f", CPU[p]) "\nMEM_MB=" mb(RSS[p] / 1024) "\nWHERE=" where "\n\n"
      }
    }' <<<"$all"
}

# sysmon_view <largeur> : vue lisible des six blocs (stdin, KEY=value) sur stdout, pour lab sysmon et les tests ; aucune mise en
# forme définitive (lot 05), juste les chiffres justes et qui consomme.
sysmon_view() {
  LC_ALL=C awk -v w="$1" '
    BEGIN { RS = ""; FS = "\n" }
    function val(k,   i) { for (i = 1; i <= NF; i++) if (index($i, k "=") == 1) return substr($i, length(k) + 2); return "" }
    function size(m) { m += 0; return (m >= 1024) ? sprintf("%.1fG", m / 1024) : int(m + 0.5) "M" }
    function rate(b) { b += 0; return (b >= 1048576) ? sprintf("%.1fM/s", b / 1048576) : (b >= 1024) ? int(b / 1024) "K/s" : int(b) "B/s" }
    $1 == "BLOCK=CPU" { print "CPU " (val("USAGE_PCT") == "" ? "load " val("LOAD_1") : val("USAGE_PCT") "%") \
        (val("SOURCE") == "macmon" ? " (E " val("E_PCT") "% / P " val("P_PCT") "%, GPU " val("GPU_PCT") "%, " val("POWER_W") " W)" : " (" val("CORES") " cores, load " val("LOAD_1") ")") }
    $1 == "BLOCK=MEM" { print "MEM " size(val("USED_MB")) " of " size(val("TOTAL_MB")) " (" val("USED_PCT") "%, pressure " val("PRESSURE") "), swap " size(val("SWAP_USED_MB")) }
    $1 == "BLOCK=DISK" { print "DISK " val("USED_PCT") "% used, " size(val("FREE_MB")) " free, " val("IO_MBS") " MB/s" }
    $1 == "BLOCK=NET" { print "NET " val("IFACE") " down " rate(val("DOWN_BPS")) " up " rate(val("UP_BPS")) }
    $1 == "BLOCK=BATTERY" { if (val("PRESENT") == "yes") print "BATTERY " val("PERCENT") "% " val("STATE") (val("TIME") == "" ? "" : " " val("TIME")) ", " val("CYCLES") " cycles, " val("HEALTH_PCT") "% of design" }
    $1 == "BLOCK=TEMP" { print "TEMP CPU " val("CPU_C") "°C, GPU " val("GPU_C") "°C, fans " val("FAN1_RPM") "/" val("FAN2_RPM") " rpm" }
    $1 == "BLOCK=PROC" { T[val("KIND")] = T[val("KIND")] sprintf("  %-7s %-24s %5s%% %7s\n", val("PID"), (val("WHERE") == "" ? val("NAME") : val("NAME") " " val("WHERE")), val("CPU"), size(val("MEM_MB"))) }
    END { if (T["cpu"] != "") printf "Top CPU:\n%s", T["cpu"]; if (T["mem"] != "") printf "Top memory:\n%s", T["mem"] }'
}

# sysmon_report : les blocs sur stdout, la vue lisible sur stderr (lab sysmon).
sysmon_report() {
  local blocks
  . "$LAB_ROOT/lib/top.sh"
  blocks="$(sysmon_collect)"
  printf '%s\n' "$blocks"
  printf '%s\n' "$blocks" | sysmon_view "$(onboard_cols)" >&2 || true
}

# ---------- historique circulaire (lot 05) ----------
# Une ligne par passe du collecteur, « epoch cpu mem pression io down up batt temp » (« - » pour une valeur absente) ; borné à
# SYSMON_HIST_MAX lignes (10 min à 30 s, graphiques des menus légendés « −10 min », étalés sur toute leur largeur), la barre lit
# les SYSMON_BAR_POINTS derniers (ses six bâtons : 3 min à 30 s). Réécrit en entier à chaque passe (≤ 20 lignes, < 1 Ko) puis
# renommé : jamais de croissance, jamais de fichier à moitié écrit. Lot 04 de charge-processeur : 60 points à 10 s avant.
SYSMON_HIST_MAX=20
# shellcheck disable=SC2034 # lu par widget_module_render (lib/widget.sh)
SYSMON_BAR_POINTS=6
# sysmon_history_push <fichier> <blocs KEY=value> : ajoute le point de la passe, garde les SYSMON_HIST_MAX derniers
sysmon_history_push() {
  local f="$1" now; now="${LAB_NOW_EPOCH:-$(exec date +%s)}"
  LC_ALL=C awk -v f="$f" -v tmp="$f.$$" -v now="$now" -v max="$SYSMON_HIST_MAX" '
    BEGIN { RS = ""; FS = "\n" }
    function val(k,   i) { for (i = 1; i <= NF; i++) if (index($i, k "=") == 1) return substr($i, length(k) + 2); return "" }
    function d(x) { return (x == "") ? "-" : x }
    $1 == "BLOCK=CPU" { cpu = val("USAGE_PCT") }
    $1 == "BLOCK=MEM" { mem = val("USED_PCT"); lvl = val("PRESSURE") }
    $1 == "BLOCK=DISK" { io = val("IO_MBS") }
    $1 == "BLOCK=NET" { down = val("DOWN_BPS"); up = val("UP_BPS") }
    $1 == "BLOCK=BATTERY" { if (val("PRESENT") == "yes") batt = val("PERCENT") }
    $1 == "BLOCK=TEMP" { temp = val("CPU_C") }
    END {
      RS = "\n"; n = 0
      while ((getline l < f) > 0) if (l != "") H[++n] = l
      close(f)
      H[++n] = now " " d(cpu) " " d(mem) " " d(lvl) " " d(io) " " d(down) " " d(up) " " d(batt) " " d(temp)
      for (i = (n > max) ? n - max + 1 : 1; i <= n; i++) print H[i] > tmp
      close(tmp)
    }' <<<"$2" && mv "$f.$$" "$f"
}
# sysmon_history_tail <fichier> <n> : les n derniers points (rien si l'historique n'existe pas encore)
sysmon_history_tail() { tail -n "$2" "$1" 2>/dev/null || true; }

# ---------- images vectorielles (lot 05) ----------
# Moteur choisi par mesure (rapport de preuves, étape 1) : un PDF écrit en texte par awk puis encodé en base64 dans le même awk,
# que SwiftBar affiche par image= (NSImage lit le PDF : vectoriel, net en Retina). ≈ 2 ms par image, contre ≈ 10 ms pour un binaire
# Swift (compilé à la pose, outils Xcode exigés) et ≈ 10 ms par image pour osascript JavaScript ; aucune dépendance au-delà d awk.
# Repères : x vers la droite, y depuis le HAUT de l image (converti en bas-gauche PDF par py). Polices : Menlo (F1, chasse fixe,
# 0,602 em par caractère) pour les chiffres, Helvetica-Bold (F2) pour les petites étiquettes ; texte en WinAnsi (accents latins).
# Couleurs : palette « light » (texte sombre, barre ou menu clairs) et « dark » des maquettes validées ; alphas fixes /a12…/a35.
# shellcheck disable=SC2034,SC2016 # lu par widget_module_render (lib/widget.sh) ; programme awk, ses $ sont les siens
SYSMON_PDF_AWK='
function pdf_init(   i, k, n, L) {
  for (i = 1; i < 256; i++) ORD[sprintf("%c", i)] = i
  B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  MW = "602"; for (i = 33; i <= 255; i++) MW = MW " 602"
  n = split("light fg .114 .114 .122|light mute .369 .369 .388|light label .227 .227 .243|light ok .118 .557 .243|light warn .698 .373 0|light crit .843 0 .082|light down 0 .443 .643|light up .537 .267 .671|light ink 0 0 0|dark fg .961 .961 .969|dark mute .631 .631 .651|dark label .631 .631 .651|dark ok .188 .82 .345|dark warn 1 .624 .039|dark crit 1 .271 .227|dark down .392 .824 1|dark up .855 .561 1|dark ink 1 1 1", L, "|")
  for (i = 1; i <= n; i++) { split(L[i], k, " "); PAL[k[1], k[2]] = k[3] " " k[4] " " k[5] }
  n = split("C 722 P 667 U 722 M 833 E 667 S 667 D 722 B 722 A 722 T 611 N 722 G 778 O 778 I 278 K 722", L, " ")
  for (i = 1; i < n; i += 2) HB[L[i]] = L[i + 1]
}
function pdf_begin(w, h) { PW = w; PH = h; PC = "" }
function n2(x) { return sprintf("%.2f", x) }
function py(y) { return n2(PH - y) }
# couleur de remplissage ou de trait : un nom de palette (fg, ok…) dans l apparence app
function pdf_fill(app, name) { PC = PC PAL[app, name] " rg\n" }
function pdf_stroke(app, name) { PC = PC PAL[app, name] " RG\n" }
function pdf_alpha(a) { PC = PC "/a" a " gs\n" }
function pdf_push() { PC = PC "q\n" }
function pdf_pop() { PC = PC "Q\n" }
function pdf_rect(x, y, w, h) { PC = PC n2(x) " " py(y + h) " " n2(w) " " n2(h) " re f\n" }
# rectangle arrondi (r) : rempli (op = f) ou tracé (op = S)
function pdf_rrect(x, y, w, h, r, op,   k, x2, y2) {
  k = r * 0.5523; x2 = x + w; y2 = y + h
  PC = PC n2(x + r) " " py(y) " m " n2(x2 - r) " " py(y) " l " n2(x2 - r + k) " " py(y) " " n2(x2) " " py(y + r - k) " " n2(x2) " " py(y + r) " c " \
    n2(x2) " " py(y2 - r) " l " n2(x2) " " py(y2 - r + k) " " n2(x2 - r + k) " " py(y2) " " n2(x2 - r) " " py(y2) " c " \
    n2(x + r) " " py(y2) " l " n2(x + r - k) " " py(y2) " " n2(x) " " py(y2 - r + k) " " n2(x) " " py(y2 - r) " c " \
    n2(x) " " py(y + r) " l " n2(x) " " py(y + r - k) " " n2(x + r - k) " " py(y) " " n2(x + r) " " py(y) " c h " op "\n"
}
function pdf_disc(cx, cy, r) { pdf_rrect(cx - r, cy - r, 2 * r, 2 * r, r, "f") }
# part de camembert : de midi, dans le sens des aiguilles, pct % du disque (polygone de 64 pas par tour)
function pdf_wedge(cx, cy, r, pct,   n, i, t) {
  if (pct <= 0) return
  if (pct >= 99.9) { pdf_disc(cx, cy, r); return }
  n = int(pct * 64 / 100) + 1
  PC = PC n2(cx) " " py(cy) " m "
  for (i = 0; i <= n; i++) { t = (pct / 100) * 6.283185 * i / n; PC = PC n2(cx + r * sin(t)) " " py(cy - r * cos(t)) " l " }
  PC = PC "h f\n"
}
# pdf_series(x, y, w, h, vals, n, max, app, name, area) : courbe de n valeurs (V[1..n] lues dans vals, séparées par des espaces),
# la plus récente à droite ; un point absent (« - ») coupe la courbe. area = 1 : surface remplie sous la courbe en alpha 28.
function pdf_series(x, y, w, h, vals, n, max, app, name, area,   V, i, k, px, pyv, step, path, seg, first, fx, ap) {
  split(vals, V, " "); if (max <= 0) max = 1; step = w / (((hm + 0 > 1) ? hm : 60) - 1); path = ""; seg = 0; ap = ""
  for (i = 1; i <= n; i++) {
    if (V[i] == "-" || V[i] == "") { seg = 0; continue }
    px = x + w - (n - i) * step; k = V[i] / max; if (k > 1) k = 1; if (k < 0) k = 0
    pyv = y + h - 1 - k * (h - 3)
    if (!seg) { path = path n2(px) " " py(pyv) " m "; seg = 1; if (first == "") first = px } else path = path n2(px) " " py(pyv) " l "
    ap = ap n2(px) " " py(pyv) " l "
    fx = px; LASTY = pyv
  }
  if (path == "") return
  if (area && first != "") {
    pdf_push(); pdf_alpha(28); pdf_fill(app, name)
    PC = PC n2(first) " " py(y + h) " m " ap n2(fx) " " py(y + h) " l h f\n"; pdf_pop()
  }
  pdf_push(); pdf_stroke(app, name); PC = PC "1.4 w 1 j 1 J\n" path "S\n"; pdf_pop()
}
# pdf_str(s) : chaîne PDF en WinAnsi depuis l UTF-8 (accents latins, °, ·, …, —) ; PSLEN = nombre de caractères
function pdf_str(s,   i, c, o, r, b) {
  r = ""; PSLEN = 0
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1); o = ORD[c]
    if (o < 128) { if (c == "(" || c == ")" || c == "\\") r = r "\\" c; else r = r c; PSLEN++; continue }
    b = ORD[substr(s, i + 1, 1)]
    if (o == 194) { r = r sprintf("\\%03o", b); i++; PSLEN++ }
    else if (o == 195) { r = r sprintf("\\%03o", b + 64); i++; PSLEN++ }
    else if (o == 226) {
      c = substr(s, i, 3); i += 2; PSLEN++
      if (c == "\342\200\246") r = r "\\205"; else if (c == "\342\200\224") r = r "\\227"; else if (c == "\342\200\223") r = r "\\226"; else r = r "-"
    } else if (o >= 240) i += 3; else if (o >= 224) i += 2; else if (o >= 192) i++
  }
  return r
}
# largeur d un texte : Menlo (F1) à chasse fixe ; Helvetica-Bold (F2) par la table HB (majuscules), plus l espacement tc par caractère
function pdf_tw(s, font, size, tc,   i, c, w, t) {
  t = pdf_str(s)
  if (font == 1) return PSLEN * 0.602 * size
  w = 0
  for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (ORD[c] >= 128) { c = "E"; i++ } w += (c in HB) ? HB[c] : 667 }
  return w * size / 1000 + PSLEN * tc
}
# pdf_text(x, base, font, size, app, name, s, tc) : texte dont la ligne de base est à base (depuis le haut)
function pdf_text(x, base, font, size, app, name, s, tc) {
  PC = PC "BT " PAL[app, name] " rg /F" font " " size " Tf " ((tc > 0) ? tc " Tc " : "") "1 0 0 1 " n2(x) " " py(base) " Tm (" pdf_str(s) ") Tj ET\n"
}
# texte calé à droite sur x
function pdf_rtext(x, base, font, size, app, name, s, tc) { pdf_text(x - pdf_tw(s, font, size, tc), base, font, size, app, name, s, tc) }
# flèche pleine (dir = 1 vers le haut, -1 vers le bas), pointe large de w
function pdf_arrow(x, y, w, h, dir,   m) {
  m = x + w / 2
  if (dir > 0) PC = PC n2(m) " " py(y) " m " n2(x + w) " " py(y + h * 0.5) " l " n2(m + w * 0.16) " " py(y + h * 0.5) " l " n2(m + w * 0.16) " " py(y + h) " l " n2(m - w * 0.16) " " py(y + h) " l " n2(m - w * 0.16) " " py(y + h * 0.5) " l " n2(x) " " py(y + h * 0.5) " l h f\n"
  else PC = PC n2(m) " " py(y + h) " m " n2(x + w) " " py(y + h * 0.5) " l " n2(m + w * 0.16) " " py(y + h * 0.5) " l " n2(m + w * 0.16) " " py(y) " l " n2(m - w * 0.16) " " py(y) " l " n2(m - w * 0.16) " " py(y + h * 0.5) " l " n2(x) " " py(y + h * 0.5) " l h f\n"
}
function pdf_obj(s) { PN++; POFF[PN] = length(PD); PD = PD PN " 0 obj\n" s "\nendobj\n" }
# pdf_end() → le PDF complet de l image en cours, encodé en base64 (une ligne)
function pdf_end(   x, i) {
  PD = "%PDF-1.4\n"; PN = 0
  pdf_obj("<</Type/Catalog/Pages 2 0 R>>")
  pdf_obj("<</Type/Pages/Kids[3 0 R]/Count 1>>")
  pdf_obj("<</Type/Page/Parent 2 0 R/MediaBox[0 0 " PW " " PH "]/Contents 4 0 R/Resources<</Font<</F1 5 0 R/F2 6 0 R>>/ExtGState<</a12<</ca .12/CA .12>>/a18<</ca .18/CA .18>>/a22<</ca .22/CA .22>>/a28<</ca .28/CA .28>>/a35<</ca .35/CA .35>>>>>>>>")
  pdf_obj("<</Length " length(PC) ">>\nstream\n" PC "endstream")
  pdf_obj("<</Type/Font/Subtype/TrueType/BaseFont/Menlo-Regular/Encoding/WinAnsiEncoding/FirstChar 32/LastChar 255/Widths[" MW "]/FontDescriptor 7 0 R>>")
  pdf_obj("<</Type/Font/Subtype/Type1/BaseFont/Helvetica-Bold/Encoding/WinAnsiEncoding>>")
  pdf_obj("<</Type/FontDescriptor/FontName/Menlo-Regular/Flags 33/FontBBox[-558 -375 718 1042]/ItalicAngle 0/Ascent 928/Descent -236/CapHeight 729/StemV 80>>")
  x = length(PD); PD = PD "xref\n0 " (PN + 1) "\n0000000000 65535 f \n"
  for (i = 1; i <= PN; i++) PD = PD sprintf("%010d 00000 n \n", POFF[i])
  PD = PD "trailer\n<</Size " (PN + 1) "/Root 1 0 R>>\nstartxref\n" x "\n%%EOF\n"
  return b64(PD)
}
function b64(s,   i, n, a, b, c, r) {
  r = ""; n = length(s)
  for (i = 1; i <= n; i += 3) {
    a = ORD[substr(s, i, 1)]; b = (i + 1 <= n) ? ORD[substr(s, i + 1, 1)] : 0; c = (i + 2 <= n) ? ORD[substr(s, i + 2, 1)] : 0
    r = r substr(B64, int(a / 4) + 1, 1) substr(B64, (a % 4) * 16 + int(b / 16) + 1, 1)
    r = r ((i + 1 <= n) ? substr(B64, (b % 16) * 4 + int(c / 64) + 1, 1) : "=") ((i + 2 <= n) ? substr(B64, c % 64 + 1, 1) : "=")
  }
  return r
}
'
