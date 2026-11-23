# shellcheck shell=bash
# hooks.sh — SessionStart / SessionEnd / StopFailure, Notification, UserPromptSubmit (Claude) / PreToolUse(Bash|Write|Edit|apply_patch,
# AskUserQuestion). Entrée : JSON sur stdin.
# Mêmes scripts pour Claude Code et Codex. Un hook cassé ne doit jamais bloquer : toute erreur interne → exit 0.
declare -F guard_fields >/dev/null || . "$LAB_ROOT/lib/guard_fast.sh"   # primitives et pré-filtres communs au chemin court
PROTECTED_BRANCHES="main master staging prod production"
CANON_FOR='' HOOK_JOINED=''   # mémoires d'un seul crochet, jamais héritées de l'environnement
read_payload() {
  PAYLOAD="$(cat 2>/dev/null || true)"
  HOOK_CWD="$(payload_get .cwd)"; HOOK_CWD="${HOOK_CWD:-$PWD}"
}
payload_get() { printf '%s' "$PAYLOAD" | jq -r "$1 // empty" 2>/dev/null || true; }   # <chemin jq>
# guard_read : PAYLOAD, HOOK_CWD et HF_* — déjà lus par le chemin court, sinon ici ; une charge que son jq unique refuse (champ d'un
# autre type, plusieurs objets, JSON illisible) se lit champ par champ, comme avant lui
guard_read() {
  guard_fields && return 0
  HOOK_CWD="$(payload_get .cwd)"; HOOK_CWD="${HOOK_CWD:-$HOOK_HERE}"
  HF_TOOL="$(payload_get .tool_name)"; HF_PATH="$(payload_get .tool_input.file_path)"; HF_CMD="$(payload_get .tool_input.command)"
  GUARD_FIELDS=slow
}
json_context() { jq -cn --arg c "$1" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'; }
json_deny() {
  jq -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  printf '%s\n' "$1" >&2
}
is_protected() { local b; for b in $PROTECTED_BRANCHES; do [ "$1" = "$b" ] && return 0; done; return 1; }

# ---------- SessionStart ----------
hook_session_start() {
  read_payload
  local root agent res ctx p slug br lot st docs notes n pr lotrel lock priority='' notice='' rdv='' life='' flat='' online='' night='' lic=''
  root="$(repo_root "$HOOK_CWD" 2>/dev/null || true)"; [ -n "$root" ] || exit 0
  transcript_note "$root" 2>/dev/null || true   # lot 02 de pilotage-voix : la session reprise ou effacée change de transcript
  agent="$(detect_agent)"
  if [ "${LAB_DRY:-0}" = 1 ]; then res=DRY; else res="$(claim "$root" "$agent" 2>/dev/null || echo CLAIMED)"; fi
  case "$res" in
    UPDATING) json_context 'LAB: update in progress. Start no work; reopen this session once treelab update has finished.'; return 0 ;;
    UPDATE_PENDING) json_context 'LAB: Treelab restore pending. Start no work; finish treelab update --resume outside any session, then reopen this session.'; return 0 ;;
  esac
  ctx="LAB worktree=$root branch=$(branch_name "$root")"
  if p="$(project_from_cwd "$root" 2>/dev/null)" && [ -n "$p" ]; then
    load_project "$p" 2>/dev/null || true
    slug="$(wt_lane "$root")"; same_path "$root" "$P_ROOT" && slug="main-checkout"
    br="$(branch_name "$root")"
    if [ "$slug" = main-checkout ]; then ctx="LAB project=$p worktree=$root (main-checkout)"; else ctx="LAB project=$p worktree=$root lane=$slug"; fi
    if [ "$slug" != main-checkout ]; then
      ctx="$ctx phase=$(lane_phase "$root")"
      case "$(lane_phase "$root")" in
        'in acceptance') ctx="$ctx — Work finished, to try together." ;;
        'acceptance passed') ctx="$ctx — Closing on explicit confirmation." ;;
        permanent) ctx="$ctx — Permanent lane: no batch left, wait for the request." ;;
        *) [ -z "$(last_lot_notice "$root")" ] || ctx="$ctx — $(last_lot_notice "$root")" ;;
      esac
    fi
    ctx="$ctx branch=${br:-detached-HEAD} base=$P_BASE pr-target=$(pr_base)"
    # règle cloud (lot 03 de cmux-pro) : avec cmux seulement, jamais en mode mesure ; aucune question depuis le lot 01 d'aiguillage-cloud,
    # la ligne Execution de chaque fiche choisit Cloud ou Mac
    if [ "${LAB_DRY:-0}" != 1 ] && has_cmux; then
      local cw=-; [ "$slug" = main-checkout ] || cw="$root"
      cloud_resolve "$p" "$cw" 2>/dev/null || true
      ctx="$ctx cloud=$CLOUD($CLOUD_SOURCE)"
      # besoins trouvés sur une VM, retenus hors du dépôt (lot 02 d'aiguillage-cloud) : batch-plan les lit avant d'écrire la ligne Execution
      # les trois plus récents seulement, puis leur compte : le plafond de 800 ne coupe jamais batch=, file= ni lock= (revue)
      local needs; needs="$(cloud_needs_lines "$p" 2>/dev/null | awk -F '\t' '{ l[NR] = $2 "(" $5 ")" } END { s = (NR > 3 ? NR - 2 : 1); for (i = s; i <= NR; i++) printf "%s%s", (i > s ? "," : ""), l[i]; if (NR > 3) printf " +%d more", NR - 3 }')" || needs=""
      [ -z "$needs" ] || ctx="$ctx cloud-needs=$needs"
    fi
    pr="$(pr_info "$P_ROOT" "$br" 2>/dev/null || true)"
    [ -n "$pr" ] && ctx="$ctx PR=#$(printf '%s' "$pr" | cut -f1)($(printf '%s' "$pr" | cut -f2))"
    # ce qui est en ligne (lot 02 de mise-en-ligne), jamais en mode mesure : en tête si ce couloir est servi sans être fusionné,
    # sinon avant les chemins longs (LAB_DOCS, file) que le plafond de 800 coupe
    if [ "${LAB_DRY:-0}" != 1 ]; then online="$(en_ligne_line 2>/dev/null || true)"; fi
    if [ -n "$online" ] && [ "$slug" != main-checkout ] && [ -n "$(deploy_serving "$slug" 2>/dev/null)" ]; then
      priority="${online%.} — this lane is live: go live with lab deploy only."
    elif [ -n "$online" ]; then ctx="$ctx $online"; fi
    docs="$(docs_dir "$root")"
    [ "$P_DOCS" = local ] && ctx="$ctx LAB_DOCS=$docs (docs outside the repository: masterplan, batches and CHANGELOG live there)"
    if [ "$slug" != main-checkout ]; then
      lot="$(wt_lot_file "$root")"   # fiche du lot de la branche courante (une branche par lot), sinon celle du couloir
      if [ -n "$lot" ]; then st="$(lot_state "$lot")"; lotrel="${lot#"$root"/}"; ctx="$ctx batch=$(basename "$lot" .md) state=${st:-?} file=$lotrel"
      else ctx="$ctx batch=none (lab batch new --title …)"; fi
      # issue des veilleurs de livraison (lot 14) : un rouge, un conflit, un échec ou un veilleur mort passe en tête
      local wline
      while IFS= read -r wline; do
        [ -n "$wline" ] || continue
        case "$wline" in
          *" red — "*|*" conflict — "*|*" failed — "*|*" changed — "*|*" dead — "*) priority="${priority:+$priority }WATCHER=$wline." ;;
          *) ctx="$ctx WATCHER=$wline." ;;
        esac
      done < <(SLUG="$slug" watch_summary "$slug" 2>/dev/null || true)
      # couloirs synchronisés (lot 15) : git local seul — ni fetch, ni commit, ni gh ; lab launch fait le merge, pas le hook. Jamais en
      # mode mesure : ces lignes varient avec les autres couloirs, et le cliquet du doctor les verrait monter
      local behind=0 overlap='' migr=''
      if [ "${LAB_DRY:-0}" != 1 ]; then
        sync_stacked "$root" 2>/dev/null || behind="$(sync_behind "$root" 2>/dev/null || echo 0)"
        overlap="$(overlap_hook_line "$root" 2>/dev/null || true)"
        migr="$(migrations_hook_line "$root" 2>/dev/null || true)"   # lot 02 de sans-perte : avertit, ne bloque rien
      fi
      [ -z "$migr" ] || priority="${priority:+$priority }$migr"
      # en tête, avec les alertes du veilleur : le plafond de 800 coupe la fin du contexte, jamais elles (parcours réel du lot 15)
      [ -z "$overlap" ] || priority="${priority:+$priority }$overlap"
      [ "${behind:-0}" -eq 0 ] 2>/dev/null || priority="${priority:+$priority }BASE=behind by $behind: lab sync $p $slug."
    else
      ctx="$ctx — main checkout: no commit here; \"lab new <lane>\""
    fi
    notes="$(project_dir "$p")/notes.md"
    # vivre avec son projet (lot 18) : ressources tenues, build servie, fiches à plat voisines d'un couloir neuf — informations
    # seulement, jamais en mode mesure (elles varient avec les autres couloirs et l'horloge)
    if [ "${LAB_DRY:-0}" != 1 ]; then
      life="$(resource_hook_line 2>/dev/null || true)"
      life="$life${life:+ }$(served_hook_line 2>/dev/null || true)"
      if [ "$slug" != main-checkout ] && lane_unplanned "$root" 2>/dev/null; then
        flat="$(flat_lots_overlap "$(docs_dir "$root")" "$(lane_topic "$root" 2>/dev/null)" 2>/dev/null | sync_join)" || flat=''
        [ -z "$flat" ] || life="$life${life:+ }FLAT_BATCHES=$flat (old location, close to the topic: read them before planning)."
      fi
      life="${life% }"
    fi
    # échéances du projet (lot 05) : jamais en mode mesure — la ligne varie avec l'horloge, et le cliquet du doctor la verrait monter
    if [ "${LAB_DRY:-0}" != 1 ]; then rdv="$(rdv_hook_line "$p" "$(hook_session_key)" 2>/dev/null)" || rdv=''; fi
  fi
  # nuit de la base rouge (lot 03 de ci-sobre) : le cache seul, jamais gh ; en tête de toute session du projet, derrière un éventuel
  # LOCK= ; jamais en mode mesure — la ligne dépend de GitHub et de l'horloge
  if [ -n "${p:-}" ] && [ "${LAB_DRY:-0}" != 1 ]; then night="$(night_line "$p" "${slug:-}" 2>/dev/null)" || night=''; fi
  [ -z "$night" ] || priority="$night${priority:+ $priority}"
  case "$res" in
    # mode mesure (doctor) : libellé constant, de la longueur du plus long libellé réel — la mesure ne dépend pas de l'agent qui la lance (lot 16)
    DRY) ctx="$ctx lock=this session (measure)." ;;
    # claim tourne dans une substitution de commande : ses LOCK_* n'existent pas ici, et set -u tuait le hook sans un mot —
    # aucun contexte rendu sur un worktree occupé (mesuré le 2026-09-02, lot 8). On relit le verrou.
    OCCUPIED) lock="$(lock_file "$root")"; priority="LOCK=ANOTHER LIVE SESSION ($(lock_field "$lock" agent || true) pid $(lock_field "$lock" pid || true) since $(lock_field "$lock" since || true)): write nothing here; offer to resume that session or to isolate a new topic (lab new).${priority:+ $priority}" ;;
    # relance en masse (lot 01 de reprise-apres-migration) : contention entre sessions, jamais une mise à jour ; contexte complet, et la
    # garde (hook_lock_resume) prend le verrou au premier outil
    PENDING) priority="LOCK=pending (simultaneous start, no update): work normally; the lock is taken at your first tool.${priority:+ $priority}" ;;
    REGISTRY_FAILED) priority="LOCK=registry-failed (session index $(operation_paths 2>/dev/null; printf '%s' "${LAB_SESSION_DIRECTORY:-?}") refused this session, no update): work normally; the lock is retried at your first tool; if this comes back, fix that folder (yours, mode 700, no link).${priority:+ $priority}" ;;
    *) ctx="$ctx lock=this session ($agent)." ;;
  esac
  case "$rdv" in
    neutre$'\t'*) ctx="$ctx ${rdv#*$'\t'}" ;;                             # après lock=, avant Notes: — le plafond de 800 coupe la fin
    rouge$'\t'*) priority="${priority:+$priority }${rdv#*$'\t'}" ;;          # en tête, après un éventuel LOCK=
  esac
  # fin des droits aux mises à jour (lot 05 de refonte-onboarding) : cache seul, une fois par jour, en tête comme une échéance en
  # retard ; jamais en mode mesure, jamais consommée par une session refusée (OCCUPIED), muette sur toute erreur
  if [ "${LAB_DRY:-0}" != 1 ] && [ "$res" != OCCUPIED ]; then
    lic="$(entitlement_hook_line 2>/dev/null)" || lic=''
    [ -z "$lic" ] || priority="${priority:+$priority }$lic"
  fi
  # en tête, après les alertes : des chemins longs (LAB_DOCS, file) remplissaient le plafond de 800 avant elles (parcours réel du lot 18)
  [ -z "$life" ] || priority="${priority:+$priority }$life"
  # langue de l'agent (lot 01 du couloir anglais) : premier champ du contexte ordinaire (« LAB lang=fr project=… »), après les alertes
  # qui gardent la tête, avant la coupe à 800 ; jamais en mode mesure, comme les lignes ci-dessus — elle dépend de la machine, et le
  # cliquet du doctor la verrait monter
  [ "${LAB_DRY:-0}" = 1 ] || ctx="LAB lang=$(lab_lang_detect) ${ctx#LAB }"
  if [ -n "$priority" ]; then ctx="$priority $ctx"; fi
  if [ -n "${notes:-}" ] && [ -f "$notes" ]; then
    n="$(grep -v '^# ' "$notes" | grep -v '^[[:space:]]*$' | head -20 | tr '\n' ' ' || true)"
    [ -n "$n" ] && ctx="$ctx Notes: $n"
  fi
  [ "${#ctx}" -gt 800 ] && ctx="${ctx:0:797}…"
  # annonce laissée par la mise à jour automatique de lab next (lot 21), rendue une seule fois
  # une session refusée (OCCUPIED) ne la consomme pas : elle reste pour la session ouverte par lab next
  if [ "${LAB_DRY:-0}" != 1 ] && [ "$res" != OCCUPIED ] && [ -f "$LAB_STATE/update-auto-notice" ]; then
    notice="$(. "$LAB_ROOT/lib/install.sh"; . "$LAB_ROOT/lib/update.sh"; update_auto_notice)" 2>/dev/null || notice=''
    if [ -n "$notice" ]; then
      [ "$((${#ctx}+${#notice}+1))" -le 800 ] || ctx="${ctx:0:$((797-${#notice}))}…"
      ctx="$ctx $notice"
    fi
  fi
  json_context "$ctx"
}

# hook_session_key : la clé de la session qui démarre — .session_id du JSON reçu, sinon agent_pid ; une reprise garde sa clé
hook_session_key() {
  local k; k="$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null | tr -d '\t\r\n' || true)"
  if [ -n "$k" ]; then printf '%s\n' "$k"; else agent_pid; fi
}
# rdv_hook_line <projet> <clé> → « neutre<TAB>DUE: … », « rouge<TAB>DUE=RED … » ou rien (ni retard ni 48 h : vert).
# Rouge : un retard ouvert (même id, même échéance) déjà vu en retard par une autre session — un rouge permanent n'est plus un signal
# (constat 6 du brief), seul un retard resté non tranché d'une session à l'autre l'est. Mémoire : $LAB_STATE/echeances/<projet>.vues,
# id⇥échéance⇥clé⇥horodatage, deux clés au plus par retard (une clé autre que la courante suffit), purgée de tout ce qui n'est plus
# un retard ouvert (tranché, redaté). rc 1 sur toute erreur (registre illisible, état non inscriptible, LAB_NOW mal formé) :
# l'appelant garde son contexte habituel. Deux démarrages simultanés : la dernière écriture gagne, au pire un rouge retardé.
rdv_hook_line() {
  local p="$1" key="$2" reg now nowe scan open late n48 dir vues src out newv tmp reds='' ids r=0
  reg="$(rdv_file "$p")"; dir="$LAB_STATE/echeances"; vues="$dir/$p.vues"
  [ -e "$reg" ] || return 0
  [ -r "$reg" ] || return 1
  now="$(rdv_now)" || return 1
  nowe="$(rdv_epoch "$now")" || return 1
  scan="$(rdv_scan "$reg" "$nowe")" || return 1
  open="$(rdv_open "$scan")" || return 1
  late="$(printf '%s\n' "$open" | awk -F "$RDV_US" '$9 == "late" { print $3 "\t" $4 }')" || return 1
  n48="$(printf '%s\n' "$open" | awk -F "$RDV_US" '$9 == "48h" { n++ } END { print n + 0 }')" || return 1
  if [ -n "$late" ] || [ -e "$vues" ]; then
    mkdir -p "$dir" 2>/dev/null && [ -w "$dir" ] || return 1
    src="$vues"; [ -e "$src" ] || src=/dev/null
    out="$(printf '%s\n' "$late" | RDV_KEY="$key" RDV_NOW="$now" awk '
      BEGIN { FS = OFS = "\t"; key = ENVIRON["RDV_KEY"]; now = ENVIRON["RDV_NOW"] }
      FNR == NR { if ($0 != "") { n++; order[n] = $1 FS $2; late[$1 FS $2] = 1 }; next }
      NF >= 4 && (($1 FS $2) in late) && !seen[$1 FS $2 FS $3]++ {
        k = $1 FS $2
        if (cnt[k] < 2) { cnt[k]++; kept[k] = kept[k] "V" OFS $0 "\n"; if ($3 == key) mine[k] = 1; else red[k] = 1 }
      }
      END {
        for (i = 1; i <= n; i++) {
          k = order[i]; printf "%s", kept[k]
          if (!mine[k] && cnt[k] < 2) print "V", k, key, now
          if (red[k]) { split(k, f, FS); print "R", f[1] }
        }
      }' - "$src")" || return 1
    newv="$(printf '%s\n' "$out" | awk 'substr($0, 1, 2) == "V\t" { print substr($0, 3) }')"
    if [ -z "$newv" ]; then rm -f "$vues" || return 1
    elif [ "$newv" != "$(cat "$vues" 2>/dev/null)" ]; then
      tmp="$(mktemp "$dir/.$p.vues.XXXXXX")" || return 1
      if ! { printf '%s\n' "$newv" >"$tmp" && mv "$tmp" "$vues"; }; then rm -f "$tmp"; return 1; fi
    fi
    reds="$(printf '%s\n' "$out" | awk 'substr($0, 1, 2) == "R\t" { print substr($0, 3) }')"
  fi
  [ -n "$late" ] || [ "$n48" -gt 0 ] || return 0
  if [ -n "$reds" ]; then
    r="$(printf '%s\n' "$reds" | grep -c .)"
    ids="$(printf '%s\n' "$reds" | head -5 | paste -sd, - | sed 's/,/, /g')"; [ "$r" -le 5 ] || ids="$ids, …"
    printf 'rouge\tDUE=RED %s overdue deadline(s) left unsettled since an earlier session (no. %s): report them to the user first; lab due %s settles them.\n' "$r" "$ids" "$p"
  else
    printf 'neutre\tDUE: %s overdue, %s within 48 h — lab due %s\n' "$(printf '%s\n' "$late" | grep -c . || true)" "$n48" "$p"
  fi
}

# ---------- SessionEnd ----------
hook_session_end() {
  read_payload
  local root; root="$(repo_root "$HOOK_CWD" 2>/dev/null || true)"; [ -n "$root" ] || exit 0
  release "$root" 2>/dev/null || true
  # session finie : sa question n'attend plus personne (lot 03 d'autonomie-tours) ; son couloir est son dossier de lancement
  root="$(repo_root "${CLAUDE_PROJECT_DIR:-$HOOK_CWD}" 2>/dev/null || true)"; [ -z "$root" ] || waits_clear_answered "$root" 2>/dev/null || true
  exit 0
}

# ---------- notify (lot 03 d'autonomie-tours) ----------
# Claude Code seul, mesuré sur 2.1.322 : Notification porte message, title et notification_type (permission_prompt, idle_prompt,
# elicitation_dialog… ; le matcher filtre sur ce type) ; PreToolUse de l'outil AskUserQuestion porte tool_input.questions ;
# UserPromptSubmit porte prompt ; PostToolUse d'AskUserQuestion porte le libellé choisi dans tool_response.answers (2.1.330, lot 10).
# Une question ou une autorisation pose l'entrée d'attente du couloir (<couloir>/.lab/waits-for) et
# notifie son onglet — sauf sous l'enveloppe Claude de cmux, qui notifie déjà cette surface ; un prompt envoyé l'efface. Couloirs
# de tous les projets, tour ou non ; checkout principal et dossier hors projet : rien. Toute erreur : sortie 0, aucun texte.
hook_notify() {
  read_payload
  local ev root p kind why notify=yes source=""
  ev="$(printf '%s' "$PAYLOAD" | jq -r '.hook_event_name // empty' 2>/dev/null || true)"
  # le couloir de la session est son dossier de lancement, jamais le dossier où elle a fait cd (revue du lot) — comme la garde
  root="$(repo_root "${CLAUDE_PROJECT_DIR:-$HOOK_CWD}" 2>/dev/null || true)"; [ -n "$root" ] && [ -d "$root/.lab" ] || exit 0
  transcript_note "$root" 2>/dev/null || true
  case "$ev" in
    # lot 10 : les mots de l'utilisateur (prompt exact, libellé cliqué) enregistrés par lab, puis la consigne rendue à la session
    UserPromptSubmit) waits_clear "$root" 2>/dev/null || true; ( words_on_prompt "$root" ) 2>/dev/null || true; exit 0 ;;
    PostToolUse)   # la réponse à AskUserQuestion est arrivée : la boîte est effacée quoi que dise l'attente (un autre crochet a pu
      rm -f "$(waits_question_file "$root")" 2>/dev/null || true   # l'effacer le premier, essai réel du lot 02 de pilotage-voix)
      waits_clear_answered "$root" 2>/dev/null || true
      [ "$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // empty' 2>/dev/null || true)" != AskUserQuestion ] || ( words_on_click "$root" ) 2>/dev/null || true
      exit 0 ;;
    # fin du tour (lot 09, revue) : aucune boîte ni autorisation ne reste ouverte — une autorisation accordée d'un clic n'envoie ni
    # prompt ni PostToolUse suivi ; l'idle_prompt qui suivra ne masque plus rien. Un blocage posé par lab reste.
    Stop) waits_clear_answered "$root" 2>/dev/null || true; exit 0 ;;
    Notification)
      case "$(printf '%s' "$PAYLOAD" | jq -r '.notification_type // empty' 2>/dev/null || true)" in
        permission_prompt) kind=permission ;; elicitation_dialog) kind=question ;;
        # session au repos : kind=question pour Ginkgo et les autres lecteurs, source=idle pour la tour (lot 09) ; la tour attend
        # son prochain point : ce n'est pas une question
        idle_prompt) kind=question; source=idle
          # une vraie question, une autorisation ou un blocage déjà posés restent : le repos qui les suit ne les masque pas
          case "$(waits_get "$root" kind 2>/dev/null)" in question|permission|blocked) waits_idle "$root" 2>/dev/null || exit 0 ;; esac
          p="$(project_from_cwd "$root" 2>/dev/null)" && load_project "$p" 2>/dev/null && lane_is_tower "$root" && exit 0 ;;
        *) exit 0 ;;
      esac
      why="$(printf '%s' "$PAYLOAD" | jq -r '.message // empty' 2>/dev/null || true)" ;;
    PreToolUse)
      [ "$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // empty' 2>/dev/null || true)" = AskUserQuestion ] || exit 0
      kind=question; why="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.questions[0].question // empty' 2>/dev/null || true)" ;;
    *) exit 0 ;;
  esac
  p="$(project_from_cwd "$root" 2>/dev/null)" && [ -n "$p" ] && load_project "$p" 2>/dev/null || exit 0
  ! same_path "$root" "$P_ROOT" || exit 0
  ! tower_cmux_notifies || notify=no
  # la boîte entière, pour lab ginkgo question (lot 02 de pilotage-voix) : avant l'entrée d'attente, jamais sans elle
  [ "$ev" != PreToolUse ] || waits_question_set "$root" "$(printf '%s' "$PAYLOAD" | jq -c '.tool_input.questions' 2>/dev/null || true)" 2>/dev/null || true
  tower_signal "$root" "$kind" "${why:-$(waits_label "$kind")}" "$notify" "$source" 2>/dev/null || true
  exit 0
}

# ---------- StopFailure (lot 02 de cmux-pro) ----------
# Une limite d'usage (5 h ou 7 jours) arrête le tour de Claude : le compte de la session (LAB_COMPTE, posé par lab au lancement) est
# marqué épuisé jusqu'à l'heure lue, puis la bascule relance la même conversation dans l'onglet du couloir sur le compte suivant.
# Elle est détachée (nouvelle session POSIX, comme le veilleur) : elle remplace la session dont ce hook est l'enfant.
# LAB_COMPTE_SYNC=1 (tests) la déroule sur place. Sans jeton rangé, hors couloir ou sur un 429 passager : rien.
hook_stop_failure() {
  read_payload
  local err msg sid root p slug label f held ech win rc pid dir
  err="$(printf '%s' "$PAYLOAD" | jq -r '.error // empty' 2>/dev/null || true)"; [ "$err" = rate_limit ] || exit 0
  comptes_actifs || exit 0
  [ "${LAB_APPEL_COURT:-0}" != 1 ] || exit 0   # appel de vérification de lab (compte_appel_court) : il note la limite lui-même
  msg="$(printf '%s' "$PAYLOAD" | jq -r '.last_assistant_message // empty' 2>/dev/null || true)"
  compte_limite_lue "$msg" || exit 0
  sid="$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null || true)"
  compte_conversation_ok "$sid" || exit 0
  # lot 06 : la note d'abord, partout — couloir, main, claude tapé à la main hors de tout projet enregistré
  f="$(state_dir comptes)/bascule.log"
  # sans heure lisible : échéance de repli (+1 h) sous la fenêtre « ? », jamais recoupée avec un relevé (revue du lot 05)
  if ech="$(compte_reprise_annoncee "$msg")"; then win="$(compte_fenetre_lue "$msg")"; else ech="$(compte_reprise_lue "$msg")"; win="?"; fi
  rc=0
  # le compte noté est celui de la fenêtre qui a touché la limite (lot 05) — la charge du hook ne porte ni e-mail ni usage (mesuré
  # sur Claude Code 2.1.318). Sous un jeton, LAB_COMPTE (compte_reel). Badges en service : la fenêtre garde en mémoire la connexion
  # de son lancement, même après une bascule globale — LAB_COMPTE, sauf /login adopté depuis. Sinon le /login réel (lot 01). Un
  # e-mail sans étiquette : avertissement, aucune note, et pas de bascule — elle pourrait relancer sur ce même /login et boucler.
  if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && compte_badges_servent && [ -n "${LAB_COMPTE:-}" ] && compte_connu "$LAB_COMPTE" \
      && ! compte_adopte_depuis "${LAB_COMPTE_DEPUIS:-}"; then label="$LAB_COMPTE"
  elif [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -z "${LAB_COMPTE:-}" ] && compte_fenetre_ancienne; then
    # fenêtre lancée avant le dernier changement de compte du Mac (incident du lot 06) : jamais le compte du Mac, seulement le seul
    # compte dont le relevé, plein, annonce cette reprise
    label="$(compte_releve_concordant "" "$ech" "$win")" || label=""
  else label="$(compte_reel)" || rc=$?; fi
  if [ "$rc" != 0 ]; then
    if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && comptes_identifies && { [ "$rc" = 2 ] || ! compte_badges_servent; }; then
      printf 'lab: warning: the /login account of this session is not identified: no note, no switch — lab account identify <label>\n' >>"$f" 2>/dev/null || true
      exit 0
    elif [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && compte_badges_servent; then label=""
    else label="${LAB_COMPTE:-$COMPTE_PRINCIPAL}"; compte_connu "$label" || label=""; fi   # compte retiré : jamais le principal à sa place
  fi
  # recoupement : une échéance que le relevé du compte dément n'est pas la sienne — le seul compte dont le relevé concorde, ou aucun
  if [ -n "$label" ] && [ "$(compte_releve_accord "$label" "$ech" "$win")" = contradicts ]; then
    label="$(compte_releve_concordant "$label" "$ech" "$win")" || label=""
  fi
  if [ -n "$label" ]; then compte_marquer "$label" "$ech" "$win"
  else
    # aucune note plutôt qu'une fausse ; la session repart sur le compte posé, une seule fois par 10 min (jamais de boucle)
    if compte_sans_note_recente "$sid"; then
      printf 'lab: warning: account of session %s undetermined again: no note, not switched again\n' "$sid" >>"$f" 2>/dev/null || true
      exit 0
    fi
    printf 'lab: warning: account of session %s undetermined: no note, switched to the account in place\n' "$sid" >>"$f" 2>/dev/null || true
  fi
  root="$(repo_root "$HOOK_CWD" 2>/dev/null || true)"
  if [ -n "$root" ] && p="$(project_from_cwd "$root" 2>/dev/null)" && [ -n "$p" ] && load_project "$p" 2>/dev/null \
      && ! same_path "$root" "$P_ROOT"; then
    # couloir : seule la session qui tient le verrou du couloir est remplacée dans l'onglet : une autre session Claude du worktree
    # (claude -p lancé depuis elle, seconde session ouverte à la main) a pour agent le plus proche un autre pid — le compte est
    # marqué, rien n'est tué. Sans verrou, personne à protéger : la bascule a lieu (mesuré au lot 02 : verrou absent pendant une
    # session réelle).
    slug="$(wt_lane "$root")"
    held="$(lock_field "$(lock_file "$root")" pid || true)"
    [ -z "$held" ] || [ "$(agent_pid)" = "$held" ] || exit 0
    stop_failure_detache "$root" "$f" account switch "$p" "$slug" "$sid"
    exit 0
  fi
  # main, claude tapé à la main (lot 06) : la fenêtre la plus proche, si c'est bien un claude, relancée dans son onglet cmux ou, hors
  # cmux, badge suivant posé (lab account relaunch, détaché : la pose testée dépasse le délai du hook)
  pid="$(agent_pid)"
  case "$(basename -- "$(ps -o comm= -p "$pid" 2>/dev/null)")" in claude|claude-code) ;;
    *) printf 'lab: warning: session %s: its claude window not found (pid %s): noted, not relaunched\n' "$sid" "$pid" >>"$f" 2>/dev/null || true; exit 0 ;;
  esac
  dir="${CLAUDE_PROJECT_DIR:-$HOOK_CWD}"
  stop_failure_detache "$dir" "$f" account relaunch "$sid" "$pid" "$dir"
  exit 0
}
# stop_failure_detache <dossier> <journal> <arguments de lab…> : lab lancé hors de la session (setsid), sortie au journal ;
# LAB_COMPTE_SYNC=1 (tests) le déroule sur place
stop_failure_detache() {
  local d="$1" f="$2"; shift 2
  if [ "${LAB_COMPTE_SYNC:-0}" = 1 ]; then
    "$LAB_ROOT/bin/lab" "$@" </dev/null >>"$f" 2>&1 || true
  else
    ( cd "$d" 2>/dev/null || cd /; exec perl -e 'use POSIX (); POSIX::setsid(); exec @ARGV or exit 127' \
        "$LAB_ROOT/bin/lab" "$@" </dev/null >>"$f" 2>&1 3>&- ) &
  fi
}

# ---------- PreToolUse Bash ----------
# Découpe la commande en segments (&&, ||, ;, |, & seul, \n) après avoir neutralisé le contenu des chaînes quotées ;
# les redirections >&, <&, &> restent dans leur segment (« cmd & git … » lance deux commandes).
# Le marqueur est un caractère de contrôle : un « Q » l'était, et tout chemin portant un Q majuscule devenait non résoluble
# (bats-run-Q4SsbB : commit après cd vers le checkout principal laissé passer — mesuré le 2026-09-02, lot 8).
# QUOTED et segments_line : lib/guard_fast.sh. segments_set <commande> [data] : SEGMENTS, un segment par ligne — par le shell seul pour
# une commande courte sans here-doc, sinon par un seul awk (heredoc_awk retire les corps, puis découpe) : mêmes lignes des deux façons
segments_set() {
  local line
  SEGMENTS=''
  case "$1" in *'<<'*|*$'\001'*|*$'\002'*|*$'\003'*) ;; *)   # un octet dont l'awk se sert comme marque : lui seul le lit comme avant
    if [ "${#1}" -le 2000 ]; then
      while IFS= read -r line || [ -n "$line" ]; do segments_line "$line"; SEGMENTS="$SEGMENTS$SEG_LINE"$'\n'; done <<<"$1"
      return 0
    fi ;;
  esac
  SEGMENTS="$(heredoc_awk "${2:-0}" 1 <<<"$1")" && return 0
  SEGMENTS=''   # awk en échec : la commande entière reste contrôlée
  while IFS= read -r line || [ -n "$line" ]; do segments_line "$line"; SEGMENTS="$SEGMENTS$SEG_LINE"$'\n'; done <<<"$1"
}
# quote_join : une chaîne entre guillemets ouverte en fin de ligne (git commit -m "$(cat <<'EOF' … EOF )" -- a.md) est recollée sur
# une seule ligne. Sert à la seule règle du commit (commit_joined_ok) : segments() garde ses lignes d'origine, toutes contrôlées,
# car un recollage mal apparié ($'…\'…') cacherait une commande dans une chaîne (lot-01 de sans-perte).
quote_join() {
  awk -v q="'" '
    {
      line = $0
      if (open) buf = buf " " line; else buf = line
      n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (st == 0) { if (c == "\\") i++; else if (c == q) st = 1; else if (c == "\"") st = 2 }
        else if (st == 1) { if (c == q) st = 0 }
        else { if (c == "\\") i++; else if (c == "\"") st = 0 }
      }
      if (st) { open = 1; next }
      print (buf != line ? "\002" : "") buf; open = 0   # \002 : enregistrement recollé depuis plusieurs lignes
    }
    END { if (open) print "\002" buf }
  '
}
# heredoc_strip <commande> : retire le corps d'un here-doc qui alimente ssh — il s'exécute sur la machine distante, jamais ici (lot 17).
# Marqueurs nus, cités ('EOF', "EOF", \EOF) et <<- (tabulations de tête) ; plusieurs here-docs par ligne lus dans l'ordre ; marqueur
# nu : les lignes qui portent $(…) ou un accent grave restent contrôlées (elles s'exécutent localement avant ssh). En cas de
# doute, le corps reste contrôlé : commande propriétaire autre que ssh (bash, sh, zsh, eval…), opérateur entre guillemets, marqueur
# jamais refermé (le corps retenu est alors rendu). Les <<< (here-string) ne sont pas des here-docs.
# [data] = 1 (garde des déploiements, lot 02 de mise-en-ligne) : le corps qui alimente une commande autre qu'un shell (cat, python3,
# git commit -F -…) est du texte, retiré aussi ; un corps donné à bash, sh, zsh, eval ou source reste contrôlé.
heredoc_strip() {
  local out; out="$(printf '%s\n' "$1" | heredoc_awk "${2:-0}")" || out="$1"   # awk en échec : la commande entière reste contrôlée
  printf '%s\n' "$out"
}
# Toujours dans un sous-shell (exec). [cut] = 1 : chaque ligne gardée est rendue neutralisée (chaînes citées → QUOTED) et découpée en segments
heredoc_awk() {
  exec awk -v q="'" -v data="${1:-0}" -v cut="${2:-0}" -v qd="$QUOTED" '
    function out(l) {
      if (cut) {
        gsub(/\047[^\047]*\047/, qd, l); gsub(/"[^"]*"/, qd, l)
        gsub(/&&|\|\||;|\|/, "\n", l); gsub(/>&/, "\001", l); gsub(/<&/, "\002", l); gsub(/&>/, "\003", l); gsub(/&/, "\n", l)
        gsub(/\001/, ">\\&", l); gsub(/\002/, "<\\&", l); gsub(/\003/, "\\&>", l)
      }
      print l
    }
    function owner_word(pre,   parts, k, w, i, t) {
      k = split(pre, parts, /&&|\|\||;|\|/); pre = parts[k]
      w = split(pre, t, /[ \t]+/)
      for (i = 1; i <= w; i++) {
        if (t[i] == "" || t[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || t[i] ~ /^(sudo|env|nohup|command|exec|time)$/) continue
        sub(/.*\//, "", t[i]); sub(/^\(+/, "", t[i]); return t[i]
      }
      return ""
    }
    function owner_is_shell(pre,   o) { o = owner_word(pre); return o == "" || o ~ /^(bash|sh|zsh|dash|ksh|fish|eval|source|\.)$/ }
    function owner_is_ssh(pre,   parts, k, w, i, t) {
      k = split(pre, parts, /&&|\|\||;|\|/); pre = parts[k]
      w = split(pre, t, /[ \t]+/)
      for (i = 1; i <= w; i++) {
        if (t[i] == "" || t[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || t[i] ~ /^(sudo|env|nohup|command|exec|time)$/) continue
        sub(/.*\//, "", t[i]); return t[i] == "ssh"
      }
      return 0
    }
    function quotes_open(pre,   a, b) { a = gsub(q, q, pre); b = gsub(/"/, "\"", pre); return (a % 2) || (b % 2) }
    BEGIN { n = 0; cur = 0; buf = "" }
    {
      if (cur < n) {                                   # dans le corps du here-doc courant
        line = $0; if (dash[cur]) sub(/^\t+/, "", line)
        if (line == mk[cur]) {
          if (!skip[cur]) out($0); else print ""       # la ligne de fin reste une ligne (vide) : les segments suivants gardent leur place
          cur++; buf = ""; if (cur == n) { n = 0; cur = 0 }
          next
        }
        # marqueur non cité : $(…) et accents graves du corps tournent ici, avant ssh — ces lignes restent contrôlées (revue du lot 17)
        if (skip[cur] && (quoted[cur] || ($0 !~ /\$\(/ && index($0, "`") == 0))) buf = buf $0 "\n"; else out($0)
        next
      }
      out($0)
      rest = $0; pre = ""
      while (match(rest, /<<-?[ \t]*/)) {
        pre = pre substr(rest, 1, RSTART - 1); op = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
        if (substr(rest, 1, 1) == "<" || substr(pre, length(pre), 1) == "<") { pre = pre op; continue }   # <<< here-string
        if (quotes_open(pre)) { pre = pre op; continue }                                              # opérateur cité : texte
        word = rest; sub(/[ \t;&|<>)].*/, "", word)
        if (word == "") { pre = pre op; continue }
        pre = pre op word; rest = substr(rest, length(word) + 1)
        cited = (index(word, q) || index(word, "\"") || index(word, "\\")); gsub(q, "", word); gsub(/"/, "", word); gsub(/\\/, "", word)
        if (word !~ /^[A-Za-z0-9_.-]+$/) continue      # marqueur illisible : rien retiré
        owner = substr(pre, 1, length(pre) - length(op) - length(word))
        mk[n] = word; dash[n] = (op ~ /^<<-/); quoted[n] = cited; skip[n] = owner_is_ssh(owner) || (data == 1 && !owner_is_shell(owner)); n++
      }
    }
    END {                                              # jamais refermé : le corps est contrôlé
      if (cur < n && skip[cur]) { if (!cut) printf "%s", buf; else { k = split(buf, bl, "\n"); for (i = 1; i < k; i++) out(bl[i]) } }
    }
  '
}
branch_set() { BRANCH="$(exec git -C "$1" branch --show-current 2>/dev/null)" || BRANCH=''; }   # <dossier> : BRANCH, sa branche courante ou vide
# shellcheck disable=SC2088
resolve_target_set() { # <arg> : RESOLVED, chemin absolu normalisé, ou vide si non résoluble (variable, glob, quote)
  local abs="$1"
  RESOLVED=''
  case "$abs" in *'$'*|*'*'*|*'?'*|*"$QUOTED"*) return 0 ;; esac
  case "$abs" in '~'|'~/'*) abs="$HOME${abs#'~'}" ;; /*) ;; *) [ "${HOOK_CWD_UNKNOWN:-0}" = 1 ] && return 0; abs="$HOOK_CWD/$abs" ;; esac
  lexical_set "$abs"; abs="$LEXICAL"
  if [ -d "$abs" ]; then real_path_set "$abs"; RESOLVED="$REAL_PATH"; return 0; fi
  RESOLVED="${abs%/*}"; real_path_set "${RESOLVED:-/}"; RESOLVED="$REAL_PATH/${abs##*/}"
}
# lab_data_repo <dossier> : le dépôt git de ce dossier héberge LAB_HOME ou LAB_PROJECTS (registre, fiches), même s'il est enregistré
# comme projet. Seule la règle « commit sur branche protégée » l'ignore ; push --force, reset --hard, clean et checkout larges y restent.
# Jamais le checkout du code lui-même : en mode dev, LAB_HOME vaut LAB_ROOT, et un commit sur main y reste un commit dans un projet (revue, lot 03).
# Un dépôt n'héberge LAB_HOME ou LAB_PROJECTS que si sa racine est l'un de leurs dossiers parents : sans cela, aucun git n'est lancé.
lab_data_repo() {
  local root d r
  git_places "$1" || return 1
  root="$GP_TOP"
  for d in "$LAB_HOME" "$LAB_PROJECTS"; do
    if [ ! -d "$d" ] || ! dir_above "$root" "$d"; then continue; fi
    r="$(repo_root "$d" 2>/dev/null || true)"
    if [ -z "$r" ] || ! same_path "$r" "$root"; then continue; fi
    if same_path "$root" "$(repo_root "$LAB_ROOT" 2>/dev/null || printf '%s' "$LAB_ROOT")"; then return 1; fi
    return 0
  done
  return 1
}
# dir_above <dossier> <sous-dossier> : rc 0 si le premier est le second, ou l'un de ses parents réels ; sans processus
dir_above() {
  local here="$PWD" x
  cd -P "$2" >/dev/null 2>&1 || return 1
  x="$PWD"; cd "$here" >/dev/null 2>&1 || true
  while [ -n "$x" ]; do [ ! "$x" -ef "$1" ] || return 0; x="${x%/*}"; done
  [ / -ef "$1" ]
}
path_allowed_for_rm() { # <chemin absolu> : sous le worktree courant (pas lui-même), jamais le checkout principal ni un autre worktree ; temporaires ok
  local p="$1" wt="" main="" tmp
  if git_places "$HOOK_CWD"; then real_path_set "$GP_TOP"; wt="$REAL_PATH"; real_path_set "$GP_MAIN"; main="$REAL_PATH"; fi
  case "$p" in /|"$HOME"|"$HOME/") return 1 ;; esac
  if [ -n "$wt" ]; then
    case "$p" in "$wt") return 1 ;; "$wt"/*) return 0 ;; esac
    case "$wt" in "$p"/*) return 1 ;; esac            # ancêtre du worktree
  fi
  if [ -n "$main" ]; then case "$p" in "$main"|"$main"/*) return 1 ;; esac; fi   # checkout principal ou autre worktree
  for tmp in "${TMPDIR:-/nonexistent}" /tmp /private/tmp /var/folders /private/var/folders; do
    tmp="${tmp%/}"; case "$p" in "$tmp"/*) return 0 ;; esac
  done
  return 1
}
# ---------- garde git (lot 03 de mise-en-ligne : fusions sans perte) ----------
# Deux catégories de refus : DENY_KIND=perte (le travail d'un autre côté disparaît sans trace : push forcé vers une branche protégée,
# -X ours|theirs, checkout|restore --ours|--theirs) n'est jamais levé ; tout autre refus cède à LAB_FORCE=1, préfixe du seul segment
# (LAB_FORCE=1 git …) ou variable d'environnement de la session. « LAB_FORCE=1 true; git reset --hard » reste refusé.
seg_forced() { # <segment> → 0 si LAB_FORCE=1 vaut pour ce segment
  local -a t=(); local i=0
  [ "${LAB_FORCE:-0}" = 1 ] && return 0
  words_split "${1//[()]/ }"; t=("${WORDS[@]+"${WORDS[@]}"}")
  while [ "$i" -lt "${#t[@]}" ]; do
    case "${t[$i]}" in LAB_FORCE=1) return 0 ;; *=*|sudo|env|nohup|command|exec|time) i=$((i+1)) ;; *) return 1 ;; esac
  done
  return 1
}
deny_perte() { DENY_REASON="${1:-$DENY_REASON} LAB_FORCE does not lift it: ask the user to do it themselves if they really want it."; DENY_KIND=perte; }
base_ref() { # <ref> → 0 si c'est HEAD (ou un ancêtre de HEAD) ou une branche protégée, locale ou distante : la base du projet
  local r="$1"
  case "$r" in HEAD|@|HEAD~*|HEAD^*|@~*|@^*) return 0 ;; esac
  r="${r#refs/heads/}"; r="${r#refs/remotes/}"; r="${r#origin/}"; r="${r#upstream/}"
  is_protected "$r"
}
stash_message() { # <action> → DENY_REASON d'un stash refusé
  DENY_REASON="git stash $1 refused: the stash stack is shared by every session and every worktree, $1 without a SHA can take or erase another session's work. Alternative: a WIP commit; or git stash push -m <label>, then git stash apply <sha> read from git stash list --format='%H %gs'."
}
# ---------- index partagé (lot-01 de sans-perte) ----------
# Le dépôt des fiches et le checkout principal d'un projet n'ont qu'un index pour toutes les sessions : un commit sans chemins
# (ou -a, ou --amend sans chemins) emporte aussi ce qu'une autre session y a indexé, un git add large y indexe son travail.
# shared_index <dossier> : SHARED_INDEX, dépôt des fiches ou checkout principal (projet enregistré, hors couloir) ; rc 1 sinon.
shared_index() {
  SHARED_INDEX=''
  if lab_data_repo "$1"; then SHARED_INDEX='batch-file repository'; return 0; fi
  project_from_cwd_set "$1" 2>/dev/null || return 1
  is_worktree "$1" 2>/dev/null && return 1
  SHARED_INDEX='main checkout'
}
# commit_paths_ok <arguments de git commit…> → 0 si le commit nomme ses chemins (après --, positionnels, --pathspec-from-file), sans -a
# ni -i (tout l'index en plus des chemins), ni chemin qui vaut tout l'arbre (., .., *, :/). Options à valeur (-m, -F, -c, -C, -t,
# --author…) : la valeur n'est pas un chemin ; groupe court (-am x) : lettre par lettre ; redirections (2>&1, << EOF, &>f, > f)
# ignorées avec leur cible. Limite : une valeur entre guillemets ('*', "$PWD") est illisible ici et compte comme un chemin.
commit_paths_ok() {
  local arg skip=0 dd=0 paths=0 all=0 k c
  for arg in "$@"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    if index_redirect "$arg"; then [ "$INDEX_REDIRECT" = nu ] && skip=1; continue; fi
    if index_broad "$arg"; then all=1; continue; fi   # tout l'arbre : un -a déguisé
    if [ "$dd" = 1 ]; then paths=1; continue; fi
    case "$arg" in
      --) dd=1 ;;
      -a|--all|-i|--include) all=1 ;;
      --pathspec-from-file|--pathspec-from-file=*) paths=1; [ "$arg" = --pathspec-from-file ] && skip=1 ;;
      -m|-F|-c|-C|-t|--message|--file|--reuse-message|--reedit-message|--template|--author|--date|--cleanup|--fixup|--squash|--trailer) skip=1 ;;
      --*) ;;
      -?*)
        k=1; while [ "$k" -lt "${#arg}" ]; do
          c="${arg:$k:1}"; k=$((k+1))
          case "$c" in a|i) all=1 ;; m|F|c|C|t) [ "$k" -lt "${#arg}" ] || skip=1; break ;; u|S) break ;; esac
        done ;;
      *) paths=1 ;;
    esac
  done
  [ "$all" = 0 ] && [ "$paths" = 1 ]
}
# commit_joined_ok <segment> → 0 si ce git commit continue sur les lignes suivantes (chaîne entre guillemets ouverte, message sur
# plusieurs lignes) et que, recollé, il nomme ses chemins. Candidat : un fragment recollé (marqué \002 dans HOOK_JOINED) qui
# commence comme le segment et porte la chaîne recollée ; un seul candidat, sinon refus. Ne lève que le refus du commit sans chemins.
commit_joined_ok() {
  local seg="$1" pre line k found="" n=0; local -a t=()
  case "$seg" in *\'*|*'"'*) ;; *) return 1 ;; esac
  pre="${seg%%[\'\"]*}"; pre="${pre#"${pre%%[! ]*}"}"; [ -n "$pre" ] || return 1
  # recollage fait ici, pour ce seul refus : il coûtait une dizaine de processus à chaque commande contrôlée
  HOOK_JOINED="$(heredoc_strip "$HF_CMD" | quote_join | sed -E "s/'[^']*'/$QUOTED/g; s/\"[^\"]*\"/$QUOTED/g" | awk '{ m = sub(/^\002/, ""); gsub(/&&|\|\||;|\|/, m ? "\n\002" : "\n"); print (m ? "\002" : "") $0 }')"
  while IFS= read -r line; do
    case "$line" in $'\002'*) line="${line#?}" ;; *) continue ;; esac
    line="${line#"${line%%[! ]*}"}"
    case "$line" in "$pre"*"$QUOTED"*) n=$((n+1)); found="$line" ;; esac
  done <<<"${HOOK_JOINED:-}"
  [ "$n" = 1 ] || return 1
  read -r -a t <<<"$found"; k=0
  while [ "$k" -lt "${#t[@]}" ] && [ "${t[$k]}" != commit ]; do k=$((k+1)); done
  [ "$k" -lt "${#t[@]}" ] && commit_paths_ok "${t[@]:$((k+1))}"
}
# index_broad <mot> → 0 si ce chemin vaut tout l'arbre (ou tout un dossier parent) : ., ./, .., ../, *, :/, :/*
index_broad() { case "$1" in .|./|..|../|'*'|:/|':/*') return 0 ;; esac; return 1; }
# index_redirect <mot> → 0 si c'est une redirection ; INDEX_REDIRECT=nu quand sa cible est le mot suivant (> f, << EOF, &> f)
index_redirect() {
  INDEX_REDIRECT=""
  case "$1" in
    '<'|'<<'|'<<-'|'<<<'|'>'|'>>'|'>|'|'&>'|'&>>'|[0-9]'>'|[0-9]'>>'|[0-9]'<') INDEX_REDIRECT=nu; return 0 ;;
    '<'*|'>'*|'&>'*|[0-9]'>'*|[0-9]'<'*) return 0 ;;
  esac
  return 1
}
# add_broad <arguments de git add…> → 0 si l'ajout vise tout l'arbre : ., .., *, :/, ou -A/-u sans chemin nommé.
add_broad() {
  local arg flag=0 paths=0 skip=0
  for arg in "$@"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    if index_redirect "$arg"; then [ "$INDEX_REDIRECT" = nu ] && skip=1; continue; fi
    index_broad "$arg" && return 0
    case "$arg" in
      -A|--all|-u|--update) flag=1 ;; --) ;; --*) ;;
      -?*) case "$arg" in *A*|*u*) flag=1 ;; esac ;;
      *) paths=1 ;;
    esac
  done
  [ "$flag" = 1 ] && [ "$paths" = 0 ]
}
guard_segment() { # → 0 si ok ; sinon écrit DENY_REASON (et DENY_KIND=perte si non forçable) et retourne 1
  DENY_REASON=""; DENY_KIND=""
  guard_rules "$1" && return 0
  [ "$DENY_KIND" != perte ] && seg_forced "$1" && return 0
  return 1
}
guard_rules() {
  local -a t=(); local seg="$1" i n cmd sub j arg
  words_split "$seg"; t=("${WORDS[@]+"${WORDS[@]}"}"); n=${#t[@]}; [ "$n" -gt 0 ] || return 0
  i=0; while [ "$i" -lt "$n" ]; do
    case "${t[$i]}" in *=*) i=$((i+1)) ;; sudo|env|nohup|command|exec|time) i=$((i+1)) ;; *) break ;; esac
  done
  [ "$i" -lt "$n" ] || return 0
  base_set "${t[$i]}"; cmd="$BASE"
  case "$cmd" in
    git)
      j=$((i+1)); sub=""; local gitcwd="$HOOK_CWD" gitcwd_unknown="${HOOK_CWD_UNKNOWN:-0}" d
      while [ "$j" -lt "$n" ]; do
        case "${t[$j]}" in
          -C) resolve_target_set "${t[$((j+1))]:-}"; d="$RESOLVED"; if [ -n "$d" ] && [ -d "$d" ]; then gitcwd="$d"; gitcwd_unknown=0; else gitcwd_unknown=1; fi; j=$((j+2)) ;;
          -c|--git-dir|--work-tree) j=$((j+2)) ;; -*) j=$((j+1)) ;; *) sub="${t[$j]}"; j=$((j+1)); break ;; esac
      done
      local -a a=(); [ "$j" -lt "$n" ] && a=("${t[@]:$j}")
      case "$sub" in
        push)
          local force=0 remote="" ref="" dest all=0 del=0; local -a refs=()
          for arg in "${a[@]+"${a[@]}"}"; do
            case "$arg" in -f|--force|--force-with-lease*|--force-if-includes) force=1 ;; -[!-]*f*) force=1 ;; --all) all=1 ;;
              --mirror) all=1; force=1 ;; -d|--delete) del=1 ;; --*) ;; -*) ;;   # --mirror force toutes les références (revue de sécurité)
              *) if [ -z "$remote" ]; then remote="$arg"; else refs+=("$arg"); fi ;; esac
          done
          # supprimer une branche protégée (--delete main, :main) efface tout ce qu'elle porte
          for ref in "${refs[@]+"${refs[@]}"}"; do
            case "$del:$ref" in 1:*|0::*) dest="${ref#:}"; dest="${dest#refs/heads/}"
              if is_protected "$dest"; then deny_perte "deleting the remote branch \"$dest\" refused: it erases all the merged work. Alternative: delete only a batch branch."; return 1; fi ;; esac
          done
          [ "$del" = 0 ] || return 0
          if [ "${#refs[@]}" = 0 ]; then
            [ "$force" = 1 ] || return 0
            if [ "$all" = 1 ] || [ "$gitcwd_unknown" = 1 ]; then ref="main"; else branch_set "$gitcwd"; ref="$BRANCH"; fi
            refs=("$ref")
          fi
          for ref in "${refs[@]}"; do
            case "$ref" in +*) ;; *) [ "$force" = 1 ] || continue ;; esac
            dest="${ref#+}"; dest="${dest##*:}"; dest="${dest#refs/heads/}"
            [ -n "$dest" ] || { branch_set "$gitcwd"; dest="$BRANCH"; }
            if is_protected "$dest"; then DENY_REASON="git push --force (or refspec \"+…\", --mirror) to \"$dest\" refused: it rewrites the shared history and erases the commits merged by the other lanes. Alternative: push a batch branch (git push -u origin <branch>) and open a PR."; deny_perte; return 1; fi
          done ;;
        merge|rebase|cherry-pick|pull|revert)
          local prev="" side=""
          for arg in "${a[@]+"${a[@]}"}"; do
            case "$prev:$arg" in
              -X:ours|-X:theirs|--strategy-option:ours|--strategy-option:theirs|-s:ours|--strategy:ours) side="$prev $arg" ;;
              *:-Xours|*:-Xtheirs|*:-sours) side="$arg" ;;
              *:--strategy-option=ours|*:--strategy-option=theirs|*:--strategy=ours) side="$arg" ;;
            esac
            prev="$arg"
          done
          if [ -n "$side" ]; then deny_perte "git $sub $side refused: each conflict is silently settled for one side and the lines added on the other side (often by another lane) disappear. Alternative: git $sub without this option, then resolve file by file (git diff, edit, git add)."; return 1; fi ;;
        reset)
          for arg in "${a[@]+"${a[@]}"}"; do [ "$arg" = --hard ] && { DENY_REASON="git reset --hard refused: it erases uncommitted work (yours or another session's). Alternative: a WIP commit, or a targeted git restore <file>."; return 1; }; done ;;
        clean)
          local f=0 dry=0
          for arg in "${a[@]+"${a[@]}"}"; do case "$arg" in -n|--dry-run) dry=1 ;; --force) f=1 ;; -[!-]*) case "$arg" in *f*) f=1 ;; *n*) dry=1 ;; esac ;; esac; done
          [ "$f" = 1 ] && [ "$dry" = 0 ] && { DENY_REASON="git clean -f refused: it deletes untracked files (often .env, notes, work in progress). Alternative: git clean -n to list them, then a targeted rm or trash."; return 1; } ;;
        checkout|restore)
          local dd=0 path=0 broad=0 side="" src="" want=0 pos=0 newb=0
          for arg in "${a[@]+"${a[@]}"}"; do
            if [ "$want" = 1 ]; then src="$arg"; want=0; continue; fi
            if [ "$want" = 2 ]; then want=0; continue; fi   # nom de la nouvelle branche
            case "$arg" in
              -b|-B|--orphan) [ "$sub$dd$src" = checkout0 ] && { newb=1; want=2; } ;; -b?*|-B?*|--orphan=*) [ "$sub$dd$src" = checkout0 ] && newb=1 ;;
              --ours|--theirs) side="$arg" ;;
              --source=*) src="${arg#--source=}" ;; --source|-s) [ "$sub" = restore ] && want=1 ;; -s?*) [ "$sub" = restore ] && src="${arg#-s}" ;;
              --) dd=1 ;; .|./|:/|'*') broad=1 ;; -*) ;;
              *) if [ "$dd" = 1 ] || [ "$sub" = restore ]; then path=1; elif [ -z "$src" ]; then src="$arg"; else path=1; pos=1; fi ;;
            esac
          done
          if [ -n "$side" ]; then deny_perte "git $sub $side refused: the conflicted file takes a single version and the lines from the other side (often another lane) disappear. Alternative: open the file, keep both contributions, then git add."; return 1; fi
          if [ "$broad" = 1 ] || { [ "$dd" = 1 ] && [ "$path" = 0 ]; }; then DENY_REASON="git $sub on the whole tree refused: it overwrites uncommitted changes. Alternative: a targeted git $sub -- <file>."; return 1; fi
          # checkout <ref> [--] f et restore --source <ref> : la version d'une autre branche ; checkout <ref> seul change de branche ;
          # checkout -b|-B|--orphan <branche> [<base>] crée une branche et ne copie aucun fichier (git refuse -b avec des chemins)
          if [ "$newb" = 0 ] && { [ "$sub" = restore ] || [ "$dd" = 1 ] || [ "$pos" = 1 ]; } && [ -n "$src" ] && ! base_ref "$src"; then
            DENY_REASON="git $sub from \"$src\" refused: the file takes the version of another branch and erases what was added since on the base or in this lane. Alternative: git diff $src -- <file>, then take only the lines you want; from HEAD or the base (origin/main), the restore goes through."; return 1
          fi ;;
        stash)
          local act="${a[0]:-push}" sha=""
          case "$act" in
            pop|drop|clear|branch) stash_message "$act"; return 1 ;;   # branch applique puis retire l'entrée la plus récente
            apply)
              for arg in "${a[@]:1}"; do case "$arg" in -*) ;; *) sha="$arg" ;; esac; done
              if ! [[ $sha =~ ^[0123456789abcdef]{7,40}$ ]]; then stash_message "apply${sha:+ $sha}"; return 1; fi ;;
          esac ;;
        commit)
          local br where; [ "$gitcwd_unknown" = 1 ] && return 0   # dossier inconnu (cd ou -C non résoluble) : on ne peut pas juger
          shared_index "$gitcwd" || return 0   # couloir ou dépôt non enregistré : libre
          where="$SHARED_INDEX"
          # registre et fiches (LAB_HOME, LAB_PROJECTS) se committent sur main : 277 fichiers jamais enregistrés (constat 3, lot 03)
          branch_set "$gitcwd"; br="$BRANCH"
          if [ "$where" = 'main checkout' ] && is_protected "$br"; then DENY_REASON="commit on \"$br\" from the main checkout refused. Alternative: lab new <slug> (worktree + branch + PR)."; return 1; fi
          if ! commit_paths_ok "${a[@]+"${a[@]}"}" && ! commit_joined_ok "$seg"; then DENY_REASON="git commit without paths (or -a, --amend without paths) refused in the $where: its index is shared by every session, this commit would also take what another one staged there. Alternative: git commit -- <files> (with -m <message>), which records only those files."; return 1; fi ;;
        add)
          local where; [ "$gitcwd_unknown" = 1 ] && return 0
          shared_index "$gitcwd" || return 0
          where="$SHARED_INDEX"
          [ "$where" = 'main checkout' ] || return 0   # dépôt des fiches : seul le commit nomme ses chemins (périmètre du lot)
          if add_broad "${a[@]+"${a[@]}"}"; then DENY_REASON="git add on the whole tree (-A, -u, ., *, :/) refused in the $where: its index is shared by every session, it would mix your work with theirs. Alternative: git add <named files>."; return 1; fi ;;
      esac ;;
    rm)
      local rec=0 force=0 tgt
      for arg in "${t[@]:$((i+1))}"; do case "$arg" in --recursive) rec=1 ;; --force) force=1 ;; --) ;; -[!-]*) case "$arg" in *[rR]*) rec=1 ;; esac; case "$arg" in *f*) force=1 ;; esac ;; esac; done
      [ "$rec" = 1 ] && [ "$force" = 1 ] || return 0
      for arg in "${t[@]:$((i+1))}"; do
        case "$arg" in -*) continue ;; esac
        resolve_target_set "$arg"; tgt="$RESOLVED"
        if [ -z "$tgt" ] || ! path_allowed_for_rm "$tgt"; then DENY_REASON="rm -rf \"$arg\" refused: outside the current worktree (or target not resolvable). Alternative: trash <path>, or an explicit path under the worktree."; return 1; fi
      done ;;
  esac
  return 0
}
# ---------- garde des droits de la tour (lot 06 d'autonomie-tours) ----------
# guard_tower_segment <segment> : dans un projet doté d'une tour, un agent qui n'est pas la session de la tour ne fusionne pas une PR
# (gh pr merge) et ne pousse pas vers une branche protégée ; la branche du lot se pousse librement. Sans agent parmi les ancêtres
# (l'utilisateur) ou projet sans tour : rien. Jamais levé par LAB_FORCE : le geste passe par lab merge, la tour le fait.
# → 0 si ok ; sinon DENY_REASON, rc 1
guard_tower_segment() {
  local -a t=(); local i=0 n cmd j sub what="" arg dest ref all=0 remote="" gitcwd="$HOOK_CWD" d p root tw pid lane r where
  local -a refs=()
  words_split "$1"; t=("${WORDS[@]+"${WORDS[@]}"}"); n=${#t[@]}
  while [ "$i" -lt "$n" ]; do case "${t[$i]}" in LAB_AGENT_SCAN=*) what=scan; break ;; *=*|sudo|env|nohup|command|exec|time) i=$((i+1)) ;; *) break ;; esac; done
  if [ -z "$what" ]; then
    [ "$i" -lt "$n" ] || return 0
    base_set "${t[$i]}"; cmd="$BASE"
    case "$cmd" in
      gh)   # options de gh (-R <dépôt>, --repo=…) sautées ; gh api vers …/pulls/<n>/merge vaut gh pr merge (revue)
        local -a w=(); j=$((i+1))
        while [ "$j" -lt "$n" ]; do
          case "${t[$j]}" in -R|--repo) j=$((j+2)) ;; -*) j=$((j+1)) ;; *) w+=("${t[$j]}"); j=$((j+1)) ;; esac
        done
        case "${w[0]:-} ${w[1]:-}" in 'pr merge') what=merge ;; esac
        if [ "${w[0]:-}" = api ]; then case " ${w[*]} " in *'/pulls/'*'/merge '*) what=merge ;; esac; fi ;;
      export|unset) case " ${t[*]:$((i+1))} " in *" LAB_AGENT_SCAN"[=\ ]*) what=scan ;; esac ;;
      git)
        j=$((i+1)); sub=""
        while [ "$j" -lt "$n" ]; do
          case "${t[$j]}" in
            -C) resolve_target_set "${t[$((j+1))]:-}"; d="$RESOLVED"; [ -z "$d" ] || [ ! -d "$d" ] || gitcwd="$d"; j=$((j+2)) ;;
            -c|--git-dir|--work-tree) j=$((j+2)) ;; -*) j=$((j+1)) ;; *) sub="${t[$j]}"; j=$((j+1)); break ;; esac
        done
        [ "$sub" = push ] || return 0
        for arg in "${t[@]:$j}"; do
          case "$arg" in --all|--mirror) all=1 ;; -*) ;; *) if [ -z "$remote" ]; then remote="$arg"; else refs+=("$arg"); fi ;; esac
        done
        [ "${#refs[@]}" -gt 0 ] || { branch_set "$gitcwd"; refs=("$BRANCH"); }
        [ "$all" = 0 ] || refs+=(main)
        for ref in "${refs[@]}"; do
          dest="${ref#+}"; dest="${dest##*:}"; dest="${dest#refs/heads/}"
          case "$dest" in ''|HEAD) branch_set "$gitcwd"; dest="$BRANCH" ;; esac
          if is_protected "$dest"; then what="push $dest"; break; fi
        done ;;
    esac
  fi
  [ -n "$what" ] || return 0
  project_from_cwd_set "$gitcwd" 2>/dev/null && [ -n "$FOUND_PROJECT" ] || return 0
  p="$FOUND_PROJECT"; kv_value "$LAB_PROJECTS/$p/config" root || true
  root="$KV_VALUE"; tw="$root/.worktrees/$TOWER_LANE"
  [ -n "$root" ] && [ -d "$tw" ] && P_NAME="$p" lane_is_tower "$tw" || return 0
  [ "${LAB_AGENT_SCAN:-1}" != 0 ] || [ "$what" = scan ] || return 0
  pid="$(agent_pid_found)" || return 0   # aucun agent : l'utilisateur garde la main
  [ "$(lock_field "$(lock_file "$tw")" pid 2>/dev/null || true)" != "$pid" ] || return 0
  r="$(repo_root "$gitcwd" 2>/dev/null || true)"
  if [ -n "$r" ] && ! same_path "$r" "$root"; then lane="$(wt_lane "$r")"; where="lane $lane"; else lane="<lane>"; where="the main checkout"; fi
  case "$what" in
    merge) DENY_REASON="merging a pull request from $where refused: in $p only the tower merges, at its round, once the CI is green. Alternative: lab merge $p $lane queues it for the tower; nothing to ask the user." ;;
    scan) DENY_REASON="LAB_AGENT_SCAN is reserved to the test suite of lab: in $p the tower rights apply to every agent. Alternative: lab merge, lab deploy and lab close say what goes through the tower." ;;
    *) DENY_REASON="pushing to ${what#push } from $where refused: in $p only the tower delivers to ${what#push }. Alternative: push the batch branch, then lab merge $p $lane queues it for the tower; nothing to ask the user." ;;
  esac
  return 1
}
# ---------- garde des déploiements bruts (lot 02 de mise-en-ligne) ----------
# Un projet qui déclare une cible (deploy.<cible>= de sa config) ne se met en ligne que par lab deploy : une commande de déploiement
# connue, ou le début d'une commande deploy.<cible> déclarée, est refusée ; un projet sans cible n'est jamais gêné.
# Mots, signatures et commandes connues : lib/guard_fast.sh (deploy_*), communs au pré-filtre.
guard_deploy_segment() { # <segment> → 0 si ok ; sinon écrit DENY_REASON et retourne 1
  local words plain p t s hit="" known=0 targets
  deploy_words_set "$1"; words="$DEPLOY_WORDS"; [ -n "$words" ] || return 0; deploy_plain_set "$words"; plain="$DEPLOY_PLAIN"
  # répétition sans envoi : seul wrangler (deploy, publish) est connu pour honorer --dry-run ; un script maison l'ignorerait (revue)
  case " $plain " in *" wrangler deploy "*|*" wrangler publish "*) case " $words " in *" --dry-run "*) return 0 ;; esac ;; esac
  base_set "${words%% *}"; [ "$BASE" != lab ] || return 0
  deploy_builtin "$words" && known=1
  if [ "$known" = 0 ]; then
    [ -n "${DEPLOY_SIGS:-}" ] || return 0
    while IFS=$'\t' read -r p t s; do [ -n "$s" ] || continue; case "$plain " in "$s "*) known=1; break ;; esac; done <<<"$DEPLOY_SIGS"
    [ "$known" = 1 ] || return 0
  fi
  project_from_cwd_set "$HOOK_CWD" 2>/dev/null && [ -n "$FOUND_PROJECT" ] || return 0
  p="$FOUND_PROJECT"
  targets="$(awk -F= '/^deploy\./ { t = $1; sub(/^deploy\./, "", t); printf "%s%s", (n++ ? " " : ""), t }' "$(project_dir "$p")/config" 2>/dev/null)"
  [ -n "$targets" ] || return 0   # garde active seulement pour un projet qui déclare une cible
  hit="$(awk -F'\t' -v p="$p" -v w="$plain " '$1 == p && $3 != "" && index(w, $3 " ") == 1 { print $2; exit }' <<<"${DEPLOY_SIGS:-}")"
  if [ -z "$hit" ]; then deploy_builtin "$words" || return 0; fi
  [ -n "$hit" ] || case "$targets" in *" "*) hit="<target>" ;; *) hit="$targets" ;; esac
  [ "${#words}" -le 60 ] || words="${words:0:59}…"
  DENY_REASON="raw deployment refused: \"$words\" goes live without the register and can erase a served lane that is not merged. Alternative: lab deploy $hit (targets declared for $p: $targets); lab deploy $hit --dry-run first shows what would be lost."
  return 1
}
flag_last() { # <mots> <--option> → 1 si l'option booléenne vaut vrai à sa dernière occurrence, 0 si fausse, rien si absente
  local w v=''; local -a t=()
  read -r -a t <<<"$1"
  for w in "${t[@]+"${t[@]}"}"; do
    case "$w" in
      "$2") v=1 ;;
      "$2"=*) case "$(printf '%s' "${w#*=}" | tr '[:upper:]' '[:lower:]')" in false|0|no|f|n) v=0 ;; *) v=1 ;; esac ;;
    esac
  done
  printf '%s' "$v"
}
# guard_migrations_segment <segment> (lot 02 de sans-perte) : appliquer des migrations à la base distante depuis un couloir les met en
# production avant leur fusion — wrangler d1 migrations apply --remote, supabase db push (sauf --local). Garde active seulement dans
# un projet qui déclare migrations= ; la branche de base passe. → 0 si ok ; sinon DENY_REASON, rc 1 (LAB_FORCE=1 le lève).
guard_migrations_segment() {
  local words plain p root br base
  deploy_words_set "$1"; words="$DEPLOY_WORDS"; [ -n "$words" ] || return 0; deploy_plain_set "$words"; plain="$DEPLOY_PLAIN"
  # les mots de la sous-commande sont cherchés dans l'ordre, pas côte à côte (wrangler d1 --config x migrations apply) ; l'option est
  # lue comme la CLI : la dernière occurrence l'emporte, seules les valeurs fausses explicites (false, 0, no, f) l'éteignent. En cas de
  # doute, distant : un argument entre guillemets ou une expansion ($VAR, $(…)) illisibles ici, ou --db-url, --linked chez supabase (revue de sécurité)
  case " $plain " in
    *" wrangler"*" d1"*" migrations"*" apply "*)
      case "$words" in *"$QUOTED"*|*'$'*|*'`'*) ;; *) [ "$(flag_last "$words" --remote)" = 1 ] || return 0 ;; esac ;;
    *" supabase"*" db"*" push "*)
      case "$words" in *"$QUOTED"*|*'$'*|*'`'*|*--db-url*|*--linked*) ;; *) [ "$(flag_last "$words" --local)" != 1 ] || return 0 ;; esac ;;
    *) return 0 ;;
  esac
  p="$(project_from_cwd "$HOOK_CWD" 2>/dev/null)" && [ -n "$p" ] || return 0
  [ -n "$(config_get "$p" migrations 2>/dev/null)" ] || return 0
  root="$(repo_root "$HOOK_CWD" 2>/dev/null)" || return 0
  br="$(branch_name "$root" 2>/dev/null)"; base="$(config_get "$p" base 2>/dev/null)"; base="${base:-main}"
  [ "$br" != "$base" ] || return 0
  [ "${#words}" -le 60 ] || words="${words:0:59}…"
  DENY_REASON="remote migration refused from \"${br:-detached HEAD}\": \"$words\" applies migrations that are not merged yet to production. Alternative: --local to try; production after the merge, from $base."
  return 1
}
track_cd() { # <segment> → met à jour HOOK_CWD si c'est un cd ; retourne 0 si c'était un cd
  local target
  words_split "$1"; [ "${WORDS[0]:-}" = cd ] || return 1
  target="${WORDS[1]:-}"
  case "$target" in ""|-) HOOK_CWD_UNKNOWN=1; return 0 ;; esac
  resolve_target_set "$target"; target="$RESOLVED"
  if [ -n "$target" ] && [ -d "$target" ]; then HOOK_CWD="$target"; HOOK_CWD_UNKNOWN=0; else HOOK_CWD_UNKNOWN=1; fi
  return 0
}
hook_guard_bash() {
  guard_read
  hook_guard_bash_payload
}
hook_guard_bash_payload() {
  HOOK_CWD_UNKNOWN=0
  local cmd="$HF_CMD" seg; [ -n "$cmd" ] || exit 0
  # pré-filtre (lib/guard_fast.sh) : git, rm, une migration distante, ou une commande qui ressemble à un déploiement (connue, ou début
  # d'une deploy.<cible> déclarée) ; pose DEPLOY_SIGS
  ! guard_bash_ordinary "$cmd" || exit 0
  local cwd0="$HOOK_CWD"
  segments_set "$cmd"
  while IFS= read -r seg; do
    # aucun des mots que cd, guard_rules et guard_tower_segment cherchent : rien à juger (une commande longue a des centaines de segments)
    case "$seg" in *cd*|*git*|*rm*|*gh*|*export*|*unset*|*LAB_AGENT_SCAN*) ;; *) continue ;; esac
    track_cd "$seg" && continue
    if ! guard_segment "$seg"; then
      if [ "$DENY_KIND" = perte ]; then json_deny "LAB: $DENY_REASON"; else json_deny "LAB: $DENY_REASON If the user explicitly asked for it, run it again with LAB_FORCE=1 before the command."; fi
      exit 0
    fi
    if ! guard_tower_segment "$seg"; then json_deny "LAB: $DENY_REASON"; exit 0; fi   # lot 06 d'autonomie-tours, jamais forcé
  done <<<"$SEGMENTS"
  # jugés sur la commande brute, même entre guillemets (bash -c "…", URL citée) : LAB_AGENT_SCAN écrit n'importe où, fusion d'une PR
  # par gh api (REST …/pulls/<n>/merge, GraphQL mergePullRequest) — revue de sécurité
  HOOK_CWD="$cwd0"
  case "$cmd" in *LAB_AGENT_SCAN=*) guard_tower_segment "LAB_AGENT_SCAN=" || { json_deny "LAB: $DENY_REASON"; exit 0; } ;; esac
  case "$cmd" in *"gh api"*/pulls/*/merge*|*"gh api"*mergePullRequest*) guard_tower_segment "gh pr merge" || { json_deny "LAB: $DENY_REASON"; exit 0; } ;; esac
  # lot 10 : l'accord de l'utilisateur est tapé par lui seul — un envoi cmux qui le tape est refusé, jamais forcé (LAB_FORCE sans effet)
  case "$cmd" in *cmux*|*cmx*) guard_words_send "$cmd" || { json_deny "LAB: $DENY_REASON"; exit 0; } ;; esac
  # déploiements et migrations : seulement si un mot que leurs règles exigent est dans la commande (un segment n'en contient aucun autre)
  case "$cmd" in
    *deploy*|*publish*|*vercel*|*rsync*|*migrations*|*supabase*) ;;
    *) case "$DEPLOY_SIGS" in *"$QUOTED"*) ;; *) deploy_sig_hint "$cmd" || exit 0 ;; esac ;;
  esac
  # le corps d'un here-doc donné à cat, python3, git… est du texte, jamais exécuté ici (0.5.1)
  HOOK_CWD="$cwd0"; HOOK_CWD_UNKNOWN=0
  segments_set "$cmd" 1
  while IFS= read -r seg; do
    [ -n "$seg" ] || continue
    track_cd "$seg" && continue
    if { ! guard_deploy_segment "$seg" || ! guard_migrations_segment "$seg"; } && ! seg_forced "$seg"; then
      json_deny "LAB: $DENY_REASON If the user explicitly asked for it, run it again with LAB_FORCE=1 before the command."
      exit 0
    fi
  done <<<"$SEGMENTS"
  exit 0
}

# guard_words_send <commande brute> (lot 10 d'autonomie-tours) : un texte tapé dans un onglet par cmux (send, paste, send-panel,
# set-buffer) qui dit l'accord de l'utilisateur (words_match, lib/words.sh, avec les couloirs du projet) ou la formule « confirmed
# aloud » de Ginkgo est refusé : le crochet de lab lirait ces mots comme les siens. /exit, une touche, tout autre texte passent. Chaque
# chaîne entre guillemets, chaque ligne de la commande (here-doc compris), puis toutes ses chaînes recollées (morceaux coupés dans la
# même commande, revue de sécurité) sont jugées, séquences \n \r \t comprises ; un \n ou un \r tapé fait deux prompts : chaque morceau
# est aussi jugé seul (revue du lot). Hors de portée, nommé par la fiche : des morceaux
# envoyés en plusieurs appels, un script qui tape à la place de l'agent — la garde est une défense de plus, pas une preuve.
guard_words_send() {
  local cmd="$1" t lanes='' texts
  printf '%s\n' "$cmd" | LC_ALL=C grep -Eq '(^|[^[:alnum:]_.-])(cmux|cmx)([[:space:]][^|;&]*)?[[:space:]](send|paste|send-panel|set-buffer)([[:space:]]|$)' || return 0
  # un texte sans aucun des mots que les deux règles exigent (replié comme words_fold) n'est pas jugé : un envoi ordinaire coûtait six
  # processus par texte et par ligne. Un perl en échec n'en trie aucun : il faut aussi à words_match, qui ne jugerait rien non plus
  texts="$(printf '%s\n' "$cmd" | perl -MEncode -MUnicode::Normalize -e '
    my (@t, $all); $all = "";
    while (<STDIN>) {
      while (/"((?:[^"\\]|\\.)*)"|\x27([^\x27]*)\x27/g) { my $q = defined $1 ? $1 : $2; $all .= $q; push @t, "$q\n"; push @t, "$_\n" for split /\\[nr]|\r/, $q }
      push @t, $_;
    }
    push @t, "$all\n"; push @t, "$_\n" for split /\\[nr]|\r/, $all;
    for (@t) {
      s/\\[nrt]/ /g; my $f = NFD(decode("UTF-8", $_)); $f =~ s/\p{Mn}//g; $f =~ s/\p{Cf}//g; $f =~ s/\p{Zs}/ /g;
      print if lc($f) =~ /ferm|clo|recette|accept|approuv|approve|valide|confirm|voix haute/;
    }' 2>/dev/null)" || return 0
  [ -n "$texts" ] || return 0
  lanes="$( { p="$(project_from_cwd "$HOOK_CWD")" && [ -n "$p" ] && load_project "$p" && words_lanes; } 2>/dev/null | tr '\n' ' ')"
  while IFS= read -r t; do
    [ -n "${t// /}" ] || continue
    # shellcheck disable=SC2086 # noms de couloir : des mots (valid_slug)
    if WORDS_BARE=1 words_match "$t" $lanes >/dev/null || printf '%s' "$t" | words_fold | LC_ALL=C grep -Eq 'confirm[a-z]*[^a-z]*(aloud|out[^a-z]*loud)|voix haute'; then
      DENY_REASON="the user's agreement is typed by them only: cmux typing \"$(printf '%s' "$t" | words_clean 80)\" refused — they write it in the tab themselves, or answer a question asked with AskUserQuestion."
      return 1
    fi
  done <<<"$texts"
  return 0
}

# ---------- PreToolUse Write / Edit / apply_patch ----------
# CANON ; le dossier de travail n'est résolu qu'une fois par crochet.
canonical_set() {
  if [ "${CANON_FOR:-}" != "$HOOK_CWD" ]; then
    lexical_set "$HOOK_CWD"; CANON_RAW="$LEXICAL"; real_path_set "$HOOK_CWD"; CANON_REAL="$REAL_PATH"; CANON_FOR="$HOOK_CWD"
  fi
  case "$1" in
    /*)
      lexical_set "$1"; CANON="$LEXICAL"
      case "$CANON" in "$CANON_RAW") CANON="$CANON_REAL" ;; "$CANON_RAW"/*) CANON="$CANON_REAL/${CANON#"$CANON_RAW"/}" ;; esac ;;
    *) lexical_set "$CANON_REAL/$1"; CANON="$LEXICAL" ;;
  esac
}
# parent_set <chemin> : PARENT = dirname du chemin, sans processus (chemin absolu)
parent_set() { PARENT="${1%/*}"; PARENT="${PARENT:-/}"; }
nearest_set() { # <chemin> : NEAREST, le dossier existant le plus proche
  NEAREST="$1"
  while [ ! -d "$NEAREST" ] && [ "$NEAREST" != / ]; do parent_set "$NEAREST"; NEAREST="$PARENT"; done
}

# Pose CT_PROJECT et CT_PATH si la cible est l'un des cinq fichiers de contexte protégés.
context_target() {
  local target p root rel d
  CT_PROJECT=""; CT_PATH=""
  # nom d'aucun fichier protégé, le cas ordinaire : aucun projet à lire (15 projets × 160 couloirs coûtaient 3 000 processus par Edit)
  ! target_off_context "$1" || return 1
  canonical_set "$1"; target="$CANON"

  # notes et mémoires sont hors dépôt : on les rattache explicitement à leur projet et à leur checkout/worktree.
  case "$target" in
    */notes.md)
      for p in $(project_names); do
        canonical_set "$LAB_PROJECTS/$p/notes.md"
        if [ "$target" = "$CANON" ]; then CT_PROJECT="$p"; CT_PATH="$target"; load_project "$p"; return 0; fi
      done ;;
    */MEMORY.md)   # par son nom seul : un dossier memory atteint par un lien change tout le reste du chemin (revue)
      for p in $(project_names); do
        kv_value "$LAB_PROJECTS/$p/config" root || true
        root="$KV_VALUE"; [ -d "$root" ] || continue
        if context_memory "$target" "$root"; then CT_PROJECT="$p"; CT_PATH="$target"; load_project "$p"; return 0; fi
      done ;;
  esac

  nearest_set "$target"
  git_places "$NEAREST" || return 1
  root="$GP_TOP"
  project_by_root_set "$GP_MAIN" || return 1
  p="$FOUND_PROJECT"
  real_path_set "$root"; root="$REAL_PATH"
  case "$target" in
    "$root/AGENTS.md"|"$root/CLAUDE.md") ;;
    "$root"/.claude/rules/*.md)
      rel="${target#"$root/.claude/rules/"}"
      case "$rel" in */*) return 1 ;; *.md) ;; *) return 1 ;; esac ;;
    *) return 1 ;;
  esac
  CT_PROJECT="$p"; CT_PATH="$target"; load_project "$p"

  # Projet non maintenu : un fichier déjà suivi reste informatif, comme dans le doctor. Les fichiers locaux restent protégés.
  if [ "$P_OWNER" = other ]; then
    rel="${target#"$root"/}"
    git -C "$root" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 && return 1
  fi
  return 0
}

# context_memory <cible> <checkout principal> : rc 0 si la cible est la mémoire Claude de ce checkout ou de l'un de ses worktrees
context_memory() {
  local line home wt
  home="$(claude_home)"; wt="$2"
  canonical_set "$home/projects/${wt//\//-}/memory/MEMORY.md"
  [ "$1" != "$CANON" ] || return 0
  while IFS= read -r line; do
    case "$line" in 'worktree '*) wt="${line#worktree }" ;; *) continue ;; esac
    [ -n "$wt" ] || continue
    canonical_set "$home/projects/${wt//\//-}/memory/MEMORY.md"
    [ "$1" != "$CANON" ] || return 0
  done <<<"$(exec git -C "$2" worktree list --porcelain 2>/dev/null)"
  return 1
}

# guard_context_content <cible> <contenu> [champ] : 0 si autorisé, 1 après avoir posé DENY_REASON ; champ : le contenu est ce champ de
# tool_input, lu dans la charge seulement pour une cible protégée
guard_context_content() {
  local target="$1" content="$2" name
  context_target "$target" || return 0
  [ -z "${3:-}" ] || content="$(payload_get ".tool_input.$3")"
  for name in $(hermetism_forbidden_names "$CT_PROJECT"); do
    if name_maybe_in "$name" "$content" && printf '%s' "$content" | project_name_in_text "$name"; then
      DENY_REASON="mention of \"$name\" refused in \"$CT_PATH\". Rephrase without naming another project, or explicitly ask for an exceptional write."
      return 1
    fi
  done
  return 0
}

# name_maybe_in <nom> <texte> : rc 0 si le texte porte le nom, casse ignorée — sur-ensemble sans processus de project_name_in_text
name_maybe_in() {
  local rc=1
  shopt -s nocasematch
  [[ "$2" != *"$1"* ]] || rc=0
  shopt -u nocasematch
  return "$rc"
}

# guard_state_target <cible> (lot 09 d'autonomie-tours) : 0 si autorisé ; 1 et DENY_REASON si la cible est sous l'état de lab
# ($LAB_STATE : accords, marque de la tour, files, registres), qui n'est écrit que par lab. Chemin réel : lien final suivi (Write et
# Edit écrivent à travers), puis chaque dossier parent comparé à l'état par -ef (liens des parents, casse d'un disque insensible) ;
# un état encore absent est comparé lexicalement.
guard_state_target() {
  local t d st
  [ -n "${LAB_STATE:-}" ] || return 0
  ! target_off_state "$1" || return 0   # le cas ordinaire, sans processus
  canonical_set "$1"; t="$CANON"; t="$(resolve_file "$t" 2>/dev/null || printf '%s\n' "$t")"
  lexical_set "$LAB_STATE"; st="$LEXICAL"
  case "$t" in "$st"|"$st"/*) ;; *)
    [ -d "$LAB_STATE" ] || return 0
    nearest_set "$t"; d="$NEAREST"
    while [ ! "$d" -ef "$LAB_STATE" ]; do [ "$d" != / ] && [ -n "$d" ] || return 0; parent_set "$d"; d="$PARENT"; done ;;
  esac
  DENY_REASON="lab's state is written by lab only: \"$1\" refused — the lab command that keeps it writes it (lab acceptance for an agreement)."
  return 1
}

guard_patch_payload() {
  local patch="$1" line target="" seen=0 move
  case "$patch" in '*** Begin Patch'$'\n'*) ;; *) return 0 ;; esac
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '*** Add File: '*|'*** Update File: '*|'*** Delete File: '*|'*** Move to: '*)
        guard_state_target "${line#'*** '*': '}" || return 1 ;;
    esac
    case "$line" in
      '*** Add File: '*) target="${line#'*** Add File: '}"; seen=1 ;;
      '*** Update File: '*) target="${line#'*** Update File: '}"; seen=1 ;;
      '*** Delete File: '*) target=""; seen=1 ;;
      '*** Move to: '*)
        move="${line#'*** Move to: '}"; seen=1
        if context_target "$move"; then
          DENY_REASON="move to the context file \"$CT_PATH\" refused: express the operation again as an add or an edit that can be checked."
          return 1
        fi
        target="$move" ;;
      '*** End Patch') ;;
      +*)
        [ "$seen" = 1 ] && [ -n "$target" ] || continue
        guard_context_content "$target" "${line#+}" || return 1 ;;
    esac
  done <<<"$patch"
  return 0
}

# hook_lock_resume <outil> (lot 01 de reprise-apres-migration) : une session démarrée sans verrou (PENDING d'une relance en masse,
# registre refusé, lab d'avant ce lot) le prend à son premier outil. Couloir : celui où l'agent a démarré (CLAUDE_PROJECT_DIR, sinon
# le dossier du JSON) — un cd vers un autre couloir n'y pose jamais de verrou. Chemin rapide sans claim : le verrou désigne déjà un
# ancêtre (session_owned_here). Sans agent parmi les ancêtres (hook lancé à la main) : rien. OCCUPIED → Write, Edit, apply_patch
# refusés — seulement dans un couloir d'un projet enregistré (jamais un dépôt ordinaire ni le checkout principal), pour un fichier
# sous ce couloir (apply_patch : ses chemins sont relatifs au couloir), et jamais sous LAB_FORCE=1 (revue du lot) ; PENDING,
# UPDATING ou toute erreur : rien, réessai à l'outil suivant. rc 1 et DENY_REASON seulement pour un refus.
hook_lock_resume() {
  local tool="$1" target="${2:-}" root lock held res p real t
  [ "${LAB_DRY:-0}" != 1 ] || return 0
  git_places "${CLAUDE_PROJECT_DIR:-$HOOK_CWD}" || return 0
  root="$GP_TOP"
  waits_clear_answered "$root" 2>/dev/null || true   # un outil repart : la question ou l'autorisation est réglée (lot 03 d'autonomie-tours)
  lock="$root/.lab/session.lock"
  kv_value "$lock" pid 2>/dev/null || true; held="$KV_VALUE"
  if [ -n "$held" ] && session_owned_here "$root"; then return 0; fi
  agent_pid_found >/dev/null 2>&1 || return 0
  res="$(claim "$root" 2>/dev/null || true)"
  [ "$res" = OCCUPIED ] || return 0
  case "$tool" in Write|Edit|apply_patch) ;; *) return 0 ;; esac
  [ "${LAB_FORCE:-0}" != 1 ] || return 0
  p="$(project_from_cwd "$root" 2>/dev/null || true)"; [ -n "$p" ] || return 0
  load_project "$p" 2>/dev/null || return 0
  ! same_path "$root" "$P_ROOT" || return 0
  if [ "$tool" != apply_patch ]; then
    [ -n "$target" ] || return 0
    real_path_set "$root"; real="$REAL_PATH"; canonical_set "$target"; t="$CANON"
    case "$t" in "$real"/*|"$root"/*) ;; *) return 0 ;; esac
  fi
  DENY_REASON="LOCK=ANOTHER LIVE SESSION ($(lock_field "$lock" agent || true) pid $(lock_field "$lock" pid || true) since $(lock_field "$lock" since || true)) in $root: write nothing here; resume that session, or isolate a new topic (lab new)."
  return 1
}
hook_guard_tool() {
  local tool target
  guard_read
  tool="$HF_TOOL"; target="$HF_PATH"
  if [ "$GUARD_LOCK" != ok ] && ! hook_lock_resume "$tool" "$target"; then json_deny "LAB: $DENY_REASON"; exit 0; fi
  [ "${LAB_FORCE:-0}" = 1 ] && [ "$tool" != Bash ] && exit 0   # Write, Edit, apply_patch : exemption entière ; Bash : portée par segment
  case "$tool" in
    Bash) hook_guard_bash_payload ;;
    Write)
      [ -n "$target" ] || exit 0
      if ! guard_state_target "$target" || ! guard_context_content "$target" '' content; then json_deny "LAB: $DENY_REASON"; fi ;;
    Edit)
      [ -n "$target" ] || exit 0
      if ! guard_state_target "$target" || ! guard_context_content "$target" '' new_string; then json_deny "LAB: $DENY_REASON"; fi ;;
    apply_patch)
      [ -n "$HF_CMD" ] || exit 0
      if ! guard_patch_payload "$HF_CMD"; then json_deny "LAB: $DENY_REASON"; fi ;;
    *) ;;
  esac
  exit 0
}
cmd_hook() {
  case "${1:-}" in
    session-start) hook_session_start ;; session-end) hook_session_end ;; stop-failure) hook_stop_failure ;; notify) hook_notify ;;
    guard-bash) hook_guard_bash ;; guard-tool) hook_guard_tool ;;
    *) die "hook expected: session-start | session-end | stop-failure | notify | guard-bash | guard-tool" ;;
  esac
}
