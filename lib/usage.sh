# shellcheck shell=bash
# usage.sh — lab usage (lot 04 de contexte-neuf) : la mesure de la tour du 2026-11-26, refaite pour un projet. Part des tokens envoyés
# au modèle par des appels dont le contexte dépasse context_max, sur une fenêtre de temps, lue dans les seuls compteurs des journaux
# Claude de ce Mac : <claude_home>/projects/<racine encodée>/*.jsonl et <racine encodée>--worktrees-*/*.jsonl (racine et couloirs ;
# le dossier d'un autre projet de même préfixe, <racine encodée>-app, n'en est pas). Formule de la tour : lignes assistant horodatées
# dans la fenêtre, dédoublonnées par (message.id, requestId) — une réponse à plusieurs blocs s'écrit sur plusieurs lignes, une
# conversation reprise recopie les appels déjà faits ; contexte d'un appel = input_tokens + cache_creation_input_tokens +
# cache_read_input_tokens. Sous-agents (<session>/subagents/*.jsonl, lignes isSidechain) comptés à part : le chiffre principal reste
# comparable aux 78 % de la tour. Codex et les sessions jouées sur une machine Cloud n'y sont pas. Lecture seule, aucun texte rendu.
declare -F context_max_set >/dev/null || . "${BASH_SOURCE[0]%/*}/context.sh"
USAGE_DAYS_DEFAULT=7
USAGE_SYNTAX='lab usage <project> [--days N | --from <date> [--to <date>]]'
USAGE_DATE_FORMS='expected YYYY-MM-DD (midnight UTC) or YYYY-MM-DDTHH:MM:SSZ (UTC)'

# usage_stamp <date tapée> → l'instant UTC « YYYY-MM-DDTHH:MM:SSZ » ; rc 1 si illisible (rdv_epoch de lib/rdv.sh juge le calendrier)
usage_stamp() {
  local d="$1"
  case "$d" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) d="${d}T00:00:00Z" ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) return 1 ;;
  esac
  rdv_epoch "$d" >/dev/null 2>&1 || return 1
  printf '%s\n' "$d"
}

# USAGE_JQ : un seul jq pour toute la fenêtre. Entrée : les lignes des journaux du fil principal, une ligne « #SUBAGENTS# », puis
# celles des sous-agents. Un appel déjà vu garde sa première ligne ; une ligne illisible, sans horodatage, sans usage ou de contexte
# nul (message synthétique) ne compte pas ; le texte des lignes n'est jamais rendu, seulement les sommes.
# shellcheck disable=SC2016 # programme jq, ses $ sont les siens
USAGE_JQ='def call($sub): try (
    select(.type == "assistant") | (.timestamp | strings | .[0:19]) as $t | select($t >= $from and $t < $to)
    | (.message | objects) as $m | ($m.usage | objects) as $u
    | {k: (if (($m.id // "") | tostring) == "" and ((.requestId // "") | tostring) == "" then "u|\(.uuid // $t)"
           else "\($m.id // "")|\(.requestId // "")" end),
       s: ($sub or .isSidechain == true),
       c: (($u.input_tokens // 0) + ($u.cache_creation_input_tokens // 0) + ($u.cache_read_input_tokens // 0)),
       o: ($u.output_tokens // 0)}
    | select((.c | type) == "number" and .c > 0 and (.o | type) == "number")
  ) catch empty;
  def sums: {n: length, t: (map(.c) | add // 0), a: (map(select(.c > $max) | .c) | add // 0), o: (map(.o) | add // 0)};
  def share: if .t > 0 then ((.a * 1000 / .t) + 0.5 | floor) else 0 end | "\(. / 10 | floor).\(. % 10)";
  (reduce inputs as $l ({sub: false, seen: {}};
      if $l == "#SUBAGENTS#" then .sub = true
      else .sub as $s | ([$l | try fromjson catch empty | objects | call($s)] | first) as $x
        | if $x == null or (.seen | has($x.k)) then . else .seen[$x.k] = $x end end)
   | [.seen[]]) as $all
  | ($all | map(select(.s | not)) | sums) as $m | ($all | map(select(.s)) | sums) as $a
  | "CALLS\t\($m.n)", "TOKENS\t\($m.t | floor)", "TOKENS_ABOVE\t\($m.a | floor)", "SHARE_ABOVE\t\($m | share)",
    "OUTPUT_TOKENS\t\($m.o | floor)", "SUBAGENT_CALLS\t\($a.n)", "SUBAGENT_TOKENS\t\($a.t | floor)",
    "SUBAGENT_TOKENS_ABOVE\t\($a.a | floor)", "SUBAGENT_SHARE_ABOVE\t\($a | share)"'

# usage_files_set <dossiers…> : USAGE_MAIN et USAGE_SUB, les journaux du fil principal et des sous-agents modifiés depuis USAGE_REF
# (repère à l'instant FROM) — un journal écrit pour la dernière fois avant la fenêtre n'a aucune ligne dedans ; USAGE_JOURNALS, leur
# nombre. Dans le shell courant : usage_stream les lit ensuite dans un tuyau.
usage_files_set() {
  local -a main=() sub=(); local f g rest
  while IFS= read -r f; do
    rest=""
    for g in "$@"; do case "$f" in "$g"/*) rest="${f#"$g"/}"; break ;; esac; done
    # fil principal : <dossier>/<session>.jsonl ; sous-agents : <dossier>/<session>/subagents/<agent>.jsonl ; rien d'autre
    case "$rest" in */subagents/*.jsonl) sub+=("$f") ;; */*|'') ;; *.jsonl) main+=("$f") ;; esac
  done < <(find "$@" -maxdepth 3 -type f -name '*.jsonl' -newer "$USAGE_REF" 2>/dev/null | LC_ALL=C sort)
  USAGE_JOURNALS=$(( ${#main[@]} + ${#sub[@]} ))
  USAGE_MAIN=("${main[@]+"${main[@]}"}"); USAGE_SUB=("${sub[@]+"${sub[@]}"}")
}
# usage_stream : sur stdout les lignes assistant de USAGE_MAIN, « #SUBAGENTS# », puis celles de USAGE_SUB. grep lit les fichiers
# lui-même et termine chaque ligne qu'il rend : la dernière ligne d'un journal en cours d'écriture, sans saut de ligne final, ne se
# colle pas à la première du suivant (cat les collait, deux appels perdus : revue du lot 04)
usage_stream() {
  if [ "${#USAGE_MAIN[@]}" -gt 0 ] && [ -n "${USAGE_MAIN[0]}" ]; then LC_ALL=C grep -hF '"type":"assistant"' -- "${USAGE_MAIN[@]}" 2>/dev/null || true; fi
  printf '#SUBAGENTS#\n'
  if [ "${#USAGE_SUB[@]}" -gt 0 ] && [ -n "${USAGE_SUB[0]}" ]; then LC_ALL=C grep -hF '"type":"assistant"' -- "${USAGE_SUB[@]}" 2>/dev/null || true; fi
}

# usage_millions <tokens> → en millions, une décimale (la phrase ; les clés gardent le compte exact)
usage_millions() { LC_ALL=C awk -v n="$1" 'BEGIN { printf "%.1f\n", n / 1000000 }'; }

cmd_usage() {
  local p days="" from="" to="" now enc base d max fe te out k v ref_dir
  [ "$#" -ge 1 ] || usage
  case "$1" in -*) usage ;; esac
  p="$1"; shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --days|--from|--to) [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 needs a value ($USAGE_SYNTAX)"
        case "$1" in --days) days="$2" ;; --from) from="$2" ;; --to) to="$2" ;; esac; shift 2 ;;
      *) die "unknown option: $1 ($USAGE_SYNTAX)" ;;
    esac
  done
  load_project "$p"
  command -v jq >/dev/null 2>&1 || die "jq is required by lab usage (brew install jq)"
  if [ -n "$days" ] && [ -n "$from" ]; then die "--days or --from, not both ($USAGE_SYNTAX)"; fi
  if [ -n "$days" ]; then
    case "$days" in ''|*[!0-9]*) die "--days \"$days\" refused: a whole number of days, 1 to 365" ;; esac
    [ "${#days}" -le 3 ] && [ "$((10#$days))" -ge 1 ] && [ "$((10#$days))" -le 365 ] || die "--days \"$days\" refused: a whole number of days, 1 to 365"
  fi
  if [ -n "$to" ]; then d="$(usage_stamp "$to")" || die "date \"$to\" unreadable: $USAGE_DATE_FORMS"; to="$d"
  else now="$(rdv_now)" || die "$(rdv_now_refusal)"; to="$now"; fi
  te="$(rdv_epoch "$to")"
  if [ -n "$from" ]; then d="$(usage_stamp "$from")" || die "date \"$from\" unreadable: $USAGE_DATE_FORMS"; from="$d"
  else from="$(jq -nr --argjson e "$(( te - 86400 * 10#${days:-$USAGE_DAYS_DEFAULT} ))" '$e | todate')"; fi
  fe="$(rdv_epoch "$from")"
  [ "$fe" -lt "$te" ] || die "--from must come before --to (from $from, to $to)"
  context_max_set; max="$CONTEXT_MAX"; [ "$max" -gt 0 ] || max="$CONTEXT_MAX_DEFAULT"
  # dossiers du projet : la racine et ses couloirs, encodés comme Claude Code (tout caractère non alphanumérique → -)
  enc="$(printf '%s' "$P_ROOT" | sed 's/[^A-Za-z0-9]/-/g')"; base="$(claude_home)/projects"
  local -a dirs=()
  for d in "$base/$enc" "$base/$enc--worktrees-"*; do [ ! -d "$d" ] || dirs+=("$d"); done
  out=""; USAGE_JOURNALS=0
  if [ "${#dirs[@]}" -gt 0 ]; then
    ref_dir="$(mktemp -d "${TMPDIR:-/tmp}/lab-usage.XXXXXX")" || die "temporary folder impossible (TMPDIR)"
    USAGE_REF="$ref_dir/from"
    TZ=UTC0 touch -t "$(printf '%s' "$from" | sed -E 's/^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})Z$/\1\2\3\4\5.\6/')" "$USAGE_REF" \
      || { rm -f "$USAGE_REF"; rmdir "$ref_dir"; die "time reference impossible for $from"; }
    usage_files_set "${dirs[@]}"
    out="$(usage_stream | jq -nrR --arg from "${from%Z}" --arg to "${to%Z}" --argjson max "$max" "$USAGE_JQ")" \
      || { rm -f "$USAGE_REF"; rmdir "$ref_dir"; die "journals unreadable by jq"; }
    rm -f "$USAGE_REF"; rmdir "$ref_dir" 2>/dev/null || true
  fi
  [ -n "$out" ] || out="$(jq -nrR --arg from "${from%Z}" --arg to "${to%Z}" --argjson max "$max" "$USAGE_JQ" </dev/null)"
  kv PROJECT "$p"; kv FROM "$from"; kv TO "$to"; kv CONTEXT_MAX "$max"
  local calls=0 tokens=0 share=0.0 scalls=0 stokens=0 sshare=0.0
  while IFS=$'\t' read -r k v; do
    [ -n "$k" ] || continue; kv "$k" "$v"
    case "$k" in CALLS) calls="$v" ;; TOKENS) tokens="$v" ;; SHARE_ABOVE) share="$v" ;; SUBAGENT_CALLS) scalls="$v" ;;
      SUBAGENT_TOKENS) stokens="$v" ;; SUBAGENT_SHARE_ABOVE) sshare="$v" ;; esac
  done <<<"$out"
  kv JOURNALS "$USAGE_JOURNALS"
  log_wrap "$p, $from to $to: $share % of the tokens sent to the model went to calls above context_max $max ($calls calls, $(usage_millions "$tokens") million tokens). Subagents, apart: $sshare % ($scalls calls, $(usage_millions "$stokens") million tokens). Claude journals of this Mac only, read for their counters."
}
