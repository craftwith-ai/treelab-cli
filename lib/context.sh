# shellcheck shell=bash
# context.sh — contexte neuf (lot 01 de contexte-neuf). Chaque action renvoie au modèle toute la conversation : au-delà de context_max
# (250 000 tokens par défaut depuis le lot 08, 200 000 avant), une session de lot repart à neuf depuis son Handoff par lab next. Le contexte d'un appel suit la formule
# de la statusline de Claude Code : input_tokens + cache_creation_input_tokens + cache_read_input_tokens de la dernière réponse, lue
# ici dans le transcript (la charge d'un crochet ne la porte pas). Chargé par lib/guard_fast.sh (crochet notify) avec kv.sh.
CONTEXT_MAX_DEFAULT=250000
CONTEXT_TAIL_BYTES=524288   # lecture par la fin, bornée : un transcript dépasse 100 Mo ; une réponse tient dans ces 512 Kio
CONTEXT_WIDE_BYTES=16777216 # seconde lecture, lignes de réponse seules : un résultat d'outil (une capture) dépasse parfois 512 Kio

# context_max_set : CONTEXT_MAX, le seuil — LAB_CONTEXT_MAX, sinon context_max= de la config globale, sinon le défaut ; 0 coupe le
# rappel ; une valeur qui n'est pas un entier rend le défaut. Config globale : <LAB_HOME>/config, LAB_HOME résolu comme lib/project.sh
context_max_set() {
  local v="${LAB_CONTEXT_MAX-}" home="${LAB_HOME:-}"
  if [ -z "$v" ]; then
    if [ -z "$home" ]; then if [ -f "$LAB_ROOT/.release" ]; then home="$HOME/.lab"; else home="$LAB_ROOT"; fi; fi
    if kv_value "$home/config" context_max; then v="$KV_VALUE"; fi
  fi
  case "$v" in ''|*[!0-9]*) v="$CONTEXT_MAX_DEFAULT" ;; esac
  case "$v" in ?????????????*) v="$CONTEXT_MAX_DEFAULT" ;; esac   # plus de 12 chiffres : illisible, jamais un dépassement d'entier
  CONTEXT_MAX=$((10#$v))
}

# context_tokens <transcript> : CONTEXT_TOKENS, le contexte du dernier appel du fil principal écrit au transcript (Claude ou Codex,
# formule CONTEXT_JQ_DEF) ; rc 1 et vide si le transcript manque ou ne dit
# rien. Claude Code écrit la réponse qui appelle un outil après le départ du crochet PostToolUse (≈ 220 ms, essai C7) : le contexte lu
# est celui de l'appel précédent, et rien au premier outil d'une session. Sans réponse dans les 512 Kio de la fin, seconde lecture des
# seules lignes à compteur des 16 Mio de la fin (revue du lot 01), frontières de compaction comprises : après une compaction au
# repos, Claude Code écrit plus de 512 Kio sans compteur (480 Kio chez la tour, lot 06). jq lit chaque ligne pour elle-même : la
# première, coupée par la lecture par la fin, et un « usage » cité dans un texte ou un résultat d'outil (ligne user) ne comptent pas.
context_tokens() {
  CONTEXT_TOKENS=''
  [ -f "$1" ] && [ -r "$1" ] || return 1
  CONTEXT_TOKENS="$(exec tail -c "$CONTEXT_TAIL_BYTES" -- "$1" 2>/dev/null | context_usage_last)" || CONTEXT_TOKENS=''
  [ -n "$CONTEXT_TOKENS" ] || CONTEXT_TOKENS="$(exec tail -c "$CONTEXT_WIDE_BYTES" -- "$1" 2>/dev/null \
    | exec grep -F -e '"type":"assistant"' -e '"type":"token_count"' -e '"compact_boundary"' 2>/dev/null | exec tail -n 8 \
    | context_usage_last)" || CONTEXT_TOKENS=''
  case "$CONTEXT_TOKENS" in ''|0|*[!0-9]*) CONTEXT_TOKENS=''; return 1 ;; esac
}
# CONTEXT_JQ_DEF : la formule, une seule fois, pour le rappel, la tour (context_tokens) et lab top (lib/top.sh). context_of sur une
# ligne lue comme objet JSON : Claude, réponse du fil principal → input_tokens + cache_creation_input_tokens + cache_read_input_tokens
# de son usage ; Codex (lot 03), compteur token_count → input_tokens du dernier appel (last_token_usage, cache compris : le total de
# la session ne compte pas) ; Claude, frontière de compaction du fil principal (lot 06, une compaction au repos n'écrit aucune
# réponse après elle) → compactMetadata.postTokens, le contexte d'après, 0 sans lui ou illisible (contexte inconnu : jamais l'ancien
# chiffre, les lecteurs écartent le 0) ; rien pour toute autre ligne, une somme nulle (message synthétique d'erreur, compteur sans info) ou un
# champ d'un autre type : une ligne étrange n'arrête jamais la lecture des suivantes (lab top lit tous les journaux d'une passe).
CONTEXT_JQ_DEF='def context_of: try (
  if .type == "assistant" and (.isSidechain // false) == false then .message | objects | .usage | objects
    | (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)
  elif .type == "event_msg" and ((.payload | objects | .type) == "token_count") then .payload.info | objects | .last_token_usage | objects
    | .input_tokens // 0
  else empty end) catch empty | numbers | select(. > 0) | floor;
  def boundary_of: try (select(.type == "system" and .subtype == "compact_boundary" and (.isSidechain // false) == false)
    | (.compactMetadata | objects | .postTokens) // 0 | if type == "number" and . >= 0 then floor else 0 end) catch empty;
  def counter_of: context_of, boundary_of;'
# context_usage_last : sur stdout, le contexte de la dernière ligne qui en porte un (réponse ou frontière), lue sur stdin ; rien
# sinon, ni quand la dernière est une frontière sans postTokens
context_usage_last() {
  exec jq -nR "$CONTEXT_JQ_DEF"' last(inputs | try fromjson catch empty | objects | counter_of) // empty | select(. > 0)' 2>/dev/null
}

# context_reminder <événement> <transcript> <projet> <couloir> [outil] [tower] : sur stdout la ligne JSON hookSpecificOutput du rappel,
# rien sous le seuil, avec context_max=0 ou sans contexte lisible. UserPromptSubmit, ou réponse cliquée à AskUserQuestion : les mots
# de l'utilisateur partent dans le Handoff, la session neuve les traite (un seul appel lourd) ; toute autre action : finir l'étape en
# cours, log et Handoff, puis lab next. tower (lot 05) : un seul message pour tout événement — la tour n'a pas de Handoff à relire et
# ses ordres sont des gestes lab courts : elle exécute d'abord le message ou la réponse, finit son geste (une fermeture suivie de sa
# publication, que seule sa conversation connaît), puis lab next <projet> tower ; le point de 30 min (prompt de /loop) revient à la
# session neuve.
context_reminder() {
  local msg what=message
  context_max_set; [ "$CONTEXT_MAX" -gt 0 ] || return 0
  context_tokens "$2" || return 0
  [ "$CONTEXT_TOKENS" -gt "$CONTEXT_MAX" ] || return 0
  msg="LAB: context $CONTEXT_TOKENS tokens, above context_max $CONTEXT_MAX (~/.lab/config, 0 turns this reminder off)."
  if [ "${6:-}" = tower ]; then
    msg="$msg The tower starts fresh by itself, asking the user nothing: carry out first the user's message or answer if this turn brings one (the tower's own 30-minute check is left to the fresh session), finish the gesture in progress (a close with its publication included) and start no other, then run lab next $3 tower from this session; a fresh tower session takes over in this tab with its check and its 30-minute loop."
    jq -cn --arg e "$1" --arg c "$msg" '{hookSpecificOutput:{hookEventName:$e,additionalContext:$c}}'; return 0
  fi
  [ "$1" = UserPromptSubmit ] || what=answer
  case "$1/${5:-}" in
    UserPromptSubmit/*|PostToolUse/AskUserQuestion) msg="$msg Do not handle the user's $what here: copy it word for word into ## Handoff of the batch file as the first thing to do, update the log, then run lab next $3 $4 from this session; the fresh session handles it." ;;
    *) msg="$msg Finish the current step, update the log and ## Handoff of the batch file, then run lab next $3 $4 from this session; the fresh session goes on from the Handoff." ;;
  esac
  jq -cn --arg e "$1" --arg c "$msg" '{hookSpecificOutput:{hookEventName:$e,additionalContext:$c}}'
}
