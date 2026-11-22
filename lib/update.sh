# shellcheck shell=bash
# shellcheck disable=SC1112 # Apostrophes françaises dans les diagnostics.
# shellcheck disable=SC2030,SC2031 # Chaque commande conserve ses variables et traps dans son sous-shell.
# shellcheck disable=SC2153 # LAB_SETUP_CODEX est fourni par _setup_configuration.
# Mise à jour explicite : source choisie ou distribution privée, sans activation.
# _update_say <message> : une ligne humaine sur stderr, par lab_say (lib/install.sh) quand il est chargé ; sinon intacte
# (release-local.sh et doctor_product.sh chargent update.sh seul).
_update_say() { if declare -F lab_say >/dev/null; then lab_say "$*"; else printf 'lab: %s
' "$*" >&2; fi; }
_update_error() { _update_say "$*"; _update_note; return 1; }
# Contrat d'échec (lot 02 de livrer-sans-friction) : la première cause notée (LAB_UPDATE_REASON, LAB_UPDATE_FILE) et chaque
# RESULT écrit vont dans LAB_UPDATE_STATUS, que cmd_update relit à la sortie du sous-shell ; aucune note hors de cmd_update.
_update_note() {
  [ -n "${LAB_UPDATE_STATUS:-}" ] && ! grep -q '^REASON=' "$LAB_UPDATE_STATUS" 2>/dev/null || return 0
  printf 'REASON=%s\nFILE=%s\n' "${LAB_UPDATE_REASON:-layout}" "${LAB_UPDATE_FILE:-}" >>"$LAB_UPDATE_STATUS" 2>/dev/null || true
}
_update_result() { kv RESULT "$1"; [ -z "${LAB_UPDATE_STATUS:-}" ] || printf 'RESULT=%s\n' "$1" >>"$LAB_UPDATE_STATUS" 2>/dev/null || true; }
# _update_news <version> → la ligne des nouveautés de cette version sur treelab.sh (lot 03 de vitrine) : partie fixe courte, à part.
_update_news() { printf "What's new: https://treelab.sh/en/whats-new/#v%s\n" "$1"; }
_update_cause() { LAB_UPDATE_REASON="$1" LAB_UPDATE_FILE="${2:-}"; }
# _update_local <url> : chemin d'une source file://, vide pour une URL distante.
_update_local() { case "$1" in file:///*) printf '%s\n' "${1#file://}" ;; esac; }
_update_usage() { _update_say 'Usage: treelab update [--rollback|--resume|--catalogue|--adopt] [--json].'; return 2; }
LAB_UPDATE_LICENSE_REMEDY='No license: activate your key with curl -fsSL https://treelab.sh/install | bash'
_update_version() { [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; }
_update_previous_format() {
  [ -f "$1" ] && [ ! -L "$1" ] && jq -es 'length==1 and (.[0]|type=="object" and .format==1 and
    (.path|type=="string") and (.version|type=="string") and
    (.digest|type=="string" and test("^[0-9a-f]{64}$")))' "$1" >/dev/null 2>&1
}
_update_compare() {
  # Comparaison décimale sans limite entière de bash/jq et sans ordre lexical 9/10.
  LC_ALL=C awk -v a="$1" -v b="$2" 'BEGIN {
    split(a,x,"."); split(b,y,"."); r=0
    for(i=1;i<=3;i++) {
      if(length(x[i])!=length(y[i])) {r=(length(x[i])>length(y[i])?1:-1); break}
      if("x" x[i]!="x" y[i]) {r=("x" x[i]>"x" y[i]?1:-1); break}
    }
    print r
  }'
}
_update_url() {
  # file:// est une source explicitement choisie, jamais un secours réseau.
  case "$1" in *[[:cntrl:]]*|'') return 1 ;; https://?*|file:///?*) return 0 ;; *) return 1 ;; esac
}
_update_fetch() {
  local url="$1" output="$2" timeout="${3:-30}" connect="${4:-5}"
  _update_url "$url" || return 1
  case "$url" in
    file:///*) [ -f "${url#file://}" ] && cp "${url#file://}" "$output" 2>/dev/null ;;
    https://*) curl --proto '=https' --proto-redir '=https' --location --fail --silent \
      --connect-timeout "$connect" --max-time "$timeout" --max-filesize 134217728 \
      --output "$output" -- "$url" 2>/dev/null ;;
  esac
}
_update_catalogue() {
  local input="$1"
  jq -es '
    def text: type=="string" and length>0 and (explode|all(.>=32 and .!=127));
    length==1 and (.[0] | type=="object" and
      (.version|text and test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$")) and
      (.url|text and (startswith("https://") or startswith("file:///"))) and
      (.sha256|text and test("^[A-Fa-f0-9]{64}$")))
  ' "$input" >/dev/null 2>&1 || return 1
  LAB_UPDATE_VERSION="$(jq -r .version "$input")"
  LAB_UPDATE_URL="$(jq -r .url "$input")"
  LAB_UPDATE_SHA="$(jq -r '.sha256|ascii_downcase' "$input")"
  _update_url "$LAB_UPDATE_URL"
}
_update_tree() {
  local root="$1" version="$2" file part
  [ -d "$root" ] && [ ! -L "$root" ] || return 1
  for part in bin lib hooks skills agents templates scripts; do
    [ -d "$root/$part" ] && [ ! -L "$root/$part" ] || return 1
  done
  for file in VERSION .release templates/global-instructions.md; do
    [ -f "$root/$file" ] && [ ! -L "$root/$file" ] || return 1
  done
  printf '%s\n' "$version" | cmp -s - "$root/VERSION" || return 1
  for file in bin/lab install.sh hooks/session-start.sh hooks/session-end.sh hooks/guard-tool.sh hooks/guard-bash.sh; do
    [ -f "$root/$file" ] && [ ! -L "$root/$file" ] && [ -x "$root/$file" ] || return 1
  done
  # Les bibliothèques utilisées par la version courante font partie du protocole d'une candidate. Une release
  # précédente peut en précéder plusieurs (0.1.1 : ni onboard.sh ni update_private.sh, constat du couloir api le
  # 2026-09-30) : le retour hors ligne ne les charge pas et l'empreinte complète enregistrée la vérifie ensuite.
  [ "${3:-}" != previous ] || return 0
  for file in "$LAB_ROOT"/lib/*.sh; do
    [ -f "$root/lib/${file##*/}" ] && [ ! -L "$root/lib/${file##*/}" ] || return 1
  done
}
_update_archive() {
  local archive="$1" temp="$2" version="$3" sum
  sum="$(shasum -a 256 <"$archive" | cut -d ' ' -f 1)" || return
  [ "$sum" = "$LAB_UPDATE_SHA" ] || { _update_error 'The archive checksum is wrong. Installation kept; get a trusted catalogue, then run treelab update again.'; return 1; }
  # bsdtar échappe les noms non imprimables ; la grammaire ASCII du package les
  # refuse également. Les deux vues utilisent les noms effectifs (PAX compris).
  LC_ALL=C tar -tzf "$archive" >"$temp/names" 2>/dev/null &&
    LC_ALL=C tar --numeric-owner -tvzf "$archive" >"$temp/members" 2>/dev/null || return 1
  LC_ALL=C awk -v root="treelab-$version" '
    NR==FNR {
      if($0 !~ /^[A-Za-z0-9_.\/-]+$/) exit 1
      name=$0; sub(/\/$/,"",name)
      n=split(name,p,"/"); if(p[1]!=root || seen[name]++) exit 1
      for(i=1;i<=n;i++) if(p[i]=="" || p[i]=="." || p[i]=="..") exit 1
      count++; next
    }
    {
      if(NF!=9 || $1 !~ /^[-d][rwx-][rwx-][rwx-][rwx-][rwx-][rwx-][rwx-][rwx-][rwx-]$/) exit 1
      name=$9; sub(/\/$/,"",name)
      if(!(name in seen) || types[name]!="") exit 1
      types[name]=substr($1,1,1); rows++
    }
    END {
      if(count==0 || count!=rows) exit 1
      for(name in types) {
        parent=name
        while(sub(/\/[^\/]+$/,"",parent)) if(parent in types && types[parent]!="d") exit 1
      }
    }
  ' "$temp/names" "$temp/members" || return 1
  mkdir -m 700 "$temp/extracted" || return
  COPYFILE_DISABLE=1 tar --no-same-owner -xzf "$archive" -C "$temp/extracted" 2>/dev/null || return
  LAB_UPDATE_CANDIDATE="$temp/extracted/treelab-$version"
  _update_tree "$LAB_UPDATE_CANDIDATE" "$version"
}
_update_guard() {
  [ -f "$LAB_ROOT/.release" ] && [ ! -L "$LAB_ROOT/.release" ] || {
    _update_error 'This copy is a development checkout. Use a distributed installation for treelab update.'; return 1;
  }
  LAB_UPDATE_HOME="$HOME/.lab"
  LAB_UPDATE_CURRENT="$LAB_UPDATE_HOME/current"
  LAB_UPDATE_RELEASES="$LAB_UPDATE_HOME/releases"
  # LAB_UPDATE_FROM : la release quittée. --adopt (lot 22) est lancé depuis la nouvelle, extraite par l'installeur dans
  # releases/treelab-<VERSION> ; current désigne encore l'ancienne pose (0.1.1), dont le client refuse les sessions vivantes.
  LAB_UPDATE_FROM="$LAB_ROOT"
  if [ "${LAB_UPDATE_ADOPT:-no}" = yes ]; then
    LAB_UPDATE_FROM="$LAB_UPDATE_RELEASES/treelab-$(head -1 "$LAB_UPDATE_CURRENT/VERSION" 2>/dev/null)"
    if ! { [ "$LAB_ROOT" = "$LAB_UPDATE_RELEASES/treelab-$(head -1 "$LAB_ROOT/VERSION")" ] &&
      [ -f "$LAB_UPDATE_FROM/.release" ] && [ ! -L "$LAB_UPDATE_FROM/.release" ]; }; then
      _update_error 'Layout cannot be adopted: run releases/treelab-<VERSION>/bin/lab, with current linked to a distributed release.'; return 1
    fi
  fi
  LAB_UPDATE_OLD="$(cat "$LAB_UPDATE_FROM/VERSION" 2>/dev/null)"
  _update_version "$LAB_UPDATE_OLD" || { LAB_UPDATE_FILE="$LAB_UPDATE_FROM/VERSION"; _update_error 'Local version unknown or invalid. Restore VERSION from the installed distribution.'; return 1; }
  printf '%s\n' "$LAB_UPDATE_OLD" | cmp -s - "$LAB_UPDATE_FROM/VERSION" || {
    LAB_UPDATE_FILE="$LAB_UPDATE_FROM/VERSION"; _update_error 'VERSION must hold a single line. Restore the file from the installed distribution.'; return 1;
  }
  _txn_plain_path "$LAB_UPDATE_HOME/previous-release" || {
    LAB_UPDATE_FILE="$LAB_UPDATE_HOME/previous-release"; _update_error 'Version metadata is a link. Keep its target and restore previous-release as a regular file before treelab update.'; return 1;
  }
  if [ "${LAB_UPDATE_RESUME:-no}" != yes ] && _txn_exists "$LAB_UPDATE_HOME/previous-release" && ! _update_previous_format "$LAB_UPDATE_HOME/previous-release"; then
    LAB_UPDATE_FILE="$LAB_UPDATE_HOME/previous-release"; _update_error 'Previous version metadata is incompatible. Keep this file and restore previous-release before treelab update.'; return 1
  fi
  if [ "${LAB_UPDATE_RESUME:-no}" != yes ] && _txn_exists "$LAB_UPDATE_HOME/update-pending"; then
    LAB_UPDATE_REASON=operation LAB_UPDATE_FILE="$LAB_UPDATE_HOME/update-pending"
    _update_error 'Update in progress or restore pending. Wait for it to finish; if it was interrupted, run treelab update --resume.'; return 1
  fi
  if ! { _txn_plain_path "$LAB_UPDATE_RELEASES" && [ -d "$LAB_UPDATE_RELEASES" ] &&
    [ -L "$LAB_UPDATE_CURRENT" ] && [ "$LAB_UPDATE_CURRENT" -ef "$LAB_UPDATE_FROM" ] &&
    [ "$LAB_UPDATE_FROM" = "$LAB_UPDATE_RELEASES/treelab-$LAB_UPDATE_OLD" ]; }; then
    _update_error 'Unsupported release layout. Keep current and the releases; restore the distributed installation before treelab update.'; return 1
  fi
  export LAB_SETUP_MODE=setup LAB_SETUP_RESUME="${LAB_UPDATE_RESUME:-no}"
  preflight || { [ -z "${LAB_TXN_PENDING:-}" ] || LAB_UPDATE_REASON=operation; _update_note; return 1; }
  _setup_info || return 1
  if [ -z "$LAB_SETUP_INFO" ] || [ "$(printf '%s' "$LAB_SETUP_INFO" | jq -r .root)" != "$LAB_UPDATE_CURRENT" ] || _setup_all_done; then
    _update_error 'Distributed installation missing or incompatible. Finish the first installation before treelab update.'; return 1
  fi
  _setup_configuration
}
_update_register() {
  merge_register_commands
  LAB_TXN_COMMANDS+=('_update_switch:_update_restore')
}
_update_public_diagnostics() {
  # Traduire les diagnostics du moteur dans le parcours public de cette commande.
  # shellcheck disable=SC2329 # Appelé par les primitives de lib/install.sh.
  _txn_message() {
    case "$*" in
      'Inverse '*) _update_say 'A file could not be restored. Check the permissions of its folder, then run treelab update --resume.' ;;
      'Fix the shown cause (permissions or inverse)'*) : ;;
      'Failed (code '*) _update_say 'The change failed. Restoring the previous version.' ;;
      *txn_rollback*) _update_say 'Restore needed. Keep the backups and run treelab update --resume.' ;;
      *) _update_say "$*" ;;
    esac
  }
}
_update_actual_version() {
  local value
  value="$("$LAB_UPDATE_CURRENT/bin/lab" --version 2>/dev/null)" || value=''
  value="${value#VERSION=}"
  if _update_version "$value"; then printf '%s\n' "$value"; else printf 'unknown\n'; fi
}
_setup_operation_guard() {
  if _txn_exists "$HOME/.lab/update-pending"; then
    _update_error 'Update restore pending. Finish treelab update --resume before setup or uninstall.'; return 1
  fi
  _update_register
}
_update_retained_target() {
  case "$1" in "$HOME/.lab/current"|"$HOME/.lab/previous-release") ;; *) return 1 ;; esac
  [ -n "${LAB_SETUP_INFO:-}" ] || return 1
  [ "$(printf '%s' "$LAB_SETUP_INFO" | jq -r .root)" = "$HOME/.lab/current" ]
}
_update_switch() {
  local target="$1" source="$2" mode="$3" temp rc=0
  temp="$(mktemp -d "$(dirname "$target")/.treelab-switch.XXXXXXXX")" || return
  ln -s "$source" "$temp/link" && chmod -h "$mode" "$temp/link" && mv -fh "$temp/link" "$target" || rc=$?
  rm -R "$temp" || return
  return "$rc"
}
_update_restore() { _update_switch "$1" "$4" "$5"; }
_update_client_removed() {
  local target="$1" line found=''
  _txn_exists "$target" && return 1
  [ -f "$LAB_TXN_MANIFEST" ] || return 1
  while IFS= read -r line; do
    [ "$line" != $'treelab-install\t1' ] || continue
    _txn_parse "$line" || return 1
    if [ "${LAB_TXN_FIELDS[3]}" = "$target" ] && [ "${LAB_TXN_FIELDS[2]}" != skip ]; then found="$line"; fi
  done <"$LAB_TXN_MANIFEST"
  [ -n "$found" ] && _txn_parse "$found" || return 1
  [ "${LAB_TXN_FIELDS[5]}" != absent ]
}
_update_remove_obsolete() {
  local item name dest
  for item in "$LAB_UPDATE_FROM"/skills/*; do
    [ -d "$item" ] || continue
    name="${item##*/}"
    [ ! -d "$LAB_UPDATE_CANDIDATE/skills/$name" ] || continue
    if [ "$LAB_SETUP_CLAUDE" = yes ]; then install_link_remove "$(claude_home)/skills/$name" || return; fi
    if [ "$LAB_SETUP_CODEX" = yes ]; then install_link_remove "$(agents_home)/skills/$name" || return; fi
  done
  for item in "$LAB_UPDATE_FROM"/agents/*.md; do
    [ -f "$item" ] || continue
    name="${item##*/}"
    [ ! -f "$LAB_UPDATE_CANDIDATE/agents/$name" ] || continue
    if [ "$LAB_SETUP_CLAUDE" = yes ]; then install_link_remove "$(claude_home)/agents/$name" || return; fi
    if [ "$LAB_SETUP_CODEX" = yes ]; then
      dest="$LAB_STATE/generated/codex-agents/${name%.md}.toml"
      install_link_remove "$(codex_home)/agents/${name%.md}.toml" && _merge_generated_remove "$dest" || return
    fi
  done
}
_update_save() {
  chmod 600 "$2" || return 1
  if [ -f "$1" ]; then record_op modify "$1" "$2"; else record_op create "$1" "$2"; fi
}
_update_finish() {
  local rc="$1" adopt_result=refused
  trap - ERR EXIT INT TERM
  if [ "${LAB_UPDATE_COMMITTED:-no}" = yes ]; then
    adopt_result=interrupted
    if [ -n "${LAB_TXN_ACTIVE:-}" ]; then rm -f "$LAB_TXN_ACTIVE/rollback" || rc=1; fi
    if [ "$rc" = 0 ]; then rm -f "$LAB_UPDATE_HOME/update-pending" || rc=1; fi
    LAB_TXN_ACTIVE=''
  elif [ -n "${LAB_TXN_ACTIVE:-}" ]; then
    if txn_rollback; then
      rm -f "$LAB_UPDATE_HOME/update-pending" || { rc=1; adopt_result=interrupted; }
    else
      _setup_resume_capture || true
      _setup_message 'Restore incomplete. Keep the backups; run treelab update --resume.'
      rc=1; adopt_result=interrupted
    fi
    _setup_message "Running version: $(_update_actual_version). Check with treelab --version."
  elif [ "${LAB_UPDATE_STARTED:-no}" = yes ]; then
    # record_op peut déjà avoir achevé l'inverse lors d'une erreur prise en charge.
    rm -f "$LAB_UPDATE_HOME/update-pending" || { rc=1; adopt_result=interrupted; }
    _setup_message "Version $(_update_actual_version) restored. Check with treelab doctor before trying treelab update again."
  fi
  # Contrat --adopt (fiche du lot 22) : refused = rien modifié (transaction défaite) ; interrupted = pose validée ou
  # restauration incomplète, la release lancée peut être active : reprise par treelab update --resume.
  if [ "$rc" != 0 ] && [ "${LAB_UPDATE_ADOPT:-no}" = yes ]; then
    _update_result "$adopt_result"; [ "$adopt_result" != refused ] || kv REASON "${LAB_UPDATE_REASON:-layout}"; rc=1
  elif [ "$rc" != 0 ]; then _update_note
  fi
  operation_release
  [ -z "${temp:-}" ] || rm -R "$temp"
  return "$rc"
}
_update_previous() {
  local file="$LAB_UPDATE_HOME/previous-release" digest
  if ! { _txn_plain_path "$file" && _update_previous_format "$file"; }; then
    LAB_UPDATE_FILE="$file"; _update_error 'Previous version missing or incompatible. Keep the active version; a successful update prepares the rollback.'; return 1
  fi
  LAB_UPDATE_VERSION="$(jq -r .version "$file")"
  LAB_UPDATE_CANDIDATE="$(jq -r .path "$file")"
  digest="$(jq -r .digest "$file")"
  # un retour après adoption ramène la pose de l'installeur : RESULT=restored (contrat du lot 22)
  LAB_UPDATE_RESTORE="$(jq -r 'if .adopted==true then "yes" else "no" end' "$file")"
  if ! { _update_version "$LAB_UPDATE_VERSION" &&
    [ "$LAB_UPDATE_CANDIDATE" = "$LAB_UPDATE_RELEASES/treelab-$LAB_UPDATE_VERSION" ] &&
    [ "$LAB_UPDATE_CANDIDATE" != "$LAB_ROOT" ] && _txn_plain_path "$LAB_UPDATE_CANDIDATE" &&
    _update_tree "$LAB_UPDATE_CANDIDATE" "$LAB_UPDATE_VERSION" previous &&
    [ "$(_txn_fingerprint "$LAB_UPDATE_CANDIDATE")" = "$digest" ]; }; then
    LAB_UPDATE_FILE="$LAB_UPDATE_CANDIDATE"; _update_error 'Previous version altered or outside the allowed folder. Keep the active version and restore the saved release before treelab update --rollback.'; return 1
  fi
}
_update_resume() {
  local file="$LAB_UPDATE_HOME/update-pending" data id phase
  operation_acquire || { _update_cause operation; _update_error 'Another operation is running. Wait for it to finish, then run treelab update --resume again.'; return 1; }
  trap 'operation_release' EXIT
  _update_guard || return 1
  if ! _txn_exists "$file"; then
    if [ -n "$LAB_TXN_PENDING" ]; then
      _update_error 'Installation restore pending. Use treelab uninstall --resume for this operation.'; return 1
    fi
    _update_result current; kv VERSION "$LAB_UPDATE_OLD"; _setup_message 'Nothing to resume; installation unchanged.'; return 0
  fi
  _update_cause layout "$file"
  _txn_plain_path "$file" && [ -f "$file" ] && [ "$(stat -f %Lp "$file")" = 600 ] || {
    _update_error 'Invalid resume journal. Keep the backups and restore update-pending before resuming.'; return 1;
  }
  data="$(cat "$file")"; id="${data% *}"; phase="${data#* }"
  if ! { [[ "$id" =~ ^txn\.[A-Za-z0-9]+$ ]] && { [ "$phase" = pending ] || [ "$phase" = committed ]; }; }; then
    _update_error 'Incompatible resume journal. Keep the backups and restore update-pending.'; return 1;
  fi
  if [ "$phase" = committed ]; then
    _txn_committed "$id" && { [ -z "$LAB_TXN_PENDING" ] || [ "$LAB_TXN_PENDING" = "$LAB_TXN_BACKUPS/$id" ]; } || return 1
    rm -f "$LAB_TXN_BACKUPS/$id/rollback" && rm "$file" || return 1
  else
    if [ -n "$LAB_TXN_PENDING" ]; then
      [ "$LAB_TXN_PENDING" = "$LAB_TXN_BACKUPS/$id" ] || return 1
      _setup_resume_guard "$LAB_TXN_PENDING" 'treelab update --resume' || {
        _setup_message 'Resume paused; once the recent data is kept safe, run treelab update --resume again.'; return 1;
      }
      if txn_rollback; then :; else
        _setup_message 'Restore incomplete. Keep the backups and run treelab update --resume again once the cause is fixed.'; return 1
      fi
    elif [ -d "$LAB_TXN_BACKUPS/$id" ]; then
      _update_error 'Inconsistent resume journal. Keep the backups; restore its state before treelab update --resume.'; return 1
    fi
    rm "$file" || return 1
  fi
  _update_result restored
  "$HOME/.local/bin/treelab" --version
  _setup_message 'Resume finished. Check the active version with treelab --version.'
}
cmd_reapply() (
  local temp
  LAB_UPDATE_COMMITTED=no LAB_UPDATE_STARTED=no LAB_UPDATE_RESUME=no
  _update_public_diagnostics
  _update_register
  _update_guard || return 1
  LAB_UPDATE_VERSION="$LAB_UPDATE_OLD" LAB_UPDATE_CANDIDATE="$LAB_ROOT"
  temp="$(mktemp -d /private/tmp/treelab-reapply.XXXXXXXX)" || return
  trap 'rm -R "$temp"' EXIT
  LAB_UPDATE_REAPPLY=yes
  _update_apply
)
_update_apply() {
  local destination="$LAB_UPDATE_RELEASES/treelab-$LAB_UPDATE_VERSION" mode before old_digest target_digest
  [ "${LAB_UPDATE_HELD:-no}" = yes ] || operation_acquire || { _update_cause operation; _update_error 'Another operation is running. Wait for it to finish, then run treelab update again.'; return 1; }
  trap 'rc=$?; _update_finish "$rc"; exit $?' EXIT
  trap 'exit 1' INT TERM
  _update_guard || return 1
  LAB_SETUP_REAPPLY=yes LAB_SETUP_SOURCE="$LAB_UPDATE_CANDIDATE"
  export LAB_SETUP_REAPPLY LAB_SETUP_SOURCE
  mkdir "$temp/plan" || return
  setup_plan "$temp/plan" || return 1
  old_digest="$(_txn_fingerprint "$LAB_UPDATE_FROM")" && target_digest="$(_txn_fingerprint "$LAB_UPDATE_CANDIDATE")" || return
  if _txn_exists "$destination"; then
    _txn_plain_path "$destination" && [ -d "$destination" ] &&
      [ "$(_txn_fingerprint "$destination")" = "$target_digest" ] || {
      LAB_UPDATE_FILE="$destination"; _update_error 'A release with this name exists with different content. Keep it and get the matching distribution.'; return 1;
    }
  else
    # Publication du code validé avant la transaction des intégrations. Une
    # candidate conservée après échec est inerte et sera revérifiée au prochain appel.
    mv "$LAB_UPDATE_CANDIDATE" "$destination" || return 1
  fi
  LAB_UPDATE_CANDIDATE="$destination"
  if [ "${LAB_PREFLIGHT_SESSIONS:-yes}" != no ]; then
    LAB_PREFLIGHT_ERRORS=0; _preflight_sessions
    [ "$LAB_PREFLIGHT_ERRORS" = 0 ] || return 1
  fi
  set -E
  txn_begin || return 1
  # L'appelant possède l'unique issue jusqu'à la publication du point de succès.
  _txn_restore_shell
  trap 'rc=$?; _update_finish "$rc"; exit $?' EXIT
  trap 'exit 1' INT TERM
  _txn_write "$LAB_UPDATE_HOME/update-pending" "$LAB_TXN_ID pending" || return 1
  LAB_UPDATE_STARTED=yes
  _txn_write "$LAB_TXN_ACTIVE/rollback" pending || return 1
  _update_remove_obsolete || return 1
  _setup_apply "$temp/plan/plan" yes || return 1
  _setup_reapproval_publish "$temp/plan"
  if [ "${LAB_UPDATE_REAPPLY:-no}" != yes ]; then
  before="$(readlink "$LAB_UPDATE_CURRENT")"; mode="$(stat -f %Lp "$LAB_UPDATE_CURRENT")"
  record_op cmd "$LAB_UPDATE_CURRENT" _update_switch _update_restore "$destination" "$mode" "$before" "$mode" || return 1
  jq -cn --arg path "$LAB_UPDATE_FROM" --arg version "$LAB_UPDATE_OLD" --arg digest "$old_digest" \
    --argjson adopted "$([ "${LAB_UPDATE_ADOPT:-no}" = yes ] && echo true || echo false)" \
    '{format:1,path:$path,version:$version,digest:$digest} + (if $adopted then {adopted:true} else {} end)' >"$temp/previous"
  _update_save "$LAB_UPDATE_HOME/previous-release" "$temp/previous" || return 1
  fi
  [ "$("$HOME/.local/bin/treelab" --version)" = "VERSION=$LAB_UPDATE_VERSION" ] || {
    LAB_UPDATE_FILE="$HOME/.local/bin/treelab"; _update_error 'The installed command does not match the expected version. Restoring the previous version.'; return 1;
  }
  # Publication provisoire du manifeste : le marqueur reste reprenable jusqu'au
  # point de succès, même si le processus est arrêté entre ces deux écritures.
  _txn_commit || return 1
  _txn_write "$LAB_UPDATE_HOME/update-pending" "$LAB_TXN_ID committed" || return 1
  LAB_UPDATE_COMMITTED=yes
  if ! { rm "$LAB_TXN_ACTIVE/rollback" && rm "$LAB_UPDATE_HOME/update-pending"; }; then
    LAB_UPDATE_FILE="$LAB_UPDATE_HOME/update-pending"; _update_error 'Version installed, finishing incomplete. Run treelab update --resume before going back to work.'; return 1
  fi
  LAB_TXN_ACTIVE=''
  # Un retour arrière choisi n'est pas défait par lab next : la version quittée n'est plus qu'annoncée (update_auto).
  if [ "${LAB_UPDATE_ROLLBACK:-no}" = yes ]; then printf '%s\n' "$LAB_UPDATE_OLD" >"$LAB_STATE/update-auto-skip" || true
  elif [ "${LAB_UPDATE_REAPPLY:-no}" != yes ]; then rm -f "$LAB_STATE/update-auto-skip" || true; fi
  if [ "${LAB_UPDATE_REAPPLY:-no}" = yes ]; then
    _setup_message "Integrations of version $LAB_UPDATE_VERSION reapplied. Check with treelab doctor."
    _update_result reapplied
  else
    _setup_message "Version $LAB_UPDATE_OLD → $LAB_UPDATE_VERSION installed. Check with treelab doctor; roll back with treelab update --rollback."
    _setup_message "$(_update_news "$LAB_UPDATE_VERSION")"
    # lot 04 de pilotage-voix : Ginkgo en marche n'est jamais arrêté (conversation en cours) ; l'app livrée change à son prochain lancement
    if pgrep -x Ginkgo >/dev/null 2>&1; then
      _setup_message 'Ginkgo keeps running the previous version until lab ginkgo <project> opens the new one.'
    fi
    if [ "${LAB_UPDATE_ADOPT:-no}" = yes ]; then
      _setup_message 'Open sessions kept: each one takes the new version when it restarts.'
      _update_result adopted
    elif [ "${LAB_UPDATE_RESTORE:-no}" = yes ]; then _update_result restored
    else _update_result updated; fi
    kv PREVIOUS_VERSION "$LAB_UPDATE_OLD"
    [ "${LAB_UPDATE_AUTO:-no}" != yes ] || { kv AUTO_NOTICE "treelab updated $LAB_UPDATE_OLD → $LAB_UPDATE_VERSION; roll back: treelab update --rollback"
      kv AUTO_LINK "$(_update_news "$LAB_UPDATE_VERSION")"; }
  fi
  kv VERSION "$LAB_UPDATE_VERSION"
}
# _update_adopt : lancé depuis releases/treelab-NEW, extraite par l'installeur (pont tl_bridge du couloir api) ; current → l'ancienne
# pose. Catalogue local seul (licence non lue) ; la release extraite doit avoir l'empreinte de l'archive du catalogue. Chaque
# refus porte une REASON du contrat ; seule une opération lab arrête l'adoption, jamais une session vivante.
_update_adopt() {
  LAB_UPDATE_ADOPT=yes LAB_UPDATE_REASON=operation
  trap 'rc=$?; _update_finish "$rc"; exit $?' EXIT
  trap 'exit 1' INT TERM
  operation_acquire || { _update_error 'Another lab operation is running. Wait for it to finish, then run treelab update --adopt again.'; return 1; }
  LAB_UPDATE_HELD=yes LAB_UPDATE_REASON=layout
  _update_guard || return 1
  if [ "$LAB_UPDATE_FROM" = "$LAB_ROOT" ]; then
    _update_result current; kv VERSION "$LAB_UPDATE_OLD"; _setup_message "Version $LAB_UPDATE_OLD already adopted."; return 0
  fi
  LAB_UPDATE_REASON=source
  case "${LAB_UPDATE_SOURCE:-}" in file:///?*) ;; *)
    _update_error 'Local catalogue required: LAB_UPDATE_SOURCE=file:///…/catalogue.json. Installation kept.'; return 1 ;;
  esac
  temp="$(mktemp -d /private/tmp/treelab-adopt.XXXXXXXX)" || return
  if ! { _update_fetch "$LAB_UPDATE_SOURCE" "$temp/latest.json" && _update_catalogue "$temp/latest.json"; }; then
    _update_error 'Local catalogue unreadable or invalid: stable version, URL and SHA-256 checksum required. Installation kept.'; return 1
  fi
  LAB_UPDATE_REASON=version
  [ "$LAB_UPDATE_VERSION" = "$(head -1 "$LAB_ROOT/VERSION")" ] || {
    _update_error "The catalogue announces $LAB_UPDATE_VERSION, the running release is $(head -1 "$LAB_ROOT/VERSION"). Installation kept."; return 1;
  }
  [ "$(_update_compare "$LAB_UPDATE_VERSION" "$LAB_UPDATE_OLD")" = 1 ] || {
    _update_error "Installed version $LAB_UPDATE_OLD is not older than $LAB_UPDATE_VERSION: nothing to adopt. Installation kept."; return 1;
  }
  LAB_UPDATE_REASON=archive
  if ! { _update_fetch "$LAB_UPDATE_URL" "$temp/release.tgz" && _update_archive "$temp/release.tgz" "$temp" "$LAB_UPDATE_VERSION" &&
    [ "$(_txn_fingerprint "$LAB_UPDATE_CANDIDATE")" = "$(_txn_fingerprint "$LAB_ROOT")" ]; }; then
    _update_error 'Extracted release differs from the catalogue archive. Installation kept; extract the archive again.'; return 1
  fi
  # Au-delà, toute panne est défaite par la transaction : refus « layout » (intégrations ou commande installée).
  LAB_UPDATE_REASON=layout
  _update_apply
}
# cmd_update : point de sortie unique du contrat d'échec. Un échec (hors usage, code 2) sans RESULT écrit finit par
# RESULT=refused (rien modifié) ou interrupted (update-pending laissé, même après un arrêt brutal : reprise par --resume),
# REASON= et FILE= (absent si aucun fichier en cause).
cmd_update() {
  local LAB_UPDATE_STATUS rc=0 reason file
  LAB_UPDATE_STATUS="$(mktemp /private/tmp/treelab-status.XXXXXXXX 2>/dev/null)" || LAB_UPDATE_STATUS=''
  _update_command "$@" || rc=$?
  [ -n "$LAB_UPDATE_STATUS" ] || return "$rc"
  if [ "$rc" != 0 ] && [ "$rc" != 2 ] && ! grep -q '^RESULT=' "$LAB_UPDATE_STATUS"; then
    reason="$(sed -n 's/^REASON=//p' "$LAB_UPDATE_STATUS" | head -1)"; file="$(sed -n 's/^FILE=//p' "$LAB_UPDATE_STATUS" | head -1)"
    if [ "${reason:-layout}" != operation ] && _txn_exists "$HOME/.lab/update-pending"; then kv RESULT interrupted
    else kv RESULT refused; fi
    kv REASON "${reason:-layout}"; [ -z "$file" ] || kv FILE "$file"
  fi
  rm -f "$LAB_UPDATE_STATUS"
  return "$rc"
}
_update_command() (
  local option mode=update temp order private=no
  LAB_UPDATE_COMMITTED=no LAB_UPDATE_STARTED=no LAB_UPDATE_REAPPLY=no LAB_UPDATE_ROLLBACK=no
  LAB_UPDATE_ADOPT=no LAB_UPDATE_HELD=no LAB_UPDATE_RESTORE=no
  # Sessions vivantes permises : seule une opération lab (operation_acquire) arrête update, --rollback et --resume (lot 21).
  LAB_PREFLIGHT_SESSIONS=no
  _update_public_diagnostics
  for option in "$@"; do
    case "$option:$mode" in --rollback:update) mode=rollback ;; --resume:update) mode=resume ;; --catalogue:update) mode=catalogue ;;
      --auto:update) mode=auto ;; --adopt:update) mode=adopt ;; *) _update_usage; return 2 ;; esac
  done
  _update_register
  LAB_UPDATE_RESUME=no LAB_UPDATE_AUTO=no
  # --auto : appelé par lab next (update_auto), budget réseau court ; une majeure ou auto_update=no n'amène qu'une annonce.
  [ "$mode" != auto ] || LAB_UPDATE_AUTO=yes
  [ "$mode" != resume ] || LAB_UPDATE_RESUME=yes
  # --catalogue lit et valide seulement le catalogue (publier.sh) : rien n'est posé, une copie de développement suffit.
  _update_cause layout
  [ "$mode" = catalogue ] || [ "$mode" = adopt ] || _update_guard || return 1
  if [ "$mode" = adopt ]; then _update_adopt; return; fi
  if [ "$mode" = resume ]; then _update_resume; return; fi
  if [ "$mode" = rollback ]; then
    LAB_UPDATE_ROLLBACK=yes
    _update_previous || return 1
    temp="$(mktemp -d /private/tmp/treelab-rollback.XXXXXXXX)" || return
    trap 'rm -R "$temp"' EXIT
    _update_apply; return
  fi
  if [ -z "${LAB_UPDATE_SOURCE:-}" ]; then
    set +x
    # shellcheck source=lib/update_private.sh
    . "$LAB_ROOT/lib/update_private.sh"
    umask 077
    temp="$(mktemp -d /private/tmp/treelab-private.XXXXXXXX)" || return
    trap 'rm -R "$temp"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    private=yes
    # Une seconde de marge pour la précision entière de SECONDS : budget <120 s (mode auto : LAB_UPDATE_AUTO_BUDGET, 30 s).
    local LAB_PRIVATE_DEADLINE=$((SECONDS+119))
    [ "$mode" != auto ] || LAB_PRIVATE_DEADLINE=$((SECONDS+${LAB_UPDATE_AUTO_BUDGET:-30}))
    local license_status=0
    _update_cause licence "$LAB_HOME/license"
    _update_license_read "$LAB_HOME/license" "$temp/license" || license_status=$?
    case "$license_status" in
      # la clé ne s'active que par l'installeur en ligne (décision 3 du lot 21) : le remède est nommé, jamais un blocage de lab next
      2) if [ "$mode" = auto ]; then kv AUTO_NOTICE "$LAB_UPDATE_LICENSE_REMEDY"; return 0; fi
        _update_error "$LAB_UPDATE_LICENSE_REMEDY. Installation kept."; return 1 ;;
      0) ;;
      *) _update_error 'License file unusable. Installation kept; restore a valid regular file with mode 0600.'; return 1 ;;
    esac
    _update_cause source
    _update_private_catalogue || return 1
  else
    _update_cause source "$(_update_local "$LAB_UPDATE_SOURCE")"
    _update_url "$LAB_UPDATE_SOURCE" || { _update_error 'Invalid catalogue source. Choose an explicit HTTPS or file:// URL.'; return 1; }
    temp="$(mktemp -d /private/tmp/treelab-update.XXXXXXXX)" || return
    trap 'rm -R "$temp"' EXIT
    _update_fetch "$LAB_UPDATE_SOURCE" "$temp/latest.json" "${LAB_UPDATE_AUTO_BUDGET:-30}" || { LAB_UPDATE_REASON=network; _update_error 'Catalogue unavailable or timed out. Installation kept; check the connection, then run treelab update again.'; return 1; }
    _update_catalogue "$temp/latest.json" || { _update_error 'Invalid catalogue: stable version, URL and SHA-256 checksum required. Installation kept; get a trusted catalogue.'; return 1; }
  fi
  if [ "$mode" = catalogue ]; then kv LATEST "$LAB_UPDATE_VERSION"; kv SHA256 "$LAB_UPDATE_SHA"; return 0; fi
  order="$(_update_compare "$LAB_UPDATE_VERSION" "$LAB_UPDATE_OLD")"
  # droits lus par la distribution privée (lot 05) : écrits par un update réussi seulement — déjà à jour, annoncé ou posé
  local entitled=:; [ "$private" != yes ] || entitled=_update_private_entitlement_commit
  # mode auto : un poste plus récent que le catalogue (release locale non publiée) n'est pas un échec
  if [ "$mode:$order" = auto:-1 ]; then "$entitled"; _update_result current; kv VERSION "$LAB_UPDATE_OLD"; return 0; fi
  case "$order" in
    0) "$entitled"; _update_result current; kv VERSION "$LAB_UPDATE_OLD"; _setup_message "Version $LAB_UPDATE_OLD: already up to date."; return 0 ;;
    -1) _update_cause version; _update_error 'The catalogue version is older. Use treelab update --rollback to go back to the previous version.'; return 1 ;;
  esac
  local skip=''
  if [ "$mode" = auto ] && [ -f "$LAB_STATE/update-auto-skip" ]; then skip="$(head -1 "$LAB_STATE/update-auto-skip")"; fi
  _update_version "$skip" && [ "$(_update_compare "$LAB_UPDATE_VERSION" "$skip")" != 1 ] || skip=''
  if [ "$mode" = auto ] && { [ -n "$skip" ] || [ "${LAB_UPDATE_VERSION%%.*}" != "${LAB_UPDATE_OLD%%.*}" ] ||
    [ "$(global_config_get auto_update)" = no ]; }; then
    "$entitled"; _update_result announced; kv VERSION "$LAB_UPDATE_OLD"; kv AUTO_NOTICE "Version $LAB_UPDATE_VERSION available: treelab update"
    kv AUTO_LINK "$(_update_news "$LAB_UPDATE_VERSION")"; return 0
  fi
  if [ "$private" = yes ]; then
    _update_cause network
    _update_private_download || return 1
  else
    _update_cause network "$(_update_local "$LAB_UPDATE_URL")"
    _update_fetch "$LAB_UPDATE_URL" "$temp/release.tgz" || { _update_error 'Archive unavailable or timed out. Installation kept; check the connection, then run treelab update again.'; return 1; }
  fi
  LAB_UPDATE_REASON=archive
  _update_archive "$temp/release.tgz" "$temp" "$LAB_UPDATE_VERSION" || { _update_error 'Archive refused. Installation kept; get a complete and safe distribution before treelab update.'; return 1; }
  _update_cause layout
  _update_apply || return
  "$entitled"
)

# update_auto : appelé par lab next, au plus une tentative par 24 heures (horloge revenue en arrière : aucune tentative).
# L'horodatage est écrit avant le réseau : une panne attend le lendemain. Pose par un processus enfant, treelab update --auto ;
# rien ne bloque lab next : rc toujours 0, une ligne au plus sur stderr, stdout = chemin de la release posée ou rien.
# L'annonce de la session suivante va dans $LAB_STATE/update-auto-notice, lue une seule fois par SessionStart.
_update_auto_write() {
  local file="$1" value="$2" pending rc=0
  _txn_plain_path "$file" || return 1
  pending="$(mktemp "$LAB_STATE/.treelab-auto.XXXXXXXX")" || return 1
  printf '%s\n' "$value" >"$pending" && mv -f "$pending" "$file" || rc=$?
  rm -f "$pending"
  return "$rc"
}
_update_auto_run() (
  [ "${LAB_DRY:-0}" != 1 ] && [ -f "$LAB_ROOT/.release" ] || return 0
  local now cache last err out rc=0 notice reason link
  _txn_paths && [ -d "$LAB_STATE" ] && [ -w "$LAB_STATE" ] || return 0
  cache="$LAB_STATE/update-auto.json"
  _txn_plain_path "$cache" || return 0
  now="$(date +%s)"
  [[ "$now" =~ ^[1-9][0-9]{0,11}$ ]] || return 0
  operation_acquire notice || return 0
  trap 'operation_release' EXIT
  if _txn_exists "$cache"; then
    [ -f "$cache" ] && [ -w "$cache" ] &&
      jq -es 'length==1 and (.[0]|type=="object" and .format=="treelab-update-auto-v1" and
        (.attempt|type=="number" and floor==. and .>0 and .<1000000000000))' "$cache" >/dev/null 2>&1 || return 0
    last="$(jq -r .attempt "$cache")"
    [ "$now" -ge "$last" ] && [ "$((now-last))" -ge 86400 ] || return 0
  fi
  _update_auto_write "$cache" "$(jq -cn --argjson now "$now" '{format:"treelab-update-auto-v1",attempt:$now}')" || return 0
  err="$(mktemp "$LAB_STATE/.treelab-auto-err.XXXXXXXX")" || return 0
  trap 'rm -f "$err"; operation_release' EXIT
  out="$(COLUMNS='' "$LAB_ROOT/bin/lab" update --auto </dev/null 2>"$err")" || rc=$?
  if [ "$rc" = 0 ]; then
    notice="$(printf '%s\n' "$out" | sed -n 's/^AUTO_NOTICE=//p' | head -1)"
    [ -n "$notice" ] || return 0
    link="$(printf '%s\n' "$out" | sed -n 's/^AUTO_LINK=//p' | head -1)"
    printf 'MSG=%s\n' "$notice"; [ -z "$link" ] || printf 'LINK=%s\n' "$link"
    _update_auto_write "$LAB_STATE/update-auto-notice" "$notice${link:+$'\n'$link}" || true
    if printf '%s\n' "$out" | grep -qx 'RESULT=updated'; then printf 'UPDATED_ROOT=%s\n' "$(cd "$HOME/.lab/current" && pwd -P)"; fi
  else
    reason="$(sed -n 's/^lab: //p' "$err" | sed -E 's/^(Bloqué :|Blocked:) //' | head -1)"
    if [ -e "$HOME/.lab/update-pending" ]; then
      printf 'MSG=automatic update interrupted%s; run treelab update --resume outside the sessions\n' "${reason:+ (${reason%.})}"
    elif printf '%s\n' "$out" | grep -qx 'REASON=entitlement'; then
      # droits échus (lot 05 de refonte-onboarding) : la phrase du refus (date, version gardée, lien), une ligne par jour au plus à
      # partager avec le rappel de lab next (même tampon entitlement-notice)
      [ -n "$reason" ] && declare -F entitlement_once >/dev/null && entitlement_once entitlement-notice || return 0
      printf 'MSG=%s\n' "$reason"
    else
      printf 'MSG=automatic update not done%s; version %s kept, next try tomorrow\n' \
        "${reason:+ (${reason%.})}" "$(cat "$LAB_ROOT/VERSION")"
    fi
  fi
)
update_auto() {
  local out line
  out="$(_update_auto_run 2>/dev/null)" || true
  line="$(printf '%s\n' "$out" | sed -n 's/^MSG=//p' | head -1)"
  [ -z "$line" ] || _update_say "$line"
  line="$(printf '%s\n' "$out" | sed -n 's/^LINK=//p' | head -1)"
  [ -z "$line" ] || _update_say "$line"
  printf '%s\n' "$out" | sed -n 's/^UPDATED_ROOT=//p' | head -1
}
# update_auto_notice : l'annonce laissée par update_auto (et sa ligne de nouveautés), rendue une seule fois puis retirée ; rien sur toute erreur.
update_auto_notice() {
  local file="$LAB_STATE/update-auto-notice" line
  _txn_plain_path "$file" 2>/dev/null && [ -f "$file" ] || return 0
  line="$(head -2 "$file" | tr -d '\r' | cut -c1-200 | paste -sd' ' -)"
  rm -f "$file" || return 0
  printf '%s\n' "$line"
}
