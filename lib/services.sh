# shellcheck shell=bash
# services.sh — services locaux d'un couloir (lot 01 de services-couloir) : un projet déclare un crochet versionné
# scripts/lab-services, détecté par sa seule présence (comme scripts/dev.sh). lab close et lab close --abandon l'appellent avec
# le verbe stop juste avant le retrait du dossier — le crochet voit encore son couloir — et lab services <projet> stop <couloir>
# le relance après coup. Environnement du crochet : LAB_PROJECT, LAB_LANE, LAB_WORKTREE (vide quand le dossier n'existe plus) ;
# il tourne dans le dossier du couloir, sinon depuis le checkout principal. Un échec ou un dépassement du délai avertit en se
# nommant : ni la livraison ni le retrait ne sont bloqués (un couloir resté sur disque pour des conteneurs serait pire).

SERVICES_HOOK_REL='scripts/lab-services'
SERVICES_TIMEOUT=120   # LAB_SERVICES_TIMEOUT abrège le délai pour les tests ; une valeur illisible garde celui-ci
SERVICES_LIST_TIMEOUT=15   # list (lot 02) : lu par sweep et doctor, court ; LAB_SERVICES_LIST_TIMEOUT pour les tests

# services_timeout → le délai du crochet, en secondes
services_timeout() {
  local t="${LAB_SERVICES_TIMEOUT:-}"
  [[ "$t" =~ ^[1-9][0-9]*$ ]] || t="$SERVICES_TIMEOUT"
  printf '%s\n' "$t"
}
# services_list_timeout → le délai du verbe list, en secondes
services_list_timeout() {
  local t="${LAB_SERVICES_LIST_TIMEOUT:-}"
  [[ "$t" =~ ^[1-9][0-9]*$ ]] || t="$SERVICES_LIST_TIMEOUT"
  printf '%s\n' "$t"
}
# services_hook <dossier> → le chemin du crochet exécutable de ce dossier, vide sinon (dossier absent, fichier absent ou non
# exécutable : un crochet qu'on ne peut pas lancer n'est pas un crochet)
services_hook() {
  local f
  [ -n "${1:-}" ] || return 0
  f="$1/$SERVICES_HOOK_REL"
  [ -f "$f" ] && [ -x "$f" ] || return 0
  printf '%s\n' "$f"
}
# services_dir <dossier|-> → le dossier d'où lancer le crochet : celui du couloir s'il existe encore, sinon le checkout principal
services_dir() {
  if [ -n "${1:-}" ] && [ "$1" != - ] && [ -d "$1" ]; then printf '%s\n' "$1"; else printf '%s\n' "$P_ROOT"; fi
}
# services_worktree <dossier|-> → ce même dossier quand il existe encore, vide sinon : le LAB_WORKTREE du crochet
services_worktree() {
  if [ -n "${1:-}" ] && [ "$1" != - ] && [ -d "$1" ]; then printf '%s\n' "$1"; fi
}
# services_state <dossier|-> → hook | none : ce que --dry-run annonce sans rien exécuter
services_state() {
  if [ -n "$(services_hook "$(services_dir "${1:-}")")" ]; then printf 'hook\n'; else printf 'none\n'; fi
}
# services_show <dossier|-> : la ligne du récapitulatif avant confirmation, sur stderr. Deux lignes quand le crochet existe,
# chacune tient en 40 colonnes (même règle que close_procs_show)
services_show() {
  if [ -n "$(services_hook "$(services_dir "${1:-}")")" ]; then
    printf 'Services: %s stop\n  %s s max; a failure does not block\n' "$SERVICES_HOOK_REL" "$(services_timeout)" >&2
  else printf 'Services: no hook\n' >&2; fi
}
# services_stop <projet> <couloir> <dossier|-> : le crochet, verbe stop, une fois. Pose SERVICES=stopped|failed|timeout|none,
# l'écrit en KEY=value et avertit en nommant le crochet ; rc 0 (arrêté ou aucun crochet), 1 (échec) ou 2 (délai dépassé) —
# l'appelant continue dans tous les cas. La sortie du crochet part sur stderr : stdout reste du KEY=value.
services_stop() {
  local pname="$1" lane="$2" dir hook wt where secs rc=0
  dir="$(services_dir "${3:-}")"; hook="$(services_hook "$dir")"; wt="$(services_worktree "${3:-}")"
  # « où » plutôt que le chemin : un chemin plus long que la largeur du terminal ne se replie pas, et SOURCE= le nomme déjà
  where="the main checkout"; [ -z "$wt" ] || where="the lane folder"
  SERVICES=none   # sans crochet, rien d'écrit : la sortie de lab close reste celle d'avant (C5), seul --dry-run l'annonce
  [ -n "$hook" ] || return 0
  secs="$(services_timeout)"
  # sous-shell : le cd et les trois variables ne survivent pas à l'appel ; </dev/null, un crochet ne lit jamais le terminal
  (
    cd "$dir" || exit 127
    # shellcheck disable=SC2030 # sous-shell voulu : les trois variables ne survivent pas à l'appel
    export LAB_PROJECT="$pname" LAB_LANE="$lane" LAB_WORKTREE="$wt"
    with_timeout "$secs" "$hook" stop >&2 </dev/null
  ) || rc=$?
  case "$rc" in
    0) SERVICES=stopped; kv SERVICES stopped; log_wrap "services of $lane stopped: $SERVICES_HOOK_REL stop, run from $where" ;;
    124) SERVICES=timeout; kv SERVICES timeout
         warn_wrap "services of $lane not stopped: $SERVICES_HOOK_REL stop, run from $where, exceeded $secs s — TERM then KILL sent to it and its children"
         return 2 ;;
    *) SERVICES=failed; kv SERVICES failed
       warn_wrap "services of $lane not stopped: $SERVICES_HOOK_REL stop, run from $where, failed (code $rc) — its own message is above"
       return 1 ;;
  esac
}

# services_lane_known <couloir> : une trace du couloir existe-t-elle ? Sa fiche ou sa feuille de route dans les documents du
# projet, ou sa fiche fusionnée sur la base distante (le checkout principal ne tire jamais). Sans elle, un nom mal tapé lancerait
# le crochet du checkout principal pour un couloir qui n'a jamais existé.
# Lot 02 : un couloir sans trace que le verbe list nomme encore (ses conteneurs portent son nom) est connu lui aussi.
services_lane_known() {
  local docs ref
  docs="$(docs_dir "$P_ROOT")"
  [ -d "$(lots_dir "$docs" "$1")" ] || [ -f "$(treeplan_file "$docs" "$1")" ] && return 0
  for ref in "$P_REMOTE/$P_BASE" ${P_STAGING:+"$P_REMOTE/$P_STAGING"}; do
    git -C "$P_ROOT" cat-file -e "$ref:docs/lots/$1" 2>/dev/null && return 0
  done
  services_list "$1" && [ -n "$SERVICES_ROWS" ]
}

# services_list [couloir] (lot 02) : le crochet du checkout principal, verbe list, une fois, depuis le checkout principal, avec
# LAB_LANE vide (tout le projet) ou le couloir demandé, LAB_WORKTREE vide, 15 s au plus. Pose SERVICES_LIST=ok|none|failed|timeout,
# SERVICES_ROWS (une ligne <couloir><TAB><ressource> par ressource, couloir valide et ressource non vide seulement ; avec un
# couloir demandé, les siennes seules), SERVICES_LIST_CODE et SERVICES_LIST_ERR (dernière ligne non vide de son stderr).
# rc 0 (ok ou aucun crochet), 1 (échec), 2 (délai dépassé). N'écrit rien : sweep, doctor et lab services le disent chacun à leur façon.
services_list() {
  local only="${1:-}" hook out err secs rc=0 line lane res
  SERVICES_LIST=none; SERVICES_ROWS=""; SERVICES_LIST_CODE=0; SERVICES_LIST_ERR=""
  hook="$(services_hook "$P_ROOT")"; [ -n "$hook" ] || return 0
  secs="$(services_list_timeout)"; out="$(mktemp)"; err="$(mktemp)"
  (
    cd "$P_ROOT" || exit 127
    # shellcheck disable=SC2031 # sous-shell voulu, comme celui de services_stop
    export LAB_PROJECT="$P_NAME" LAB_LANE="$only" LAB_WORKTREE=""
    with_timeout "$secs" "$hook" list >"$out" 2>"$err" </dev/null
  ) || rc=$?
  SERVICES_LIST_CODE="$rc"
  SERVICES_LIST_ERR="$(awk 'NF { l = $0 } END { print l }' "$err" 2>/dev/null | tr -d '\r' | cut -c1-200)"
  case "$rc" in
    0) SERVICES_LIST=ok
       # découpage sur la première tabulation : read avec un IFS tabulation sauterait une tabulation de tête (revue)
       while IFS= read -r line || [ -n "$line" ]; do
         line="${line%$'\r'}"
         case "$line" in *$'\t'*) ;; *) continue ;; esac
         lane="${line%%$'\t'*}"; res="${line#*$'\t'}"
         valid_slug "$lane" && [ -n "$res" ] || continue
         [ -z "$only" ] || [ "$lane" = "$only" ] || continue
         SERVICES_ROWS="$SERVICES_ROWS${SERVICES_ROWS:+$'\n'}$lane"$'\t'"$res"
       done <"$out" ;;
    124) SERVICES_LIST=timeout ;;
    *) SERVICES_LIST=failed ;;
  esac
  rm -f "$out" "$err"
  case "$SERVICES_LIST" in ok) return 0 ;; timeout) return 2 ;; *) return 1 ;; esac
}
# services_list_why → pourquoi list n'a rien rendu, en une phrase (échec ou délai), son dernier message compris
services_list_why() {
  case "$SERVICES_LIST" in
    timeout) printf '%s list exceeded %s s' "$SERVICES_HOOK_REL" "$(services_list_timeout)" ;;
    *) printf '%s list failed (code %s)' "$SERVICES_HOOK_REL" "$SERVICES_LIST_CODE" ;;
  esac
  [ -z "$SERVICES_LIST_ERR" ] || printf ': %s' "$SERVICES_LIST_ERR"
  printf '\n'
}
# services_lanes → les couloirs de SERVICES_ROWS, dans l'ordre d'apparition, chacun avec son nombre de ressources (<couloir><TAB><n>)
services_lanes() {
  [ -n "$SERVICES_ROWS" ] || return 0
  printf '%s\n' "$SERVICES_ROWS" | awk -F'\t' '!($1 in cnt) { order[++k] = $1 } { cnt[$1]++ } END { for (i = 1; i <= k; i++) print order[i] "\t" cnt[order[i]] }'
}
# services_orphans → ceux dont le dossier .worktrees/<couloir> n'existe plus : les services d'un couloir fermé
services_orphans() {
  local lane n
  while IFS=$'\t' read -r lane n; do
    [ -n "$lane" ] && [ ! -d "$P_ROOT/.worktrees/$lane" ] || continue
    printf '%s\t%s\n' "$lane" "$n"
  done < <(services_lanes)
}
# services_count <n> → « 1 service » ou « <n> services »
services_count() { if [ "$1" = 1 ]; then printf '1 service'; else printf '%s services' "$1"; fi; }
# services_no_hook <dossier|-> : le refus nommé quand aucun crochet n'existe, avec le gabarit (une seule ligne de refus)
services_no_hook() {
  log_wrap "a project stops its lanes' services with one executable file committed with the code, $SERVICES_HOOK_REL; ready-made example: templates/project/lab-services"
  die "no $SERVICES_HOOK_REL in $(services_dir "$1"): nothing run"
}

# cmd_services [projet] stop <couloir> : relance le crochet du couloir après coup. Dossier présent → sa copie du crochet ;
# couloir déjà fermé → celle du checkout principal (nommée : elle peut être plus ancienne), LAB_WORKTREE vide. Aucun crochet,
# nulle part : refus nommé, rien lancé.
# Lot 02 : cmd_services [projet] list [couloir] montre ce que list nomme, couloir par couloir (ORPHAN=yes pour un couloir fermé) ;
# cmd_services [projet] stop --orphans lance stop une fois par couloir orphelin.
cmd_services() {
  local verb="" orphans=0 dir rc=0; local -a pos=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      stop|list) if [ -z "$verb" ]; then verb="$1"; else pos+=("$1"); fi; shift ;;   # un couloir peut s'appeler list
      --orphans) orphans=1; shift ;;
      -*) usage ;; *) pos+=("$1"); shift ;;
    esac
  done
  [ -n "$verb" ] || usage
  if [ "$orphans" = 1 ]; then
    [ "$verb" = stop ] && [ "${#pos[@]}" -le 1 ] || usage
    PROJECT="$(resolve_project "${pos[0]:-}")" || exit 1
    load_project "$PROJECT"; services_stop_orphans; return
  fi
  if [ "$verb" = list ]; then
    [ "${#pos[@]}" -le 2 ] || usage
    services_list_cmd "${pos[@]+"${pos[@]}"}"; return
  fi
  [ "${#pos[@]}" -ge 1 ] && [ "${#pos[@]}" -le 2 ] || usage
  split_project_slug "${pos[@]+"${pos[@]}"}"; load_project "$PROJECT"
  valid_slug "$SLUG" || die "invalid lane name: nothing run"
  dir="$(worktree_path "$SLUG")"; [ -d "$dir" ] || dir=-
  kv PROJECT "$P_NAME"; kv LANE "$SLUG"
  if [ "$dir" = - ]; then
    kv SOURCE main-checkout
    if ! services_lane_known "$SLUG"; then
      log_wrap "lane $SLUG has no folder, no batch file, and $SERVICES_HOOK_REL list does not name it"
      die "unknown lane $SLUG: nothing run"
    fi
    [ -z "$(services_hook "$P_ROOT")" ] \
      || log_wrap "lane $SLUG already removed: the hook of the main checkout is used, it may be older than the one the lane had"
  else kv SOURCE lane; fi
  kv HOOK "$(services_state "$dir")"
  # un refus tient sur une seule ligne (lab close --dry-run relit la dernière) : le remède, lui, se replie avant
  [ "$(services_state "$dir")" = hook ] || services_no_hook "$dir"
  services_stop "$P_NAME" "$SLUG" "$dir" || rc=$?
  [ "$rc" = 0 ] || die "services of $SLUG not stopped: fix the hook above, then run it again"
}
# services_list_cmd [projet] [couloir] : lab services list. Un bloc par couloir : LANE=, ORPHAN=yes|no, SERVICE=<couloir> <ressource>
# par ressource ; la commande de ménage nommée quand un orphelin existe. Aucun crochet, échec ou délai : refus nommé, rc 1.
services_list_cmd() {
  local p lane l n orph=0
  if [ "$#" -eq 2 ]; then p="$1"; lane="$2"
  elif [ "$#" -eq 1 ] && project_exists "$1"; then p="$1"; lane=""
  else p=""; lane="${1:-}"; fi
  p="$(resolve_project "$p")" || exit 1; load_project "$p"
  [ -z "$lane" ] || valid_slug "$lane" || die "invalid lane name: nothing run"
  kv PROJECT "$P_NAME"
  services_list "$lane" || true
  kv SERVICES_LIST "$SERVICES_LIST"
  case "$SERVICES_LIST" in
    none) services_no_hook - ;;
    failed|timeout) warn_wrap "$(services_list_why)"; die "services not listed: fix the hook above" ;;
  esac
  sep
  [ -n "$SERVICES_ROWS" ] || { log_wrap "no services listed by $SERVICES_HOOK_REL list${lane:+ for lane $lane}"; return 0; }
  while IFS=$'\t' read -r l n; do
    kv LANE "$l"
    if [ -d "$P_ROOT/.worktrees/$l" ]; then kv ORPHAN no; else kv ORPHAN yes; orph=$((orph + 1)); fi
    printf '%s\n' "$SERVICES_ROWS" | awk -F'\t' -v l="$l" '$1 == l { print "SERVICE=" $1 " " $2 }'
    sep
  done < <(services_lanes)
  if [ "$orph" -ge 1 ]; then
    if [ "$orph" = 1 ]; then n="1 closed lane still has"; else n="$orph closed lanes still have"; fi
    log_wrap "$n services: lab services $P_NAME stop <lane> stops one, lab services $P_NAME stop --orphans stops them all"
  fi
}
# services_stop_orphans : stop une fois par couloir orphelin que list nomme, depuis le checkout principal (LAB_WORKTREE vide) ;
# un échec n'arrête pas les suivants, il rend rc 1 à la fin en nommant les couloirs en échec. Aucun orphelin : dit, rc 0.
services_stop_orphans() {
  local lane n stopped=0 failed=0 names=""
  kv PROJECT "$P_NAME"
  services_list || true
  kv SERVICES_LIST "$SERVICES_LIST"
  case "$SERVICES_LIST" in
    none) services_no_hook - ;;
    failed|timeout) warn_wrap "$(services_list_why)"; die "services not listed, nothing stopped" ;;
  esac
  sep
  while IFS=$'\t' read -r lane n; do
    [ -n "$lane" ] || continue
    kv LANE "$lane"; kv SOURCE main-checkout
    if services_stop "$P_NAME" "$lane" -; then stopped=$((stopped + 1)); else failed=$((failed + 1)); names="$names $lane"; fi
    sep
  done < <(services_orphans)
  kv STOPPED "$stopped"; kv FAILED "$failed"
  if [ "$((stopped + failed))" = 0 ]; then log_wrap "no orphan lane services: nothing stopped"; return 0; fi
  [ "$failed" = 0 ] && return 0
  log_wrap "not stopped:$names; fix the hook above, then run lab services $P_NAME stop --orphans again"
  if [ "$failed" = 1 ]; then die "services of 1 lane not stopped"; else die "services of $failed lanes not stopped"; fi
}
# services_close <dossier> : l'arrêt des services au moment du retrait (lab close, lab close --abandon, veilleur compris).
# Jamais bloquant : un échec ou un délai dépassé est nommé, puis la fermeture continue — un couloir gardé sur disque pour des
# conteneurs serait pire que des conteneurs restés debout.
# Pose SERVICES_FORCE=--force quand le crochet a laissé des fichiers dans un dossier propre avant lui : git worktree remove
# refuserait sinon le retrait, après la livraison.
# shellcheck disable=SC2034 # SERVICES_FORCE est lu par close_finish (lib/close.sh)
services_close() {
  local before=""
  SERVICES_FORCE=""
  [ -z "$(services_hook "$(services_dir "$1")")" ] || before="$(git -C "$1" status --porcelain 2>/dev/null || true)"
  services_stop "$P_NAME" "$SLUG" "$1" \
    || warn_wrap "the lane is removed anyway ($SERVICES): lab services $P_NAME stop $SLUG stops its services later, from the main checkout"
  if [ "$SERVICES" != none ] && [ -z "$before" ] && [ -n "$(git -C "$1" status --porcelain 2>/dev/null || true)" ]; then
    SERVICES_FORCE=--force
    warn_wrap "files left by $SERVICES_HOOK_REL in the lane folder are removed with it"
  fi
}
