# shellcheck shell=bash
# mcp_pin.sh — lab mcp --pin|--bump|--undo (lot 02 du couloir mcp-sobres) : figer les serveurs d'outils, avec accord et retour arrière.
# --pin : version lue dans le cache npx, sans réseau. npx range chaque spécification écrite (« paquet@latest », « paquet ») dans
# ~/.npm/_npx/<16 premiers caractères du sha512 de la spécification> : la version de ce dossier est celle que npx lance. Les autres
# dossiers du même paquet (autres spécifications) ne sont jamais pris. --bump : dernière version publiée (npm view).
# Accord : l'aperçu ne montre que « paquet avant → après » (un fichier de configuration porte des jetons) ; au terminal, une question
# [y/N] ; sinon rien n'est écrit et --yes porte un accord déjà reçu. Chaque fichier est sauvegardé dans $LAB_STATE/mcp-pin/<horodatage>/
# avant d'être réécrit (fichier temporaire, mv, abandon s'il a changé entre la lecture et l'écriture) ; --undo restaure la dernière
# sauvegarde à l'octet près, ou ne remet que le jeton si une session a réécrit le fichier entre-temps.

MCP_SEMVER='^v?[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]*)?$'
MCP_NPM_NAME='^(@[A-Za-z0-9][A-Za-z0-9._~-]*/)?[A-Za-z0-9][A-Za-z0-9._~-]*$'
# Remplacement d'un jeton dans les arguments du serveur $n sous le chemin $p : argument égal, ou mot d'un script (sh -c « … »).
# shellcheck disable=SC2016 # programme jq, ses $ sont les siens
MCP_REP_JQ='
def rep: if . == $o then $w
  elif type == "string" and (split(" ") | any(.[]; . == $o)) then split(" ") | map(if . == $o then $w else . end) | join(" ")
  else . end;
getpath($p + [$n, "args"]) as $a | if ($a | type) == "array" then setpath($p + [$n, "args"]; $a | map(rep)) else error("args") end'
# Le même jeton remplacé dans le texte, seulement entre guillemets, apostrophes ou espaces ; en TOML, dans la seule section du
# serveur (jamais ses sous-tables, dont env). Le nombre de remplacements va dans le fichier CNT.
# shellcheck disable=SC2016 # programme awk, ses $ sont les siens
MCP_TOKREP_AWK='
function rep(s,   out, i, a, z, L, k) {
  out = ""; L = length(O)
  while ((i = index(s, O)) > 0) {
    a = (i > 1) ? substr(s, i - 1, 1) : substr(out, length(out), 1); z = substr(s, i + L, 1)
    k = substr(s, i + L + 1); sub(/^[ \t]*/, "", k)   # après le guillemet fermant : « : » fait du jeton une clé JSON, jamais remplacée
    if (a != "" && z != "" && index(B, a) && index(B, z) && !(z == "\"" && substr(k, 1, 1) == ":")) { out = out substr(s, 1, i - 1) W; n++ }
    else out = out substr(s, 1, i - 1 + L)
    s = substr(s, i + L)
  }
  return out s
}
BEGIN { O = ENVIRON["MCP_O"]; W = ENVIRON["MCP_W"]; B = "\" \047"; n = 0; insec = (mode == "json") }
mode == "toml" && /^[ \t]*\[/ {
  h = $0; sub(/^[ \t]*\[[ \t]*/, "", h); sub(/[ \t]*\][ \t]*(#.*)?$/, "", h)
  insec = (h == "mcp_servers." SEC || h == "mcp_servers.\"" SEC "\""); print; next
}
insec { $0 = rep($0) }
{ print }
END { print n > CNT }'
# Vue de l'aperçu, lignes T (titre), C (changement), S (écarté : raison), F (pied) ; repliée à w colonnes, aucun mot coupé.
# shellcheck disable=SC2016 # programme awk, ses $ sont les siens
MCP_PIN_VIEW_AWK='
function wrap(s, ind,   n, a, i, cur) {
  n = split(s, a, " "); cur = ""
  for (i = 1; i <= n; i++) { if (cur == "") cur = ind a[i]; else if (length(cur " " a[i]) <= w) cur = cur " " a[i]; else { print cur; cur = ind a[i] } }
  if (cur != "") print cur
}
function who(sc, src, nm,   x) { x = sc " · " src " · " nm; if (length(x) <= w) print x; else { print nm; print "  " sc " · " src } }
BEGIN { FS = "\t" }
$1 == "T" { wrap($2, ""); next }
$1 == "C" { print ""; who($2, $3, $4); if ($6 == "") wrap($5, "  "); else if (length("  " $5 " → " $6) <= w) print "  " $5 " → " $6; else { print "  " $5; print "  → " $6 } next }
$1 == "S" { if (!ns++) { print ""; print "Not changed:" } print ""; who($2, $3, $4); wrap($5, "  "); next }
$1 == "F" { print ""; wrap($2, ""); next }'

mcp_sha() { shasum -a 256 "$1" 2>/dev/null | cut -c1-64; }
# mcp_pkgname <spécification> → nom du paquet npm, sans sa version (@portée/nom@x → @portée/nom)
mcp_pkgname() { local s="$1" at=""; case "$s" in @*) at="@"; s="${s#@}" ;; esac; printf '%s%s\n' "$at" "${s%%@*}"; }
# mcp_eol_like <référence> <fichier> : sans fin de ligne finale dans la référence, le fichier perd la sienne (awk et jq en ajoutent une)
mcp_eol_like() { [ ! -s "$1" ] || [ -z "$(tail -c 1 "$1")" ] || perl -pi -e 'chomp if eof' "$2"; }

# mcp_npx_version <spécification> → la version que npx lance pour elle, lue dans son dossier du cache ; rc 1 sans copie lisible
mcp_npx_version() {
  local spec="$1" name d v
  name="$(mcp_pkgname "$spec")"
  d="${npm_config_cache:-$HOME/.npm}/_npx/$(printf '%s' "$spec" | shasum -a 512 | cut -c1-16)"
  jq -e --arg n "$name" '.dependencies | has($n)' "$d/package.json" >/dev/null 2>&1 || return 1
  v="$(jq -r '.version // ""' "$d/node_modules/$name/package.json" 2>/dev/null)" || return 1
  printf '%s\n' "$v" | grep -Eq "$MCP_SEMVER" || return 1
  printf '%s\n' "$v"
}
# mcp_npm_latest <paquet> → dernière version publiée (npm view, 20 s au plus) ; rc 1 si npm ne répond pas
mcp_npm_latest() {
  local v
  printf '%s\n' "$1" | grep -Eq "$MCP_NPM_NAME" || return 1   # un nom du registre, jamais une URL, un dépôt git ou un chemin
  v="$(with_timeout 20 "${LAB_MCP_NPM:-npm}" view -- "$1" version 2>/dev/null | tail -1)" || return 1
  printf '%s\n' "$v" | grep -Eq "$MCP_SEMVER" || return 1
  printf '%s\n' "$v"
}

# mcp_pin_target <source> <portée> → « json|toml<TAB>fichier<TAB>chemin jq de l'objet des serveurs (- en TOML) » ; rc 1 si inconnu
mcp_pin_target() {
  local src="$1" scope="$2" root=""
  if [ "$scope" != global ]; then
    root="$(top_projects | awk -F '\t' -v p="$scope" '$1 == p { print $2; exit }')"; [ -n "$root" ] || return 1
  fi
  case "$src/$scope" in
    claude/global) printf 'json\t%s\t%s\n' "$HOME/.claude.json" '["mcpServers"]' ;;
    claude-settings/global) printf 'json\t%s\t%s\n' "${LAB_CLAUDE_SETTINGS:-$(claude_home)/settings.json}" '["mcpServers"]' ;;
    codex/global) printf 'toml\t%s\t-\n' "$(codex_config)" ;;
    claude/*) printf 'json\t%s\t%s\n' "$HOME/.claude.json" "$(jq -cn --arg r "$root" '["projects", $r, "mcpServers"]')" ;;
    mcp.json/*) printf 'json\t%s\t%s\n' "$root/.mcp.json" '["mcpServers"]' ;;
    codex/*) printf 'toml\t%s\t-\n' "$root/.codex/config.toml" ;;
    *) return 1 ;;
  esac
}

# mcp_edit <json|toml> <chemin jq> <nom> <ancien> <nouveau> <entrée> <sortie> : rc 0 si seul le jeton a changé, mise en forme gardée.
# JSON : remplacement dans le texte s'il est unique et que le résultat égale, pour jq, l'édition du chemin exact ; sinon réécriture
# jq si elle rend le fichier à l'identique ; sinon refus. TOML : remplacement unique dans la section, relu par l'inventaire.
mcp_edit() {
  local kind="$1" path="$2" name="$3" old="$4" new="$5" from="$6" out="$7" want n
  if [ "$kind" = json ]; then
    want="$(jq -c --argjson p "$path" --arg n "$name" --arg o "$old" --arg w "$new" "$MCP_REP_JQ" "$from" 2>/dev/null)" || return 1
    [ "$want" != "$(jq -c . "$from" 2>/dev/null)" ] || return 1   # jeton introuvable
    MCP_O="$old" MCP_W="$new" LC_ALL=C awk -v mode=json -v CNT="$out.n" "$MCP_TOKREP_AWK" "$from" >"$out" 2>/dev/null || return 1
    mcp_eol_like "$from" "$out"; n="$(cat "$out.n")"; rm -f "$out.n"
    [ "$n" = 1 ] && [ "$(jq -c . "$out" 2>/dev/null)" = "$want" ] && return 0
    jq . "$from" >"$out" 2>/dev/null || return 1; mcp_eol_like "$from" "$out"
    cmp -s "$from" "$out" || return 1   # jq ne rend pas ce fichier à l'identique : sa mise en forme changerait
    jq --argjson p "$path" --arg n "$name" --arg o "$old" --arg w "$new" "$MCP_REP_JQ" "$from" >"$out" 2>/dev/null || return 1
    mcp_eol_like "$from" "$out"; return 0
  fi
  MCP_O="$old" MCP_W="$new" LC_ALL=C awk -v mode=toml -v SEC="$name" -v CNT="$out.n" "$MCP_TOKREP_AWK" "$from" >"$out" 2>/dev/null || return 1
  mcp_eol_like "$from" "$out"; n="$(cat "$out.n")"; rm -f "$out.n"
  [ "$n" = 1 ] || return 1
  mcp_toml codex x "$out" | LC_ALL=C awk -v MCP_OPTARG="$MCP_OPTARG" -v MCP_PKG="$MCP_PKG" "$MCP_FINISH_AWK" \
    | awk -F '\t' -v n="$name" -v w="$new" '$3 == n && $5 == w { ok = 1 } END { exit !ok }'
}

# mcp_edit_all <identifiant> <entrée> <sortie> [--undo] : toutes les éditions d'un fichier ($MCP_TMP/changes), l'une après l'autre ;
# --undo les inverse (nouveau → ancien). rc 1 dès qu'une édition est refusée.
mcp_edit_all() {
  local id="$1" from="$2" out="$3" rev="${4:-}" fid kind path name old new cur="$MCP_TMP/e.cur"
  cp "$from" "$cur"
  while IFS=$'\t' read -r fid kind path name old new; do
    [ "$fid" = "$id" ] || continue
    if [ -n "$rev" ]; then mcp_edit "$kind" "$path" "$name" "$new" "$old" "$cur" "$cur.x" || return 1
    else mcp_edit "$kind" "$path" "$name" "$old" "$new" "$cur" "$cur.x" || return 1; fi
    mv "$cur.x" "$cur"
  done <"${MCP_CHANGES_FILE:-$MCP_TMP/changes}"
  mv "$cur" "$out"
}

mcp_reason() { # <raison> <lanceur> <version> → la phrase de l'aperçu
  case "$1" in
    launcher) printf '%s\n' "launched by $2, not npx: no npx cache to read the running version; pin it by hand" ;;
    no-cache) printf '%s\n' "not in the npx cache: start it once, or use lab mcp --bump" ;;
    format) printf '%s\n' "the package cannot be changed alone in its file (layout, or the same text elsewhere): pin it by hand" ;;
    unknown) printf '%s\n' "configuration file not found" ;;
    symlink) printf '%s\n' "its file is a symbolic link: pin it by hand" ;;
    npm) printf '%s\n' "npm did not answer: try again later" ;;
    latest) printf '%s\n' "already the latest published version ($3)" ;;
  esac
}

# mcp_plan <pin|bump> : $MCP_TMP/changes (« id fichier, json|toml, chemin jq, nom, ancien, nouveau »), $MCP_TMP/files
# (« id, json|toml, fichier, portée, source »), $MCP_TMP/view (lignes C et S), $MCP_TMP/kv ; chaque fichier essayé sur une copie.
mcp_plan() {
  local mode="$1" src scope name pkg pin ln pname v new tg kind file path id w
  : >"$MCP_TMP/changes"; : >"$MCP_TMP/files"; : >"$MCP_TMP/view"; : >"$MCP_TMP/kv"; : >"$MCP_TMP/latest"
  mcp_skip() { # <raison> [version]
    printf 'MCP_SKIP=%s %s %s %s %s\n' "$scope" "$src" "$name" "$pkg" "$1" >>"$MCP_TMP/kv"
    printf 'S\t%s\t%s\t%s\t%s\n' "$scope" "$src" "$name" "$(mcp_reason "$1" "$ln" "${2:-}")" >>"$MCP_TMP/view"
  }
  while IFS=$'\t' read -r src scope name _ pkg pin _ ln; do
    [ -n "$name" ] && [ "$pkg" != - ] || continue
    case "$ln" in npx|npm) ;; *) [ "$pin" = no ] && mcp_skip launcher; continue ;; esac
    [ "$mode" = bump ] || [ "$pin" = no ] || continue
    pname="$(mcp_pkgname "$pkg")"
    if [ "$mode" = pin ]; then v="$(mcp_npx_version "$pkg")" || { mcp_skip no-cache; continue; }
    else
      v="$(awk -F '\t' -v n="$pname" '$1 == n { print $2; exit }' "$MCP_TMP/latest")"
      if [ -z "$v" ]; then v="$(mcp_npm_latest "$pname")" || v=-; printf '%s\t%s\n' "$pname" "$v" >>"$MCP_TMP/latest"; fi
      [ "$v" != - ] || { mcp_skip npm; continue; }
      [ "$pkg" != "$pname@$v" ] || { mcp_skip latest "$v"; continue; }
    fi
    new="$pname@$v"
    tg="$(mcp_pin_target "$src" "$scope")" || tg=""
    kind="${tg%%$'\t'*}"; file="${tg#*$'\t'}"; path="${file#*$'\t'}"; file="${file%%$'\t'*}"
    [ -n "$tg" ] && [ -f "$file" ] || { mcp_skip unknown; continue; }
    [ ! -L "$file" ] || { mcp_skip symlink; continue; }
    id="$(awk -F '\t' -v f="$file" '$3 == f { print $1; exit }' "$MCP_TMP/files")"
    if [ -z "$id" ]; then
      id="$(($(wc -l <"$MCP_TMP/files") + 1))"; printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$kind" "$file" "$scope" "$src" >>"$MCP_TMP/files"
      cp "$file" "$MCP_TMP/w.$id"
    fi
    w="$MCP_TMP/w.$id"
    mcp_edit "$kind" "$path" "$name" "$pkg" "$new" "$w" "$w.x" || { rm -f "$w.x"; mcp_skip format; continue; }
    mv "$w.x" "$w"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$kind" "$path" "$name" "$pkg" "$new" >>"$MCP_TMP/changes"
    printf 'MCP_CHANGE=%s %s %s %s %s\n' "$scope" "$src" "$name" "$pkg" "$new" >>"$MCP_TMP/kv"
    printf 'C\t%s\t%s\t%s\t%s\t%s\n' "$scope" "$src" "$name" "$pkg" "$new" >>"$MCP_TMP/view"
  done < <(mcp_inventory)
  unset -f mcp_skip
}

# mcp_agree <résumé> <commande avec --yes> <oui=0|1> → rc 0 si l'écriture est accordée ; MCP_ACTION= declined|preview sinon
mcp_agree() {
  local answer=""
  [ "$3" = 0 ] || return 0
  if [ ! -t 0 ]; then
    printf 'F\t%s\n' "$1 Nothing written: $2 applies it after agreement." | LC_ALL=C awk -v w="$(onboard_cols)" "$MCP_PIN_VIEW_AWK" >&2
    kv MCP_ACTION preview; return 1
  fi
  printf 'F\t%s\n' "$1" | LC_ALL=C awk -v w="$(onboard_cols)" "$MCP_PIN_VIEW_AWK" >&2
  printf 'Apply? [y/N] ' >&2
  IFS= read -r answer || answer=""
  case "$answer" in y|Y|yes|YES|Yes) return 0 ;; esac
  kv MCP_ACTION declined; log "Nothing written."; return 1
}

# mcp_write <fichier> <contenu prêt> <empreinte attendue> : remplace le fichier (temporaire dans son dossier, mode gardé, mv) s'il
# porte encore l'empreinte attendue ; rc 1 sinon, rien d'écrit
mcp_write() {
  local f="$1" tmp
  tmp="$(mktemp "$(dirname "$f")/.lab-mcp.XXXXXX" 2>/dev/null)" || return 1   # nom imprévisible, créé par mktemp : jamais un lien posé d'avance
  if ! cp -p "$f" "$tmp" 2>/dev/null || ! cat "$2" >"$tmp"; then rm -f "$tmp"; return 1; fi
  [ "$(mcp_sha "$f")" = "$3" ] || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f"
}

# mcp_change <pin|bump> <oui=0|1> : aperçu, accord, sauvegarde, écriture
mcp_change() {
  local mode="$1" yes="$2" n nf bk id kind file scope src try sha0 done_=0 title
  MCP_TMP="$(mktemp -d "${TMPDIR:-/tmp}/lab-mcp.XXXXXX")"; trap 'rm -rf "$MCP_TMP"' EXIT
  mcp_plan "$mode"
  n="$(wc -l <"$MCP_TMP/changes" | tr -d ' ')"; nf="$(cut -f1 "$MCP_TMP/changes" | sort -u | wc -l | tr -d ' ')"
  kv MCP_MODE "$mode"; cat "$MCP_TMP/kv"; kv MCP_CHANGES "$n"
  if [ "$mode" = pin ]; then title="Pin each tool server (MCP) to the version that runs (npx cache, no network):"
  else title="Move each tool server (MCP) to the latest version published on npm:"; fi
  { printf 'T\t%s\n' "$title"; grep '^C' "$MCP_TMP/view" || true; grep '^S' "$MCP_TMP/view" || true; } | LC_ALL=C awk -v w="$(onboard_cols)" "$MCP_PIN_VIEW_AWK" >&2
  if [ "$n" = 0 ]; then printf 'F\tNothing to change.\n' | LC_ALL=C awk -v w="$(onboard_cols)" "$MCP_PIN_VIEW_AWK" >&2; kv MCP_ACTION none; return 0; fi
  mcp_agree "$n change(s) in $nf file(s); each file is saved first and lab mcp --undo restores it." "lab mcp --$mode --yes" "$yes" || return 0
  bk="$LAB_STATE/mcp-pin/$(date -u +%Y%m%dT%H%M%SZ)-$(printf '%07d' "$$")"   # le tri des noms suit le temps, même dans la même seconde
  (umask 077; mkdir -p "$bk") || die "backup folder $bk cannot be created: nothing written"
  cp "$MCP_TMP/changes" "$bk/changes.tsv"; : >"$bk/files.tsv"
  while IFS=$'\t' read -r id kind file scope src; do
    awk -F '\t' -v i="$id" '$1 == i { f = 1 } END { exit !f }' "$MCP_TMP/changes" || continue
    for try in 1 2 3; do
      cp -p "$file" "$bk/$id.orig" || break; sha0="$(mcp_sha "$bk/$id.orig")"
      MCP_CHANGES_FILE="$MCP_TMP/changes" mcp_edit_all "$id" "$bk/$id.orig" "$MCP_TMP/new.$id" || { try=refused; break; }
      if mcp_write "$file" "$MCP_TMP/new.$id" "$sha0"; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$kind" "$file" "$(mcp_sha "$MCP_TMP/new.$id")" "$scope" "$src" >>"$bk/files.tsv"
        kv MCP_WRITTEN "$scope $src"; done_=$((done_ + 1)); try=ok; break
      fi
    done
    case "$try" in
      ok) ;; refused) warn "$scope · $src: file changed since the preview and no longer takes the change, left as it was" ;;
      *) warn "$scope · $src: file kept changing while writing, left as it was; run lab mcp --$mode again" ;;
    esac
  done <"$MCP_TMP/files"
  kv MCP_BACKUP "$bk"
  if [ "$done_" = 0 ]; then mv "$bk" "$bk.undone" 2>/dev/null || true; kv MCP_ACTION none; return 0; fi
  kv MCP_ACTION applied; log "$done_ file(s) written; lab mcp --undo restores them from $bk."
}

# mcp_undo <oui=0|1> : la dernière sauvegarde non annulée ; fichier inchangé depuis l'écriture → copie exacte de la sauvegarde ;
# réécrit entre-temps → seuls les jetons sont remis (le reste de la session gardé) ; jeton modifié à la main → laissé, nommé.
mcp_undo() {
  local yes="$1" root="$LAB_STATE/mcp-pin" bk="" d id kind file sha scope src how n=0 sha0 ok
  MCP_TMP="$(mktemp -d "${TMPDIR:-/tmp}/lab-mcp.XXXXXX")"; trap 'rm -rf "$MCP_TMP"' EXIT
  kv MCP_MODE undo
  for d in "$root"/*/; do d="${d%/}"; case "$d" in *.undone|*'*') ;; *) [ -f "$d/files.tsv" ] && bk="$d" ;; esac; done
  if [ -z "$bk" ]; then kv MCP_ACTION none; log "No lab mcp --pin or --bump to undo."; return 0; fi
  : >"$MCP_TMP/view"; : >"$MCP_TMP/how"
  while IFS=$'\t' read -r id kind file sha scope src; do
    if [ "$(mcp_sha "$file")" = "$sha" ]; then how=exact; d="the file saved before the change, byte for byte"
    else how=merged; d="rewritten since: only the package versions are put back"; fi
    printf '%s\t%s\n' "$id" "$how" >>"$MCP_TMP/how"; n=$((n + 1))
    printf 'C\t%s\t%s\t%s\t%s\t\n' "$scope" "$src" "$(basename "$file")" "$d" >>"$MCP_TMP/view"
  done <"$bk/files.tsv"
  kv MCP_BACKUP "$bk"; kv MCP_CHANGES "$n"
  { printf 'T\t%s\n' "Restore the files saved by the last lab mcp --pin or --bump:"; cat "$MCP_TMP/view"; } \
    | LC_ALL=C awk -v w="$(onboard_cols)" "$MCP_PIN_VIEW_AWK" >&2
  mcp_agree "$n file(s) to restore." "lab mcp --undo --yes" "$yes" || return 0
  n=0
  while IFS=$'\t' read -r id kind file sha scope src; do
    how="$(awk -F '\t' -v i="$id" '$1 == i { print $2 }' "$MCP_TMP/how")"; ok=0
    for _ in 1 2 3; do
      cp "$file" "$MCP_TMP/cur" || break; sha0="$(mcp_sha "$MCP_TMP/cur")"
      if [ "$sha0" = "$sha" ]; then how=exact; cp "$bk/$id.orig" "$MCP_TMP/new"
      else how=merged; MCP_CHANGES_FILE="$bk/changes.tsv" mcp_edit_all "$id" "$MCP_TMP/cur" "$MCP_TMP/new" --undo || { how=kept; break; }; fi
      if mcp_write "$file" "$MCP_TMP/new" "$sha0"; then ok=1; break; fi
    done
    [ "$ok" = 1 ] || how=kept
    kv MCP_RESTORED "$scope $src $how"
    if [ "$how" = kept ]; then warn "$scope · $src: package versions changed by hand since, file left as it is"; else n=$((n + 1)); fi
  done <"$bk/files.tsv"
  if [ "$n" = 0 ]; then kv MCP_ACTION none; log "Nothing restored: the save $bk is kept."; return 0; fi
  mv "$bk" "$bk.undone"
  kv MCP_ACTION applied; log "Restored from $bk."
}
