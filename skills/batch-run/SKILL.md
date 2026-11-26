---
name: batch-run
description: Runs the current batch's Goal step by step, with tests, evidence, log and commits, then applies batch-end. Use it in the session that planned the batch, right after batch-plan, or in the resumption opened by lab next.
---

# batch-run — run a batch

Prerequisite: the current batch is planned or in progress (`planifié`, `en cours` in a French batch file) with a precise Goal — the session that planned it goes on with it, the resumption opened by lab next receives it in its start message. Otherwise, apply `batch-plan`; never invent the expected result.

## Start

1. Read the Goal, `docs/treeplans/<lane>.md`, the whole batch file and its Handoff if any.
2. Set the batch file alone to in progress, in the language of its State field: `en cours` under `**État**`, `in progress` under `**State**`. The treeplan keeps order and intent; write no state in the masterplan nor in another lane's documents.
3. Find the project's real commands: install, tests, code style check and type check.
4. If screens are listed, keep them with their sizes as closing criteria, not as suggestions; `better` stays available to review them, at your discretion.

## Loop per step

- Do the smallest step that brings the Goal directly closer, with its test. No uncovered code, unless an exception is explicitly justified in the batch file.
- Run the targeted checks. Quote command, exit code and an understandable result. When the project's CI workflow cites the `full-suite` label, the targeted tests are the same selection as its CI (`scripts/ci-select.sh files <base> HEAD` when the project has it) and no whole suite runs for a batch, locally or on the Cloud: it runs in CI at night (and at the tag when the workflow has one); a `full-suite` label posted by hand runs it once per posting, so remove the label and post it again to rerun it. Otherwise the whole suite waits for frozen code: `lab cloud <project> suite` when the project has `scripts/cloud-suite.sh` and it answers (rc 0 green, 1 red), otherwise the suite on the Mac, detached.
- **Cause before the second fix.** Same symptom = same message, same counter or same metric. At the second fix of the same symptom, stop: read the code path end to end (or apply the project's investigation skill if there is one), then write **Cause** in the log entry — structural cause, or the admission "unknown" — before any new tweak. A third tweak without a written **Cause** is a closing red for `batch-end`.
- **Proof of red.** For each bug fix and each new business rule, write the test first and watch it fail for the expected reason, before the fix; quote command and failure message under **Red before** in the log entry. A test never seen red proves nothing.
- Log: at most one entry per session, timestamped by `lab now` (UTC, `YYYY-MM-DDTHH:MM:SSZ`), filled in during the session, ≤ 15 lines: **Proven** (command → result, commit), **Left**, **Decided not to do**, **Cause** when relevant. The long story, screenshots and measurements go to the evidence report `docs/lots/<lane>/preuves/lot-NN-<slug>.md`, linked from the entry; no figure is copied from one document to another.
- An evidence file outside the repository (screenshot, output, measurement) is filed with `lab proof <project> <batch> add [--step <name>] <files…>`, never with a script nor a hand-written manifest.
- A dated appointment made during the batch (follow-up, promised delivery, third-party deadline) is recorded with `lab due <project> add <due> <subject>`, never in the batch file nor the Handoff; `lab due <project>` lists them and settles the late ones.
- Make a conventional commit `type(scope): … (lot-NN)`; push the branch at the first commit as soon as a remote exists (backup: a push without a pull request starts no CI). No pull request before `batch-end`, which opens it as a draft. Exception, stacked batch (opened by `lab next` on top of a batch whose PR waits for its CI, `stacked_on` in `.lab/meta`): never push its branch and open no pull request — the watcher moves it onto the base after the batch below is merged, then pushes it itself; no force push, ever.
- `lab launch` merges the base into the lane before opening the session (`SYNC=merged`): run the targeted tests first. A conflict with the base is the first task — the fixing session names it; solve it with `git merge`, never with rebase nor force push, then `lab sync <project> <lane>` must answer `SYNC=up-to-date`. A `OVERLAP=` at start signals another lane on the same files: `lab status <project>` gives the order of passage.
- If a criterion is unfeasible or out of scope, note it under "Decided not to do" with the reason; do not hide it.
- Going live = `lab deploy <target>`, never a raw deployment (`wrangler deploy`, `gcloud run deploy`, `rsync` to a host…): the guard refuses it in a project that declares a target. `SERVED=` at start says what is served; before any release, `lab deploy <target> --dry-run` shows what it would erase (`LOST=`). A missing target is declared with `lab deploy --add [worker|rsync|cloudrun] <target>` (template with probe; `--include` for a private file outside the repository), never by editing the config by hand.

## Heavy context

Never use `/compact`. Update the log and `## Handoff`, then run yourself, from your session:

```text
lab next <project> <lane>
```

It checks everything that follows, then replaces your session with a fresh one in the same tab, with the same agent; finish your writes before running it (`--auto` is still accepted, same effect). A refusal kills nothing: it names the cause and the document to fix — fix it, then run it again. It refuses to replace another live session. Do not ask the user to step in.

## End

When every criterion of the Goal is covered, apply `batch-end`. Never close the batch by hand. After the last batch, batch-end hands over to acceptance: keep the lane for the user's trial and feedback.
