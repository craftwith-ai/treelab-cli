# shellcheck shell=bash
# shellcheck disable=SC1112 # Apostrophes françaises dans les diagnostics.
# shellcheck disable=SC2154 # temp est le dossier privé de cmd_update, dans le même sous-shell.
# Contrat treelab-distribution-v1@1.3.0 (lecture des droits et 402 du lot 05 ; lab subscribe du lot 06 réutilise ce transport).
# Chargé par update privé et par lab subscribe.
# Aucune activation ; aucun effet au chargement. Tous les secrets restent en
# fichiers privés ou dans des variables locales non exportées.
_update_license_read() (
  local source="$1" destination="$2" metadata bytes staged
  _txn_plain_path "$source" || return 1
  case "$source" in *'/../'*|*'/./'*|*'//'*) return 1 ;; esac
  [ -e "$source" ] || return 2
  [ -f "$source" ] && [ ! -L "$source" ] && [ -r "$source" ] || return 1
  metadata="$(stat -f '%u:%Lp:%z' "$source" 2>/dev/null)" || return 1
  case "$metadata" in "$(id -u):600:"*) ;; *) return 1 ;; esac
  bytes="${metadata##*:}"
  [[ "$bytes" =~ ^[0-9]+$ ]] && [ "$bytes" -gt 0 ] && [ "$bytes" -le 4096 ] || return 1
  # Lecture bornée dans un fichier éphémère. Le chemin de sortie ne reçoit les
  # identifiants qu’après validation, jamais un document partiellement accepté.
  umask 077
  staged="$(mktemp "${destination}.XXXXXXXX")" || return 1
  trap 'rm -f "$staged"' EXIT
  head -c 4097 "$source" >"$staged" 2>/dev/null || return 1
  [ "$(stat -f %z "$staged")" = "$bytes" ] &&
    [ "$(stat -f '%u:%Lp:%z' "$source" 2>/dev/null)" = "$metadata" ] &&
    _txn_plain_path "$source" || return 1
  # --stream garde les propriétés dupliquées, même écrites avec un échappement
  # Unicode ; le parseur JSON ordinaire seul les aurait silencieusement écrasées.
  { cat "$staged"; printf '\n'; } | jq --stream -es 'length==5 and
    ([.[] | select(length==2) | .[0]] | length==4 and all(length==1) and (unique|length==4))' \
    >/dev/null 2>&1 || return 1
  jq -es '
    def uuid: type=="string" and length==36 and test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\\z");
    length==1 and (.[0] | type=="object" and
      keys==["activation_id","activation_token","format","machine_id"] and
      .format=="treelab-license-v1" and (.activation_id|uuid) and (.machine_id|uuid) and
      (.activation_token|type=="string" and length==71 and test("^tl_act_[0-9a-f]{64}\\z")))
  ' "$staged" >/dev/null 2>&1 || return 1
  [ ! -e "$destination" ] && [ ! -L "$destination" ] || return 1
  mv "$staged" "$destination"
)

_update_private_trust() {
  # Configuration livrée et revue, jamais issue de l’environnement ou du réseau.
  # Destination du service API livré (reçu de déploiement du 2026-09-08).
  LAB_PRIVATE_API='https://treelab.sh'
  LAB_PRIVATE_R2='https://eacbafbfa9edff3cec31644d9e355a4a.r2.cloudflarestorage.com'
  LAB_PRIVATE_BUCKET='treelab-releases'
  LAB_PRIVATE_PREFIX='stable'
  [[ "$LAB_PRIVATE_R2" =~ ^https://[0-9a-f]{32}\.r2\.cloudflarestorage\.com$ ]] &&
    [[ "$LAB_PRIVATE_BUCKET" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]] &&
    [[ "$LAB_PRIVATE_PREFIX" =~ ^[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)*$ ]]
}
_update_private_protocol_error() {
  LAB_UPDATE_REASON=source; _update_error 'Incompatible license response. Installation kept; keep the current version and contact support.'
}
_update_private_network_error() {
  LAB_UPDATE_REASON=network; _update_error 'Connection or download interrupted. Installation kept; check the connection, then run treelab update again.'
}
_update_private_flat() {
  # Les réponses positives du protocole sont des objets plats. Compter les
  # événements de flux interdit les clés dupliquées avant le parsing ordinaire.
  { cat "$1"; printf '\n'; } | jq --stream -es --argjson count "$2" 'length==($count+1) and
    ([.[]|select(length==2)|.[0]] | length==$count and all(length==1) and (unique|length==$count))' \
    >/dev/null 2>&1
}
_update_private_config() {
  local method="$1" route="$2" output="$3"
  {
    printf 'url = "%s%s"\nrequest = "%s"\n' "$LAB_PRIVATE_API" "$route" "$method"
    printf 'header = "Accept: application/json"\nheader = "X-Treelab-Contract: 1"\n'
    jq -r '"header = \"Authorization: Bearer "+.activation_token+"\"",
      "header = \"X-Treelab-Activation: "+.activation_id+"\"",
      "header = \"X-Treelab-Machine: "+.machine_id+"\""' "$temp/license" || return 1
    if [ "$method" = POST ]; then
      printf 'header = "Content-Type: application/json"\ndata = "{}"\n'
    fi
  } >"$output"
}
_update_private_fetch() {
  local config="$1" body="$2" limit="$3" timeout="$4" remaining rc=0
  remaining="$((LAB_PRIVATE_DEADLINE-SECONDS))"
  [ "$remaining" -gt 0 ] || return 1
  [ "$timeout" -le "$remaining" ] || timeout="$remaining"
  # La coupe du flux protège aussi curl <8.4, dont max-filesize ne borne pas un
  # corps sans Content-Length. Le code HTTP seul va sur stderr privé ; aucune
  # erreur curl brute ne rejoint le diagnostic public. Pipefail conserve l’échec
  # de curl même si head a lu un préfixe JSON apparemment valide.
  if curl -q --config "$config" --silent --no-location --max-redirs 0 \
    --proto '=https' --proto-redir '=https' --globoff --path-as-is \
    --disallow-username-in-url --no-netrc --proxy '' --noproxy '*' \
    --connect-timeout 5 --max-time "$timeout" --max-filesize "$limit" \
    --dump-header "$temp/headers" --write-out '%{stderr}%{http_code}' \
    2>"$temp/status" | head -c "$((limit+1))" >"$body"; then :; else rc=$?; fi
  [ "$rc" = 0 ] && [ "$(stat -f %z "$body")" -le "$limit" ] || return 1
  LAB_PRIVATE_STATUS="$(cat "$temp/status")"
  [[ "$LAB_PRIVATE_STATUS" =~ ^[1-5][0-9][0-9]$ ]] || return 1
}
_update_private_headers() {
  # Ne conserver que le dernier bloc HTTP (100/103 ou CONNECT possibles).
  # Aucun en-tête reçu ne configure le transport suivant.
  [ "$(stat -f %z "$temp/headers")" -le 32768 ] || return 1
  LC_ALL=C awk -v status="$LAB_PRIVATE_STATUS" '
    /^HTTP\// {contract=0; cache=0; media=0; challenge=0; retry=0; bad=0; next}
    {
      sub(/\r$/, ""); n=index($0, ":"); if(!n) next
      key=tolower(substr($0,1,n-1)); value=substr($0,n+1)
      sub(/^[ \t]+/, "", value); sub(/[ \t]+$/, "", value)
      if(key=="x-treelab-contract") {contract++; if(value!="1") bad=1}
      if(key=="cache-control") {cache++; if(tolower(value)!="no-store") bad=1}
      if(key=="content-type") {media++; if(tolower(value)!~/^application\/json(;[ \t]*charset=utf-8)?$/) bad=1}
      if(key=="www-authenticate") {challenge++; if(value!~/^Bearer([ \t]|$)/) bad=1}
      if(key=="retry-after") {retry++; if(value!~/^[0-9]+$/ || value+0<1 || value+0>300) bad=1}
    }
    END {exit !(contract==1 && cache==1 && media==1 && !bad &&
      (status!=401 || challenge==1) && (status!=429 || retry==1))}
  ' "$temp/headers"
}
# _update_private_ended <corps> : 402 ENTITLEMENT_ENDED du contrat — date de fin, version gardée, et lab subscribe (lot 06), qui
# garde la clé ; jamais le message du service ni son renew_url, qui mène à une clé neuve.
_update_private_ended() {
  local input="$1" until day
  if ! { { cat "$input"; printf '\n'; } | jq --stream -es 'length==7 and ([.[]|select(length==2)|.[0]] |
    sort==[["error","code"],["error","entitled_until"],["error","message"],["error","renew_url"],["error","request_id"]])' >/dev/null 2>&1 &&
  jq -es 'length==1 and (.[0].error | .code=="ENTITLEMENT_ENDED" and (.message|type=="string") and (.renew_url|type=="string") and
    (.entitled_until|type=="number" and floor==. and .>0 and .<253402300800) and
    (.request_id|type=="string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")))' \
    "$input" >/dev/null 2>&1; }; then _update_private_protocol_error; return 1; fi
  until="$(jq -r .error.entitled_until "$input")"
  day="$(date -u -r "$until" +%Y-%m-%d)" || { _update_private_protocol_error; return 1; }
  # shellcheck disable=SC2034 # LAB_UPDATE_REASON est lu par _update_note (lib/update.sh), dans le même sous-shell.
  LAB_UPDATE_REASON=entitlement
  _update_error "Your Treelab updates ended on $day (UTC). Installed version kept ($LAB_UPDATE_OLD): it keeps working. Run lab subscribe to get new versions."
}
_update_private_refusal() {
  local input="$1" code
  if [ "$LAB_PRIVATE_STATUS" = 402 ]; then _update_private_ended "$input"; return 1; fi
  if ! { { cat "$input"; printf '\n'; } | jq --stream -es 'length==4 and
    ([.[]|select(length==2)|.[0]] | sort==[["error","code"],["error","request_id"]])' \
    >/dev/null 2>&1 &&
  jq -es 'length==1 and (.[0] | type=="object" and keys==["error"] and
    (.error | type=="object" and keys==["code","request_id"] and (.code|type=="string") and
      (.request_id|type=="string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"))))' \
    "$input" >/dev/null 2>&1; }; then _update_private_protocol_error; return 1; fi
  code="$(jq -r .error.code "$input")"
  # shellcheck disable=SC2034 # LAB_UPDATE_REASON est lu par _update_note (lib/update.sh), dans le même sous-shell.
  # Raison du contrat d'échec : licence pour un refus d'identité, network pour un service saturé, source sinon.
  case "$LAB_PRIVATE_STATUS" in 401|403) LAB_UPDATE_REASON=licence ;; 429|503) LAB_UPDATE_REASON=network ;; *) LAB_UPDATE_REASON=source ;; esac
  case "$LAB_PRIVATE_STATUS:$code" in
    401:AUTH_REQUIRED|401:CREDENTIALS_INVALID)
      _update_error 'Local license not recognized. Installation kept; restore the valid credentials of this installation or contact support.' ;;
    403:LICENSE_REFUSED)
      _update_error 'License refused. Installation kept; contact support.' ;;
    403:ACTIVATION_REPLACED)
      _update_error 'This activation was replaced. Installation kept; use the active installation or contact support.' ;;
    403:MACHINE_MISMATCH)
      _update_error 'License tied to another installation. Installation kept; restore the file that belongs to this Mac.' ;;
    429:RATE_LIMITED)
      _update_error 'Service temporarily limited. Installation kept; wait before running treelab update again.' ;;
    503:SERVICE_UNAVAILABLE|503:RELEASE_UNAVAILABLE)
      _update_error 'Service unavailable. Installation kept; try again later with treelab update.' ;;
    404:RELEASE_NOT_FOUND|409:RELEASE_MISMATCH)
      _update_error 'Distribution unavailable or inconsistent. Installation kept; try again later or contact support.' ;;
    400:INVALID_REQUEST|426:CONTRACT_UNSUPPORTED|*) _update_private_protocol_error ;;
  esac
  return 1
}
_update_private_api() {
  local method="$1" path="$2" output="$3"
  _update_private_config "$method" "$path" "$temp/request.conf" || return 1
  _update_private_fetch "$temp/request.conf" "$output" 16384 15 || { _update_private_network_error; return 1; }
  case "$LAB_PRIVATE_STATUS" in 3??) _update_private_network_error; return 1 ;; esac
  _update_private_headers || { _update_private_protocol_error; return 1; }
  [ "$LAB_PRIVATE_STATUS" = 200 ] || { _update_private_refusal "$output"; return 1; }
}
_update_private_latest() {
  local input="$1"
  _update_private_flat "$input" 3 &&
    jq -es --arg origin "$LAB_PRIVATE_API" '
      length==1 and (.[0] | type=="object" and keys==["sha256","url","version"] and
        (.version|type=="string" and test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$")) and
        .url==($origin+"/api/download/treelab-"+.version+".tgz") and
        (.sha256|type=="string" and test("^[0-9a-f]{64}$")))' "$input" >/dev/null 2>&1 || return 1
  _update_catalogue "$input"
}
_update_private_catalogue() {
  _update_private_trust || {
    _update_error 'Private distribution not configured in this version. Installation kept; keep this version and contact support.'; return 1;
  }
  _update_private_api POST /api/validate "$temp/validate.json" || return 1
  if ! { _update_private_flat "$temp/validate.json" 3 &&
    jq -es --slurpfile license "$temp/license" '
      length==1 and (.[0] | type=="object" and keys==["activation_id","machine_id","status"] and
      .status=="valid" and .activation_id==$license[0].activation_id and .machine_id==$license[0].machine_id)' \
      "$temp/validate.json" >/dev/null 2>&1; }; then _update_private_protocol_error; return 1; fi
  _update_private_entitlement
  _update_private_api GET /api/latest "$temp/latest.json" || return 1
  _update_private_latest "$temp/latest.json" || { _update_private_protocol_error; return 1; }
}
# Lecture des droits (contrat 1.2.0) après un validate réussi, jamais bloquante : panne, refus (400 d'un service sans la route,
# 404, 503…), en-têtes ou forme fausse laissent la mise à jour et le cache tels quels, sans un mot. La réponse attend dans $temp :
# seul un update réussi l'écrit (_update_private_entitlement_commit), un refus ne change rien sous HOME.
_update_private_entitlement() {
  local started="$SECONDS"
  rm -f "$temp/entitlement.json"
  _update_private_config GET /api/entitlement "$temp/entitlement.conf" 2>/dev/null &&
    _update_private_fetch "$temp/entitlement.conf" "$temp/entitlement.body" 1024 5 2>/dev/null &&
    [ "$LAB_PRIVATE_STATUS" = 200 ] && _update_private_headers 2>/dev/null &&
    _update_private_flat "$temp/entitlement.body" 3 &&
    jq -es 'length==1 and (.[0] | type=="object" and keys==["entitled_until","plan","renews"] and
      (.plan=="trial" or .plan=="subscription") and (.renews|type=="boolean") and
      (.entitled_until==null or (.entitled_until|type=="number" and floor==. and .>0 and .<253402300800)))' \
      "$temp/entitlement.body" >/dev/null 2>&1 &&
    mv "$temp/entitlement.body" "$temp/entitlement.json" || true
  rm -f "$temp/entitlement.conf" "$temp/entitlement.body"
  # le temps de cette lecture (5 s au plus) est rendu au budget : elle ne raccourcit jamais latest ni le téléchargement (revue)
  LAB_PRIVATE_DEADLINE=$((LAB_PRIVATE_DEADLINE + SECONDS - started))
  return 0
}
_update_private_entitlement_commit() {
  [ -f "$temp/entitlement.json" ] || return 0
  declare -F entitlement_write >/dev/null || . "$LAB_ROOT/lib/entitlement.sh" 2>/dev/null || return 0
  entitlement_write "$temp/entitlement.json" || true
  return 0
}
_update_private_grant() {
  local input="$1"
  _update_private_flat "$input" 5 || return 1
  # Les paramètres S3 sont une grammaire fermée : aucun jeton de licence,
  # identifiant machine ou cible arbitraire ne peut être envoyé en query à R2.
  jq -es --arg version "$LAB_UPDATE_VERSION" --arg sha "$LAB_UPDATE_SHA" \
    --arg path "$LAB_PRIVATE_R2/$LAB_PRIVATE_BUCKET/$LAB_PRIVATE_PREFIX/treelab-$LAB_UPDATE_VERSION.tgz" '
    def uint: type=="number" and floor==. and .>0 and .<1000000000000;
    length==1 and (.[0] | type=="object" and keys==["expires_at","server_time","sha256","url","version"] and
      .version==$version and .sha256==$sha and (.server_time|uint) and (.expires_at|uint) and
      .expires_at==(.server_time+300) and
      (.url|type=="string" and length<=8192 and startswith($path+"?") and
        (.[($path|length)+1:] | split("&") | map(split("=")) |
          length>=6 and length<=8 and all(length==2) and
          (map(.[0])|length==(unique|length)) and
          (map({key:.[0],value:.[1]})|from_entries |
            (keys-["X-Amz-Algorithm","X-Amz-Credential","X-Amz-Date","X-Amz-Expires","X-Amz-SignedHeaders","X-Amz-Signature","X-Amz-Content-Sha256","x-id"]|length==0) and
            .["X-Amz-Algorithm"]=="AWS4-HMAC-SHA256" and .["X-Amz-Expires"]=="300" and .["X-Amz-SignedHeaders"]=="host" and
            (.["X-Amz-Credential"]|type=="string" and test("^[A-Za-z0-9]{16,128}%2[Ff][0-9]{8}%2[Ff]auto%2[Ff]s3%2[Ff]aws4_request$")) and
            (.["X-Amz-Date"]|type=="string" and test("^[0-9]{8}T[0-9]{6}Z$")) and
            (.["X-Amz-Signature"]|type=="string" and test("^[0-9a-f]{64}$")) and
            ((has("X-Amz-Content-Sha256")|not) or .["X-Amz-Content-Sha256"]=="UNSIGNED-PAYLOAD") and
            ((has("x-id")|not) or .["x-id"]=="GetObject")))))
  ' "$input" >/dev/null 2>&1
}

_update_private_download() {
  local attempt
  for attempt in 1 2; do
    _update_private_api GET "/api/download/treelab-$LAB_UPDATE_VERSION.tgz?sha256=$LAB_UPDATE_SHA" "$temp/grant.json" || return 1
    _update_private_grant "$temp/grant.json" || { _update_private_protocol_error; return 1; }
    # jq émet le secret dans le fichier, pas dans les arguments d’un processus.
    jq -r '"url = \""+.url+"\"\nrequest = \"GET\""' "$temp/grant.json" >"$temp/download.conf" || return 1
    _update_private_fetch "$temp/download.conf" "$temp/release.tgz" 134217728 30 || { _update_private_network_error; return 1; }
    case "$LAB_PRIVATE_STATUS" in
      200) return 0 ;;
      401|403) [ "$attempt" = 1 ] && continue
        _update_error 'Temporary access to the archive refused. Installation kept; run treelab update again to request new access.'; return 1 ;;
      *) _update_private_network_error; return 1 ;;
    esac
  done
}
