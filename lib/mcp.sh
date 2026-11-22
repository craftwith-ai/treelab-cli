# shellcheck shell=bash
# mcp.sh — lab mcp (lot 01 du couloir mcp-sobres) : les serveurs d'outils (MCP) configurés et leurs copies vivantes, en lecture seule.
# Inventaire : global Claude (~/.claude.json, settings.json), global Codex (config.toml), et pour chaque projet enregistré son entrée
# projects de ~/.claude.json, son .mcp.json et son .codex/config.toml. Vivants : un seul instantané ps, regroupé par paquet.
# Secrets : une configuration porte des jetons (env, headers, url, arguments) et une ligne de commande aussi (mcp-remote --header).
# Rien n'en sort : seuls le nom du serveur, le transport et le premier argument après le lanceur (le paquet) sont émis, filtrés à un
# jeu de caractères sûr ; les erreurs de jq sont muettes, un fichier illisible n'est nommé que par son chemin.
. "$LAB_ROOT/lib/top.sh"   # TOP_AWK_LIB : agent_of et top_base, même reconnaissance des sessions que lab top

MCP_RSS_WARN_MB=1024   # seuil par défaut de global.mcp.rss (doctor), réglable par mcp_rss_warn_mb= dans $LAB_HOME/config

# Ligne interne (jamais affichée) : source, portée, nom, transport, commande, arguments séparés par \037. MCP_FINISH_AWK en tire
# la ligne publique : source, portée, nom, transport, paquet (ou -), figé yes|no|-, clé de rapprochement avec les vivants, lanceur
# du paquet (npx, npm, uvx… ou -).
# shellcheck disable=SC2016 # programme jq, ses $ sont les siens
MCP_JQ='
def rows($src; $scope): (. // {}) | if type == "object" then to_entries[] | select(.value | type == "object") | .value as $v
  | [$src, $scope, .key, (($v.type // (if $v.url then "http" else "stdio" end)) | tostring), (($v.command // "") | tostring),
     ([($v.args // [])[]? | tostring] | join("\u001f"))] | map(gsub("[\t\n\r]"; " ")) | @tsv
  else empty end;'
# Options de lanceur suivies d'une valeur, et forme d'un nom de paquet (portée npm, version @x ou ==x) : rien d'autre ne sort.
MCP_OPTARG='^(--from|--registry|--index-url|--extra-index-url|--index|--with|--python|--cache|--userconfig|--prefix|--package|-p)$'
MCP_PKG='^(@[A-Za-z0-9._~-]+/)?[A-Za-z0-9._~-]+(@[A-Za-z0-9._^~<>=*+-]+|==[A-Za-z0-9._+-]+)?$'
# shellcheck disable=SC2016 # programme awk, ses $ sont les siens
MCP_FINISH_AWK='
function safe(s) { gsub(/[^A-Za-z0-9._@\/+=:~-]/, "?", s); return (s == "") ? "-" : s }
function base(s) { sub(/\/+$/, "", s); sub(/.*\//, "", s); return s }
# pkg_of <mots> <n> <k> : le paquet si un lanceur commence au mot k (npx, bunx, pnpx, uvx, npm exec, pnpm dlx, pipx run [--spec x]),
# sinon vide ; le premier mot qui n est pas une option, jamais les suivants
function pkg_of(t, n, k,   b, i) {
  b = base(t[k]); LN = b   # LN : le lanceur reconnu (npm exec → npm), lu par lab mcp --pin
  if (b ~ /^(npx|bunx|pnpx|uvx)$/) i = k + 1
  else if ((b == "npm" && t[k + 1] == "exec") || (b == "pnpm" && t[k + 1] == "dlx") || (b == "pipx" && t[k + 1] == "run")) i = k + 2
  else return ""
  for (; i <= n; i++) {
    if (t[i] == "--spec" && b == "pipx") return t[i + 1]
    if (t[i] ~ OPTARG) { i++; continue }   # sa valeur (dépôt git, registre à jeton…) n est jamais le paquet
    if (t[i] !~ /^-/) return t[i]
  }
  return ""
}
BEGIN { FS = "\t"; OFS = "\t"; OPTARG = MCP_OPTARG; PKG = MCP_PKG }
NF >= 4 {
  t = ($4 == "sse" || $4 == "http" || $4 == "streamable-http") ? $4 : "stdio"; if (t == "streamable-http") t = "http"
  split("", w); w[1] = $5; n = split($6, a, "\037"); for (i = 1; i <= n; i++) w[i + 1] = a[i]; n++
  b = base($5); pkg = ""; key = ""
  if (t == "stdio") {
    pkg = pkg_of(w, n, 1)
    if (pkg == "" && b ~ /^(sh|bash|zsh|dash)$/) {   # lanceur derrière un shell : sh -c "… exec npx -y <paquet> …"
      for (i = 2; i < n; i++) if (w[i] ~ /^-[a-z]*c[a-z]*$/) { m = split(w[i + 1], c, /[ \t;&|]+/); for (j = 1; j <= m && pkg == ""; j++) pkg = pkg_of(c, m, j); break }
    }
    if (pkg != "" && pkg !~ PKG) pkg = ""   # pas la forme d un nom de paquet : jamais affiché
    if (pkg == "" && b !~ /^(node|bun|deno|python[0-9.]*|ruby|sh|bash|zsh|dash|uv|docker|npx|npm|bunx|pnpx|pnpm|uvx|pipx|claude|codex)$/) key = b
  }
  pin = "-"
  if (pkg != "") {
    if ((i = index(pkg, "==")) > 0) { key = substr(pkg, 1, i - 1); ver = substr(pkg, i + 2) }
    else { p = pkg; at = (substr(p, 1, 1) == "@") ? 1 : 0; if (at) p = substr(p, 2); i = index(p, "@")
      if (i > 0) { key = substr(pkg, 1, i - 1 + at); ver = substr(p, i + 1) } else { key = pkg; ver = "" } }
    pin = (ver ~ /^v?[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]*)?$/) ? "yes" : "no"
  }
  if (key !~ /^[A-Za-z0-9._@\/+~-]+$/) key = ""   # clé de rapprochement : un nom sûr, jamais un morceau de script
  print $1, safe($2), safe($3), t, (pkg == "" ? "-" : safe(pkg)), pin, safe(key), (pkg == "" ? "-" : LN)
}'
# TOML de Codex lu à la main, comme global.codex.mcp.count de lib/doctor.sh : [mcp_servers.<nom>] ou [mcp_servers."<nom>"], ses clés
# command, url et args (tableau sur une ou plusieurs lignes) ; les sous-tables ([mcp_servers.<nom>.env]) ne sont jamais lues.
# shellcheck disable=SC2016 # programme awk, ses $ sont les siens
MCP_TOML_AWK='
BEGIN { q = sprintf("%c", 39); STR = "\"([^\"\\\\]|\\\\.)*\"|" q "[^" q "]*" q }   # chaîne TOML "…" ou littérale \047…\047
function strs(s, out,   v) {   # chaînes TOML de s, jointes par \037
  out = ""
  while (match(s, STR)) { v = substr(s, RSTART + 1, RLENGTH - 2); out = out (out == "" ? "" : "\037") v; s = substr(s, RSTART + RLENGTH) }
  return out
}
function flush() { if (cur != "") print src "\t" scope "\t" cur "\t" (url ? "http" : "stdio") "\t" cmd "\t" args; cur = ""; cmd = ""; args = ""; url = 0; inargs = 0 }
/^[ \t]*\[/ {
  flush(); h = $0; sub(/^[ \t]*\[[ \t]*/, "", h); sub(/[ \t]*\][ \t]*(#.*)?$/, "", h)
  if (substr(h, 1, 12) == "mcp_servers.") { nm = substr(h, 13)
    if (nm ~ /^"[^"]*"$/) cur = substr(nm, 2, length(nm) - 2); else if (nm !~ /[."]/ && nm != "") cur = nm }
  next
}
cur == "" { next }
inargs { buf = buf " " $0; rest = buf; gsub(STR, "", rest); if (index(rest, "]")) { args = strs(buf); inargs = 0 } next }
/^[ \t]*command[ \t]*=/ { v = $0; sub(/^[^=]*=/, "", v); cmd = strs(v); next }
/^[ \t]*url[ \t]*=/ { url = 1; next }
/^[ \t]*args[ \t]*=/ { buf = $0; sub(/^[^=]*=/, "", buf); rest = buf; gsub(STR, "", rest)
  if (index(rest, "]")) args = strs(buf); else inargs = 1; next }
END { flush() }'

# mcp_json <source> <portée> <fichier> <filtre jq vers l'objet mcpServers> [--arg nom valeur] → lignes internes ; illisible : nommé
mcp_json() {
  local src="$1" scope="$2" f="$3" filter="$4"; shift 4
  [ -f "$f" ] || return 0
  jq -r --arg src "$src" --arg scope "$scope" "$@" "$MCP_JQ $filter | rows(\$src; \$scope)" "$f" 2>/dev/null \
    || warn "$f unreadable (invalid JSON): its tool servers are not counted"
}
mcp_toml() { [ -f "$3" ] || return 0; LC_ALL=C awk -v src="$1" -v scope="$2" "$MCP_TOML_AWK" "$3" 2>/dev/null || true; }

# mcp_inventory → « source<TAB>portée<TAB>nom<TAB>transport<TAB>paquet<TAB>figé<TAB>clé<TAB>lanceur », une ligne par serveur configuré
mcp_inventory() {
  local cj="$HOME/.claude.json" p root rest
  {
    mcp_json claude global "$cj" '.mcpServers'
    mcp_json claude-settings global "${LAB_CLAUDE_SETTINGS:-$(claude_home)/settings.json}" '.mcpServers'
    mcp_toml codex global "$(codex_config)"
    while IFS=$'\t' read -r p root rest; do
      [ -n "$root" ] && [ -d "$root" ] || continue   # projet enregistré dont le dossier a disparu : ignoré
      # shellcheck disable=SC2016 # $root est une variable de jq
      mcp_json claude "$p" "$cj" '.projects[$root].mcpServers' --arg root "$root"
      mcp_json mcp.json "$p" "$root/.mcp.json" '.mcpServers'
      mcp_toml codex "$p" "$root/.codex/config.toml"
    done < <(top_projects)
  } | LC_ALL=C awk -v MCP_OPTARG="$MCP_OPTARG" -v MCP_PKG="$MCP_PKG" "$MCP_FINISH_AWK"
}

# mcp_live <inventaire> → « LIVE<TAB>paquet<TAB>copies<TAB>processus<TAB>RSS Ko » par paquet, plus gros d'abord, puis
# « TOTAL<TAB>processus<TAB>RSS Ko ». Racine d'un serveur : npm exec / npx / uvx <paquet>, node ou python sur un script, ou un binaire,
# dont le nom porte « mcp » ou figure à l'inventaire ; le helper cmux-cua. Ses descendants lui sont comptés (node de _npx, mcp-remote).
# Les sessions claude et codex (leur --mcp-config nomme les serveurs) sont jugées par la commande avant sa première option : jamais
# racines, jamais comptées. Rend 1 si ps est illisible.
mcp_live() {
  local ps_out known
  ps_out="$(LC_ALL=en_US.UTF-8 "${LAB_MCP_PS:-ps}" -axww -o pid=,ppid=,rss=,args= 2>/dev/null)" || return 1
  known="$(printf '%s\n' "$1" | awk -F '\t' 'NF >= 7 && $7 != "-" { printf "%s%s", (n++ ? "," : ""), $7 }')"
  printf '%s\n' "$ps_out" | LC_ALL=C awk -v known="$known" -v self="$$" -v MCP_OPTARG="$MCP_OPTARG" "$TOP_AWK_LIB"'
    function pkgname(s,   i, p, at) {
      if ((i = index(s, "==")) > 0) return substr(s, 1, i - 1)
      at = (substr(s, 1, 1) == "@") ? 1 : 0; p = substr(s, at + 1); i = index(p, "@")
      return (i > 0) ? substr(s, 1, i - 1 + at) : s
    }
    function mcpish(s) { return s ~ SAFE && ((s in KNOWN) || tolower(s) ~ /mcp/) }   # un nom sûr, jamais une URL ni un jeton
    function root_of(args,   head, a, n, b0, i, st, s) {
      head = args; sub(/ -.*$/, "", head)
      if (head ~ /\/cmux-cua( |$)/) return "cmux-cua"
      n = split(args, a, " "); b0 = top_base(a[1]); st = 0
      if (b0 ~ /^(npx|bunx|pnpx|uvx)$/) st = 2
      else if ((b0 == "npm" && a[2] == "exec") || (b0 == "pnpm" && a[2] == "dlx")) st = 3
      if (st) { for (i = st; i <= n; i++) { if (a[i] ~ OPTARG) { i++; continue } if (a[i] !~ /^-/) { s = pkgname(a[i]); return mcpish(s) ? s : "" } } return "" }
      if (tolower(b0) ~ /^(node|bun|deno|python[0-9.]*|ruby)$/) {
        for (i = 2; i <= n; i++) if (a[i] !~ /^-/) { s = top_base(a[i]); return mcpish(s) ? s : "" }
        return ""
      }
      if (b0 ~ /^(sh|bash|zsh|fish|dash)$/) return ""
      if ((i = index(head, ".app/Contents/MacOS/")) > 0) { s = substr(head, i + 20); sub(/ .*$/, "", s) } else s = b0
      return mcpish(s) ? s : ""
    }
    BEGIN { nk = split(known, K, ","); for (i = 1; i <= nk; i++) KNOWN[K[i]] = 1; OPTARG = MCP_OPTARG; SAFE = "^[A-Za-z0-9._@/+~-]+$" }
    match($0, /^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+[0-9]+[ \t]*/) {
      head = substr($0, 1, RLENGTH); rest = substr($0, RLENGTH + 1); sub(/^[ \t]+/, "", head); split(head, f, /[ \t]+/)
      p = f[1]; PP[p] = f[2]; RS_KB[p] = f[3]; ord[++np] = p
      if (p == self) next
      AGENT[p] = (agent_of(rest) != ""); if (!AGENT[p]) ROOT[p] = root_of(rest)
    }
    END {
      for (k = 1; k <= np; k++) {
        p = ord[k]; q = p; top = ""; d = 0
        while (q != "" && q != "0" && d < 64 && !AGENT[q]) { if (ROOT[q] != "") top = q; q = PP[q]; d++ }
        if (top == "") continue
        g = ROOT[top]; procs[g]++; kb[g] += RS_KB[p]; tp++; tk += RS_KB[p]
        if (top == p) copies[g]++
      }
      for (g in procs) print "LIVE\t" g "\t" copies[g] + 0 "\t" procs[g] "\t" kb[g]
      print "TOTAL\t" tp + 0 "\t" tk + 0
    }' | sort -t $'\t' -k1,1 -k5,5nr
}

mcp_mb() { awk -v k="$1" 'BEGIN { printf "%d\n", int(k / 1024 + 0.5) }'; }

# mcp_view <largeur> : inventaire puis vivants (sections #I, #L sur stdin) → vue lisible. Tableau quand il tient dans la largeur,
# sinon un bloc par ligne, nom en tête ; un nom n'est jamais coupé.
# shellcheck disable=SC2016 # programme awk, ses $ sont les siens
MCP_VIEW_AWK='
function pad(s, n) { while (length(s) < n) s = s " "; return s }
function lpad(s, n) { while (length(s) < n) s = " " s; return s }
function pinned(x) { return (x == "yes") ? "pinned" : (x == "no") ? "not pinned" : "" }
function mbs(k) { return int(k / 1024 + 0.5) " MB" }
function part(x) { if (x == "") return; if (cur == "") cur = "  " x; else if (length(cur " · " x) <= w) cur = cur " · " x; else { print cur; cur = "  " x } }   # détail replié entre deux morceaux
function say(a, b) { if (length(a " " b) <= w) print a " " b; else { print a; print "  " b } }   # titre et chiffres, repliés si trop larges
BEGIN { FS = "\t" }
/^#[A-Z]$/ { sec = substr($0, 2); next }
sec == "I" && NF >= 6 { ni++; I1[ni] = $2; I2[ni] = $1; I3[ni] = $3; I4[ni] = $4; I5[ni] = $5; I6[ni] = $6; nu += ($6 == "no"); next }
sec == "L" && $1 == "LIVE" { nl++; L1[nl] = $2; L2[nl] = $3; L3[nl] = $4; L4[nl] = $5; next }
sec == "L" && $1 == "TOTAL" { tp = $2; tk = $3; next }
END {
  say("Tool servers (MCP):", ni " configured, " nu + 0 " not pinned")
  h[1] = "Scope"; h[2] = "Name"; h[3] = "Type"; h[4] = "Package"; h[5] = "Pinned"   # la source reste dans MCP_SERVER= et la vue en blocs
  for (c = 1; c <= 5; c++) wd[c] = length(h[c])
  for (i = 1; i <= ni; i++) { v[1] = I1[i]; v[2] = I3[i]; v[3] = I4[i]; v[4] = I5[i]; v[5] = I6[i]
    for (c = 1; c <= 5; c++) if (length(v[c]) > wd[c]) wd[c] = length(v[c]) }
  tot = 0; for (c = 1; c <= 5; c++) tot += wd[c] + 2
  if (ni > 0 && tot - 2 <= w) {
    print ""; line = ""; for (c = 1; c <= 5; c++) line = line pad(h[c], (c < 5) ? wd[c] + 2 : 0); print line
    for (i = 1; i <= ni; i++) print pad(I1[i], wd[1] + 2) pad(I3[i], wd[2] + 2) pad(I4[i], wd[3] + 2) pad(I5[i], wd[4] + 2) I6[i]
  } else for (i = 1; i <= ni; i++) {
    print ""; print I3[i]; cur = ""; part(I1[i]); part(I2[i]); part(I4[i]); part(pinned(I6[i])); print cur
    if (I5[i] != "-") print "  " I5[i]
  }
  print ""
  say("Running:", tp + 0 " processes, " mbs(tk) " resident")
  wn = length("Package"); for (i = 1; i <= nl; i++) if (length(L1[i]) > wn) wn = length(L1[i])
  if (nl > 0 && wn + 2 + 6 + 2 + 9 + 2 + 7 <= w) {
    print ""; print pad("Package", wn + 2) lpad("Copies", 6) "  " lpad("Processes", 9) "  " lpad("Memory", 7)
    for (i = 1; i <= nl; i++) print pad(L1[i], wn + 2) lpad(L2[i], 6) "  " lpad(L3[i], 9) "  " lpad(mbs(L4[i]), 7)
  } else for (i = 1; i <= nl; i++) { print ""; print L1[i]; cur = ""; part(L2[i] " copies"); part(L3[i] " processes"); part(mbs(L4[i])); print cur }
}'

# mcp_report : lab mcp — KEY=value sur stdout, vue lisible sur stderr
mcp_report() {
  local inv live="" total procs=0 kb=0
  inv="$(mcp_inventory)"
  if ! live="$(mcp_live "$inv")"; then live=""; warn "process table unreadable (ps): running copies not counted"; fi
  total="$(printf '%s\n' "$live" | awk -F '\t' '$1 == "TOTAL" { print $2 "\t" $3 }')"
  if [ -n "$total" ]; then procs="${total%%$'\t'*}"; kb="${total#*$'\t'}"; fi
  kv MCP_SERVERS "$(printf '%s\n' "$inv" | awk -F '\t' 'NF >= 6 { n++ } END { print n + 0 }')"
  kv MCP_UNPINNED "$(printf '%s\n' "$inv" | awk -F '\t' '$6 == "no" { n++ } END { print n + 0 }')"
  kv MCP_PROCESSES "$procs"
  kv MCP_RSS_MB "$(mcp_mb "$kb")"
  printf '%s\n' "$inv" | awk -F '\t' 'NF >= 6 { print "MCP_SERVER=" $2 " " $1 " " $3 " " $4 " " $5 " " $6 }'
  printf '%s\n' "$live" | awk -F '\t' '$1 == "LIVE" { printf "MCP_LIVE=%s %s %s %d\n", $2, $3, $4, int($5 / 1024 + 0.5) }'
  printf '#I\n%s\n#L\n%s\n' "$inv" "$live" | LC_ALL=C awk -v w="$(onboard_cols)" "$MCP_VIEW_AWK" >&2
}

# mcp_doctor : lignes global.mcp.rss (avertit au-delà de mcp_rss_warn_mb=, défaut 1024) et global.mcp.unpinned (avertit au-delà de 0)
# de lab doctor ; jamais rouges, hors baseline (une mesure de la machine, pas du projet). Fonctions check et flag de lib/doctor.sh.
mcp_doctor() {
  local lim note="" inv live total procs=0 kb=0 unp
  lim="$(global_config_get mcp_rss_warn_mb)"
  case "$lim" in
    '') lim="$MCP_RSS_WARN_MB" ;;
    *[!0-9]*) note="mcp_rss_warn_mb=$lim in $LAB_HOME/config: whole megabytes expected, $MCP_RSS_WARN_MB used; "; lim="$MCP_RSS_WARN_MB" ;;
  esac
  inv="$(mcp_inventory 2>/dev/null)"
  if live="$(mcp_live "$inv" 2>/dev/null)"; then
    total="$(printf '%s\n' "$live" | awk -F '\t' '$1 == "TOTAL" { print $2 "\t" $3 }')"
    if [ -n "$total" ]; then procs="${total%%$'\t'*}"; kb="${total#*$'\t'}"; fi
    check global.mcp.rss "$(mcp_mb "$kb")" "$lim" warn "${note}Resident memory (MB) of the $procs tool server (MCP) processes; lab mcp details them; threshold mcp_rss_warn_mb= in $LAB_HOME/config" sans-cliquet
  else flag global.mcp.rss warn unreadable "${note}process table unreadable (ps): tool servers not measured"; fi
  unp="$(printf '%s\n' "$inv" | awk -F '\t' '$6 == "no" { n++ } END { print n + 0 }')"
  check global.mcp.unpinned "$unp" 0 warn "Tool servers without a fixed version (@latest or none): each start may fetch a new one; lab mcp lists them" sans-cliquet
}
