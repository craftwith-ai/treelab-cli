# shellcheck shell=bash
# shellcheck disable=SC2034 # CLOUD_MODE, CLOUD_SIZE, CLOUD_MACHINE et CLOUD_TERMINAL sont lus par bin/lab (open_fresh_session)
# cloud.sh — la session d'exécution d'un lot part sur une machine Cloud de cmux, puis revient au Mac pour batch-end (lot 04 de
# cmux-pro). Le Mac garde lab, les onglets, la revue et la livraison ; la VM reçoit la branche par GitHub en SSH, grâce à une clé de
# déploiement du dépôt — une par couloir, par départ : ssh-keygen sur la VM, clé publique remontée au Mac pour `gh repo deploy-key add`,
# clé privée jamais sur le Mac ni le disque local, révoquée sur GitHub à la fin (lot 06 d'aiguillage-cloud) — et un claude interactif en
# bypassPermissions (VM isolée). Marque du couloir : $WT/.lab/cloud (lot, machine, terminal, workspace, since, key_id, key_title,
# state=alive|idle-paused|finished|failed, detail, waiting, woken, idle_alerted, pane, pane_ws — un marqueur d'avant le lot 09 dit
# vivant|attente-pause|fini|échec, lang_code le relit) ; tant qu'elle dit alive ou idle-paused, lab next et lab launch ne relancent rien. Image du projet :
# $LAB_STATE/cloud/<projet> (machine outillée, snapshot), préparée une fois par lab cloud <projet> image.
CLOUD_MIN_MB=8192    # 4g refusé : 2 vCPU pour une session qui lance des tests (borne processeur, lot 01)
CLOUD_MAX_MB=32768
# cmux vm exec tourne en cmux depuis cmux 0.65 (mesuré le 2026-10-16 : runuser y est refusé), en root avant : ces deux préfixes
# distants passent à l'utilisateur de travail dans les deux cas — commande seule, ou script dans son shell de connexion
# shellcheck disable=SC2016 # évalués sur la VM
CLOUD_AS_CMUX=(sh -c 'if [ "$(id -u)" = 0 ]; then exec runuser -u cmux -- "$@"; fi; exec "$@"' sh)
# shellcheck disable=SC2016 # évalués sur la VM
CLOUD_LOGIN_CMUX=(sh -c 'if [ "$(id -u)" = 0 ]; then exec runuser -l cmux -c "$1"; fi; cd /home/cmux && HOME=/home/cmux exec bash -lc "$1"' sh)
# l'outillage du projet (apt-get) tourne en root : direct en root, sinon sudo -n (cmux, mesuré au lot 04 d'aiguillage-cloud)
# shellcheck disable=SC2016 # évalué sur la VM
CLOUD_AS_ROOT=(sh -c 'if [ "$(id -u)" = 0 ]; then exec bash "$1"; fi; exec sudo -n bash "$1"' sh)

cloud_vm() { CMUX_QUIET=1 with_timeout "${2:-120}" cmux vm "${@:3}" </dev/null; }   # <libellé> <délai> <arguments de cmux vm…>
cloud_marker() { printf '%s/.lab/cloud\n' "${1:-$WT}"; }
cloud_get() { if kv_value "${2:-$WT}/.lab/cloud" "$1"; then printf '%s\n' "$KV_VALUE"; fi; }   # marque absente : vide
cloud_get_set() { kv_value "${2:-$WT}/.lab/cloud" "$1" || true; CLOUD_GET="$KV_VALUE"; }   # <clé> [wt] : CLOUD_GET, sans processus
cloud_put() { # <clé> <valeur> [wt] : réécriture atomique d'une clé de la marque
  local f tmp; f="$(cloud_marker "${3:-$WT}")"; mkdir -p "$(dirname "$f")"; tmp="$(mktemp "$f.XXXXXX")"
  { grep -v "^$1=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$1" "$(printf '%s' "$2" | tr '\n' ' ' | cloud_plain)"; } >"$tmp" && mv "$tmp" "$f"
}
# cloud_plain : texte venu de la VM (fin, dmesg) sans caractère de contrôle — jamais une séquence d'échappement sur le terminal du Mac
# cloud_mask : secrets masqués dans un texte venu de la VM — jetons GitHub (ghp_, gho_, ghs_, ghu_, github_pat_), clés sk-…, et toute
# ligne d'une clé privée (-----BEGIN… jusqu'à -----END…, une fin sans son début, toute longue ligne base64) remplacée en entier (lot 10)
cloud_mask() {
  sed -E -e '/-----BEGIN/,/-----END/c\
[private key hidden]' -e 's/^.*-----END.*$/[private key hidden]/' -e 's/^[[:space:]]*[A-Za-z0-9+\/=]{40,}[[:space:]]*$/[private key hidden]/' \
    -e 's/(gh[pousr]_|github_pat_)[A-Za-z0-9_]+/\1***/g' -e 's/(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{6,}/\1sk-***/g'
}
# CLOUD_GIT_NOISE : les deux lignes de conseil que git ajoute à tout échec d'accès distant, jamais une cause
CLOUD_GIT_NOISE='Please make sure you have the correct access rights|and the repository exists\.'
# cloud_terminal_tail <machine> <terminal> → les 3 dernières lignes utiles du journal du terminal VM (cmux vm terminal output, lu par
# morceaux jusqu'à complete=true, 50 au plus), sans couleur ni ligne vide ni les deux lignes de conseil de git, secrets masqués, jointes
# par « / », ≤ 240 caractères ; vide si le Cloud se tait. Réveille une VM en pause (mesuré au lot 10) : jamais appelée sur une VM endormie.
cloud_terminal_tail() {
  local out text="" prev="" after="" n=0 esc=$'\033' bel=$'\007'
  while [ "$n" -lt 50 ]; do
    out="$(cloud_vm output 60 terminal output "$1" "$2" ${after:+--after "$after"} --json 2>/dev/null)" || break
    prev="$text"; text="$(jq -r '.text // empty' <<<"$out" 2>/dev/null)" || break
    [ "$(jq -r '.complete' <<<"$out" 2>/dev/null)" = false ] || break
    after="$(jq -r '.next_offset // empty' <<<"$out" 2>/dev/null)"; [ -n "$after" ] || break
    n=$((n + 1))
  done
  printf '%s%s\n' "$prev" "$text" | tr '\r' '\n' | sed -E "s/${esc}\\][^${bel}${esc}]*(${bel}|${esc}\\\\)?//g; s/${esc}\\[[0-9;?]*[A-Za-z]//g" | cloud_plain \
    | cloud_mask | grep -v '^[[:space:]]*$' | grep -vxE "$CLOUD_GIT_NOISE" \
    | tail -3 | awk 'NR > 1 { printf " / " } { printf "%s", $0 } END { if (NR) print "" }' | cut -c1-240 || true   # aucune ligne (journal vide, illisible) : rc 0 sous set -e (lot 10, réel)
}
cloud_plain() { LC_ALL=C tr -d '\000-\010\013-\037\177'; }
# cloud_live [wt] : une session de lot tourne sur une VM pour ce couloir — aucune autre ne part
cloud_live() { cloud_get_set state "${1:-$WT}"; lang_code_set "$CLOUD_GET"; [ "$LANG_CODE" = alive ]; }
# cloud_paused [wt] : la session du lot attend sa réponse, VM mise en pause après LAB_CLOUD_IDLE_MAX (lot 09 de cmux-pro) ; lab next
# la réveille, lab launch ne lance rien d'autre
cloud_paused() { cloud_get_set state "${1:-$WT}"; lang_code_set "$CLOUD_GET"; [ "$LANG_CODE" = idle-paused ]; }
# cloud_finished <wt> <fiche> : la session VM de cette fiche a fini proprement — le Mac ouvre batch-end (session « fin »)
cloud_finished() { [ "$(lang_code "$(cloud_get state "$1")")" = finished ] && [ "$(cloud_get lot "$1")" = "$(basename "$2" .md)" ]; }
# ---------- besoins découverts sur la VM (lot 02 d'aiguillage-cloud) ----------
# Mémoire locale du projet, hors du dépôt : $(project_dir <p>)/cloud-needs, une ligne TSV par lot bloqué — date, besoin, détail,
# couloir, lot —, écrite sous registry_locked par le veilleur, oubliée seulement par lab cloud <p> needs reset. lab next la lit avant
# la ligne Execution (cloud_need_keeps_mac), lab cloud la liste (NEED=), le contexte de démarrage la cite (cloud-needs=).
cloud_needs_file() { printf '%s/cloud-needs\n' "$(project_dir "${1:-$P_NAME}")"; }
cloud_needs_lines() { local f; f="$(cloud_needs_file "${1:-}")"; [ -f "$f" ] || return 0; { awk -F '\t' 'NF >= 5 && $2 != ""' "$f" 2>/dev/null || true; } | cloud_plain; }
cloud_need_of_lot() { cloud_needs_lines | awk -F '\t' -v s="$1" -v l="$2" '$4 == s && $5 == l { r = $0 } END { if (r != "") print r }'; }   # <couloir> <lot>
cloud_need_write_() { # <p> <date> <besoin> <détail> <couloir> <lot> : sous registry_locked ; la ligne du même lot est remplacée
  local f tmp; f="$(cloud_needs_file "$1")"; mkdir -p "$(dirname "$f")"; tmp="$(mktemp "$f.XXXXXX")"
  { awk -F '\t' -v s="$5" -v l="$6" '!($4 == s && $5 == l)' "$f" 2>/dev/null || true; printf '%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" "$6"; } >"$tmp" && mv "$tmp" "$f"
}
cloud_need_add() { registry_locked "$P_NAME" cloud_need_write_ "$P_NAME" "$(cloud_now)" "$1" "$2" "$SLUG" "$3"; }   # <besoin> <détail> <lot>
cloud_needs_reset() { registry_locked "$1" rm -f "$(cloud_needs_file "$1")"; }
# cloud_need_name <besoin> → « need secret », ou « unknown need "gpu" » hors de la liste fermée (LOT_EXECUTION_NEEDS, lib/docs.sh)
cloud_need_name() { case " $LOT_EXECUTION_NEEDS " in *" $1 "*) printf 'need %s\n' "$1" ;; *) printf 'unknown need "%s"\n' "$1" ;; esac; }
# cloud_fin_need <ligne de fin> → « <besoin><TAB><détail> » pour « blocked: need <besoin>: <détail> » (casse et espaces tolérés),
# besoin borné à 40 caractères, détail à 160, sans tabulation ; rien pour toute autre fin. Sans deux-points, seul un besoin de la
# liste fermée compte : « blocked: need to wait… » est une raison libre, jamais le besoin « to » (revue)
cloud_fin_need() {
  printf '%s\n' "$1" | tr '\t' ' ' | cloud_plain | LC_ALL=C awk -v needs=" $LOT_EXECUTION_NEEDS " '{
    l = tolower($0)
    if (!match(l, /^ *blocked *: *need +/)) exit
    r = substr($0, RLENGTH + 1); l = substr(l, RLENGTH + 1)
    if (!match(l, /^[a-z][a-z0-9-]*/)) exit
    n = substr(l, 1, RLENGTH); d = substr(r, RLENGTH + 1)
    if (d ~ /^ *:/) sub(/^ *: */, "", d); else if (index(needs, " " n " ")) sub(/^ +/, "", d); else exit
    sub(/ +$/, "", d)
    printf "%s\t%s\n", substr(n, 1, 40), d
    exit
  }' | { IFS= read -r l || true; [ -z "$l" ] || printf '%s\t%s\n' "$(cut -f1 <<<"$l")" "$(cut -f2 <<<"$l" | cut -c1-160)"; }
}
# cloud_need_keeps_mac <fiche> : rc 1 si le besoin retenu de ce lot garde le Mac, CLOUD_WHY le nomme. Les besoins des autres lots ne
# décident plus rien ici : une fiche sans ligne Execution reste sur le Mac par défaut (lot 01 de session-unique), batch-plan les lit
# avant d'écrire une ligne cloud.
cloud_need_keeps_mac() {
  local r d
  r="$(cloud_need_of_lot "$SLUG" "$(basename "${1:-}" .md)")"
  [ -n "$r" ] || return 0
  d="$(cut -f3 <<<"$r")"
  CLOUD_WHY="$(cloud_need_name "$(cut -f2 <<<"$r")") found on the VM ($(cut -f1 <<<"$r" | cut -c1-10))${d:+: $d}"; return 1
}
# ---------- journal des sessions VM du projet (lot 02 d'aiguillage-cloud) ----------
# $LAB_STATE/cloud/sessions/<p> : une ligne TSV par fin — couloir, lot, machine, départ, fin, durée en s, pushs, issue (done, need,
# failed, timeout). Une écriture refusée n'arrête jamais le veilleur.
cloud_sessions_file() { printf '%s/cloud/sessions/%s\n' "$LAB_STATE" "${1:-$P_NAME}"; }
cloud_session_log() { # <issue>
  local f start end s e d="" n
  f="$(cloud_sessions_file)"; start="$(cloud_get since)"; end="$(cloud_now)"; n="$(watch_get "$WATCH_FILE" pushes)"
  if s="$(rdv_epoch "$start" 2>/dev/null)" && e="$(rdv_epoch "$end" 2>/dev/null)"; then d=$((e - s)); fi
  { mkdir -p "$(dirname "$f")" && printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$SLUG" "$(cloud_get lot "$WT")" "$(cloud_get machine)" "$start" "$end" "$d" "${n:-0}" "$1" >>"$f"; } 2>/dev/null \
    || log "session log $f not written"
}
# cloud_ago <secondes> → « 12 min », ou « 40 s » sous la minute
cloud_ago() { if [ "$1" -ge 60 ]; then printf '%s min\n' "$(($1 / 60))"; else printf '%s s\n' "$1"; fi; }
# lab cloud <p> en lecture : NEED=<besoin> — <lot> (<couloir>, <date>): <détail> par besoin retenu ; SESSION= pour les 5 dernières
# sessions VM, « <fin> <couloir>/<lot> on <machine>: <issue>, <durée> min, <n> push(es) »
cloud_needs_kv() {
  local l n d
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    n="$(cut -f2 <<<"$l")"; d="$(cut -f3 <<<"$l")"
    case " $LOT_EXECUTION_NEEDS " in *" $n "*) ;; *) n="$n (unknown)" ;; esac
    kv NEED "$n — $(cut -f5 <<<"$l") ($(cut -f4 <<<"$l"), $(cut -f1 <<<"$l" | cut -c1-10))${d:+: $d}"
  done < <(cloud_needs_lines "$1")
}
cloud_sessions_kv() {
  local f; f="$(cloud_sessions_file "$1")"; [ -f "$f" ] || return 0
  awk -F '\t' 'NF >= 8' "$f" 2>/dev/null | tail -5 | cloud_plain \
    | awk -F '\t' '{ printf "SESSION=%s %s/%s on %s: %s, %s min, %s push(es)\n", $5, $1, $2, $3, $8, ($6 == "" ? "?" : int($6 / 60)), ($7 == "" ? 0 : $7) }'
}
# cloud_session_line <wt> → « on VM <machine> since <date>, last push 12 min ago (2 pushes) » : lab status pendant la session,
# lu dans la marque et l'état du veilleur, sans réseau
cloud_session_line() {
  local wt="$1" f n at
  f="$(watch_file "$(cloud_get branch "$wt")" "$(wt_lane "$wt")")"; n="$(watch_get "$f" pushes)"; at="$(watch_get "$f" push_at)"
  if cloud_paused "$wt"; then printf 'paused on VM %s — %s\n' "$(cloud_get machine "$wt")" "$(cloud_get detail "$wt")"; return 0; fi   # lot 09
  printf 'on VM %s since %s' "$(cloud_get machine "$wt")" "$(cloud_get since "$wt")"
  [ -z "$(cloud_get waiting "$wt")" ] || printf ', answer awaited since %s' "$(cloud_hm "$(cloud_get waiting "$wt")")"   # lot 09
  case "$n:$at" in
    *[!0-9:]*|:*|*:) printf ', last push unknown\n' ;;
    0:*) printf ', no push since the start (%s)\n' "$(cloud_ago $(( $(cloud_epoch) - at )))" ;;
    1:*) printf ', last push %s ago (1 push)\n' "$(cloud_ago $(( $(cloud_epoch) - at )))" ;;
    *) printf ', last push %s ago (%s pushes)\n' "$(cloud_ago $(( $(cloud_epoch) - at )))" "$n" ;;
  esac
}
cloud_image_file() { printf '%s/cloud/%s\n' "$LAB_STATE" "$P_NAME"; }
cloud_image_get() { if kv_value "$LAB_STATE/cloud/$P_NAME" "$1"; then printf '%s\n' "$KV_VALUE"; fi; }
cloud_now() { rdv_now 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ; }

# ---------- clé de déploiement : une paire SSH par couloir, par départ (lot 06 d'aiguillage-cloud) ----------
# cloud_repo_slug → OWNER/REPO du dépôt, résolu par gh depuis le remote du couloir ; vide si gh ne le résout pas (non authentifié,
# remote non-GitHub). cloud_repo_ssh_url → l'URL SSH que la VM clone, fetch et push (compte git, hôte github.com, OWNER/REPO.git).
cloud_repo_slug() { (cd "$WT" && with_timeout 20 gh repo view --json nameWithOwner --jq .nameWithOwner) 2>/dev/null | head -1; }
cloud_repo_ssh_url() { local s host=github.com; s="$(cloud_repo_slug)" && [ -n "$s" ] || return 1; printf 'git@%s:%s.git\n' "$host" "$s"; }
# cloud_gh_quota : rc 1 si le quota REST (core) ou GraphQL de GitHub est vide — CLOUD_WHY nomme la ressource et l'heure locale de remise
# (les deux vides : la remise la plus tardive). gh répond « token invalid » à « gh auth status » quand le quota est vide (lot 11, réel) ;
# « gh api rate_limit » ne consomme aucun quota. Lecture illisible (réseau, JSON) → rc 0 : la suite décide comme avant.
cloud_gh_quota() {
  local e k l t
  e="$(with_timeout 20 gh api rate_limit --jq '[.resources | to_entries[] | select((.key == "core" or .key == "graphql") and .value.remaining == 0) | [.key, .value.limit, .value.reset]] | sort_by(.[2]) | last // empty | map(tostring) | join(" ")' 2>/dev/null)" || return 0
  read -r k l t <<<"$e" || true; case "${t:-}" in ''|*[!0-9]*) return 0 ;; esac
  CLOUD_WHY="GitHub API quota exhausted until $(cloud_hm "$t") ($k 0/$l): no deploy key"; return 1
}
# cloud_gh_ready : rc 0 si une clé de déploiement est possible — gh authentifié et remote GitHub lisible ; sinon CLOUD_WHY nomme la cause.
# La vraie capacité (scope admin:public_key) se prouve au départ : un cloud_key_make en échec fait retomber la session en local.
cloud_gh_ready() {
  has_gh || { CLOUD_WHY="gh missing or disabled: the VM needs it for a deploy key"; return 1; }
  cloud_gh_quota || return 1   # avant « gh auth status » : un quota vide s'y lit « non authentifié » (lot 11)
  # le compte actif seul : un autre compte du trousseau au jeton périmé fait rendre 1 à « gh auth status » (vu en réel au lot 09) ;
  # un gh sans --active retombe sur la forme simple
  (cd "$WT" && { with_timeout 20 gh auth status --active || with_timeout 20 gh auth status; }) >/dev/null 2>&1 || { CLOUD_WHY="gh not authenticated (gh auth login): no deploy key"; return 1; }
  [ -n "$(cloud_repo_slug)" ] || { CLOUD_WHY="remote $P_REMOTE is not a readable GitHub repository: no deploy key"; return 1; }
}
# cloud_key_title <slug> → lab-cloud-<slug>-<horodatage> : un titre de clé unique par départ, préfixe commun lab-cloud-<slug>- pour la purge
cloud_key_title() { printf 'lab-cloud-%s-%s\n' "$1" "$(date -u +%Y%m%dT%H%M%SZ)"; }
# cloud_key_* : lecture et suppression des clés de déploiement du dépôt par gh (sur le Mac) ; -R le nomme, aucun cd
cloud_key_ids() { # <préfixe de titre> → ids des clés dont le titre commence par le préfixe, un par ligne
  local r; r="$(cloud_repo_slug)" && [ -n "$r" ] || return 1
  with_timeout 30 gh repo deploy-key list -R "$r" --json id,title --jq ".[] | select(.title | startswith(\"$1\")) | .id" 2>/dev/null
}
cloud_key_listed() { # <id> : rc 0 si l'id figure encore dans la liste des clés du dépôt
  local r keys; r="$(cloud_repo_slug)" && [ -n "$r" ] || return 1
  keys="$(with_timeout 30 gh repo deploy-key list -R "$r" --json id --jq '.[].id' 2>/dev/null)" && grep -qx "$1" <<<"$keys"
}
cloud_key_delete() { local r; r="$(cloud_repo_slug)" && [ -n "$r" ] || return 1; with_timeout 30 gh repo deploy-key delete -R "$r" "$1"; }
# cloud_key_purge <slug> : les clés lab-cloud-<slug>-* restées sur GitHub (session plantée) supprimées par id, avant d'en créer une neuve ;
# best-effort, journalisé, ne bloque jamais le départ
cloud_key_purge() {
  local sl="$1" ids id
  ids="$(cloud_key_ids "lab-cloud-$sl-")" || return 0
  for id in $ids; do
    if cloud_key_delete "$id" >/dev/null 2>&1; then log "Old deploy key purged: $id."
    else warn "Cloud: old deploy key $id not purged — gh repo deploy-key delete $id"; fi
  done
}
# cloud_key_make <machine> <slug> : la paire ed25519 est générée SUR la VM (clé privée jamais sur le Mac), la clé publique ajoutée en clé
# de déploiement write du dépôt (titre lab-cloud-<slug>-<ts>), son id relu par titre → CLOUD_KEY_ID, CLOUD_KEY_TITLE. rc 1 avec CLOUD_WHY.
cloud_key_make() {
  local m="$1" sl="$2" title r pub tmp id
  r="$(cloud_repo_slug)"; [ -n "$r" ] || { CLOUD_WHY="GitHub repository unreadable for the deploy key"; return 1; }
  title="$(cloud_key_title "$sl")"
  # ssh-keygen chez l'utilisateur de travail : ~/.ssh en 700, clé en 600 ; seule la clé publique est lue (cat), la privée reste sur la VM
  # shellcheck disable=SC2016 # évalué sur la VM
  pub="$(cloud_vm keygen 120 exec --timeout 120 "$m" -- "${CLOUD_AS_CMUX[@]}" sh -c 'f="$HOME/.ssh/lab-$1"; mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh" && rm -f "$f" "$f.pub" && ssh-keygen -t ed25519 -N "" -C "$2" -f "$f" -q && chmod 600 "$f" && cat "$f.pub"' sh "$sl" "$title" 2>/dev/null | cloud_plain | grep '^ssh-' | head -1)" || true
  [ -n "$pub" ] || { CLOUD_WHY="ssh-keygen produced no public key on $m"; return 1; }
  tmp="$(mktemp)"; printf '%s\n' "$pub" >"$tmp"
  if ! with_timeout 30 gh repo deploy-key add "$tmp" -R "$r" -t "$title" -w >/dev/null 2>&1; then
    rm -f "$tmp"; CLOUD_WHY="gh repo deploy-key add refused on $r (admin:public_key scope?)"; cloud_gh_quota || true; return 1   # quota vidé entre-temps : nommé (lot 11)
  fi
  rm -f "$tmp"
  id="$(cloud_key_ids "$title" | head -1)"
  [ -n "$id" ] || { cloud_key_purge "$sl"; CLOUD_WHY="deploy key added on $r but its id was not re-read — key purged"; return 1; }
  CLOUD_KEY_ID="$id"; CLOUD_KEY_TITLE="$title"
}
# cloud_ssh_opts <route> → les options ssh de la clé du couloir sur la VM ($HOME et le slug y sont évalués) : délai de connexion court,
# et, route 443, la route SSH officielle de GitHub (ssh.github.com:443) — le port 22 de github.com expire par moments depuis la VM (lot 10, C1)
cloud_ssh_opts() {
  # shellcheck disable=SC2016 # évalué sur la VM
  printf 'ssh -i $HOME/.ssh/lab-%s -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10%s' "$SLUG" \
    "$([ "${1:-22}" != 443 ] || printf ' -o HostName=ssh.github.com -o Port=443')"
}
# cloud_access_check <machine> : git ls-remote depuis la VM avec la clé du couloir, port 22 puis 443, réessayé toutes les
# LAB_CLOUD_ACCESS_STEP secondes (5) jusqu'à LAB_CLOUD_ACCESS_MAX (60) : CLOUD_ROUTE (22|443) est la route du terminal, CLOUD_ACCESS dit
# l'attente réelle. rc 1 : CLOUD_WHY nomme la machine, le délai et la dernière ligne lue (masquée) ; la clé reste à révoquer par l'appelant.
cloud_access_check() {
  local m="$1" url max="${LAB_CLOUD_ACCESS_MAX:-60}" step="${LAB_CLOUD_ACCESS_STEP:-5}" t0="$SECONDS" n=0 out last="" route
  url="$(cloud_repo_ssh_url)" || { CLOUD_WHY="GitHub repository unreadable for the access check"; return 1; }
  while :; do
    n=$((n + 1))
    # shellcheck disable=SC2016 # évalué sur la VM ; chaque route rend la sortie de git, la première qui répond « route=<port> »
    out="$(cloud_vm access 90 exec --timeout 60 "$m" -- "${CLOUD_AS_CMUX[@]}" sh -c 'for r in 22 443; do o="$1"; [ "$r" = 22 ] || o="$2"; if e="$(GIT_SSH_COMMAND="$o" git ls-remote "$3" HEAD 2>&1)"; then echo "route=$r"; exit 0; fi; printf "%s\n" "$e"; done; exit 1' sh "$(cloud_ssh_opts 22)" "$(cloud_ssh_opts 443)" "$url" 2>&1)" || true
    route="$(printf '%s\n' "$out" | sed -n 's/^route=\([0-9]*\)$/\1/p' | tail -1)"
    if [ -n "$route" ]; then
      CLOUD_ROUTE="$route"; CLOUD_ACCESS="port $route after $((SECONDS - t0)) s ($n tries)"; return 0
    fi
    # la cause est la ligne de git (« Permission denied », « Connection timed out ») : ni ses lignes de conseil, ni « Error: exit <n> »
    # que cmux ajoute à une commande distante en échec (lot 10, réel)
    last="$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | grep -vxE "$CLOUD_GIT_NOISE|fatal: Could not read from remote repository\.|Error: exit [0-9]+" | tail -1 | cloud_plain | cloud_mask | cut -c1-160)" || last=""
    [ $((SECONDS - t0 + step)) -le "$max" ] || break
    [ "$n" -gt 1 ] || { log "GitHub access from the VM refused:"; log "retrying up to $(cloud_delay_text "$max")."; }   # 40 colonnes
    sleep "$step"
  done
  CLOUD_WHY="GitHub access refused from $m after $((SECONDS - t0)) s: ${last:-no answer}"; return 1
}
# cloud_key_remove <machine> <id> <slug> [endormie] : la clé de déploiement révoquée sur GitHub (par id — même VM en pause), son absence
# vérifiée dans la liste, puis la clé privée effacée sur la VM si elle est éveillée. rc 0 seulement si la révocation tient ; CLOUD_KEY_PROOF
# la décrit. La révocation sur GitHub coupe l'accès quelle que soit une copie de la clé privée : plus robuste que le balayage de jeton du lot 05.
cloud_key_remove() {
  local m="$1" id="$2" sl="$3" asleep="${4:-0}" r
  r="$(cloud_repo_slug)" || r=""
  [ -n "$id" ] || { CLOUD_KEY_PROOF="no deploy key id recorded for $sl"; return 1; }
  cloud_key_delete "$id" >/dev/null 2>&1 || { CLOUD_KEY_PROOF="deploy key $id not revoked on ${r:-the repository} (gh repo deploy-key delete $id)"; return 1; }
  if cloud_key_listed "$id"; then CLOUD_KEY_PROOF="deploy key $id still listed on ${r:-the repository} after the deletion"; return 1; fi
  if [ "$asleep" = 1 ]; then CLOUD_KEY_PROOF="deploy key $id deleted on GitHub (access revoked), private key inert on the paused VM"; return 0; fi
  # shellcheck disable=SC2016 # évalué sur la VM
  if cloud_vm key 60 exec --timeout 60 "$m" -- "${CLOUD_AS_CMUX[@]}" sh -c 'rm -f "$HOME/.ssh/lab-$1" "$HOME/.ssh/lab-$1.pub"; git -C "$HOME/work/$2-$1" config --unset-all core.sshCommand 2>/dev/null; :' sh "$sl" "$P_NAME" >/dev/null 2>&1; then
    CLOUD_KEY_PROOF="deploy key $id deleted on GitHub (access revoked), private key erased on $m"
  else
    CLOUD_KEY_PROOF="deploy key $id deleted on GitHub (access revoked), private key not erased on $m"
  fi
}

# ---------- forfait : taille et place ----------
# cloud_size <json de vm ls> [suite] → « <n>g<TAB><vCPU> vCPU » ; « plein<TAB><motif> » sans place. vCPU et mémoire libres du forfait
# partagés entre les places de VM libres, palier inférieur de vcpusByMemoryMb entre 8g et 32g, sous le plafond par VM du forfait
# (maxVcpus, maxMemoryMb) ; une VM en pause prend sa place (HTTP 402 vm_active_limit_exceeded, mesuré au lot 10), pas ses vCPU.
# suite (lot 01 de cloud-racine) : une seule VM, tout le reste libre du forfait pour elle, aucun plafond au-delà de celui du forfait.
cloud_size() {
  local share=1 hi="$CLOUD_MAX_MB"; [ "${2:-}" != suite ] || { share=0; hi=1048576; }
  jq -r --argjson lo "$CLOUD_MIN_MB" --argjson hi "$hi" --argjson share "$share" '
    (.limits // {}) as $l
    | ([.vms[]? | select((.status // "") != "deleted")] | length) as $act
    | (($l.maxActiveVms // 0) - $act) as $places
    | if $places <= 0 then "plein\t\($act)/\($l.maxActiveVms // 0) VMs, paused included"
      else
        (if $share == 1 then $places else 1 end) as $d
        | ((($l.poolVcpus // 0) - ($l.usedVcpus // 0)) / $d | floor) as $cpu
        | ((($l.poolMemoryMb // 0) - ($l.usedMemoryMb // 0)) / $d | floor) as $mem
        | [($l.vcpusByMemoryMb // {}) | to_entries[] | {mb: (.key | tonumber), v: .value}
           | select(.mb >= $lo and .mb <= $hi and .v <= $cpu and .mb <= $mem and .mb <= ($l.maxMemoryMb // $hi) and .v <= ($l.maxVcpus // .v))] | max_by(.mb)
        | if . != null then "\(.mb / 1024 | floor)g\t\(.v) vCPU"
          elif $share == 1 then "plein\t\($cpu) free vCPU per slot, 8g tier out of reach"
          else "plein\t\($cpu) vCPU and \($mem / 1024 | floor) GB free, at least \([($l.vcpusByMemoryMb // {}) | to_entries[] | select((.key | tonumber) >= $lo) | .value] | min // 4) vCPU and \($lo / 1024 | floor) GB needed" end
      end' <<<"$1" 2>/dev/null
}

# ---------- file : forfait plein, ordre d'arrivée (lot 05) ----------
# $LAB_STATE/cloud/queue/<projet> : une ligne « <couloir><TAB><epoch d'inscription> » par couloir en attente, dans l'ordre d'arrivée.
# Lu et écrit sous un verrou (mkdir) : veilleurs de file, lab next et lab close s'y croisent. Au-delà de LAB_CLOUD_QUEUE_MAX
# secondes (30 min), le couloir part en local nommé.
cloud_queue_file() { printf '%s/cloud/queue/%s\n' "$LAB_STATE" "$P_NAME"; }
cloud_epoch() { compte_now 2>/dev/null || date +%s; }
cloud_queue_max() { printf '%s\n' "${LAB_CLOUD_QUEUE_MAX:-1800}"; }
cloud_queue_delay() { local s; s="$(cloud_queue_max)"; if [ "$((s % 60))" = 0 ]; then printf '%s min\n' "$((s / 60))"; else printf '%s s\n' "$s"; fi; }
cloud_queue_locked() { # <commande…> : sous le verrou du fichier de file ; un verrou laissé par un processus mort est repris
  local f d n=0 rc=0; f="$(cloud_queue_file)"; d="$f.lock"; mkdir -p "$(dirname "$f")"
  until mkdir "$d" 2>/dev/null; do
    n=$((n + 1))
    if [ "$n" -ge 50 ] || cloud_lock_stale "$d" "$n" 20; then cloud_lock_drop "$d"; n=0; continue; fi
    sleep 0.1
  done
  printf '%s\n' "$$" >"$d/pid"
  "$@" || rc=$?
  cloud_lock_drop "$d"; return "$rc"
}
cloud_queue_lines() { # entrées vivantes : couloir présent, et veilleur de file vivant (ou inscription de moins de 2 min, veilleur à venir)
  local f l s; f="$(cloud_queue_file)"; [ -f "$f" ] || return 0
  while IFS=$'\t' read -r l s; do
    [ -n "$l" ] && [ -d "$(worktree_path "$l")" ] || continue
    cloud_queue_watched "$l" "$s" || continue
    printf '%s\t%s\n' "$l" "$s"
  done <"$f"
}
cloud_queue_watched() { # <couloir> <epoch> : son veilleur de file vit — un veilleur tué ou remplacé (merge, close) ne garde aucune place (revue)
  local w; w="$(watch_file "$(branch_name "$(worktree_path "$1")")" "$1")"
  [ $(( $(cloud_epoch) - ${2:-0} )) -lt 120 ] && return 0
  [ "$(watch_get "$w" action)" = file ] && pid_alive "$(watch_get "$w" pid)"
}
cloud_queue_write() { # entrée standard → fichier de file, atomiquement ; couloirs disparus retirés au passage
  local f tmp l; f="$(cloud_queue_file)"; tmp="$(mktemp "$f.XXXXXX")"
  while IFS= read -r l; do [ -z "$l" ] || printf '%s\n' "$l"; done >"$tmp"   # cloud_queue_lines a déjà écarté les orphelines
  mv "$tmp" "$f"
}
# la file est lue une fois dans une variable : un grep -q ou un awk qui s'arrête tôt couperait le producteur (SIGPIPE), et sous
# pipefail « déjà inscrit » deviendrait faux (doublon, revue)
cloud_queue_add_() {
  local q; q="$(cloud_queue_lines)"
  case "$q" in "$1"$'\t'*|*$'\n'"$1"$'\t'*) return 0 ;; esac
  { [ -z "$q" ] || printf '%s\n' "$q"; printf '%s\t%s\n' "$1" "$(cloud_epoch)"; } | cloud_queue_write
}
cloud_queue_rm_() { cloud_queue_lines | { grep -v "^$1"$'\t' || true; } | cloud_queue_write; }   # file vidée : grep sans ligne, jamais une erreur
cloud_queue_add() { cloud_queue_locked cloud_queue_add_ "$1"; }   # déjà inscrit : rien ne change, ni place ni heure
cloud_queue_rm() { local f; f="$(cloud_queue_file)"; [ -f "$f" ] || return 0; cloud_queue_locked cloud_queue_rm_ "$1"; }
cloud_queue_pos() { local q; q="$(cloud_queue_lines)"; awk -F '\t' -v s="$1" '$1 == s && !n {n = NR} END {if (n) print n}' <<<"$q"; }   # 1 = premier ; vide hors file
cloud_queue_len() { local q; q="$(cloud_queue_lines)"; grep -c . <<<"$q" || true; }
cloud_queue_since() { local q; q="$(cloud_queue_lines)"; awk -F '\t' -v s="$1" '$1 == s && v == "" {v = $2} END {if (v != "") print v}' <<<"$q"; }
cloud_queue_expired() { local s; s="$(cloud_queue_since "$1")"; [ -n "$s" ] && [ "$(( $(cloud_epoch) - s ))" -ge "$(cloud_queue_max)" ]; }
cloud_queue_status_kv() { # lab status : CLOUD_FILE=<couloir> <position>/<longueur> depuis <heure>
  local l n=0 m; m="$(cloud_queue_len)"
  while IFS=$'\t' read -r l s; do
    [ -n "$l" ] || continue; n=$((n + 1)); kv CLOUD_FILE "$l $n/$m since $(compte_heure "$s" 2>/dev/null || printf '%s' "$s")"
  done < <(cloud_queue_lines)
}
# cloud_start_lock / cloud_start_unlock : la décision et le départ d'un couloir se suivent sous un verrou du projet — deux lab next
# simultanés liraient sinon la même place libre (course vue en test). Verrou d'un processus mort repris ; attente bornée
# (LAB_CLOUD_START_WAIT, 900 s : une restauration réelle peut durer plusieurs minutes), puis repris quand même, jamais bloquant.
cloud_lock_drop() { rm -f "$1/pid"; rmdir "$1" 2>/dev/null || true; }
# cloud_lock_stale <dossier> <tours> <tours de grâce> : pid écrit et mort ; sans pid, seulement après la grâce — un verrou tout juste
# pris (entre mkdir et l'écriture du pid) n'est jamais volé (revue)
cloud_lock_stale() {
  local p; p="$(cat "$1/pid" 2>/dev/null)" || p=""
  if [ -n "$p" ]; then pid_dead "$p"; else [ "$2" -ge "$3" ]; fi
}
# cloud_lock_reclaim <dossier> <tours> <tours de grâce> : retire un verrou jugé mort sous un second verrou <dossier>.reclaim, qui relit
# son pid avant de le retirer — deux attentes qui l'ont vu mort au même instant ne le retirent qu'une fois, la seconde ne vole jamais le
# verrou neuf de la première (CI rouge de #189 : deux reconstructions). rc 0 verrou retiré ; 1 vivant, ou reprise en cours ailleurs.
# Reste d'une reprise tuée : pid mort (ou absent passé la grâce), retiré.
cloud_lock_reclaim() {
  local r="$1.reclaim" rc=1
  if mkdir "$r" 2>/dev/null; then
    printf '%s\n' "$$" >"$r/pid"
    if cloud_lock_stale "$1" "$2" "$3"; then cloud_lock_drop "$1"; rc=0; fi
    cloud_lock_drop "$r"
  elif cloud_lock_stale "$r" "$2" "$3"; then cloud_lock_drop "$r"
  fi
  return "$rc"
}
# un seul verrou de départ pour le poste : le forfait est celui du compte, partagé entre projets (revue)
cloud_start_lock_dir() { printf '%s/cloud/start.lock\n' "$LAB_STATE"; }
cloud_start_lock() {
  local d n=0; d="$(cloud_start_lock_dir)"; mkdir -p "$LAB_STATE/cloud"
  until mkdir "$d" 2>/dev/null; do
    if cloud_lock_stale "$d" "$n" 10 || [ "$n" -ge "$(( ${LAB_CLOUD_START_WAIT:-900} * 2 ))" ]; then cloud_lock_drop "$d"; n=0; continue; fi
    [ "$n" != 2 ] || { log "Cloud: another start of the"; log "project is running, waiting…"; }   # 40 colonnes
    n=$((n + 1)); sleep 0.5
  done
  printf '%s\n' "$$" >"$d/pid"; CLOUD_START_LOCKED=1
}
cloud_start_unlock() { # le verrou n'est retiré que s'il est encore le sien
  [ "${CLOUD_START_LOCKED:-0}" != 1 ] || [ "$(cat "$(cloud_start_lock_dir)/pid" 2>/dev/null)" != "$$" ] || cloud_lock_drop "$(cloud_start_lock_dir)"
  CLOUD_START_LOCKED=0
}
# cloud_places <json de vm ls> → places de VM neuves libres du forfait (une VM en pause en prend une, lot 10)
cloud_places() {
  jq -r '((.limits.maxActiveVms // 0) - ([.vms[]? | select((.status // "") != "deleted")] | length))' <<<"$1" 2>/dev/null
}
# cloud_resumable <json de vm ls> <machine> : rc 0 si la VM existe et que ses vCPU tiennent dans le reste du forfait — reprendre une VM
# en pause ne prend aucune place neuve, seulement ses vCPU (lot 10) ; une VM éveillée l'est toujours
cloud_resumable() {
  jq -e --arg m "$2" '(.limits // {}) as $l | [.vms[]? | select(.id == $m)][0] as $v | $v != null
    and (($v.status // "") == "running" or ((($l.poolVcpus // 0) - ($l.usedVcpus // 0)) >= ($v.resources.vcpus // $v.vcpus // 0)))' <<<"$1" >/dev/null 2>&1
}
# cloud_queue_turn <slug> <places> : rc 0 si ce couloir passe — les places libres couvrent les couloirs inscrits avant lui
cloud_queue_turn() {
  local pos ahead; pos="$(cloud_queue_pos "$1")"
  if [ -n "$pos" ]; then ahead=$((pos - 1)); else ahead="$(cloud_queue_len)"; fi
  [ "${2:-0}" -gt "$ahead" ]
}

# ---------- réveils : VM du projet éveillée sans session (lot 05) ----------
# Les machines du projet sont celle de l'image et celle de chaque couloir (cloud_machine) ; une session vivante est la marque
# state=alive du couloir sur cette machine, une machine en préparation ou en départ porte $LAB_STATE/cloud/busy/<machine> (pid).
cloud_busy_file() { printf '%s/cloud/busy/%s\n' "$LAB_STATE" "$1"; }
cloud_busy() { mkdir -p "$(dirname "$(cloud_busy_file "$1")")"; printf '%s\n%s\n' "$$" "${SLUG:-}" >"$(cloud_busy_file "$1")"; CLOUD_BUSY="$1"; }   # pid, puis couloir préparé
cloud_busy_pid() { head -1 "$(cloud_busy_file "$1")" 2>/dev/null || true; }
cloud_busy_lane() { { sed -n 2p "$(cloud_busy_file "$1")" 2>/dev/null || true; } | cloud_plain; }
cloud_unbusy() { rm -f "$(cloud_busy_file "$1")"; }
# cloud_unbusy_mine : départ ou image fini (réussi ou non) — la marque part, un pid recyclé ne la rendrait jamais vivante (revue)
cloud_unbusy_mine() {   # seulement la sienne : un autre départ a pu poser la sienne sur la même VM partagée (lot 05 d'aiguillage-cloud)
  [ -z "${CLOUD_BUSY:-}" ] || [ "$(cloud_busy_pid "$CLOUD_BUSY")" != "$$" ] || cloud_unbusy "$CLOUD_BUSY"; CLOUD_BUSY=""
}
cloud_project_machines() { # → « <machine><TAB><rôle> » : image du projet, puis couloir <slug>
  local wt
  kv_value "$LAB_STATE/cloud/$P_NAME" machine || true; [ -z "$KV_VALUE" ] || printf '%s\tproject image\n' "$KV_VALUE"
  for wt in "$P_ROOT"/.worktrees/*/; do
    wt="${wt%/}"; kv_value "$wt/.lab/meta" cloud_machine || true; [ -n "$KV_VALUE" ] || continue
    printf '%s\tlane %s\n' "$KV_VALUE" "${wt##*/}"
  done
}
cloud_machine_live() { # <machine> [<couloir exclu>] : une session de lot vivante l'occupe, ou lab la prépare — hors le couloir exclu
  if pid_alive "$(cloud_busy_pid "$1")" && { [ -z "${2:-}" ] || [ "$(cloud_busy_lane "$1")" != "$2" ]; }; then return 0; fi
  [ -n "$(cloud_lanes_on "$1" "${2:-}")" ]
}

# ---------- VM partagée : plusieurs couloirs du projet sur une machine (lot 05 d'aiguillage-cloud) ----------
# cloud_capacity <vCPU> → sessions de lot par VM : une par 4 vCPU (16 → 4, 32 → 8), au moins une ; LAB_CLOUD_LANES_PER_VM la remplace
cloud_capacity() {
  local n="${LAB_CLOUD_LANES_PER_VM:-}"
  case "$n" in ''|*[!0-9]*|0) n="${1:-}"; case "$n" in ''|*[!0-9]*) n=4 ;; esac; n=$((n / 4)); [ "$n" -ge 1 ] || n=1 ;; esac
  printf '%s\n' "$n"
}
# cloud_lanes_on <machine> [<couloir exclu>] → couloirs dont la session vit sur la machine (marque alive), puis celui que lab y prépare
# (busy vivant), un par ligne
cloud_lanes_on() {
  local wt l out=""
  for wt in "$P_ROOT"/.worktrees/*/; do
    wt="${wt%/}"; l="${wt##*/}"; [ "$l" != "${2:-}" ] || continue
    cloud_get_set machine "$wt"; if [ "$CLOUD_GET" = "$1" ] && cloud_live "$wt"; then out="$out$l"$'\n'; fi
  done
  l="$(cloud_busy_lane "$1")"
  if [ -n "$l" ] && [ "$l" != "${2:-}" ] && pid_alive "$(cloud_busy_pid "$1")"; then
    case $'\n'"$out" in *$'\n'"$l"$'\n'*) ;; *) out="$out$l"$'\n' ;; esac
  fi
  printf '%s' "$out"
}
cloud_lanes_join() { paste -sd, - | sed 's/,$//'; }   # lignes → a,b
# cloud_lanes_paused_on <machine> [<couloir exclu>] → couloirs dont la session attend en pause sur la machine (idle-paused, lot 09) :
# comptés dans la capacité d'une VM partagée, jamais comme vivants (la garde des réveils remet leur VM en pause)
cloud_lanes_paused_on() {
  local wt l
  for wt in "$P_ROOT"/.worktrees/*/; do
    wt="${wt%/}"; l="$(basename "$wt")"; [ "$l" != "${2:-}" ] || continue
    if [ "$(cloud_get machine "$wt")" = "$1" ] && cloud_paused "$wt"; then printf '%s
' "$l"; fi
  done
  return 0
}
# cloud_machine_users <machine> [<couloir exclu>] → couloirs dont la meta cloud_machine nomme la machine (vivants ou finis)
cloud_machine_users() {
  local wt
  for wt in "$P_ROOT"/.worktrees/*/; do
    wt="${wt%/}"; [ "$(basename "$wt")" != "${2:-}" ] || continue
    [ "$(wt_meta "$wt" cloud_machine 2>/dev/null)" != "$1" ] || basename "$wt"
  done
  return 0
}
# cloud_pick_machine <json de vm ls> → « <machine>\t<statut>\t<sessions des autres>\t<capacité>\t<couloirs a,b> » : la VM du projet
# (couloirs, jamais l'image) qui a de la place, éveillée d'abord, puis en pause ; à rang égal celle du couloir ; rien sans place
cloud_pick_machine() {
  local ls="$1" img own m st cpu others n cap rank best="" bestr=9
  img="$(cloud_image_get machine)"; own="$(wt_meta "$WT" cloud_machine)"
  while IFS=$'\t' read -r m st cpu; do
    [ -n "$m" ] && [ "$m" != "$img" ] || continue
    [ "$st" != deleted ] || continue
    ! cloud_is_refused "$m" || continue   # VM qui a refusé son terminal : jamais reprise (lot 10)
    # une session en pause y garde sa place, nommée (lot 09)
    others="$(cloud_lanes_on "$m" "$SLUG"; cloud_lanes_paused_on "$m" "$SLUG" | sed 's/$/(paused)/')"   # sans espace : CLOUD_SHARED garde trois champs
    n="$(printf '%s' "$others" | grep -c . || true)"; cap="$(cloud_capacity "$cpu")"
    [ "$n" -lt "$cap" ] || continue
    rank=0; [ "$st" = running ] || rank=2; [ "$m" = "$own" ] || rank=$((rank + 1))   # éveillée d'abord, puis celle du couloir
    [ "$rank" -lt "$bestr" ] || continue
    bestr="$rank"; best="$m"$'\t'"$st"$'\t'"$n"$'\t'"$cap"$'\t'"$(printf '%s' "$others" | cloud_lanes_join)"
  done < <(cloud_project_machines | awk -F '\t' '$2 ~ /^lane / && !seen[$1]++ {print $1}' | while IFS= read -r m; do
             jq -r --arg m "$m" '.vms[]? | select(.id == $m) | "\(.id)\t\(.status // "")\t\(.resources.vcpus // .vcpus // "")"' <<<"$ls" 2>/dev/null | head -1
           done)
  [ -z "$best" ] || printf '%s\n' "$best"
}
# cloud_drop_old <machine> : ancienne VM d'un couloir passé sur une autre — supprimée si plus aucun couloir ne la référence ni ne
# l'occupe ; jamais celle de l'image ; un refus est nommé, jamais bloquant
cloud_drop_old() {
  local m="$1"
  [ -n "$m" ] && [ "$m" != "$(cloud_image_get machine)" ] || return 0
  [ -z "$(cloud_machine_users "$m" "$SLUG")" ] || { log "Cloud: former VM $m kept (other lanes)"; return 0; }
  ! cloud_machine_live "$m" "$SLUG" || return 0
  [ -n "$(cloud_vm_status "$m" 2>/dev/null)" ] || return 0   # déjà partie du Cloud (ou Cloud muet) : rien à supprimer, rien à dire
  if cloud_vm rm 300 rm "$m" >/dev/null 2>&1; then kv CLOUD_VM "$m deleted"; log "Former lane VM deleted:"; log "$m"   # 40 colonnes
  else warn "Cloud: deletion of the former VM $m refused — cmux vm rm $m"; fi
}
# cloud_wake_guard [json de vm ls] : met en pause chaque VM du projet éveillée sans session vivante, CLOUD_REVEIL=… par machine ;
# CLOUD_WOKEN = nombre remis en pause. Sans machine connue, aucun appel au Cloud ; cmux muet ou en échec : rien, jamais bloquant.
cloud_wake_guard() {
  local ls="${1:-}" known m role st; CLOUD_WOKEN=0
  known="$(cloud_project_machines | sort -u -t$'\t' -k1,1)"; [ -n "$known" ] || return 0
  [ -n "$ls" ] || ls="$(cloud_vm ls 60 ls --json 2>/dev/null)" || return 0
  while IFS=$'\t' read -r m role; do
    st="$(jq -r --arg m "$m" '[.vms[]? | select(.id == $m) | .status][0] // empty' <<<"$ls" 2>/dev/null)" || st=""
    [ "$st" = running ] || continue
    ! cloud_machine_live "$m" || continue
    if cloud_vm pause 120 pause "$m" >/dev/null 2>&1; then
      kv CLOUD_WAKE "$m paused again ($role, no live session)"; CLOUD_WOKEN=$((CLOUD_WOKEN + 1))
    else warn "Cloud: $m awake without a session ($role), pause refused — cmux vm pause $m"; fi
  done <<<"$known"
}

# ---------- ménage : VM et snapshots du projet devenus inutiles (lot 02 de cloud-racine) ----------
# Une VM est au projet si elle est restaurée d'un de ses snapshots (champ image de cmux vm ls ∈ snapshots lab-<projet> de la machine
# d'image, l'actuel compris) ; toute autre VM (autre projet, pool d'agents de cmux, machine faite à la main) n'est jamais touchée ni
# nommée. Liste blanche avant tout retrait : machine d'image, VM nommée par un couloir ouvert (meta cloud_machine, marque .lab/cloud),
# machine occupée (cloud_machine_live), VM créée il y a moins de LAB_CLOUD_CLEAN_MIN_AGE secondes (600 : fenêtre entre une restauration
# et sa marque busy) ou d'âge illisible. Snapshots lab-<projet> : l'actuel, le plus récent des autres (le précédent) et tout snapshot qui
# porte encore une VM restent ; aucun n'est retiré pendant une reconstruction d'image. Un refus de cmux est nommé, jamais bloquant.
# cloud_open_machines → « <machine><TAB><couloir> » des couloirs ouverts du projet
cloud_open_machines() {
  local wt l m
  for wt in "$P_ROOT"/.worktrees/*/; do
    wt="${wt%/}"; [ -d "$wt" ] || continue; l="$(basename "$wt")"
    m="$(wt_meta "$wt" cloud_machine)"; [ -z "$m" ] || printf '%s\t%s\n' "$m" "$l"
    m="$(cloud_get machine "$wt")"; [ -z "$m" ] || printf '%s\t%s\n' "$m" "$l"
  done
  return 0
}
# cloud_clean [<json de vm ls>] [<1 : à blanc>] : le ménage ; CLOUD_CLEANED (VM retirées), CLOUD_CLEANED_SNAPS ; CLEAN_VM=, CLEAN_SNAPSHOT=
# par retrait, CLEAN_KEPT= par élément du projet gardé si CLOUD_CLEAN_VERBOSE=1 (lab cloud <projet> clean). Cloud muet : rien, rc 0.
cloud_clean() {
  local ls="${1:-}" dry="${2:-}" img snap snaps min now open m image created l gone="" s prev="" n=0 ns=0 what tab=$'\t'
  CLOUD_CLEANED=0; CLOUD_CLEANED_SNAPS=0
  img="$(cloud_image_get machine)"; snap="$(cloud_image_get snapshot)"
  [ -n "$snap" ] || return 0   # sans image du projet, aucune VM ni aucun snapshot n'est reconnu comme sien
  [ -n "$ls" ] || ls="$(cloud_vm ls 60 ls --json 2>/dev/null)" || return 0
  jq -e '.vms' <<<"$ls" >/dev/null 2>&1 || return 0
  snaps=""
  [ -z "$img" ] || snaps="$(cloud_vm snapls 60 snapshot ls "$img" --json 2>/dev/null \
    | jq -r --arg n "lab-$P_NAME" '[.snapshots[]? | select(.name == $n)] | sort_by(.created_at) | reverse | .[].id' 2>/dev/null)" || snaps=""
  min="${LAB_CLOUD_CLEAN_MIN_AGE:-600}"; case "$min" in ''|*[!0-9]*) min=600 ;; esac
  now="$(date +%s)"; open="$(cloud_open_machines)"
  if [ "$dry" = 1 ]; then what="to delete (dry run)"; else what=deleted; fi
  while IFS="$tab" read -r m image created; do
    [ -n "$m" ] || continue
    if [ "$m" = "$img" ]; then cloud_clean_kept "$m" "project image machine"; continue; fi
    if [ -z "$image" ] || { [ "$image" != "$snap" ] && ! grep -qxF -- "$image" <<<"$snaps"; }; then continue; fi   # pas au projet : jamais touchée ni nommée
    l="$(awk -F '\t' -v m="$m" '$1 == m { print $2; exit }' <<<"$open")"
    if [ -n "$l" ]; then cloud_clean_kept "$m" "open lane $l"; continue; fi
    if cloud_machine_live "$m"; then cloud_clean_kept "$m" "in use"; continue; fi
    case "$created" in ''|*[!0-9]*) cloud_clean_kept "$m" "creation time unknown"; continue ;; esac
    if [ "$((now - created / 1000))" -lt "$min" ]; then cloud_clean_kept "$m" "created less than $min s ago"; continue; fi
    if [ "$dry" != 1 ] && ! cloud_vm rm 300 rm "$m" >/dev/null 2>&1; then
      warn "Cloud cleanup: deletion of $m refused — cmux vm rm $m"; continue
    fi
    kv CLEAN_VM "$m $what"; n=$((n + 1)); gone="$gone$m"$'\n'
    [ "$dry" = 1 ] || { cloud_unbusy "$m"; log "Cloud cleanup, VM deleted:"; log "$m"; }   # 40 colonnes
  done < <(jq -r '.vms[]? | select((.status // "") != "deleted") | "\(.id)\t\(.image // "")\t\(.createdAt // "")"' <<<"$ls" 2>/dev/null)
  if [ -n "$snaps" ] && [ -d "$LAB_STATE/cloud/image.lock" ] && pid_alive "$(cat "$LAB_STATE/cloud/image.lock/pid" 2>/dev/null)"; then
    log "Cloud cleanup: image rebuild"; log "in progress, snapshots kept."; snaps=""   # 40 colonnes
  fi
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if [ "$s" = "$snap" ]; then cloud_clean_kept "$s" "current image"; continue; fi
    if [ -z "$prev" ]; then prev="$s"; cloud_clean_kept "$s" "previous image"; continue; fi
    if cloud_snap_carried "$ls" "$s" "$gone"; then cloud_clean_kept "$s" "carries a VM"; continue; fi
    if [ "$dry" != 1 ] && ! cloud_vm snaprm 120 snapshot rm "$img" "$s" >/dev/null 2>&1; then
      warn "Cloud cleanup: deletion of snapshot $s refused — cmux vm snapshot rm $img $s"; continue
    fi
    kv CLEAN_SNAPSHOT "$s $what"; ns=$((ns + 1))
    [ "$dry" = 1 ] || { log "Cloud cleanup, snapshot deleted:"; log "$s"; }   # 40 colonnes
  done <<<"$snaps"
  CLOUD_CLEANED="$n"; CLOUD_CLEANED_SNAPS="$ns"
}
cloud_clean_kept() { [ "${CLOUD_CLEAN_VERBOSE:-0}" != 1 ] || kv CLEAN_KEPT "$1 ($2)"; }
# cloud_snap_carried <json de vm ls> <snapshot> <VM retirées, une par ligne> : rc 0 si une VM restante est restaurée de ce snapshot
cloud_snap_carried() {
  local v
  while IFS= read -r v; do
    [ -n "$v" ] || continue; grep -qxF -- "$v" <<<"$3" || return 0
  done < <(jq -r --arg s "$2" '.vms[]? | select((.status // "") != "deleted" and .image == $s) | .id' <<<"$1" 2>/dev/null)
  return 1
}
# lab cloud <projet> clean [--dry-run] : le ménage à la demande, CLEAN=<n> VM(s), <m> snapshot(s) deleted ; Cloud muet : refus nommé
cloud_clean_cmd() {
  local p="$1" dry="" ls; shift
  case "${1:-}" in '') ;; --dry-run) dry=1; shift ;; *) usage ;; esac
  [ "$#" = 0 ] || usage
  has_cmux || die "cmux missing: nothing cleaned"
  if ! ls="$(cloud_vm ls 60 ls --json 2>/dev/null)" || ! jq -e '.vms' <<<"$ls" >/dev/null 2>&1; then die "Cloud unavailable (cmux vm ls): nothing cleaned"; fi
  CLOUD_CLEAN_VERBOSE=1; cloud_clean "$ls" "$dry"; CLOUD_CLEAN_VERBOSE=0
  if [ "$dry" = 1 ]; then kv CLEAN "$CLOUD_CLEANED VM(s), $CLOUD_CLEANED_SNAPS snapshot(s) to delete (dry run)"
  else kv CLEAN "$CLOUD_CLEANED VM(s), $CLOUD_CLEANED_SNAPS snapshot(s) deleted"; fi
  kv PROJECT "$p"
}

# cloud_shared_status_kv : lab status — chaque VM du projet qui porte des sessions, CLOUD_SHARED=<machine> <a,b> <n>/<max> (lot 05
# d'aiguillage-cloud) ; le Cloud n'est lu que si une session vit ; muet : capacité de 4 vCPU, jamais un arrêt
cloud_shared_status_kv() {
  local ls="" m lanes cpu
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    lanes="$(cloud_lanes_on "$m")"; [ -n "$lanes" ] || continue
    [ -n "$ls" ] || ls="$(cloud_vm ls 60 ls --json 2>/dev/null)" || ls='{}'
    cpu="$(jq -r --arg m "$m" '[.vms[]? | select(.id == $m) | (.resources.vcpus // .vcpus // "")][0] // ""' <<<"$ls" 2>/dev/null)" || cpu=""
    kv CLOUD_SHARED "$m $(printf '%s' "$lanes" | cloud_lanes_join) $(printf '%s' "$lanes" | grep -c .)/$(cloud_capacity "$cpu")"
  done < <(cloud_project_machines | awk -F '\t' '$2 ~ /^lane / && !seen[$1]++ {print $1}')
}

# ---------- CodeRouter : comptes Claude de l'équipe, que les VM empruntent (lot 05) ----------
# cloud_coderouter_check : rc 0 si au moins un compte est sain (actif, sans pause en cours) et visible de l'équipe ; sinon
# CLOUD_WHY nomme la cause. lab ne lit que l'état des comptes : aucun jeton n'est lu ni écrit.
cloud_coderouter_json() { CMUX_QUIET=1 with_timeout 60 cmux coderouter "$@" --json </dev/null; }
# shellcheck disable=SC2016 # programme jq, rien à développer
CLOUD_CR_JQ='def until_s: (.cooldownUntil // "" | sub("\\.[0-9]+Z$"; "Z") | (try fromdateiso8601 catch 0));
  def cooling: until_s > $now;
  def sain: (.state == "active") and (cooling | not);
  def etat: if (.state != "active") then .state elif cooling then "\(.lastFailureCode // "paused") until \(until_s | strftime("%d/%m %H:%M")) UTC" else "healthy" end;'
cloud_coderouter_check() {
  local out err a
  err="$(mktemp)"
  if ! out="$(cloud_coderouter_json status 2>"$err")" || ! a="$(jq -ce '.claude_accounts' <<<"$out" 2>/dev/null)"; then
    CLOUD_WHY="CodeRouter unreadable ($(head -1 "$err" | cut -c1-120))"; CLOUD_WHY="${CLOUD_WHY% ()}"; rm -f "$err"; return 1
  fi
  rm -f "$err"
  CLOUD_WHY="$(jq -r --argjson now "$(cloud_epoch)" "$CLOUD_CR_JQ"'
    if length == 0 then "CodeRouter: no Claude account in the team"
    elif any(.[]; sain and .visibility == "team") then ""
    elif any(.[]; sain) then (map(select(sain)) | .[0] | "CodeRouter: visibility \(.visibility // "unknown") for \(.label // .id), team expected")
    else "CodeRouter: no healthy Claude account — " + (map("\(.label // .id) \(etat)") | join(", ")) end' <<<"$a" 2>/dev/null)" \
    || CLOUD_WHY="CodeRouter unreadable (accounts)"
  [ -z "$CLOUD_WHY" ]
}
# cloud_coderouter_kv : lab compte — CODEROUTER=<étiquette> <type> <visibilité> : <état>, jamais l'identifiant (masqué mais sk-ant-…)
# cloud_coderouter_a <étiquette> : rc 0 si un compte Claude de l'équipe porte déjà cette étiquette
cloud_coderouter_a() {
  local out; out="$(cloud_coderouter_json claude list 2>/dev/null)" || return 1
  jq -e --arg l "$1" 'any(.accounts[]?; .label == $l)' <<<"$out" >/dev/null 2>&1
}
# cloud_coderouter_ajouter <étiquette> : le jeton lu sur l'entrée standard devient un compte Claude de l'équipe sous cette étiquette
# (lot 04 de comptes-complets) — jamais en argument, CLAUDE_CODE_OAUTH_TOKEN d'une session retiré pour que seul stdin compte. Refus :
# rc ≠ 0 et la cause sur la sortie, un jeton éventuel masqué.
cloud_coderouter_ajouter() {
  local err rc=0
  err="$(mktemp)"
  ( unset CLAUDE_CODE_OAUTH_TOKEN; CMUX_QUIET=1 WITH_TIMEOUT_STDIN=1 with_timeout 60 cmux coderouter claude add oauth-token --label "$1" --stdin --json >/dev/null 2>"$err" ) || rc=$?
  if [ "$rc" = 124 ]; then printf 'no answer within 60 s\n'
  elif [ "$rc" != 0 ]; then sed -E 's/sk-ant-[A-Za-z0-9_-]*/sk-ant-…/g' "$err" | grep -v '^[[:space:]]*$' | head -1 | cut -c1-120; fi
  rm -f "$err"
  return "$rc"
}
cloud_coderouter_kv() {
  local out l
  if ! out="$(cloud_coderouter_json claude list 2>/dev/null)" || ! jq -e '.accounts' <<<"$out" >/dev/null 2>&1; then
    kv CODEROUTER "unreadable (cmux coderouter claude list)"; return 0
  fi
  while IFS= read -r l; do [ -z "$l" ] || kv CODEROUTER "$l"; done < <(jq -r --argjson now "$(cloud_epoch)" "$CLOUD_CR_JQ"'
    .accounts[] | "\(.label // .id) \(.kind // "?") \(.visibility // "?") : \(etat)"' <<<"$out")
  [ -n "$(jq -r '.accounts[]?' <<<"$out" | head -1)" ] || kv CODEROUTER "no Claude account in the team"
}

# ---------- fermeture : la VM du couloir supprimée (lot 05) ----------
# cloud_close_guard : une session de lot vivante sur la VM refuse la fermeture, rien n'est retiré
cloud_close_guard() {
  ! cloud_paused || die "batch session paused on the Cloud machine $(cloud_get machine), its agent waits for an answer there: lane kept — lab next $P_NAME $SLUG wakes it, --local closes it; then run lab close again"
  ! cloud_live || die "batch session alive on the Cloud machine $(cloud_get machine) (terminal $(cloud_get terminal)): lane kept — wait for its end (the Mac takes it back) or close that terminal, then run lab close again"
}
# cloud_close_vm <machine> <couloir> [workspace] : après le retrait du couloir, sa ligne d'état Cloud effacée du workspace (lot 09), sa
# VM supprimée (cmux vm rm) et annoncée ; jamais celle de l'image ni celle qu'un autre couloir garde ; VM absente ou Cloud indisponible :
# message nommé, la fermeture n'est jamais bloquée
cloud_close_vm() {
  cloud_queue_rm "$2" 2>/dev/null || true   # un couloir fermé n'attend plus de place
  [ -z "${3:-}" ] || ! has_cmux || cmx clear-status "lab-cloud-$2" --workspace "$3" >/dev/null 2>&1 || true
  [ -n "$1" ] || return 0
  cloud_start_lock; cloud_close_vm_ "$@" || true; cloud_start_unlock   # un départ qui vient de choisir la VM ne la perd pas (revue)
}
cloud_close_vm_() {
  local m="$1" lane="$2" ls users
  if [ "$m" = "$(cloud_image_get machine)" ]; then warn "Cloud: $m is the project image machine, kept"; return 0; fi
  users="$(cloud_machine_users "$m" "$lane" | cloud_lanes_join)"
  if [ -n "$users" ]; then   # VM partagée encore utilisée : gardée, le dossier du couloir y est effacé (lot 05 d'aiguillage-cloud)
    case "$users" in *,*) warn "Cloud: $m kept, lanes ${users//,/, } still use it" ;; *) warn "Cloud: $m kept, lane $users still uses it" ;; esac
  fi
  has_cmux || { [ -n "$users" ] || warn "Cloud: cmux unavailable, VM $m not deleted — cmux vm rm $m"; return 0; }
  if ! ls="$(cloud_vm ls 60 ls --json 2>/dev/null)" || ! jq -e '.vms' <<<"$ls" >/dev/null 2>&1; then
    [ -n "$users" ] || warn "Cloud unavailable: VM $m not deleted — cmux vm rm $m"; return 0
  fi
  if ! jq -e --arg m "$m" '.vms[]? | select(.id == $m)' <<<"$ls" >/dev/null 2>&1; then
    kv CLOUD_VM "$m already gone"; log "VM $m already gone from the Cloud."; return 0
  fi
  if [ -n "$users" ]; then cloud_close_shared "$m" "$lane" "$users" "$(jq -r --arg m "$m" '[.vms[]? | select(.id == $m) | .status][0] // ""' <<<"$ls")"; return 0; fi
  if cloud_machine_live "$m" "$lane"; then warn "Cloud: $m kept, a start is in preparation on it"; return 0; fi   # départ en cours
  cloud_unbusy "$m"
  if cloud_vm rm 300 rm "$m" >/dev/null 2>&1; then kv CLOUD_VM "$m deleted"; log "Lane VM deleted:"; log "$m"   # 40 colonnes
  else warn "Cloud: deletion of $m refused — cmux vm rm $m"; fi
}
# cloud_close_shared <machine> <couloir> <couloirs a,b> <statut> : la VM gardée pour les autres couloirs ; éveillée, le dossier du couloir
# (~/work/<projet>-<couloir>) et son fichier de fin effacés par cmux vm exec ; en pause, jamais réveillée : ils partent avec la VM
cloud_close_shared() {
  local m="$1" lane="$2" users="${3//,/, }" dir="/home/cmux/work/$P_NAME-$2" fin="/home/cmux/.lab-fin/$2"
  case "$4" in
    paused|stopped)
      kv CLOUD_VM "$m kept for $users (paused, not woken: $dir erased with the VM)"
      log "VM $m paused, not woken:"; log "the lane folder goes with it." ;;   # 40 colonnes
    *)
      if cloud_vm erase 120 exec --timeout 120 "$m" -- "${CLOUD_AS_CMUX[@]}" rm -rf "$dir" "$fin" >/dev/null 2>&1; then
        kv CLOUD_VM "$m kept for $users, $dir and $fin erased"; log "Lane folder erased on the"; log "shared VM $m."
      else
        kv CLOUD_VM "$m kept for $users"; warn "Cloud: $dir not erased on $m — cmux vm exec $m -- rm -rf $dir $fin"
      fi ;;
  esac
}

# ---------- décision ----------
# cloud_decide <session> <local 0|1> [<fiche>] : pose CLOUD_MODE (vm|file|local), CLOUD_WHY (motif nommé du repli), CLOUD_QUEUE
# (position n/m en file), CLOUD_SIZE, CLOUD_CPU et CLOUD_MACHINE (la machine du couloir, réutilisée). Seule la session d'exécution
# (run) part ; tout le reste est local. Lot 01 d'aiguillage-cloud : EXECUTION (cloud|mac) et EXECUTION_WHY disent le choix que lab
# next annonce ; la fiche décide (cloud_execution_line) après les refus du poste, avant les prérequis techniques.
cloud_decide() {
  EXECUTION_WHY=""
  cloud_decide_ "$@"
  if [ "$CLOUD_MODE" = local ]; then EXECUTION=mac; EXECUTION_WHY="$CLOUD_WHY"; else EXECUTION=cloud; fi
}
# cloud_execution_line <fiche> : rc 1 si la fiche garde le Mac — besoin écrit, signal dur des étapes, valeur illisible (Mac par
# sécurité), puis ligne absente (Mac par défaut depuis le lot 01 de session-unique) —, CLOUD_WHY le nomme ; rc 0 pour une ligne
# « cloud » écrite, EXECUTION_WHY le dit.
cloud_execution_line() {
  local x mode need detail n raw sig said needs
  x="$(lot_execution "${1:-}" | cloud_plain)"   # texte écrit dans la fiche, par une session VM peut-être : aucun octet de contrôle au terminal
  mode="$(cut -f1 <<<"$x")"; need="$(cut -f2 <<<"$x")"; detail="$(cut -f3 <<<"$x")"; n="$(cut -f4 <<<"$x")"; raw="$(cut -f5- <<<"$x")"
  needs="$(sed -e 's/ /, /g' -e 's/, \([^,]*\)$/ or \1/' <<<"$LOT_EXECUTION_NEEDS")"
  if [ "$mode" = mac ]; then
    case " $LOT_EXECUTION_NEEDS " in
      *" $need "*) CLOUD_WHY="$need${detail:+: $detail}" ;;
      *) if [ -z "$need" ]; then CLOUD_WHY="need not named (expected $needs)"
         else CLOUD_WHY="unknown need \"$need\" (expected $needs)${detail:+: $detail}"; fi ;;
    esac
    return 1
  fi
  sig="$(lot_mac_signal "${1:-}" | cloud_plain)"
  if [ -n "$sig" ]; then   # le Mac gagne sur un signal dur, même contre une ligne cloud : motif dit, ni question ni arrêt
    case "$mode" in cloud) said="the line said cloud" ;; absent) said="no Execution line" ;; *) said="line $n unreadable" ;; esac
    CLOUD_WHY="$(cut -f1 <<<"$sig"): $(cut -f2 <<<"$sig") in Steps, $said"; return 1
  fi
  [ "$mode" != unreadable ] || { CLOUD_WHY="line $n of $(basename "$1") unreadable (\"$raw\"): Mac for safety"; return 1; }
  [ "$mode" = cloud ] || { CLOUD_WHY="by default, no Execution line"; return 1; }
  EXECUTION_WHY="written in the batch file${detail:+: $detail}"
}
# cloud_execution_say <session> : lab next annonce où tourne l'exécution du lot, une ligne repliée à la largeur du terminal ; les
# autres sessions sont toujours locales, sans annonce
cloud_execution_say() {
  [ "$1" = run ] || return 0
  kv EXECUTION "$EXECUTION"; kv EXECUTION_WHY "$EXECUTION_WHY"
  log_wrap "Execution: $EXECUTION — $EXECUTION_WHY"
  [ "$EXECUTION" = cloud ] && [ "${CLOUD_MODE:-}" = vm ] && [ -n "${CLOUD_SHARED:-}" ] || return 0   # VM partagée (lot 05 d'aiguillage-cloud)
  local sm sl sn; read -r sm sl sn <<<"$CLOUD_SHARED"   # « <machine> <a,b> <n/max> »
  kv CLOUD_SHARED "$CLOUD_SHARED"; log_wrap "VM $sm shared with ${sl//,/, } ($sn)"
}
cloud_decide_() {
  local session="$1" local_flag="$2" lot="${3:-}" ls err size m tab=$'\t' places full awake
  CLOUD_MODE=local; CLOUD_WHY=""; CLOUD_SIZE=""; CLOUD_CPU=""; CLOUD_MACHINE=""; CLOUD_QUEUE=""; CLOUD_SHARED=""
  [ "$session" = run ] || { CLOUD_WHY="session $session always local"; return 0; }
  [ "$local_flag" != 1 ] || { CLOUD_WHY="--local"; return 0; }
  cloud_resolve "$P_NAME" "$WT"
  case "$CLOUD" in yes) ;; no) CLOUD_WHY="cloud=no ($CLOUD_SOURCE)"; return 0 ;; *) CLOUD_WHY="$(cloud_note)"; return 0 ;; esac
  [ "$AGENT" = claude ] || { CLOUD_WHY="agent $AGENT: the Cloud only runs claude"; return 0; }
  [ "$P_DOCS" = repo ] || { CLOUD_WHY="batch files outside the repository (docs=$P_DOCS): the VM would not see them"; return 0; }
  [ -z "$(wt_meta "$WT" stacked_on)" ] || { CLOUD_WHY="stacked batch, never pushed before $(wt_meta "$WT" stacked_on) is merged"; return 0; }
  cloud_need_keeps_mac "$lot" || return 0   # besoin trouvé sur la VM, retenu hors du dépôt (lot 02) : avant la ligne de la fiche
  cloud_execution_line "$lot" || return 0   # la fiche garde le Mac : ni clé, ni CodeRouter, ni forfait lus
  cloud_gh_ready || return 0   # la clé de déploiement se crée par gh : sans gh authentifié ni remote GitHub, le Mac (motif nommé)
  cloud_coderouter_check || return 0   # la VM route claude par CodeRouter : sans compte sain, la session y tomberait aussitôt
  err="$(mktemp)"
  if ! ls="$(cloud_vm ls 60 ls --json 2>"$err")" || ! jq -e '.limits' <<<"$ls" >/dev/null 2>&1; then
    CLOUD_WHY="Cloud unavailable ($(head -1 "$err" | cut -c1-120))"; CLOUD_WHY="${CLOUD_WHY% ()}"; rm -f "$err"; return 0
  fi
  rm -f "$err"
  cloud_wake_guard "$ls"   # une VM du projet réveillée seule prend une place : remise en pause avant de compter (lot 05)
  [ "${CLOUD_WOKEN:-0}" = 0 ] || ls="$(cloud_vm ls 60 ls --json 2>/dev/null)" || ls=""
  # ménage au fil de l'eau (lot 02 de cloud-racine) : VM orphelines du projet et anciens snapshots retirés avant de compter les places
  cloud_clean "$ls"; [ "${CLOUD_CLEANED:-0}" = 0 ] || ls="$(cloud_vm ls 60 ls --json 2>/dev/null)" || ls=""
  # une VM du projet avec de la place, éveillée d'abord (lot 05 d'aiguillage-cloud) ; partagée : CLOUD_SHARED la nomme avec ses couloirs
  m="$(cloud_pick_machine "$ls")"
  if [ -n "$m" ]; then
    CLOUD_MACHINE="$(cut -f1 <<<"$m")"
    [ "$(cut -f3 <<<"$m")" = 0 ] || CLOUD_SHARED="$CLOUD_MACHINE $(cut -f5 <<<"$m") $(( $(cut -f3 <<<"$m") + 1 ))/$(cut -f4 <<<"$m")"
  elif [ -z "$(cloud_image_get snapshot)" ]; then
    CLOUD_WHY="no Cloud image for the project: lab cloud $P_NAME image"; return 0
  fi
  size="$(cloud_size "$ls")" || size=""   # jq en échec (schéma changé) : repli nommé, jamais un arrêt muet
  places="$(cloud_places "$ls")" || places=0; case "$places" in ''|*[!0-9-]*) places=0 ;; esac
  # une VM existante du projet ne prend aucune place de plus (une VM en pause garde la sienne, lot 10), ni ne passe par la file :
  # éveillée, elle part ; en pause, seulement si ses vCPU tiennent dans le reste du forfait
  full=""; awake=0
  if [ -n "$CLOUD_MACHINE" ]; then
    if cloud_resumable "$ls" "$CLOUD_MACHINE"; then awake=1; else full="plan full (no free vCPU to resume $CLOUD_MACHINE)"; fi
  fi
  case "$size" in
    plein*) [ "$awake" = 1 ] || [ -n "$full" ] || full="plan full (${size#plein"$tab"})" ;;
    '') CLOUD_WHY="plan unreadable in cmux vm ls"; return 0 ;;
    *) CLOUD_SIZE="${size%%"$tab"*}"; CLOUD_CPU="${size#*"$tab"}"; CLOUD_CPU="${CLOUD_CPU%% *}"
       # des places restent, mais des couloirs inscrits avant celui-ci les attendent : ordre d'arrivée (lot 05)
       [ "$awake" = 1 ] || [ -n "$full" ] || cloud_queue_turn "$SLUG" "$places" || full="plan full for the queue ($places slot(s), $(cloud_queue_len) lane(s) waiting)" ;;
  esac
  if [ -n "$full" ]; then   # lot 05 : en file, au-delà du délai en local nommé
    if cloud_queue_expired "$SLUG"; then
      cloud_queue_rm "$SLUG"; CLOUD_WHY="queue: $(cloud_queue_delay) wait exceeded, $full"; return 0
    fi
    cloud_queue_add "$SLUG"
    CLOUD_MODE="file"; CLOUD_WHY="$full"; CLOUD_QUEUE="position $(cloud_queue_pos "$SLUG")/$(cloud_queue_len)"; return 0
  fi
  [ -z "$CLOUD_MACHINE" ] || { CLOUD_SIZE=""; CLOUD_CPU=""; }   # machine du couloir : ni retaillée, ni annoncée à une autre taille
  CLOUD_MODE=vm
}

# ---------- lancement ----------
# cloud_goal_prompt <fiche> : le Goal de la VM — batch-run jusqu'aux preuves poussées, ni batch-end ni lab (absent de la VM) ; un
# blocage sur un besoin du Mac s'écrit « blocked: need <besoin>: <détail> » (lot 02 d'aiguillage-cloud) : le Mac reprend le lot seul ;
# toute autre question s'attend dans le terminal, comme en local — l'alerte native de cmux fait sonner le pane du couloir (lot 09)
cloud_goal_prompt() {
  local lot="$1" rel tp objective
  rel="$(prompt_path "$lot")"; tp="$(prompt_path "$(treeplan_file "$(lot_docs "$lot")" "$SLUG")")"; objective="$(lot_objective "$lot")"
  [ -n "$objective" ] || objective="carry out the batch described in $rel"
  printf '/goal Execute %s on this Cloud machine, without closing it. Goal: %s Start by reading %s and the whole batch, Handoff included, then apply the batch-run skill: code and tests together, evidence in the log, each commit pushed to %s; tests tagged macos are replayed on the Mac. A command killed with 137, 143 or 144 hit the memory cap: fix the command, do not retry it as is. Do not apply batch-end and never run lab, absent here: the Mac takes the closing back. A question or a blocker: ask it in this terminal and wait for the answer, the user types it here. When the evidence, the log and the Handoff of the batch file are pushed, write the code done in ~/.lab-fin/%s; when only the Mac can go on, push the log, then write there "blocked: need <need>: <detail>" (need among %s: the Mac takes the batch back alone); when impossible to go on even with an answer, push the log and write there "failed: <reason>"; then stop.' \
    "$rel" "$objective" "$tp" "$(branch_name "$WT")" "$SLUG" "${LOT_EXECUTION_NEEDS// /, }"
}
# cloud_end_prompt <fiche> : le Goal du Mac après la VM — vérifier sur le Mac ce que la VM ne pouvait pas, puis batch-end
cloud_end_prompt() {
  local lot="$1" rel tp objective
  rel="$(prompt_path "$lot")"; tp="$(prompt_path "$(treeplan_file "$(lot_docs "$lot")" "$SLUG")")"; objective="$(lot_objective "$lot")"
  printf '/goal Close %s: its run session was carried out on the Cloud machine %s, its commits are pulled into this lane. Goal: %s Read %s and the whole batch, log and Handoff included; first read the diff that came from the VM (git log and git diff from the base), written without asking for permission, before running anything here; then replay on the Mac the tests tagged macos, the screens and the checks, complete the missing evidence, then apply the batch-end skill. Finish only when the batch is closed, or stop with the exact blocker.' \
    "$rel" "$(cloud_get machine)" "${objective:-see the batch file.}" "$tp"
}
# CLOUD_START_MARK : la ligne que le terminal VM écrit juste avant exec claude, avec le fichier repère ~/.lab-fin/<couloir>.started
# que cloud_start attend : le journal d'un terminal vivant ne garde que sa fin, le repère y défile (mesuré au lot 10)
CLOUD_START_MARK="lab: agent starting on the VM"
# cloud_vm_script <fiche> → le script bash du terminal VM : clone ou mise à jour en SSH par la clé de déploiement du couloir
# (GIT_SSH_COMMAND et core.sshCommand pointant ~/.ssh/lab-<slug>), branche du lot alignée sur GitHub, claude interactif ; un arbre sale
# (session tuée au milieu) est rangé dans un stash nommé lab-<date>, annoncé, jamais committé ni jeté (cloud-agent-mort). Aucun GH_TOKEN,
# aucun gh : la VM ne fait que du git en SSH (lot 06 d'aiguillage-cloud). Chaque commande de l'agent passe par lib/memcap.sh
# (CLAUDE_CODE_SHELL_PREFIX) : une commande emballée meurt avant lui (lot 02 de cloud-agent-mort).
cloud_vm_script() {
  local br dir url; br="$(branch_name "$WT")"; dir="work/$P_NAME-$SLUG"; url="$(cloud_repo_ssh_url)"
  # shellcheck disable=SC2016 # évalué sur la VM
  printf 'set -e; export GIT_SSH_COMMAND="%s"; mkdir -p ~/.lab-fin ~/work; rm -f ~/.lab-fin/%s ~/.lab-fin/%s.started; printf "%%s\\n" %s >~/.lab-fin/memcap; chmod +x ~/.lab-fin/memcap; LAB_CLOUD_MEM_MAX=%s ~/.lab-fin/memcap --setup; export CLAUDE_CODE_SHELL_PREFIX="$HOME/.lab-fin/memcap"; [ -d ~/%s/.git ] || git clone -q %s ~/%s; cd ~/%s; git config core.sshCommand "$GIT_SSH_COMMAND"; git fetch -q origin; if [ -n "$(git status --porcelain)" ]; then s="lab-$(date -u +%%Y%%m%%dT%%H%%M%%SZ)"; echo "lab: uncommitted changes kept in git stash $s (never committed, never dropped):"; git status --porcelain; git -c user.name=lab -c user.email=lab stash push -q -u -m "$s"; fi; git checkout -q -B %s %s; echo "%s"; : >~/.lab-fin/%s.started; exec claude --permission-mode bypassPermissions %s\n' \
    "$(cloud_ssh_opts "${CLOUD_ROUTE:-22}")" "$SLUG" "$SLUG" "$(shell_quote "$(cat "$LAB_ROOT/lib/memcap.sh")")" "$(shell_quote "${LAB_CLOUD_MEM_MAX:-}")" "$dir" "$(shell_quote "$url")" "$dir" "$dir" "$(shell_quote "$br")" "$(shell_quote "origin/$br")" "$CLOUD_START_MARK" "$SLUG" "$(shell_quote "$(cloud_goal_prompt "$1")")"
}
# cloud_lane_ws → « <workspace>⇥<terminal initial> » : l'espace local du couloir, où le terminal VM s'affiche, et le terminal né avec lui
# si cet appel l'a créé (vide sinon), à rendre une fois le terminal VM affiché
cloud_lane_ws() {
  local ws initial="" target; ws="$(wt_ws "$WT")"
  if [ -z "$ws" ] || ! cmux_ws_exists "$ws"; then
    target="$(cmux_prepare_project "$P_NAME" "$P_ROOT")" || target=""
    IFS=$'\t' read -r _ ws initial <<<"$target"
  fi
  printf '%s\t%s\n' "$ws" "$initial"
}
# cloud_open <machine> <workspace distant> <terminal> : le terminal VM affiché dans le workspace du couloir, son pane local retenu
# (pane, pane_ws : « OK surface=<id> workspace=<id> terminal=<id> », forme mesurée au lot 09) pour les alertes et la ligne d'onglet
cloud_open() {
  local ws initial out; ws="$(cloud_lane_ws)"; initial="${ws#*$'\t'}"; ws="${ws%%$'\t'*}"
  if ! out="$(cloud_vm open 60 open "$1/$2/$3" ${ws:+--workspace "$ws"} --no-focus 2>/dev/null)"; then
    warn "Cloud: terminal $3 not shown here — cmux vm open $1/$2/$3"; return 0
  fi
  cloud_put pane "$(printf '%s\n' "$out" | sed -n 's/.*surface=\([^ ]*\).*/\1/p' | head -1)"
  cmux_drop_initial "$ws" "$initial" "$(cloud_get pane)" "$P_NAME"
  cloud_put pane_ws "$(printf '%s\n' "$out" | sed -n 's/.*workspace=\([^ ]*\).*/\1/p' | head -1)"
}
# cloud_pane [wt] → « <workspace><TAB><surface> » du pane local qui affiche le terminal VM, sinon le workspace du couloir seul
cloud_pane() { local ws; ws="$(cloud_get pane_ws "${1:-$WT}")"; [ -n "$ws" ] || ws="$(wt_ws "${1:-$WT}")"; printf '%s\t%s\n' "$ws" "$(cloud_get pane "${1:-$WT}")"; }
# cloud_alert <corps> [workspace surface] : notification cmux ciblée sur l'onglet donné, sinon sur le pane du terminal VM ; refusée
# (pane fermé) : le workspace seul. Le veilleur hérite des variables de cmux de la session qui a lancé lab next : écartées, sinon
# cmux prendrait cette surface-là pour cible (vu en réel au lot 06).
cloud_alert() {
  local ws="${2:-}" s="${3:-}"
  [ -n "$s" ] || IFS=$'\t' read -r ws s < <(cloud_pane)
  has_cmux || return 0
  (
    unset CMUX_SURFACE_ID CMUX_PANEL_ID CMUX_TAB_ID
    if [ -n "$ws" ] && [ -n "$s" ] && cmx notify --title "lab · $SLUG" --body "$1" --workspace "$ws" --surface "$s" >/dev/null 2>&1; then exit 0; fi
    cmux_notify "lab · $SLUG" "$1" "$ws"
  ) || true
}
# cloud_line <texte> : la ligne d'état de la session Cloud dans la barre latérale du workspace du couloir, une clé par couloir (le
# workspace du projet peut en accueillir plusieurs)
cloud_line() {
  local ws; ws="$(cloud_pane | cut -f1)"; [ -n "$ws" ] && has_cmux || return 0
  cmx set-status "lab-cloud-$SLUG" "$SLUG · $1" --workspace "$ws" --icon cloud >/dev/null 2>&1 || true
}
# cloud_restore <snapshot> <fichier> [<lanceur>] : la restauration de l'image, une seule fonction pour la suite et le départ de couloir
# (lot 01 de cloud-racine). Sortie de cmux (stdout et stderr) dans le fichier, la machine dans CLOUD_RESTORED ; le lanceur (cloud_suite_bg)
# reçoit « <fichier> <commande…> ». HTTP 502 ou retryAfterSeconds → deux nouveaux essais au plus, après le délai annoncé (5 s sinon), borné
# par LAB_CLOUD_RESTORE_WAIT_MAX (10 s) ; HTTP 402 vm_active_limit_exceeded → plan full avec les machines comptées. rc 1 avec CLOUD_WHY.
cloud_restore_one() { cloud_vm restore 600 restore "$2" --json 2>"$1"; }   # <fichier d'erreur> <snapshot> : un essai, le JSON sur stdout
cloud_restore() {
  local snap="$1" f="$2" n=0 w max="${LAB_CLOUD_RESTORE_WAIT_MAX:-10}" code; shift 2
  CLOUD_RESTORED=""
  while :; do
    n=$((n + 1))
    # le JSON seul dans le fichier, la sortie d'erreur à côté : un avis de cmux avant le JSON d'une réussite ne la rend jamais
    # illisible (une seconde restauration laisserait la première VM orpheline, revue)
    if [ "$#" -gt 0 ]; then "$@" "$f" cloud_restore_one "$f.err" "$snap" || true
    else cloud_restore_one "$f.err" "$snap" >"$f" || true; fi
    CLOUD_RESTORED="$({ jq -r '.machine // .id // empty' "$f" 2>/dev/null || true; } | head -1)"
    [ -z "$CLOUD_RESTORED" ] || return 0
    if grep -qE 'vm_active_limit_exceeded|HTTP 402' "$f" "$f.err" 2>/dev/null; then
      CLOUD_WHY="plan full (HTTP 402, paused VMs included): $(cat "$f" "$f.err" 2>/dev/null | sed -n 's/.*[Mm]achines [^:]*: *\([^.]*\)\..*/\1/p' | head -1 | cloud_plain | cut -c1-200)"
      CLOUD_WHY="${CLOUD_WHY%: }"; return 1
    fi
    if ! grep -qE 'HTTP 502|retryAfterSeconds' "$f" "$f.err" 2>/dev/null; then CLOUD_WHY="restore of image $snap refused"; return 1; fi
    code="$(cat "$f" "$f.err" 2>/dev/null | grep -oE 'HTTP 5[0-9][0-9]' | head -1)" || code=""; code="${code:-HTTP 502}"
    [ "$n" -lt 3 ] || { CLOUD_WHY="Cloud unavailable: restore of image $snap answered $code $n times"; return 1; }
    w="$(cat "$f" "$f.err" 2>/dev/null | sed -n 's/.*retryAfterSeconds: *\([0-9][0-9]*\).*/\1/p' | head -1)"; w="${w:-5}"
    case "$max" in ''|*[!0-9]*) max=10 ;; esac; [ "$w" -le "$max" ] || w="$max"
    log "Cloud: restore answered $code,"; log "retry $n/2 in $w s."   # 40 colonnes
    sleep "$w"
  done
}
# cloud_start <fiche> : branche poussée, machine prête (VM du projet choisie par cloud_pick_machine, jamais agrandie, sinon restaurée du snapshot et agrandie au palier), clé de
# déploiement du couloir purgée puis créée, terminal VM lancé, affiché dans le workspace du couloir, marque écrite, veilleur armé.
# rc 1 : CLOUD_WHY nomme l'étape, la clé de ce couloir est révoquée (chacun a la sienne) et la session part en local.
cloud_start() {
  local lot="$1" br m out term rws ws snap old size
  br="$(branch_name "$WT")"; old="$(wt_meta "$WT" cloud_machine)"
  [ -z "$(git -C "$WT" status --porcelain --untracked-files=normal -- . ':!.lab' 2>/dev/null)" ] \
    || { CLOUD_WHY="uncommitted changes in $WT: the VM starts from GitHub"; return 1; }
  git -C "$WT" push -q -u "$P_REMOTE" "$br" 2>/dev/null || { CLOUD_WHY="push of $br refused: the VM starts from GitHub"; return 1; }
  m="$CLOUD_MACHINE"
  if [ -n "$m" ]; then
    cloud_busy "$m"   # éveillée avant la marque vivante : la garde des réveils ne la remet pas en pause (lot 05)
    cloud_vm resume 120 resume "$m" >/dev/null 2>&1 || true   # une machine éveillée répond déjà ; un vrai refus se verra au terminal
    [ "$m" = "$old" ] || meta_set "$WT" cloud_machine "$m"   # VM partagée rejointe (lot 05 d'aiguillage-cloud), jamais agrandie
  else
    # jamais la machine de l'image elle-même : deux couloirs s'y retrouveraient, et le premier fini mettrait l'autre en pause (revue)
    snap="$(cloud_image_get snapshot)"
    [ -n "$snap" ] || { CLOUD_WHY="restore of image none refused"; return 1; }
    cloud_image_ensure || return 1   # image périmée reconstruite d'abord, sous verrou (lot 01 de cloud-racine)
    snap="$(cloud_image_get snapshot)"; out="$(mktemp)"
    cloud_restore "$snap" "$out" || { rm -f "$out" "$out.err"; return 1; }   # CLOUD_WHY posé : 402, 502 répétés ou refus
    rm -f "$out" "$out.err"; m="$CLOUD_RESTORED"
    cloud_busy "$m"; log "Project image restored:"; log "$m"   # 40 colonnes
    if [ -n "$CLOUD_CPU" ]; then
      cloud_vm resize 300 resize "$m" --cpu "$CLOUD_CPU" --memory "${CLOUD_SIZE%g}" >/dev/null 2>&1 \
        || warn "Cloud: $m not resized to $CLOUD_SIZE (original size kept)"
    fi
    meta_set "$WT" cloud_machine "$m"
  fi
  # l'ancienne VM du couloir n'est plus référencée par lui : supprimée si orpheline, même si la suite du départ échoue (revue)
  [ -z "$old" ] || [ "$old" = "$m" ] || cloud_drop_old "$old"
  # clé de déploiement de ce couloir : d'abord la purge des clés lab-cloud-<slug>-* restées d'une session plantée (C3), puis une neuve
  cloud_key_purge "$SLUG"
  cloud_key_make "$m" "$SLUG" || return 1   # CLOUD_WHY posé ; échec du scope → repli local nommé (la garde au décide était légère)
  # l'accès GitHub de la VM prouvé avant le terminal : un clone en échec tuait le terminal en 128 avant l'agent (lot 10)
  if ! cloud_access_check "$m"; then
    cloud_key_remove "$m" "$CLOUD_KEY_ID" "$SLUG" || warn "Cloud: $CLOUD_KEY_PROOF"; return 1
  fi
  kv CLOUD_ACCESS "$CLOUD_ACCESS"
  if ! cloud_terminal_new "$m" "$lot"; then
    cloud_key_remove "$m" "$CLOUD_KEY_ID" "$SLUG" || warn "Cloud: $CLOUD_KEY_PROOF"   # chaque couloir révoque sa propre clé
    # VM reprise qui refuse son terminal : écartée pour de bon, une seule VM neuve restaurée de l'image (lot 10)
    # une coupure de la liaison locale avec l'application cmux n'est jamais la faute de la VM : elle n'est pas écartée (revue)
    if [ -n "$CLOUD_MACHINE" ] && [ -z "${CLOUD_REFUSED:-}" ] && [ -n "$(cloud_image_get snapshot)" ] \
       && case "$CLOUD_TERMINAL_ERR" in *"Socket closed before reply"*) false ;; *) true ;; esac; then
      cloud_refuse "$m"; cloud_unbusy_mine; CLOUD_MACHINE=""
      # la VM neuve est taillée comme un départ neuf (cloud_decide_ n'a pas mesuré de palier pour une VM du couloir), forfait relu
      size="$(cloud_size "$(cloud_vm ls 60 ls --json 2>/dev/null)")" || size=""
      case "$size" in plein*|'') ;; *) CLOUD_SIZE="${size%%$'\t'*}"; CLOUD_CPU="${size#*$'\t'}"; CLOUD_CPU="${CLOUD_CPU%% *}" ;; esac
      log "VM refused its terminal:"; log "$m"; log "set aside, new VM restored."   # 40 colonnes
      cloud_start "$lot"; return
    fi
    CLOUD_WHY="terminal not started on $m after ${LAB_CLOUD_TERMINAL_TRIES:-3} tries${CLOUD_TERMINAL_ERR:+: $CLOUD_TERMINAL_ERR}${CLOUD_REFUSED:+ (after $CLOUD_REFUSED refused its terminal and was set aside)}"; return 1
  fi
  out="$CLOUD_TERMINAL_OUT"; term="$(jq -r '.terminal_id // empty' <<<"$out")"
  # le terminal écrit son repère avant exec claude : une sortie avant lui est nommée ici, par ses dernières lignes (lot 10)
  if ! cloud_terminal_started "$m" "$term"; then
    cloud_key_remove "$m" "$CLOUD_KEY_ID" "$SLUG" || warn "Cloud: $CLOUD_KEY_PROOF"; return 1
  fi
  rws="$(jq -r '.remote_workspace_id // empty' <<<"$out")"
  : >"$(cloud_marker)"
  cloud_put lot "$(basename "$lot" .md)"; cloud_put machine "$m"; cloud_put terminal "$term"; cloud_put workspace "$rws"
  cloud_put branch "$br"; cloud_put since "$(cloud_now)"; cloud_put state alive; cloud_put detail "batch session on $m"
  cloud_put key_id "$CLOUD_KEY_ID"; cloud_put key_title "$CLOUD_KEY_TITLE"   # id de la clé pour la révocation à la fin (marque et veilleur)
  cloud_open "$m" "$rws" "$term"; cloud_line "Cloud: agent working"
  CLOUD_MACHINE="$m"; CLOUD_TERMINAL="$term"
  # marque vivante écrite : le départ suivant la voit ; préparation et verrou rendus avant d'armer le veilleur — sa fin (cloud_finish)
  # reprend le verrou
  cloud_unbusy_mine; cloud_start_unlock
  # référence des pushs (lot 02) : la tête que lab vient de pousser, à l'heure du départ — 60 min sans push comptent d'ici
  watch_arm cloud "$br" machine="$m" terminal="$term" key_id="$CLOUD_KEY_ID" push_sha="$(git -C "$WT" rev-parse HEAD)" push_at="$(cloud_epoch)" pushes=0 >/dev/null
}

# cloud_terminal_new <machine> <fiche> : le terminal VM ouvert, sa sortie JSON dans CLOUD_TERMINAL_OUT. Réessayé
# LAB_CLOUD_TERMINAL_TRIES fois (3), LAB_CLOUD_ACCESS_STEP secondes d'écart (5) : la liaison avec l'application cmux du Mac se coupe par
# moments (« Socket closed before reply », mesuré au lot 10). rc 1 : CLOUD_TERMINAL_ERR, la dernière ligne d'erreur de cmux, masquée.
cloud_terminal_new() {
  local m="$1" script err n=0 tries="${LAB_CLOUD_TERMINAL_TRIES:-3}"
  script="$(cloud_vm_script "$2")"; err="$(mktemp)"; CLOUD_TERMINAL_OUT=""; CLOUD_TERMINAL_ERR=""
  # le repère d'un départ précédent (VM reprise) effacé d'abord : jamais pris pour celui de ce terminal (revue)
  # shellcheck disable=SC2016 # évalué sur la VM
  cloud_vm started 60 exec --timeout 60 "$m" -- "${CLOUD_AS_CMUX[@]}" sh -c 'rm -f "$HOME/.lab-fin/$1.started"' sh "$SLUG" >/dev/null 2>&1 || true
  while [ "$n" -lt "$tries" ]; do
    n=$((n + 1))
    if CLOUD_TERMINAL_OUT="$(CMUX_QUIET=1 with_timeout 120 cmux surface new-terminal --machine "$m" --no-open --name "$SLUG" --json -- bash -lc "$script" </dev/null 2>"$err")" \
       && [ -n "$(jq -r '.terminal_id // empty' <<<"$CLOUD_TERMINAL_OUT" 2>/dev/null)" ]; then
      rm -f "$err"; return 0
    fi
    CLOUD_TERMINAL_ERR="$(grep -v '^[[:space:]]*$' "$err" | tail -1 | cloud_plain | cloud_mask | cut -c1-160)" || CLOUD_TERMINAL_ERR=""
    [ "$n" -ge "$tries" ] || sleep "${LAB_CLOUD_ACCESS_STEP:-5}"
  done
  rm -f "$err"; return 1
}
# cloud_terminal_started <machine> <terminal> : rc 0 le fichier repère existe sur la VM, ou LAB_CLOUD_START_MAX secondes (120)
# passent sans sortie (jamais un échec sur un doute : le veilleur le suit) ; rc 1 sorti avant le repère, CLOUD_WHY nomme le code et les
# dernières lignes masquées
cloud_terminal_started() {
  local m="$1" t="$2" t0="$SECONDS" out code
  while :; do
    # shellcheck disable=SC2016 # évalué sur la VM
    out="$(cloud_vm started 60 exec --timeout 60 "$m" -- "${CLOUD_AS_CMUX[@]}" sh -c 'test -f "$HOME/.lab-fin/$1.started" && echo started' sh "$SLUG" 2>/dev/null)" || out=""
    case "$out" in *started*) return 0 ;; esac
    out="$(cloud_vm wait 40 terminal wait-exit "$m" "$t" --timeout 5 2>&1)" || true
    code="$(printf '%s\n' "$out" | sed -nE 's/.*exited (code|signal)=([0-9]+).*/\1 \2/p' | tail -1)"
    if [ -n "$code" ]; then
      out="$(cloud_terminal_tail "$m" "$t")"
      CLOUD_WHY="terminal exited with $code on $m before the agent${out:+: $out}"; return 1
    fi
    if [ $((SECONDS - t0)) -ge "${LAB_CLOUD_START_MAX:-120}" ]; then
      log "Agent not started after $(cloud_delay_text "${LAB_CLOUD_START_MAX:-120}"):"; log "the watcher follows it."; return 0   # 40 colonnes
    fi
    case "$out" in *pending*|*"still running"*) ;; *) sleep "${LAB_CLOUD_ACCESS_STEP:-5}" ;; esac   # Cloud muet : on espace
  done
}
# cloud_refused_file → $LAB_STATE/cloud/refused/<projet> : une VM par ligne, écartée après avoir refusé son terminal (lot 10) ;
# cloud_pick_machine ne la reprend jamais
cloud_refused_file() { printf '%s/cloud/refused/%s\n' "$LAB_STATE" "$P_NAME"; }
cloud_is_refused() { grep -qxF "$1" "$(cloud_refused_file)" 2>/dev/null; }
# cloud_refuse <machine> : inscrite comme refusée, référence du couloir retirée ; orpheline (aucun couloir ne la référence ni ne
# l'occupe), elle est supprimée — une VM en pause garde sa place au forfait, la VM neuve en a besoin (lot 10) ; sinon mise en pause
# sans session d'un autre couloir. CLOUD_REFUSED la retient pour le second départ.
cloud_refuse() {
  local f; f="$(cloud_refused_file)"; mkdir -p "$(dirname "$f")"
  cloud_is_refused "$1" || printf '%s\n' "$1" >>"$f"
  [ "$(wt_meta "$WT" cloud_machine)" != "$1" ] || meta_unset "$WT" cloud_machine
  CLOUD_REFUSED="$1"; kv CLOUD_REFUSED "$1"
  cloud_drop_old "$1"
  [ -n "$(cloud_vm_status "$1" 2>/dev/null)" ] || return 0   # supprimée, ou déjà partie
  [ -n "$(cloud_lanes_on "$1" "$SLUG")" ] || cloud_vm pause 120 pause "$1" >/dev/null 2>&1 || true
}

# ---------- veilleur de file : place libre → lab next relancé (lot 05) ----------
# cloud_queue_enter <fiche> : le couloir est inscrit (cloud_decide) ; son veilleur est armé, l'onglet de la session qui a lancé lab next
# rendu. Rien ne part en local : le veilleur relance lab next dès que le couloir passe, ou au délai (repli local nommé).
cloud_queue_enter() {
  local br; br="$(branch_name "$WT")"
  kv CLOUD_RUN "file ($CLOUD_QUEUE)"; kv CLOUD_WHY "$CLOUD_WHY"
  log "Cloud plan full: lane queued,"; log "$CLOUD_QUEUE. It starts by itself"   # 40 colonnes
  log "as soon as a slot frees up;"; log "locally after $(cloud_queue_delay) of waiting."
  watch_arm file "$br" >/dev/null
  if [ "${LAB_REPLACE:-0}" = 1 ]; then   # la session qui a lancé lab next laisse l'onglet : le veilleur relancera le lot
    cmux_restart_session "$REPLACE_WS" "$REPLACE_SURFACE" "$(respawn_command "echo 'lab: lane $SLUG queued for the Cloud ($CLOUD_QUEUE); it starts by itself as soon as a slot frees up.'")" \
      || warn "cmux: session of tab $SLUG not replaced — close it, the watcher will restart the batch"
  fi
}
# cloud_queue_ready : rc 0 si ce couloir doit être relancé — son tour est venu (places libres, réveils remis en pause d'abord) ou son
# délai est dépassé ; CLOUD_QUEUE_INFO dit où il en est
cloud_queue_ready() {
  local ls places m
  CLOUD_QUEUE_INFO="$(cloud_queue_delay) wait exceeded"; cloud_queue_expired "$SLUG" && return 0
  ls="$(cloud_vm ls 60 ls --json 2>/dev/null)" || { CLOUD_QUEUE_INFO="Cloud silent"; return 1; }
  cloud_wake_guard "$ls" >&2
  [ "${CLOUD_WOKEN:-0}" = 0 ] || ls="$(cloud_vm ls 60 ls --json 2>/dev/null)" || { CLOUD_QUEUE_INFO="Cloud silent"; return 1; }
  # ménage à chaque tour (lot 02 de cloud-racine, revue) : une VM orpheline trop récente au départ libère sa place dès qu'elle vieillit
  cloud_clean "$ls" >&2
  [ "${CLOUD_CLEANED:-0}" = 0 ] || ls="$(cloud_vm ls 60 ls --json 2>/dev/null)" || { CLOUD_QUEUE_INFO="Cloud silent"; return 1; }
  # VM du projet avec de la place, éveillée ou reprenable (ses vCPU tiennent) : ni place neuve ni tour de file (lot 10)
  m="$(cloud_pick_machine "$ls" | cut -f1)"
  if [ -n "$m" ] && cloud_resumable "$ls" "$m"; then CLOUD_QUEUE_INFO="room on a project VM"; return 0; fi
  places="$(cloud_places "$ls")"; case "$places" in ''|*[!0-9-]*) places=0 ;; esac
  CLOUD_QUEUE_INFO="position $(cloud_queue_pos "$SLUG")/$(cloud_queue_len), $places free slot(s)"
  case "$(cloud_size "$ls")" in plein*|'') CLOUD_QUEUE_INFO="$CLOUD_QUEUE_INFO, plan full ($(cloud_size "$ls" | cut -f2))"; return 1 ;; esac   # place sans vCPU : lab next remettrait en file (revue)
  cloud_queue_turn "$SLUG" "$places"
}
watch_cloud_queue() {
  local f="$WATCH_FILE" out run rc
  while :; do
    if [ -z "$(cloud_queue_pos "$SLUG")" ]; then watch_issue "$f" removed "lane removed from the Cloud queue (--local, lab close or start)"; return 0; fi
    if cloud_queue_ready; then
      # issue non armée d'abord : le réarmement par lab next (veilleur de la VM) ne tue pas ce processus
      watch_issue "$f" restarted "its turn came ($CLOUD_QUEUE_INFO): lab next $P_NAME $SLUG"
      rc=0; out="$(LAB_UNATTENDED=1 "$LAB_ROOT/bin/lab" next "$P_NAME" "$SLUG" </dev/null 2>&1)" || rc=$?
      printf '%s\n' "$out"
      if [ "$rc" != 0 ]; then   # refus nommé : le couloir quitte la file, il ne bloque pas les suivants (revue)
        cloud_queue_rm "$SLUG"
        watch_issue "$f" failed "lab next $P_NAME $SLUG run by the queue refused: $(printf '%s\n' "$out" | grep -E "^$DIE_READ" | tail -1 | sed -E "s/^$DIE_READ//") — removed from the queue, run it again yourself"; return 0
      fi
      run="$(printf '%s\n' "$out" | sed -n 's/^CLOUD_RUN=//p' | tail -1)"
      [ "$(watch_get "$f" pid)" = "$WATCH_SELF" ] || return 0   # lab next a armé un autre veilleur (VM, ou de nouveau la file)
      watch_issue "$f" started "CLOUD_RUN=${run:-unknown}"; return 0
    fi
    watch_put "$f" detail "queued: ${CLOUD_QUEUE_INFO:-waiting}"
    watch_poll
  done
}

# ---------- veilleur : fin du terminal VM → retrait, pause, avance rapide, batch-end sur le Mac ----------
# cloud_vm_status <machine> → statut de la machine dans cmux vm ls (running, paused…) ; vide si absente ; rc 1 si le Cloud se tait
cloud_vm_status() {
  local ls; ls="$(cloud_vm ls 60 ls --json 2>/dev/null)" && jq -e '.vms' <<<"$ls" >/dev/null 2>&1 || return 1
  jq -r --arg m "$1" '[.vms[]? | select(.id == $m) | .status][0] // empty' <<<"$ls"
}
# cloud_agent_alive <machine> : rc 0 claude tourne sur la VM, 1 mort prouvé (CLOUD_DEAD_CAUSE : dernière ligne OOM de dmesg, si
# lisible), 2 indéterminé. Le script distant rend toujours 0 et dit alive|dead|unknown : seul un pgrep sans résultat (rc 1) est une
# mort ; un échec de cmux vm exec ou de pgrep lui-même (absent, erreur) n'en est jamais une.
# Le motif [b]ypass… ne se reconnaît pas lui-même dans la ligne de commande du sh qui le lance ; « lab-fin/<couloir>; » du Goal de la VM
# vise la session de ce couloir, jamais le claude d'un autre couloir sur une VM partagée (lot 05 d'aiguillage-cloud).
cloud_agent_alive() {
  local out; CLOUD_DEAD_CAUSE=""
  # shellcheck disable=SC2016 # évalué sur la VM
  out="$(cloud_vm agent 60 exec --timeout 60 "$1" -- sh -c 'pgrep -f "claude.*[b]ypassPermissions.*lab-fin/$1[;]" >/dev/null 2>&1; case $? in 0) echo alive ;; 1) echo dead; dmesg 2>/dev/null | grep -iE "out of memory|oom-kill" | tail -1 ;; *) echo unknown ;; esac' sh "$SLUG" 2>/dev/null)" || return 2
  case "$(head -1 <<<"$out")" in
    alive) return 0 ;;
    dead) CLOUD_DEAD_CAUSE="$(printf '%s\n' "$out" | sed -n 2p | sed -E 's/^\[[^]]*\] *//' | cloud_plain | cut -c1-160)"
          CLOUD_DEAD_CAUSE="${CLOUD_DEAD_CAUSE:+last OOM since boot: $CLOUD_DEAD_CAUSE}"; return 1 ;;   # VM reprise, jamais redémarrée : peut-être une session plus ancienne
  esac
  return 2
}
# cloud_vm_asleep <machine> : rc 0 si la VM est en pause ou arrêtée — la session ne tourne plus ; CLOUD_DEAD_WHY la nomme, et plus
# aucun cmux vm exec ne part vers elle (il la réveillerait). Cloud muet ou machine absente de la liste : rc 1, jamais un échec sur un doute.
cloud_vm_asleep() {
  local st; st="$(cloud_vm_status "$1")" || return 1
  case "$st" in paused|stopped) CLOUD_VM_ASLEEP=1; CLOUD_DEAD_WHY="VM $st during the batch session" ;; *) return 1 ;; esac
}
# cloud_agent_dead <machine> : rc 0 si l'absence de claude est prouvée ; CLOUD_DEAD_WHY la nomme, avec la cause lue dans dmesg
cloud_agent_dead() {
  local rc=0; cloud_agent_alive "$1" || rc=$?
  [ "$rc" = 1 ] || return 1
  CLOUD_DEAD_WHY="agent dead: no claude process on $1${CLOUD_DEAD_CAUSE:+ ($CLOUD_DEAD_CAUSE)}"
}
# cloud_fin_read <machine> → la ligne de fin écrite par l'agent ; rien tant qu'elle manque (cat en échec n'arrête jamais le veilleur)
cloud_fin_read() { { cloud_vm fin 60 exec --timeout 60 "$1" -- cat "/home/cmux/.lab-fin/$SLUG" 2>/dev/null || true; } | head -1 | tr '\t' ' ' | cloud_plain | cut -c1-240; }   # bornée, sans tabulation (revue)
# cloud_push_seen <fichier> <branche> <epoch> : tête distante de la branche (git ls-remote, depuis le Mac : la VM n'est jamais
# réveillée) ; un changement note push_sha, push_at et compte un push (pushes), et réarme le silence. rc 1 si la lecture échoue ou ne
# rend rien : jamais une conclusion sur un doute (lot 02 d'aiguillage-cloud)
cloud_push_seen() {
  local f="$1" out sha n
  out="$(with_timeout 60 git -C "$WT" ls-remote "$P_REMOTE" "refs/heads/$2" 2>/dev/null)" || return 1
  sha="$(printf '%s\n' "$out" | cut -f1 | head -1)"; [ -n "$sha" ] || return 1
  [ "$sha" != "$(watch_get "$f" push_sha)" ] || return 0
  n="$(watch_get "$f" pushes)"; case "$n" in ''|*[!0-9]*) n=0 ;; esac
  [ -z "$(watch_get "$f" push_sha)" ] || n=$((n + 1))   # sans référence (veilleur d'une release plus ancienne) : la tête lue la devient
  watch_put "$f" push_sha "$sha"; watch_put "$f" push_at "$3"; watch_put "$f" pushes "$n"
  [ -z "$(watch_get "$f" silent)" ] || { watch_put "$f" silent ""; watch_put "$f" detail "waiting for the session to end on $(watch_get "$f" machine)"; }
}
# cloud_push_watch <fichier> <branche> : à chaque cycle du veilleur — LAB_CLOUD_SILENT_S (3600) sans push → une notification et le
# détail du veilleur, une seule fois jusqu'au push suivant ; rien n'est tué, rien n'est conclu sur une lecture illisible
cloud_push_watch() {
  local f="$1" now at m
  now="$(cloud_epoch)"
  cloud_push_seen "$f" "$2" "$now" || { log "pushes of $2 unreadable (git ls-remote): no conclusion"; return 0; }
  at="$(watch_get "$f" push_at)"; case "$at" in ''|*[!0-9]*) return 0 ;; esac
  [ -z "$(watch_get "$f" silent)" ] && [ "$((now - at))" -ge "${LAB_CLOUD_SILENT_S:-3600}" ] || return 0
  m="$(watch_get "$f" machine)"
  watch_put "$f" silent "$now"; watch_put "$f" detail "no push for $(cloud_ago $((now - at))) on $m: notified, nothing stopped"
  log "no push of $2 for $(cloud_ago $((now - at))): notified, nothing stopped"
  cmux_notify "lab · $SLUG" "No push for $(cloud_ago $((now - at))) from the Cloud session on $m — nothing stopped" 2>/dev/null || true
}
# ---------- la session se pilote comme en local (lot 09 de cmux-pro) ----------
# L'alerte « l'agent attend » est native (hooks de l'image relayés au pane du couloir en ≈ 7 s, mesuré) : lab ne la double jamais. Le
# veilleur sonde toutes les LAB_CLOUD_POLL secondes (60) : sortie du terminal, fichier de fin (done, failed: …, blocked: need … seulement),
# état de l'agent (cmux vm tree, miroir local : jamais un réveil) écrit en une ligne dans l'onglet du couloir ; une attente au-delà de
# LAB_CLOUD_IDLE_MAX (7200 s) met la VM seule du couloir en pause (state=idle-paused), lab next la réveille.
cloud_poll() { printf '%s\n' "${LAB_CLOUD_POLL:-60}"; }
cloud_idle_max() { printf '%s\n' "${LAB_CLOUD_IDLE_MAX:-7200}"; }
cloud_delay_text() { if [ "$(($1 % 3600))" = 0 ]; then printf '%s h\n' "$(($1 / 3600))"; elif [ "$(($1 % 60))" = 0 ]; then printf '%s min\n' "$(($1 / 60))"; else printf '%s s\n' "$1"; fi; }
cloud_hm() { compte_heure "$1" 2>/dev/null | awk '{print $NF}'; }   # <epoch> → HH:MM
# cloud_agent_state <machine> <terminal> → « <état><TAB><epoch du dernier changement> » (working, idle = tour fini, attend une saisie,
# blocked = question ouverte) ; rien si cmux ne connaît pas l'agent de ce terminal
cloud_agent_state() {
  { cloud_vm tree 60 tree "$1" --json 2>/dev/null || true; } | jq -r --arg t "$2" '[.cloud_states[]?.snapshot.agents[]? | select(.terminal_id == $t)]
    | max_by(.updated_at_ms | tonumber? // 0) // empty | "\(.state)\t\((.updated_at_ms | tonumber? // 0) / 1000 | floor)"' 2>/dev/null | cloud_plain || true
}
# cloud_agent_watch <machine> <terminal> : un tour de lecture de l'état de l'agent ; rc 1 quand l'attente dépasse LAB_CLOUD_IDLE_MAX
cloud_agent_watch() {
  local s st since w; s="$(cloud_agent_state "$1" "$2")"; [ -n "$s" ] || return 0
  st="${s%%$'\t'*}"; since="${s#*$'\t'}"
  case "$since" in ''|0|*[!0-9]*) return 0 ;; esac   # horodatage absent ou illisible : jamais une pause sur la foi d'un zéro
  case "$st" in
    idle|blocked)
      if [ "$(cloud_get waiting)" != "$since" ]; then   # nouvelle attente : la ligne de l'onglet le dit, l'alerte est native
        cloud_put waiting "$since"; cloud_put detail "answer awaited in the terminal since $(cloud_hm "$since")"
        cloud_line "Cloud: answer awaited since $(cloud_hm "$since")"
        watch_put "$WATCH_FILE" detail "agent waiting for an answer since $(cloud_hm "$since")"
      fi
      # réveillée par lab next, l'agent attend toujours depuis avant la pause : le délai repart du réveil
      w="$(cloud_get woken)"; case "$w" in ''|*[!0-9]*) ;; *) [ "$w" -le "$since" ] || since="$w" ;; esac
      [ $(( $(cloud_epoch) - since )) -lt "$(cloud_idle_max)" ] ;;
    working)
      if [ -n "$(cloud_get waiting)" ] || [ "$(cloud_get detail)" != "agent working on $1" ]; then
        cloud_put waiting ""; cloud_put idle_alerted ""; cloud_put detail "agent working on $1"
        cloud_line "Cloud: agent working"; watch_put "$WATCH_FILE" detail "agent working on $1"
      fi ;;
  esac
}
# cloud_idle_pause <machine> : sans réponse depuis LAB_CLOUD_IDLE_MAX. VM seule du couloir → pause sous le verrou de départ (le
# processus claude y reste, mesuré), state=idle-paused, alerte nommée, rc 0 : le veilleur s'arrête, lab next la réveillera. VM partagée
# avec un couloir vivant (ou un départ en préparation) → une alerte « attend toujours », une seule fois par attente, rc 1 : on continue.
cloud_idle_pause() {
  local m="$1" d others
  d="$(cloud_delay_text "$(cloud_idle_max)")"
  cloud_start_lock
  others="$(cloud_lanes_on "$m" "$SLUG" | cloud_lanes_join)"
  [ -n "$others" ] || ! cloud_machine_live "$m" "$SLUG" || others="a start in preparation"
  if [ -n "$others" ]; then
    cloud_start_unlock
    [ "$(cloud_get idle_alerted)" != "$(cloud_get waiting)" ] || return 1
    cloud_put idle_alerted "$(cloud_get waiting)"
    cloud_line "Cloud: still waiting, VM shared"
    cloud_alert "No answer for $d, still waiting: VM $m shared with ${others//,/, }, not paused."
    watch_put "$WATCH_FILE" detail "no answer for $d: VM $m shared with ${others//,/, }, kept awake"
    return 1
  fi
  if ! cloud_vm pause 120 pause "$m" >/dev/null 2>&1; then
    cloud_start_unlock; log "pause of $m refused: the watcher keeps waiting"; return 1
  fi
  cloud_put state idle-paused; cloud_put detail "no answer for $d: $m paused, lab next $P_NAME $SLUG wakes it"
  cloud_start_unlock
  cloud_line "Cloud: paused, no answer"
  cloud_alert "No answer for $d: VM paused. lab next $P_NAME $SLUG wakes it, the agent still waits."
  watch_issue "$WATCH_FILE" paused "agent without an answer for $d: $m paused, the session waits there — lab next $P_NAME $SLUG wakes it"
}
watch_cloud() {
  local f="$WATCH_FILE" m t out code="" why="" fin deadline probe br poll
  CLOUD_VM_ASLEEP=0; m="$(watch_get "$f" machine)"; t="$(watch_get "$f" terminal)"; br="$(watch_get "$f" branch)"; poll="$(cloud_poll)"
  deadline=$((SECONDS + ${LAB_CLOUD_WAIT_MAX:-172800}))
  while :; do
    # agent tué (OOM, kill) sans que son terminal se ferme : le veilleur attendrait sans fin (lot 01 de cloud-agent-mort). Sondé après
    # la grâce, pour qu'un claude qui démarre ne soit jamais pris pour mort ; un doute (VM injoignable) ne conclut jamais. Une VM en
    # pause est vue en tête de cycle : wait-exit, comme exec, la réveillerait (mesuré le 2026-10-16) ; le fichier de fin prime sur la sonde.
    probe=0; [ "$SECONDS" -lt "${LAB_CLOUD_GRACE_S:-180}" ] || probe=1
    if [ "$probe" = 1 ] && cloud_vm_asleep "$m"; then code=1; why="$CLOUD_DEAD_WHY"; break; fi
    out="$(cloud_vm wait "$((poll + 30))" terminal wait-exit "$m" "$t" --timeout "$poll" 2>&1)" || true
    code="$(printf '%s\n' "$out" | sed -n 's/.*exited code=\([0-9][0-9]*\).*/\1/p' | tail -1)"
    # mise en pause pendant l'attente : vue avant le premier exec, qui la réveillerait (revue)
    if [ -z "$code" ] && [ "$probe" = 1 ] && cloud_vm_asleep "$m"; then code=1; why="$CLOUD_DEAD_WHY"; break; fi
    if [ -n "$code" ]; then   # sorti en 0 ne suffit pas : un /exit tapé au milieu du lot n'est pas une fin (revue)
      # une fin « blocked… » écrite avant la sortie reste le motif : un besoin nommé y ramène le lot sur le Mac (lot 02)
      fin="$(cloud_fin_read "$m")"
      if [ "$code" = 0 ]; then
        case "$fin" in done*|fini*) ;; '') code=1; why="terminal closed without an end file (\"done\" expected)" ;; *) code=1; why="$fin" ;; esac
      elif [ -n "$(cloud_fin_need "$fin")" ]; then code=1; why="$fin"   # agent tué après avoir écrit son besoin (revue)
      fi
      break
    fi
    cloud_push_watch "$f" "$br"   # dernier push vu sur GitHub ; long silence → une notification, rien n'est tué (lot 02)
    fin="$(cloud_fin_read "$m")"
    # seules done, failed: … et blocked: need … ferment ; toute autre ligne (« blocked: <motif> » d'un ancien Goal) n'arrête rien :
    # l'agent attend sa réponse dans le terminal (lot 09)
    case "$fin" in done*|fini*) code=0 ;; failed*) code=1; why="$fin" ;; *) code=""; [ -z "$(cloud_fin_need "$fin")" ] || { code=1; why="$fin"; } ;; esac
    if [ -n "$code" ]; then   # l'agent interactif a fini et attend : son terminal est fermé ici
      cloud_vm close 60 terminal close "$m" "$t" >/dev/null 2>&1 || true; break
    fi
    if ! cloud_agent_watch "$m" "$t" && cloud_idle_pause "$m"; then return 0; fi   # 2 h sans réponse : VM en pause, lab next la réveille
    if [ "$probe" = 1 ] && cloud_agent_dead "$m"; then   # terminal fermé avant le retrait : aucun processus ne garde le jeton
      cloud_vm close 60 terminal close "$m" "$t" >/dev/null 2>&1 || true
      code=1; why="$CLOUD_DEAD_WHY"; break
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then   # le terminal est fermé avant le retrait : aucun processus ne garde le jeton (revue)
      cloud_vm close 60 terminal close "$m" "$t" >/dev/null 2>&1 || true
      code=timeout; why="still running after ${LAB_CLOUD_WAIT_MAX:-172800} s, terminal closed"; break
    fi
    # un terminal vivant répond « pending », puis « still running » (mesuré au lot 09) : sinon, Cloud muet, on espace
    case "$out" in *pending*|*"still running"*) ;; *) log "end of terminal $t unreadable (${out:-no answer}): trying again"; watch_poll ;; esac
  done
  cloud_finish "$m" "$code" "$why" "${CLOUD_VM_ASLEEP:-0}"
}
# cloud_finish <machine> <code> <motif> [endormie 0|1] : clé de déploiement du couloir révoquée sur GitHub (par id, toujours — même VM
# partagée, même VM en pause : la révocation coupe l'accès sans réveil), puis pause sauf si un autre couloir vit encore sur la VM ou si
# elle est déjà endormie ; batch-end ouvert seulement sur une fin propre. Une fin « blocked: need <besoin>: … » ramène le lot sur le Mac
# (lot 02 d'aiguillage-cloud) : après la révocation et l'avance rapide seulement. Chaque issue écrit sa ligne au journal (done, need, failed, timeout).
cloud_finish() {
  local m="$1" code="$2" why="${3:-}" asleep="${4:-0}" f="$WATCH_FILE" br rc=0 keyproof keyid need="" end=batch-end
  br="$(watch_get "$f" branch)"
  keyid="$(watch_get "$f" key_id)"; [ -n "$keyid" ] || keyid="$(cloud_get key_id "$WT")"
  cloud_push_seen "$f" "$br" "$(cloud_epoch)" || true   # les pushs des dernières minutes comptent au journal
  [ "$code" != 1 ] || need="$(cloud_fin_need "$why")"
  [ -z "$need" ] || end="run on the Mac"
  # la vraie cause se lit à l'écran du terminal : ses dernières lignes, masquées (lot 10), lues avant la pause — une lecture réveille une
  # VM en pause (revue) ; jamais sur une VM endormie, ni pour une fin propre, un besoin ou un « failed: <motif> » écrit par l'agent
  local tail=""
  [ "$code" = 0 ] || [ -n "$need" ] || case "$asleep:$why" in 1:*|*:failed*) ;; *) tail="$(cloud_terminal_tail "$m" "$(watch_get "$f" terminal)")" ;; esac
  # la garde ne gouverne plus que la PAUSE de la VM (chaque couloir révoque sa propre clé) : un autre couloir vivant ou un départ en
  # préparation la gardent éveillée ; sous le verrou de départ, pour qu'un départ sur cette VM ne se glisse jamais entre la lecture et la pause.
  local others="" paused="$m paused"
  if [ "$asleep" != 1 ]; then
    cloud_start_lock
    others="$(cloud_lanes_on "$m" "$SLUG" | cloud_lanes_join)"
    [ -n "$others" ] || ! cloud_machine_live "$m" "$SLUG" || others="a start in preparation"
  fi
  [ -z "$others" ] || paused="$m kept awake"
  # clé révoquée sur GitHub par son id : sur une VM endormie, delete seul (jamais de cmux vm exec qui la réveillerait) ; sinon la clé
  # privée du couloir est aussi effacée sur la VM
  if [ "$asleep" = 1 ]; then
    if cloud_key_remove "$m" "$keyid" "$SLUG" 1; then keyproof="$CLOUD_KEY_PROOF"; else keyproof="WARNING $CLOUD_KEY_PROOF"; fi
  elif cloud_key_remove "$m" "$keyid" "$SLUG"; then keyproof="$CLOUD_KEY_PROOF"
  else keyproof="WARNING $CLOUD_KEY_PROOF"; fi
  log "deploy key: $keyproof"
  [ "$asleep" = 1 ] || [ -n "$others" ] || cloud_vm pause 120 pause "$m" >/dev/null 2>&1 || log "pause of $m refused"
  cloud_put state ending   # plus vivant avant le verrou rendu : une fin proche sur la même VM ne le compte plus (revue)
  cloud_start_unlock
  if [ "$code" != 0 ] && [ -z "$need" ]; then
    why="${why:-terminal exited with code $code}"
    [ -z "$tail" ] || why="$why — last lines: $tail"
    # la VM part avec lab close ou le ménage Cloud, jamais une commande à taper (lot 01 de restes-cloud) ; jamais la VM d'un autre
    local hint="; VM $m removed by lab close or the Cloud cleanup"; [ -z "$others" ] || hint=" — VM $m shared with ${others//,/, }, kept"
    cloud_put state failed; cloud_put detail "$why"
    if [ "$code" = timeout ]; then cloud_session_log timeout; else cloud_session_log failed; fi
    watch_issue "$f" failed "VM session of $br: $why — batch-end not opened; deploy key: $keyproof; next: lab next $P_NAME $SLUG (VM), --local (Mac)$hint"
    cloud_line "Cloud: stopped — $why"
    cloud_alert "Cloud session stopped: $why. Next: lab next $P_NAME $SLUG, or --local for the Mac."
    return 0
  fi
  case "$keyproof" in WARNING*)
    cloud_put state failed; cloud_put detail "$CLOUD_KEY_PROOF"; cloud_session_log failed
    cloud_line "Cloud: stopped — deploy key to revoke"
    cloud_alert "Cloud session stopped${need:+: $why}: $CLOUD_KEY_PROOF — $end not opened."
    watch_issue "$f" failed "$CLOUD_KEY_PROOF — $end not opened${need:+ ($why)}: revoke it with gh repo deploy-key delete $keyid"; return 0 ;;
  esac
  git -C "$WT" fetch -q "$P_REMOTE" "$br" 2>/dev/null && git -C "$WT" merge -q --ff-only "$P_REMOTE/$br" 2>/dev/null || rc=$?
  if [ "$rc" != 0 ]; then
    cloud_put state failed; cloud_put detail "fast-forward of $br impossible"; cloud_session_log failed
    cloud_line "Cloud: stopped — fast-forward impossible"
    cloud_alert "Cloud session stopped${need:+: $why}: $br does not fast-forward here — $end not opened."
    watch_issue "$f" failed "fast-forward of $br from GitHub impossible (local branch diverged or offline) — $end not opened${need:+ ($why)}"; return 0
  fi
  if [ -n "$need" ]; then cloud_back_on_mac "$m" "$br" "$need" "$keyproof" "$paused"; return 0; fi
  cloud_put state finished; cloud_put detail "$br pulled at $(git -C "$WT" rev-parse --short HEAD)"; cloud_session_log 'done'
  local out ws sf opened
  if out="$(LAB_UNATTENDED=1 "$LAB_ROOT/bin/lab" next "$P_NAME" "$SLUG" </dev/null 2>&1)"; then
    printf '%s\n' "$out"   # au journal du veilleur, comme avant ; l'alerte vise l'onglet où la session vient de s'ouvrir
    ws="$(printf '%s\n' "$out" | sed -n 's/^WORKSPACE=//p' | tail -1)"; sf="$(printf '%s\n' "$out" | sed -n 's/^SURFACE=//p' | tail -1)"
    # la session réellement ouverte, sur sa preuve : batch-end (session end), ou une correction si la fiche venue de la VM est incomplète
    opened="$(printf '%s\n' "$out" | sed -n 's/^CLOUD_RUN=local (session \([a-z]*\) always local)$/\1/p' | tail -1)"
    case "$opened" in
      end) opened="batch-end opened"; cloud_line "Cloud: batch done, batch-end opened"; cloud_alert "Batch done on the VM, batch-end opened on the Mac." "$ws" "$sf" ;;
      correction) opened="fixing session opened"; cloud_line "Cloud: batch done, fixing session opened"
        cloud_alert "Batch done on the VM; fixing session opened on the Mac (batch file to complete)." "$ws" "$sf" ;;
      ?*) opened="session $opened opened"; cloud_line "Cloud: batch done, $opened"; cloud_alert "Batch done on the VM; $opened on the Mac." "$ws" "$sf" ;;
      *) opened="next step opened by lab next"; cloud_line "Cloud: batch done"; cloud_alert "Batch done on the VM; lab next opened the next step (lab status $P_NAME)." "$ws" "$sf" ;;
    esac
    watch_issue "$f" resumed "$br pulled at $(git -C "$WT" rev-parse --short HEAD), deploy key: $keyproof, $paused, $opened"
  else
    printf '%s\n' "$out"
    cloud_line "Cloud: batch done, batch-end refused"; cloud_alert "Batch done on the VM, but lab next refused to open batch-end: lab status $P_NAME."
    watch_issue "$f" failed "$br pulled, but lab next $P_NAME $SLUG refused to open batch-end (log $f.log)"
  fi
}
# cloud_back_on_mac <machine> <branche> <besoin TAB détail> <preuve de révocation de la clé> [<état de la VM>] : le besoin retenu hors du dépôt, la marque passe à
# local (lab next n'annonce aucun échec), une notification, puis lab next rouvre run sur le Mac — cloud_decide_ y lit le besoin. Un
# registre occupé n'écrit rien : échec nommé, jamais un rebond sur la VM.
cloud_back_on_mac() {
  local m="$1" br="$2" nd d f="$WATCH_FILE"
  nd="$(cut -f1 <<<"$3")"; d="$(cut -f2 <<<"$3")"
  if ! (cloud_need_add "$nd" "$d" "$(cloud_get lot "$WT")") >/dev/null; then
    cloud_put state failed; cloud_put detail "$(cloud_need_name "$nd") not recorded in $(cloud_needs_file)"; cloud_session_log failed
    cloud_line "Cloud: stopped — need not recorded"
    cloud_alert "Cloud session stopped: $(cloud_need_name "$nd") not recorded — not back on the Mac"
    watch_issue "$f" failed "VM session of $br blocked on $(cloud_need_name "$nd"), not recorded in $(cloud_needs_file) — run on the Mac not opened; next: lab next $P_NAME $SLUG --local"; return 0
  fi
  cloud_put state local; cloud_put detail "back on the Mac: $(cloud_need_name "$nd")${d:+: $d}"; cloud_session_log need
  cloud_line "Cloud: back on the Mac — $(cloud_need_name "$nd")"
  cloud_alert "Back on the Mac: $(cloud_need_name "$nd") found on the VM — run reopened here"
  if "$LAB_ROOT/bin/lab" next "$P_NAME" "$SLUG" </dev/null; then
    watch_issue "$f" resumed "back on the Mac: $(cloud_need_name "$nd") found on the VM; $br pulled at $(git -C "$WT" rev-parse --short HEAD), $4, ${5:-$m paused}, run opened locally"
  else
    watch_issue "$f" failed "back on the Mac: $(cloud_need_name "$nd") recorded, but lab next $P_NAME $SLUG refused to open run (log $f.log)"
  fi
}

# ---------- réveil : la session en pause après 2 h sans réponse (lot 09 de cmux-pro) ----------
# cloud_terminal_alive <machine> <terminal> : rc 0 le processus du terminal tourne (« pending », « still running ») ; 2 sorti ; 1 muet
cloud_terminal_alive() {
  local out; out="$(cloud_vm wait 40 terminal wait-exit "$1" "$2" --timeout 5 2>&1)" || true
  case "$out" in *pending*|*"still running"*) return 0 ;; *exited*) return 2 ;; *) return 1 ;; esac
}
# cloud_repause <machine> : remet la VM en pause seulement si aucun autre couloir n'y vit ni n'y part (revue du lot 09)
cloud_repause() { cloud_machine_live "$1" "$SLUG" || cloud_vm pause 120 pause "$1" >/dev/null 2>&1 || true; }
# cloud_wake : lab next sur une session idle-paused — VM reprise sous le verrou de départ (une place et des vCPU du forfait, comme un
# départ), terminal vérifié vivant, rouvert dans le couloir, veilleur réarmé ; aucun agent relancé. Forfait plein ou Cloud muet, terminal
# muet : refus nommé, VM laissée (ou remise) en pause. Terminal sorti pendant la pause : refus nommé aussi — clé du couloir révoquée,
# VM remise en pause, marque en échec ; lab next suivant relance le lot depuis sa fiche.
cloud_wake() {
  local m t rws ls st rc=0 keyid
  m="$(cloud_get machine)"; t="$(cloud_get terminal)"; rws="$(cloud_get workspace)"
  has_cmux || die "cmux missing: the batch session stays paused on $m"
  cloud_start_lock
  if ! ls="$(cloud_vm ls 60 ls --json 2>/dev/null)" || ! jq -e '.limits' <<<"$ls" >/dev/null 2>&1; then
    cloud_start_unlock; die "Cloud unavailable: the batch session stays paused on $m — run lab next $P_NAME $SLUG again"
  fi
  st="$(jq -r --arg m "$m" '[.vms[]? | select(.id == $m) | .status][0] // empty' <<<"$ls")"
  [ -n "$st" ] || { cloud_start_unlock; cloud_put state failed; cloud_put detail "VM $m gone during the pause"
    die "VM $m gone from the Cloud during the pause: session lost — lab next $P_NAME $SLUG restarts the batch from its file"; }
  # reprendre la VM ne prend aucune place neuve, seulement ses vCPU (lot 10)
  cloud_resumable "$ls" "$m" || { cloud_start_unlock; die "Cloud plan full: the batch session stays paused on $m — run lab next $P_NAME $SLUG again when vCPUs free up (lab status $P_NAME)"; }
  cloud_busy "$m"   # éveillée avant la marque vivante : la garde des réveils ne la remet pas en pause
  cloud_vm resume 120 resume "$m" >/dev/null 2>&1 || true   # un vrai refus se lit ci-dessous : terminal muet
  cloud_terminal_alive "$m" "$t" || rc=$?
  if [ "$rc" = 1 ]; then   # muet (refus du resume, relais en reconnexion) : jamais pris pour un terminal sorti, aucun agent relancé
    cloud_unbusy_mine; cloud_repause "$m"
    cloud_unbusy_mine; cloud_start_unlock
    die "terminal $t silent when waking $m: the batch session stays paused — run lab next $P_NAME $SLUG again in a moment"
  fi
  if [ "$rc" = 2 ]; then   # sorti pendant la pause : clé révoquée, VM remise en pause, rien ne repart en silence
    keyid="$(cloud_get key_id)"
    cloud_key_remove "$m" "$keyid" "$SLUG" || warn "Cloud: $CLOUD_KEY_PROOF"
    cloud_unbusy_mine; cloud_repause "$m"; cloud_start_unlock
    cloud_put state failed; cloud_put detail "terminal $t exited during the pause of $m"
    watch_issue "$(watch_file "$(branch_name "$WT")")" failed "terminal $t exited during the pause of $m: deploy key revoked, nothing woken"
    cloud_line "Cloud: stopped — terminal exited during the pause"
    die "terminal $t exited during the pause of $m: nothing woken, deploy key revoked — lab next $P_NAME $SLUG restarts the batch from its file (VM), --local on the Mac"
  fi
  cloud_put state alive; cloud_put waiting ""; cloud_put idle_alerted ""; cloud_put woken "$(cloud_epoch)"
  cloud_put detail "woken by lab next, the agent waits for its answer"
  cloud_open "$m" "$rws" "$t"; cloud_line "Cloud: woken, answer awaited"
  cloud_unbusy_mine; cloud_start_unlock   # marque vivante écrite : verrou rendu avant d'armer, la fin du veilleur le reprend (comme cloud_start)
  watch_arm cloud "$(branch_name "$WT")" machine="$m" terminal="$t" key_id="$(cloud_get key_id)" push_at="$(cloud_epoch)" pushes=0 >/dev/null   # sans push_sha : la tête distante lue la devient
  kv CLOUD_RUN "$m (woken)"; kv TERMINAL "$t"
  log "Lane VM woken:"; log "$m"; log "the batch session goes on in its"; log "terminal, here; the agent waits"; log "for your answer."   # 40 colonnes
}
# cloud_abandon : --local sur une session en pause — terminal VM fermé, clé du couloir révoquée, VM remise en pause ; la fiche repart
# sur le Mac. Fermeture ou révocation refusées : la session reste en pause, refus nommé (l'agent de la VM n'avance jamais en parallèle)
cloud_abandon() {
  local m t keyid; m="$(cloud_get machine)"; t="$(cloud_get terminal)"; keyid="$(cloud_get key_id)"
  cloud_vm resume 120 resume "$m" >/dev/null 2>&1 || true
  if ! cloud_vm close 60 terminal close "$m" "$t" >/dev/null 2>&1; then
    cloud_repause "$m"
    die "--local refused: terminal $t not closed on $m (Cloud silent), the batch session stays paused — run lab next $P_NAME $SLUG --local again"
  fi
  if ! cloud_key_remove "$m" "$keyid" "$SLUG"; then
    cloud_repause "$m"
    die "--local refused: $CLOUD_KEY_PROOF — run lab next $P_NAME $SLUG --local again"
  fi
  [ -n "$(cloud_lanes_on "$m" "$SLUG")" ] || cloud_vm pause 120 pause "$m" >/dev/null 2>&1 || warn "Cloud: pause of $m refused — cmux vm pause $m"
  cloud_put state local; cloud_put detail "taken back locally by --local, VM session closed"; cloud_line "Cloud: taken back on the Mac"
  watch_issue "$(watch_file "$(branch_name "$WT")")" resumed "taken back locally by --local: terminal $t closed on $m, deploy key revoked"
  log "VM session closed, VM paused:"; log "the batch goes on on the Mac."   # 40 colonnes
}

# ---------- image : la machine outillée du projet, figée une fois ----------
# cloud_image_cmd <projet> [<machine>] [--ref <branche>] : clone de la base (ou de la branche nommée) en SSH par une clé de déploiement
# éphémère (titre lab-cloud-image-<projet>-<ts>), méthode de lab (skills, agents, instructions globales) liée dans ~/.claude, script
# d'outillage du projet (scripts/cloud-image.sh, en root) s'il existe, identité git ; puis la clé révoquée et sa clé privée effacée AVANT
# le snapshot (aucune clé privée dans l'image), snapshot, pause. Chaque couloir part ensuite de ce snapshot (vm restore), jamais de cette machine.
cloud_image_cmd() {
  local p="$1" m="" ref="$P_BASE"; shift
  while [ "$#" -gt 0 ]; do
    case "$1" in --ref) [ -n "${2:-}" ] || usage; ref="$2"; shift 2 ;; -*) usage ;; *) [ -z "$m" ] || usage; m="$1"; shift ;; esac
  done
  cloud_image_build "$p" "$m" "$ref" || die "$CLOUD_WHY"
  kv PROJECT "$p"; kv IMAGE_MACHINE "$CLOUD_IMAGE_MACHINE"; kv IMAGE_SNAPSHOT "$CLOUD_IMAGE_SNAPSHOT"
}
# cloud_image_build <projet> <machine|""> <ref> : le corps de lab cloud <projet> image, sans jamais tuer l'appelant — un départ de couloir
# ou une suite le lance aussi quand l'image est périmée (lot 01 de cloud-racine) ; WT local : celui de l'appelant est rendu intact.
# Écrit machine, snapshot, at et tooling (empreinte de l'outillage de <ref>) ; CLOUD_IMAGE_MACHINE, CLOUD_IMAGE_SNAPSHOT ; rc 1 avec CLOUD_WHY.
cloud_image_build() {
  local p="$1" m="$2" ref="$3" url out snap print f WT="$P_ROOT"
  has_cmux || { CLOUD_WHY="cmux missing: no Cloud image prepared"; return 1; }
  cloud_gh_ready || { CLOUD_WHY="$CLOUD_WHY: no Cloud image prepared"; return 1; }
  url="$(cloud_repo_ssh_url)" || { CLOUD_WHY="remote $P_REMOTE is not a readable GitHub repository in $P_ROOT"; return 1; }
  [ -n "$m" ] || m="$(cloud_image_get machine)"
  if [ -z "$m" ]; then
    out="$(cloud_vm route 600 route --new --provision --size 8g --json)" && m="$(jq -r '.machine // empty' <<<"$out")" && [ -n "$m" ] \
      || { CLOUD_WHY="no Cloud machine created (cmux vm route --new --provision): nothing prepared"; return 1; }
    log "Cloud: machine $m created for the image of $p"
  else cloud_vm resume 120 resume "$m" >/dev/null 2>&1 || true; fi
  cloud_busy "$m"   # en préparation : la garde des réveils ne la remet pas en pause (lot 05)
  cloud_key_purge "image-$p"   # clés lab-cloud-image-<projet>-* restées d'une construction plantée : révoquées avant d'en créer une neuve
  cloud_key_make "$m" "image-$p" || { cloud_unbusy_mine; CLOUD_WHY="deploy key not created on $m: $CLOUD_WHY — nothing prepared"; return 1; }
  if ! cloud_image_steps "$m" "$url" "$ref" "image-$p"; then
    cloud_key_remove "$m" "$CLOUD_KEY_ID" "image-$p" || warn "$CLOUD_KEY_PROOF"
    cloud_unbusy_mine; CLOUD_WHY="image of $p not prepared on $m: $CLOUD_WHY — deploy key revoked, nothing frozen"; return 1
  fi
  cloud_key_remove "$m" "$CLOUD_KEY_ID" "image-$p" || { cloud_unbusy_mine; CLOUD_WHY="$CLOUD_KEY_PROOF: no snapshot taken while the private key may remain in the image"; return 1; }
  log_wrap "deploy key: $CLOUD_KEY_PROOF"   # repliée à 40 colonnes : la reconstruction parle aussi dans la suite et le départ (lot 01 de cloud-racine)
  out="$(cloud_vm snapshot 600 snapshot "$m" --name "lab-$p" 2>&1)" || { cloud_unbusy_mine; CLOUD_WHY="snapshot of $m refused: $out"; return 1; }
  # l'identifiant (sh-…) se relit dans la liste : la sortie de la prise n'est pas une forme stable (mesuré le 2026-10-12)
  snap="$(cloud_vm snapls 60 snapshot ls "$m" --json 2>/dev/null \
    | jq -r --arg n "lab-$p" '[.snapshots[]? | select(.name == $n)] | sort_by(.created_at) | last | .id // empty' 2>/dev/null)" || snap=""
  [ -n "$snap" ] || { cloud_unbusy_mine; CLOUD_WHY="snapshot of $m taken, but not found in cmux vm snapshot ls: image not recorded"; return 1; }
  cloud_image_fetch "$ref"; print="$(cloud_image_print "$ref")" || print=""
  # écrit à côté puis renommé : un départ simultané qui lit l'image voit l'ancienne ou la nouvelle, jamais un fichier vidé par la
  # redirection (nuits rouges des 10, 12 et 14 nov. : « no Cloud image for the project », lot 01 de fix-nuit-2026-11-14)
  f="$(cloud_image_file)"; mkdir -p "$(dirname "$f")"
  if ! { printf 'machine=%s\nsnapshot=%s\nat=%s\n' "$m" "$snap" "$(cloud_now)"; [ -z "$print" ] || printf 'tooling=%s\n' "$print"; } >"$f.$$" \
     || ! mv "$f.$$" "$f"; then
    rm -f "$f.$$"; cloud_vm pause 120 pause "$m" >/dev/null 2>&1 || true; cloud_unbusy_mine; CLOUD_WHY="image file $f not written"; return 1
  fi
  cloud_vm pause 120 pause "$m" >/dev/null 2>&1 || warn "pause of $m refused"
  cloud_unbusy_mine
  CLOUD_IMAGE_MACHINE="$m"; CLOUD_IMAGE_SNAPSHOT="$snap"
}
# cloud_image_print [<ref>] → l'empreinte sha256 de l'outillage de l'image : scripts/cloud-image.sh et chaque fichier du dépôt qu'il cite
# (scripts/ci-bash32.sh, tests/bin-linux/shlock…), lus dans <ref> (la base par défaut) tel que GitHub le voit ($P_REMOTE/<ref>, d'où
# l'image clone), jamais dans le couloir ; rc 1 sans scripts/cloud-image.sh (projet sans outillage : jamais périmé)
cloud_image_print() {
  local ref="${1:-$P_BASE}" f b
  ! git -C "$P_ROOT" rev-parse -q --verify "$P_REMOTE/$ref^{commit}" >/dev/null 2>&1 || ref="$P_REMOTE/$ref"
  [ "$(git -C "$P_ROOT" cat-file -t "$ref:scripts/cloud-image.sh" 2>/dev/null)" = blob ] || return 1
  { printf 'scripts/cloud-image.sh\n'; git -C "$P_ROOT" show "$ref:scripts/cloud-image.sh" 2>/dev/null | grep -oE '[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+' || true; } \
    | LC_ALL=C sort -u | while IFS= read -r f; do
        b="$(git -C "$P_ROOT" rev-parse -q --verify "$ref:$f" 2>/dev/null)" || continue
        [ "$(git -C "$P_ROOT" cat-file -t "$b" 2>/dev/null)" = blob ] || continue
        printf '%s %s\n' "$b" "$f"
      done | shasum -a 256 | cut -c1-64
}
# cloud_image_stale : rc 0 si l'image du projet existe et que son empreinte (tooling=) manque ou diffère de celle de la base ; CLOUD_IMAGE_PRINT
cloud_image_stale() {
  [ -n "$(cloud_image_get snapshot)" ] || return 1
  CLOUD_IMAGE_PRINT="$(cloud_image_print)" && [ -n "$CLOUD_IMAGE_PRINT" ] || return 1
  [ "$(cloud_image_get tooling)" != "$CLOUD_IMAGE_PRINT" ]
}
# cloud_image_ensure : avant toute restauration (suite, départ de couloir) — une image périmée est reconstruite d'abord, une seule fois,
# sous le verrou $LAB_STATE/cloud/image.lock : un second départ simultané attend, relit l'empreinte et ne reconstruit rien. Verrou d'un
# processus mort repris ; attente bornée (LAB_CLOUD_IMAGE_WAIT, 1800 s : outillage, bash 3.2 compilé, pip). rc 1 avec CLOUD_WHY.
cloud_image_ensure() {
  local d n=0 rc=0 p
  cloud_image_fetch; cloud_image_stale || return 0
  d="$LAB_STATE/cloud/image.lock"; mkdir -p "$LAB_STATE/cloud"
  until mkdir "$d" 2>/dev/null; do
    # verrou mort repris sous cloud_lock_reclaim (relu avant d'être retiré : le verrou neuf d'une autre attente n'est jamais déplacé) ;
    # un verrou vivant n'est jamais volé : passé l'attente, refus nommé (revue)
    if cloud_lock_stale "$d" "$n" 10 && cloud_lock_reclaim "$d" "$n" 10; then n=0; continue; fi
    if [ "$n" -ge "$(( ${LAB_CLOUD_IMAGE_WAIT:-1800} * 2 ))" ]; then
      p="$(cat "$d/pid" 2>/dev/null)" || p=""
      CLOUD_WHY="image rebuild still running (pid ${p:-unknown}) after ${LAB_CLOUD_IMAGE_WAIT:-1800} s: nothing restored"; return 1
    fi
    [ "$n" != 2 ] || { log "Cloud: the project image is"; log "being rebuilt, waiting…"; }   # 40 colonnes
    n=$((n + 1)); sleep 0.5
  done
  printf '%s\n' "$$" >"$d/pid"
  if cloud_image_stale; then
    log "Cloud image of $P_NAME stale:"; log "rebuilt before the restore."   # 40 colonnes
    if cloud_image_build "$P_NAME" "" "$P_BASE"; then CLOUD_IMAGE_REBUILT=1
    else rc=1; CLOUD_WHY="stale image of $P_NAME not rebuilt: $CLOUD_WHY"; fi
  fi
  [ "$(cat "$d/pid" 2>/dev/null)" != "$$" ] || cloud_lock_drop "$d"
  return "$rc"
}
# cloud_image_fetch [<ref>] : la base relue sur GitHub (30 s au plus, échec toléré) avant l'empreinte — un origin/main local en retard
# dirait à jour une image que GitHub a déjà périmée (revue)
cloud_image_fetch() { with_timeout 30 git -C "$P_ROOT" fetch -q "$P_REMOTE" "${1:-$P_BASE}" </dev/null >/dev/null 2>&1 || true; }
# cloud_image_steps <machine> <url SSH> <ref> <slug de la clé> : les étapes de l'image ; clone en SSH par la clé de déploiement ; rc 1 avec CLOUD_WHY
cloud_image_steps() {
  local m="$1" url="$2" ref="$3" sl="$4" name email d ssh
  name="$(git -C "$P_ROOT" config user.name 2>/dev/null || true)"; email="$(git -C "$P_ROOT" config user.email 2>/dev/null || true)"
  ssh="export GIT_SSH_COMMAND=\"ssh -i \$HOME/.ssh/lab-$sl -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new\""
  cloud_vm clone 600 exec --timeout 600 "$m" -- "${CLOUD_LOGIN_CMUX[@]}" \
    "$ssh && rm -rf ~/work/_image && git clone -q --depth 1 --branch $(shell_quote "$ref") $(shell_quote "$url") ~/work/_image${name:+ && git config --global user.name $(shell_quote "$name")}${email:+ && git config --global user.email $(shell_quote "$email")}" >&2 \
    || { CLOUD_WHY="clone of $url refused"; return 1; }
  for d in skills agents templates/global-instructions.md; do
    cloud_vm push 300 push "$m" "$LAB_ROOT/$d" ".lab-method/$(basename "$d")" >/dev/null 2>&1 || { CLOUD_WHY="method $d not pushed"; return 1; }
  done
  # shellcheck disable=SC2016 # évalué sur la VM
  cloud_vm lien 60 exec --timeout 60 "$m" -- sh -c 'h=/home/cmux; mkdir -p "$h/.claude" && rm -rf "$h/.claude/skills" "$h/.claude/agents" "$h/.claude/CLAUDE.md" && ln -s "$h/.lab-method/skills" "$h/.claude/skills" && ln -s "$h/.lab-method/agents" "$h/.claude/agents" && ln -s "$h/.lab-method/global-instructions.md" "$h/.claude/CLAUDE.md" && chown -hR cmux:cmux "$h/.claude" "$h/.lab-method"' >&2 \
    || { CLOUD_WHY="method not linked in ~/.claude"; return 1; }
  if cloud_vm test 60 exec --timeout 60 "$m" -- test -f /home/cmux/work/_image/scripts/cloud-image.sh >/dev/null 2>&1; then
    log "Cloud: project tooling"; log "(scripts/cloud-image.sh),"; log "several minutes."   # 40 colonnes
    cloud_vm outils 900 exec --timeout 900 "$m" -- "${CLOUD_AS_ROOT[@]}" /home/cmux/work/_image/scripts/cloud-image.sh >&2 || { CLOUD_WHY="scripts/cloud-image.sh failed"; return 1; }
  fi
  cloud_vm propre 60 exec --timeout 60 "$m" -- rm -rf /home/cmux/work/_image >/dev/null 2>&1 || true
}

# ---------- suite déportée : la suite bats du commit courant sur une VM jetable (lot 04 d'aiguillage-cloud) ----------
# lab cloud <projet> suite [<couloir>] : contrôles (arbre propre, scripts/cloud-suite.sh au commit, cmux, règle cloud, image, place de
# CLOUD_SUITE_CPU vCPU / CLOUD_SUITE_GB Go au forfait) → VM restaurée du snapshot du projet et agrandie → copie du commit hors
# documents de lab (git archive) en morceaux de 1 Mo relus, recollée, sha256 relu, dépôt git neuf dont l'arbre est relu égal → lanceur
# du projet dans un terminal durable → résultats rapatriés → VM supprimée par un trap, même en échec ou interruption. Aucun secret :
# ni clé de déploiement, ni gh, ni vm env set (git archive, pas de clone distant). stdout KEY=value, progression sur stderr ; rc 0 green, 1 red, 3 unavailable.
CLOUD_SUITE_CPU=""   # taille lue dans le forfait par cloud_suite_fits (lot 01 de cloud-racine)
CLOUD_SUITE_GB=""
CLOUD_SUITE_JOBS=""   # tâches bats : les vCPU vus sur la VM agrandie (cloud_suite_cpus)
CLOUD_SUITE_DIR=/home/cmux/bats-run   # sur la VM ; ~/bats-run dans les commandes distantes
CLOUD_SUITE_EXCLUDE=(docs/lots docs/treeplans)   # documents de lab seulement : des tests lisent le reste de docs/ (lot 03)
cloud_suite_cmd() {
  local p="$1" wt here label snap ls out term w tree arch deadline v l k; shift
  [ "$#" -le 1 ] || usage
  if [ "$#" = 1 ]; then
    wt="$(worktree_path "$1")"
    valid_slug "$1" && [ -d "$wt" ] && [ ! -L "$wt" ] || { (die "\"$1\" is not a lane of $p: lab cloud $p suite [<lane>]") || exit 2; }
  else   # sans couloir nommé : le dépôt du projet où la commande est lancée, sinon le checkout principal
    here="$(repo_root 2>/dev/null || true)"; wt="$P_ROOT"
    if [ -n "$here" ] && { same_path "$here" "$P_ROOT" || same_path "$(dirname "$here")" "$P_ROOT/.worktrees"; }; then wt="$here"; fi
  fi
  if same_path "$wt" "$P_ROOT"; then label="$P_BASE"; else label="$(basename "$wt")"; fi
  CLOUD_SUITE_HEAD="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" || CLOUD_SUITE_HEAD=""
  CLOUD_SUITE_MACHINE=""; CLOUD_SUITE_REPORT=""; CLOUD_SUITE_T0="$SECONDS"; CLOUD_SUITE_SAID=0; CLOUD_SUITE_BG=""; CLOUD_SUITE_RUN=""
  trap cloud_suite_cleanup EXIT   # dès le départ : une sortie sans verdict (set -e) devient unavailable, jamais un rc 1 lu « red »
  [ -n "$CLOUD_SUITE_HEAD" ] || cloud_suite_stop "no commit in $wt"
  [ -z "$(git -C "$wt" status --porcelain --untracked-files=normal -- . ':!.lab' 2>/dev/null)" ] \
    || cloud_suite_stop "uncommitted changes in $wt: commit them, nothing sent"
  git -C "$wt" cat-file -e "HEAD:scripts/cloud-suite.sh" 2>/dev/null \
    || cloud_suite_stop "no scripts/cloud-suite.sh in the commit: this project has no remote suite launcher"
  has_cmux || cloud_suite_stop "cmux missing: the suite runs only on a cmux Cloud machine"
  if same_path "$wt" "$P_ROOT"; then cloud_resolve "$p" -; else cloud_resolve "$p" "$wt"; fi
  case "$CLOUD" in yes) ;; no) cloud_suite_stop "cloud=no ($CLOUD_SOURCE)" ;; *) cloud_suite_stop "$(cloud_note)" ;; esac
  snap="$(cloud_image_get snapshot)"; [ -n "$snap" ] || cloud_suite_stop "no Cloud image for the project: lab cloud $p image"
  CLOUD_SUITE_LABEL="$label"; CLOUD_SUITE_WT="$wt"
  if ! ls="$(cloud_vm ls 60 ls --json 2>/dev/null)" || ! jq -e '.limits' <<<"$ls" >/dev/null 2>&1; then cloud_suite_stop "Cloud unavailable (cmux vm ls)"; fi
  # ménage d'abord (lot 02 de cloud-racine) ; forfait plein après lui : la même suite sur le Mac, aussitôt, avec l'alerte forfait
  cloud_clean "$ls"
  if [ "${CLOUD_CLEANED:-0}" != 0 ]; then
    if ! ls="$(cloud_vm ls 60 ls --json 2>/dev/null)" || ! jq -e '.limits' <<<"$ls" >/dev/null 2>&1; then cloud_suite_stop "Cloud unavailable (cmux vm ls)"; fi
  fi
  cloud_suite_fits "$ls" || cloud_suite_full_or_stop
  # image périmée reconstruite avant la restauration, forfait lu d'abord (jamais une machine réveillée sur un forfait plein), relu
  # après une reconstruction (lot 01 de cloud-racine)
  CLOUD_IMAGE_REBUILT=0; cloud_image_ensure || cloud_suite_stop "$CLOUD_WHY"
  snap="$(cloud_image_get snapshot)"
  if [ "$CLOUD_IMAGE_REBUILT" = 1 ]; then
    if ! ls="$(cloud_vm ls 60 ls --json 2>/dev/null)" || ! jq -e '.limits' <<<"$ls" >/dev/null 2>&1; then cloud_suite_stop "Cloud unavailable (cmux vm ls)"; fi
    cloud_suite_fits "$ls" || cloud_suite_full_or_stop
  fi

  cloud_suite_report_new
  arch="$CLOUD_SUITE_REPORT/copy.tar.gz"
  git -C "$wt" archive --format=tar.gz --prefix=repo/ "$CLOUD_SUITE_HEAD" -- . "${CLOUD_SUITE_EXCLUDE[@]/#/:!}" >"$arch" 2>/dev/null \
    || cloud_suite_stop "git archive of $CLOUD_SUITE_HEAD refused"
  tree="$(cloud_suite_tree "$wt" "$CLOUD_SUITE_HEAD")" || cloud_suite_stop "tree of $CLOUD_SUITE_HEAD unreadable"
  log "Suite of ${CLOUD_SUITE_HEAD:0:12}: restoring"; log "the project image."
  # restauration en arrière-plan, sortie dans restore.json : interrompue, le nettoyage y lit encore la VM créée (revue)
  if ! cloud_restore "$snap" "$CLOUD_SUITE_REPORT/restore.json" cloud_suite_bg; then
    case "$CLOUD_WHY" in "plan full"*) cloud_suite_mac "$CLOUD_WHY" ;; esac   # HTTP 402 : places prises hors de vm ls (lot 02)
    cloud_suite_stop "$CLOUD_WHY"
  fi
  CLOUD_SUITE_MACHINE="$CLOUD_RESTORED"
  cloud_busy "$CLOUD_SUITE_MACHINE"; log "Suite VM restored:"; log "$CLOUD_SUITE_MACHINE"   # 40 colonnes : vm- et 32 caractères, sans point
  cloud_vm resize 300 resize "$CLOUD_SUITE_MACHINE" --cpu "$CLOUD_SUITE_CPU" --memory "$CLOUD_SUITE_GB" >/dev/null 2>&1 \
    || cloud_suite_stop "resize of $CLOUD_SUITE_MACHINE to $CLOUD_SUITE_CPU vCPU / $CLOUD_SUITE_GB GB refused"
  cloud_suite_cpus "$CLOUD_SUITE_MACHINE"
  cloud_suite_push "$CLOUD_SUITE_MACHINE" "$arch" || cloud_suite_stop "copy not sent: $CLOUD_WHY"
  log "Copy sent: $CLOUD_SUITE_PARTS parts, sha256 ok."
  # shellcheck disable=SC2016 # évalué sur la VM
  out="$(cloud_vm extract 600 exec --timeout 600 "$CLOUD_SUITE_MACHINE" -- sh -c 'cd ~/bats-run && rm -rf repo && tar -xzf copy.tar.gz && cd repo && git init -q && git add -A -f && git -c user.name=lab -c user.email=lab -c commit.gpgsign=false commit -q --no-verify -m suite && git rev-parse "HEAD^{tree}"' 2>/dev/null | tail -1 | tr -d '\r')" || out=""
  [ "$out" = "$tree" ] || cloud_suite_stop "tree on the VM (${out:-unread}) differs from the commit tree ($tree)"
  log "Tree checked: ${tree:0:12}."
  if ! out="$(CMUX_QUIET=1 with_timeout 120 cmux surface new-terminal --machine "$CLOUD_SUITE_MACHINE" --no-open --name "suite-$label" --json -- \
       bash -lc "cd ~/bats-run/repo && SETUP_PTY_DELAI=300 UPDATE_OBSERVE_DELAI=600 bash scripts/cloud-suite.sh ~/bats-run/out $CLOUD_SUITE_JOBS" </dev/null 2>/dev/null)" \
     || ! term="$(jq -r '.terminal_id // empty' <<<"$out" 2>/dev/null)" || [ -z "$term" ]; then
    cloud_suite_stop "terminal not started on $CLOUD_SUITE_MACHINE"
  fi
  log "Suite running: $CLOUD_SUITE_JOBS jobs."
  deadline=$((SECONDS + ${LAB_CLOUD_SUITE_MAX:-14400}))
  while :; do
    # attente bornée au temps restant (60 s à 3600 s) : l'échéance tombe à l'heure, pas une heure plus tard
    k=$((deadline - SECONDS)); [ "$k" -le 3600 ] || k=3600; [ "$k" -ge 60 ] || k=60
    cloud_suite_bg "$CLOUD_SUITE_REPORT/wait.out" cloud_vm wait "$((k + 100))" terminal wait-exit "$CLOUD_SUITE_MACHINE" "$term" --timeout "$k" || true
    w="$(cat "$CLOUD_SUITE_REPORT/wait.out" 2>/dev/null)" || w=""
    case "$w" in *exited*) break ;; esac
    [ "$SECONDS" -lt "$deadline" ] || cloud_suite_partial "suite not finished after ${LAB_CLOUD_SUITE_MAX:-14400} s"
    sleep "${LAB_CLOUD_SUITE_POLL:-30}"
  done
  cloud_vm pull 900 pull "$CLOUD_SUITE_MACHINE" "$CLOUD_SUITE_DIR/out" "$CLOUD_SUITE_REPORT/vm" >/dev/null 2>&1 || true
  l="$(find "$CLOUD_SUITE_REPORT/vm" -maxdepth 2 -name suite.log 2>/dev/null | head -1)" || l=""   # rien rapatrié : find en échec
  [ -s "$l" ] || cloud_suite_stop "results not pulled from $CLOUD_SUITE_MACHINE"
  v="$(sed -n 's/^SUITE=//p' "$l" | tail -1)"
  case "$v" in green|red) ;; *) cloud_suite_stop "no verdict in suite.log: the suite stopped on the VM" ;; esac
  log "Results pulled: $v."
  CLOUD_SUITE_SAID=1
  { kv SUITE "$v"; kv RUN cloud; kv HEAD "$CLOUD_SUITE_HEAD"; kv MACHINE "$CLOUD_SUITE_MACHINE"; kv DURATION_S "$((SECONDS - CLOUD_SUITE_T0))"
    for k in BATS_S OK NOT_OK SKIP REPLAYED; do kv "$k" "$(sed -n "s/^$k=//p" "$l" | tail -1)"; done
    grep '^RED=' "$l" || true; kv REPORT "$CLOUD_SUITE_REPORT"; } | tee "$CLOUD_SUITE_REPORT/verdict.log"
  [ "$v" = green ] && exit 0
  exit 1
}
# cloud_suite_report_new : un dossier neuf par passage (jamais le suite.log d'un passage précédent relu à la place du sien), puis les
# interruptions armées ; une fois seulement
cloud_suite_report_new() {
  [ -z "$CLOUD_SUITE_REPORT" ] || return 0
  CLOUD_SUITE_REPORT="$LAB_STATE/cloud/suite/$P_NAME/$CLOUD_SUITE_LABEL/$(date -u +%Y%m%dT%H%M%SZ)"
  [ ! -e "$CLOUD_SUITE_REPORT" ] || CLOUD_SUITE_REPORT="$CLOUD_SUITE_REPORT-$$"
  mkdir -p "$CLOUD_SUITE_REPORT"
  trap 'cloud_suite_stop "interrupted (INT)" 130' INT; trap 'cloud_suite_stop "interrupted (TERM)" 143' TERM; trap 'cloud_suite_stop "interrupted (HUP)" 129' HUP
}
CLOUD_SUITE_ALERT="Cloud plan full after cleanup: a larger plan would keep the suite on the Cloud"
# cloud_suite_mac <motif du forfait plein> : forfait plein après le ménage (lot 02 de cloud-racine) — la même suite sur le Mac, aussitôt :
# copie figée du commit lu au départ (git archive hors documents de lab, dépôt git neuf, comme sur la VM) dans le dossier du rapport,
# jamais le dossier du couloir qu'on édite ; scripts/cloud-suite.sh à une tâche (en série sur le Mac), tests macos compris
# (CLOUD_SUITE_FILTER vide) ; SIGINT et SIGPIPE rétablis (un lanceur en arrière-plan les ignore : traps, PTY et lang rougiraient) ;
# alerte forfait (log, PLAN_ALERT=, notification cmux). Verdict et rc de la suite : 0 vert, 1 rouge ; jamais de retour.
cloud_suite_mac() {
  local why="$1" repo l v k
  CLOUD_SUITE_RUN=mac; cloud_suite_report_new
  log "Cloud plan full after cleanup:"; log_wrap "$why."; log_wrap "A larger plan would keep the suite on the Cloud."   # 40 colonnes
  cmux_notify "lab · $P_NAME" "$CLOUD_SUITE_ALERT."
  repo="$CLOUD_SUITE_REPORT/mac-repo"; mkdir -p "$repo"
  if ! { git -C "$CLOUD_SUITE_WT" archive --format=tar --prefix=repo/ "$CLOUD_SUITE_HEAD" -- . "${CLOUD_SUITE_EXCLUDE[@]/#/:!}" 2>/dev/null | tar -xf - -C "$repo" 2>/dev/null \
       && (cd "$repo/repo" && git init -q && git add -A -f && git -c user.name=lab -c user.email=lab -c commit.gpgsign=false commit -q --no-verify -m suite) >/dev/null 2>&1; }; then
    cloud_suite_stop "copy of $CLOUD_SUITE_HEAD for the Mac refused"
  fi
  log_wrap "Suite running on the Mac: 1 job, frozen copy of ${CLOUD_SUITE_HEAD:0:12}."
  # cd dans python, jamais par sh -c : le sh de Linux (dash) jette les fonctions bash exportées, dont bats_readlinkf qu'un bats
  # pris dans le libexec du PATH appelle — 0 résultat en CI Linux (lot 03 de cloud-racine)
  cloud_suite_bg "$CLOUD_SUITE_REPORT/mac.out" env CLOUD_SUITE_FILTER= \
    python3 -c 'import os, signal, sys; os.chdir(sys.argv[1]); signal.signal(signal.SIGINT, signal.SIG_DFL); signal.signal(signal.SIGPIPE, signal.SIG_DFL); os.execvp(sys.argv[2], sys.argv[2:])' \
    "$repo/repo" bash scripts/cloud-suite.sh "$CLOUD_SUITE_REPORT/mac" 1 || true
  rm -rf "$repo"
  l="$CLOUD_SUITE_REPORT/mac/suite.log"; v="$(sed -n 's/^SUITE=//p' "$l" 2>/dev/null | tail -1)"
  case "$v" in green|red) ;; *) cloud_suite_stop "no verdict in suite.log: the suite stopped on the Mac ($CLOUD_SUITE_REPORT/mac.out)" ;; esac
  log "Suite on the Mac: $v."
  CLOUD_SUITE_SAID=1
  { kv SUITE "$v"; kv RUN mac; kv PLAN_FULL "$why"; kv PLAN_ALERT "$CLOUD_SUITE_ALERT"; kv HEAD "$CLOUD_SUITE_HEAD"
    kv DURATION_S "$((SECONDS - CLOUD_SUITE_T0))"
    for k in BATS_S OK NOT_OK SKIP REPLAYED; do kv "$k" "$(sed -n "s/^$k=//p" "$l" | tail -1)"; done
    grep '^RED=' "$l" || true; kv REPORT "$CLOUD_SUITE_REPORT"; } | tee "$CLOUD_SUITE_REPORT/verdict.log"
  [ "$v" = green ] && exit 0
  exit 1
}
# cloud_pids_tree <pid> → le pid et tous ses descendants, relevés avant tout arrêt (un parent tué d'abord perdrait ses enfants)
cloud_pids_tree() {
  local c; printf '%s\n' "$1"
  for c in $(pgrep -P "$1" 2>/dev/null); do cloud_pids_tree "$c"; done
}
# cloud_suite_partial <motif> : échéance globale — le rapport partiel (TAP, JUnit, suite.log) rapatrié avant l'arrêt qui supprime la VM,
# et nommé dans le verdict (lot 01 de cloud-racine)
cloud_suite_partial() {
  if cloud_vm pull 900 pull "$CLOUD_SUITE_MACHINE" "$CLOUD_SUITE_DIR/out" "$CLOUD_SUITE_REPORT/vm" >/dev/null 2>&1 \
     && [ -n "$(ls -A "$CLOUD_SUITE_REPORT/vm" 2>/dev/null)" ]; then
    cloud_suite_stop "$1; partial report pulled: $CLOUD_SUITE_REPORT/vm"
  fi
  cloud_suite_stop "$1; partial report not pulled"
}
# cloud_suite_stop <motif> [rc] : SUITE=unavailable, motif nommé, rc 3 (130, 143, 129 sur interruption) ; le trap supprime la VM
cloud_suite_stop() {
  trap - INT TERM HUP; CLOUD_SUITE_SAID=1
  { kv SUITE unavailable; kv RUN "${CLOUD_SUITE_RUN:-cloud}"; [ -z "$CLOUD_SUITE_HEAD" ] || kv HEAD "$CLOUD_SUITE_HEAD"; [ -z "$CLOUD_SUITE_MACHINE" ] || kv MACHINE "$CLOUD_SUITE_MACHINE"
    kv REASON "$1"; [ -z "$CLOUD_SUITE_REPORT" ] || kv REPORT "$CLOUD_SUITE_REPORT"; } | if [ -n "$CLOUD_SUITE_REPORT" ]; then tee "$CLOUD_SUITE_REPORT/verdict.log"; else cat; fi
  exit "${2:-3}"
}
# cloud_suite_cleanup : trap EXIT — la VM jetable supprimée (ou la commande qui la supprime nommée), copie locale effacée
cloud_suite_cleanup() {
  local rc=$? m="$CLOUD_SUITE_MACHINE"
  trap - EXIT INT TERM HUP; set +e
  if [ -n "$CLOUD_SUITE_BG" ] && [ "${CLOUD_SUITE_RUN:-}" = mac ]; then   # suite sur le Mac interrompue : tout son arbre arrêté (lot 02)
    # shellcheck disable=SC2046 # une liste de pid, un par mot
    kill -TERM $(cloud_pids_tree "$CLOUD_SUITE_BG") 2>/dev/null
  elif [ -n "$CLOUD_SUITE_BG" ]; then   # appel interrompu : une restauration va à son terme pour livrer sa VM, une attente est arrêtée
    if [ -z "$m" ] && [ -f "$CLOUD_SUITE_REPORT/restore.json" ] && [ ! -s "$CLOUD_SUITE_REPORT/restore.json" ]; then wait "$CLOUD_SUITE_BG"
    else pkill -TERM -P "$CLOUD_SUITE_BG" 2>/dev/null; kill "$CLOUD_SUITE_BG" 2>/dev/null; fi
  fi
  [ -n "$m" ] || m="$(cloud_suite_restored)"
  [ -z "$CLOUD_SUITE_REPORT" ] || rm -f "$CLOUD_SUITE_REPORT/copy.tar.gz" "$CLOUD_SUITE_REPORT"/parts/part.* 2>/dev/null
  [ -z "$CLOUD_SUITE_REPORT" ] || [ ! -d "$CLOUD_SUITE_REPORT/mac-repo" ] || rm -rf "$CLOUD_SUITE_REPORT/mac-repo"   # copie figée du Mac
  if [ -n "$m" ]; then
    if cloud_vm rm 300 rm "$m" >/dev/null 2>&1; then log "Suite VM deleted:"; log "$m"
    else warn "Cloud: deletion of $m refused — cmux vm rm $m"; fi
    cloud_unbusy_mine
  fi
  [ "$CLOUD_SUITE_SAID" = 1 ] || cloud_suite_stop "internal error (exit $rc)"
}
# cloud_suite_bg <sortie> <commande…> : la commande en arrière-plan, attendue par wait — un INT ou un TERM est traité aussitôt, pas
# au retour d'un appel qui peut durer une heure (timeout tourne dans son propre groupe de processus : le signal ne l'atteint pas) ;
# rc de la commande
cloud_suite_bg() {
  local f="$1" rc=0; shift
  : >"$f"; "$@" >"$f" 2>&1 </dev/null & CLOUD_SUITE_BG=$!
  wait "$CLOUD_SUITE_BG" || rc=$?
  CLOUD_SUITE_BG=""; return "$rc"
}
# cloud_suite_restored → la VM écrite par la restauration dans restore.json (.machine, ou .id mesuré sur cmux 0.65), sinon rien
cloud_suite_restored() {
  [ -n "$CLOUD_SUITE_REPORT" ] || return 0
  { jq -r '.machine // .id // empty' "$CLOUD_SUITE_REPORT/restore.json" 2>/dev/null || true; } | head -1
}
# cloud_suite_fits <json de vm ls> : une place de VM libre et le plus grand palier qui tient dans le plafond par VM du forfait et dans son
# reste libre (cloud_size … suite, lot 01 de cloud-racine), 4 vCPU au moins ; CLOUD_SUITE_CPU et CLOUD_SUITE_GB le prennent ; sinon CLOUD_WHY
cloud_suite_fits() {
  local r tab=$'\t'; r="$(cloud_size "$1" suite)" || r=""; CLOUD_SUITE_FULL=0
  case "$r" in
    plein"$tab"*) CLOUD_WHY="${r#plein"$tab"}"; CLOUD_SUITE_FULL=1; return 1 ;;
    *g"$tab"*' vCPU') CLOUD_SUITE_GB="${r%%g"$tab"*}"; CLOUD_SUITE_CPU="${r#*"$tab"}"; CLOUD_SUITE_CPU="${CLOUD_SUITE_CPU%% *}" ;;
    *) CLOUD_WHY="plan unreadable in cmux vm ls"; return 1 ;;
  esac
}
# cloud_suite_full_or_stop : après un cloud_suite_fits en échec — forfait plein (aucun palier) → la suite sur le Mac (lot 02 de
# cloud-racine) ; forfait illisible → unavailable, jamais cinq heures de Mac sur une lecture ratée (revue)
cloud_suite_full_or_stop() {
  [ "${CLOUD_SUITE_FULL:-0}" != 1 ] || cloud_suite_mac "$CLOUD_WHY"
  cloud_suite_stop "$CLOUD_WHY"
}
# cloud_suite_tree <dossier> <commit> → l'arbre du commit sans CLOUD_SUITE_EXCLUDE, celui que le dépôt neuf de la VM doit recomposer
cloud_suite_tree() {
  local idx rc=0; idx="$(mktemp)"; rm -f "$idx"
  { GIT_INDEX_FILE="$idx" git -C "$1" read-tree "$2" \
    && GIT_INDEX_FILE="$idx" git -C "$1" rm -r -q --cached --ignore-unmatch -- "${CLOUD_SUITE_EXCLUDE[@]}" >/dev/null \
    && GIT_INDEX_FILE="$idx" git -C "$1" write-tree; } 2>/dev/null || rc=1
  rm -f "$idx"; return "$rc"
}
# cloud_suite_cpus <machine> : attend (300 s au plus) que la VM agrandie voie ses vCPU ; sinon un avertissement, la suite part quand même
# avec les vCPU vus (CLOUD_SUITE_JOBS : une tâche bats par vCPU obtenu, jamais plus que demandé ; illisible : ceux demandés)
cloud_suite_cpus() {
  local n t=$((SECONDS + ${LAB_CLOUD_SUITE_RESIZE_WAIT:-300}))
  CLOUD_SUITE_JOBS="$CLOUD_SUITE_CPU"
  while :; do
    n="$(cloud_vm cpus 60 exec --timeout 60 "$1" -- getconf _NPROCESSORS_ONLN 2>/dev/null | tr -d ' \r')" || n=""
    case "$n" in ''|*[!0-9]*|0) ;; *) [ "$n" -lt "$CLOUD_SUITE_CPU" ] || { CLOUD_SUITE_JOBS="$CLOUD_SUITE_CPU"; return 0; }; CLOUD_SUITE_JOBS="$n" ;; esac
    [ "$SECONDS" -lt "$t" ] || { warn "Cloud: $1 shows ${n:-?} vCPU, not $CLOUD_SUITE_CPU yet"; return 0; }
    sleep 5
  done
}
# cloud_suite_push <machine> <archive> : morceaux de 1 Mo, chacun envoyé jusqu'à 5 fois et sa taille relue sur la VM (cmux vm push
# coupé une fois sur deux d'un bloc, lot 03), recollés et sha256 relu ; CLOUD_SUITE_PARTS, CLOUD_SUITE_TRIES ; rc 1 avec CLOUD_WHY
cloud_suite_push() {
  local m="$1" a="$2" d f b size got n sum
  d="$(dirname "$a")/parts"; mkdir -p "$d"; CLOUD_SUITE_PARTS=0; CLOUD_SUITE_TRIES=0
  (cd "$d" && split -b 1m "$a" part.) || { CLOUD_WHY="copy not split"; return 1; }
  cloud_vm prep 60 exec --timeout 60 "$m" -- sh -c 'rm -rf ~/bats-run && mkdir -p ~/bats-run/parts' >/dev/null 2>&1 \
    || { CLOUD_WHY="folder ~/bats-run not created on $m"; return 1; }
  for f in "$d"/part.*; do
    b="$(basename "$f")"; size="$(wc -c <"$f" | tr -d ' ')"; n=0; got=""
    while [ "$n" -lt 5 ] && [ "$got" != "$size" ]; do
      n=$((n + 1)); CLOUD_SUITE_TRIES=$((CLOUD_SUITE_TRIES + 1))
      cloud_vm push 300 push "$m" "$f" "bats-run/parts/$b" >/dev/null 2>&1 || true
      got="$(cloud_vm size 60 exec --timeout 60 "$m" -- sh -c "wc -c <~/bats-run/parts/$b" 2>/dev/null | tr -d ' \r')" || got=""
    done
    [ "$got" = "$size" ] || { CLOUD_WHY="part $b not received after 5 tries"; return 1; }
    CLOUD_SUITE_PARTS=$((CLOUD_SUITE_PARTS + 1))
  done
  sum="$(shasum -a 256 "$a" | cut -c1-64)"
  got="$(cloud_vm sum 120 exec --timeout 120 "$m" -- sh -c 'cd ~/bats-run && cat parts/part.* >copy.tar.gz && { sha256sum copy.tar.gz 2>/dev/null || shasum -a 256 copy.tar.gz; }' 2>/dev/null | cut -c1-64)" || got=""
  [ "$got" = "$sum" ] || { CLOUD_WHY="sha256 of the copy differs on $m (${got:-unread})"; return 1; }
}
