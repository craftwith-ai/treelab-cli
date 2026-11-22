# shellcheck shell=bash
# onboard.sh — les textes fixes lus par un client (lot 11) : lab help (page courte, puis une page par commande, sur stdout) et les
# trois écrans de lab onboard (stderr). Rien n'est tronqué : chaque ligne est repliée au mot à la largeur mesurée, 40 à 80 colonnes.

# onboard_cols → largeur d'affichage : COLUMNS s'il est posé, sinon le terminal de stderr (stty lit son descripteur d'entrée ; stdout
# est ici le tuyau de la substitution, et tput exige un TERM connu), sinon 80 ; toujours entre 40 et 80
onboard_cols() {
  local c="${COLUMNS:-}"
  case "$c" in ''|*[!0-9]*) c=""; if [ -t 2 ]; then c="$(stty size <&2 2>/dev/null | awk '{print $2}' || true)"; fi ;; esac
  case "$c" in ''|*[!0-9]*) c=80 ;; esac
  if [ "${#c}" -gt 3 ] || [ "$c" -gt 80 ]; then c=80; fi
  [ "$c" -ge 40 ] || c=40
  printf '%s\n' "$c"
}
# onboard_wrap <largeur> : replie chaque ligne de stdin au mot. Une ligne de suite reprend le retrait de sa ligne, quatre espaces de
# plus pour une commande (« lab … ») ; une ligne vide reste vide. Une ponctuation française détachée reste avec son mot : jamais
# « : », « ; », « ? », « ! » ou « » » en début de ligne, jamais « « » en fin. Pur bash : ${#mot} compte des caractères en locale
# UTF-8 et des octets sinon — un repli un peu tôt, jamais un dépassement.
onboard_wrap() {
  local width="$1" line indent cont out w i n; local -a raw words
  while IFS= read -r line || [ -n "$line" ]; do
    indent="${line%%[! ]*}"
    IFS=' ' read -ra raw <<<"$line"
    words=(); n=0; i=0
    while [ "$i" -lt "${#raw[@]}" ]; do
      w="${raw[$i]}"; i=$((i + 1))
      case "$w" in
        ':'|';'|'?'|'!'|'»'|'»'[.,]) if [ "$n" -gt 0 ]; then words[n - 1]="${words[n - 1]} $w"; continue; fi ;;
        '«') if [ "$i" -lt "${#raw[@]}" ]; then w="$w ${raw[$i]}"; i=$((i + 1)); fi ;;
      esac
      words[n]="$w"; n=$((n + 1))
    done
    [ "${#words[@]}" -gt 0 ] || { printf '\n'; continue; }
    # une commande repliée garde sa suite en retrait : elle ne se lit jamais comme une seconde commande (revue du lot 07)
    cont="$indent"; case "${words[0]}" in lab|gh|brew|git) cont="$indent    " ;; esac
    out="$indent${words[0]}"; i=1
    while [ "$i" -lt "${#words[@]}" ]; do
      w="${words[$i]}"; i=$((i + 1))
      if [ $((${#out} + 1 + ${#w})) -le "$width" ]; then out="$out $w"; else printf '%s\n' "$out"; out="$cont$w"; fi
    done
    printf '%s\n' "$out"
  done
}

# onboard_say, onboard_die <message> : log et die, repliés à la largeur du terminal — un accueil lisible à 40 colonnes
onboard_say() { printf 'lab: %s\n' "$*" | onboard_wrap "$(onboard_cols)" >&2; }
onboard_die() { (die "$*") 2>&1 | onboard_wrap "$(onboard_cols)" >&2; exit 1; }

# ---------- lab onboard : les trois écrans ----------
ONBOARD_SCREENS=3
onboard_screen() { # <1|2|3>
  case "$1" in
    1) cat <<'SCREEN'
Welcome to Treelab — 1/3 · The words

With Treelab, an agent (an AI assistant that writes code) builds what you need, one need at a time, and never touches the version you rely on. A few words are enough.

Project: your folder of code, registered once in Treelab. It is a repository: the folder plus the history of every change, kept by git (the tool that records each version).

Branch: a separate copy of the work. Your main branch, the version you rely on, stays as it is: nobody works on it directly.

Lane: one need to deliver, for instance "a contact page". It gets its own copy of the project, its own agent and its own tab in cmux (the terminal where the agents work). Several lanes move forward at the same time without getting in each other's way.

Batch: one step of a lane, on its own branch. Its result is checked by tests: small programs that make sure it works. It ends with a pull request: a page that shows every change, to read before you accept it. That page is on GitHub, the website that keeps your project online.
SCREEN
      ;;
    2) cat <<'SCREEN'
Treelab — 2/3 · The cycle

Three commands move a need forward, from start to finish. Your agent runs them for you; you can type them too.

  lab new <lane>: opens a lane. The agent asks you a few questions, five at most for your first lane, then writes the plan.

  lab next <project> <lane>: moves to the next step. The command reads where the lane stands and starts what is needed: the work, then your final trial.

  lab close <project> <lane>: after your trial and your agreement, delivers the work into your main branch, then removes the lane.

At any moment, lab guide <project> <lane> shows where your lane stands, in four steps.
SCREEN
      ;;
    3) cat <<'SCREEN'
Treelab — 3/3 · The guarantees

Nothing is written on the main branch: every change goes through a branch and a pull request that you accept.

Nothing is deleted without your agreement: only lab close removes a lane, after your trial and a confirmation.

Nothing becomes public: if your project is not on GitHub yet, the agent offers to create a private repository, visible to you only, and waits for your yes.

In doubt? lab doctor checks the installation and says what to fix. lab help lists the commands.

Next: this repository is registered in Treelab, without touching your files. Its tower opens in a "tower" tab: it watches your lanes and tells you what waits for you. Then an agent opens in the project's "main" tab and asks for your first need.
SCREEN
      ;;
  esac
}
# onboard_screens <terminal 0|1> : avec un terminal, Entrée fait avancer et le dernier écran attend avant toute écriture ; sans
# terminal, les trois écrans sortent d'un bloc, sans attente. Rend 1 si l'entrée se ferme avant la fin ou si un écran ne peut pas
# être écrit (rien n'est alors enregistré).
onboard_screens() {
  local tty="$1" width n; width="$(onboard_cols)"
  n=1
  while [ "$n" -le "$ONBOARD_SCREENS" ]; do
    # un écran qui ne peut pas être écrit (stderr fermé) arrête tout : rien n'est enregistré sans avoir été annoncé
    onboard_screen "$n" | onboard_wrap "$width" >&2 || return 1
    printf '\n' >&2 || return 1
    if [ "$tty" = 1 ]; then
      if [ "$n" -lt "$ONBOARD_SCREENS" ]; then printf 'Press Enter to continue.\n' >&2
      else printf '%s\n' "Press Enter to register this repository and open the agent, or Ctrl-C to stop, without writing anything." | onboard_wrap "$width" >&2; fi
      IFS= read -r _ || return 1
      printf '\n' >&2
    fi
    n=$((n + 1))
  done
}
# onboard_tower : lab onboard d'un projet neuf lui crée sa tour (lot 04 d'autonomie-tours), par lab tower dans un processus à part
# (tower_spawn), sans installation ; seuls TOWER= et TOWER_WHY= sortent. Sans cmux, sans Claude (la tour tourne sous Claude seul,
# même dans un projet Codex) ou copie principale modifiée : l'accueil continue, TOWER=skipped, la cause et le remède. L'onglet de la
# tour s'ouvre en fond : l'appelant rend ensuite le focus à main.
onboard_tower() {   # [cause imposée par l'appelant]
  local why="${1:-}" fix="lab tower $P_NAME"
  if [ -n "$why" ]; then :
  elif ! has_cmux; then why="cmux not found"
  elif ! command -v claude >/dev/null 2>&1; then why="Claude Code not found, and the tower runs under Claude only"; fix="install Claude Code, then lab tower $P_NAME"
  elif ! is_clean "$P_ROOT"; then why="the main checkout has uncommitted changes"; fix="commit them or set them aside, then lab tower $P_NAME"
  fi
  if [ -z "$why" ]; then
    tower_spawn "$P_NAME" --no-install
    if [ "$TOWER_DONE" = present ]; then kv TOWER present; onboard_say "tower already present: the lane tower of $P_NAME (lab tower $P_NAME)."; return 0; fi
    if [ "$TOWER_DONE" = created ]; then
      kv TOWER created
      if [ -z "$TOWER_CAUSE" ]; then onboard_say "tower created: the lane tower, in its own tab, watches your lanes and tells you what waits for you (lab help tower)."
      else kv TOWER_WHY "$TOWER_CAUSE"; onboard_say "tower created, but its session did not open ($TOWER_CAUSE). To open it: lab next $P_NAME tower."; fi
      return 0
    fi
    why="$TOWER_CAUSE"
  fi
  kv TOWER skipped; kv TOWER_WHY "$why"
  onboard_say "tower not created: $why. To create it: $fix."
}
# onboard_prompt <agent> <projet> → le prompt d'ouverture : lab agit ici pour l'utilisateur, qui seul peut invoquer le skill réservé
# onboarding — Claude l'invoque par /nom, Codex par $nom
onboard_prompt() {
  local call
  # shellcheck disable=SC2016 # « $onboarding » est le texte que Codex lit, pas une variable
  case "$1" in claude) call='/onboarding' ;; codex) call='$onboarding' ;; *) die "unknown agent: $1" ;; esac
  printf "%s Project %s: guide me to my first lane." "$call" "$2"
}

# ---------- lab help ----------
help_page() {
  cat <<'PAGE'
lab — from need to delivery, one lane at a time

1. Install
  lab setup — install Treelab on this machine, after your agreement
  lab doctor — check the installation and say what to fix
  lab update — move to the latest version (going back: --rollback)
  lab subscribe — subscribe: your trial key becomes a paid key

2. Start
  lab onboard — guided tour in your repository, up to the first lane
  lab new <lane> — open a lane for a new need
  lab guide <project> <lane> — where your lane stands, in four steps

3. Move forward
  lab next <project> <lane> — move to the lane's next step
  lab permanent <project> <lane> — keep a lane open for good, never closed
  lab tower <project> — the tower: what each lane waits for, alerts
  lab ginkgo <project> — talk with the tower out loud (macOS)
  lab plan — see the lanes and their progress
  lab status — see the detailed state of each lane
  lab top — see who uses what on this machine, and what to cut
  lab widget install — the same in the menu bar, cut with one click
  lab mcp — see the tool servers (MCP), their copies and memory

4. Finish
  lab acceptance <project> <lane> --accept — record your agreement after the trial
  lab close <project> <lane> --dry-run — list what would prevent closing
  lab close <project> <lane> — deliver then remove the lane, after your trial and your agreement
  lab sweep — inventory the lanes; deletes nothing

Details of a command: lab help <command>
Words, with their former French names: lab help glossary

Other commands: init, open, launch, list, merge, sync, promote, batch, handoff, now, due, account, cloud, proof, lock, unlock, served, services, deploy, watch, wake, hook, uninstall.

Full technical reference: lab --help
PAGE
}
# help_topic <commande> → sa page ; rend 1 pour une commande inconnue. Une ligne de syntaxe ou d'exemple commence par « lab ».
help_topic() {
  case "$1" in
    help) cat <<'HELP'
lab help — the help

  lab help
  lab help <command>

Without a command: the useful commands, sorted by moment (install, start, move forward, finish). With a command: what it is for, its syntax and an example.

Example:
  lab help new
HELP
      ;;
    onboard) cat <<'HELP'
lab onboard — guided tour, from your repository to the first lane

  lab onboard [--agent claude|codex]

Run it in your git repository's folder. Three screens present the words, the cycle and the guarantees. Then the repository is registered as a project, without touching your files, the project's tower opens in its "tower" tab (lab help tower), and an agent opens in the project's "main" tab: it asks for your need and opens your first lane. Without cmux, without Claude or with uncommitted changes in the main checkout, the tower is skipped (TOWER=skipped) with its cause and the command that creates it later.

Running the command again creates nothing twice. Without cmux, it prints the command to run yourself (NEXT_COMMAND).

Example:
  lab onboard
HELP
      ;;
    init) cat <<'HELP'
lab init — register a repository as a project

  lab init [name] [--root <path>] [--docs repo|local] [--owner shared|other] [--agent claude|codex]

Detects the main branch, the staging branch if it exists, the merge method, the dependency install and the tests, then writes the project configuration in Treelab's registry, outside your repository: none of your files is modified. lab onboard does it for you the first time.

Working documents (plans, batch files) stay outside the repository by default; --docs repo versions them in the repository, through the lane.

If your production is the CI that deploys the branch targeted by pull requests (staging if it exists, otherwise the main one), write recette=production in the project configuration: lab init keeps it, and at the final trial lab next reminds you to merge first, then to try in production.

Example:
  lab init myproject
HELP
      ;;
    new) cat <<'HELP'
lab new — open a lane for a new need

  lab new [project] <lane> [--brief <file>] [--agent claude|codex] [--kind feat|fix|chore] [--batch <slug>] [--title <text>] [--base <branch>] [--no-open] [--no-install] [--permanent] [--guided]

Creates the lane's isolated working copy and its first branch, installs the dependencies, prepares the first batch file, then opens the lane's tab with an agent. The agent starts with a few questions to frame the need.

--brief stores the text of your need with the lane's documents: the agent starts from it. --permanent creates the lane already permanent (see lab help permanent). --guided makes it a first lane, short and guided: GitHub made ready first, five questions at most, one single batch up to its pull request, and the steps shown by lab guide; lab onboard and the installer use it. The main repository must have no pending change.

Example:
  lab new myproject payment --brief need.md
HELP
      ;;
    guide) cat <<'HELP'
lab guide — where your lane stands, in four steps

  lab guide [project] <lane>

Shows the lane's step in plain words: 1 questions about your need, 2 the plan, 3 the work, checked by tests, 4 your review of the pull request (a page on GitHub that shows every change before you accept it). Then it says whether GitHub is ready, and if not, what to do: install gh (GitHub's command-line tool), sign in, or create a private repository, only with your agreement.

It only reads: nothing is written, and a slow network never blocks it. GUIDE_STEP= and GITHUB= give the same information to an agent.

Example:
  lab guide myproject my-site
HELP
      ;;
    open) cat <<'HELP'
lab open — go back to a lane's tab

  lab open [project] <lane> [--agent claude|codex] [--prompt <text>|-]

Fallback command: it finds the lane's tab, or reopens it with its agent, without deciding a new step. To move forward, use lab next.

Example:
  lab open myproject payment
HELP
      ;;
    launch) cat <<'HELP'
lab launch — start the agent in the lane's tab

  lab launch [project] <lane> [--agent claude|codex] [--goal <addition>]

You do not have to type it: lab new and lab next write it in the lane's tab. It reads the batch file again, rebuilds the agent's instruction and hands over to it.

Example:
  lab launch myproject payment
HELP
      ;;
    next) cat <<'HELP'
lab next — move to a lane's next step

  lab next [project] <lane> [--agent claude|codex] [--goal <criteria>] [--local]
  lab next [project] <lane> --batch <slug> [--kind feat|fix|chore] [--title <text>]

Reads where the lane stands and starts what is needed: run or resume the batch, open the next batch after a delivery, or prepare your final trial. It neither merges nor deletes anything.

If the last nightly CI of the main branch is red, it says so (NIGHT=red) and suggests a fix lane (NIGHT_FIX=), without blocking anything.

Started from the lane's session, it replaces that session with a fresh one in the same tab. The second form imposes the next batch, for example a fix after your trial.

Each batch chooses by itself, without a question: its Execution line, written at planning (cloud, or mac — <need>: <detail> with secret, deploy, mac-tool, human, resource or live), a lab deploy or lab lock command in its Steps, or an unreadable line keeps it on the Mac; without a line, it goes to the Cloud. lab next announces the choice in one line (EXECUTION=, EXECUTION_WHY=).

With cmux, the Cloud rule at yes, gh signed in and a ready image (see lab help cloud), a batch's run goes to a Cloud machine sized by your plan (CLOUD_RUN=, CLOUD_SIZE=) and shows in the lane's workspace; lanes of a project share a machine that has room (one session per 4 vCPU, LAB_CLOUD_LANES_PER_VM), awake first, without taking a slot of the plan (CLOUD_SHARED=<machine> <lanes> <n/max>, also in lab status); at its end, the Mac takes it back alone for the closing. If your plan is full, the lane takes its place in a queue (CLOUD_RUN=file (position n/m)) and leaves alone as soon as a slot frees up, in order of arrival; after 30 minutes of waiting, it runs on the Mac. Otherwise, or with --local (which also removes it from the queue), it stays on the Mac and CLOUD_RUN= says why. Planning, fixing and the final trial always stay on the Mac.

A Cloud session blocked on a need of the Mac (it writes "blocked: need <need>: <detail>") comes back alone: the run reopens on the Mac, a notification says so, and the need is remembered for the project (see lab help cloud). Without a push for an hour, a notification tells you; nothing is stopped.

The VM agent is driven as locally: it asks its questions in its terminal, the lane's tab rings (cmux alert) and you answer in that terminal; the lane's sidebar says where it stands (working, answer awaited, paused), and a targeted alert announces its end or its stop. Without an answer for 2 hours, its VM pauses (unless another live lane shares it: an alert only); lab next wakes it and reopens its terminal, without restarting anything, and --local closes it to go on on the Mac.

Example:
  lab next myproject payment
HELP
      ;;
    permanent) cat <<'HELP'
lab permanent — keep a lane open for good

  lab permanent [project] <lane> [on|off]

A permanent lane chains its batches, each one delivered by its own pull request. It is never offered for a trial (acceptance), never removed, never closed: lab close and lab close --abandon refuse it. When no batch is left, lab next opens a free session that waits for your request.

Without a value, or with on, the lane becomes permanent; off makes it ordinary again. PERMANENT=yes or no gives the result; lab status and lab list show PERMANENT=yes.

Example:
  lab permanent myproject tower
HELP
      ;;
    tower) cat <<'HELP'
lab tower — the tower: what each lane waits for

  lab tower [project] [--no-install]
  lab tower --all
  lab tower [project] --lift-deny [--yes|--no]

Every project has a tower: lab onboard creates it for a new project. The first call creates the tower of the project: the permanent lane tower, started under Claude in bypassPermissions mode (the first start may ask you once to confirm that mode). Its session applies the tower skill: about every 30 minutes it checks every lane, relaunches a stopped one, delivers what is ready, and lists what waits for you. It never answers a question in your place. TOWER=created gives the result; a tower under Codex is refused.

Next calls print TOWER=present, then one block per lane: LANE=, WAITS_FOR= (you, merge, acceptance, close, date, ci or nothing), WHY= and SESSION= (live or none); WAITING_FOR_YOU= names the lanes that wait for you. merge: the lane's agent queued its batch, the tower merges it without asking you. close: acceptance passed, the tried revision is served and verified, and its prod check is green — the tower closes the lane alone.

In a project with a tower, only the tower merges, deploys and closes; a lane agent is queued (lab merge, lab deploy) or refused with a pointer to the tower (lab close, a raw merge or push to the main branches). If the shared .claude/settings.json forbids agents to push or merge, PROPOSE=lift-deny names those rules once: --lift-deny lists them, --yes removes only them in the tower (the lab guard replaces them), --no keeps them; the answer is written and never asked again.

In every project, with or without a tower, a question, a permission request, an acceptance ready or a refused lab next sends a cmux alert to the tab of its lane.

--all offers a tower to each registered project that has none: CANDIDATE= names it, SKIPPED= names a project that cannot get one yet, with its cause (uncommitted changes, a branch feat/tower already there). In a terminal, one question [y/N] per project, and only the yes get their tower (CREATED=, DECLINED=); without a terminal, nothing is created and CONFIRM=needed asks the agent to put these questions to you. --no-install skips the installation of the project's dependencies. lab wake restarts within the hour a tower without a session, and lab doctor shows the tower of each project (absent, no session or alive), as information only.

Example:
  lab tower myproject
  lab tower --all
HELP
      ;;
    ginkgo) cat <<'HELP'
lab ginkgo — talk with the tower of a project, out loud

  lab ginkgo [project]
  lab ginkgo status
  lab ginkgo key openai
  lab ginkgo state [project]
  lab ginkgo tell <project> <lane> <text>
  lab ginkgo question <project> <lane>
  lab ginkgo answer <project> <lane> --qid <id> (--q <n> [--choice <c>]... [--recommended] [--other <text>])...
  lab ginkgo answer <project> <lane> --text <text>
  lab ginkgo order <project> <text>
  lab ginkgo close <project> <lane> [--confirm <token>]
  lab ginkgo reply <project> [--since <utc-time>]
  lab ginkgo news <project> --open yes|no [--forget <key>]...
  lab ginkgo news <project> --baseline

Ginkgo is a small macOS app in the menu bar. lab ginkgo <project> opens it on that project: speak freely, without a key to hold; Ginkgo answers out loud, in your language, what the tower sees and what waits for you, and it passes a message on to a lane when you ask. Say stop, or use its menu bar icon, and the microphone closes: your voice only goes to OpenAI during an open conversation.

The voice engine is only ears and mouth: the work stays with the tower and the lanes. Ginkgo reads with lab ginkgo state, which never creates a tower (TOWER=absent without one), and speaks to a lane with lab ginkgo tell, which delivers the text to the agent of its tab through cmux, from Ginkgo; an unknown lane, a lane of another project, the tower itself or a lane without a tab are refused.

Ginkgo also settles what the lanes wait for. lab ginkgo question reads the exact question of a lane: its whole choice box (questions, choices, descriptions, several choices, the recommended one, and a QID), or the end of the last message of a session that waits, or WAITS=none. lab ginkgo answer types the answers of the whole box in the lane's tab, one question after the other, the extra words going into "Other"; a question changed since it was read (QID), an unknown choice or a question left out are refused before any key. lab ginkgo order types an order in the tower's tab ("Ginkgo, voice of the user: ..."), and lab ginkgo reply reads the tower's answer. Closing a lane is never a free order: lab ginkgo close reads it back first (READBACK=, TOKEN=) and sends it to the tower only with that token, said back within 120 seconds.

Ginkgo also speaks first when a lane starts waiting for you: a question, a permission, a blocked lane, an acceptance ready or a close to confirm; merges, CI and dates stay silent. Every 10 seconds the app reads lab ginkgo news. With the conversation open, it says out loud which lane asks and what, in a few words; closed, a Ginkgo notification with a sound opens the conversation when clicked, and the conversation starts with that news. Each wait is announced once, a new question again; what already waits when Ginkgo starts is not announced (lab ginkgo news --baseline), and a news Ginkgo could not say before the conversation closed is decided again (--forget). ginkgo_speak=always|conversation|never in ~/.lab/config: always by default (out loud when open, a notification when closed), conversation (out loud only), never. Quiet hours, ginkgo_quiet=21:00-08:00 by default, Mac time (off for none): nothing while the conversation is closed, then one notification sums up what still waits; a conversation you open yourself gets the news as usual.

Ginkgo.app comes with treelab, built and signed: nothing to install, on an Apple Silicon Mac with macOS 14 or later (elsewhere, lab ginkgo refuses and the rest of treelab works); a development checkout builds it from its sources. Your own OpenAI API key is used: the first lab ginkgo in a terminal asks for it, hidden, and stores it in the macOS keychain (lab ginkgo key openai does the same at any time); lab ginkgo status says whether it is there (KEY=present), never the key itself, and where the app comes from (SOURCE=release|checkout). macOS asks once for the microphone (again after each update); lab doctor says whether the shipped app is in place. ginkgo_model= in ~/.lab/config picks another OpenAI realtime model.

Example:
  lab ginkgo key openai
  lab ginkgo myproject
HELP
      ;;
    plan) cat <<'HELP'
lab plan — see the lanes and their progress

  lab plan [project]

Recomputed at each display, from the batch files: each lane's current batch, the batches done out of the total, and the phase. Read only.

Example:
  lab plan myproject
HELP
      ;;
    list) cat <<'HELP'
lab list — inventory the lanes

  lab list [project]

One block per lane: folder, branch, batch and state, agent, pull request, running session. Without a project: every registered project. Read only, except a finished watcher whose pull request was merged or closed outside it: its outcome is updated.

Example:
  lab list myproject
HELP
      ;;
    status) cat <<'HELP'
lab status — see a project's detailed state

  lab status [project]

The project (folder, branch, merge target, default agent), then each lane as in lab list, the pending deliveries and the files touched by two lanes at once. Read only, except a finished watcher whose pull request was merged or closed outside it: its outcome is updated.

Example:
  lab status myproject
HELP
      ;;
    top) cat <<'HELP'
lab top — see who uses what on this machine, and what to cut

  lab top [--fast]
  lab top --cut <pid|family|idle|lane-done>
  lab top --wake <tab>
  lab top --explain <pid|family>

Without an option, a read-only snapshot: memory pressure, compressed memory, swap, load and thermal state; then each claude or codex session, tied to its project and lane (by the lane's session lock, otherwise by its folder) and to its cmux tab, with its memory footprint, processor, age, time since its last exchange and status (idle, busy, or waiting for an answer: never put to sleep); the processes it started count with it. Everything else is grouped in families outside Treelab: Chrome, test browsers, virtual machines, node, cmux, cmux-cua, agent helpers, other.

Last comes the list of what to cut, each with its reason, what the cut implies and the command of its click: a session idle for 24 hours or more (hibernate; set top_idle_hours= in LAB_HOME/config), a session whose lane is finished or removed (close), an agent holding three zombie processes or more (sleep then wake it), a tool server or test browser left orphan for an hour, a heavy family, a Lima virtual machine or a forgotten tool (stop). cmux, cmux-cua, the calling session and its parents, the parents of any session (a tab's shell, tmux), root processes, other accounts and the names in top_keep= (comma list in LAB_HOME/config) are never proposed; a tab shared by two sessions is only explained. Sessions put to sleep by lab appear with their wake command.

One gesture at a time, without confirmation: lab takes a fresh snapshot, checks the reason again and refuses otherwise, naming the refusal. --cut <pid> or --cut <family> acts on one line: an idle session sleeps in its tab and keeps its conversation; the tab of a finished lane closes only with a filled Handoff, no uncommitted file, an idle session and the tab off screen; a session running a background command is left alone; a process outside agents gets a stop signal, then a forced stop after 10 seconds (a family by its root, a Lima VM by limactl stop, node never as a whole). An agent is never killed. --cut idle and --cut lane-done act on every line of that reason. --wake <tab> resumes a sleeping session in place. --explain opens a cmux tab where claude, in plan mode, reads what lab knows and explains before anything is cut.

--fast, for frequent refreshes, reads resident memory instead of the footprint (marked approximate) and does not reread the acceptance of lanes: a lane finished by lab close is still proposed, an accepted lane only by the full pass. KEY=value blocks on stdout (--json available), the readable view on stderr.

Example:
  lab top
  lab top --cut idle
HELP
      ;;
    sysmon) cat <<'HELP'
lab sysmon — measure the Mac for the menu-bar modules

  lab sysmon

One collection pass returns six KEY=value blocks: processor, memory, disks, network, battery and temperatures. macmon (installed by brew) gives the usage of the performance and efficiency cores, the GPU, power, temperatures and fans; the native tools (sysctl, vm_stat, df, iostat, netstat, pmset, ioreg, ps) give memory, disks, network throughput and the battery. For processor and memory, each block also lists the five largest consumers, tying agent sessions to their project and lane.

Without macmon, the temperatures and the power disappear and the other modules stay whole. A single collector feeds the six menu-bar modules (lab widget): each plugin only reads the shared cache, it never reruns macmon, which the cost budget requires. KEY=value blocks on stdout, a readable view on stderr. Read-only: nothing is cut.

Example:
  lab sysmon
HELP
      ;;
    widget) cat <<'HELP'
lab widget — the Mac in the macOS menu bar

  lab widget install
  lab widget remove
  lab widget modules [list|on <module>|off <module>]
  lab widget order save|show
  lab widget order apply [--relaunch]
  lab widget order stow <name> [--relaunch]
  lab widget tidy [--confirm] [spacing|duplicates|istat]

install puts in place the lab top dot (every 60 seconds: colored by memory pressure, the number of agent sessions and the number of cuts; its menu cuts with one click) and six system modules — processor, memory, disks, network, battery, temperatures — refreshed every 10 seconds, each its own bar item with a detailed menu (figures and, for processor and memory, the top five consumers). A single collector feeds the six modules, as the cost budget requires. lab installs macmon through brew for temperatures and power; without it the native modules still work. modules list shows the active modules, off removes one and on puts it back; the state is kept.

SwiftBar is never installed by lab: without it, install shows brew reinstall --cask swiftbar and stops. The plugins go into the plugin folder SwiftBar already uses, otherwise into a folder of lab registered in its preferences; SwiftBar opens at login. The items are placed near the right end of the menu bar, grouped, so that a full bar does not hide them behind the notch; a place you chose by dragging stays. remove takes the dot and the six modules away, and the login item if lab added it; macmon, the preferences and the other plugins stay. KEY=value on stdout: WIDGET=, PLUGIN=, MODULES=, MACMON=, LOGIN_ITEM=, SEPARATOR=.

install also puts a chevron left of the dot. Closed, it pushes every icon on its left off the screen; open, it shows them for 10 seconds. Its menu draws a map of the bar (notch, room left, what is visible, what is tucked away) and watches it: a lab icon hidden, a new icon right of the chevron, an order that moved, a duplicate or iStat back. Until the bar is tidied, it walks through four steps, one at a time, each saying what it implies before its button.

order save keeps the position of every menu bar icon (Command-drag them first: left of the chevron to tuck an icon away, right of it to keep it visible). order show compares with the saved order. order apply puts it back: a SwiftBar plugin is moved without a relaunch, a stopped app is written; an app that runs must relaunch, which is announced with its impact and done only with --relaunch (the click in the menu). cmux, agents and SwiftBar are never relaunched. order stow tucks one icon behind the chevron. order refuses while Bartender, Ice or Hidden Bar runs: two bar organisers fight. KEY=value: ORDER=, MOVED=, RELAUNCH=, RELAUNCHED=, PLANNED=, SKIPPED=, REFUSAL=.

tidy announces, then with --confirm does: spacing tightens the system icon spacing from 16 to 6 points (Control Center and SwiftBar relaunch, other apps at their next launch); duplicates hides from the bar the Control Center icons already in its panel (Wi-Fi stays); istat quits iStat Menus and takes it off login (its settings stay; uninstalling it in Setapp is yours). remove puts back every value tidy replaced. KEY=value: TIDY=, SPACING=, DUPLICATES=, ISTAT=.

Examples:
  lab widget install
  lab widget order save
  lab widget order apply --relaunch
  lab widget tidy
HELP
      ;;
    mcp) cat <<'HELP'
lab mcp — see the tool servers (MCP), their copies and memory

  lab mcp
  lab mcp --pin|--bump|--undo [--yes]

Lists each tool server (MCP) configured for Claude and Codex: globally (~/.claude.json, the Claude settings, the Codex config.toml) and for each registered project (its entry in ~/.claude.json, its .mcp.json, its .codex/config.toml). For each one: scope, source, name, transport (stdio or http), package and whether its version is pinned; @latest or no version is not pinned, and each start may fetch a new one.

Then the running copies, grouped by package: copies, processes and resident memory. Agent sessions are never counted, even though their command line names the servers; cmux-cua is counted, never changed.

No secret is ever shown: environment, headers, addresses and arguments other than the package name are never read out, and a file that cannot be read is only named. lab doctor warns when the servers use more than 1024 MB (set mcp_rss_warn_mb= in LAB_HOME/config) or when a version is not pinned. KEY=value on stdout (--json available), a readable view on stderr. Without an option, read-only.

--pin pins each unpinned server launched by npx to the version npx runs, read from its cache without network. --bump offers the latest version published on npm. Both show each change (package before → after, never a file's content) and ask Apply? [y/N]; without a terminal they write nothing, and --yes carries an agreement already given. Each file is saved first, and only the package text changes in it. A server launched otherwise (uvx, pipx) is named with its reason, never pinned. --undo restores the last save byte for byte, or puts back only the versions if a session rewrote the file since.

Examples:
  lab mcp
  lab mcp --pin
  lab mcp --undo
HELP
      ;;
    sweep) cat <<'HELP'
lab sweep — inventory the lanes and what they wait for

  lab sweep [project] [--dry-run]

For each lane: its branch, whether it is merged, and what it waits for (a trial, a closing, the rest of the batch). It is an inventory: it deletes nothing. Only lab close removes a lane. When the project has scripts/lab-services, the services that a closed lane still has are named too, with the command that stops them.

Example:
  lab sweep myproject
HELP
      ;;
    close) cat <<'HELP'
lab close — deliver then remove a finished lane

  lab close [project] <lane> [--confirm <lane>] [--retire <sha>…] [--night-red-ok <reason>]
  lab close [project] <lane> --abandon [--confirm <lane>]
  lab close [project] <lane> --dry-run

--dry-run lists at once everything that would prevent closing, one OBSTACLE line per obstacle with its remedy, then RESULT=ok or RESULT=blocked. Nothing is modified: no merge, no commit, no tab.

Shows what will be delivered and removed, then asks for a confirmation by typing the lane's name again. It requires your trial of the result and your agreement, recorded by the agent. Then it merges the last batch, removes the working copy, the branches and the lane's tab.

Right before the merge, the main branch is read again up to date: if the merge would remove lines added by another lane, lab refuses and names them. Restore them, or confirm that removal with --retire <sha>.

If the last nightly CI of the main branch is red, lab close refuses and suggests a fix lane, unless the lane proves its fix: a green manual run of the same workflow, on a revision that contains the first red commit and comes before the lane head; for such a lane, the count of red nights in lab doctor (ci.night_red_days) does not stop the delivery either. To close anyway, give your reason with --night-red-ok "<reason>": in both cases a dated agreement line (citing the green run for a proof) is committed in the acceptance section of the batch file, before the confirmation, and stays there if the closing stops.

--abandon removes a lane that has nothing to deliver, after the same confirmation.

You never have to type it. Write in the lane's tab, or in the tower's, that the acceptance is validated and the lane can be closed (for example "acceptance validated, close the lane"), or click the button the agent shows you: lab reads your words and the agent closes without --confirm, delivered then removed; from the lane's own tab, that tab closes with its session at the very end. On a red night the agent asks you with one button, "Close <lane> despite the red night": your click is the agreement, its reason written by lab.

In a project with a tower, the tower closes the lane on its own once the acceptance is passed, without asking again; the agent of a lane is refused unless your words were read by lab (--dry-run stays allowed).
Without --confirm, the tower closes only on the agreement recorded by lab acceptance (kept outside the lane, on the tried revision; a hand-written acceptance section never counts) and when three things are green for every target that serves the lane: the acceptance, the tried revision served and verified, and the prod check on it (run again if older than 24 hours); it prints CLOSED_BY=tower and posts a cmux alert in its tab, otherwise lab close names what is missing. --dry-run shows CLOSE_ALONE=.

Example:
  lab close myproject payment
HELP
      ;;
    acceptance) cat <<'HELP'
lab acceptance — record the lane's acceptance after your trial

  lab acceptance [project] <lane> --accept --evidence <text>…
  lab acceptance [project] <lane> --reject [--feedback <text>]

After your trial of the result, the agent records your decision in one command: the tried revision is noted, the last batch file's acceptance section is written, then committed alone. An agreement requires at least one piece of evidence. Refused if the lane is not in acceptance or if changes are not committed. lab writes the Validated by line: who accepted (user, tower or lane agent) and the typed evidence it checked. The decision itself is kept by lab outside the lane, tied to the tried revision (LAB_STATE/<project>/agreements/<lane>); --reject replaces it, lab close erases it once the lane is removed. In a project with a tower, only that agreement lets the tower close without asking you again, and never while a question or a permission waits in the lane.

Typed evidence: check: runs the acceptance_check= command of the project config, written by hand like recette=, and requires exit 0; screens:<batch> checks again the screens filed by lab proof. In a project with a tower, the tower accepts with check:, plus screens: shown to you when the lane touches its interface; the agent of a lane is refused (--reject stays allowed).

You never have to type it: write in the lane's tab, or in the tower's, that the acceptance is validated (for example "acceptance validated, close the lane"), or click the button the agent shows you. lab records your exact words outside the lane, tied to its revision, for one hour (LAB_WORDS_TTL); the agent of the lane or the tower then accepts on them without typed evidence — lab writes the evidence "words: ..." and Validated by "user — words ..." — and closes, since your words are also the order to close. A question, a long message, a command or a negation never counts.

Example:
  lab acceptance myproject payment --accept --evidence "payment tried, agreement received"
HELP
      ;;
    merge) cat <<'HELP'
lab merge — deliver a finished batch

  lab merge [project] <lane> [--title <title>] [--body-file <file>] [--retire <sha>…]

Merges the batch's pull request into staging if it exists, otherwise into the main branch, as soon as the automatic checks are green. If they are still running, a watcher merges in its place after the green and the command returns. The agent runs it at the end of each batch.

Before merging, the command then the watcher redo a dry run on the fresh base and refuse a merge that would remove lines added by another lane: the refusal names file, lines and commit. If that removal is wanted, --retire <sha> allows it for that commit.

In a project with a tower, only the tower merges. Run by the agent of a lane, the command checks the lane then queues it for the tower (MERGE=queued) and merges nothing; the tower merges it at its round, at that same revision, once the checks are green. If the lane changed in between, the tower refuses and the lane queues it again. You, in your terminal, merge as before.

Example:
  lab merge myproject payment
HELP
      ;;
    sync) cat <<'HELP'
lab sync — bring the base branch into a lane

  lab sync [project] <lane>

Merges into the lane the changes that arrived on the base branch, without pushing anything. A conflict is cancelled and named: the lane stays intact. lab launch does it before each session.

Example:
  lab sync myproject payment
HELP
      ;;
    promote) cat <<'HELP'
lab promote — take staging to production

  lab promote [project] [--confirm <project>]

Without --confirm: shows what would go from staging to the main branch, without writing anything. With --confirm: opens the dated pull request and merges it after green checks. Run it yourself; an agent runs it only on your explicit request.

Example:
  lab promote myproject
HELP
      ;;
    batch) cat <<'HELP'
lab batch — read the batch files of the current lane

  lab batch current
  lab batch list
  lab batch new [--title <text>]
  lab batch processes
  lab batch wait <Cn> <date> "<reason>"
  lab batch wait --done <Cn>

Run it in a lane's folder. current gives the current batch file and its state; list gives each batch file and its state; new creates a batch file. processes names what still runs in the lane folder (PROCESS=, PROCESSES=), except the calling session and its helpers: nothing is stopped, the agent stops each one or justifies it in the batch file. Agents use it during a batch.

wait puts an exit criterion on hold for a measure at a date (YYYY-MM-DD, YYYY-MM-DDTHH:MM:SSZ in UTC, or +Nd for N days from today): the batch file gets a Waiting line and the state waiting, the batch is delivered as usual and lab next opens the next one. At the date, lab next reopens this batch file for that criterion only (branch chore/<slug>.c<n>), before the next batch. One postponement per criterion. wait --done marks it measured. The acceptance and lab close wait until every measure of the lane is done. An unknown criterion, a past or unreadable date is refused.

Examples:
  lab batch current
  lab batch wait C4 +7d "traffic check"
HELP
      ;;
    handoff) cat <<'HELP'
lab handoff — check a batch's handoff

  lab handoff [project] [lane] [--template]

Checks that the batch file says where the work stands and which batch follows, commits the lane's batch files, then prints the next command (NEXT_COMMAND). --template prints the expected form. The agent runs it at the end of a batch.

Example:
  lab handoff
HELP
      ;;
    wake) cat <<'HELP'
lab wake — reopen waiting batches at their date

  lab wake
  lab wake --install
  lab wake --remove
  lab wake --status

Without an option: for each lane whose waiting measure is due and that has no live session, runs lab next, which reopens the batch file for that criterion; a project's tower without a live session is restarted the same way (WOKEN=<project>/tower). --install sets the macOS alarm, a launch agent that runs lab wake every hour and at login; lab batch wait sets it too. --status says whether it is loaded and when it last ran; --remove takes it away. Each run is written to wake.log in the state folder. If cmux cannot be reached (its socket accepts only the processes it started), a due lane is only logged and the next lab next reopens it.

Example:
  lab wake --status
HELP
      ;;
    now) cat <<'HELP'
lab now — the timestamp of the logs

  lab now

Prints the present instant in universal time, as YYYY-MM-DDTHH:MM:SSZ. Agents use it to date their logs.

Example:
  lab now
HELP
      ;;
    due) cat <<'HELP'
lab due — follow a project's due dates

  lab due [project]
  lab due [project] add <YYYY-MM-DD> <subject…>
  lab due [project] done <id> <sha>
  lab due [project] reschedule <id> <due date>
  lab due [project] cancel <id> <reason…>

Without an action: the open due dates, late ones first, then those within 48 hours. The actions add a due date, or settle an existing one: done (with the commit that proves it), rescheduled or cancelled (with a reason).

Example:
  lab due myproject add 2030-01-15 follow up with the supplier
HELP
      ;;
    account) cat <<'HELP'
lab account — rotate the Claude accounts

  lab account
  lab account add <label>
  lab account remove <label>
  lab account next
  lab account identify [<label> [<e-mail>]]
  lab account free <label>|--all
  lab account badge <label>
  lab account use <label>
  lab account coderouter <label>
  lab account record

Account no. 1 is the one of your /login. add guides three steps: your /login with that account becomes its badge, claude setup-token gives a token stored in the macOS keychain (never in a file), then the token joins CodeRouter, the team accounts the Cloud machines use. A failed step keeps the previous ones; coderouter sends a stored token later. When an account reaches its limit (5 hours or 7 days), the account really logged in is noted, and the same conversation resumes in its tab on the free account whose 7-day reset comes first; if all are exhausted, the tab shows each account, waits for the reset time and resumes alone (Ctrl-C keeps notes and lane: lab next resumes). next switches account right away, from the lane's Claude session.

identify links the e-mail of the current /login (or the given one) to a label, so that a manual /login is noted on the right account. free erases a wrong note, principal included. record reads the JSON of the Claude status line and keeps each account's usage; add this line after input=$(cat) in your status line script:
  printf '%s' "$input" | lab account record

Example:
  lab account add personal
  lab account identify personal
HELP
      ;;
    cloud) cat <<'HELP'
lab cloud — a project's Cloud rule

  lab cloud <project> [<lane>] [yes|no|reset]
  lab cloud <project> image [<machine>] [--ref <branch>]
  lab cloud <project> needs [reset]
  lab cloud <project> suite [<lane>]
  lab cloud <project> clean [--dry-run]

Says whether this project's batch sessions may run on cmux Cloud machines, and where the answer comes from: lane, project, global setting (cloud= in ~/.lab/config, read only) or default (yes). yes or no records it for the project, or for the named lane only; reset removes that level. Run without a project in a lane's folder, it targets that lane. With cmux, lab status, lab next and the session context show it. no keeps every batch on the Mac, whatever its Execution line; with yes, each batch file chooses (see lab help next), never a question.

image prepares the project's machine once (test tools, lab's method) from the main branch, or the one of --ref, freezes it as a snapshot then pauses it: each batch starts from it.

needs lists what Cloud sessions could not do without the Mac: when a session writes "blocked: need <need>: <detail>", lab takes it back on the Mac and remembers the need here, outside the repository. That batch then stays on the Mac, and so does a batch file without an Execution line; planning reads them. needs reset forgets them all. Without a value, lab cloud also shows them (NEED=) with the 5 last Cloud sessions (SESSION=: duration, pushes, outcome).

suite runs the project's bats suite of the current commit on a disposable Cloud machine restored from the image and sized to the largest tier the plan allows and has free (at least 4 vCPU, one bats job per vCPU), through the project's launcher scripts/cloud-suite.sh, then deletes the machine, even on failure or interruption. An image older than its tooling (scripts/cloud-image.sh and the files it reads, on the base) is rebuilt first, once, under a lock; a transient HTTP 502 is retried twice; a test stuck past 600 s is stopped and red, and at the global deadline the partial report is pulled before the machine is deleted. The committed tree is sent without lab's batch documents and without any token; each red is replayed alone. The answer is the exit code: SUITE=green (0), red (1, RED= names each test that stayed red alone) or unavailable (3, REASON=: uncommitted changes, cloud=no, no image, cmux or launcher missing) — RUN=cloud. A plan still full after the cleanup (no tier left, or HTTP 402 with the counted machines) runs the same suite on the Mac at once, never silently: RUN=mac, PLAN_FULL= (why), PLAN_ALERT= and a notification say that a larger plan would keep the suite on the Cloud; one job, macos tests included, in a frozen copy of the commit, same verdict and exit code. DURATION_S= counts everything; REPORT= keeps TAP, JUnit and replays.

clean frees the plan: it deletes the project's Cloud machines that nothing uses any more (restored from its image, no open lane naming them, not in use, older than 10 minutes: an orphan suite VM, a closed lane's VM) and its image snapshots older than the previous one, unless a machine still starts from them. The image machine, an open lane's machine, the current and previous snapshots are always kept; a machine lab did not restore from the project's image (another project, cmux's agent pool, a hand-made one) is never touched. --dry-run only names them (CLEAN_VM=, CLEAN_SNAPSHOT=; CLEAN_KEPT= says what is kept and why, CLEAN= the count). The same cleanup runs before each suite and each Cloud batch start.

Before each start, lab creates a deploy key limited to the repository with gh — no keychain token, no manual step: the key pair is generated on the VM, only the public key goes up for gh repo deploy-key add, the VM clones, fetches and pushes over SSH, and the key is revoked on GitHub at the end (proof), even if the VM stays paused. lab also checks that a CodeRouter Claude account is healthy and shared with the team (lab account shows them, without secrets), and pauses again the project's machines woken without a session (lab status reports them). Full plan: the lane waits its turn in a queue, lab status shows its place. A shared machine stays awake until its last session ends; each lane revokes its own deploy key, and lab close only erases the lane's folder on it; otherwise lab close deletes the lane's machine, never the image's.

Examples:
  lab cloud myproject no
  lab cloud myproject image
  lab cloud myproject suite
HELP
      ;;
    proof) cat <<'HELP'
lab proof — store a batch's evidence

  lab proof [project] <batch> add [--step <name>] <files…>
  lab proof [project] <batch> verify

add copies a batch's screenshots, outputs and measurements outside the repository, with each file's fingerprint. verify recomputes these fingerprints and reports a modified or missing piece of evidence.

Example:
  lab proof myproject lot-01-payment add screenshot.png
HELP
      ;;
    lock) cat <<'HELP'
lab lock — hold a resource shared between lanes

  lab lock [project] <resource> [--pid <pid>]

Reserves a resource declared in the project configuration (a simulator, a local database, a port) for the current lane. If another lane holds it, the command refuses and names it. lab unlock releases it.

Example:
  lab lock myproject simulator
HELP
      ;;
    unlock) cat <<'HELP'
lab unlock — release a shared resource

  lab unlock [project] <resource>

Releases a resource held by the current lane, or by a session that no longer exists.

Example:
  lab unlock myproject simulator
HELP
      ;;
    served) cat <<'HELP'
lab served — record which lane serves the application

  lab served <port> [--pid <pid>]

Called by the project's development script: it records the lane, its revision and the served port. At a session's start, the agent thus knows which version is running.

Example:
  lab served 3000
HELP
      ;;
    services) cat <<'HELP'
lab services — stop the local services of a lane

  lab services [project] stop <lane>
  lab services [project] list [<lane>]
  lab services [project] stop --orphans

A project can declare one executable file, scripts/lab-services, committed with the code. lab finds it by its presence alone and runs it with the verb stop: the Docker stack, database or containers of that lane are stopped and removed. lab close and lab close --abandon run it themselves, from the lane's folder, just before removing that folder; this command runs it again afterwards, for example when the first attempt failed.

The hook gets LAB_PROJECT, LAB_LANE and LAB_WORKTREE (empty when the lane's folder is already gone: the hook of the main checkout is used instead, and may be older than the one the lane had). It has 120 seconds; beyond that, it and its children are stopped. A failure never blocks a closing: lab names it and removes the lane anyway.

With the verb list, the hook names what the lanes still hold, one resource per line. lab services list shows them lane by lane (ORPHAN=yes for a lane already closed); lab sweep and lab doctor name the closed ones, in 15 seconds at most, and never stop anything. stop --orphans stops them all, one lane after the other, and goes on after a failure.

A ready-made example for a Docker Compose stack named after the lane: templates/project/lab-services.

Example:
  lab services myproject stop payment
  lab services myproject list
  lab services myproject stop --orphans
HELP
      ;;
    deploy) cat <<'HELP'
lab deploy — go live without erasing another lane

  lab deploy [project] <target> [--with <lane>…]
  lab deploy [project] <target> --retire <lane>
  lab deploy [project] <target> --record
  lab deploy [project] <target> --dry-run
  lab deploy [project] <target> --cancel
  lab deploy [project] <target> --check
  lab deploy [project] --queue
  lab deploy [project] --add [type] <target>

Declare a target: --add writes its block in the project configuration from a template. The type is inferred from the repository (wrangler.json → worker, Dockerfile → cloudrun) or given: worker, rsync (--host, --path, --restart) or cloudrun (--region). --include names the private files, outside the repository, copied from the main checkout before each deployment. A target already declared is never rewritten.

Deploys a target declared in the project configuration (deploy.<target>= and probe.<target>=). It always starts from the up-to-date main branch; from a lane, its branch is added, and --with adds others. The assembly is pushed to serve/<target>.

A registry records what is served. If the target serves an unmerged lane that you do not include, lab refuses and names it: include it with --with, or remove it with --retire. The probe then checks the served revision. --record registers what exists without deploying; --dry-run shows the plan.

One go-live per target at a time. In a project with a tower, lab deploy from another lane goes into the target's queue (DEPLOY=queued POSITION=n): nothing is deployed, and the tower's round, lab deploy <project> --queue, deploys each request in order at its queued revision, staging and production apart. A red CI or a failed go-live stops that target's queue and marks the lane blocked (DEPLOY_STOPPED=) until the lane asks again; --cancel removes its request. Without a tower, a target already being deployed is waited for, 30 minutes at most (LAB_DEPLOY_WAIT_MAX), then lab gives up and names the lane holding it. lab status and lab tower show the queues (DEPLOY_QUEUE=).

Production check: prod_check.<target>=, written by hand in the project configuration, is a read-only command that says whether production works. lab deploy runs it once the probe has verified the served revision and records the result in the registry (PROD_CHECK=green or red). Red: the go-live stays, nothing is rolled back, the lanes it serves are marked blocked and the tower is warned. --check runs it again on the served revision without deploying anything.

What is live shows at a session's start, in lab status and in lab next (SERVED=). That line ends with the last prod check. A merge marks the lane "merged" without deploying anything. In a project that declares a target, a direct deployment (wrangler deploy, gcloud run deploy, rsync to a server…) is refused: go through lab deploy.

Examples:
  lab deploy myproject --add worker api --include api/wrangler.prod.json
  lab deploy myproject production --dry-run
HELP
      ;;
    watch) cat <<'HELP'
lab watch — a delivery's watcher

  lab watch <project> <lane> <branch>

Internal command: you do not have to run it. lab merge and lab close start it in the background to wait for the automatic checks, then merge. lab status shows where each watcher stands.

To follow a delivery:
  lab status myproject
HELP
      ;;
    hook) cat <<'HELP'
lab hook — the automations called by the agents

  lab hook session-start
  lab hook session-end
  lab hook guard-bash
  lab hook guard-tool

Internal command: you do not have to run it. Claude Code and Codex call it at a session's start and end, and before a risky command. An automation never blocks your work on an internal error.

To check that they are in place:
  lab doctor
HELP
      ;;
    setup) cat <<'HELP'
lab setup — install Treelab on this machine

  lab setup [--dry-run] [--dev] [--import <copy>]
  lab setup --reapply

Checks the machine, summarizes what will be installed, then waits for your agreement before writing. Your existing settings are kept and backed up. --dry-run shows the plan without installing anything.

Then: lab doctor, then lab onboard in your project's folder.

Example:
  lab setup --dry-run
HELP
      ;;
    doctor) cat <<'HELP'
lab doctor — check the installation

  lab doctor [project] [--report] [--project-only] [--root <folder>] [--freeze]

Checks the machine's installation and, with a project, its working frame. Each point is green, a warning or red; a red comes with what to do. Read only, except --freeze, which resets the reference of the project's measurements.

--report produces an anonymized report that you can pass on: nothing is sent.

Example:
  lab doctor
HELP
      ;;
    subscribe) cat <<'HELP'
lab subscribe — subscribe without changing keys

  lab subscribe

Opens this installation's subscription page in your browser. A trial key becomes a paid key: nothing to paste, nothing to reinstall. A cancelled or unpaid subscription opens its Stripe page (card, invoices, renewal). The link comes from the activated installation, works for one hour and is shown only when no browser opens.

With a terminal, it waits for the payment, 30 minutes at most, then shows the new end date; q then Enter stops waiting without losing anything. Without a terminal (an agent), it opens the page and returns at once. A key without an end date has nothing to do; another seat of a team subscription is managed by its purchaser.

Example:
  lab subscribe
HELP
      ;;
    update) cat <<'HELP'
lab update — update Treelab

  lab update [--rollback|--resume|--catalogue]

Downloads the latest version, checks it, then switches to it. The previous version is kept: --rollback goes back to it, without network. --resume resumes an interrupted update. --catalogue only reads the available version.

Running agent sessions may stay open: they keep their version, the next one starts from the new one. Without typing anything, lab next installs the latest minor or patch version at most once a day; a major version is only announced. To receive only the announcement, write auto_update=no in ~/.lab/config.

Example:
  lab update
HELP
      ;;
    uninstall) cat <<'HELP'
lab uninstall — remove Treelab from this machine

  lab uninstall [--dry-run] [--keep-state] [--resume]

Removes what lab setup installed and restores your previous settings. Your additions made since are kept, as well as the backups. Ginkgo too, shown before your agreement: the app is stopped, its microphone permission forgotten, its OpenAI key and its folder removed. --dry-run shows the plan; --keep-state keeps the registered projects, the Ginkgo key and folder; --resume resumes an interrupted removal.

Example:
  lab uninstall --dry-run
HELP
      ;;
    glossary) cat <<'HELP'
lab help glossary — Treelab's words, with their former French names

Older batch files, plans and habits use the French words: lab reads both, and each French command name still works.

  lane (FR: couloir)
      one need, in its own working copy, branch and tab.
  batch (FR: lot)
      one step of a lane: one branch, one session, one pull request.
  batch file (FR: fiche)
      the batch's document: Goal, steps, log and Handoff.
  Goal (FR: Objectif)
      the batch's observable result, one line handed to the agent.
  exit criteria (FR: critères de fin)
      the measurable evidence that the Goal is reached: C1, C2…
  log (FR: journal)
      what each session did and proved, dated.
  Handoff (FR: Reprise)
      where the work stands and what comes next, readable without the agent's memory.
  evidence report (FR: preuves)
      the long story, captures and measurements of a batch.
  acceptance (FR: recette)
      your trial of the finished lane, then your recorded agreement.
  treeplan (FR: treeplan)
      a lane's roadmap: the order and intent of its batches.
  masterplan (FR: masterplan)
      why the project exists, and its overall goal.
  permanent lane (FR: couloir permanent)
      a lane kept for good: its batches are delivered by pull request, never tried, removed nor closed.
  tower (FR: tour)
      a project's permanent lane that checks every lane and warns you; it never answers for you. One per project: lab onboard creates it, lab tower --all offers it to older projects.
  waiting batch (FR: lot en attente)
      a delivered batch whose criterion waits for a measure at a date; lab next reopens it then.
  tool server (FR: serveur d'outils)
      a program (MCP) that gives an agent extra tools; lab mcp lists them.

French command names:
  lab acceptance (FR: lab recette)
  lab account (FR: lab compte)
  lab account free (FR: lab compte libre)
  lab due (FR: lab rdv)
  lab batch (FR: lab lot)
  lab tower (FR: lab tour)
  lab top (FR: lab poste)

Example:
  lab help glossary
HELP
      ;;
    *) return 1 ;;
  esac
}
# help_alias <commande> → le nom anglais d'un ancien nom français (alias muets : recette, compte, rdv, lot, glossaire, poste, tour), sinon la commande
help_alias() { case "$1" in recette) echo acceptance ;; compte) echo account ;; rdv) echo due ;; lot) echo batch ;; glossaire) echo glossary ;; poste) echo top ;; tour) echo tower ;; *) printf '%s\n' "$1" ;; esac; }
# cmd_help [commande] : page courte ou page d'une commande, sur stdout ; commande inconnue ou arguments en trop → message, code 2
cmd_help() {
  local text
  # die écrit le refus (lui seul écrit le préfixe d'erreur) ; une demande d'aide mal formée sort en 2, comme l'usage
  if [ "$#" -gt 1 ]; then (die "one command at a time: lab help <command>") || exit 2; fi
  if [ "$#" -eq 0 ]; then text="$(help_page)"
  else text="$(help_topic "$(help_alias "$1")")" || { (die "unknown command: $1 — lab help lists the commands") || exit 2; }; fi
  printf '%s\n' "$text" | onboard_wrap "$(onboard_cols)"
}
