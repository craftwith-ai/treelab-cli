# Changelog

Release notes of each published version of Treelab, newest first.

## 1.8.2 — 2026-11-26

**The doctor no longer stops while wrapping its lines on Linux**

- On Linux, lab doctor run in a terminal could stop in the middle of its report with “Diagnosis interrupted”: the line it was wrapping to the terminal width was cut while being written. The text is now fully wrapped before it is written.
- First release of the content of 1.8.1, whose build stopped on this fault.

## 1.8.1 — 2026-11-26

**A dated measure no longer blocks the trial**

- When the pull request of the last batch waits for your trial, a due measure of an earlier batch starts from the base, without the code not yet accepted; the branch of the last batch is kept aside, untouched.
- Once the measure is merged, lab next goes back to that branch by itself, merges the base into it and opens the trial: no more loop between the measure, the merge and the trial, nothing to type.
- During the measure, lab next and lab status say where the lane will come back, and the tower announces the measure to make before the trial.
- A measure due on the last batch itself is refused with its cause and its remedy, without any merge.

## 1.8.0 — 2026-11-26

**One task, one session: a few questions, then the agent codes**

- When a worktree opens, the agent asks its questions in one go, then writes the lot, codes it and closes it in the same session: your answers are your agreement, with no plan to approve nor summary to confirm.
- The next lots ask questions only when a decision remains open; otherwise the agent carries on without asking you.
- A lot stays on your Mac by default: only a lot whose document asks for the Cloud goes to a Cloud machine.
- Explaining a process (lab top --explain) opens a tab where Claude says what is running, cutting and changing nothing before you agree.
- The home page publishes the new count: at least 3 actions from you for a worktree of two lots, measured with Claude Code and with Codex.

## 1.7.0 — 2026-11-26

**Docker no longer fills up: what lab starts goes away when it ends**

- Closing a lane announces its Docker containers and images before your agreement, then removes them after the delivery, running ones stopped first; Docker missing, silent or refusing never blocks the closing.
- lab docker clean also removes everything that lanes already closed left, whatever its age; never anything of another project nor without a label.
- lab doctor warns, never fails, when Docker is short of room or leftovers of the project remain, with the figures and the command that removes them.
- In a lab project, the agent no longer runs a Docker command that would leave leftovers: the guard gives the exact line, with --rm, the labels and the project's builder.

## 1.6.1 — 2026-11-25

**The tower first: the main tab hands over to it**

- A main tab left by an older version hands over to the tower then closes, by itself, with nothing ever typed in it nor asked: an idle terminal closes, a Claude session at rest is summed up by a headless copy of its conversation, never saved.
- The tower sums the handover up in three lines and asks you, with one checkbox question, which needs open a lane; a tower already open is told once to read its skill again.
- Your “yes, close” is given once: it also covers a red night and the fixes that follow it, and neither a mere question nor a message from another session takes it back.
- Never closed: the tab you are looking at, the last one of its workspace, or one where another program runs.
- While a pull request waits for its checks, its watcher launches ten times fewer programs per minute, with exactly the same decisions.

## 1.5.1 — 2026-11-24

**Close as soon as the checks are green**

- Once you accept the result, the lane is delivered and closed as soon as the checks of its pull request are green: no label posted and no wait for the full suite, which runs every night.
- Leftovers of lanes already closed disappear on their own, with no gesture or button, and no longer show in the project status.
- The project status, the list, the plan, a session start and the health check give the same answers with up to 780 times fewer processes.
- The tower is the only pinned tab, and the first; a new project is welcomed in a tab of its own that closes by itself.
- The tower reads production health at each pass: a red one waits for you with its numbers and alerts you once, nothing blocked.

## 1.5.0 — 2026-11-22

**Free trial and subscription: the key arrives at once**

- A 14-day free trial, no card: the installer shows the agreement before sending, and the key leaves at once by email, in English or French, with the contract attached.
- A monthly or yearly subscription, per seat: one email confirms the purchase, its price, its taxes and its contract, then the keys appear. On the payment page, your local currency may be offered.
- Your trial key becomes the paid key, with nothing to reinstall: from lab subscribe, the installer or the link in the trial email. After a trial request, the installer never opens the new-key page again.
- The pricing page says it all: price per seat with taxes included, team discount, what stays yours if you stop, licence and readable code.
- Resuming a session: the input line of a tab is cleared before each typed command, never glued to another one again.

## 1.4.2 — 2026-11-22

**Accept and close in a few words, nothing to type**

- Write “acceptance validated, close the lane” in the lane’s tab or the tower’s: treelab reads your words, the agent accepts, then delivers and closes, folder and tab included. A click on a button works too, even to close despite a red night.
- Ginkgo comes with treelab: talk to the tower out loud, it answers, reads the question of a waiting lane, answers it for you and tells you on its own when something waits for you.
- The tower merges, goes live in order, runs the production check and closes on its own what you accepted: no command left to type.
- A 14-day free trial by e-mail, a monthly or yearly subscription for several seats; your update rights are shown, with a reminder before they end.
- On a new Mac, the installer asks one question per screen and speaks French on a French Mac.

## 1.3.0 — 2026-11-12

**A control tower watches over each project**

- `lab tower <project>` opens a tower that checks in every 30 minutes and tells you what each lane is waiting for from you: a question, a permission, an acceptance ready or a blocked lane alerts its tab.
- A lane can become permanent: it chains its batches and never goes to acceptance or gets closed.
- A batch with a measurement that can only happen at a later date is delivered anyway, then reopened on its own at that date.
- A Claude window that hits its limit restarts in its tab on the next account, each login checked by a real call.
- The Cloud test suite fits your plan and falls back to the Mac when the plan is full; services of closed lanes are reported and stopped in one command.

## 1.2.5 — 2026-11-11

**Sessions restarted all at once each keep their lane**

- When cmux reopens dozens of sessions at once, none is wrongly told “update in progress” any more: a session that starts alongside the others works normally and takes its lane lock at its first tool.
- A live session in a lane without a lock is named: `lab status` shows it, `lab next` refuses to open a second session on the same files, and `lab doctor` tells you what to do.
- A real update keeps its message: start nothing until it has finished.

## 1.2.1 — 2026-11-04

**Closing work that is already delivered no longer trips over the main branch**

- When your pull request is already merged and your copy then pulled the main branch, `lab close` no longer refuses the files that came from that branch: they are already delivered, and one line tells you how many were set aside.
- A file that really differs from the main branch stays protected: closing stops and names it.
- Offline, the real close stops and keeps the folder instead of judging from an old copy.

## 1.2.0 — 2026-10-28

**A tidy menu bar, and Cloud agents that hold on**

- A chevron in the menu bar hides the other apps’ icons behind it and tells you when a new app shows up or the order has moved.
- `lab widget order save` remembers the order of your icons and `lab widget order apply` restores it; `lab widget tidy` tightens the spacing and hides duplicates; `lab widget remove` undoes it all.
- On a Cloud machine, a command that eats all the memory is stopped on its own: your agent goes on with its batch instead of going down with it.
- An agent stopped on its Cloud machine, or a paused machine, is reported with its cause by `lab next` instead of leaving the batch waiting.

## 1.1.1 — 2026-10-26

**Closing work delivered in two steps now goes all the way**

- When your last batch was delivered by two stacked pull requests and your local copy followed the main branch afterwards, `lab close` now removes the folder and branches instead of stopping on “remote branch changed”.
- A remote branch that really carries new work stays protected: closing stops and keeps it.
- A folder left open by this issue closes when you type `lab close` again.

## 1.1.0 — 2026-10-26

**Your Mac at a glance, and accounts that no longer lock up by mistake**

- `lab top` shows each of your agent’s sessions tied to its project, the memory state and what can be cut safely; `lab widget install` puts it in the menu bar, with six system modules (processor, memory, disks, network, battery, temperatures).
- Claude account rotation records the account actually signed in: an account with usage left is no longer marked exhausted, the wait stops cleanly with Ctrl-C, and `lab account free` clears a wrong note.
- `lab close` also closes the tabs and processes left in the closed folder, accepts a last batch delivered by two stacked pull requests, and finds a pull request merged by hand.
- `lab mcp` measures your agent’s tool servers and pins their version on request; `lab doctor` warns above 1 GB.
- `lab sweep` is up to three times faster with many working folders, and Cloud mode picks on its own, batch by batch, between a remote machine and your Mac.

## 1.0.1 — 2026-10-16

**Merging no longer waits for a job that will never run**

- When a pull request is marked ready and a job is skipped by its own condition (a deployment limited to main, for example), `lab merge` merges it as soon as the rest is green, instead of waiting three hours.
- If a job reserved for ready pull requests can no longer run because the workflow does not listen to `ready_for_review`, `lab merge` stops right away and says what to do: add `ready_for_review` to the `pull_request` types, or push a commit.
- `lab doctor` reports this setup ahead of time.
- A watcher already waiting resumes when you type `lab merge` again.

## 1.0.0 — 2026-10-15

**Treelab speaks English**

- The `lab` command, its messages, its refusals and the website installer are in English, like the instructions given to your agent, the context handed over at the start of each session and the `KEY=value` lines it prints.
- Your agent answers in your Mac’s language, then in the language you use with it.
- The former French command names are still accepted, and `lab help glossary` gives each English word with its former French equivalent.
- Your existing projects carry on unchanged: their French documents and whatever lab had already written on your disk are still read as they are.
- The licence and terms of sale move to version 2026-10-15.1, which describes a package in English; `lab update` installs this version like the previous ones.

## 0.9.2 — 2026-10-11

**Founder places shown, simpler withdrawal**

- The “Founder pack” card on treelab.sh shows how many of the 20 places are left, based on sales actually paid, and says when the offer is sold out.
- A purchase made from the terminal can be withdrawn through the personal link sent with your key: the key is revoked, the refund follows and you receive a confirmation.
- The `lab` command is unchanged: nothing to do on your side, `lab update` installs this version like the previous ones.

## 0.9.1 — 2026-10-11

**What’s new, online sooner**

- Each new version appears sooner on treelab.sh, its what’s-new pages and its Atom feed: a version already checked is no longer re-verified in full before going live.
- The `lab` command is unchanged: nothing to do on your side, `lab update` installs this version like the previous ones.

## 0.9.0 — 2026-10-11

**Parallel work without loss**

- Where several sessions share the same git index, a `git commit` without paths or an overly broad `git add` is refused, with the safe command instead.
- A database migration that reuses a number already taken is refused before merging, with the next free number; applying it remotely is refused outside the main branch.
- `lab close --dry-run` lists every obstacle before closing, and `lab recette` records approval or refusal after a trial.
- When `lab update` fails, it names the reason and the file involved.
- Buying from the terminal: the install script creates the order for the chosen offer, follows the payment for 30 minutes and accepts the key pasted from the e-mail.

## 0.8.2 — 2026-10-08

**Stricter reviews**

- The end-of-batch review also reports a weakened test, scope creep and needless complexity.
- Verification gives one verdict per completion criterion: passed, failed or to be checked.
- Upgrading with `lab update` still works from 0.8.0 and earlier versions.

## 0.8.1 — 2026-10-07

**Update fixed with Codex**

- `lab update` failed silently on machines with Codex installed: upgrading works again.
- The review agents generated for Codex are now updated without blocking during later upgrades.

## 0.8.0 — 2026-10-07

**Simpler purchase, finer checks**

- Payment fits on a single page; the confirmation e-mail arrives in your country’s language, with the licence key first and no attachment.
- The key is sent as soon as you pay; a withdrawal revokes it.
- The setup assistant offers Claude Code first and explains what to do if you paste a fingerprint instead of the key.
- `lab doctor` flags a batch that weakens its tests without a written reason, and any completion criterion never cited as proven.
- `git checkout -b` is no longer wrongly refused by the guardrails.
