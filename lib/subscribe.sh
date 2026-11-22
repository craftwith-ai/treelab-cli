# shellcheck shell=bash
# shellcheck disable=SC2154 # temp est le dossier privé de cmd_subscribe, lu par lib/update_private.sh dans le même sous-shell.
# subscribe.sh — lab subscribe (lot 06 de refonte-onboarding) : s'abonner depuis l'installation activée, sans changer de clé.
# POST /api/subscribe-link (contrat treelab-distribution-v1@1.3.0) donne le lien : essai → page de paiement avec la preuve tirée de
# l'installation (la clé d'essai devient le poste 1, payante) ; abonnement vivant → portail Stripe (poste 1 seulement) ; autre poste
# d'une équipe → owner ; abonnement fini → page habituelle, clés neuves ; sans fin → none ; service ancien (400, 404, 503) → page
# habituelle, clé neuve par e-mail. Transport privé de lib/update_private.sh (licence 0600, en-têtes, origine de confiance) : le
# jeton d'activation reste dans les fichiers privés, jamais dans une URL ni un argument ; le lien n'est affiché que si open échoue.
# Avec un terminal, attente par relecture de GET /api/entitlement (30 minutes au plus, q puis Entrée arrête), cache des droits
# récrit au changement ; sans terminal (un agent), le lien est ouvert et la main rendue.
SUBSCRIBE_WAIT_MAX=1800   # LAB_SUBSCRIBE_WAIT ne l'allonge jamais ; LAB_SUBSCRIBE_POLL (10 s) espace les relectures

_subscribe_say() { log_wrap "$*"; }

# _subscribe_call <POST|GET> <route> <sortie> : un appel du contrat, LAB_PRIVATE_STATUS = statut ; rc 1 sur coupure, redirection
# ou en-têtes hors contrat (le corps n'est alors jamais lu)
_subscribe_call() {
  LAB_PRIVATE_DEADLINE=$((SECONDS + 16))
  _update_private_config "$1" "$2" "$temp/request.conf" 2>/dev/null &&
    _update_private_fetch "$temp/request.conf" "$3" 16384 15 2>/dev/null || return 1
  case "$LAB_PRIVATE_STATUS" in 3??) return 1 ;; esac
  _update_private_headers 2>/dev/null
}

# _subscribe_rights <sortie> : rc 0 pour un 200 conforme de GET /api/entitlement ; SUB_RETRY = Retry-After d'un 429 (1 à 300 s,
# borné par _update_private_headers)
_subscribe_rights() {
  SUB_RETRY=''
  _subscribe_call GET /api/entitlement "$1" || return 1
  if [ "$LAB_PRIVATE_STATUS" = 429 ]; then
    SUB_RETRY="$(LC_ALL=C awk -F: 'tolower($1)=="retry-after" {v=$2; gsub(/[ \t\r]/, "", v)} END {print v}' "$temp/headers")"
    return 1
  fi
  [ "$LAB_PRIVATE_STATUS" = 200 ] && _update_private_flat "$1" 3 &&
    jq -es 'length==1 and (.[0] | type=="object" and keys==["entitled_until","plan","renews"] and
      (.plan=="trial" or .plan=="subscription") and (.renews|type=="boolean") and
      (.entitled_until==null or (.entitled_until|type=="number" and floor==. and .>0 and .<253402300800)))' "$1" >/dev/null 2>&1
}

# _subscribe_link_valid <corps> : réponse 200 du contrat 1.3.0 — l'URL est sur l'origine de confiance et finit par une preuve de
# 64 hexadécimaux (jamais un jeton d'activation), ou l'une des formes sans lien
_subscribe_link_valid() {
  _update_private_flat "$1" 3 && jq -es --arg origin "$LAB_PRIVATE_API" '
    def until: type=="number" and floor==. and .>0 and .<253402300800;
    def proof($path): (.url|type=="string") and (.url|startswith($origin+$path)) and
      (.url[(($origin+$path)|length):] | test("^[0-9a-f]{64}$"));
    length==1 and (.[0] | type=="object" and keys==["action","expires_at","url"] and (
      (.action=="checkout" and proof("/subscribe?claim=") and (.expires_at|until)) or
      (.action=="checkout" and .url==($origin+"/subscribe") and .expires_at==null) or
      (.action=="portal" and proof("/billing?link=") and (.expires_at|until)) or
      ((.action=="owner" or .action=="none") and .url==null and .expires_at==null)))' "$1" >/dev/null 2>&1
}

# _subscribe_refused <corps> : refus de l'identité, du limiteur ou réponse hors contrat → die, cause nommée ; rien ouvert ni écrit
_subscribe_refused() {
  local code
  code="$(jq -r 'if type=="object" and (.error|type)=="object" and (.error.code|type)=="string" then .error.code else "" end' "$1" 2>/dev/null)"
  case "$LAB_PRIVATE_STATUS:$code" in
    401:AUTH_REQUIRED|401:CREDENTIALS_INVALID)
      die 'Local license not recognized. Restore the license of this installation, or use the subscribe link in your trial email.' ;;
    403:LICENSE_REFUSED) die 'License refused. Nothing changed; contact support.' ;;
    403:ACTIVATION_REPLACED)
      die 'This key is now active on another installation. Use the subscribe link in your trial email, or activate the key here again with the install command (the other installation then stops getting updates).' ;;
    403:MACHINE_MISMATCH) die 'License tied to another installation. Restore the license file that belongs to this Mac.' ;;
    429:RATE_LIMITED) die 'Service temporarily limited. Wait a minute, then run lab subscribe again.' ;;
    *) die 'Incompatible response from the Treelab service. Nothing changed; contact support.' ;;
  esac
}

# _subscribe_open <url> <private|public> : le navigateur ; le lien ne s'affiche que s'il n'a pas pu s'ouvrir (scrollback, journal)
_subscribe_open() {
  if open "$1" >/dev/null 2>&1; then return 0; fi
  if [ "$2" = private ]; then _subscribe_say 'No browser could be opened. Open this link yourself; it is private, valid for one hour:'
  else _subscribe_say 'No browser could be opened. Open this link yourself:'; fi
  log "$1"
  return 1
}

# _subscribe_done <checkout|portal> <droits> [droits d'avant, [plan,fin,renews]] : nouvelle date affichée, cache récrit.
# Paiement reçu sans fin plus tardive (l'acheteur attend les 14 jours de rétractation, la clé garde sa fin d'essai) :
# aucune date payée annoncée, RESULT=deferred (revue du lot 06).
_subscribe_done() {
  local until was
  entitlement_write "$2" || true
  until="$(jq -r '.entitled_until // empty' "$2")"
  was="$(printf '%s' "${3:-[]}" | jq -r '.[1] // empty' 2>/dev/null)" || was=''
  if [ "$1" = checkout ] && [[ "$until" =~ ^[0-9]+$ ]] && [[ "$was" =~ ^[0-9]+$ ]] && [ "$until" -le "$was" ]; then
    _subscribe_say 'Payment received. You chose to wait for the 14-day withdrawal period: this key becomes paid when it ends; nothing else to do.'
    kv RESULT deferred; return 0
  fi
  if [ -z "$until" ]; then _subscribe_say 'Subscription updated: updates without an end date.'
  elif [ "$1" = portal ]; then _subscribe_say "Subscription updated: updates paid until $(entitlement_day "$until") (UTC)."
  else _subscribe_say "Payment received: updates paid until $(entitlement_day "$until") (UTC). This key keeps working; nothing else to do."; fi
  [ -z "$until" ] || kv LICENSE_UNTIL "$(entitlement_instant "$until")"
  if [ "$1" = portal ]; then kv RESULT changed; else kv RESULT paid; fi
}

# _subscribe_wait <checkout|portal> : relit les droits jusqu'au changement, au plus SUBSCRIBE_WAIT_MAX ; q puis Entrée arrête.
# Référence : les droits lus avant l'ouverture, sinon la première lecture réussie. rc 1 seulement au bout de l'attente.
_subscribe_wait() {
  local wait="${LAB_SUBSCRIBE_WAIT:-$SUBSCRIBE_WAIT_MAX}" poll="${LAB_SUBSCRIBE_POLL:-10}" deadline next reply rc before='' now
  [[ "$wait" =~ ^[1-9][0-9]{0,5}$ ]] && [ "$wait" -le "$SUBSCRIBE_WAIT_MAX" ] || wait="$SUBSCRIBE_WAIT_MAX"
  [[ "$poll" =~ ^[1-9][0-9]{0,2}$ ]] || poll=10
  deadline=$((SECONDS + wait)); next=$((SECONDS + poll))
  [ ! -f "$temp/before.json" ] || before="$(jq -c '[.plan,.entitled_until,.renews]' "$temp/before.json")"
  if [ "$1" = portal ]; then _subscribe_say "Waiting for a change, $(((wait + 59) / 60)) minutes at most. q then Enter stops waiting."
  else _subscribe_say "Waiting for the payment, $(((wait + 59) / 60)) minutes at most. q then Enter stops waiting; the link stays valid for an hour."; fi
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ "$SECONDS" -ge "$next" ]; then
      next=$((SECONDS + poll))
      if _subscribe_rights "$temp/rights.json"; then
        now="$(jq -c '[.plan,.entitled_until,.renews]' "$temp/rights.json")"
        if [ -z "$before" ]; then before="$now"
        elif [ "$now" != "$before" ]; then _subscribe_done "$1" "$temp/rights.json" "$before"; return 0; fi
      elif [ -n "$SUB_RETRY" ]; then next=$((SECONDS + SUB_RETRY)); fi
    fi
    rc=0; IFS= read -r -t 1 reply || rc=$?
    if [ "$rc" = 0 ] && [ "${reply//[[:space:]]/}" = q ]; then
      if [ "$1" = portal ]; then _subscribe_say 'Stopped waiting. Nothing is lost: changes made in the browser apply on their own; treelab update shows the new date.'
      else _subscribe_say 'Stopped waiting. Nothing is lost: once paid, this key becomes paid on its own; treelab update or lab subscribe shows it.'; fi
      kv RESULT stopped; return 0
    fi
    # fin de l'entrée (et non délai écoulé) : read rend la main tout de suite, l'attente se fait ici
    [ "$rc" = 0 ] || [ "$rc" -gt 128 ] || sleep 1
  done
  if [ "$1" = portal ]; then _subscribe_say 'No change seen yet. Nothing is lost: changes made in the browser apply on their own; run lab subscribe again to check.'
  else _subscribe_say 'No payment seen yet. Nothing is lost: if you pay later, this key becomes paid on its own; run lab subscribe again to check.'; fi
  kv RESULT timeout; return 1
}

cmd_subscribe() (
  [ "$#" = 0 ] || { (die 'usage: lab subscribe — no argument') || exit 2; }
  set +x
  declare -F _txn_plain_path >/dev/null || . "$LAB_ROOT/lib/install.sh"
  # shellcheck source=lib/update_private.sh
  . "$LAB_ROOT/lib/update_private.sh"
  umask 077
  local temp action url plan license=0 opened=yes
  temp="$(mktemp -d /private/tmp/treelab-subscribe.XXXXXXXX)" || die 'Private temporary folder unavailable. Nothing changed.'
  trap 'rm -R "$temp"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  _update_private_trust || die 'Private distribution not configured in this version. Nothing changed; contact support.'
  _update_license_read "$LAB_HOME/license" "$temp/license" || license=$?
  case "$license" in
    0) ;;
    2) die 'No license on this Mac. Install Treelab first: curl -fsSL https://treelab.sh/install | bash' ;;
    *) die 'License file unusable. Restore a valid regular file with mode 0600, then run lab subscribe again.' ;;
  esac
  _subscribe_rights "$temp/before.json" || rm -f "$temp/before.json"
  _subscribe_call POST /api/subscribe-link "$temp/link.json" ||
    die 'Connection interrupted. Nothing changed; check the connection, then run lab subscribe again.'
  case "$LAB_PRIVATE_STATUS" in
    200) _subscribe_link_valid "$temp/link.json" || die 'Incompatible response from the Treelab service. Nothing changed; contact support.'
      action="$(jq -r .action "$temp/link.json")"; url="$(jq -r '.url // empty' "$temp/link.json")"
      if [ "$action" = checkout ] && [ "$url" = "$LAB_PRIVATE_API/subscribe" ]; then action=renew; fi ;;
    400|404|503) action=legacy; url="$LAB_PRIVATE_API/subscribe" ;;
    *) _subscribe_refused "$temp/link.json" ;;
  esac
  kv SUBSCRIBE "$action"
  case "$action" in
    none) _subscribe_say 'Your updates have no end date: nothing to do.'; kv RESULT nothing; return 0 ;;
    owner) _subscribe_say 'This key is a seat of a team subscription managed by its purchaser: they manage it from the link in their confirmation email.'
      kv RESULT nothing; return 0 ;;
    renew) _subscribe_open "$url" public && _subscribe_say 'The subscription page is open in your browser.'
      _subscribe_say 'Your subscription has ended: a new subscription sends new keys by email; then run the install command from that email.'
      kv RESULT opened; return 0 ;;
    legacy) plan=''; [ ! -f "$temp/before.json" ] || plan="$(jq -r .plan "$temp/before.json")"
      [ -n "$plan" ] || { entitlement_read 2>/dev/null && plan="$ENT_PLAN"; } || plan=''
      _subscribe_open "$url" public && _subscribe_say 'The usual subscription page is open in your browser.'
      if [ "$plan" = subscription ]; then
        _subscribe_say 'This Treelab service cannot open your subscription from here yet: manage it from the link in your confirmation email, or subscribe again (a new key arrives by email).'
      else
        _subscribe_say 'This Treelab service cannot keep your trial key yet: after payment, a new key arrives by email; then run the install command from that email.'
      fi
      kv RESULT opened; return 0 ;;
    portal) _subscribe_open "$url" private || opened=no
      [ "$opened" = no ] || _subscribe_say 'Your subscription page (Stripe) is open in your browser: card, invoices, renewal, cancellation.' ;;
    *) _subscribe_open "$url" private || opened=no
      [ "$opened" = no ] || _subscribe_say 'The subscription page is open in your browser.'
      _subscribe_say 'After payment, this trial key becomes a paid key: nothing else to do.' ;;
  esac
  if ! { [ -t 0 ] && [ -t 2 ]; }; then
    _subscribe_say 'Without a terminal, lab subscribe does not wait: once done in the browser, treelab update shows the new date.'
    kv RESULT opened; return 0
  fi
  _subscribe_wait "$action"
)
