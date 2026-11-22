# shellcheck shell=bash
# words.sh — les mots de l'utilisateur (lot 10 d'autonomie-tours). « recette validée, couloir à fermer », écrit dans l'onglet du
# couloir ou de la tour, un clic sur un bouton (AskUserQuestion) ou une fermeture confirmée à voix haute (lab ginkgo close) sont lus
# par le crochet de lab dans la charge que Claude Code lui donne — prompt de UserPromptSubmit, tool_response.answers de PostToolUse,
# mesurés sur 2.1.330 —, jamais dans un texte de l'agent. Ils sont rangés hors du couloir, dans $LAB_STATE/<projet>/words/<couloir>
# (700/600, la garde du lot 09 y refuse Write et Edit), liés à la révision du couloir, et valent LAB_WORDS_TTL s (1 h) : lab
# acceptance --accept les accepte de l'agent du couloir ou de la tour, sans preuve typée, puis lab close ferme sans --confirm.

# ---------- repli du texte, partagé avec Ginkgo (lib/ginkgo.sh) ----------
# words_clean <octets> : l'entrée en une ligne, sans caractère de contrôle ni DEL, coupée puis rendue à une frontière UTF-8
words_clean() {
  # espaces Unicode (insécable…) → espace, caractères de format (largeur nulle…) retirés : un filtre de mots ne se contourne pas par eux
  tr '\n\r\t' '   ' | perl -CSD -pe 's/\p{Zs}/ /g; s/\p{Cf}//g; s/[\x{2028}\x{2029}\x{85}]/ /g' 2>/dev/null | LC_ALL=C tr -d '\000-\037\177' \
    | LC_ALL=C cut -c1-"$1" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null || true
}
# words_fold : minuscules sans accents ni caractères de format, pour les filtres de mots (« FERMÉ », « clôture »)
words_fold() { perl -CSD -MUnicode::Normalize -pe '$_ = NFD($_); s/\p{Mn}//g; s/\p{Cf}//g; s/\p{Zs}/ /g; $_ = lc' 2>/dev/null || true; }

# ---------- reconnaissance ----------
# Texte replié (words_fold), ponctuation → espace. Ne comptent jamais : un texte vide, une commande (« / », « ! » en tête), une
# question (« ? »), plus de WORDS_MAX caractères ou de WORDS_MAX_WORDS mots (un prompt de lab, une consigne), une négation ou une
# réserve (pas, ne, non, not, mais, attends…), le mot « lab » (une commande tapée), un ordre libre de Ginkgo. Comptent : une
# recette dite validée, acceptée ou ok, ou un ordre de fermer le couloir — « couloir », « lane » ou le nom d'un couloir donné —, en
# français ou en anglais ; chacun vaut les deux (décision 2 du grill-me). Avec « malgré », « despite »… et « nuit » ou « night » :
# l'accord nuit rouge.
WORDS_MAX=120
WORDS_MAX_WORDS=16
# shellcheck disable=SC2016 # programme perl littéral
WORDS_PERL='
use Unicode::Normalize;
local $/; my $t = <STDIN>; $t = "" unless defined $t;
sub fold { my $s = NFD($_[0]); $s =~ s/\p{Mn}//g; $s =~ s/\p{Cf}//g; $s =~ s/[\p{Zs}\t\r\n\x{2028}\x{2029}\x{85}]/ /g; return lc $s; }
sub flat { my $s = $_[0]; $s =~ s/[^\p{L}\p{N}]+/ /g; $s =~ s/^ +| +$//g; return $s; }
$t = fold($t); $t =~ s/^\s+|\s+$//g;
my @lanes = grep { length } map { flat(fold($_)) } split /\s+/, ($ENV{WORDS_LANES} // "");
my $n = flat($t); my @w = split / /, $n;
exit($n =~ /\b(?:ferm|clo|recette|acceptance)/ ? 0 : 1) if $ENV{WORDS_MODE} eq "maybe";
if ($ENV{WORDS_MODE} eq "named") {
  for my $r (split /\s+/, ($ENV{WORDS_LANES} // "")) { my $l = flat(fold($r)); print "$r\n" if length $l && " $n " =~ /\Q $l \E/ }
  exit 0;
}
exit 1 if $t eq "" || $t =~ m{^[/!]} || $t =~ /[?\x{bf}\x{ff1f}]/;
exit 1 if length($n) > $ENV{WORDS_MAX} || @w > $ENV{WORDS_MAX_WORDS} || !@w;
my %stop = map { $_ => 1 } qw(pas ne n non ni jamais aucun aucune rien sans mais sauf attends attendre attendez attend tard si
  not no never nope don dont doesn didn isn aren wasn can cannot won t without but except wait later if lab);
for (@w) { exit 1 if $stop{$_} }
exit 1 if $w[0] eq "ginkgo";
my $lane = @lanes ? join("|", map { quotemeta } @lanes) : "(?!)";
my $verb = "(?:ferme|fermer|fermez|fermons|clore|cloture|cloturer|cloturez|close|closing)";
my @close = (qr/\b$verb(?: \S+){0,2}? (?:couloir|lane|$lane)\b/,
  qr/\b(?:couloir|lane) (?:est |is )?(?:a|to) (?:fermer|clore|cloturer|close)\b/);
my @accept = (qr/\brecette (?:est |a ete |c est )?(?:validee?s?|acceptee?s?|ok|okay|bonne|approuvee?s?|reussie|passee)\b/,
  qr/\b(?:je |j )?(?:valide|accepte|approuve) (?:la |cette |ta |ma )?recette\b/,
  qr/\bacceptance (?:is )?(?:validated|valid|accepted|approved|ok|okay|passed|good|done)\b/,
  qr/\b(?:i )?(?:accept|approve|validate) (?:the |this )?acceptance\b/);
my $close = grep { $n =~ $_ } @close; my $accept = grep { $n =~ $_ } @accept;
exit 1 unless $close || $accept;
# the agreement is the whole message: once the recognised spans, the lanes given and quand meme are removed, only link words
# may remain (a delay, a condition, a refusal or another lane name leaves a word that is not one: nothing counts)
my $rest = " $n "; $rest =~ s/$_/ /g for (@close, @accept, qr/\bquand meme\b/); $rest =~ s/ \Q$_\E / /g for @lanes;
my %fill = map { $_ => 1 } qw(ok okay oui yes yep yeah c est cest bon bonne tout top parfait super nickel merci thanks thank you
  please stp svp tu peux pouvez vous on peut je j et and the le la les l ce cette this de du pour for alors so go allez vas y
  maintenant now donc enfin good great perfect it is s a au also aussi couloir lane recette acceptance accepter accepte accept
  valider valide validate approve approuve ferme fermer fermez fermons clore cloture cloturer cloturez close closing nuit night
  rouge red malgre despite regardless nonobstant anyway);
for (split " ", $rest) { exit 1 unless $fill{$_} }
my $night = $n =~ /\b(?:nuit|night)\b/ && $n =~ /\b(?:malgre|despite|regardless|nonobstant|anyway)\b|\bquand meme\b/;
print $night ? "night\n" : "accept\n";
'
# words_match <texte> [couloir…] → « accept » ou « night », rc 0 ; rien, rc 1 sinon
words_match() {
  local t="$1"; shift
  printf '%s' "$t" | WORDS_LANES="$*" WORDS_MAX="$WORDS_MAX" WORDS_MAX_WORDS="$WORDS_MAX_WORDS" WORDS_MODE=match perl -CSD -e "$WORDS_PERL" 2>/dev/null
}
# words_maybe <texte> : rc 0 si le texte replié porte l'un des mots sans lesquels words_match ne rend jamais rien (ferm…, clo…,
# recette, acceptance ; la formule de Ginkgo dit « close ») — le crochet écarte ainsi un prompt ordinaire avant de lire le
# projet (registre, config : ~0,24 s mesurées par prompt, rapport du lot 10)
words_maybe() { printf '%s' "$1" | WORDS_MODE=maybe perl -CSD -e "$WORDS_PERL" 2>/dev/null; }
# words_named <texte> <couloir…> → les couloirs nommés par le texte (mots entiers, repliés), un par ligne, sous leur nom réel
words_named() {
  local t="$1"; shift
  printf '%s' "$t" | WORDS_LANES="$*" WORDS_MODE=named perl -CSD -e "$WORDS_PERL" 2>/dev/null || true
}

# ---------- registre ----------
words_ttl() { case "${LAB_WORDS_TTL:-}" in ''|*[!0-9]*) echo 3600 ;; *) echo "$LAB_WORDS_TTL" ;; esac; }
words_file() { printf '%s/%s/words/%s\n' "$LAB_STATE" "$P_NAME" "$1"; }   # <couloir>
words_get() { [ -f "$1" ] && [ ! -L "$1" ] || return 0; sed -n "s/^$2=//p" "$1" | head -1; }   # <fichier> <champ>
words_clear() { rm -f "$(words_file "$1")"; }
# words_lanes → les couloirs du projet, la tour exceptée, un par ligne
words_lanes() {
  local wt
  for wt in "$P_ROOT"/.worktrees/*/; do
    [ -d "$wt" ] || continue; wt="${wt%/}"
    ! lane_is_tower "$wt" || continue
    valid_slug "$(wt_lane "$wt")" && printf '%s\n' "$(wt_lane "$wt")"
  done
  return 0
}
words_in_acceptance() { case "$(lane_phase "$1" 2>/dev/null)" in 'in acceptance'|'acceptance passed') return 0 ;; esac; return 1; }
# words_record <wt> <kind> <mots> <onglet lane|tower|ginkgo> <source prompt|click|voice> : réécriture atomique ; rc 1 sans rien écrire
# si le couloir n'est pas en recette (ni recette passée) ou si son nom ou sa révision sont illisibles
words_record() {
  local wt="$1" lane f rev said
  lane="$(wt_lane "$wt")"; valid_slug "$lane" || return 1
  words_in_acceptance "$wt" || return 1
  rev="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" || return 1
  said="$(printf '%s' "$3" | words_clean 200)"; f="$(words_file "$lane")"
  ( umask 077; mkdir -p "$(dirname "$f")" && rm -f "$f.tmp.$$" \
    && printf 'said=%s\nkind=%s\ntab=%s\nsource=%s\nlane=%s\nrev=%s\nat=%s\nsession=%s\n' "$said" "$2" "$4" "$5" "$lane" "$rev" "$(rdv_now)" \
      "$(printf '%s' "${PAYLOAD:-}" | jq -j '.session_id // empty' 2>/dev/null | words_clean 80)" >"$f.tmp.$$" && mv "$f.tmp.$$" "$f" )
}
# words_valid <wt> [kinds, défaut « accept night »] : rc 0 si des mots valent pour ce couloir — même couloir, kind admis, révision =
# HEAD du couloir, dits depuis LAB_WORDS_TTL s au plus ; pose WD_SAID, WD_KIND, WD_TAB, WD_SOURCE, WD_AT, WD_REV ; sinon rc 1 et WD_WHY
# shellcheck disable=SC2034 # WD_* sont lus par lib/recette.sh, lib/close.sh, lib/night.sh et lib/tower.sh
words_valid() {
  local wt="$1" kinds="${2:-accept night}" lane f rev now at
  WD_SAID=""; WD_KIND=""; WD_TAB=""; WD_SOURCE=""; WD_AT=""; WD_WHY=""; WD_REV=""
  lane="$(wt_lane "$wt")"; valid_slug "$lane" || { WD_WHY="lane name unreadable"; return 1; }
  f="$(words_file "$lane")"
  if [ ! -f "$f" ] || [ -L "$f" ]; then WD_WHY="no words of the user recorded by lab"; return 1; fi
  [ "$(words_get "$f" lane)" = "$lane" ] || { WD_WHY="words recorded for another lane"; return 1; }
  WD_KIND="$(words_get "$f" kind)"
  case " $kinds " in *" $WD_KIND "*) ;; *) WD_WHY="words of kind ${WD_KIND:-unknown}, not $kinds"; return 1 ;; esac
  rev="$(git -C "$wt" rev-parse HEAD 2>/dev/null)"
  [ -n "$rev" ] && [ "$(words_get "$f" rev)" = "$rev" ] \
    || { WD_WHY="words said at revision $(words_get "$f" rev | cut -c1-7), the lane is at ${rev:0:7}"; return 1; }
  WD_AT="$(words_get "$f" at)"; at="$(rdv_epoch "$WD_AT" 2>/dev/null)" || { WD_WHY="words with an unreadable time"; return 1; }
  now="$(rdv_epoch "$(rdv_now)")" || { WD_WHY="clock unreadable"; return 1; }
  [ "$((now - at))" -ge -60 ] && [ "$((now - at))" -le "$(words_ttl)" ] \
    || { WD_WHY="words older than $(( $(words_ttl) / 60 )) min"; return 1; }
  WD_SAID="$(words_get "$f" said)"; WD_TAB="$(words_get "$f" tab)"; WD_SOURCE="$(words_get "$f" source)"; WD_REV="$rev"
}
# words_where → « lane tab, 08:12 UTC » (ou « click, tower tab, … », « voice, ginkgo, … ») des derniers mots lus par words_valid
words_where() {
  local tab
  case "$WD_TAB" in lane) tab='lane tab' ;; tower) tab='tower tab' ;; ginkgo) tab='ginkgo, voice' ;; *) tab="${WD_TAB:-tab unknown}" ;; esac
  case "$WD_SOURCE" in click) tab="click, $tab" ;; esac
  printf '%s, %s UTC' "$tab" "$(printf '%s' "$WD_AT" | cut -c12-16)"
}
words_evidence() { printf 'words: "%s" (%s)' "$WD_SAID" "$(words_where)"; }

# ---------- crochets (lib/hooks.sh, hook_notify) ----------
# words_context <événement> <consigne> : la sortie du crochet, lue par la session (additionalContext, mesuré en C1)
words_context() { jq -cn --arg e "$1" --arg c "$2" '{hookSpecificOutput:{hookEventName:$e,additionalContext:$c}}'; }
# words_order <couloir> <rév> <mots> : la consigne donnée à l'agent qui a reçu les mots — accepter puis fermer, sans rien redemander
words_order() {
  printf 'LAB: lab recorded the user'"'"'s words "%s" as their acceptance of lane %s of %s, closing included, tied to revision %s for %s min. Without asking again, run lab acceptance %s %s --accept, then lab close %s %s (no --confirm: these words are the order). If lab close refuses on a red night, ask once with AskUserQuestion, two buttons "Close %s despite the red night" and "Keep %s" (in the user'"'"'s language), and run lab close %s %s again on that click. Never type these words yourself.' \
    "$3" "$1" "$P_NAME" "${2:0:7}" "$(( $(words_ttl) / 60 ))" "$P_NAME" "$1" "$P_NAME" "$1" "$1" "$1" "$P_NAME" "$1"
}
# words_take <wt de l'onglet> <kind> <mots> <onglet> <source> <couloir visé|vide> <couloirs nommés ou en recette> : enregistre et
# pose WORDS_CONTEXT, la consigne ; un couloir hors recette ou un choix ambigu n'enregistrent rien
words_take() {
  local kind="$2" said="$3" tab="$4" src="$5" lane="$6" list="$7" wt rev n
  if [ -z "$lane" ]; then
    n="$(printf '%s\n' "$list" | grep -c .)"
    [ "$n" -gt 1 ] || return 0
    WORDS_CONTEXT="LAB: these words look like the user's acceptance, but $n lanes of $P_NAME could be meant ($(printf '%s' "$list" | tr '\n' ' ' | sed 's/ $//')) and the message names none: nothing recorded. Ask which one with AskUserQuestion, one button per lane labelled \"Close <lane>\" (in the user's language); lab records the click."
    return 0
  fi
  wt="$(worktree_path "$lane")"; [ -d "$wt" ] || return 0
  if ! words_record "$wt" "$kind" "$said" "$tab" "$src"; then
    WORDS_CONTEXT="LAB: lane $lane of $P_NAME is not in acceptance (phase: $(lane_phase "$wt" 2>/dev/null)): lab recorded nothing; its batches come first."
    return 0
  fi
  rev="$(git -C "$wt" rev-parse HEAD 2>/dev/null)"; said="$(printf '%s' "$said" | words_clean 200)"
  if [ "$kind" = night ]; then
    WORDS_CONTEXT="LAB: lab recorded the user's click \"$said\" as the red night agreement for lane $lane of $P_NAME: run lab close $P_NAME $lane again now (no --confirm, no --night-red-ok)."
  else WORDS_CONTEXT="$(words_order "$lane" "$rev" "$said")"; fi
}
# words_target <texte> [question] → WT_LANE, le couloir visé depuis l'onglet de la tour : celui que nomme le texte (ou la question
# d'un bouton), sinon le seul en recette ; WT_LIST, les candidats d'un choix ambigu
words_target() {
  local named lanes l acc=""
  WT_LANE=""; WT_LIST=""
  lanes="$(words_lanes)"
  # shellcheck disable=SC2086 # les noms de couloir sont des mots (valid_slug)
  named="$(words_named "$1" $lanes)"
  # shellcheck disable=SC2086 # idem
  [ -n "$named" ] || named="$(words_named "${2:-}" $lanes)"
  if [ -n "$named" ]; then
    if [ "$(printf '%s\n' "$named" | grep -c .)" = 1 ]; then WT_LANE="$named"; else WT_LIST="$named"; fi
    return 0
  fi
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    ! words_in_acceptance "$(worktree_path "$l")" || acc="${acc:+$acc$'\n'}$l"
  done <<<"$lanes"
  if [ "$(printf '%s\n' "$acc" | grep -c .)" = 1 ]; then WT_LANE="$acc"; else WT_LIST="$acc"; fi
}
# words_ginkgo <prompt> : rc 0 et WG_LANE si c'est la fermeture confirmée à voix haute que tape lab ginkgo close dans la tour
# (« Ginkgo, voice of the user: close lane <c> of <p> (lab close <p> <c>), confirmed aloud by the user at <instant>. »)
# Revue de sécurité : la formule ne vaut que si lab ginkgo close (refusé à tout agent) vient de la taper — sa marque close-sent,
# écrite juste avant la frappe, nomme le même couloir depuis WORDS_GINKGO_TTL s au plus ; lue une fois, puis retirée
WORDS_GINKGO_TTL=120
words_ginkgo() {
  local f lane at now
  WG_LANE="$(printf '%s' "$1" | sed -nE "s/^Ginkgo, voice of the user: close lane ([a-z0-9][a-z0-9._-]*) of ([^ ]+) \\(lab close [^ ]+ [^ )]+\\), confirmed aloud by the user at [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\\.\$/\\1 \\2/p")"
  [ -n "$WG_LANE" ] && [ "${WG_LANE#* }" = "$P_NAME" ] || return 1
  WG_LANE="${WG_LANE%% *}"; valid_slug "$WG_LANE" || return 1
  f="$LAB_STATE/$P_NAME/ginkgo/close-sent"; [ -f "$f" ] && [ ! -L "$f" ] || return 1
  lane="$(sed -n 's/^lane=//p' "$f" | head -1)"; at="$(sed -n 's/^at=//p' "$f" | head -1)"; rm -f "$f"
  now="${LAB_NOW_EPOCH:-$(date +%s)}"
  case "$at" in ''|*[!0-9]*) return 1 ;; esac
  [ "$lane" = "$WG_LANE" ] && [ "$((now - at))" -ge 0 ] && [ "$((now - at))" -le "$WORDS_GINKGO_TTL" ]
}
# words_session_ok <wt de l'onglet> : le crochet vient de la session qui tient le verrou de cet onglet (couloir ou tour) — jamais d'une
# session lancée par l'agent (claude -p, sous-session dans le dossier), dont le prompt serait le sien (revue de sécurité du lot :
# UserPromptSubmit part aussi sous claude -p, mesure C1). Même critère que la tour (caller_role) : l'agent le plus proche est le pid
# du verrou. Le verrou vit dans le couloir : une session sans personne devant (claude -p) est refusée aussi — Claude Code y pose
# lui-même CLAUDE_CODE_ENTRYPOINT=sdk-cli et CLAUDE_CODE_SESSION_ATTENDED=0, hérités par le crochet (mesuré sur 2.1.330, même sous
# une session parente en cli). Limite nommée par la fiche : un script qui réécrirait le verrou et taperait à la place de l'agent.
words_session_ok() {
  local held me
  case "${CLAUDE_CODE_ENTRYPOINT:-}" in sdk*) return 1 ;; esac
  [ "${CLAUDE_CODE_SESSION_ATTENDED:-1}" != 0 ] || return 1
  held="$(lock_field "$(lock_file "$1")" pid 2>/dev/null)"; [ -n "$held" ] || return 1
  me="$(agent_pid_found 2>/dev/null)" || return 1
  [ "$me" = "$held" ]
}
words_not_session() { WORDS_CONTEXT="LAB: these words come from a session that does not hold the lock of $(wt_lane "$1") (one started by an agent?): lab recorded nothing."; }
# words_hook_project <racine> : le projet du couloir de la session chargé ; jamais le checkout principal
words_hook_project() {
  local p; p="$(project_from_cwd "$1" 2>/dev/null)" && [ -n "$p" ] && load_project "$p" 2>/dev/null || return 1
  ! same_path "$1" "$P_ROOT"
}
# words_on_prompt <racine> (UserPromptSubmit) : le texte exact envoyé par l'utilisateur ; sortie JSON du crochet si une consigne suit
# words_retract <couloir…> (revue du lot) : un message qui parle de recette ou de fermeture sans être un accord (négation,
# question, report) efface les mots encore en attente de ces couloirs ; l'accord déjà écrit reste, seul --reject le remplace —
# la consigne le rappelle. Sans mots en attente : silence.
words_retract() {
  local l note
  for l in "$@"; do
    [ -f "$(words_file "$l")" ] || continue
    words_clear "$l"; note=""
    ! agreement_by_words "$P_ROOT/.worktrees/$l" 2>/dev/null \
      || note=" Its acceptance already passed on their earlier words: if they no longer want it closed, run lab acceptance $P_NAME $l --reject --feedback \"<their words>\"."
    WORDS_CONTEXT="${WORDS_CONTEXT:+$WORDS_CONTEXT }LAB: the user's last message takes back their agreement for lane $l of $P_NAME: lab dropped the words it had recorded; do not accept nor close lane $l, ask them if unsure.$note"
  done
  return 0
}
# words_retract_tower <texte> : dans l'onglet de la tour, les couloirs nommés, sinon tous ceux qui ont des mots en attente
words_retract_tower() {
  local named l all=""
  # shellcheck disable=SC2046,SC2086 # noms de couloir : des mots
  named="$(words_named "$1" $(words_lanes))"
  if [ -z "$named" ]; then for l in $(words_lanes); do [ ! -f "$(words_file "$l")" ] || all="$all $l"; done; named="$all"; fi
  # shellcheck disable=SC2086
  words_retract $named
}
words_on_prompt() {
  local root="$1" prompt kind lanes
  WORDS_CONTEXT=""
  prompt="$(printf '%s' "$PAYLOAD" | jq -r '.prompt // empty' 2>/dev/null)"; [ -n "$prompt" ] || return 0
  words_maybe "$prompt" || return 0
  words_hook_project "$root" || return 0
  if lane_is_tower "$root"; then
    if words_ginkgo "$prompt"; then
      if words_session_ok "$root"; then words_take "$root" accept "close lane $WG_LANE, confirmed aloud" ginkgo voice "$WG_LANE" ""
      else words_not_session "$root"; fi
    else
      lanes="$(words_lanes)"
      # shellcheck disable=SC2086 # noms de couloir : des mots
      if ! kind="$(words_match "$prompt" $lanes)"; then words_retract_tower "$prompt"
      elif words_session_ok "$root"; then
        # décision 3 du grill-me : l'accord de nuit rouge ne passe que par le clic du bouton ; écrit, il vaut un accord simple
        [ "$kind" != night ] || kind=accept
        words_target "$prompt"; words_take "$root" "$kind" "$prompt" tower prompt "$WT_LANE" "$WT_LIST"
      else words_not_session "$root"; fi
    fi
  else
    if ! kind="$(words_match "$prompt" "$(wt_lane "$root")")"; then words_retract "$(wt_lane "$root")"
    elif words_session_ok "$root"; then
      [ "$kind" != night ] || kind=accept
      words_take "$root" "$kind" "$prompt" lane prompt "$(wt_lane "$root")" ""
    else words_not_session "$root"; fi
  fi
  [ -z "$WORDS_CONTEXT" ] || words_context UserPromptSubmit "$WORDS_CONTEXT"
}
# words_on_click <racine> (PostToolUse d'AskUserQuestion) : le libellé choisi, lu dans tool_response.answers — le choix de la personne,
# même quand l'agent a prérempli answers (mesure C1) ; la question sert seulement à nommer le couloir
words_on_click() {
  local root="$1" q label kind lanes tower=0
  WORDS_CONTEXT=""
  words_hook_project "$root" || return 0
  if lane_is_tower "$root"; then tower=1; lanes="$(words_lanes)"; else lanes="$(wt_lane "$root")"; fi
  while IFS=$'\t' read -r q label; do
    [ -n "$label" ] || continue
    # shellcheck disable=SC2086 # noms de couloir : des mots
    if ! kind="$(words_match "$label" $lanes)"; then
      words_maybe "$label" || continue
      if [ "$tower" = 1 ]; then words_retract_tower "$label"; else words_retract "$lanes"; fi
      break
    fi
    if ! words_session_ok "$root"; then words_not_session "$root"
    elif [ "$tower" = 1 ]; then words_target "$label" "$q"; words_take "$root" "$kind" "$label" tower click "$WT_LANE" "$WT_LIST"
    else words_take "$root" "$kind" "$label" lane click "$lanes" ""; fi
    break
  done < <(printf '%s' "$PAYLOAD" | jq -r '(.tool_response.answers // {}) | to_entries[] | [(.key | tostring), (.value | tostring)] | map(gsub("[\t\n\r]"; " ")) | @tsv' 2>/dev/null)
  [ -z "$WORDS_CONTEXT" ] || words_context PostToolUse "$WORDS_CONTEXT"
}
