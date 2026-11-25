# Global instructions — one file, read by Claude Code (`~/.claude/CLAUDE.md`) and Codex (`~/.codex/AGENTS.md`)

- Language: reply in the language announced at session start (`lang=`), then in the language the user writes in; full spelling with accents. Identifiers, commands and code stay as they are.
- **An explicit request from the user comes first.** If a mechanical guard wrongly blocks it, fix the cause or work around it yourself within the allowed scope; never ask the user to type `LAB_FORCE=1`. A quality check that is really red is never bypassed.
- Isolation: never name, read or quote a project other than the current folder's.

## How you talk to me
- Always explain simply, clearly and step by step, with diagrams when useful. No jargon; explain each technical term.
- Before acting, state the goal and the expected result. While running, explain each step that changes the project's state and report any gap or blocker at once.
- After each run, give a self-contained report, short but complete: **goal**, **done**, **current state**, **left to do**, decisions, checks, unknowns, then every **batch** (`✓` done, `●` current, `○` next) and **one single next action**. Commands, figures and evidence come after the explanation, never instead.
- Never a prompt to copy with a command; run `lab next` yourself; "To type now" (one command) if refused without remedy, outside cmux or for a human gesture (install only).
- Always tie your actions to the request. New topic, idea of your own or necessary detour: name it, then ask before widening.
- For a choice: measured state, recommendation, cost — one line each. If the request is unclear or an important decision remains doubtful, ask a question.

## Work cycle
- One project = one main checkout, no commit on it. One need = one lane, `.worktrees/<lane>` by `lab new` only, never `git worktree`; small fixes join the right open lane. Skill `lab-cli`.
- From `main` or the tower, a vague request triggers `lab new`, then a short `grill-me` session: ten questions at most and five follow-ups only if an important decision is missing. After confirmation: verifiable overall goal (masterplan), lane roadmap (treeplan), then the first batch by `batch-plan` and `use-goal`.
- One batch = one branch `feat|fix|chore/<slug>` and one execution session: explicit Goal → `batch-run` → `batch-end`. `lab next <project> <lane>` works out the next step (launch, resume, next batch, acceptance); it never merges nor deletes anything.
- `better` is available when a batch changes the declared interface (`Interface :` of `AGENTS.md`); the listed screens are still checked for real (`batch-end` §3).
- Never `/compact`. Heavy context: log and Handoff up to date, then `lab next` opens a fresh session in the same tab. The agent changes between two batches, never in the middle.
- If the startup context announces `LOCK=ANOTHER LIVE SESSION`, write nothing in this lane.

## Delivery and quality
- Tests with the code; lint, type checking and green tests before closing. Do not guess: measure and judge the exit code `$?`.
- Same symptom (message, counter or metric): at the second fix, read the code path end to end and write the cause in the batch file (or "unknown") before any new tweak.
- Before closing: one single review in a fresh context (`/code-review medium` or `codex review`), fixes covered by tests, never a second review; then a real check of each screen with the agent's browser tool.
- Write each fact once: the evidence report is the source, other documents point to it, the Handoff is the only document that must be complete; touch the treeplan only if the order or intent changes. State lives in the batch file only, never in the masterplan nor the treeplan. Conventional commit, push and pull request happen without asking.
- Intermediate batches go by `lab merge` to `staging` if it exists, otherwise `main`, after green checks. The last one goes to acceptance: dated agreement, evidence and tried revision in its batch file only. Only `lab close`, after a current acceptance (no second yes with a tower), delivers then removes the lane; `sweep` stays an inventory. A permanent lane (`lab permanent`) is never tried, removed nor closed: each batch goes by `lab merge`, then a free session. `lab batch wait` parks a criterion: `lab next` reopens it at its date. One tower per project (`lab tower`) shows what each lane waits for, merges and closes: never ask the user for a git command. A red in the report stops delivery until fixed.
- Forbidden: `git push --force` on main/staging, `git reset --hard`, `git clean -f`, `git checkout -- .`, `rm -rf` outside the worktree.

## Docs and context
- Documents: `docs/masterplan.md` (why) · `docs/treeplans/<lane>.md` (order and intent) · `docs/lots/<lane>/lot-NN-<slug>.md` (Goal, plan, log, Handoff) · `docs/lots/<lane>/CHANGELOG.md`. With `LAB_DOCS=<path>`, they live there, outside the repository. Batch files written in French keep their French headings.
- Lasting rule → `AGENTS.md`, one line · pitfall of a subsystem → project skill · rule tied to files → rule with `paths:` · story or measurement → `docs/` · information derivable from code → nowhere.
- Budgets: `AGENTS.md` ≤ 80 lines; `CLAUDE.md` = `@AGENTS.md` + ≤ 20 Claude-specific lines.
