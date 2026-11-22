# shellcheck shell=bash
# entitlement.sh — droits aux mises à jour vus par lab (lot 05 de refonte-onboarding). Cache local seul, jamais le réseau ni la
# licence : $LAB_STATE/entitlement.json, format treelab-entitlement-v1 — plan (trial|subscription), until (secondes UTC, fin
# exclue ; null = sans fin), renews (abonnement qui se renouvelle seul), checked_at (lecture). Écrit par un treelab update réussi
# après GET /api/entitlement (contrat 1.2.0), lu par lab status, le doctor, le rappel de lab next et le hook de début de session.
# Toute erreur (cache absent, illisible, d'un autre schéma, horloge LAB_NOW mal formée) donne l'état unknown, sans un mot.
ENTITLEMENT_FORMAT=treelab-entitlement-v1
ENTITLEMENT_SOON=172800   # 2 jours : un essai ou un abonnement résilié est rappelé à moins de 2 jours de sa fin (borne exclue)

entitlement_file() { printf '%s/entitlement.json\n' "$LAB_STATE"; }
# entitlement_now → epoch ; LAB_NOW (YYYY-MM-DDTHH:MM:SSZ) fixe l'horloge des tests, rc 1 s'il est mal formé
entitlement_now() {
  if [ -n "${LAB_NOW:-}" ]; then declare -F rdv_is_stamp >/dev/null && rdv_is_stamp "$LAB_NOW" && rdv_epoch "$LAB_NOW"; return; fi
  date +%s
}

# entitlement_read : ENT_PLAN, ENT_UNTIL (vide = sans fin), ENT_RENEWS (true|false), ENT_CHECKED depuis le cache ; rc 1 sinon
entitlement_read() {
  local f row
  ENT_PLAN='' ENT_UNTIL='' ENT_RENEWS='' ENT_CHECKED=''
  f="$(entitlement_file)"
  [ -f "$f" ] && [ ! -L "$f" ] && [ -r "$f" ] && [ "$(wc -c <"$f" 2>/dev/null | tr -d ' ')" -le 1024 ] 2>/dev/null || return 1
  row="$(jq -esr --arg format "$ENTITLEMENT_FORMAT" '
    def epoch: type=="number" and floor==. and .>0 and .<253402300800;
    if length==1 and (.[0] | type=="object" and keys==["checked_at","format","plan","renews","until"] and .format==$format and
      (.plan=="trial" or .plan=="subscription") and (.renews|type=="boolean") and (.until==null or (.until|epoch)) and (.checked_at|epoch))
    then .[0] | "\(.plan) \(.until // "-") \(.renews) \(.checked_at)" else error("schema") end' "$f" 2>/dev/null)" || return 1
  read -r ENT_PLAN ENT_UNTIL ENT_RENEWS ENT_CHECKED <<<"$row"
  [ "$ENT_UNTIL" != - ] || ENT_UNTIL=''
}

# entitlement_state [now] : ENT_STATE = active|ending|ended|none|unknown, ENT_* lus — dans le shell courant, jamais dans $( ) qui
# perdrait les ENT_*. Abonnement qui se renouvelle dont la fin est passée : cache périmé (renouvellement pas encore relu), unknown —
# jamais une fausse fin ; le 402 de la tentative suivante dit la vérité.
entitlement_state() {
  local now="${1:-}"
  ENT_STATE=unknown
  [ -n "$now" ] || now="$(entitlement_now 2>/dev/null)" || now=''
  [[ "$now" =~ ^[1-9][0-9]{0,11}$ ]] && entitlement_read || return 0
  if [ -z "$ENT_UNTIL" ]; then ENT_STATE=none
  elif [ "$now" -ge "$ENT_UNTIL" ]; then if [ "$ENT_RENEWS" = true ]; then ENT_STATE=unknown; else ENT_STATE=ended; fi
  elif [ "$ENT_RENEWS" = false ] && [ "$((ENT_UNTIL - now))" -lt "$ENTITLEMENT_SOON" ]; then ENT_STATE=ending
  else ENT_STATE=active; fi
}

entitlement_day() { date -u -r "$1" +%Y-%m-%d; }
entitlement_instant() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
entitlement_version() { head -1 "$LAB_ROOT/VERSION" 2>/dev/null | tr -cd '0-9A-Za-z.+-'; }

# entitlement_line <ending|ended> → la phrase pour l'utilisateur (ENT_* lus) : date de fin, version gardée, et lab subscribe — qui
# garde la clé d'essai et ouvre le portail d'un abonnement résilié (lot 06) ; plus jamais un lien seul, qui menait à une clé neuve
entitlement_line() {
  local at
  case "$1" in
    ending)
      at="$(date -u -r "$ENT_UNTIL" '+%Y-%m-%d at %H:%M UTC')" || return 1
      if [ "$ENT_PLAN" = trial ]; then printf 'Your Treelab trial ends on %s. Run lab subscribe to keep this key and its updates.\n' "$at"
      else printf 'Your Treelab subscription ends on %s and will not renew. Run lab subscribe to renew it.\n' "$at"; fi ;;
    ended)
      printf 'Your Treelab updates ended on %s (UTC). Installed version kept (%s): it keeps working. Run lab subscribe to get new versions.\n' \
        "$(entitlement_day "$ENT_UNTIL")" "$(entitlement_version)" ;;
    *) return 1 ;;
  esac
}

# entitlement_once <nom> [now] : rc 0 et le jour noté dans $LAB_STATE/<nom> s'il ne l'était pas encore — un passage par jour (jour
# du Mac) ; rc 1 si déjà vu aujourd'hui ou sur toute erreur (état non inscriptible : silence plutôt qu'une ligne à chaque passage).
# entitlement-notice : lab next et lab update --auto, une seule ligne par jour à eux deux ; entitlement-session : le hook.
# LAB_UNATTENDED=1 (lab next de lab wake ou d'un veilleur Cloud, sortie vers un journal) : rc 1, rien de consommé.
entitlement_once() {
  local f="$LAB_STATE/$1" now="${2:-}" day tmp
  [ "${LAB_UNATTENDED:-0}" != 1 ] || return 1
  [ -n "$now" ] || now="$(entitlement_now 2>/dev/null)" || return 1
  [[ "$now" =~ ^[1-9][0-9]{0,11}$ ]] && day="$(date -r "$now" +%Y-%m-%d 2>/dev/null)" || return 1
  [ ! -L "$f" ] && [ "$(head -1 "$f" 2>/dev/null)" != "$day" ] || return 1
  [ -d "$LAB_STATE" ] && [ -w "$LAB_STATE" ] || return 1
  tmp="$(mktemp "$LAB_STATE/.$1.XXXXXX" 2>/dev/null)" || return 1
  if printf '%s\n' "$day" >"$tmp" && mv -f "$tmp" "$f"; then return 0; fi
  rm -f "$tmp"; return 1
}

# entitlement_write <réponse> : réponse 200 validée de GET /api/entitlement → cache, en une écriture atomique ; rc 1 sur toute erreur
entitlement_write() {
  local now tmp f; f="$(entitlement_file)"
  now="$(entitlement_now 2>/dev/null)" && [[ "$now" =~ ^[1-9][0-9]{0,11}$ ]] || return 1
  [ -d "$LAB_STATE" ] && [ -w "$LAB_STATE" ] && [ ! -L "$f" ] || return 1
  tmp="$(mktemp "$LAB_STATE/.entitlement.XXXXXX" 2>/dev/null)" || return 1
  if jq -c --arg format "$ENTITLEMENT_FORMAT" --argjson now "$now" \
      '{format:$format, plan:.plan, until:.entitled_until, renews:.renews, checked_at:$now}' "$1" >"$tmp" 2>/dev/null && mv -f "$tmp" "$f"; then
    return 0
  fi
  rm -f "$tmp"; return 1
}

# entitlement_status_kv : lignes LICENSE_* de lab status ; rien pour unknown (aucune lecture des droits encore faite, ou service
# antérieur au contrat 1.2.0 : lab reste muet)
entitlement_status_kv() {
  entitlement_state
  [ "$ENT_STATE" != unknown ] || return 0
  kv LICENSE_PLAN "$ENT_PLAN"
  if [ -n "$ENT_UNTIL" ]; then kv LICENSE_UNTIL "$(entitlement_instant "$ENT_UNTIL")"; else kv LICENSE_UNTIL none; fi
  kv LICENSE_STATE "$ENT_STATE"
  kv LICENSE_CHECKED "$(entitlement_instant "$ENT_CHECKED")"
}

# entitlement_remind : rappel de lab next — essai ou abonnement résilié à moins de 2 jours de la fin, ou droits échus — une fois par
# jour (même tampon que lab update --auto) ; jamais pour un abonnement qui se renouvelle. Muet sur toute erreur, rc toujours 0.
entitlement_remind() {
  local now line
  now="$(entitlement_now 2>/dev/null)" || return 0
  entitlement_state "$now"
  case "$ENT_STATE" in ending|ended) ;; *) return 0 ;; esac
  line="$(entitlement_line "$ENT_STATE")" && [ -n "$line" ] || return 0
  entitlement_once entitlement-notice "$now" || return 0
  log_wrap "$line"
}

# entitlement_hook_line → la ligne de début de session, une fois par jour ; rien sinon, rc 0 même sur erreur
entitlement_hook_line() {
  local now line
  now="$(entitlement_now 2>/dev/null)" || return 0
  entitlement_state "$now"
  case "$ENT_STATE" in ending|ended) ;; *) return 0 ;; esac
  line="$(entitlement_line "$ENT_STATE")" && [ -n "$line" ] || return 0
  entitlement_once entitlement-session "$now" || return 0
  printf 'LICENSE=%s %s Tell the user first, in their language.\n' "$(printf '%s' "$ENT_STATE" | tr '[:lower:]' '[:upper:]')" "$line"
}
