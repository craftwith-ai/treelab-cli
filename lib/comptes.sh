# shellcheck shell=bash
# comptes.sh — rotation des comptes Claude (lot 02 de cmux-pro). Le compte n° 1 est le /login de l'utilisateur (« principal »,
# sans jeton) ; les suivants sont des jetons de claude setup-token rangés dans le trousseau macOS, dans l'ordre d'ajout.
# Aucun jeton n'est jamais écrit dans un fichier, passé en argument (ps le verrait) ni imprimé : seuls les étiquettes
# ($LAB_HOME/comptes), les identités du /login ($LAB_HOME/comptes-identites), les notes ($LAB_STATE/comptes-epuises), les relevés
# d'usage ($LAB_STATE/comptes-usage) et les essais courts ($LAB_STATE/comptes-essais) touchent le disque.
# Couloir comptes-complets, lot 01 : la note vise le compte réellement connecté, pas celui que lab croit actif.
COMPTE_SERVICE=treelab-claude
COMPTE_PRINCIPAL=principal
COMPTE_FENETRE_S=18000 # une limite des 5 h ne se lève jamais à plus de 5 h
COMPTE_REPLI_S=3600    # message de limite sans heure lisible : nouvelle vérification une heure plus tard
COMPTE_MARGE_S=60      # l'attente dépasse l'heure annoncée d'une minute
COMPTE_RELEVE_MARGE_S=120 # un relevé ne contredit une note que s'il la suit de deux minutes (statusline qui redessine l'ancien JSON)
COMPTE_ESSAI_S=600     # au plus un essai court par compte toutes les 10 minutes : jamais de boucle limite → essai → limite
COMPTE_VERIF_S=600     # un jeton accepté par un vrai appel n'est pas revérifié pendant 10 minutes (lot 02 de comptes-complets)
COMPTE_REFUS_S=604800  # jeton refusé (401) : compte écarté 7 jours, ou jusqu'à lab account free, remove puis add
COMPTE_IMMOBILE_S=120  # une session arrêtée n'est remplacée que si sa conversation n'a pas bougé depuis 2 minutes
# shellcheck disable=SC2034 # lu par bin/lab (lab launch --resume)
COMPTE_PROMPT="continue: the conversation resumes on another Claude account after a usage limit — carry on where you stopped."

comptes_file() { printf '%s/comptes\n' "$LAB_HOME"; }
comptes_identites_file() { printf '%s/comptes-identites\n' "$LAB_HOME"; }
comptes_epuises_file() { printf '%s/comptes-epuises\n' "$LAB_STATE"; }
comptes_usage_file() { printf '%s/comptes-usage\n' "$LAB_STATE"; }
comptes_essais_file() { printf '%s/comptes-essais\n' "$LAB_STATE"; }
comptes_verifs_file() { printf '%s/comptes-verifs\n' "$LAB_STATE"; }
comptes_attente_dir() { printf '%s/comptes-attente\n' "$LAB_STATE"; }   # un fichier par onglet en attente, nommé par son pid
compte_conversation_ok() { (LC_ALL=C; case "$1" in ''|-*|*[!A-Za-z0-9-]*) exit 1 ;; esac; [ "${#1}" -le 64 ]); }   # identifiant de session Claude
compte_label_ok() { (LC_ALL=C; case "$1" in ''|*[!A-Za-z0-9._-]*|.*|-*) exit 1 ;; esac; [ "${#1}" -le 24 ]); }
compte_email_ok() { (LC_ALL=C; case "$1" in *[!A-Za-z0-9._%+@-]*|*@*@*|@*|*@) exit 1 ;; *@*.*) ;; *) exit 1 ;; esac; [ "${#1}" -le 254 ]); }
# comptes_jetons → les étiquettes des comptes à jeton, dans l'ordre d'ajout
comptes_jetons() { [ -f "$(comptes_file)" ] || return 0; grep -E '^[A-Za-z0-9._-]+$' "$(comptes_file)" || true; }
# comptes_actifs : la rotation n'existe que si au moins un jeton est rangé — sinon tout reste comme avant
comptes_actifs() { [ -n "$(comptes_jetons)" ]; }
comptes_liste() { printf '%s\n' "$COMPTE_PRINCIPAL"; comptes_jetons; }
compte_connu() { local liste; liste="$(comptes_liste)" && grep -qxF "$1" <<<"$liste"; }

compte_now() { # → epoch ; LAB_NOW (AAAA-MM-JJTHH:MM:SSZ) fixe l'horloge des tests
  if [ -n "${LAB_NOW:-}" ]; then
    perl -MTime::Local -e '$ARGV[0] =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)Z$/ or exit 1; print timegm($6,$5,$4,$3,$2-1,$1), "\n"' "$LAB_NOW"
  else date +%s; fi
}
compte_heure() { perl -MPOSIX -e 'print strftime("%d/%m %H:%M", localtime($ARGV[0])), "\n"' "$1"; }   # <epoch> → « 13/10 09:00 »
# fichier_remplace <fichier> : l'entrée standard remplace le fichier d'un coup (mktemp + mv, mode 600) — jamais un fichier à moitié écrit.
# Coupé par TERM, INT ou HUP, le fichier temporaire part avec lui : Claude Code 2.1.331 tue tout le groupe de la statusline à chaque
# rafraîchissement, relevé lancé en arrière-plan compris (111 restes sur le poste, lot 04 de charge-processeur). Toujours appelée au
# bout d'un tuyau, donc dans un sous-shell : le piège ne remplace jamais celui de l'appelant. Un arrêt par KILL laisse son reste,
# balayé au relevé complet suivant (compte_restes_balayer).
fichier_remplace() {
  local tmp=""
  trap 'rm -f "$tmp"; exit 1' TERM INT HUP
  [ -d "${1%/*}" ] || mkdir -p "${1%/*}" || return 1
  tmp="$(umask 077; mktemp "$1.XXXXXX")" || return 1
  if cat >"$tmp" && mv "$tmp" "$1"; then return 0; fi
  rm -f "$tmp"; return 1
}
# compte_restes_balayer : les restes de fichier_remplace (<fichier>.XXXXXX, mktemp) des fichiers de comptes de plus de 10 minutes —
# leur écriture a été tuée ; plus jeune, une écriture peut être en cours. Jamais un fichier d'un autre nom.
COMPTE_RESTE_MIN=10
compte_restes_balayer() {
  local x='[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]'
  # -H : un dossier d'état rangé derrière un lien symbolique est parcouru (revue du lot)
  { find -H "$LAB_STATE" "$LAB_HOME" -maxdepth 1 -type f -name "comptes*.$x" -mmin "+$COMPTE_RESTE_MIN"
    [ ! -d "$(comptes_badges_dir)" ] || find -H "$(comptes_badges_dir)" -maxdepth 1 -type f -name "*.$x" -mmin "+$COMPTE_RESTE_MIN"
  } 2>/dev/null | while IFS= read -r f; do rm -f "$f"; done
}

# ---------- identité réelle : l'étiquette du compte dont Claude se sert vraiment ----------
# compte_email_login → l'e-mail du /login de ce poste. Mesuré (lot 01 de comptes-complets) : oauthAccount.emailAddress de .claude.json
# se lit en 10 ms et suit chaque /login ; claude auth status (300 ms) en repli. Sous un jeton setup-token, ni l'un ni l'autre ne
# donne l'e-mail du jeton (auth status : authMethod oauth_token sans email ; profil OAuth : 403, scope user:profile absent).
compte_email_login() {
  local f="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json" e=""
  [ ! -f "$f" ] || e="$(jq -r '.oauthAccount.emailAddress // empty' "$f" 2>/dev/null)" || e=""
  # COMPTE_SANS_AUTH=1 (lab account record, à chaque rafraîchissement de la statusline) : jamais les 300 ms de claude auth status
  if [ -z "$e" ] && [ "${COMPTE_SANS_AUTH:-0}" != 1 ] && command -v claude >/dev/null 2>&1; then
    e="$(env -u CLAUDE_CODE_OAUTH_TOKEN claude auth status --json 2>/dev/null </dev/null | jq -r '.email // empty' 2>/dev/null)" || e=""
  fi
  compte_email_ok "$e" && printf '%s\n' "$e"
}
compte_identite_label() { # <e-mail> → l'étiquette reliée par lab account identify, rien sinon
  awk -F'\t' -v e="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" 'tolower($2) == e {print $1; exit}' "$(comptes_identites_file)" 2>/dev/null || true
}
compte_identite_de() { awk -F'\t' -v l="$1" '$1 == l {print $2; exit}' "$(comptes_identites_file)" 2>/dev/null || true; }   # <étiquette> → e-mail
compte_identite_courte() { local e; e="$(compte_identite_de "$1")"; [ -n "$e" ] || return 1; e="${e%%@*}"; printf '%s\n' "${e:0:10}"; }
# compte_identite_ecrire <étiquette> <e-mail> : un e-mail relié à une seule étiquette, une étiquette à un seul e-mail
compte_identite_ecrire() {
  local f; f="$(comptes_identites_file)"
  { awk -F'\t' -v l="$1" -v e="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" '$1 != l && tolower($2) != e' "$f" 2>/dev/null
    printf '%s\t%s\n' "$1" "$2"; } | fichier_remplace "$f"
}
comptes_identifies() { [ -s "$(comptes_identites_file)" ]; }
# compte_reel → l'étiquette du compte réellement connecté. Sous un jeton, lab l'a posé avec son étiquette : LAB_COMPTE fait foi.
# Sans jeton (/login), l'e-mail lu est relié à une étiquette. rc 1 : compte indéterminable ; rc 2 : e-mail sans étiquette.
compte_reel() {
  local e l
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    l="${LAB_COMPTE:-}"
    [ -n "$l" ] && [ "$l" != "$COMPTE_PRINCIPAL" ] && compte_connu "$l" || return 1
    printf '%s\n' "$l"; return 0
  fi
  e="$(compte_email_login)" || return 1
  l="$(compte_identite_label "$e")"
  [ -n "$l" ] && compte_connu "$l" || return 2
  printf '%s\n' "$l"
}

# compte_cle <étiquette> → le compte réel derrière l'étiquette. principal lance le /login, quel qu'il soit : un /login manuel sur
# perso fait de principal un second nom de perso, ses notes et relevés sont ceux de perso (revue du lot 01). Avec son badge,
# principal est son propre compte : la rotation pose ce badge-là (lot 03). Badges en service, le /login du Mac est le badge actif :
# principal sans badge n'emprunte plus ni son usage ni ses notes (lot 05, la note de pro3 du 2026-11-05).
compte_cle() {
  local l
  if [ "$1" = "$COMPTE_PRINCIPAL" ] && [ ! -s "$(comptes_badges_dir)/$1.json" ] && ! compte_badges_servent \
      && l="$(CLAUDE_CODE_OAUTH_TOKEN='' compte_reel 2>/dev/null)"; then printf '%s\n' "$l"
  else printf '%s\n' "$1"; fi
}

# ---------- notes : <étiquette> TAB <échéance> TAB <fenêtre 5h|7d|?> TAB <epoch de la note> ----------
# L'ancien format à deux colonnes (avant ce lot) reste lu, jamais réécrit : sa note est douteuse (compte peut-être mal attribué).
# compte_epuise_jusqua <étiquette> → l'échéance si elle est encore à venir, rien sinon
compte_epuise_jusqua() {
  local now; now="$(compte_now)"
  awk -F'\t' -v l="$1" -v n="$now" '$1 == l && $2 > n {e = $2} END {if (e) print e}' "$(comptes_epuises_file)" 2>/dev/null || true
}
compte_note() { awk -F'\t' -v l="$1" '$1 == l {r = $0} END {if (r) print r}' "$(comptes_epuises_file)" 2>/dev/null || true; }   # dernière ligne
compte_marquer() { # <étiquette> <epoch> [fenêtre]
  local f; f="$(comptes_epuises_file)"; mkdir -p "$(dirname "$f")"
  compte_liberer "$1"; ( umask 077; printf '%s\t%s\t%s\t%s\n' "$1" "$2" "${3:-?}" "$(compte_now)" >>"$f" )
}
compte_liberer() { # <étiquette>
  local f; f="$(comptes_epuises_file)"; [ -f "$f" ] || return 0
  awk -F'\t' -v l="$1" '$1 != l' "$f" | fichier_remplace "$f"
}

# ---------- relevé d'usage : <étiquette> TAB <5h %> TAB <5h reprise> TAB <7d %> TAB <7d reprise> TAB <epoch du relevé> ----------
# compte_relever : le JSON de la statusline sur l'entrée standard (rate_limits.five_hour|seven_day.used_percentage et resets_at, en
# secondes epoch — doc statusline de Claude Code, mesuré au lot 01) rangé pour le compte réel. Muet, toujours rc 0 : il tourne à
# chaque rafraîchissement de la statusline. « - » = valeur absente.
# shellcheck disable=SC2016 # programme jq
COMPTE_RELEVE_JQ='(.rate_limits // empty | [.five_hour.used_percentage, .five_hour.resets_at, .seven_day.used_percentage, .seven_day.resets_at]
    | map(if type == "number" then (. + 0.5 | floor | tostring) else "-" end) | join("\t"))'
compte_relever() {
  local json v; json="$(cat)" || return 0
  v="$(printf '%s' "$json" | jq -r "$COMPTE_RELEVE_JQ" 2>/dev/null)" || v=""
  compte_relever_valeurs "$v"
}
# compte_relever_valeurs <valeurs séparées par des tabulations> [epoch] : la suite du relevé, JSON déjà lu
compte_relever_valeurs() {
  local v="$1" l f
  compte_badge_suivi 1 >/dev/null 2>&1
  l="$(compte_reel 2>/dev/null)" || return 0
  # badges : une fenêtre lancée sur un autre compte garde sa connexion en mémoire après une bascule globale — relevé ambigu, ignoré ;
  # sans LAB_COMPTE (main, claude tapé à la main), toute fenêtre lancée avant le dernier changement de compte du Mac (lot 06)
  if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -n "$(compte_badge_actif)" ]; then
    if [ -n "${LAB_COMPTE:-}" ]; then [ "$(compte_cle "$LAB_COMPTE")" = "$l" ] || return 0
    elif compte_fenetre_ancienne; then return 0; fi
  fi
  case "$v" in ''|-$'\t'-$'\t'-$'\t'-) return 0 ;; esac
  f="$(comptes_usage_file)"
  { awk -F'\t' -v l="$l" '$1 != l' "$f" 2>/dev/null; printf '%s\t%s\t%s\n' "$l" "$v" "${2:-$(compte_now)}"; } | fichier_remplace "$f" || return 0
}
# ---------- chemin court de lab account record (lot 04 de charge-processeur) ----------
# Au plus un relevé complet par minute et par session (session_id du JSON ; sans identifiant lisible, « - » : une fois par minute au
# total). Un seul jq lit la session, l'heure (LAB_NOW des tests compris) et l'usage : un appel écarté coûte lab et ce jq, rien d'autre.
# Mémoire : $LAB_STATE/comptes-releves, « <session> TAB <epoch du dernier relevé complet> », réécrite au relevé complet, sessions de
# plus d'un jour oubliées. LAB_RECORD_GAP_S règle l'écart (60 ; 0 : chaque appel relève, les anciens tests des comptes).
COMPTE_RELEVE_ECART_S="${LAB_RECORD_GAP_S:-60}"
COMPTE_RELEVE_OUBLI_S=86400
comptes_releves_file() { printf '%s/comptes-releves\n' "$LAB_STATE"; }
compte_releve_court() {
  local json="" r sid now v s t last="" f="$LAB_STATE/comptes-releves"
  IFS= read -r -d '' json || :
  # shellcheck disable=SC2016 # programme jq
  r="$(exec jq -r '[(.session_id // "" | tostring), ($ENV.LAB_NOW // "" | if . == "" then now else fromdateiso8601 end | floor | tostring),
    ('"$COMPTE_RELEVE_JQ"' // "")] | join("|")' <<<"$json" 2>/dev/null)" || return 0
  IFS='|' read -r sid now v <<<"$r"
  case "$sid" in ''|-*|*[!A-Za-z0-9-]*) sid=- ;; esac
  [ "${#sid}" -le 64 ] || sid=-
  case "$now" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$COMPTE_RELEVE_ECART_S" != 0 ] && [ -f "$f" ]; then
    while IFS=$'\t' read -r s t; do [ "$s" != "$sid" ] || last="$t"; done <"$f"
    case "$last" in ''|*[!0-9]*) ;; *) [ "$now" -lt "$last" ] || [ $((now - last)) -ge "$COMPTE_RELEVE_ECART_S" ] || return 0 ;; esac
  fi
  # relevé complet : la minute est prise d'abord (un relevé qui échoue ne se relance pas à chaque rafraîchissement), restes balayés
  { awk -F'\t' -v s="$sid" -v n="$now" -v o="$COMPTE_RELEVE_OUBLI_S" '$1 != s && $2 ~ /^[0-9]+$/ && n - $2 < o' "$f" 2>/dev/null
    printf '%s\t%s\n' "$sid" "$now"; } | fichier_remplace "$f" || :
  compte_restes_balayer
  compte_relever_valeurs "$v" "$now"
}
compte_usage() { awk -F'\t' -v l="$1" '$1 == l {r = $0} END {if (r) print r}' "$(comptes_usage_file)" 2>/dev/null || true; }
# compte_releve_bloque <étiquette> → la reprise d'une fenêtre relevée pleine (≥ 100 %) et encore à venir (la plus tardive), rien sinon
compte_releve_bloque() {
  local now; now="$(compte_now)"
  compte_usage "$1" | awk -F'\t' -v n="$now" '{
    if ($2 != "-" && $2 + 0 >= 100 && $3 != "-" && $3 > n) e = $3
    if ($4 != "-" && $4 + 0 >= 100 && $5 != "-" && $5 > n && $5 > e) e = $5
  } END {if (e) print e}'
}
# compte_note_douteuse <étiquette> : rc 0 si la note en cours ne prouve rien — ancien format (compte peut-être mal attribué), ou
# relevé postérieur d'au moins deux minutes qui montre la fenêtre notée sous 100 %
compte_note_douteuse() {
  local note u; note="$(compte_note "$1")"; [ -n "$note" ] || return 1
  u="$(compte_usage "$1")"
  printf '%s\n%s\n' "$note" "$u" | awk -F'\t' -v m="$COMPTE_RELEVE_MARGE_S" '
    NR == 1 {if (NF < 4) {douteux = 1; exit} w = $3; t = $4; if (w == "401") exit; next}   # un jeton refusé ne se réessaie jamais seul
    NR == 2 && NF >= 6 && $6 >= t + m {
      if (w == "5h") douteux = ($2 != "-" && $2 + 0 < 100)
      else if (w == "7d") douteux = ($4 != "-" && $4 + 0 < 100)
      else douteux = ($2 != "-" && $2 + 0 < 100 && $4 != "-" && $4 + 0 < 100)
    } END {exit !douteux}'
}
# compte_releve_accord <étiquette> <échéance> <fenêtre 5h|7d> → « agree » si le relevé de cette fenêtre, encore en cours (reprise à
# venir), a la même reprise à COMPTE_ACCORD_S près ; « contradicts » s'il en a une autre sous 100 % ; rien sinon (pas de relevé
# de cette fenêtre, fenêtre « ? », relevé plein à une autre heure). Une fenêtre de 5 h ou de 7 jours n'a qu'une reprise : une
# limite annoncée à une autre heure n'est pas celle de ce compte (lot 05 : pro3 noté avec l'échéance de perso).
COMPTE_ACCORD_S=1800
compte_releve_accord() {
  local now; now="$(compte_now)"
  compte_usage "$1" | awk -F'\t' -v e="$2" -v w="$3" -v n="$now" -v t="$COMPTE_ACCORD_S" '
    { if (w == "5h") {p = $2; r = $3} else if (w == "7d") {p = $4; r = $5} else exit
      if (p == "-" || r == "-" || r + 0 <= n + 0) exit
      d = r - e; if (d < 0) d = -d
      if (d <= t) print "agree"; else if (p + 0 < 100) print "contradicts" }'
}
# compte_releve_concordant <étiquette exclue> <échéance> <fenêtre> → le seul autre compte dont le relevé, plein, a cette reprise ;
# aucun ou plusieurs → rc 1 (une même heure de reprise seule ne prouve rien : revue du lot 05)
compte_releve_concordant() {
  local l r=""
  while IFS= read -r l; do
    [ "$l" != "$1" ] && [ "$(compte_releve_accord "$l" "$2" "$3")" = agree ] && [ -n "$(compte_releve_bloque "$l")" ] || continue
    [ -z "$r" ] || return 1; r="$l"
  done < <(comptes_liste)
  [ -n "$r" ] && printf '%s\n' "$r"
}
# compte_note_bloque <étiquette> → l'échéance de sa note à venir, sauf si le relevé de son compte la contredit (note ignorée)
compte_note_bloque() {
  local e; e="$(compte_epuise_jusqua "$1")"; [ -n "$e" ] || return 0
  [ "$(compte_releve_accord "$1" "$e" "$(compte_note "$1" | cut -f 3)")" = contradicts ] || printf '%s\n' "$e"
}
# compte_bloque_jusqua <étiquette> → la plus tardive des échéances qui bloquent le compte (note à venir non contredite, fenêtre
# relevée pleine), lues sous l'étiquette et sous le compte réel qu'elle lance (compte_cle)
compte_bloque_jusqua() {
  local k; k="$(compte_cle "$1")"
  { compte_note_bloque "$1"; compte_releve_bloque "$1"
    [ "$k" = "$1" ] || { compte_note_bloque "$k"; compte_releve_bloque "$k"; }; } | sort -n | tail -n 1
}
# compte_etat <étiquette> → « token refused » (note 401 encore à venir), « until 13/10 09:00 » ou « available »
compte_etat() {
  local e; e="$(compte_bloque_jusqua "$1")"
  if [ -z "$e" ]; then printf 'available\n'
  elif [ -n "$(compte_epuise_jusqua "$1")" ] && [ "$(compte_note "$1" | cut -f 3)" = 401 ]; then printf 'token refused\n'
  else printf 'until %s\n' "$(compte_heure "$e")"; fi
}

# compte_libre → le premier compte de la liste lue sur l'entrée standard qui n'est pas bloqué ; aucun → rc 1
compte_libre() {
  local l
  while IFS= read -r l; do [ -n "$l" ] && ! compte_ecarte "$l" && [ -z "$(compte_bloque_jusqua "$l")" ] && { printf '%s\n' "$l"; return 0; }; done
  return 1
}
# ---------- réserve (lot 06) : un compte de dernier recours, pris seulement quand aucun compte normal ne peut servir ----------
comptes_reserve_file() { printf '%s/comptes-reserve\n' "$LAB_STATE"; }
compte_reserve() { grep -qxF "$1" "$(comptes_reserve_file)" 2>/dev/null; }
compte_reserve_ecrire() { # <étiquette> <on|off>
  local f; f="$(comptes_reserve_file)"
  { grep -vxF "$1" "$f" 2>/dev/null || true; [ "$2" != on ] || printf '%s\n' "$1"; } | fichier_remplace "$f"
}
# comptes_groupe <normal|reserve> → les comptes de la liste de ce groupe, dans son ordre
comptes_groupe() {
  local l
  while IFS= read -r l; do
    if compte_reserve "$l"; then [ "$1" != reserve ] || printf '%s\n' "$l"; elif [ "$1" = normal ]; then printf '%s\n' "$l"; fi
  done < <(comptes_liste)
}
# compte_choisir → le compte à prendre : un normal libre, sinon un essai court sur la note douteuse d'un normal, sinon la réserve
# (libre, puis son essai court) — tout de suite, sans attendre (décisions 6 et 7 du lot 06) ; rien → rc 1
compte_choisir() { compte_meilleur_libre || compte_essai || compte_meilleur_libre reserve || compte_essai reserve; }
# compte_meilleur_libre [normal|reserve] → parmi les comptes libres du groupe (normal par défaut), celui dont la reprise des 7 jours
# est la plus proche (on consomme d'abord ce qui sera bientôt rendu) ; reprise inconnue ou passée → après, dans l'ordre de la
# liste. Aucun → rc 1
compte_meilleur_libre() {
  local l i=0 now k u
  now="$(compte_now)"
  l="$(while IFS= read -r l; do
    i=$((i + 1)); ! compte_ecarte "$l" && [ -z "$(compte_bloque_jusqua "$l")" ] || continue
    u="$(compte_usage "$(compte_cle "$l")")"; k="$(printf '%s\n' "$u" | awk -F'\t' -v n="$now" 'NF >= 6 && $5 != "-" && $5 > n {print $5}')"
    printf '%s\t%s\t%s\n' "${k:-99999999999}" "$i" "$l"
  done < <(comptes_groupe "${1:-normal}") | sort -t "$(printf '\t')" -k1,1n -k2,2n | head -n 1 | cut -f 3)"
  [ -n "$l" ] || return 1
  printf '%s\n' "$l"
}
# compte_essai [normal|reserve] [--peek] : tout le groupe est bloqué, mais une note ne prouve rien (douteuse) → un essai court sur
# celle dont l'échéance est la plus proche, sans attendre ; si la limite revient, le hook renote avec la vraie heure. Au plus un
# essai par compte toutes les 10 min. --peek : nomme le compte sans rien enregistrer ni afficher (lab account)
compte_essai() {
  local l k e best="" min="" now f last g=normal peek=0
  for l in "$@"; do if [ "$l" = --peek ]; then peek=1; else g="$l"; fi; done
  now="$(compte_now)"; f="$(comptes_essais_file)"
  while IFS= read -r l; do
    ! compte_ecarte "$l" || continue
    k="$(compte_cle "$l")"
    if [ -n "$(compte_releve_bloque "$k")" ] || ! compte_note_douteuse "$k"; then continue; fi
    last="$(compte_essai_dernier "$l")"
    [ $((now - last)) -ge "$COMPTE_ESSAI_S" ] || continue
    e="$(compte_epuise_jusqua "$k")"; [ -n "$e" ] || e="$(compte_epuise_jusqua "$l")"
    if [ -z "$min" ] || [ "$e" -lt "$min" ]; then min="$e"; best="$l"; fi
  done < <(comptes_groupe "$g")
  [ -n "$best" ] || return 1
  if [ "$peek" = 1 ]; then printf '%s\n' "$best"; return 0; fi
  { awk -F'\t' -v l="$best" '$1 != l' "$f" 2>/dev/null; printf '%s\t%s\n' "$best" "$now"; } | fichier_remplace "$f" || true
  log "Short trial on $best: its limit note"
  log "is not confirmed by its usage."
  printf '%s\n' "$best"
}
# compte_sans_note_recente <session> : rc 0 si cette session est déjà repartie sans note depuis moins de COMPTE_ESSAI_S (le hook
# ne la relance plus : jamais de boucle limite → relance → limite) ; sinon la date est notée, rc 1
compte_sans_note_recente() {
  local f now t; f="$LAB_STATE/comptes-sans-note"; now="$(compte_now)"
  t="$(awk -F'\t' -v s="$1" '$1 == s {t = $2} END {print t + 0}' "$f" 2>/dev/null || echo 0)"
  [ $((now - t)) -ge "$COMPTE_ESSAI_S" ] || return 0
  { awk -F'\t' -v n="$now" -v d="$COMPTE_ESSAI_S" -v s="$1" '$1 != s && $2 + d > n' "$f" 2>/dev/null; printf '%s\t%s\n' "$1" "$now"; } \
    | fichier_remplace "$f" || true
  return 1
}
compte_essai_dernier() { awk -F'\t' -v l="$1" '$1 == l {t = $2} END {print t + 0}' "$(comptes_essais_file)" 2>/dev/null || echo 0; }
# compte_essai_prochain → l'heure la plus proche où un essai court redevient permis (garde de 10 min), rien si aucun n'attend
compte_essai_prochain() {
  local l k t min=""
  while IFS= read -r l; do
    ! compte_ecarte "$l" || continue
    k="$(compte_cle "$l")"
    if [ -n "$(compte_releve_bloque "$k")" ] || ! compte_note_douteuse "$k"; then continue; fi
    t=$(( $(compte_essai_dernier "$l") + COMPTE_ESSAI_S ))
    if [ -z "$min" ] || [ "$t" -lt "$min" ]; then min="$t"; fi
  done < <(comptes_liste)
  printf '%s\n' "$min"
}
# compte_apres <étiquette> → le premier disponible après elle dans la rotation, elle exclue ; la réserve en dernier (lot 06)
compte_apres() {
  local o l
  o="$(comptes_liste | awk -v c="$1" '{a[NR] = $0; if ($0 == c) k = NR} END {for (i = 1; i < NR; i++) print a[(k + i - 1) % NR + 1]; if (!k) print a[NR]}')"
  { while IFS= read -r l; do compte_reserve "$l" || printf '%s\n' "$l"; done <<<"$o"
    while IFS= read -r l; do ! compte_reserve "$l" || printf '%s\n' "$l"; done <<<"$o"; } | compte_libre
}
compte_reprise_min() { # → l'échéance la plus proche parmi les comptes connus encore bloqués (un compte écarté n'est jamais attendu)
  local l e min=""
  while IFS= read -r l; do
    ! compte_ecarte "$l" || continue
    e="$(compte_bloque_jusqua "$l")"; [ -n "$e" ] || continue
    if [ -z "$min" ] || [ "$e" -lt "$min" ]; then min="$e"; fi
  done < <(comptes_liste)
  printf '%s\n' "$min"
}
# compte_usage_lignes <étiquette> → l'usage relevé en lignes de 40 colonnes au plus : « 5h 23% → 19/10 14:00 », « 7d … »,
# « read 3 min ago » ; rien de relevé → « usage unknown »
compte_usage_lignes() {
  local u now p r w a; u="$(compte_usage "$(compte_cle "$1")")"; now="$(compte_now)"
  if [ -z "$u" ]; then printf 'usage unknown\n'; return 0; fi
  for w in 5h 7d; do
    if [ "$w" = 5h ]; then p="$(cut -f 2 <<<"$u")"; r="$(cut -f 3 <<<"$u")"; else p="$(cut -f 4 <<<"$u")"; r="$(cut -f 5 <<<"$u")"; fi
    if [ "$p" = - ]; then printf '%s unknown\n' "$w"
    elif [ "$r" = - ] || [ "$r" -le "$now" ]; then printf '%s %s%% (reset passed)\n' "$w" "$p"
    else printf '%s %s%% → %s\n' "$w" "$p" "$(compte_heure "$r")"; fi
  done
  a=$(( (now - $(cut -f 6 <<<"$u")) / 60 ))
  if [ "$a" -lt 60 ]; then printf 'read %s min ago\n' "$a"; else printf 'read %s h ago\n' $((a / 60)); fi
}

# ---------- trousseau : le jeton ne passe que par l'entrée standard et les variables ----------
compte_jeton() { security find-generic-password -s "$COMPTE_SERVICE" -a "$1" -w 2>/dev/null; }
compte_ranger() { # <étiquette> ; jeton sur l'entrée standard : security -i lit ses commandes sur stdin, jamais en argument
  local tok; IFS= read -r tok || true
  compte_jeton_ok "$tok" || return 1   # security -i découpe sa ligne en mots : rien d'autre qu'un jeton bien formé n'y entre
  printf 'add-generic-password -U -s %s -a %s -w %s\n' "$COMPTE_SERVICE" "$1" "$tok" | security -i >/dev/null 2>&1 || return 1
  [ "$(compte_jeton "$1")" = "$tok" ]
}
compte_effacer() { security delete-generic-password -s "$COMPTE_SERVICE" -a "$1" >/dev/null 2>&1; }
compte_jeton_ok() { (LC_ALL=C; case "$1" in sk-ant-*) ;; *) exit 1 ;; esac; case "$1" in *[!A-Za-z0-9_-]*) exit 1 ;; esac; [ "${#1}" -ge 20 ]); }

# ---------- badges : la vraie connexion de chaque compte, posée pour tout le Mac (lot 03 de comptes-complets) ----------
# Claude Code 2.1 range sa connexion dans l'entrée « Claude Code-credentials » du compte macOS (claudeAiOauth, designOauth propres au
# compte ; mcpOAuth commun à la machine) et l'identité dans oauthAccount de ~/.claude.json. Un badge = {claudeAiOauth, designOauth}
# au trousseau (service treelab-claude-badge, compte = étiquette) + oauthAccount dans $LAB_STATE/comptes-badges/<étiquette>.json.
# Mesuré le 2026-10-29 : security -i coupe sa ligne vers 4 Ko (valeur ≤ 4036 octets) et -w lu sur l'entrée standard tronque à 128 :
# le JSON passe échappé entre guillemets, par l'entrée standard, jamais en argument ; au-delà de COMPTE_LIGNE_MAX, refus.
COMPTE_BADGE_SERVICE=treelab-claude-badge
COMPTE_CLAUDE_SERVICE="Claude Code-credentials"
COMPTE_LIGNE_MAX=3900
comptes_badges_dir() { printf '%s/comptes-badges\n' "$LAB_STATE"; }
compte_badge_actif_file() { printf '%s/comptes-badge-actif\n' "$LAB_STATE"; }
compte_badge_actif() { cat "$(compte_badge_actif_file)" 2>/dev/null || true; }
# compte_actif_ecrire <étiquette> : le badge actif ; un autre compte que le précédent note l'heure du changement (lot 06)
compte_actif_ecrire() {
  local avant; avant="$(compte_badge_actif)"
  printf '%s\n' "$1" | fichier_remplace "$(compte_badge_actif_file)" || return 1
  [ "$avant" = "$1" ] || compte_now | fichier_remplace "$(compte_change_file)" || true
}
# Incident du 2026-11-05 : après un /login sur principal, des fenêtres restées sur pro3 (connexion gardée en mémoire) rangeaient leur
# usage plein sous principal, et 23 onglets attendaient le 10/11. Une fenêtre lancée avant le dernier changement de compte du Mac
# (badge posé pour un autre compte, /login adopté) n'est plus crue sur son compte : ni relevé ni note sous le compte du Mac.
compte_change_file() { printf '%s/change\n' "$(comptes_badges_dir)"; }
compte_change_dernier() { # → l'heure du dernier changement de compte du Mac, rien si aucun n'est noté
  { cat "$(compte_change_file)" "$(compte_adopte_file)" 2>/dev/null || true; } | awk '/^[0-9]+$/ && $1 > m {m = $1} END {if (m) print m}'
}
# compte_fenetre_depuis → l'heure du lancement de la fenêtre Claude qui appelle : LAB_COMPTE_DEPUIS (posé par compte_appliquer),
# sinon l'âge du claude le plus proche parmi les ancêtres (ps -o etime=) ; rien si aucun claude n'est trouvé
compte_fenetre_depuis() {
  local p="$PPID" n=0 e
  if [ -n "${LAB_COMPTE_DEPUIS:-}" ]; then printf '%s\n' "$LAB_COMPTE_DEPUIS"; return 0; fi
  while [[ "$p" =~ ^[1-9][0-9]*$ ]] && [ "$p" != 1 ] && [ "$n" -lt 12 ]; do
    case "$(basename -- "$(ps -o comm= -p "$p" 2>/dev/null)")" in
      claude|claude-code)
        e="$(ps -o etime= -p "$p" 2>/dev/null | perl -ne 's/\s//g; my $d = s/^(\d+)-// ? $1 : 0; my @t = split /:/; unshift @t, 0 while @t < 3; print $d * 86400 + $t[0] * 3600 + $t[1] * 60 + $t[2] if /^[\d:]+$/')" || return 0
        [ -n "$e" ] && printf '%s\n' $(( $(compte_now) - e )); return 0 ;;
    esac
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"; n=$((n + 1))
  done
}
# compte_fenetre_ancienne : rc 0 si les badges servent et que la fenêtre a été lancée avant le dernier changement de compte du Mac
compte_fenetre_ancienne() {
  local c d; compte_badges_servent || return 1
  c="$(compte_change_dernier)"; [ -n "$c" ] || return 1
  d="$(compte_fenetre_depuis)"; [ -n "$d" ] || return 1
  [ "$d" -lt "$c" ]
}
compte_badge_present() { [ -s "$(comptes_badges_dir)/$1.json" ] && security find-generic-password -s "$COMPTE_BADGE_SERVICE" -a "$1" >/dev/null 2>&1; }
# état d'un badge (lot 05) : <étiquette> TAB <alive|dead|untested> TAB <epoch> — alive : un vrai appel a répondu après la pose ;
# dead : 401 sur la connexion posée (annulée) ; untested : jamais testé, ou appel sans réponse lisible. Absent = untested.
compte_badge_etat_file() { printf '%s/etat\n' "$(comptes_badges_dir)"; }
compte_badge_etat() { local s; s="$(awk -F'\t' -v l="$1" '$1 == l {s = $2} END {print s}' "$(compte_badge_etat_file)" 2>/dev/null)"; printf '%s\n' "${s:-untested}"; }
compte_badge_noter() { # <étiquette> <alive|dead|untested>
  local f; f="$(compte_badge_etat_file)"
  { awk -F'\t' -v l="$1" '$1 != l' "$f" 2>/dev/null; printf '%s\t%s\t%s\n' "$1" "$2" "$(compte_now)"; } | fichier_remplace "$f"
}
# compte_badges_servent : un badge actif est noté — la connexion du Mac est celle d'un badge, pas un /login quelconque
compte_badges_servent() { compte_badges_possibles && [ -n "$(compte_badge_actif)" ]; }
# compte_ecarte <étiquette> : rc 0 si la rotation ne doit jamais choisir ce compte — badge mort, badge actif noté ou non (son jeton
# ne sert jamais de repli : tout le Mac reste sur un compte qui marche, décision 3 du lot 05 ; sinon la pose refusée recommencerait
# sans fin, revue du lot 05), ou principal sans badge quand les badges servent (il tournerait en réalité sur le badge actif)
compte_ecarte() {
  compte_badges_possibles || return 1
  if [ -s "$(comptes_badges_dir)/$1.json" ]; then [ "$(compte_badge_etat "$1")" = dead ]; return; fi
  [ "$1" = "$COMPTE_PRINCIPAL" ] && compte_badges_servent
}
# compte_adopte_depuis <epoch du lancement> : rc 0 si un /login a été adopté comme badge depuis ce lancement (ou lancement inconnu
# et une adoption notée) — la connexion gardée en mémoire par la fenêtre n'est plus sûre
compte_adopte_file() { printf '%s/adopte\n' "$(comptes_badges_dir)"; }
compte_adopte_depuis() {
  local a; a="$(cat "$(compte_adopte_file)" 2>/dev/null)" || return 1
  [ -n "$a" ] || return 1
  [ -z "${1:-}" ] || [ "$a" -ge "$1" ]
}
compte_claude_acct() { printf '%s\n' "${USER:-$(id -un)}"; }   # Claude Code nomme l'entrée d'après l'utilisateur macOS
# un dossier de réglages à part (CLAUDE_CONFIG_DIR) a sa propre entrée de trousseau : le badge ne vise que la connexion globale
compte_badges_possibles() { [ -z "${CLAUDE_CONFIG_DIR:-}" ]; }
compte_trousseau_lire() { security find-generic-password -s "$1" -a "$2" -w 2>/dev/null; }   # <service> <compte> → la valeur
compte_trousseau_ecrire() { # <service> <compte> ; JSON sur l'entrée standard, relu après écriture
  local v q; v="$(jq -c . 2>/dev/null)" && [ -n "$v" ] || return 1
  q="$(printf '%s' "$v" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  [ "${#q}" -le "$COMPTE_LIGNE_MAX" ] || { warn "connection too long for the keychain line (${#q} > $COMPTE_LIGNE_MAX bytes): nothing written"; return 1; }
  printf 'add-generic-password -U -s "%s" -a "%s" -w "%s"\n' "$1" "$2" "$q" | security -i >/dev/null 2>&1 || return 1
  [ "$(compte_trousseau_lire "$1" "$2" | jq -c . 2>/dev/null)" = "$v" ]
}
# verrou des badges : deux poses mêlées rangeraient la connexion d'un compte sous l'étiquette d'un autre. Un verrou laissé par un
# processus mort est repris ; au-delà de 10 s d'attente, refus.
compte_badge_verrouiller() { # [essais de 0,1 s, 100]
  local d i=0 p n="${1:-100}"; d="$LAB_STATE/comptes-badge.lock"; mkdir -p "$LAB_STATE"
  until mkdir "$d" 2>/dev/null; do
    p="$(cat "$d/pid" 2>/dev/null)" || p=""
    # pid mort, ou absent depuis plus de 5 s (processus tué entre mkdir et l'écriture du pid) : verrou repris
    if { [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; } || { [ -z "$p" ] && [ "$(perl -e 'print time - (stat shift)[9]' "$d" 2>/dev/null || echo 0)" -gt 5 ]; }; then
      rm -f "$d/pid"; rmdir "$d" 2>/dev/null || true; continue
    fi
    i=$((i + 1)); [ "$i" -lt "$n" ] || return 1; sleep 0.1
  done
  printf '%s\n' "$$" >"$d/pid"
}
compte_badge_deverrouiller() { rm -f "$LAB_STATE/comptes-badge.lock/pid"; rmdir "$LAB_STATE/comptes-badge.lock" 2>/dev/null || true; }
# compte_badge_suivi [essais] : compte_badge_suivre sous le verrou, jamais bloquant pour l'appelant
compte_badge_suivi() { compte_badge_verrouiller "${1:-100}" || return 0; compte_badge_suivre || true; compte_badge_deverrouiller; }
# Un badge n'est frais qu'à sa dernière sauvegarde : Claude renouvelle la connexion (l'ancien jeton meurt) et un /login l'écrase.
# Mesuré le 2026-11-03 : badge de perso rangé le 29/10, perso utilisé depuis, /login sur pro3 → « OAuth session expired and could
# not be refreshed ». La statusline (lab account record) suit donc chaque renouvellement. L'identité d'une connexion se lit par l'API
# de profil, jamais dans ~/.claude.json seul : une fenêtre ouverte sur un autre compte peut réécrire la connexion sans le toucher.
COMPTE_PROFIL_URL=https://api.anthropic.com/api/oauth/profile
# <empreinte du jeton de renouvellement> TAB <e-mail vérifié, relié ou non | « - » : profil illisible> TAB <epoch de la lecture>
compte_badge_vu_file() { printf '%s/vu\n' "$(comptes_badges_dir)"; }
COMPTE_PROFIL_REESSAI_S=60   # profil illisible : nouvel appel au plus une fois par minute
compte_connexion() { compte_trousseau_lire "$COMPTE_CLAUDE_SERVICE" "$(compte_claude_acct)"; }
compte_connexion_complete() { printf '%s' "$1" | jq -e '.claudeAiOauth.refreshToken | strings' >/dev/null 2>&1; }
compte_empreinte_lue() { local c; c="$(cat)"; [ -n "$c" ] && compte_connexion_complete "$c" && compte_empreinte "$c"; }   # connexion sur stdin
compte_empreinte() { printf '%s' "$1" | jq -r '.claudeAiOauth.refreshToken // empty' | cksum | tr -c '0-9\n' _; }
# compte_connexion_email <connexion> → l'e-mail de son compte (API de profil ; en-tête passé à curl par l'entrée standard)
compte_connexion_email() {
  local tok e
  tok="$(printf '%s' "$1" | jq -r '.claudeAiOauth.accessToken // empty')" || return 1
  (LC_ALL=C; case "$tok" in ''|*[!A-Za-z0-9._-]*) exit 1 ;; esac) || return 1
  e="$(printf 'header = "Authorization: Bearer %s"\nheader = "anthropic-beta: oauth-2025-04-20"\n' "$tok" \
    | "${LAB_PROFILE_CURL:-curl}" -sf -m 10 -K - "$COMPTE_PROFIL_URL" 2>/dev/null | jq -r '.account.email // empty' 2>/dev/null)" || return 1
  compte_email_ok "$e" && printf '%s\n' "$e"
}
# compte_badge_ranger <étiquette> <connexion> <e-mail vérifié> : la connexion devient le badge de l'étiquette (empreinte notée). Si
# ~/.claude.json porte la même identité, elle est rangée aussi et le badge devient actif (rc 0) ; sinon rc 2 : connexion d'un
# compte sous l'identité d'un autre, rien d'actif changé.
compte_badge_ranger() {
  local l="$1" cur="$2" e="$3" acc
  printf '%s' "$cur" | jq -c '{claudeAiOauth} + (if .designOauth then {designOauth} else {} end)' \
    | compte_trousseau_ecrire "$COMPTE_BADGE_SERVICE" "$l" || return 1
  # une nouvelle connexion remplace la morte : le badge redevient « untested » (lot 05)
  [ "$(compte_badge_etat "$l")" != dead ] || compte_badge_noter "$l" untested || true
  printf '%s\t%s\t%s\n' "$(compte_empreinte "$cur")" "$e" "$(compte_now)" | fichier_remplace "$(compte_badge_vu_file)" || return 1
  acc="$(compte_identite_json "$e")" || return 2
  printf '%s\n' "$acc" | fichier_remplace "$(comptes_badges_dir)/$l.json" || return 1
  compte_actif_ecrire "$l"
}
compte_identite_json() { # <e-mail> → oauthAccount de ~/.claude.json s'il porte cet e-mail
  jq -ce --arg e "$1" '.oauthAccount | objects | select((.emailAddress // "" | ascii_downcase) == ($e | ascii_downcase))' "$HOME/.claude.json" 2>/dev/null
}
# compte_badge_suivre : range la connexion posée sous le compte qu'elle sert vraiment — jeton renouvelé, ou /login tapé dans une
# session (badge actif changé : ADOPTED=). Connexion inchangée depuis sa dernière sauvegarde : aucun appel. Seulement quand les
# badges servent déjà (un badge actif noté). rc 0 : rangée ou déjà rangée ; 1 : rien à ranger (badges inutilisés, compte non
# relié) ; 2 : ~/.claude.json montre un autre compte que la connexion ; 3 : profil illisible, connexion non rangée.
compte_badge_suivre() {
  local actif cur sum vs="" ve="" vt="" e l rc=0
  actif="$(compte_badge_actif)"; [ -n "$actif" ] && compte_badges_possibles || return 1
  cur="$(compte_connexion)" && compte_connexion_complete "$cur" || return 1
  sum="$(compte_empreinte "$cur")"
  IFS=$'\t' read -r vs ve vt 2>/dev/null <"$(compte_badge_vu_file)" || true
  if [ "$sum" = "$vs" ] && [ "$ve" != - ]; then e="$ve"
  elif [ "$sum" = "$vs" ] && [ $(($(compte_now) - ${vt:-0})) -lt "$COMPTE_PROFIL_REESSAI_S" ]; then return 3
  elif ! e="$(compte_connexion_email "$cur")"; then
    printf '%s\t-\t%s\n' "$sum" "$(compte_now)" | fichier_remplace "$(compte_badge_vu_file)" || true; return 3
  fi
  l="$(compte_identite_label "$e")"
  if [ -z "$l" ] || ! compte_connu "$l"; then   # compte non relié : rien à ranger, e-mail retenu pour ne plus appeler
    [ "$sum" = "$vs" ] || printf '%s\t%s\t%s\n' "$sum" "$e" "$(compte_now)" | fichier_remplace "$(compte_badge_vu_file)" || true
    return 1
  fi
  if [ "$sum" = "$vs" ]; then   # déjà rangée : seule une identité devenue cohérente (fin d'un /login) change encore l'actif
    [ "$l" != "$actif" ] || return 0
    compte_identite_json "$e" >/dev/null || return 2
  fi
  compte_badge_ranger "$l" "$cur" "$e" || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  [ "$l" != "$actif" ] || return 0
  compte_now | fichier_remplace "$(compte_adopte_file)" || true   # le hook StopFailure ne croit plus LAB_COMPTE d'avant (lot 05)
  kv ADOPTED "$l"
}
# compte_badge_poser <étiquette> : resauve d'abord la connexion posée, puis pose le badge cible (trousseau de Claude Code, mcpOAuth
# gardé ; oauthAccount de ~/.claude.json, autres clés gardées), relu après la pose.
compte_badge_poser() {
  local l="$1" cur badge f acc new rc=0 t old_acc old_actif old_vu
  compte_badges_possibles || die "CLAUDE_CONFIG_DIR is set: badges act on the global Claude connection only"
  compte_badge_verrouiller || die "another badge change is running: try again in a moment"
  compte_badge_suivre || rc=$?
  if [ "$rc" = 3 ]; then   # la poser par-dessus perdrait un renouvellement rangé nulle part : la panne du 2026-11-03
    compte_badge_deverrouiller; die "the current connection was renewed but not saved (account unreadable: network?): nothing changed, try again"
  fi
  rc=0
  if ! badge="$(compte_trousseau_lire "$COMPTE_BADGE_SERVICE" "$l")" || [ ! -s "$(comptes_badges_dir)/$l.json" ]; then
    compte_badge_deverrouiller; die "no badge for $l: /login with this account in Claude, then lab account badge $l"
  fi
  cur="$(compte_trousseau_lire "$COMPTE_CLAUDE_SERVICE" "$(compte_claude_acct)")" || cur=""
  f="$HOME/.claude.json"; acc="$(comptes_badges_dir)/$l.json"
  # de quoi tout remettre si l'appel de test prouve la connexion morte (lot 05) : identité, badge actif, empreinte vue
  old_acc="$(jq -c '.oauthAccount // null' "$f" 2>/dev/null)" || old_acc=null
  old_actif="$(compte_badge_actif)"; old_vu="$(cat "$(compte_badge_vu_file)" 2>/dev/null)" || old_vu=""
  printf '%s\n%s\n' "${cur:-null}" "$badge" | jq -cs '(.[0] | objects // {} | del(.claudeAiOauth, .designOauth)) + .[1]' \
    | compte_trousseau_ecrire "$COMPTE_CLAUDE_SERVICE" "$(compte_claude_acct)" || rc=1
  if [ "$rc" = 0 ]; then
    # un ~/.claude.json illisible n'est jamais remplacé par un fichier vide
    if [ -f "$f" ]; then new="$(jq --slurpfile a "$acc" '.oauthAccount = $a[0]' "$f" 2>/dev/null)" || new=""
    else new="$(jq -n --slurpfile a "$acc" '{oauthAccount: $a[0]}')"; fi
    [ -n "$new" ] && printf '%s\n' "$new" | fichier_remplace "$f" || rc=1
    # Claude Code réécrit ~/.claude.json en continu : la pose n'est acquise que relue
    [ "$(jq -r '.oauthAccount.emailAddress // empty' "$f" 2>/dev/null)" = "$(jq -r '.emailAddress // empty' "$acc")" ] || rc=1
    # connexion posée sans son identité : l'ancienne revient, sinon la prochaine resauvegarde la rangerait sous le mauvais compte
    [ "$rc" = 0 ] || [ -z "$cur" ] || printf '%s\n' "$cur" | compte_trousseau_ecrire "$COMPTE_CLAUDE_SERVICE" "$(compte_claude_acct)" || true
  fi
  [ "$rc" != 0 ] || compte_actif_ecrire "$l" || rc=1
  [ "$rc" != 0 ] || printf '%s\t%s\n' "$(compte_empreinte "$badge")" "$(jq -r '.emailAddress' "$acc")" | fichier_remplace "$(compte_badge_vu_file)" || rc=1
  if [ "$rc" != 0 ]; then compte_badge_deverrouiller; die "badge of $l not set (keychain or ~/.claude.json refused): /login in Claude restores a connection"; fi
  # pose testée sous le verrou (lot 05) : seul un refus prouvé (401) annule ; un appel sans réponse garde la pose (untested)
  t=0; compte_badge_tester "$l" || t=$?
  if [ "$t" = 1 ]; then
    compte_badge_remettre "$cur" "$old_acc" "$old_actif" "$old_vu"
    compte_badge_deverrouiller
    log "Previous connection restored."; log "/login with $l in Claude, then:"; log "lab account badge $l"
    die "badge $l refused (401)"
  fi
  [ "$t" != 0 ] || compte_badge_suivre >/dev/null 2>&1 || true   # l'appel a pu renouveler la connexion : rangée tout de suite
  compte_badge_deverrouiller
  kv BADGE "$l"; kv ACTIVE "$l"
}
# compte_badge_remettre <connexion> <oauthAccount|null> <badge actif> <empreinte vue> : l'état d'avant une pose refusée, relu tel quel
compte_badge_remettre() {
  local f="$HOME/.claude.json" new acct; acct="$(compte_claude_acct)"
  if [ -n "$1" ]; then printf '%s\n' "$1" | compte_trousseau_ecrire "$COMPTE_CLAUDE_SERVICE" "$acct" || warn "previous connection not restored: /login in Claude"
  else security delete-generic-password -s "$COMPTE_CLAUDE_SERVICE" -a "$acct" >/dev/null 2>&1 || true; fi
  if [ -f "$f" ]; then
    new="$(jq --argjson a "$2" 'if $a == null then del(.oauthAccount) else .oauthAccount = $a end' "$f" 2>/dev/null)" || new=""
    [ -z "$new" ] || printf '%s\n' "$new" | fichier_remplace "$f" || true
  fi
  if [ -n "$3" ]; then compte_actif_ecrire "$3" || true; else rm -f "$(compte_badge_actif_file)"; fi
  if [ -n "$4" ]; then printf '%s\n' "$4" | fichier_remplace "$(compte_badge_vu_file)" || true; else rm -f "$(compte_badge_vu_file)"; fi
}

# compte_limite_lue <message> → rc 0 si le message parle d'une limite d'usage (« You've hit your … limit », « usage limit »,
# « resets … ») ; un 429 passager (« Rate limited. Please try again ») n'épuise aucun compte
compte_limite_lue() { grep -Eqi "hit your|usage limit|limit reached|resets? " <<<"$1"; }
# compte_fenetre_lue <message> → 7d (limite hebdomadaire, ou reprise datée d'un jour), sinon 5h
compte_fenetre_lue() {
  if grep -Eqi 'week|7-day|resets? +(at +)?(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.? +[0-9]' <<<"$1"; then echo 7d; else echo 5h; fi
}
# compte_reprise_lue <message> → epoch de reprise. Forme mesurée (2026-10-11) : « You've hit your weekly limit · resets Oct 13 at
# 9am (Europe/Brussels) » ; la limite des 5 h n'a que l'heure (déjà passée → échue dans une minute). Heure illisible ou hors des
# 8 jours → maintenant + 1 h, puis nouvelle vérification (lot 01 de comptes-complets : 5 h bloquaient pour rien).
compte_reprise_lue() {
  local now; compte_reprise_annoncee "$1" && return 0
  now="$(compte_now)"; printf '%s\n' $((now + COMPTE_REPLI_S))
}
# compte_reprise_annoncee <message> → l'epoch de reprise lue dans le message, à venir et sous 8 jours ; illisible → rc 1, rien
compte_reprise_annoncee() {
  local now e; now="$(compte_now)"
  e="$(perl -MPOSIX -e '
    my ($m, $now, $fenetre, $marge) = @ARGV;
    $m =~ /resets?\s+(?:at\s+)?(?:([A-Za-z]{3})[a-z]*\.?\s+(\d{1,2}),?\s+(?:at\s+)?)?(\d{1,2})(?::(\d\d))?\s*([ap]m)?\s*(?:\(([^)]+)\))?/i or exit 1;
    my ($mon, $day, $h, $mi, $ap, $tz) = ($1, $2, $3, $4 // 0, lc($5 // ""), $6);
    if (defined $tz && $tz =~ m{^[A-Za-z_+/-]+$}) { $ENV{TZ} = $tz; tzset(); }
    $h = 0 if $ap eq "am" && $h == 12; $h += 12 if $ap eq "pm" && $h < 12;
    exit 1 if $h > 23 || $mi > 59;
    my @t = localtime($now); my ($y, $mo, $d) = ($t[5], $t[4], $t[3]);
    if (defined $mon) {
      my %ms = (jan=>0,feb=>1,mar=>2,apr=>3,may=>4,jun=>5,jul=>6,aug=>7,sep=>8,oct=>9,nov=>10,dec=>11);
      exists $ms{lc $mon} or exit 1; $mo = $ms{lc $mon}; $d = $day;
      my $e = mktime(0, $mi, $h, $d, $mo, $y, 0, 0, -1);
      $e = mktime(0, $mi, $h, $d, $mo, $y + 1, 0, 0, -1) if $e < $now - 86400;
      print "$e\n"; exit 0;
    }
    # sans date = limite des 5 h : une reprise à plus de 5 h vient en fait de passer — échue, jamais reportée au lendemain
    for my $k (0 .. 1) {
      my $e = mktime(0, $mi, $h, $d + $k, $mo, $y, 0, 0, -1); next if $e <= $now;
      $e = $now + $marge if $e > $now + $fenetre; print "$e\n"; exit 0;
    }
    exit 1;
  ' "$1" "$now" "$COMPTE_FENETRE_S" "$COMPTE_MARGE_S" 2>/dev/null)" || return 1
  [ -n "$e" ] && [ "$e" -gt "$now" ] && [ "$e" -le $((now + 8 * 86400)) ] || return 1
  printf '%s\n' "$e"
}
# compte_marquer_limite <étiquette> <message> : la note d'une limite lue dans un message ; sans heure lisible, l'échéance de repli
# (+1 h) est notée sous la fenêtre « ? » — jamais recoupée avec un relevé, elle n'en annonce aucune (revue du lot 05)
compte_marquer_limite() {
  local e; if e="$(compte_reprise_annoncee "$2")"; then compte_marquer "$1" "$e" "$(compte_fenetre_lue "$2")"
  else compte_marquer "$1" "$(compte_reprise_lue "$2")" "?"; fi
}

# compte_attendre : tous les comptes sont bloqués pour de vrai — l'onglet montre l'état de chaque compte, attend l'échéance la plus
# proche (plus la marge), puis libère les notes échues à cette heure-là. Ctrl-C rend le terminal (rc 130) sans toucher aux notes ni
# au couloir : lab next le rouvre et ne réattend que si c'est encore vrai. Chaque ligne tient en 40 colonnes.
compte_attendre() {
  local min now secs h l e n=0 s pid g f woke
  min="$(compte_reprise_min)"; now="$(compte_now)"; [ -n "$min" ] || return 0
  # un essai court gardé (10 min) redevient permis avant l'échéance des notes : l'attente vise la fin de la garde (revue du lot 01)
  g="$(compte_essai_prochain)"; if [ -n "$g" ] && [ "$g" -lt "$min" ]; then min="$g"; fi
  secs=$((min - now + COMPTE_MARGE_S)); [ "$secs" -gt 0 ] || secs="$COMPTE_MARGE_S"
  h=$((secs / 3600)); h="$h h $(((secs % 3600) / 60)) min"
  log "All Claude accounts exhausted."
  while IFS= read -r l; do
    n=$((n + 1)); log "$n $l"; log "  $(compte_etat "$l")"
    while IFS= read -r s; do log "  $s"; done < <(compte_usage_lignes "$l")
  done < <(comptes_liste)
  # sleep en arrière-plan + wait : un SIGINT interrompt wait tout de suite (un sleep au premier plan le retiendrait jusqu'au bout).
  # USR1 (lab account resume) arrête le sleep sans libérer aucune note : la boucle de compte_appliquer refait le choix, et se remet
  # à attendre si rien n'est libre (piège 1 du lot 02 de comptes-complets : écourter l'attente libérait des notes vraies).
  woke=0
  trap 'woke=1; kill "$pid" 2>/dev/null' USR1
  sleep "$secs" & pid=$!
  trap 'kill "$pid" 2>/dev/null; compte_attente_effacer; log "Stopped. Notes and lane kept:"; log "lab next resumes this lane."; exit 130' INT
  compte_attente_inscrire "$min"   # avant l'annonce : un resume lancé dès que « Ctrl-C » s'affiche trouve l'onglet
  log "Resuming on $(compte_heure $((min + COMPTE_MARGE_S)) | sed 's/ / at /'),"
  log "that is in $h."
  log "The tab waits, then resumes alone."
  log "Ctrl-C: stop; lab next resumes."
  wait "$pid" || true
  wait "$pid" 2>/dev/null || true   # ramasse le sleep tué par un réveil : sinon bash l'annonce (« Terminated ») dans l'onglet
  compte_attente_effacer
  trap - INT; trap : USR1   # un USR1 tardif (registre lu juste avant l'effacement) ne tue jamais lab ; exec rend le défaut à l'agent
  if [ "$woke" = 1 ]; then log "Woken: accounts checked again."; return 0; fi
  while IFS= read -r l; do
    e="$(compte_epuise_jusqua "$l")"; [ -z "$e" ] || [ "$e" -gt "$min" ] || compte_liberer "$l"
  done < <(comptes_liste)
  f="$(comptes_essais_file)"   # les gardes échues à cette heure-là aussi : l'essai court reprend
  [ ! -f "$f" ] || awk -F'\t' -v m="$min" -v d="$COMPTE_ESSAI_S" '$2 + d > m' "$f" | fichier_remplace "$f" || true
}
# compte_appliquer [étiquette imposée] : avant d'exécuter Claude, choisit le compte, attend si tous sont épuisés, puis pose son
# jeton dans l'environnement de ce seul processus (rien pour le compte n° 1). Sans jeton rangé : rien ne change.
# COMPTE_SANS_ATTENTE=1 : tout épuisé → rc 1 au lieu d'attendre.
compte_appliquer() {
  local label="${1:-}" tok actif="" pose=1 n0
  comptes_actifs || return 0
  [ -z "${ANTHROPIC_API_KEY:-}" ] || die "ANTHROPIC_API_KEY is set: Claude prefers it to any stored account, rotation would have no effect. Remove it (unset ANTHROPIC_API_KEY), then run again."
  if [ -z "$label" ] && compte_badges_possibles; then
    compte_badge_suivi >/dev/null; actif="$(compte_badge_actif)"
    # décision 2 du lot 03 : le badge actif libre est gardé — un lancement ordinaire ne rebascule jamais tout le Mac ; sauf la
    # réserve, quittée dès qu'un compte normal est libre (décision 5 du lot 06 : les fenêtres déjà ouvertes restent)
    if [ -n "$actif" ] && compte_connu "$actif" && compte_badge_present "$actif" && ! compte_ecarte "$actif" \
        && [ -z "$(compte_bloque_jusqua "$actif")" ] && ! { compte_reserve "$actif" && compte_meilleur_libre >/dev/null; }; then
      label="$actif"; pose=0
    fi
  fi
  if [ -n "$label" ] && compte_ecarte "$label"; then warn "account $label unusable (dead badge or none): another is chosen"; label=""; fi
  # badge rangé : la vraie connexion du compte est posée pour tout le Mac (Chrome, pages, dictée) — aucun jeton exporté. Une pose
  # impossible ne bloque jamais le lancement : le jeton du compte prend le relais ; un badge mort (401 au test de pose) fait passer
  # au compte suivant, jamais à son jeton (décision 3 du lot 05).
  while :; do
    if [ -z "$label" ]; then
      until label="$(compte_choisir)"; do
        [ -n "$(compte_reprise_min)$(compte_essai_prochain)" ] \
          || die "no usable Claude account: dead badges or none — /login with an account in Claude, then lab account badge <label>"
        [ "${COMPTE_SANS_ATTENTE:-0}" != 1 ] || return 1   # hook hors cmux : personne ne regarderait l'attente
        compte_attendre
      done
    fi
    if [ "$pose" = 0 ]; then pose=ok; break; fi
    if ! compte_badges_possibles || ! compte_badge_present "$label"; then break; fi
    n0="$(compte_note "$label")"
    if ( compte_badge_poser "$label" >/dev/null ); then
      # le test de pose vient de noter une limite : la session irait droit dessus — compte suivant (revue du lot 05)
      if [ "$(compte_note "$label")" = "$n0" ] || [ -z "$(compte_bloque_jusqua "$label")" ]; then pose=ok; break; fi
      warn "account $label at its limit: next account"; label=""; continue
    fi
    [ "$(compte_badge_etat "$label")" = dead ] || { warn "badge of $label not set: its stored token is used"; break; }
    warn "badge of $label refused (401): next account"; label=""
  done
  if [ "$pose" = ok ]; then unset CLAUDE_CODE_OAUTH_TOKEN
  elif [ "$label" = "$COMPTE_PRINCIPAL" ]; then unset CLAUDE_CODE_OAUTH_TOKEN; compte_badge_suivi >/dev/null
  else
    tok="$(compte_jeton "$label")" && [ -n "$tok" ] \
      || die "token of account $label missing from the keychain: lab account remove $label, then lab account add $label"
    compte_badge_suivi >/dev/null   # un /login tapé depuis la dernière pose reste rangé
    export CLAUDE_CODE_OAUTH_TOKEN="$tok"
  fi
  # LAB_COMPTE_DEPUIS : l'heure du lancement, que le hook StopFailure compare à la dernière adoption d'un /login (lot 05)
  export LAB_COMPTE="$label" LAB_COMPTE_DEPUIS; LAB_COMPTE_DEPUIS="$(compte_now)"; kv ACCOUNT "$label"
}

# ---------- reprise générale (lot 02 de comptes-complets) : lab account resume ----------
# Registre d'attente : $LAB_STATE/comptes-attente/<pid> = <pid> TAB <projet> TAB <couloir|-> TAB <conversation|-> TAB <échéance> TAB
# <heure de démarrage du pid (ps lstart, LC_ALL=C : la même quelle que soit la langue du terminal)>, posé par compte_attendre et effacé à sa sortie (heure, Ctrl-C, réveil). Le pid n'est cru que
# s'il a gardé cette heure de démarrage et reste un lab : un pid recyclé ou devenu claude ne reçoit jamais le signal (revue du lot 02).
compte_attente_inscrire() { # <échéance>
  local d; d="$(comptes_attente_dir)"; mkdir -p "$d" || return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$$" "${P_NAME:--}" "${SLUG:--}" "${COMPTE_CONVERSATION:--}" "$1" "$(LC_ALL=C ps -o lstart= -p $$ 2>/dev/null)" \
    | fichier_remplace "$d/$$" || true
}
# compte_attente_vivante <fichier> : rc 0 si l'onglet inscrit attend encore — pid vivant, même heure de démarrage, commande lab
compte_attente_vivante() {
  local line pid start cmdline
  [ -f "$1" ] || return 1
  line="$(head -n 1 "$1")"; pid="${line%%$'\t'*}"; start="$(cut -f 6 <<<"$line")"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && [ "$(basename "$1")" = "$pid" ] && [ -n "$start" ] && pid_alive "$pid" || return 1
  [ "$(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null)" = "$start" ] && cmdline="$(ps -o command= -p "$pid" 2>/dev/null)" && grep -Eq '(^|/| )lab( |$)' <<<"$cmdline"
}
compte_attente_effacer() { rm -f "$(comptes_attente_dir)/$$"; }
# compte_attente_lignes → les lignes des onglets qui attendent encore : pid vivant dont la commande est un lab lancé pour ce couloir
# (un pid recyclé n'en reçoit jamais le signal) ; les autres fichiers sont retirés
compte_attente_lignes() {
  local f
  for f in "$(comptes_attente_dir)"/*; do
    [ -f "$f" ] || continue
    if compte_attente_vivante "$f"; then head -n 1 "$f"; else rm -f "$f"; fi
  done
}

# ---------- rotation partout (lot 06) : main et les claude tapés à la main, relancés dans leur onglet ----------
# compte_options_rejouees <ligne de ps -o args=> → les options de claude à rejouer, citées pour le shell, sur une ligne. Le prompt
# (mots sans tiret), --resume, --continue et --session-id ne sont jamais rejoués. ps joint les arguments par des espaces : seules les
# options connues, sans valeur ou à valeur d'un mot, se relisent sans ambiguïté — une autre → rc 1, rien rejoué ; -p/--print (claude
# non interactif) → rc 2, jamais relancé.
compte_options_rejouees() {
  local w v o f d out="" prompt=0; local -a mots=()
  read -r -a mots <<<"$1" || true
  set -- "${mots[@]+"${mots[@]}"}"; [ "$#" -eq 0 ] || shift   # le programme lui-même
  # -p n'importe où, seul ou groupé (-cp) : jamais relancé — dans le doute, une fenêtre de plus reste arrêtée, jamais un claude -p
  # remplacé par une session interactive (revue de sécurité du lot 06)
  for w in "$@"; do case "$w" in --print|--print=*) return 2 ;; --*) ;; -*p*) return 2 ;; esac; done
  while [ "$#" -gt 0 ]; do
    w="$1"; shift
    # après un mot du prompt, un mot à tiret peut être du prompt (« try --model haiku ») : rien n'est rejoué (revue du lot 06)
    case "$w" in -*) [ "$prompt" = 0 ] || return 1 ;; esac
    case "$w" in
      --) break ;;   # la suite est le prompt
      --resume|-r) case "${1:-}" in ''|-*) ;; *) shift ;; esac ;;   # --resume seul ouvre le sélecteur : sa valeur est facultative
      --session-id) [ "$#" -gt 0 ] || return 1; shift ;;
      # cmux lance chaque claude avec son --settings <fichier> (mesuré le 2026-11-05) : jamais rejoué, son lanceur remet le sien ;
      # du JSON en ligne peut porter des espaces → illisible
      --settings) case "${1:-}" in ''|-*|'{'*) return 1 ;; esac; shift ;;
      --name|-n) case "${1:-}" in ''|-*) return 1 ;; esac; shift ;;   # nom d'affichage de la session : jamais rejoué
      --mcp-config|--mcp-config=*)   # JSON en ligne (celui de cmux, coupé par « Application Support ») : lu jusqu'à sa dernière accolade,
        if [ "$w" = --mcp-config ]; then [ "$#" -gt 0 ] || return 1; v="$1"; shift; else v="${w#--mcp-config=}"; fi   # jamais rejoué
        case "$v" in
          '{'*) d=0
            while :; do
              o="${v//[^\{]/}"; f="${v//[^\}]/}"; d=$((d + ${#o} - ${#f}))
              [ "$d" -gt 0 ] || break
              [ "$#" -gt 0 ] || return 1
              v="$1"; shift
            done
            [ "$d" = 0 ] || return 1 ;;
          ''|-*) return 1 ;;
          *) out="$out $(shell_quote --mcp-config) $(shell_quote "$v")" ;;   # un fichier : rejoué
        esac ;;
      -c|--continue|--fork-session|--resume=*|--session-id=*) ;;
      --dangerously-skip-permissions|--allow-dangerously-skip-permissions|--verbose|--ide|--chrome|--no-chrome|--strict-mcp-config)
        out="$out $(shell_quote "$w")" ;;
      --model|--permission-mode|--fallback-model|--agent|--setting-sources)   # --settings peut porter du JSON à espaces : inconnu
        case "${1:-}" in ''|-*) return 1 ;; esac
        out="$out $(shell_quote "$w") $(shell_quote "$1")"; shift ;;
      --model=*|--permission-mode=*|--fallback-model=*|--agent=*|--setting-sources=*) out="$out $(shell_quote "$w")" ;;
      -*) return 1 ;;
      *) prompt=1 ;;   # un mot du prompt
    esac
  done
  printf '%s\n' "${out# }"
}
# compte_agent_enfant <pid> <pids de l'onglet> : rc 0 si un claude de l'onglet est l'ancêtre de ce pid — un claude lancé par une
# fenêtre (outil Bash, agent), jamais la fenêtre elle-même. La remontée s'arrête au premier ancêtre hors de l'onglet.
compte_agent_enfant() {
  local p="$1" seen=' '
  while p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')" && [[ "$p" =~ ^[1-9][0-9]*$ ]] && [ "$p" != 1 ]; do
    case "$seen" in *" $p "*) return 1 ;; esac; seen="$seen$p "
    grep -qx "$p" <<<"$2" || return 1
    case "$(basename -- "$(ps -o comm= -p "$p" 2>/dev/null)")" in claude|claude-code) return 0 ;; esac
  done
  return 1
}
# compte_relancer_ici <workspace> <surface> <pid de la fenêtre> <conversation> <dossier> : la fenêtre de cet onglet cmux est remplacée
# par la même conversation, lancée par lab account run (choix du compte, pose, attente visible), avec ses options relues. Seulement si
# cmux montre ce pid dans l'onglet et qu'il n'est ni un claude -p ni l'enfant d'un autre claude de l'onglet : RELAUNCH=<ligne> ;
# sinon RELAUNCH=none (<cause>), rc 1, rien tué.
compte_relancer_ici() {
  local ws="$1" sf="$2" pid="$3" sid="$4" dir="$5" args opts rc=0 pids line
  compte_conversation_ok "$sid" || { kv RELAUNCH "none (invalid conversation id)"; return 1; }
  [ -d "$dir" ] || { kv RELAUNCH "none (folder missing: $dir)"; return 1; }
  args="$(ps -o args= -p "$pid" 2>/dev/null)" || args=""
  [ -n "$args" ] || { kv RELAUNCH "none (window gone)"; return 1; }
  # cmux rattache un processus neuf à son onglet en 0,4 à 2,5 s (mesuré le 2026-11-05) : une fenêtre qui touche sa limite dès son
  # lancement est relue toutes les 0,5 s, COMPTE_ONGLET_ESSAIS fois au plus, tant qu'elle vit (lot 06 de comptes-complets)
  local essais="${COMPTE_ONGLET_ESSAIS:-1}"
  case "$essais" in ''|*[!0-9]*) essais=1 ;; esac
  until pids="$(cmux_surface_pids "$ws" "$sf")" && grep -qx "$pid" <<<"$pids"; do
    essais=$((essais - 1))
    if [ "$essais" -le 0 ] || ! kill -0 "$pid" 2>/dev/null; then kv RELAUNCH "none (not in its tab)"; return 1; fi
    sleep 0.5
  done
  if compte_agent_enfant "$pid" "$pids"; then kv RELAUNCH "none (child of another claude)"; return 1; fi
  opts="$(compte_options_rejouees "$args")" || rc=$?
  case "$rc" in
    0) ;;
    2) kv RELAUNCH "none (claude -p)"; return 1 ;;
    *) opts=""; log "options not replayed (unreadable without ambiguity): $args" ;;
  esac
  line="cd $(shell_quote "$dir") && $(shell_quote "${LAB_UPDATED_ROOT:-$LAB_ROOT}/bin/lab") account run --resume $(shell_quote "$sid")"
  [ -z "$opts" ] || line="$line -- $opts"
  cmux_restart_session "$ws" "$sf" "$(respawn_command "$line")" || { kv RELAUNCH "none (cmux refused)"; return 1; }
  kv RELAUNCH "$line"
}
# compte_relance <conversation> <pid de la fenêtre> <dossier> : après la note du hook StopFailure, hors couloir (main, claude tapé à la
# main). Dans cmux, la fenêtre est relancée dans son onglet ; hors cmux, le badge du compte suivant est posé pour tout le Mac (testé,
# 401 → suivant, jamais d'attente) et le journal dit quoi taper (décision 3 du lot 06).
compte_relance() {
  local sid="$1" pid="$2" dir="$3" here ws sf l a cmd
  printf '%s limit in session %s (%s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$sid" "$dir"
  if has_cmux && [ -n "${CMUX_SURFACE_ID:-}" ]; then
    here="$(cmux_identify)"; ws="${here%%$'\t'*}"; sf="${here#*$'\t'}"; ws="${ws:-${CMUX_WORKSPACE_ID:-}}"
    if [ -z "$here" ] || [ -z "$sf" ] || [ -z "$ws" ]; then kv RELAUNCH "none (cmux tab unreadable)"; return 0; fi
    COMPTE_ONGLET_ESSAIS="${LAB_TAB_TRIES:-10}" compte_relancer_ici "$ws" "$sf" "$pid" "$sid" "$dir" || true
    return 0
  fi
  if ! compte_options_rejouees "$(ps -o args= -p "$pid" 2>/dev/null)" >/dev/null && [ "$?" = 2 ]; then   # claude -p : rien posé
    kv RELAUNCH "none (claude -p)"; return 0
  fi
  COMPTE_SANS_ATTENTE=1
  if ! compte_appliquer >/dev/null; then
    kv RELAUNCH "none (no free account: lab account shows the reset times)"; return 0
  fi
  l="${LAB_COMPTE:-}"; a="$(compte_badge_actif)"
  if [ -n "$l" ] && [ "$l" = "$a" ]; then cmd="claude --resume $sid"; else cmd="lab account run --resume $sid"; fi
  kv ACCOUNT "${l:-?}"
  printf 'lab: account %s ready: /exit, then: cd %s && %s\n' "${l:-?}" "$(shell_quote "$dir")" "$cmd"
}

# compte_jeton_verifie <étiquette> : un vrai appel claude -p minimal sur le compte (jeton dans l'environnement du seul sous-processus,
# jamais en argument ; n° 1 = le /login, sans jeton). rc 0 accepté (gardé 10 min) ; 1 refusé (401 ou jeton absent : noté « 401 »,
# écarté) ; 2 limite (notée, compte non libre) ; 3 appel en échec (rien noté). Piège 2 du 2026-10-23 : un jeton rangé peut être
# refusé un quart d'heure plus tard — seul un appel le prouve.
compte_jeton_verifie() {
  local l="$1" now f t out rc=0
  now="$(compte_now)"; f="$(comptes_verifs_file)"
  t="$(awk -F'\t' -v l="$l" '$1 == l {t = $2} END {print t + 0}' "$f" 2>/dev/null || echo 0)"
  [ $((now - t)) -ge "$COMPTE_VERIF_S" ] || return 0
  if [ "$l" = "$COMPTE_PRINCIPAL" ]; then out="$(compte_appel_court)" || rc=$?; else out="$(compte_appel_court "$l")" || rc=$?; fi
  if compte_401_lu "$out"; then compte_marquer "$l" $((now + COMPTE_REFUS_S)) 401; return 1; fi
  if compte_limite_lue "$out"; then compte_marquer_limite "$l" "$out"; return 2; fi
  [ "$rc" = 0 ] || return 3
  { awk -F'\t' -v l="$l" '$1 != l' "$f" 2>/dev/null; printf '%s\t%s\n' "$l" "$now"; } | fichier_remplace "$f" || true
}
# compte_appel_court [étiquette à jeton] → la sortie d'un claude -p minimal ; rc celui de claude. Sans étiquette : la connexion
# posée sur le Mac (/login ou badge), aucun jeton. Le jeton ne passe que par l'environnement du seul sous-processus.
compte_appel_court() {
  (
    unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN
    export LAB_APPEL_COURT=1   # son hook StopFailure ne note rien : l'appelant lit la limite lui-même (revue du lot 06)
    if [ -n "${1:-}" ]; then
      CLAUDE_CODE_OAUTH_TOKEN="$(compte_jeton "$1")" && [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] || { echo 'API Error: 401 token missing'; exit 1; }
      export CLAUDE_CODE_OAUTH_TOKEN
    fi
    cd "$LAB_STATE" 2>/dev/null || cd /
    perl -e 'alarm shift; exec @ARGV or exit 127' "${LAB_VERIF_TIMEOUT:-90}" \
      claude -p --no-session-persistence --model haiku 'Reply with the single word OK.' </dev/null 2>&1
  )
}
# compte_badge_tester <étiquette> : un vrai appel sur la connexion posée, sans le cache de 10 min → BADGE_CHECK= et l'état du badge.
# rc 0 alive (une limite y est notée : la connexion marche) ; 1 dead (401) ; 3 untested (appel sans réponse lisible).
compte_badge_tester() {
  local l="$1" out rc=0
  out="$(compte_appel_court)" || rc=$?
  if compte_401_lu "$out"; then compte_badge_noter "$l" dead || true; kv BADGE_CHECK dead; return 1; fi
  if compte_limite_lue "$out"; then compte_marquer_limite "$l" "$out"; rc=0
  elif [ "$rc" != 0 ]; then
    compte_badge_noter "$l" untested || true; kv BADGE_CHECK untested
    warn "badge $l unchecked"; log "No answer (network?): badge kept."
    return 3
  fi
  compte_badge_noter "$l" alive || true; kv BADGE_CHECK alive
}
compte_401_lu() { grep -Eqi 'API Error: 401|authentication_error|invalid bearer|OAuth token (has )?(expired|revoked)|token missing' <<<"$1"; }

# compte_session_etat <dossier de travail> → « <état> TAB <conversation> » de la dernière conversation Claude de ce dossier
# (~/.claude/projects/<dossier, tout caractère non alphanumérique changé en ->/<conversation>.jsonl). État : stopped (dernière réponse =
# limite ou 401, fichier immobile depuis COMPTE_IMMOBILE_S), recent (idem, mais a bougé depuis moins longtemps), active (réponse normale
# ou tour en cours), unreadable (rien de lisible : format changé, fichier absent — jamais relancée).
compte_session_etat() {
  local d f sid last m now
  d="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')"
  # shellcheck disable=SC2012 # noms d'identifiants de session : ni espace ni retour à la ligne
  f="$(ls -t "$d"/*.jsonl 2>/dev/null | head -n 1)"; sid="$(basename "${f:-x}" .jsonl)"
  if [ -z "$f" ] || ! compte_conversation_ok "$sid"; then printf 'unreadable\t-\n'; return 0; fi
  last="$(tail -n 200 "$f" | jq -Rrn '[inputs | fromjson? | objects | select(.type == "user" or .type == "assistant")] | last // empty
    | [(if .type == "assistant" and .isApiErrorMessage == true then "error" else .type end), (.message.content | if type == "string" then . elif type == "array" then ([.[] | objects | .text // empty] | join(" ")) else "" end)]
    | map(gsub("[\t\n]"; " ")) | @tsv' 2>/dev/null)" || last=""
  if [ -z "$last" ]; then printf 'unreadable\t%s\n' "$sid"; return 0; fi
  m="${last#*$'\t'}"
  # seule une erreur d'API (isApiErrorMessage) arrête la session : une réponse normale qui parle de limite reste active (revue du lot 02)
  if [ "${last%%$'\t'*}" != error ] || ! { compte_limite_lue "$m" || compte_401_lu "$m"; }; then printf 'active\t%s\n' "$sid"; return 0; fi
  now="$(compte_now)"
  if [ $((now - $(stat -f %m "$f"))) -ge "$COMPTE_IMMOBILE_S" ]; then printf 'stopped\t%s\n' "$sid"; else printf 'recent\t%s\n' "$sid"; fi
}

# compte_sessions_arretees → « <couloir|-> TAB <projet> TAB <dossier> TAB <état> TAB <conversation> » pour chaque session Claude vivante
# (verrou de session) d'un projet enregistré dont l'état n'est pas active ; couloir « - » = checkout principal (hors couloir)
compte_sessions_arretees() {
  local p root wt lock s
  while IFS= read -r p; do
    root="$(config_get "$p" root)"; [ -d "$root" ] || continue
    for wt in "$root" "$root"/.worktrees/*; do
      lock="$(lock_file "$wt")"; [ -f "$lock" ] || continue
      { [ "$(lock_field "$lock" agent)" = claude ] && lock_alive "$lock"; } || continue
      s="$(compte_session_etat "$wt")"; [ "${s%%$'\t'*}" != active ] || continue
      if [ "$wt" = "$root" ]; then printf -- '-\t%s\t%s\t%s\n' "$p" "$wt" "$s"; else printf '%s\t%s\t%s\t%s\n' "$(basename "$wt")" "$p" "$wt" "$s"; fi
    done
  done < <(project_names)
}

# compte_reprendre [--dry-run] : relance, espacés de LAB_RESUME_GAP s (25), les onglets en attente (USR1), les sessions de couloir
# arrêtées (lab account switch) et celle du checkout principal (l'onglet de son terminal), après un vrai appel qui vérifie chaque compte libre.
# Sessions illisibles ou trop récentes : listées seulement. Rien à relancer → aucun appel. Aucun processus en fond.
compte_reprendre() {
  local dry=0 gap="${LAB_RESUME_GAP:-25}" waits stops l ok=0 n=0 pid p c wt st sid rc
  [ "${1:-}" != --dry-run ] || dry=1
  case "$gap" in ''|*[!0-9]*) die "LAB_RESUME_GAP must be a number of seconds: $gap" ;; esac
  comptes_actifs || { kv RESUMED none; log "No stored token: nothing to resume."; return 0; }
  waits="$(compte_attente_lignes)"; stops="$(compte_sessions_arretees)"
  while IFS=$'\t' read -r c p wt st sid; do
    [ -n "$c" ] || continue
    if [ "$c" = - ]; then   # session du checkout principal arrêtée : relancée plus bas dans l'onglet de son terminal
      case "$st" in
        stopped) ;;
        recent) kv LISTED "$p (main, moved < ${COMPTE_IMMOBILE_S} s)" ;;
        *) kv LISTED "$p (main, unreadable)" ;;
      esac
    elif [ "$st" = recent ]; then kv SKIPPED "$p/$c (moved < ${COMPTE_IMMOBILE_S} s)"
    elif [ "$st" = unreadable ]; then kv LISTED "$p/$c (unreadable)"; log "Unreadable answer: see its tab."
    fi
  done <<<"$stops"
  stops="$(printf '%s\n' "$stops" | awk -F'\t' '$4 == "stopped"')"
  if [ -z "$waits" ] && [ -z "$stops" ]; then kv RESUMED none; return 0; fi
  if [ "$dry" = 1 ]; then
    while IFS=$'\t' read -r pid p c _; do [ -z "$pid" ] || kv TO_RESUME "$p/$c (waiting)"; done <<<"$waits"
    while IFS=$'\t' read -r c p _ _ _; do [ -z "$c" ] || kv TO_RESUME "$p/${c/#-/main} (stopped)"; done <<<"$stops"
    log "Dry run: no call, no restart."; return 0
  fi
  while IFS= read -r l; do
    ! compte_ecarte "$l" && [ -z "$(compte_bloque_jusqua "$l")" ] || continue   # jamais relancé sur lui (revue du lot 05)
    rc=0; compte_jeton_verifie "$l" || rc=$?
    case "$rc" in
      0) kv TOKEN "$l ok"; ok=1 ;;
      1) kv SKIPPED "$l (token refused)"
         if [ "$l" = "$COMPTE_PRINCIPAL" ]; then log "Run /login again in Claude, then:"; log "lab account free $l"
         else log "Redo claude setup-token, then:"; log "lab account remove $l"; log "lab account add $l"; fi ;;
      2) kv SKIPPED "$l (limit reached)" ;;
      *) kv SKIPPED "$l (check failed)" ;;
    esac
  done < <(comptes_liste)
  if [ "$ok" = 0 ]; then kv RESUMED none; log "No token verified: nothing resumed."; return 0; fi
  while IFS=$'\t' read -r pid p c _; do
    [ -n "$pid" ] || continue
    [ "$n" = 0 ] || sleep "$gap"; n=$((n + 1))
    if compte_attente_vivante "$(comptes_attente_dir)/$pid" && kill -USR1 "$pid" 2>/dev/null; then kv RESUMED "$p/$c (waiting)"
    else kv SKIPPED "$p/$c (gone)"; fi   # relu juste avant l'envoi : l'onglet a pu finir d'attendre pendant l'écart (revue du lot 02)
  done <<<"$waits"
  while IFS=$'\t' read -r c p wt _ sid; do
    [ -n "$c" ] || continue
    [ "$n" = 0 ] || sleep "$gap"; n=$((n + 1))
    if [ "$c" = - ]; then compte_reprendre_main "$p" "$wt" "$sid"; continue; fi
    # le récit de la bascule (bien plus large que 40 colonnes) reste hors de l'écran ; sur un échec, sa cause est gardée (revue du lot 02)
    if "$LAB_ROOT/bin/lab" account switch "$p" "$c" "$sid" </dev/null >/dev/null 2>"$(comptes_attente_dir).switch"; then kv RESUMED "$p/$c (stopped)"
    else kv SKIPPED "$p/$c (switch failed)"; log "Cause: $(comptes_attente_dir).switch"; fi
  done <<<"$stops"
}
# compte_reprendre_main <projet> <checkout principal> <conversation> : la session du checkout principal arrêtée est relancée dans
# l'onglet dont le terminal est celui de son processus, quel que soit son nom (lot 01 d'onglet-tower : plus d'onglet « main »), par lab
# account run, options relues ; onglet introuvable ou cmux qui n'y montre pas le processus : sa commande à taper
compte_reprendre_main() {
  local p="$1" root="$2" sid="$3" tab pid out
  pid="$(lock_field "$(lock_file "$root")" pid || true)"
  if has_cmux && tab="$(cmux_pid_tab "$pid")"; then
    if out="$(compte_relancer_ici "${tab%%$'\t'*}" "${tab#*$'\t'}" "$pid" "$sid" "$root")"; then kv RESUMED "$p/main (stopped)"; return 0; fi
    out="${out#RELAUNCH=none (}"; kv SKIPPED "$p/main (${out%)})"
  else kv SKIPPED "$p/main (tab not found)"; fi
  log "Resume it by hand:"; log "cd $(shell_quote "$root") && lab account run --resume $sid"
}
