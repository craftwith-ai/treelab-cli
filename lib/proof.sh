# shellcheck shell=bash
# proof.sh — lab proof : les preuves d'un lot rangées hors dépôt et vérifiables par empreintes (A6 du brief, lot 06 de lab-enhancement).
# Plus de 150 fichiers et un script de manifeste réécrit à chaque lot, empreintes invérifiables ensuite : une seule commande les range.
# Dossier : $LAB_STATE/preuves/<projet>/<couloir>/lot-NN-<slug>/ (les lots sont numérotés par couloir), un manifest.json v1 par lot.
# Un fichier suivi et identique à HEAD n'est jamais copié : son commit et son blob suffisent — le blob survit à une fusion squash dès que
# le même contenu arrive sur main. Aucune écriture ni aucun commit dans un dépôt git ; lab close ne retire jamais les preuves.
PROOF_US=$'\037'   # séparateur interne des enregistrements : un nom de fichier ne porte jamais de caractère de contrôle (refusé)

proof_dir() { printf '%s/preuves/%s/%s/%s\n' "$LAB_STATE" "$P_NAME" "$1" "$2"; }   # <couloir> <lot-NN-slug>
# proof_sha256 <fichiers…> : une empreinte par ligne, dans l'ordre des fichiers, en un seul appel (shasum est un programme Perl :
# un appel par fichier coûterait son démarrage 150 fois). Repli sha256sum ; refus nommé sans l'un ni l'autre.
proof_sha256() {
  local out
  if command -v shasum >/dev/null 2>&1; then out="$(shasum -a 256 "$@")" || return 1
  elif command -v sha256sum >/dev/null 2>&1; then out="$(sha256sum "$@")" || return 1
  else die "neither shasum nor sha256sum in PATH: SHA-256 fingerprints impossible"; fi
  # un nom qui porte une barre oblique inverse est échappé par une barre en tête de ligne
  printf '%s\n' "$out" | sed -n 's/^\\\{0,1\}\([0-9a-f]\{64\}\) .*/\1/p'
}
proof_sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -c1-64
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-64
  else die "neither shasum nor sha256sum in PATH: SHA-256 fingerprints impossible"; fi
}
proof_short() { printf '%s\n' "${1:0:12}"; }

# proof_find_lot <lot> : pose PROOF_LANE et PROOF_NAME (lot-NN-<slug>). <lot> vaut lot-NN-<slug> ou <slug> ; cherché parmi les fiches
# lots/<couloir>/lot-NN-<slug>.md du checkout principal et de chaque couloir du projet — une même fiche vue deux fois compte une fois.
# Aucune → refus qui cite la valeur et les couloirs lus ; plusieurs couloirs ou plusieurs fiches → refus qui les nomme. Avec « etat »
# (verify), un lot sans fiche lisible se retrouve par son dossier de preuves : avec docs=repo, la fiche part avec le couloir retiré et le
# checkout principal n'est jamais mis à jour par lab (revue du lot 06).
proof_find_lot() {
  local want="$1" slug="$1" exact="" docs wt d f name rest lane lanes="" matches="" lanes_found n
  case "$want" in lot-[0-9]*-*) exact="$want"; rest="${want#lot-}"; slug="${rest#*-}" ;; esac
  if ! valid_slug "$slug" || { [ -n "$exact" ] && ! [[ "$exact" =~ ^lot-[0-9]+-[a-z0-9][a-z0-9._-]*$ ]]; }; then
    die "batch \"$want\" refused: expected lot-NN-<slug> or <slug> (lowercase letters, digits, hyphens, dots, underscores)"
  fi
  while IFS= read -r docs; do
    for d in "$docs"/lots/*/; do
      [ -d "$d" ] || continue
      lane="$(basename "$d")"; [ "$lane" != preuves ] || continue
      lanes="$lanes$lane"$'\n'
      for f in "$d"lot-[0-9]*.md; do
        [ -f "$f" ] || continue
        name="$(basename "$f" .md)"; rest="${name#lot-}"
        [[ "${rest%%-*}" =~ ^[0-9]+$ ]] || continue
        if [ -n "$exact" ]; then [ "$name" = "$exact" ] || continue; else [ "${rest#*-}" = "$slug" ] || continue; fi
        matches="$matches$lane"$'\t'"$name"$'\n'
      done
    done
  done < <({ docs_dir "$P_ROOT"; for wt in "$P_ROOT"/.worktrees/*/; do [ ! -d "$wt" ] || docs_dir "${wt%/}"; done; } | awk '!seen[$0]++')
  if [ -z "$matches" ] && [ "${2:-}" = etat ]; then
    for d in "$LAB_STATE/preuves/$P_NAME"/*/lot-[0-9]*/; do
      [ -f "${d}manifest.json" ] || continue
      name="$(basename "$d")"; lane="$(basename "$(dirname "$d")")"; rest="${name#lot-}"
      [[ "${rest%%-*}" =~ ^[0-9]+$ ]] || continue
      if [ -n "$exact" ]; then [ "$name" = "$exact" ] || continue; else [ "${rest#*-}" = "$slug" ] || continue; fi
      matches="$matches$lane"$'\t'"$name"$'\n'
    done
    [ -z "$matches" ] || log "no batch file for \"$want\": evidence found through its state folder"
  fi
  matches="$(printf '%s' "$matches" | LC_ALL=C sort -u)"
  lanes="$(printf '%s' "$lanes" | LC_ALL=C sort -u | paste -sd, - | sed 's/,/, /g')"
  [ -n "$matches" ] || die "no batch file lots/<lane>/lot-NN-$slug.md for \"$want\" in project $P_NAME — lanes read: ${lanes:-none}"
  lanes_found="$(printf '%s\n' "$matches" | cut -f1 | LC_ALL=C sort -u)"
  n="$(printf '%s\n' "$matches" | awk 'NF {n++} END {print n + 0}')"
  if [ "$(printf '%s\n' "$lanes_found" | awk 'NF {n++} END {print n + 0}')" -gt 1 ]; then
    die "\"$want\" names batch files in several lanes: $(printf '%s\n' "$matches" | awk -F'\t' '{printf "%s%s/%s", (NR > 1 ? ", " : ""), $1, $2}') — no evidence filed"
  fi
  [ "$n" -eq 1 ] || die "\"$want\" names several batch files in lane $lanes_found: $(printf '%s\n' "$matches" | cut -f2 | paste -sd, - | sed 's/,/, /g') — give lot-NN-<slug>"
  PROOF_LANE="${matches%%$'\t'*}"; PROOF_NAME="${matches#*$'\t'}"
}

# proof_git_info <fichier absolu> : pose PG_REPO (projet|fiches, vide hors de ces dépôts), PG_PATH, PG_COMMIT, PG_BLOB quand le fichier
# est suivi à HEAD avec exactement ces octets ; tout vide sinon (non suivi, ignoré, modifié, hors dépôt). Lecture seule : aucune écriture
# dans un dépôt. Le dossier précédent est gardé en cache : les preuves d'un appel viennent souvent du même dossier.
proof_git_info() {
  local abs="$1" dir="${1%/*}" blob object
  PG_REPO=""; PG_PATH=""; PG_COMMIT=""; PG_BLOB=""
  if [ "$dir" != "${PG_DIR:-}" ]; then
    PG_DIR="$dir"; PG_PREFIX=""; PG_KIND=""; PG_TOP=""; PG_HEAD=""
    local out common
    if out="$(git -C "$dir" rev-parse --show-prefix --path-format=absolute --git-common-dir --show-toplevel 2>/dev/null)"; then
      { IFS= read -r PG_PREFIX; IFS= read -r common; IFS= read -r PG_TOP; } <<<"$out"
      if [ -n "$PROOF_PROJECT_COMMON" ] && [ "$common" -ef "$PROOF_PROJECT_COMMON" ]; then PG_KIND=projet
      elif [ -n "$PROOF_DOCS_TOP" ] && [ "$PG_TOP" -ef "$PROOF_DOCS_TOP" ]; then PG_KIND=fiches; fi
      [ -z "$PG_KIND" ] || PG_HEAD="$(git -C "$PG_TOP" rev-parse -q --verify HEAD 2>/dev/null || true)"
    fi
  fi
  [ -n "$PG_KIND" ] && [ -n "$PG_HEAD" ] || return 0
  blob="$(git -C "$PG_TOP" rev-parse -q --verify "HEAD:$PG_PREFIX${abs##*/}" 2>/dev/null)" || return 0
  object="$(git -C "$PG_TOP" hash-object --no-filters -- "$abs" 2>/dev/null)" || return 0
  [ "$blob" = "$object" ] || return 0
  PG_REPO="$PG_KIND"; PG_PATH="$PG_PREFIX${abs##*/}"; PG_COMMIT="$PG_HEAD"; PG_BLOB="$blob"
}
proof_repo_dir() { # <projet|fiches> → le dépôt où relire un blob ; vide si le dépôt des fiches n'existe plus
  case "$1" in projet) printf '%s\n' "$P_ROOT" ;; fiches) docs_repo_root "$P_ROOT" ;; esac
}
proof_manifest_check() { # <manifeste> : refus nommé s'il n'est pas un manifeste v1 lisible
  jq -e '.version == 1 and (.files | type == "array")
    and all(.files[]; (.step | type == "string") and (.name | type == "string") and (.path | type == "string")
      and (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and (.source == "copy" or .source == "copie" or .source == "git"))' "$1" >/dev/null 2>&1 \
    || die "unreadable manifest: $1 — a manifest.json v1 (version, files[]: step, name, source, path, sha256) is expected; nothing changed"
}

cmd_proof() {
  local project
  if [ "$#" -ge 2 ] && { [ "$2" = add ] || [ "$2" = verify ]; }; then
    project="$(project_from_cwd)" || die "project unknown here: lab proof <project> <batch> add|verify"
  elif [ "$#" -ge 3 ]; then
    project_exists "$1" || die "unknown project: $1"; project="$1"; shift
  else usage; fi
  load_project "$project"
  case "$2" in
    add) local lot="$1"; shift 2; proof_add "$lot" "$@" ;;
    verify) [ "$#" -eq 2 ] || usage; proof_verify "$1" ;;
    *) usage ;;
  esac
}

# proof_add <lot> [--etape <nom>] <fichiers…> : tout est validé avant la première écriture ; empreintes des sources en un appel, copies
# vérifiées par leur propre empreinte avant d'être posées, manifeste réécrit en un appel jq (temporaire puis mv).
proof_add() {
  local want="$1" step=general f i n dir manifest now sums line decisions added=0 git=0 skipped=0
  local -a files=() abs=() names=() kinds=() paths=() commits=() blobs=() repos=() shas=() bytes=() decision=() tmps=() copies=()
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --step|--etape) [ "$#" -ge 2 ] || die "--step expects a step name"; step="$2"; shift 2 ;;
      --) shift; while [ "$#" -gt 0 ]; do files+=("$1"); shift; done ;;
      -*) die "unknown option for lab proof add: $1 (a file whose name starts with a hyphen is written ./$1)" ;;
      *) files+=("$1"); shift ;;
    esac
  done
  proof_find_lot "$want"
  [[ "$step" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "step \"$step\" refused: lowercase letters, digits, dots, hyphens and underscores, starting with a letter or a digit (e.g. cycle-1)"
  [ "$step" != manifest.json ] || die "step \"manifest.json\" is reserved for the batch manifest: choose another name — nothing filed"
  [ "${#files[@]}" -gt 0 ] || die "no file to file: lab proof $P_NAME $want add [--step <name>] <files…>"
  for f in "${files[@]}"; do
    [ "$(printf '%s' "$f" | LC_ALL=C tr -d '[:cntrl:]')" = "$f" ] || die "path refused: \"$(printf '%s' "$f" | LC_ALL=C tr '[:cntrl:]' '?')\" contains a control character"
    if [ -d "$f" ]; then die "\"$f\" is a folder: give its files one by one — nothing filed"
    elif [ ! -e "$f" ]; then die "missing file: $f — nothing filed"
    elif [ ! -f "$f" ]; then die "\"$f\" is not a regular file — nothing filed"
    elif [ ! -r "$f" ]; then die "unreadable file: $f — nothing filed"; fi
    line="$(resolve_file "$f")" || die "unresolvable path: $f — nothing filed"
    abs+=("$line")
  done
  dir="$(proof_dir "$PROOF_LANE" "$PROOF_NAME")"; manifest="$dir/manifest.json"
  [ ! -e "$manifest" ] || proof_manifest_check "$manifest"
  { [ ! -e "$dir/$step" ] && [ ! -L "$dir/$step" ]; } || [ -d "$dir/$step" ] \
    || die "\"$step\" exists in the batch folder but is not a folder ($dir): choose another step (--step <name>) — nothing filed"
  # dépôts reconnus : le projet (checkout principal et couloirs partagent un même dossier git commun) et celui des fiches (docs=local)
  PROOF_PROJECT_COMMON="$(git -C "$P_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  PROOF_DOCS_TOP="$(docs_repo_root "$P_ROOT")"; PG_DIR=""
  sums="$(proof_sha256 "${abs[@]}")" || die "fingerprints could not be computed — nothing filed"
  [ "$(printf '%s\n' "$sums" | awk 'NF {n++} END {print n + 0}')" -eq "${#abs[@]}" ] || die "unreadable fingerprints: $(printf '%s\n' "$sums" | awk 'NF {n++} END {print n + 0}') for ${#abs[@]} files — nothing filed"
  while IFS= read -r line; do shas+=("$line"); done <<<"$sums"
  i=0
  for f in "${abs[@]}"; do
    names+=("${f##*/}")
    proof_git_info "$f"
    if [ -n "$PG_REPO" ]; then kinds+=(git); paths+=("$PG_PATH"); repos+=("$PG_REPO"); commits+=("$PG_COMMIT"); blobs+=("$PG_BLOB")
    else kinds+=(copy); paths+=("$step/${f##*/}"); repos+=(""); commits+=(""); blobs+=(""); copies+=("$i"); fi
    i=$((i + 1))
  done
  if [ "${#copies[@]}" -gt 0 ]; then
    local -a copy_src=()
    for i in "${copies[@]}"; do copy_src+=("${abs[$i]}"); done
    n=0; while IFS= read -r line; do bytes[${copies[$n]}]="$line"; n=$((n + 1)); done < <(wc -c "${copy_src[@]}" | awk -v k="${#copy_src[@]}" 'NR <= k {print $1}')
  fi
  # même étape, même nom : même empreinte → ignoré ; autre empreinte → refus, que l'entrée vienne du manifeste ou de cet appel
  decisions="$(
    { [ ! -f "$manifest" ] || jq -r --arg us "$PROOF_US" '.files[] | ["E", "", .step, .name, .sha256] | join($us)' "$manifest"
      i=0; for f in "${abs[@]}"; do printf 'N%s%s%s%s%s%s%s%s\n' "$PROOF_US" "$i" "$PROOF_US" "$step" "$PROOF_US" "${names[$i]}" "$PROOF_US" "${shas[$i]}"; i=$((i + 1)); done
    } | LC_ALL=C awk -F "$PROOF_US" '
      $1 == "E" { have[$3 "/" $4] = $5; next }
      { key = $3 "/" $4; if (key in have) print (have[key] == $5 ? "skip" : "conflict " have[key]); else { have[key] = $5; print "new" } }'
  )"
  while IFS= read -r line; do decision+=("$line"); done <<<"$decisions"
  [ "${#decision[@]}" -eq "${#abs[@]}" ] || die "unreadable manifest: $manifest — nothing filed"
  i=0
  for f in "${abs[@]}"; do
    case "${decision[$i]}" in
      conflict*) die "\"$step/${names[$i]}\" is already recorded with fingerprint $(proof_short "${decision[$i]#conflict }"), this file has $(proof_short "${shas[$i]}"): file it under another step (--step <name>) — nothing filed" ;;
      new) [ "${kinds[$i]}" != copy ] || [ ! -e "$dir/$step/${names[$i]}" ] \
             || die "\"$step/${names[$i]}\" already exists in $dir without being in the manifest: remove it or choose another step (--step <name>) — nothing filed" ;;
    esac
    i=$((i + 1))
  done
  # copies : chacune vers un temporaire du dossier du lot, empreintes des copies en un appel, puis mv ; un écart retire toutes les copies
  local created=0
  [ -d "$dir" ] || created=1
  mkdir -p "$dir"
  for i in "${copies[@]+"${copies[@]}"}"; do
    [ "${decision[$i]}" = new ] || continue
    f="$(mktemp "$dir/.copie.XXXXXX")" || { proof_abort "$created" "$dir" "${tmps[@]+"${tmps[@]}"}"; die "temporary copy impossible in $dir — nothing filed"; }
    tmps+=("$f")
    cp "${abs[$i]}" "$f" 2>/dev/null || { proof_abort "$created" "$dir" "${tmps[@]}"; die "copy refused: ${abs[$i]} — nothing filed"; }
  done
  if [ "${#tmps[@]}" -gt 0 ]; then
    sums="$(proof_sha256 "${tmps[@]}")" || { proof_abort "$created" "$dir" "${tmps[@]}"; die "fingerprints of the copies impossible — nothing filed"; }
    n=0
    for i in "${copies[@]}"; do
      [ "${decision[$i]}" = new ] || continue
      n=$((n + 1)); line="$(printf '%s\n' "$sums" | sed -n "${n}p")"
      [ "$line" = "${shas[$i]}" ] || { proof_abort "$created" "$dir" "${tmps[@]}"; die "altered copy: ${names[$i]} (source $(proof_short "${shas[$i]}"), copy $(proof_short "${line:-unreadable}")) — no copy kept, manifest unchanged"; }
    done
  fi
  now="$(rdv_now)" || { proof_abort "$created" "$dir" "${tmps[@]+"${tmps[@]}"}"; die "$(rdv_now_refusal)"; }
  # le manifeste s'écrit d'abord dans un temporaire : s'il échoue, aucune copie n'est posée et la relance range normalement (revue du lot 06)
  local tmp="" pending=0
  for line in "${decision[@]}"; do [ "$line" != new ] || pending=$((pending + 1)); done
  if [ "$pending" -gt 0 ]; then
    tmp="$(mktemp "$dir/.manifest.XXXXXX")" || { proof_abort "$created" "$dir" "${tmps[@]+"${tmps[@]}"}"; die "manifest not written: $manifest — nothing filed"; }
    i=0
    for f in "${abs[@]}"; do
      [ "${decision[$i]}" = new ] && printf '%s\n' "${kinds[$i]}$PROOF_US$step$PROOF_US${names[$i]}$PROOF_US${paths[$i]}$PROOF_US${bytes[$i]:-}$PROOF_US${shas[$i]}$PROOF_US${repos[$i]}$PROOF_US${commits[$i]}$PROOF_US${blobs[$i]}"
      i=$((i + 1))
    done | jq -Rn --slurpfile old "$( [ -f "$manifest" ] && printf '%s' "$manifest" || printf /dev/null)" \
      --arg us "$PROOF_US" --arg project "$P_NAME" --arg lane "$PROOF_LANE" --arg lot "$PROOF_NAME" --arg added "$now" '
      ($old[0].files // []) + [inputs | split($us) | if .[0] == "git"
        then {step: .[1], name: .[2], source: "git", repo: .[6], path: .[3], commit: .[7], blob: .[8], sha256: .[5], added: $added}
        else {step: .[1], name: .[2], source: "copy", path: .[3], bytes: (.[4] | tonumber), sha256: .[5], added: $added} end]
      | {version: 1, project: $project, lane: $lane, lot: $lot, files: .}' >"$tmp" \
      || { proof_abort "$created" "$dir" "$tmp" "${tmps[@]+"${tmps[@]}"}"; die "manifest not written: $manifest — nothing filed"; }
  fi
  n=0
  for i in "${copies[@]+"${copies[@]}"}"; do
    [ "${decision[$i]}" = new ] || continue
    mkdir -p "$dir/$step"; mv "${tmps[$n]}" "$dir/$step/${names[$i]}"; n=$((n + 1))
  done
  [ -z "$tmp" ] || mv "$tmp" "$manifest"
  i=0
  for f in "${abs[@]}"; do
    case "${decision[$i]}:${kinds[$i]}" in
      skip:*) skipped=$((skipped + 1)); log "skipped $step/${names[$i]}: already recorded with the same fingerprint" ;;
      new:copy) added=$((added + 1)); log "copied $step/${names[$i]} — sha256 $(proof_short "${shas[$i]}")" ;;
      new:git) git=$((git + 1)); log "referenced $step/${names[$i]} — repository ${repos[$i]}, ${paths[$i]} at commit $(proof_short "${commits[$i]}"), sha256 $(proof_short "${shas[$i]}") (versioned: not copied)" ;;
    esac
    i=$((i + 1))
  done
  log "evidence of $PROOF_LANE/$PROOF_NAME: $dir"
  kv PROOF_BATCH "$PROOF_NAME"; kv PROOF_LANE "$PROOF_LANE"; kv PROOF_ADDED "$added"; kv PROOF_GIT "$git"; kv PROOF_SKIPPED "$skipped"
  kv PROOF_MANIFEST_SHA256 "$(proof_sha256 "$manifest")"
}
proof_abort() { # <créé=0|1> <dossier> [temporaires…] : retire les copies de l'appel ; le dossier du lot disparaît s'il vient d'être créé vide
  local created="$1" dir="$2"; shift 2
  [ "$#" -eq 0 ] || rm -f "$@"
  [ "$created" != 1 ] || rmdir "$dir" 2>/dev/null || true
}

# proof_verify <lot> : recalcule chaque empreinte — copie relue sur disque, entrée git relue par git cat-file blob dans son dépôt ;
# un bloc par entrée, puis PROOF_OK, PROOF_BAD, PROOF_EXTRA (fichiers du dossier absents du manifeste : avertissement seulement).
proof_verify() {
  local dir manifest entries line source step name path sha repo blob status ok=0 bad=0 extra=0 repo_dir actual
  local -a keys=() sources=() statuses=() files=() idx=() expected=()
  proof_find_lot "$1" etat
  dir="$(proof_dir "$PROOF_LANE" "$PROOF_NAME")"; manifest="$dir/manifest.json"
  [ -f "$manifest" ] || die "no evidence recorded for $PROOF_LANE/$PROOF_NAME: lab proof $P_NAME $PROOF_NAME add <files…> starts it"
  proof_manifest_check "$manifest"
  entries="$(jq -r --arg us "$PROOF_US" '.files[] | [.source, .step, .name, .path, .sha256, (.repo // ""), (.blob // "")] | join($us)' "$manifest")" \
    || die "unreadable manifest: $manifest"
  while IFS="$PROOF_US" read -r source step name path sha repo blob; do
    [ -n "$source" ] || continue
    source="$(lang_code "$source")"   # manifeste d'avant le lot 09 : « copie » vaut « copy »
    keys+=("$step/$name"); sources+=("$source"); expected+=("$sha"); status=absent
    if [ "$source" = copy ]; then
      case "/$path/" in */../*|*/./*|//*) die "unreadable manifest: $manifest — copy path outside the batch folder: $path" ;; esac
      if [ -f "$dir/$path" ] && [ -r "$dir/$path" ]; then files+=("$dir/$path"); idx+=("${#keys[@]}"); status=pending; fi
    else
      repo_dir="$(proof_repo_dir "$repo")"
      if [ -n "$repo_dir" ] && [[ "$blob" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] && git -C "$repo_dir" cat-file -e "$blob^{blob}" 2>/dev/null; then
        actual="$(git -C "$repo_dir" cat-file blob "$blob" | proof_sha256_stdin)" || actual=""
        if [ "$actual" = "$sha" ]; then status=ok; else status=altered; fi
      fi
    fi
    statuses+=("$status")
  done <<<"$entries"
  if [ "${#files[@]}" -gt 0 ]; then
    local sums n=0 k
    sums="$(proof_sha256 "${files[@]}")" || die "fingerprints could not be read again in $dir"
    while IFS= read -r line; do
      k=$((${idx[$n]} - 1)); n=$((n + 1))
      if [ "$line" = "${expected[$k]}" ]; then statuses[k]=ok; else statuses[k]=altered; fi
    done <<<"$sums"
  fi
  local i=0
  for status in "${statuses[@]+"${statuses[@]}"}"; do
    [ "$status" != pending ] || status=altered   # une copie lisible sans empreinte relue ne passe jamais pour intacte
    kv PROOF_FILE "${keys[$i]}"; kv PROOF_SOURCE "${sources[$i]}"; kv PROOF_STATUS "$status"; sep
    if [ "$status" = ok ]; then ok=$((ok + 1)); else bad=$((bad + 1)); warn "evidence $([ "$status" = absent ] && echo missing || echo altered): ${keys[$i]} (${sources[$i]})"; fi
    i=$((i + 1))
  done
  # fichiers posés à la main dans le dossier du lot : nommés, jamais comptés comme altération
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    extra=$((extra + 1)); warn "file outside the manifest: $line"
  done < <({ jq -r '.files[] | select(.source == "copy" or .source == "copie") | "K\t" + .path' "$manifest"
              (cd "$dir" && find . -type f ! -path ./manifest.json | LC_ALL=C sort | sed 's|^\./|F	|'); } |
            LC_ALL=C awk -F '\t' '$1 == "K" { known[$2] = 1; next } !($2 in known) { print $2 }')
  kv PROOF_BATCH "$PROOF_NAME"; kv PROOF_LANE "$PROOF_LANE"; kv PROOF_OK "$ok"; kv PROOF_BAD "$bad"; kv PROOF_EXTRA "$extra"
  kv PROOF_MANIFEST_SHA256 "$(proof_sha256 "$manifest")"
  if [ "$bad" -gt 0 ]; then log "evidence of $PROOF_LANE/$PROOF_NAME: $bad altered or missing out of $((ok + bad))"; return 1; fi
  if [ "$extra" -gt 0 ]; then log "evidence of $PROOF_LANE/$PROOF_NAME: $ok intact, $extra file(s) outside the manifest"
  else log "evidence of $PROOF_LANE/$PROOF_NAME: $ok intact"; fi
}
