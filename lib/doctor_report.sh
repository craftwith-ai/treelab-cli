# shellcheck shell=bash
# shellcheck disable=SC2034 # DOC_DONE est lu par le trap de dispatch dans bin/lab.
# Frontière de sortie : aucune note libre ne traverse le mode rapport.
doctor_greater() {
  local left="$1" right="$2"
  [[ "$left" =~ ^[0-9]+$ ]] && [[ "$right" =~ ^[0-9]+$ ]] || return 1
  while [ "${#left}" -gt 1 ] && [ "${left:0:1}" = 0 ]; do left="${left#0}"; done
  while [ "${#right}" -gt 1 ] && [ "${right:0:1}" = 0 ]; do right="${right#0}"; done
  [ "${#left}" -gt "${#right}" ] || { [ "${#left}" -eq "${#right}" ] && [[ "$left" > "$right" ]]; }
}
doctor_text() { printf '%s' "$1" | LC_ALL=C tr '\000-\037\177' '?'; }
# doctor_say <texte> : lignes humaines du doctor (lot 05 du couloir anglais), repliées au mot à la largeur mesurée (40 à 80 colonnes,
# onboard_cols) ; un mot plus long que la largeur (un chemin) est coupé, jamais une ligne au-delà. Les blocs KEY=value ne passent pas ici.
doctor_say() {
  local w line
  # mode rapport : stderr est fermé, la sortie humaine part sur le descripteur 3 — sa largeur se lit là
  if [ "$DOC_REPORT" = 1 ]; then w="$(onboard_cols 2>&3)"; else w="$(onboard_cols)"; fi
  # hors terminal et sans COLUMNS (un agent par un tube) : intacte, comme lab_say (revue du lot 05)
  if [ -z "${COLUMNS:-}" ] && { { [ "$DOC_REPORT" = 1 ] && [ ! -t 3 ]; } || { [ "$DOC_REPORT" != 1 ] && [ ! -t 2 ]; }; }; then
    printf '%s\n' "$1"; return
  fi
  printf '%s\n' "$1" | onboard_wrap "$w" | while IFS= read -r line || [ -n "$line" ]; do
    while [ "${#line}" -gt "$w" ]; do printf '%s\n' "${line:0:$w}"; line="${line:$w}"; done
    printf '%s\n' "$line"
  done
}
doctor_report_fields() {
  local original="$1" suffix
  DOC_SAFE_NAME=unknown; DOC_SAFE_VALUE=-; DOC_SAFE_NOTE='Cause not detailed; see the local report.'
  DOC_SAFE_CAUSE=UNSPECIFIED
  if [ -n "$DOC_PROJECT" ] && [[ "$original" == "$DOC_PROJECT."* ]]; then
    suffix="${original#"$DOC_PROJECT."}"
    case "$suffix" in
      baseline|agents_md.lines|claude_md.lines_outside_import|claude_md.imports_agents|claude_md.lines|context.bytes|rules.without_paths|skills.count|memory.lines|sessionstart.chars|notes.lines|tracked.mechanical|worktrees.prunables|worktrees.outside_layout|locks.dead|lanes.leftovers|lanes.permanent|lanes.unlocked|tower|isolation|hooks.broken|batch_files.size|ci.workflows|conflicts.repeated|targets.probe|targets.workflow|targets.old_lane|targets.probe_registry)
        DOC_SAFE_NAME="project-$DOC_PROJECT_INDEX.$suffix" ;;
    esac
  else
    case "$original" in
      install.version|install.manifest.ok|install.path|install.lab-cli.conflict|install.license|install.entitlement|install.skills.collisions|global.baseline|global.install.context|global.instructions.lines|global.instructions.bytes|global.skills.count|global.skills.desc_bytes|global.skills.codex.duplicates|global.skills.headers|global.skills.reserved.codex|global.codex.agents.count|global.settings.mcp.count|global.settings|global.hooks.claude|global.hooks.claude.write|global.hooks.codex|global.hooks.codex.write|global.hooks.codex.trust|global.hooks.codex.enabled|global.codex.trust.home|global.codex.mcp.count|global.mcp.rss|global.mcp.unpinned|global.ginkgo|link.claude-md|link.claude-skills|link.claude-agents|link.agents-md|link.agents-skills|link.codex-agents)
        DOC_SAFE_NAME="$original" ;;
    esac
  fi
  [ "$DOC_SAFE_NAME" != unknown ] || return 0
  if [[ "$3" =~ ^[0-9]+$ ]]; then DOC_SAFE_VALUE="$3"; fi
  if [ "$original" = install.version ]; then
    suffix="${3%%[-+]*}"
    if [[ "$suffix" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then DOC_SAFE_VALUE="$suffix"; fi
  fi
  case "$2" in OK) DOC_SAFE_CAUSE=OK; DOC_SAFE_NOTE='Check passed.' ;;
    WARN) DOC_SAFE_CAUSE=CHECK_WARNING ;;
    RED) DOC_SAFE_CAUSE=CHECK_FAILED ;;
  esac
  case "$7" in
    VERSION_UNKNOWN) DOC_SAFE_CAUSE="$7"; DOC_SAFE_NOTE='Historical development copy: unknown version; check where it comes from before an update.' ;;
    VERSION_INVALID) DOC_SAFE_CAUSE="$7"; DOC_SAFE_NOTE='Restore the VERSION file from the complete copy of the program.' ;;
    VERSION_DIFFERENT) DOC_SAFE_CAUSE="$7"; DOC_SAFE_NOTE='Running and checked versions differ; use the installed command.' ;;
    MANIFEST_INVALID|MANIFEST_MISSING) DOC_SAFE_CAUSE="$7"; DOC_SAFE_NOTE='Keep the manifest and the backups; restore their complete copy before any installation.' ;;
    TRANSACTION_PENDING|REMOVAL_PENDING) DOC_SAFE_CAUSE="$7"; DOC_SAFE_NOTE='Resumption pending; keep the backups and finish the removal from the local report.' ;;
    HISTORICAL) DOC_SAFE_CAUSE="$7"; DOC_SAFE_NOTE='Historical development without a manifest; integrations checked.' ;;
    ROOT_INVALID|PATH_INVALID) DOC_SAFE_CAUSE="$7"; DOC_SAFE_NOTE='Point current back to the checked copy and put the treelab command in PATH.' ;;
    SHORT_NAME) DOC_SAFE_CAUSE="$7"; DOC_SAFE_NOTE='Short name unavailable; use treelab.' ;;
    LICENSE_DEV) DOC_SAFE_CAUSE="$7"; DOC_SAFE_NOTE='No license needed in development.' ;;
    LICENSE_MISSING) DOC_SAFE_CAUSE="$7"; DOC_SAFE_NOTE='Local license missing; install the provided file with mode 0600. Activation not checked.' ;;
    LICENSE_PRESENT) DOC_SAFE_CAUSE="$7"; DOC_SAFE_NOTE='Present locally, activation not checked.' ;;
    LICENSE_CHECK) DOC_SAFE_CAUSE="$7"; DOC_SAFE_NOTE='Use a regular, readable, non-empty license file, not a link, with mode 0600.' ;;
    COLLISIONS) DOC_SAFE_CAUSE="$7"; DOC_SAFE_NOTE='Your own items with the same names were kept; choose the names to keep in the local report.' ;;
    ENTITLEMENT_ENDING) DOC_SAFE_CAUSE="$7"; DOC_SAFE_NOTE='Update rights end within 2 days; the local report gives the date. Run lab subscribe to keep them.' ;;
    ENTITLEMENT_ENDED) DOC_SAFE_CAUSE="$7"; DOC_SAFE_NOTE='Update rights ended; the installed version keeps working. Run lab subscribe to get new versions.' ;;
    ENTITLEMENT_ACTIVE|ENTITLEMENT_NONE|ENTITLEMENT_UNKNOWN) DOC_SAFE_CAUSE="$7"; DOC_SAFE_NOTE='Update rights read from the local cache only.' ;;
    '')
      if [ "$2" != OK ]; then
        case "$original" in
          global.skills.count) DOC_SAFE_CAUSE=SKILLS_LIMIT; DOC_SAFE_NOTE='Chosen limit exceeded; adjust this limit if this selection is intended.' ;;
          global.hooks.codex.trust) DOC_SAFE_CAUSE=HOOK_APPROVAL; DOC_SAFE_NOTE='Open Codex and approve the Treelab hooks after reading them.' ;;
          link.*|global.hooks.claude*|global.hooks.codex*) DOC_SAFE_CAUSE=INTEGRATION; DOC_SAFE_NOTE='Check the integrations named in the local report before a new installation.' ;;
        esac
        # notes sûres : le bilan local nomme commandes et fiches, le rapport jamais (lot 06 de lab-enhancement)
        case "$DOC_SAFE_NAME" in
          project-*.hooks.broken) DOC_SAFE_NOTE='Hook command not found; the local report names each file, event and command.' ;;
          project-*.ci.workflows) DOC_SAFE_NOTE='CI workflow without a guard; the local report names each file and the missing guard.' ;;
          project-*.batch_files.size) DOC_SAFE_NOTE='Batch file too heavy; the local report names the files; move their story to the evidence report.' ;;
          project-*.lanes.leftovers) DOC_SAFE_NOTE='Processes left by lanes; the local report names each one, lab top stops them.' ;;
          project-*.lanes.unlocked) DOC_SAFE_NOTE='Live sessions in a lane without lock; the local report names each one.' ;;
        esac
      fi ;;
    *) DOC_SAFE_CAUSE=UNSPECIFIED ;;
  esac
}
doctor_emit() {
  local name="$1" status="$2" value="$3" limit="$4" note="$5" base="${6:-}" cause="${7:-}"
  if [ "$DOC_REPORT" = 1 ]; then
    doctor_report_fields "$name" "$status" "$value" "$limit" "$note" "$base" "$cause"
    name="$DOC_SAFE_NAME"; value="$DOC_SAFE_VALUE"; note="$DOC_SAFE_NOTE"; cause="$DOC_SAFE_CAUSE"
    [[ "$limit" =~ ^[0-9]+$ ]] || limit=-
    [[ "$base" =~ ^[0-9]+$ ]] || base=''
  else
    case "${DOC_MANIFEST_CAUSE:-}:$note" in
      TRANSACTION_PENDING:*treelab\ setup*|REMOVAL_PENDING:*treelab\ setup*) note='Finish treelab uninstall --resume before a new installation; keep the backups.' ;;
    esac
    name="$(doctor_text "$name")"; value="$(doctor_text "$value")"; note="$(doctor_text "$note")"
  fi
  kv CHECK "$name"; kv STATUS "$status"; kv VALUE "$value"; kv LIMIT "$limit"
  [ -z "$base" ] || kv BASELINE "$base"
  [ -z "$cause" ] || kv CAUSE "$cause"
  kv NOTE "$note"; sep
  if [ "$DOC_REPORT" = 1 ]; then doctor_say "$status $name: $value — $note" >&3
  else doctor_say "$status $name: $value"$'\n'"$note" >&2; fi
}
doctor_error() {
  local cause="$1" message
  case "$cause" in
    OPTIONS) message='Invalid options; see treelab help for the doctor command.' ;;
    ROOT) message='Invalid root; choose a checkout of the registered project with --root.' ;;
    PROJECT) message='Project not found; check that it is registered with treelab list.' ;;
    SKILLS_LIMIT) message='Invalid skills limit; choose a whole number of zero or more, or leave the limit empty.' ;;
    FREEZE_REPORT) message='Report and freeze cannot be combined; remove --freeze to share a report without writing anything.' ;;
    *) cause=INTERNAL; message='Diagnosis interrupted; see the local report and check that the files are readable.' ;;
  esac
  kv ERROR "$cause"; kv NOTE "$message"; sep
  if [ "$DOC_REPORT" = 1 ]; then doctor_say "ERROR: $message" >&3
  else doctor_say "ERROR: $message" >&2; fi
  DOC_DONE=yes
  return 2
}
