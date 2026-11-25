# shellcheck shell=bash
# top.sh — lab top (lot 01 du couloir tableau-de-bord) : photographie du poste en lecture seule. Chaque session claude ou codex est
# rattachée à son projet et à son couloir, ses processus enfants (serveurs d'outils, commandes lancées) lui sont comptés, le reste
# est rangé en familles hors Treelab, et une liste « à couper » dit le motif et le geste annoncé. Une passe par sonde (ps, lsof,
# empreinte, tail des journaux, sysctl, vm_stat, pmset), puis des jointures awk : aucune boucle de fork par processus.
# Rien n'est écrit ni coupé ici : les gestes du lot 02 (--cut, --wake, --explain) vivent dans lib/top_cut.sh, chargé à part.
# Empreinte : phys_footprint, la valeur du Moniteur d'activité, lue par proc_pid_rusage (libproc) pour tous les processus en un
# appel (0,11 s mesurées pour 1 100 processus) ; l'outil footprint coûtait 7,6 s pour les 850 processus du compte, 2 à 2,8 s en
# parallèle (rapport de preuves du lot 01). Sans python3 ou sous --fast : mémoire résidente, marquée approximative.

TOP_TAIL_BYTES=65536     # fin de journal lue par session ; message au-delà : inactivité unknown, jamais proposée
TOP_FAMILY_MEM_PCT=25    # famille hors Treelab proposée à l'explication au-delà de ce % de la mémoire physique
TOP_FAMILY_CPU=100       # ... ou au-delà d'un cœur entier
TOP_TOOL_CPU=50          # processus seul de l'utilisateur occupé à ce % depuis TOP_TOOL_AGE secondes : outil oublié ?
TOP_TOOL_AGE=3600
TOP_ZOMBIE_MIN=3         # parent proposé au redémarrage à partir de ce nombre de zombies (Claude Code en garde un par session)
TOP_ORPHAN_AGE=3600      # serveur d'outils ou navigateur de test repris par launchd : orphelin proposé à l'arrêt à partir de cet âge
TOP_STOP_WAIT="${LAB_TOP_STOP_WAIT:-10}"   # secondes entre le signal d'arrêt et l'arrêt forcé (réglable pour les tests)

# Sonde d'empreinte : les pid sur l'entrée standard, « pid octets » sur la sortie ; un processus illisible (root) est omis.
TOP_FOOTPRINT_PY='
import ctypes, sys
try:
    lib = ctypes.CDLL("/usr/lib/libproc.dylib")
except OSError:
    sys.exit(1)
class Info(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(n, ctypes.c_uint64) for n in ("user", "system", "pkg_idle", "interrupt", "pageins", "wired", "resident", "footprint", "start", "exit")]
info = Info()
rows = []
for line in sys.stdin:
    p = line.strip()
    if p.isdigit() and lib.proc_pid_rusage(int(p), 0, ctypes.byref(info)) == 0:
        rows.append("%s %d" % (p, info.footprint))
sys.stdout.write("\n".join(rows) + "\n")
'

# Fonctions awk partagées : lecture d'une ligne de ps, classement agent, identifiant de session, famille, nom affiché, dates.
# shellcheck disable=SC2016 # programme awk, ses $ sont les siens
TOP_AWK_LIB='
function top_base(s) { sub(/\/+$/, "", s); sub(/.*\//, "", s); return s }
function ps_parse(line,   head, f) {
  if (!match(line, /^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+[0-9]+[ \t]+[^ \t]+[ \t]+[0-9]+[ \t]+[0-9.,]+[ \t]+[0-9:-]+[ \t]*/)) return 0
  head = substr(line, 1, RLENGTH); P_ARGS = substr(line, RLENGTH + 1); sub(/^[ \t]+/, "", head)
  split(head, f, /[ \t]+/)
  P_PID = f[1]; P_PPID = f[2]; P_UID = f[3]; P_STAT = f[4]; P_RSS = f[5]; P_CPU = f[6]; P_ET = f[7]; sub(/,/, ".", P_CPU)
  return 1
}
function agent_of(args,   a, n, b0, sub1) {
  n = split(args, a, " "); b0 = top_base(a[1]); sub1 = a[2]
  if (b0 == "claude" || b0 == "codex") ag = b0
  else if ((b0 == "node" || b0 == "bun") && a[2] ~ /claude-code\/cli\.m?js$/) { ag = "claude"; sub1 = a[3] }
  else return ""
  if (sub1 ~ /^(daemon|bg-pty-host|bg-spare|--bg-pty-host|--bg-spare|mcp|mcp-server|app-server|setup-token|update|doctor|install|login|logout|completion)$/) return "helper"
  return ag
}
function sid_of(args,   a, n, i, s) {
  n = split(args, a, " ")
  for (i = 2; i < n; i++) if ((a[i] == "--session-id" || a[i] == "--resume" || a[i] == "-r") && a[i + 1] ~ /^[0-9a-fA-F-]+$/ && length(a[i + 1]) == 36) return a[i + 1]
  for (i = 2; i <= n; i++) if (a[i] ~ /^--(session-id|resume)=[0-9a-fA-F-]+$/) { s = a[i]; sub(/^[^=]*=/, "", s); if (length(s) == 36) return s }
  return ""
}
# term_load : les apps de terminal posées (lot 02 du couloir app-treelab : le fork de cmux) — paquets et noms de commande de TOP_TERM_APPS et
# TOP_TERM_CLIS (terminal_found_set, posés par top_terminals), une ligne chacun ; classées comme cmux, jamais coupables
function term_load(   n, a, i) {
  if (TERM_LOADED) return
  TERM_LOADED = 1; TERM_N = 0
  n = split(ENVIRON["TOP_TERM_APPS"], a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") TERM_APP[++TERM_N] = a[i] "/"
  n = split(ENVIRON["TOP_TERM_CLIS"], a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") TERM_CLI[a[i]] = 1
}
function family_of(args, ag,   a, b0, i) {
  if (ag == "helper") return "agent-helper"
  split(args, a, " "); b0 = top_base(a[1])
  if (args ~ /cmux-cua/) return "cmux-cua"
  if (args ~ /\/cmux\.app\// || b0 == "cmux") return "cmux"
  term_load(); if (b0 in TERM_CLI) return "cmux"
  for (i = 1; i <= TERM_N; i++) if (index(args, TERM_APP[i]) > 0) return "cmux"
  if (args ~ /ms-playwright|chrome-headless-shell|Google Chrome for Testing|Chromium\.app|chromedriver|puppeteer/) return "test-browser"
  if (args ~ /\/Google Chrome\.app\//) return "chrome"
  if (args ~ /Virtualization\.framework|com\.apple\.Virtualization|qemu-system|limactl|vfkit|OrbStack|Docker\.app|com\.docker\./) return "vm"
  if (b0 ~ /^(node|bun|deno|npm|npx|pnpm|yarn|tsx)$/) return "node"
  return "other"
}
function name_of(args,   a, n, b0, head, i) {
  if (args ~ /^<defunct>/) return "<defunct>"
  n = split(args, a, " "); b0 = top_base(a[1])
  if (b0 ~ /^(npm|npx|pnpm|yarn)$/ && n >= 3 && a[2] ~ /^(exec|run|x|dlx)$/) return b0 " " top_base(a[3])
  if (b0 ~ /^(node|bun|deno|python[0-9.]*|ruby|perl|sh|bash|zsh|npm|npx|pnpm|yarn)$/ && n >= 2 && a[2] !~ /^-/) return b0 " " top_base(a[2])
  head = args; sub(/ -.*$/, "", head)   # la commande avant sa première option : un argument (JSON de --mcp-config) ne la nomme jamais
  if ((i = index(head, ".app/Contents/MacOS/")) > 0) return substr(head, i + 20)
  if (substr(head, 1, 1) == "/") return top_base(head)
  return b0
}
function iso_epoch(t,   y, m, d) {
  if (t !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/) return ""
  y = substr(t, 1, 4) + 0; m = substr(t, 6, 2) + 0; d = substr(t, 9, 2) + 0
  if (m <= 2) { y--; m += 12 }
  return (365 * y + int(y / 4) - int(y / 100) + int(y / 400) + int((153 * (m - 3) + 2) / 5) + d - 719469) * 86400 \
    + substr(t, 12, 2) * 3600 + substr(t, 15, 2) * 60 + substr(t, 18, 2)
}
function etime_s(e,   d, i, n, p, s) {
  d = 0; if ((i = index(e, "-")) > 0) { d = substr(e, 1, i - 1); e = substr(e, i + 1) }
  n = split(e, p, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + p[i]
  return d * 86400 + s
}
'

# top_projects → « nom<TAB>racine<TAB>docs<TAB>base<TAB>staging<TAB>remote » par projet enregistré, une lecture pour toutes les
# configurations ; même règle que config_get : la première valeur d'une clé compte. Valeur vide : « - » (read avec IFS tabulation
# fusionne deux tabulations : un champ vide décalerait les suivants).
top_projects() {
  local f; local -a files=()
  for f in "$LAB_PROJECTS"/*/config; do [ -f "$f" ] && files+=("$f"); done
  [ "${#files[@]}" -gt 0 ] || return 0
  LC_ALL=C awk '
    function val(k) { return (v[k] == "") ? "-" : v[k] }
    function out() { if (v["root"] != "") print p "\t" v["root"] "\t" val("docs") "\t" val("base") "\t" val("staging") "\t" val("remote") }
    FNR == 1 { if (p != "") out(); p = FILENAME; sub(/\/config$/, "", p); sub(/.*\//, "", p); split("", v) }
    { k = $0; sub(/=.*/, "", k); if (index($0, "=") && !(k in v)) v[k] = substr($0, length(k) + 2) }
    END { if (p != "") out() }' "${files[@]}"
}

# top_layout <projets> → sections #P (projets), #W (couloirs présents) et #L (verrous : projet, couloir ou main, pid), lus sans
# fork : un verrou est un fichier KEY=value, sa ligne pid= suffit ; mort ou vivant se juge plus loin sur la table de ps.
top_layout() {
  local p root rest wt lane lock line; local -a roots=() names=()
  while IFS=$'\t' read -r p root rest; do [ -n "$p" ] || continue; names+=("$p"); roots+=("$root"); done < <(printf '%s\n' "$1")
  printf '#P\n'; for p in "${!names[@]}"; do printf '%s\t%s\n' "${names[p]}" "${roots[p]}"; done
  printf '#W\n'
  for p in "${!names[@]}"; do
    for wt in "${roots[p]}"/.worktrees/*/; do [ -d "$wt" ] || continue; wt="${wt%/}"; printf '%s\t%s\n' "${names[p]}" "${wt##*/}"; done
  done
  printf '#L\n'
  for p in "${!names[@]}"; do
    root="${roots[p]}"
    for lock in "$root/.lab/session.lock" "$root"/.worktrees/*/.lab/session.lock; do
      [ -f "$lock" ] || continue
      lane=main; case "$lock" in "$root/.worktrees/"*) lane="${lock#"$root/.worktrees/"}"; lane="${lane%%/*}" ;; esac
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in pid=*) printf '%s\t%s\t%s\n' "${names[p]}" "$lane" "${line#pid=}"; break ;; esac
      done <"$lock"
    done
  done
}

# top_attach : sections #A (pid, agent, session), #C (dossier courant), #O (journal ouvert par codex), #P, #W, #L sur l'entrée →
# « pid<TAB>projet<TAB>couloir<TAB>via<TAB>état<TAB>session<TAB>journal candidat » (session ou journal inconnus : « - »). Ordre de preuve : verrou du couloir tenu par ce
# pid (via=lock), sinon dossier courant sous <racine>/.worktrees/<couloir> (via=cwd ; couloir absent : état gone), sinon checkout
# principal (couloir main), sinon hors projet (none). Un verrou dont le pid n'est plus dans la table ne rattache rien : la session
# du couloir est retrouvée par son dossier courant. Journal claude : <claude>/projects/<dossier courant, non alphanumériques en
# tirets>/<session>.jsonl ; codex : le .jsonl qu'il tient ouvert.
top_attach() {
  LC_ALL=C awk -F '\t' -v ch="$(claude_home)" '
    /^#[A-Z]$/ { sec = substr($0, 2); next }
    sec == "A" { na++; ap[na] = $1; ag[$1] = $2; sid[$1] = $3; next }
    sec == "C" { cwd[$1] = $2; next }
    sec == "O" { if (!($1 in open)) open[$1] = $2; next }
    sec == "P" { np++; pn[np] = $1; pr[np] = $2; next }
    sec == "W" { wt[$1 "\t" $2] = 1; next }
    sec == "L" { lp[$3] = $1; ll[$3] = $2; next }
    END {
      for (i = 1; i <= na; i++) {
        p = ap[i]; proj = "none"; lane = "none"; via = "none"; st = "ok"; c = cwd[p]; cp = ""; cl = ""; cs = "ok"
        if (c != "") {
          best = 0
          for (j = 1; j <= np; j++) { r = pr[j]; if ((c == r || index(c, r "/") == 1) && length(r) > best) { best = length(r); bj = j } }
          if (best) {
            cp = pn[bj]; cl = "main"; rest = substr(c, best + 2)
            if (index(rest, ".worktrees/") == 1) { cl = substr(rest, 12); sub(/\/.*$/, "", cl); if (cl == "") cl = "main" }
            if (cl != "main" && !((cp "\t" cl) in wt)) cs = "gone"
          }
        }
        # un verrou dont le pid a été repris par une session d un autre couloir ne prouve rien : le dossier courant tranche
        if ((p in lp) && (cp == "" || (cp == lp[p] && cl == ll[p]))) { proj = lp[p]; lane = ll[p]; via = "lock" }
        else if (cp != "") { proj = cp; lane = cl; via = "cwd"; st = cs }
        j = ""
        if (ag[p] == "codex") j = open[p]
        else if (sid[p] != "" && c != "") { s = c; gsub(/[^A-Za-z0-9]/, "-", s); j = ch "/projects/" s "/" sid[p] ".jsonl" }
        print p "\t" proj "\t" lane "\t" via "\t" st "\t" (sid[p] == "" ? "-" : sid[p]) "\t" (j == "" ? "-" : j)
      }
    }'
}

# top_watch_merged <projet> <couloir> <worktree> : rc 0 si le veilleur de lab close de la branche courante du couloir l'a fusionné
# (issue merged : fusion faite, retrait en attente). Seul le fichier de la branche courante compte, comme pour lane_rank : ceux des
# anciens couloirs du même nom restent sous state/watch ; « closed » prouve le retrait de leur dossier, un dossier présent est donc
# un couloir neuf. Lecture sans fork : .git du worktree, HEAD de son dossier d'administration, fichier du veilleur (lib/watch.sh).
top_watch_merged() {
  local wt="$3" gd head="" line="" action="" issue="" f
  [ -d "$LAB_STATE/watch/$1/$2" ] || return 1
  if [ -d "$wt/.git" ]; then gd="$wt/.git"
  elif [ -f "$wt/.git" ]; then
    IFS= read -r line <"$wt/.git" || [ -n "$line" ] || return 1
    gd="${line#gitdir: }"; case "$gd" in /*) ;; *) gd="$wt/$gd" ;; esac
  else return 1; fi
  [ -f "$gd/HEAD" ] || return 1
  IFS= read -r head <"$gd/HEAD" || [ -n "$head" ] || return 1
  case "$head" in "ref: refs/heads/"?*) head="${head#ref: refs/heads/}" ;; *) return 1 ;; esac
  f="$LAB_STATE/watch/$1/$2/${head//\//+}"
  [ -f "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do case "$line" in action=*) action="${line#action=}" ;; issue=*) issue="${line#issue=}" ;; esac; done <"$f"
  [ "$action" = close ] && [ "$(lang_code "$issue")" = merged ]
}

# top_phases <projets> <rattachements> <fast 0|1> → « projet<TAB>couloir<TAB>phase<TAB>fusionné 0|1 » par couloir présent qui porte
# une session. Seule la phase « acceptance passed » change une proposition, et elle exige une section de recette dans une fiche du
# couloir : un seul grep sur les fiches de tous ces couloirs choisit ceux que lane_phase (lib/recette.sh) relit ; les autres gardent
# une phase vide (non lue), comme tous sous --fast. lane_phase coûtait 170 ms par couloir sur le poste réel (35 couloirs : 5,95 s,
# rapport de preuves). P_* posés depuis la seule lecture des configurations, jamais load_project (17 lectures par projet).
top_phases() {
  local fast="${3:-0}" p lane root docs base staging remote merged phase lots f j hits=$'\n' n=0 i np=0
  local -a pn=() pr=() pd=() lp=() ll=() lr=() ld=() lo=() files=()
  while IFS=$'\t' read -r p root docs base staging remote; do
    [ -n "$p" ] || continue; pn[np]="$p"; pr[np]="$root"; pd[np]="$docs|$base|$staging|$remote"; np=$((np + 1))
  done < <(printf '%s\n' "$1")
  while IFS=$'\t' read -r p lane; do
    [ -n "$p" ] || continue
    j=0; while [ "$j" -lt "$np" ] && [ "${pn[j]}" != "$p" ]; do j=$((j + 1)); done
    [ "$j" -lt "$np" ] || continue
    root="${pr[j]}"; docs="${pd[j]%%|*}"
    if [ "$docs" = repo ]; then lots="$root/.worktrees/$lane/docs/lots/$lane"; else lots="$LAB_PROJECTS/$p/docs/lots/$lane"; fi
    lp[n]="$p"; ll[n]="$lane"; lr[n]="$root"; ld[n]="${pd[j]}"; lo[n]="$lots"; n=$((n + 1))
    [ "$fast" = 0 ] || continue
    if [ -d "$lots" ]; then for f in "$lots"/*.md; do [ ! -f "$f" ] || files+=("$f"); done
    elif [ -d "${lots%/*}" ]; then hits="$hits$lots"$'\n'; fi   # disposition ancienne (fiches à plat dans lots/) : lane_phase tranche
  done < <(printf '%s\n' "$2" | awk -F '\t' '$3 != "main" && $3 != "none" && $5 == "ok" { print $2 "\t" $3 }' | LC_ALL=C sort -u)
  if [ "${#files[@]}" -gt 0 ]; then   # dossiers de fiches dont une fiche porte une section de recette
    hits="$hits$(LC_ALL=C grep -l -E "^## ($(lang_section_re 'Recette du couloir'))[[:space:]]*\$" "${files[@]}" 2>/dev/null | sed 's|/[^/]*$||')"$'\n'
  fi
  i=0
  # shellcheck disable=SC2034 # P_* lus par lane_phase et ses lecteurs de fiches (lib/recette.sh, lib/docs.sh)
  while [ "$i" -lt "$n" ]; do
    p="${lp[i]}"; lane="${ll[i]}"; root="${lr[i]}"; phase=""
    case "$hits" in
      *$'\n'"${lo[i]}"$'\n'*)
        docs="${ld[i]%%|*}"; base="${ld[i]#*|}"; staging="${base#*|}"; remote="${staging#*|}"; base="${base%%|*}"; staging="${staging%%|*}"
        [ "$docs" != - ] || docs=local; [ "$base" != - ] || base=main; [ "$staging" != - ] || staging=""; [ "$remote" != - ] || remote=origin
        P_NAME="$p"; P_ROOT="$root"; P_DOCS="$docs"; P_BASE="$base"; P_STAGING="$staging"; P_REMOTE="$remote"
        phase="$(lane_phase "$root/.worktrees/$lane" 2>/dev/null || true)" ;;
    esac
    merged=0; if top_watch_merged "$p" "$lane" "$root/.worktrees/$lane"; then merged=1; fi
    printf '%s\t%s\t%s\t%s\n' "$p" "$lane" "$phase" "$merged"
    i=$((i + 1))
  done
}

# top_journals <rattachements> → « pid<TAB>epoch » du dernier message user ou assistant de chaque journal trouvé ; une seule
# lecture tail -c bornée pour tous (en-têtes « ==> fichier <== », /dev/null en plus pour les avoir même avec un seul journal).
top_journals() {
  local pid sid cand f g map="" ch; local -a files=()
  ch="$(claude_home)"
  while IFS=$'\t' read -r pid _ _ _ _ sid cand; do
    [ -n "$pid" ] || continue; f=""; [ "$sid" != - ] || sid=""; [ "$cand" != - ] || cand=""
    if [ -n "$cand" ] && [ -f "$cand" ]; then f="$cand"
    elif [ -n "$sid" ]; then for g in "$ch"/projects/*/"$sid".jsonl; do if [ -f "$g" ]; then f="$g"; break; fi; done; fi
    [ -n "$f" ] || continue
    files+=("$f"); map="$map$pid"$'\t'"$f"$'\n'
  done < <(printf '%s\n' "$1")
  [ "${#files[@]}" -gt 0 ] || return 0
  { tail -c "$TOP_TAIL_BYTES" -- "${files[@]}" /dev/null 2>/dev/null || true; } | TOP_MAP="$map" LC_ALL=C awk "$TOP_AWK_LIB"'
    # claude : horodatage qui suit le type au premier niveau ("type":"user|assistant","uuid":…,"timestamp":…) ; codex : premier
    # horodatage d une ligne response_item de rôle user ou assistant, ou d un événement user_message ou agent_message
    function msg_ts(l,   s) {
      if (match(l, /"type":"(user|assistant)"/)) s = substr(l, RSTART, 240)
      else if (l ~ /"type":"response_item"/ && l ~ /"role":"(user|assistant)"/ || l ~ /"type":"(user_message|agent_message)"/) s = l
      else return ""
      if (match(s, /"timestamp":"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) return substr(s, RSTART + 13, 19)
      return ""
    }
    BEGIN { n = split(ENVIRON["TOP_MAP"], rows, "\n"); for (i = 1; i <= n; i++) if (split(rows[i], kv, "\t") == 2) owner[kv[2]] = kv[1] }
    /^==> .* <==$/ { f = substr($0, 5, length($0) - 8); cur = (f in owner) ? owner[f] : ""; next }
    cur == "" { next }
    { t = msg_ts($0); if (t != "") last[cur] = t }
    END { for (p in last) print p "\t" iso_epoch(last[p]) }'
}

# top_envs <pids séparés par des virgules> → « pid<TAB>onglet<TAB>espace » des sessions lancées dans cmux, lus dans leur environnement
top_envs() {
  { LC_ALL=en_US.UTF-8 ps -axwwE -o pid=,command= 2>/dev/null || true; } | LC_ALL=C awk -v pids=",$1," '
    function last(re, skip,   s, v) { s = $0; v = ""; while (match(s, re)) { v = substr(s, RSTART + skip, RLENGTH - skip); s = substr(s, RSTART + RLENGTH) } return v }
    index(pids, "," $1 ",") { sf = last("CMUX_SURFACE_ID=[^ ]+", 16); if (sf != "") print $1 "\t" sf "\t" last("CMUX_WORKSPACE_ID=[^ ]+", 18) }'
}

# top_lane_orphans <ps> <projets> → « pid<TAB>projet<TAB>couloir » (lot 02 de fermeture-propre) : processus hors agent du compte,
# repris par launchd (parent 1) depuis TOP_ORPHAN_AGE, familles node ou other, dont le dossier courant est sous
# <racine>/.worktrees/<couloir>, présent ou retiré (lsof garde le chemin d'un dossier supprimé, mesuré) : serveur d'aperçu ou de
# dev laissé par une session finie ; jamais le parent d'une session (tmux, orchestrateur : guard() de top_snapshot le protège). Une
# passe lsof sur ces seuls candidats ; <projets> : lignes « nom<TAB>racine[<TAB>…] ».
top_lane_orphans() {
  local pids
  pids="$(printf '%s\n' "$1" | LC_ALL=C awk -v uid="$(id -u)" -v age="$TOP_ORPHAN_AGE" "$TOP_AWK_LIB"'
    ps_parse($0) { n++; ORD[n] = P_PID; PP[P_PID] = P_PPID; UID[P_PID] = P_UID; ET[P_PID] = etime_s(P_ET); ARGS[P_PID] = P_ARGS; AG[P_PID] = agent_of(P_ARGS) }
    END {
      for (i = 1; i <= n; i++) if (AG[ORD[i]] == "claude" || AG[ORD[i]] == "codex") {
        q = PP[ORD[i]]; d = 0; while (q != "" && q != "0" && q != "1" && d < 64) { AP[q] = 1; q = PP[q]; d++ }
      }
      for (i = 1; i <= n; i++) {
        p = ORD[i]; a = AG[p]; f = family_of(ARGS[p], a)
        if (PP[p] == "1" && UID[p] == uid && ET[p] >= age && a != "claude" && a != "codex" && (f == "node" || f == "other") && !(p in AP))
          printf "%s%s", (m++ ? "," : ""), p
      }
    }')"
  [ -n "$pids" ] || return 0
  { LC_ALL=en_US.UTF-8 lsof -a -d cwd -p "$pids" -Fpfn 2>/dev/null || true; } | TOP_PROJ="$2" LC_ALL=C awk '
    BEGIN { n = split(ENVIRON["TOP_PROJ"], rows, "\n"); for (i = 1; i <= n; i++) if (split(rows[i], f, "\t") >= 2) { np++; PN[np] = f[1]; PR[np] = f[2] "/.worktrees/" } }
    /^p/ { p = substr($0, 2); next }
    /^n/ { d = substr($0, 2)
      for (j = 1; j <= np; j++) if (index(d, PR[j]) == 1) { l = substr(d, length(PR[j]) + 1); sub(/\/.*$/, "", l); if (l != "") { print p "\t" PN[j] "\t" l; break } } }'
}

# top_footprints <ps> → « pid octets » ; rc 1 si la sonde est indisponible (pas de python3, libproc illisible, sortie vide).
top_footprints() {
  local out
  command -v python3 >/dev/null 2>&1 || return 1
  out="$(printf '%s\n' "$1" | LC_ALL=C awk '{ print $1 }' | python3 -c "$TOP_FOOTPRINT_PY" 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# top_snapshot <fast 0|1> [cible] → blocs KEY=value : MACHINE, puis SESSION, FAMILY, CUT et HIBERNATED (registre des gestes du
# lot 02, sans les onglets qui portent de nouveau une session vivante) ; avec une cible (pid ou famille), un bloc PROBE dit si elle
# existe et pourquoi elle est protégée — les gestes nomment ainsi leur refus. Lecture pure : aucun fichier écrit ; git sans
# verrou optionnel ni rafraîchissement d'index (git diff HEAD réécrit l'index d'un fichier suivi touché même sous GIT_OPTIONAL_LOCKS=0).
# ps et lsof sous une locale UTF-8 : sous C, ils écrivent les octets non ASCII en M-… et \xNN (mesuré), un dossier accentué ne serait
# plus reconnu ; les jointures awk restent sous C, en octets.
# top_terminals : TOP_TERM_APPS et TOP_TERM_CLIS exportés pour les awk de top (term_load) — cmux, le fork et toute app de terminal posée
top_terminals() { terminal_found_set; export TOP_TERM_APPS="$TERMINAL_FOUND" TOP_TERM_CLIS="$TERMINAL_FOUND_CLIS"; }
top_snapshot() {
  top_terminals
  local fast="$1" probe="${2:-}" ps_out agents pids codex_pids cwds opened envs projects lorph layout attach phases journals mem="" msource=footprint
  local idle_h now_iso hib gc="${GIT_CONFIG_COUNT:-0}" sp sa sdir; local -a sfiles=()
  export GIT_OPTIONAL_LOCKS=0 "GIT_CONFIG_KEY_$gc=diff.autoRefreshIndex" "GIT_CONFIG_VALUE_$gc=false" GIT_CONFIG_COUNT=$((gc + 1))
  ps_out="$(LC_ALL=en_US.UTF-8 ps -axww -o pid=,ppid=,uid=,stat=,rss=,%cpu=,etime=,args= 2>/dev/null)" || true
  [ -n "$ps_out" ] || die "process table unreadable (ps): lab top needs it to see the sessions"
  agents="$(printf '%s\n' "$ps_out" | LC_ALL=C awk -v self="$$" "$TOP_AWK_LIB"'
    ps_parse($0) && P_PID != self { a = agent_of(P_ARGS); if (a == "claude" || a == "codex") print P_PID "\t" a "\t" sid_of(P_ARGS) }')"
  # identifiant courant d'une session claude : <claude>/sessions/<pid>.json, tenu à jour par Claude Code après /clear et /resume ;
  # la ligne de commande garde celui du lancement (9 sessions sur 46 divergeaient sur le poste réel). Sans ce fichier : la ligne.
  sdir="$(claude_home)/sessions"
  while IFS=$'\t' read -r sp sa _; do
    if [ "$sa" = claude ] && [ -f "$sdir/$sp.json" ]; then sfiles+=("$sdir/$sp.json"); fi
  done < <(printf '%s\n' "$agents")
  # le même fichier porte status (idle, busy) : quatrième colonne, lue par les gestes du lot 02 (une session busy n'est jamais coupée) ;
  # cinquième, l'heure du dernier changement de statut (statusUpdatedAt, en secondes) : elle date une session idle dont le dernier
  # message est hors de la fin lue (Claude Code 2.1.309 écrit une ligne prompt_snapshot de 127 Ko après le premier échange)
  if [ "${#sfiles[@]}" -gt 0 ]; then
    agents="$(TOP_AGENTS="$agents" LC_ALL=C awk '
      { p = FILENAME; sub(/.*\//, "", p); sub(/\.json$/, "", p)
        if (match($0, /"sessionId":"[0-9A-Fa-f-]+"/)) cur[p] = substr($0, RSTART + 13, RLENGTH - 14)
        if (match($0, /"status":"[a-z_]+"/)) st[p] = substr($0, RSTART + 10, RLENGTH - 11)
        if (match($0, /"statusUpdatedAt":[0-9][0-9][0-9][0-9]+/)) su[p] = substr($0, RSTART + 18, RLENGTH - 21) }
      END {
        n = split(ENVIRON["TOP_AGENTS"], rows, "\n")
        for (i = 1; i <= n; i++) {
          if (split(rows[i], f, "\t") < 2) continue
          c = (f[2] == "claude" && (f[1] in cur)); print f[1] "\t" f[2] "\t" (c ? cur[f[1]] : f[3]) (c && (f[1] in st) ? "\t" st[f[1]] "\t" su[f[1]] : "")
        }
      }' "${sfiles[@]}")"
  fi
  pids="$(printf '%s\n' "$agents" | awk -F '\t' 'NF { printf "%s%s", (n++ ? "," : ""), $1 }')"
  codex_pids="$(printf '%s\n' "$agents" | awk -F '\t' '$2 == "codex" { printf "%s%s", (n++ ? "," : ""), $1 }')"
  cwds=""; opened=""; envs=""
  if [ -n "$pids" ]; then
    # onglet cmux de chaque session : son environnement (ps -E l'écrit après la commande, la dernière occurrence fait foi), une passe
    # sur tout le poste filtrée ici — 0,14 s pour 1 140 processus sous une charge de 39, quand « ps -p <49 sessions> » en prenait
    # 0,5 à 1,6 (mesures du lot 02). Illisible (autre compte, enfant direct de login) : hors cmux, jamais endormie ni fermée par lab.
    # Lancée en parallèle (descripteur 8, lu après les journaux) : 0,11 s de ps et d'awk sur 2,4 Mo d'environnements, en série,
    # sortaient --fast de son budget (0,55 s contre 0,5). Une fonction, jamais le texte du tuyau : bash 3.2 relit le texte d'une
    # substitution de processus et y développe les accolades ({ … pid=,command= … } devenait une erreur de syntaxe muette).
    exec 8< <(top_envs "$pids")
    cwds="$({ LC_ALL=en_US.UTF-8 lsof -a -d cwd -p "$pids" -Fpfn 2>/dev/null || true; } | awk '/^p/ { p = substr($0, 2) } /^n/ { print p "\t" substr($0, 2) }')"
  fi
  if [ -n "$codex_pids" ]; then
    opened="$({ LC_ALL=en_US.UTF-8 lsof -a -p "$codex_pids" -Fpfn 2>/dev/null || true; } | awk '/^p/ { p = substr($0, 2) } /^n.*\.jsonl$/ { print p "\t" substr($0, 2) }')"
  fi
  projects="$(top_projects)"
  lorph="$(top_lane_orphans "$ps_out" "$projects")"
  layout="$(top_layout "$projects")"
  attach="$(printf '#A\n%s\n#C\n%s\n#O\n%s\n%s\n' "$agents" "$cwds" "$opened" "$layout" | top_attach)"
  phases="$(top_phases "$projects" "$attach" "$fast")"
  journals="$(top_journals "$attach")"
  if [ -n "$pids" ]; then envs="$(cat <&8)"; exec 8<&-; fi
  if [ "$fast" = 1 ]; then msource=rss
  elif ! mem="$(top_footprints "$ps_out")"; then
    msource=rss; mem=""; warn "memory footprint unreadable (python3 with libproc): resident memory shown instead, marked approximate"
  fi
  idle_h="$(global_config_get top_idle_hours)"
  case "$idle_h" in
    '') idle_h=24 ;;
    *[!0-9]*) warn "top_idle_hours=$idle_h in $LAB_HOME/config: whole hours expected, 24 used"; idle_h=24 ;;
  esac
  now_iso="${LAB_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  hib=""; [ ! -f "$LAB_STATE/top/hibernated" ] || hib="$(cat "$LAB_STATE/top/hibernated")"
  {
    printf '#T\n%s\n#H\n%s\n#J\n%s\n#M\n%s\n' "$attach" "$phases" "$journals" "$mem"
    printf '#E\n%s\n#Q\n%s\n#B\n%s\n#D\n%s\n' "$envs" "$agents" "$hib" "$lorph"
    printf '#Y\n'; LC_ALL=C sysctl hw.memsize hw.ncpu vm.swapusage vm.loadavg kern.memorystatus_vm_pressure_level kern.memorystatus_level 2>/dev/null || true
    printf '#V\n'; LC_ALL=C vm_stat 2>/dev/null || true
    printf '#R\n'; LC_ALL=C pmset -g therm 2>/dev/null || true
    printf '#S\n%s\n' "$ps_out"
  } | LC_ALL=C awk -v self="$$" -v uid="$(id -u)" -v fast="$fast" -v msource="$msource" -v idle_h="$idle_h" -v now_iso="$now_iso" \
      -v fam_pct="$TOP_FAMILY_MEM_PCT" -v fam_cpu="$TOP_FAMILY_CPU" -v tool_cpu="$TOP_TOOL_CPU" -v tool_age="$TOP_TOOL_AGE" -v zmin="$TOP_ZOMBIE_MIN" \
      -v orphan_age="$TOP_ORPHAN_AGE" -v stop_s="$TOP_STOP_WAIT" -v keep="$(global_config_get top_keep)" -v probe="$probe" "$TOP_AWK_LIB"'
    function mb(x) { return int(x + 0.5) }
    function cpu1(c) { return sprintf("%.1f", c) }
    function mem_of(p) { if (!fast && (p in fp)) { approx = 0; return fp[p] / 1048576 } approx = 1; return RSS[p] / 1024 }
    function hours(s) { return (s >= 172800) ? int(s / 86400) "d" : (s >= 3600) ? int(s / 3600) "h" : int(s / 60) "m" }
    function size(m) { return (m >= 1024) ? sprintf("%.1fG", m / 1024) : mb(m) "M" }
    function unit_mb(v,   n) { n = v + 0; if (v ~ /G/) n *= 1024; else if (v ~ /K/) n /= 1024; return mb(n) }
    function owner(p,   q, d) { q = PP[p]; d = 0; while (q != "" && q != "0" && q != "1" && d < 64) { if (AG[q] == "claude" || AG[q] == "codex") return q; q = PP[q]; d++ } return "" }
    function mine(p,   q, d) { q = p; d = 0; while (q != "" && q != "0" && d < 64) { if (q == self) return 1; q = PP[q]; d++ } return 0 }
    function block(s) { out = out s "\n" }
    # cut : une proposition ; ID est ce que reçoivent --cut et --explain (pid, ou nom de famille), ACTION la commande du clic
    # (explication seule quand lab ne sait pas agir), IMPACT ce que la coupure implique, dit avant d agir
    function cut(reason, gesture, pid, id, target, detail, impact, m, ap, extra) {
      ncut++; CUTP[pid] = 1
      cuts = cuts "BLOCK=CUT\nREASON=" reason "\nGESTURE=" gesture "\nPID=" pid "\nID=" id "\nTARGET=" target "\n" extra "DETAIL=" detail \
        "\nIMPACT=" impact "\nACTION=lab top " ((gesture == "explain") ? "--explain " : "--cut ") id "\nEXPLAIN=lab top --explain " id \
        "\nMEM=" mb(m) "\nMEM_APPROX=" (ap ? "yes" : "no") "\n\n"
    }
    # guard <pid> <session 0|1> → pourquoi lab ne propose ni ne coupe jamais ce processus ; vide : rien ne le protège. La famille
    # n est jugée que hors session : le --mcp-config d une session nomme souvent cmux-cua.
    function guard(p, sess,   f, a) {
      if (mine(p)) return "lab top itself"
      if (p in ANC) return "the calling session or one of its parents"
      if (UID[p] == "0") return "root process"
      if (UID[p] != uid) return "process of another account"
      if (!sess) {
        f = family_of(ARGS[p], AG[p])
        if (f == "cmux") return "cmux itself"
        if (f == "cmux-cua" || f == "agent-helper") return f
        if (f in KEEP) return "family named in top_keep="
        if (p in AP) return "parent of an agent session"   # shell d un onglet, tmux, orchestrateur : l arrêter tuerait ses agents
      }
      split(ARGS[p], a, " ")
      if ((top_base(a[1]) in KEEP) || (name_of(ARGS[p]) in KEEP)) return "named in top_keep="
      return ""
    }
    function stopping() { return "; TERM, then KILL after " stop_s " s" }
    # au repos selon son fichier de session : idle, ou busy (passager, refusé par son nom au clic), ou sans statut (codex) ; waiting
    # (question ou permission en suspens) et les autres ne s endorment pas
    function at_rest(p) { return !(p in QS) || QS[p] == "idle" || QS[p] == "busy" || QS[p] == "unknown" }
    # shell lancé par l agent : une commande de fond tant qu il vit (règle de cmux, agentBackgroundWorkProcessIDs)
    function shell_of(a,   w) { split(a, w, " "); w[1] = top_base(w[1]); sub(/^-/, "", w[1]); return w[1] ~ /^(sh|bash|zsh|fish|dash|ksh|tcsh|csh)$/ }
    BEGIN { FS = "\t"; nk = split(keep, KK, ","); for (i = 1; i <= nk; i++) { k = KK[i]; gsub(/^[ \t]+|[ \t]+$/, "", k); if (k != "") KEEP[k] = 1 } }
    /^#[A-Z]$/ { sec = substr($0, 2); next }
    sec == "T" { if (NF >= 5) { TP[$1] = $2; TL[$1] = $3; TV[$1] = $4; TS[$1] = $5; TI[$1] = ($6 == "-") ? "" : $6 } next }
    sec == "H" { if (NF >= 2) { PH[$1 "\t" $2] = $3; MG[$1 "\t" $2] = $4 } next }
    sec == "J" { if (NF >= 2) JT[$1] = $2; next }
    sec == "M" { if (split($0, a, " ") == 2) fp[a[1]] = a[2]; next }
    sec == "E" { if (NF >= 2) { SF[$1] = $2; SW[$1] = $3 } next }
    sec == "Q" { if (NF >= 4) QS[$1] = $4; if (NF >= 5 && $5 != "") QU[$1] = $5; next }
    sec == "B" { if (NF >= 8) { nb++; BR[nb] = $0 } next }
    sec == "D" { if (NF >= 3) WD[$1] = $2 "/" $3; next }   # orphelin dans un dossier de couloir : projet/couloir
    sec == "Y" { k = $0; sub(/:.*/, "", k); v = $0; sub(/^[^:]*:[ \t]*/, "", v); SY[k] = v; next }
    sec == "V" {
      if (match($0, /page size of [0-9]+/)) page = substr($0, RSTART + 13, RLENGTH - 13)
      v = $0; sub(/^.*:[ \t]*/, "", v); sub(/\.$/, "", v)
      if ($0 ~ /^Pages stored in compressor:/) stored = v; else if ($0 ~ /^Pages occupied by compressor:/) occupied = v
      next
    }
    sec == "R" {
      if (match($0, /CPU_Speed_Limit[ \t]*=[ \t]*[0-9]+/)) { v = substr($0, RSTART, RLENGTH); sub(/.*=[ \t]*/, "", v); speed = v + 0 }
      if (match($0, /[Tt]hermal warning level[^0-9]*[0-9]+/)) { v = substr($0, RSTART, RLENGTH); sub(/^[^0-9]*/, "", v); twarn = v + 0 }
      if ($0 ~ /No thermal warning level has been recorded/) nominal = 1
      next
    }
    sec == "S" {
      if (!ps_parse($0)) next
      n++; ORD[n] = P_PID; PP[P_PID] = P_PPID; UID[P_PID] = P_UID; ST[P_PID] = P_STAT; RSS[P_PID] = P_RSS; CPU[P_PID] = P_CPU
      ET[P_PID] = etime_s(P_ET); ARGS[P_PID] = P_ARGS; AG[P_PID] = agent_of(P_ARGS)
      next
    }
    END {
      now = iso_epoch(now_iso); idle_s = idle_h * 3600
      ram = SY["hw.memsize"] / 1048576
      q = PP[self]; d = 0; while (q != "" && q != "0" && q != "1" && d < 64) { ANC[q] = 1; q = PP[q]; d++ }   # la session appelante, ses parents
      for (i = 1; i <= n; i++) if (AG[ORD[i]] == "claude" || AG[ORD[i]] == "codex") {   # les parents de toutes les sessions
        q = PP[ORD[i]]; d = 0; while (q != "" && q != "0" && q != "1" && d < 64) { AP[q] = 1; q = PP[q]; d++ }
      }
      # sessions, puis enfants (au plus proche ancêtre session), zombies et familles ; le lab top en cours et ses sondes sont hors compte
      for (i = 1; i <= n; i++) {
        p = ORD[i]; if (mine(p)) continue
        if (AG[p] == "claude" || AG[p] == "codex") { ns++; SESS[ns] = p; SM[p] = mem_of(p); SA[p] = approx; continue }
        if (ST[p] ~ /^Z/) { if (!(PP[p] in ZC)) { nz++; ZP[nz] = PP[p] } ZC[PP[p]]++; zt++; continue }
        m = mem_of(p); o = owner(p)
        if (o != "" && o == PP[p] && shell_of(ARGS[p]) && ET[o] - ET[p] > 30) BG[o]++   # plus de 30 s après l agent : pas son démarrage
        if (o != "") { KN[o]++; KM[o] += m; KC[o] += CPU[p]; if (approx) KA[o] = 1; continue }
        f = family_of(ARGS[p], AG[p]); PF[p] = f; PM[p] = m; PA[p] = approx
        if (!(f in FN)) { nf++; FL[nf] = f }
        FN[f]++; FM[f] += m; FC[f] += CPU[p]; if (approx) FA[f] = 1
        if (m >= FB[f]) { FB[f] = m; FX[f] = name_of(ARGS[p]); FP[f] = p }
        # VM Lima : l instance est le dernier mot de « limactl hostagent --pidfile <LIMA_HOME>/<instance>/ha.pid … <instance> » ; son
        # LIMA_HOME se lit sur ce --pidfile (Colima range ses VM sous ~/.colima/_lima : hors de lui, limactl répond « No instance found »)
        # hôte du seul compte courant, instance au nom simple, dossier absolu sans virgule : un autre processus ne pilote jamais limactl
        if (f == "vm" && UID[p] == uid && ARGS[p] ~ /limactl[^ ]* hostagent /) {
          k = split(ARGS[p], a, " "); h = ""; for (j = 2; j < k; j++) if (a[j] == "--pidfile") { h = a[j + 1]; sub(/\/[^\/]*\/[^\/]*$/, "", h) }
          if (h !~ /^\/[^,]+$/) h = ""
          if (a[k] ~ /^[A-Za-z0-9._-]+$/ && !(a[k] in LS)) { LS[a[k]] = 1; lima = lima (lima == "" ? "" : ",") a[k]; limah = limah (limah == "" ? "" : ",") h; if (h ~ /\/\.colima\/_lima$/) colima = 1 }
        }
        # orphelin : serveur d outils ou navigateur de test repris par launchd (sa session ou son test est fini), depuis orphan_age
        # ou serveur d aperçu ou de dev resté dans un dossier de couloir (WD, lot 02 de fermeture-propre)
        if (PP[p] == "1" && ET[p] >= orphan_age && (f == "test-browser" || ((f == "node" || f == "other") && (ARGS[p] ~ /mcp/ || (p in WD)))) && guard(p, 0) == "") { no++; OR[no] = p; OP[p] = 1 }
        else if ((f == "other" || f == "node") && UID[p] == uid && CPU[p] >= tool_cpu && ET[p] >= tool_age) { nt++; TT[nt] = p; TF[p] = f; TM[p] = m; TX[p] = approx }
      }
      # racines des seules familles lourdes arrêtables : le processus dont le parent n est pas de la même famille ; arrêter la racine
      # arrête ses aides. guard sur tout le poste coûtait 0,5 s de plus à --fast (mesuré) : jamais calculé pour les autres.
      for (f in FN) HEAVY[f] = (f == "chrome" || f == "test-browser") && !(f in KEEP) && ((ram > 0 && FM[f] >= ram * fam_pct / 100) || FC[f] >= fam_cpu)
      for (i = 1; i <= n; i++) {
        p = ORD[i]; if (!(p in PF)) continue; f = PF[p]
        if (!HEAVY[f] || ((PP[p] in PF) && PF[PP[p]] == f) || OP[p] || guard(p, 0) != "") continue
        RTS[f] = RTS[f] (RTS[f] == "" ? "" : ",") p
      }
      # sessions par mémoire décroissante (session et enfants)
      for (i = 1; i <= ns; i++) { TOT[SESS[i]] = SM[SESS[i]] + KM[SESS[i]]; if (SF[SESS[i]] != "") SFN[SF[SESS[i]]]++ }   # sessions par onglet
      for (i = 1; i <= ns; i++) for (j = i + 1; j <= ns; j++) if (TOT[SESS[j]] > TOT[SESS[i]]) { t = SESS[i]; SESS[i] = SESS[j]; SESS[j] = t }
      for (i = 1; i <= ns; i++) {
        p = SESS[i]; proj = (p in TP) ? TP[p] : "none"; lane = (p in TL) ? TL[p] : "none"; key = proj "\t" lane
        phase = ""; if (lane != "main" && lane != "none") phase = (TS[p] == "gone") ? "gone" : PH[key]
        # inactivité bornée par l âge du processus : une conversation reprise il y a 10 h n est pas inactive depuis 3 jours
        # sans message dans la fin lue, une session idle se date par son passage au repos ; busy ou inconnue : jamais
        t = ((p in JT) && JT[p] != "") ? JT[p] : ((p in QS) && (p in QU) && QS[p] == "idle") ? QU[p] : ""
        idle = "unknown"; if (t != "" && now != "") { idle = now - t; if (idle < 0) idle = 0; if (idle > ET[p] + 0) idle = ET[p] + 0 }
        block("BLOCK=SESSION\nPID=" p "\nAGENT=" AG[p] "\nPROJECT=" proj "\nLANE=" lane "\nVIA=" ((p in TV) ? TV[p] : "none") "\nPHASE=" phase \
          "\nMEM=" mb(SM[p]) "\nMEM_APPROX=" (SA[p] ? "yes" : "no") "\nCPU=" cpu1(CPU[p]) "\nAGE=" ET[p] "\nIDLE=" idle \
          "\nCHILDREN=" KN[p] + 0 "\nCHILDREN_MEM=" mb(KM[p]) "\nCHILDREN_CPU=" cpu1(KC[p]) "\nZOMBIES=" ZC[p] + 0 \
          "\nSURFACE=" SF[p] "\nWORKSPACE=" SW[p] "\nSTATUS=" ((p in QS) ? QS[p] : "unknown") "\nSESSION_ID=" TI[p] "\nBACKGROUND=" BG[p] + 0 "\n")
        if (SF[p] != "") LIVE[SF[p]] = p
        if (guard(p, 1) != "") continue
        where = (proj == "none") ? "outside projects" : ((lane == "main") ? proj " (main checkout)" : proj "/" lane)
        gain = SM[p] + KM[p]; ga = SA[p] || KA[p]
        if (phase == "gone") { r = "lane-gone"; g = "close"; d = "lane folder removed, session still alive"
          im = "its tab closes and the session ends; the lane folder is already gone; refused while the session is busy" }
        else if (phase == "acceptance passed" || MG[key] == 1) { r = "lane-done"; g = "close"
          d = (phase == "acceptance passed") ? "acceptance passed, session still alive" : "lane merged by lab close, session still alive"
          im = "its tab closes and the session ends; the conversation stays resumable and the lane files are not touched; refused if the Handoff is empty, a file is uncommitted or the session is busy" }
        # waiting : une question ou une permission attend l utilisateur, la session n est pas inactive (cmux refuse agent_busy)
        else if (idle != "unknown" && idle >= idle_s && at_rest(p)) { r = "idle"; g = "hibernate"; d = "no exchange for " hours(idle) " (threshold " idle_h "h)"
          im = "the session stops and keeps its conversation; lab top --wake " SF[p] " resumes it in the same tab" }
        else continue
        if (SF[p] == "") { im = "outside cmux: lab cannot " ((g == "close") ? "close its tab" : "put it to sleep") "; ask for an explanation, then act by hand"; g = "explain" }
        # un claude lancé dans une session hérite de son onglet : endormir ou fermer l onglet emporterait l autre
        else if (SFN[SF[p]] > 1) { im = "its tab also runs another session: lab cannot " ((g == "close") ? "close it" : "put one to sleep") " alone; ask for an explanation, then act by hand"; g = "explain" }
        cut(r, g, p, p, where, d, im, gain, ga)
      }
      # familles par mémoire décroissante ; node et « other » jamais en bloc, une famille par sa racine, une VM Lima par limactl stop
      for (i = 1; i <= nf; i++) for (j = i + 1; j <= nf; j++) if (FM[FL[j]] > FM[FL[i]]) { t = FL[i]; FL[i] = FL[j]; FL[j] = t }
      for (i = 1; i <= nf; i++) {
        f = FL[i]
        block("BLOCK=FAMILY\nFAMILY=" f "\nPROCESSES=" FN[f] "\nMEM=" mb(FM[f]) "\nMEM_APPROX=" (FA[f] ? "yes" : "no") "\nCPU=" cpu1(FC[f]) "\nLARGEST=" FX[f] "\n")
        if ((f in KEEP) || f == "other" || f == "cmux" || f == "cmux-cua" || f == "agent-helper") continue
        hd = "high use: " size(FM[f]) ", " cpu1(FC[f]) "% CPU"
        if (f == "vm") {
          d = "local virtual machine: " FN[f] " process(es), " size(FM[f]) ", " cpu1(FC[f]) "% CPU"
          if (lima != "") cut("family", "stop", "", "vm", "vm", d, "Lima VM " lima " shuts down cleanly (limactl stop): what runs inside stops; " \
            (colima ? "colima start" : "limactl start " lima) " brings it back", FM[f], FA[f], "FAMILY=vm\nLIMA=" lima "\nLIMA_HOME=" limah "\n")
          else cut("family", "explain", "", "vm", "vm", d, "virtual machine outside Lima: lab does not stop it; ask for an explanation first", FM[f], FA[f], "FAMILY=vm\n")
        } else if ((ram > 0 && FM[f] >= ram * fam_pct / 100) || FC[f] >= fam_cpu) {
          if (f == "node") {
            p = FP[f]; if (p == "" || OP[p] || guard(p, 0) != "") continue
            cut("family", "stop", p, p, name_of(ARGS[p]), hd " in the node family, this is its largest process", name_of(ARGS[p]) " stops: what it serves (a dev server, a build) goes down" stopping(), PM[p], PA[p], "FAMILY=node\n")
          } else if (RTS[f] != "") {
            cut("family", "stop", "", f, f, hd, ((f == "chrome") ? "Google Chrome quits: unsaved pages and forms are lost, tabs come back if Chrome restores its session" \
              : f " stops through its root process(es) " RTS[f] ": unsaved work in it is lost") stopping(), FM[f], FA[f], "FAMILY=" f "\nROOTS=" RTS[f] "\n")
          }
        }
      }
      for (i = 1; i <= no; i++) {
        p = OR[i]; f = PF[p]
        cut("orphan", "stop", p, p, name_of(ARGS[p]), "parent gone, running for " hours(ET[p]) ((p in WD) ? " in lane " WD[p] : ""), \
          ((f == "test-browser") ? "test browser left by a finished run: a test still using it would fail" \
          : (p in WD) ? "server left in the lane folder by a session that ended: what it serves goes down" \
          : "tool server left by a session that ended: nothing uses it any more") stopping(), PM[p], PA[p], "FAMILY=" f "\n")
      }
      for (i = 1; i <= nt; i++) {
        p = TT[i]; if (CUTP[p] || guard(p, 0) != "") continue
        cut("family", "stop", p, p, name_of(ARGS[p]), "busy " cpu1(CPU[p]) "% CPU for " hours(ET[p]) ": forgotten tool?", \
          name_of(ARGS[p]) " stops: whatever it is computing is lost, and lab cannot tell what depends on it" stopping(), TM[p], TX[p], "FAMILY=" TF[p] "\n")
      }
      for (i = 1; i <= nz; i++) {
        # une session déjà proposée garde son seul geste : un identifiant, un clic (son endormissement ou sa fermeture libère aussi)
        q = ZP[i]; if (ZC[q] < zmin || CUTP[q]) continue
        sess = (AG[q] == "claude" || AG[q] == "codex"); if (guard(q, sess) != "" || (sess && !at_rest(q))) continue
        d = ZC[q] " zombie process(es) held by their parent, freed only when it restarts"
        if (sess && SF[q] != "" && SFN[SF[q]] < 2) cut("zombies", "restart-parent", q, q, name_of(ARGS[q]), d, "the session sleeps then wakes in the same tab: its zombie processes go away, its conversation is kept", 0, 0, "COUNT=" ZC[q] "\n")
        else cut("zombies", "explain", q, q, name_of(ARGS[q]), d, "lab restarts only an agent alone in its cmux tab; ask for an explanation first", 0, 0, "COUNT=" ZC[q] "\n")
      }
      # endormies par lab top --cut : oubliées dès qu une autre session (autre pid) porte de nouveau leur onglet, réveil depuis cmux ;
      # la même, encore présente, est un agent qui finit de s arrêter
      for (i = 1; i <= nb; i++) {
        split(BR[i], b, "\t"); if ((b[1] in LIVE) && LIVE[b[1]] != b[3]) continue
        nh++; hibs = hibs "BLOCK=HIBERNATED\nSURFACE=" b[1] "\nWORKSPACE=" b[2] "\nPID=" b[3] "\nSESSION_ID=" b[4] "\nPROJECT=" b[5] "\nLANE=" b[6] \
          "\nAT=" b[7] "\nMEM=" b[8] "\nWAKE=lab top --wake " b[1] "\n\n"
      }
      if (probe ~ /^[0-9]+$/) {
        ex = (probe in PP); sess = (AG[probe] == "claude" || AG[probe] == "codex")
        probes = "BLOCK=PROBE\nID=" probe "\nEXISTS=" (ex ? "yes" : "no") "\nPROTECTED=" (ex ? guard(probe, sess) : "") "\nSESSION=" (sess ? "yes" : "no") "\n\n"
      } else if (probe != "") {
        pr = (probe == "cmux") ? "cmux itself" : (probe == "cmux-cua" || probe == "agent-helper") ? probe : (probe in KEEP) ? "family named in top_keep=" : ""
        probes = "BLOCK=PROBE\nID=" probe "\nEXISTS=" ((probe in FN) ? "yes" : "no") "\nPROTECTED=" pr "\nWHOLE_FAMILY=" ((probe == "node" || probe == "other") ? "yes" : "no") "\n\n"
      }
      # bloc machine
      sw = SY["vm.swapusage"]; su = sw; st = sw; sub(/.*used = /, "", su); sub(/ .*/, "", su); sub(/.*total = /, "", st); sub(/ .*/, "", st)
      ld = SY["vm.loadavg"]; gsub(/[{}]/, "", ld); split(ld, L, " ")
      lvl = SY["kern.memorystatus_vm_pressure_level"]
      pressure = (lvl == "1") ? "normal" : (lvl == "2") ? "warning" : (lvl == "4") ? "critical" : "unknown"
      thermal = (speed > 0 && speed < 100) ? "throttled" : (twarn > 0) ? "warning" : nominal ? "nominal" : "unknown"
      print "BLOCK=MACHINE\nAT=" now_iso "\nRAM_MB=" mb(ram) "\nCPUS=" SY["hw.ncpu"] "\nPRESSURE=" pressure "\nFREE_PCT=" SY["kern.memorystatus_level"] \
        "\nCOMPRESSED_MB=" ((page && stored != "") ? mb(stored * page / 1048576) : "") "\nCOMPRESSOR_MB=" ((page && occupied != "") ? mb(occupied * page / 1048576) : "") \
        "\nSWAP_USED_MB=" ((su ~ /^[0-9]/) ? unit_mb(su) : "") "\nSWAP_TOTAL_MB=" ((st ~ /^[0-9]/) ? unit_mb(st) : "") \
        "\nLOAD_1=" L[1] "\nLOAD_5=" L[2] "\nLOAD_15=" L[3] "\nTHERMAL=" thermal "\nSPEED_LIMIT=" ((speed > 0) ? speed : 100) \
        "\nMEM_SOURCE=" msource "\nIDLE_HOURS=" idle_h "\nSESSIONS=" ns + 0 "\nZOMBIES=" zt + 0 "\nCUTS=" ncut + 0 "\nHIBERNATED=" nh + 0 "\n"
      printf "%s", out; printf "%s", cuts; printf "%s", hibs; printf "%s", probes
    }'
}

# top_view <largeur> : vue lisible des blocs (stdin, KEY=value) sur stdout, aucune ligne plus large que <largeur> ; tableau à partir
# de 64 colonnes, fiches empilées en dessous.
top_view() {
  kv_to_json | jq -r --argjson w "$1" '
    def fit($n): tostring | if length > $n then .[0:($n - 1)] + "…" else . end;
    def pad($n): tostring | if length > $n then .[0:($n - 1)] + "…" else . + (" " * ($n - length)) end;
    def rpad($n): tostring | if length >= $n then .[0:$n] else (" " * ($n - length)) + . end;
    def size: (tonumber? // 0) as $m | if $m >= 1024 then ($m / 102.4 | floor | tostring | .[0:-1] + "." + .[-1:]) + "G" else "\($m)M" end;
    def wrap($n; $ind): reduce (split(" ") | map(select(length > 0)))[] as $x ([""];
      .[-1] as $cur | if $cur == "" then .[-1] = $ind + $x elif ($cur | length) + 1 + ($x | length) <= $n then .[-1] = $cur + " " + $x
      else . + [$ind + $x] end) | .[];
    def phase: if .PHASE == "" or .PHASE == "work" then "" else " · " + .PHASE end;
    def target: .TARGET + (if .PID == "" then "" else " (pid \(.PID))" end);
    def mem: (if .MEM_APPROX == "yes" then "~" else "" end) + (.MEM | size);
    def dur: if . == "unknown" or . == "" or . == null then "?" else (tonumber? // 0) as $s |
      if $s < 60 then "<1m" elif $s < 3600 then "\($s / 60 | floor)m" elif $s < 172800 then "\($s / 3600 | floor)h" else "\($s / 86400 | floor)d" end end;
    def where: if .PROJECT == "none" then "outside projects" elif .LANE == "main" then .PROJECT + " (main)" else .PROJECT + "/" + .LANE end;
    def gain: if (.MEM | tonumber? // 0) > 0 then ", frees about \(mem)" else "" end;
    (map(select(.BLOCK == "MACHINE")) | .[0] // {}) as $m |
    map(select(.BLOCK == "SESSION")) as $s | map(select(.BLOCK == "FAMILY")) as $f | map(select(.BLOCK == "CUT")) as $c |
    map(select(.BLOCK == "HIBERNATED")) as $h |
    (if $m.MEM_SOURCE == "rss" then "resident memory, approximate" else "footprint" end) as $src |
    (if $w >= 64 then
      "Machine at \($m.AT): \($m.RAM_MB | size) RAM, \($m.CPUS) CPUs, pressure \($m.PRESSURE) (\($m.FREE_PCT)% free)",
      "Compressed \($m.COMPRESSED_MB | size) in \($m.COMPRESSOR_MB | size), swap \($m.SWAP_USED_MB | size) of \($m.SWAP_TOTAL_MB | size), load \($m.LOAD_1) \($m.LOAD_5) \($m.LOAD_15)",
      "Thermal \($m.THERMAL), \($m.ZOMBIES) zombie processes, memory read as \($src)",
      "",
      "Sessions (\($s | length)), idle after \($m.IDLE_HOURS)h",
      ("PID" | rpad(6)) + " " + ("Agent" | pad(6)) + " " + ("Where" | pad($w - 44)) + " " + ("Mem" | rpad(6)) + " " + ("+kids" | rpad(6)) + " " + ("CPU" | rpad(5)) + " " + ("Age" | rpad(4)) + " " + ("Idle" | rpad(4)),
      ($s[] | (.PID | rpad(6)) + " " + (.AGENT | pad(6)) + " " + (where + phase | pad($w - 44)) + " " + (mem | rpad(6)) + " "
        + (.CHILDREN_MEM | size | rpad(6)) + " " + (.CPU | rpad(5)) + " " + (.AGE | dur | rpad(4)) + " " + (.IDLE | dur | rpad(4))),
      "",
      "Outside Treelab",
      ("Family" | pad(13)) + " " + ("Procs" | rpad(5)) + " " + ("Mem" | rpad(7)) + " " + ("CPU" | rpad(6)) + "  " + "Largest",
      ($f[] | (.FAMILY | pad(13)) + " " + (.PROCESSES | rpad(5)) + " " + (mem | rpad(7)) + " " + (.CPU | rpad(6)) + "  " + .LARGEST),
      "",
      "To cut (\($c | length)): proposals only, lab top changes nothing; each click is its command",
      ($c[] | (.REASON | pad(10)) + " " + (.GESTURE | pad(15)) + " " + target, (.DETAIL + gain | wrap($w; "           ")),
        ("impact: " + .IMPACT | wrap($w; "           ")), ("click: " + .ACTION | wrap($w; "           "))),
      (select($h | length > 0) | "", "Asleep (\($h | length)), put to sleep by lab top",
        ($h[] | ("  " + (if .PROJECT == "none" or .PROJECT == "" then "outside projects" else .PROJECT + "/" + .LANE end) + " (pid \(.PID), \(.MEM | size)) since \(.AT)" | wrap($w; "    ")),
          ("    " + .WAKE)))
    else
      "Machine",
      " RAM \($m.RAM_MB | size), \($m.CPUS) CPUs",
      " Pressure \($m.PRESSURE), \($m.FREE_PCT)% free",
      " Compressed \($m.COMPRESSED_MB | size) in \($m.COMPRESSOR_MB | size)",
      " Swap \($m.SWAP_USED_MB | size) of \($m.SWAP_TOTAL_MB | size)",
      " Load \($m.LOAD_1) \($m.LOAD_5) \($m.LOAD_15)",
      " Thermal \($m.THERMAL)",
      " Zombie processes \($m.ZOMBIES)",
      " Memory read as \($src)",
      "",
      "Sessions (\($s | length))",
      ($s[] | " \(.AGENT) \(.PID) \(where)", (select(phase != "") | "   phase \(.PHASE)"),
        "   mem \(mem) +\(.CHILDREN_MEM | size), cpu \(.CPU)", "   age \(.AGE | dur), idle \(.IDLE | dur)"),
      "",
      "Outside Treelab",
      ($f[] | " \(.FAMILY): \(.PROCESSES) procs", "   \(mem), cpu \(.CPU)"),
      "",
      "To cut (\($c | length))",
      ($c[] | " \(.REASON) -> \(.GESTURE)", (target | wrap($w; "   ")), (.DETAIL + gain | wrap($w; "   ")),
        ("impact: " + .IMPACT | wrap($w; "   ")), (.ACTION | wrap($w; "   "))),
      "Proposals only: lab top changes nothing.",
      (select($h | length > 0) | "", "Asleep (\($h | length))",
        ($h[] | " " + (if .PROJECT == "none" or .PROJECT == "" then "outside projects" else .PROJECT + "/" + .LANE end), "   pid \(.PID), \(.MEM | size)",
          ("lab top --wake" | wrap($w; "   ")), ("   " + .SURFACE)))
    end) | fit($w)'
}

# top_report <fast 0|1> : blocs sur stdout, vue lisible sur stderr à la largeur du terminal (40 à 80 colonnes).
top_report() {
  local blocks
  blocks="$(top_snapshot "$1")"
  printf '%s\n' "$blocks"
  printf '%s\n' "$blocks" | top_view "$(onboard_cols)" >&2 || warn "readable view unavailable (jq): the KEY=value blocks above are complete"
}
