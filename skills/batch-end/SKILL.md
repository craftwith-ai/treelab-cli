---
name: batch-end
description: Closes the batch only after green evidence, an independent review, the real check of the screens, the documents and the pull request. Delivers intermediate batches; hands the last one over to acceptance. Ends by running lab next itself, without having anything typed.
---

# batch-end — prove, deliver, explain

Each step leaves understandable evidence in the log. A red check gets fixed; it is never bypassed.

## 1. Prove the Goal

- Read each success criterion again and attach evidence to it; quote each `Cn` with its evidence in the log or in the evidence report.
- Agent batch-verifier: ask it for one line per criterion, named by its identifier (`C1 — PASS | FAIL | TO BE CHECKED BY THE PARENT`).
- Run the code style check, the type check and the tests. Quote each command, its exit code and the result. When the project's CI workflow cites the `full-suite` label, run only the targeted tests — the selection of `scripts/ci-select.sh files <base> HEAD` when the project has it, otherwise the tests of the changed files — and never the whole suite locally: it runs once per lane, in CI, before acceptance (§ 5), and at night. Otherwise run the whole suite: when the project has `scripts/cloud-suite.sh`, it is `lab cloud <project> suite`, run from the lane once the code is frozen: `SUITE=green` (rc 0) or `red` (rc 1, `RED=` names each test still red alone) is the answer; `SUITE=unavailable` (rc 3, `REASON=`) means the suite runs on the Mac, detached.
- Run `lab batch processes` from the lane folder: stop each listed process (`kill <pid>`), or write in the log why it must keep running. It blocks nothing; a session left in a removed folder or an orphan is named by `lab doctor` and stopped by `lab top`.
- Missing evidence keeps the batch in progress. Exception, a criterion whose measure can only be taken at a later date (traffic a week after release, a third party's answer): decide it alone, without asking, with `lab batch wait <Cn> <date|+Nd> "<reason>"` from the lane folder, just before delivery; every other criterion stays proven now. Say it in the final report (criterion, date, reason). The batch is delivered as usual and the lane goes on; `lab next` reopens it for that criterion alone at its date.
- Evidence outside the repository: `lab proof <project> <batch> verify` must return rc 0 before closing; the evidence report quotes `PROOF_MANIFEST_SHA256`, never an absolute path.
- A third tweak of the same symptom (same message, same counter or same metric) without a **Cause** written in the batch file is a closing red: write the cause, or "unknown", before going on.

## 2. Do the single independent review

- Claude: the review command at medium effort or the batch-reviewer agent, with the batch file and the pull request target.
- Codex: codex review or the batch-reviewer agent.
- Ask the reviewer to also report: weakened test (assertion removed, skip added, expectation loosened), scope overrun (code the Goal does not ask for) and over-engineering (abstraction, option or generality with no use in the batch).
- Do this review only once. Fix each real defect with a test that fails without the fix. Record a mere style remark under "Decided not to do", with its reason. Then run the full checks again, without asking for a second review.

## 3. Check the interface, if the batch contains one

1. Read the line `Interface : <folders> · screens : <widths>` of the project's `AGENTS.md`; missing or still in a comment, there is no declared interface: check the screens listed in the batch file (point 2), with no shortcut. If `git diff --stat <base>..HEAD -- <interface folders>` is empty and earlier screen evidence exists (`lab proof` manifest of a previous batch, old folder `state/<project>/lot-NN/`, or PASS in the lane's log), write one line "interface unchanged since <sha>, screen evidence kept" in the log, and nothing else; without earlier evidence, or if the batch file ties a listed screen to a change outside those folders, apply point 2.
2. Otherwise, really start the application, in a throwaway environment if needed. Claude uses its browser; Codex uses the built-in browser. Check each screen listed in the batch file, at the sizes declared by the project; `better` is available for this review (accessibility, layout, writing, typography, colours, polish) and stays a choice, not a step; contrast is measured again only if the styles changed.
3. File the screenshots with `lab proof <project> <batch> add --step ecrans <screenshots>` and write an explained PASS or FAIL per screen. Fix every FAIL.

## 4. Write each fact once

1. Source: the evidence report `docs/lots/<lane>/preuves/lot-NN-<slug>.md`, as soon as the story outgrows the log entry or there are files (screenshots, measurements, outputs); without a report, the log entry is the source. Never a flat `lot-…md` name in `lots/<lane>/`: it would be read as a batch file.
2. Log: one entry per session, ≤ 15 lines — **Proven**, **Left**, **Decided not to do** — pointing to the report.
3. `docs/lots/<lane>/CHANGELOG.md`, under Unreleased: one line — user result, pull request number, agent — the only place where the request's number is written. The root CHANGELOG gathers the notes only at a release; a closing does not modify it. In the old layout, keep the existing log until the lane is migrated.
4. Pull request body: five lines at most, and the link to the batch file or the report.
5. Treeplan: nothing, unless order or intent changes.

Copying a figure from one document to another is forbidden: the other documents point to the source. The Handoff (handoff skill: four blocks, `**Next batch** : <slug> — <title>` from `docs/treeplans/<lane>.md`, or none) is the only document that must be complete. With `docs=local`, never run `git commit` in the batch files' repository: `lab merge`, `lab next` and `lab close` record them, `DOCS_PENDING` names what is left. Keep the batch file in progress until the report is green; no state to mark in the treeplan nor in the masterplan, no write in another lane's documents.

## 5. Prepare the delivery, then tell the last batch apart

1. Add only the batch's files, conventional commit, then push the branch if a remote exists — except a stacked batch (`stacked_on` in `.lab/meta`), never pushed by you.
2. Run lab doctor <project> --root <worktree>. Fix each red; suggest no workaround. `tests.weakened` red: the batch removes more assertions than it adds, or adds a skip; restore the test, or, if the removal is intended, write at the start of a line of the batch file `Tests removed : <reason>` (warning quoted in the report). `criteria.evidence` red: a `Cn` of the closed batch file is quoted neither in the log nor in the evidence report; quote it with its evidence, or reopen the batch.
3. Create the pull request as a draft towards the context's target — staging if it exists, otherwise main — with gh pr create --draft --base <target>; body as in § 4. A draft only runs the quick checks. Stacked batch: no pull request; write its body (as in § 4) in `.lab/pr-body.md` of the worktree, untracked — the watcher will open the request with it.
4. Add its number to the CHANGELOG line, set the batch to closed in its batch file only (`clos` under `**État**`, `closed` under `**State**`) — or leave it `waiting` (`en attente`) while a line of its `## Waiting` section stays unmeasured: `lab batch wait` set it, a closed batch file with an open waiting line is a doctor red — then commit and push.
5. Last gesture on the request, after green local tests and the last commit: gh pr ready <number>. The CI of a ready request then runs once, on the final state — only the quick checks and the targeted tests when the workflow cites the `full-suite` label; `lab merge` and `lab close` mark ready a request left as a draft, and say so (`PR_READY`). Posting `full-suite` on an intermediate batch is an exception, its reason written in the batch file (for instance, the batch changes the CI).
6. Read `LAST_BATCH` again in `lab status <project>`. If the batch is intermediate, run lab merge <project> <lane> (stacked batch: add `--title "<type>(<scope>): … (lot-NN)"`). The command returns at once: CI already green or absent → immediate merge; CI running → watcher armed (`ACTION=armed`), which will merge at the exact revision after the green; stacked batch → queued (`ACTION=queued`). Do not wait: go on. The watcher's outcome is read in `lab status` and at session start (`WATCHER=`); red, conflict or insufficient rights: keep the batch undelivered and explain the blocking precisely.
   In a project with a tower, run by you it answers `MERGE=queued`: the batch is delivered to the tower, which merges it at its round at that revision once green; go on (`lab next` stacks the next batch on it). A commit after it changes the revision: run `lab merge` again. `gh pr merge` and a push to `main`/`staging` are refused to you; never ask the user for a git command.
   `lab promote` (staging → main) is never run by this skill nor by `lab next`: it belongs to the user.
   A merge puts nothing online: if `SERVED=` serves this lane, `lab merge` marks the register `merged`; the target only changes with `lab deploy <target>`, and only if the Goal asks for it. A doctor `WARN` `targets.*` or `conflicts.repeated` is quoted in the report with its cause; it does not block.
7. If it is the last batch, keep its request open. When the CI workflow cites the `full-suite` label, post it (`gh pr edit <number> --add-label full-suite`) and wait for the full suite on the request's head (`gh pr checks <number> --watch`); a red is fixed before acceptance. Then hand over to the acceptance skill with `lab next`: in the acceptance session, the user's own words (`recette validée, couloir à fermer`) or a click on a button are enough to accept and close — never a command for them to type. The explicit closing will deliver after approval of the current result. A technically closed batch allows neither the final merge without acceptance nor the removal of the lane; run no cleanup. If the last-batch indication is unknown, clarify the treeplan and the Handoff before delivering.

If there is no remote, record that fact and keep the local branch ready to be integrated; invent neither push nor pull request.

## 6. Final report

Give: goal, done, current state, left (with each waiting criterion, its date and reason), then the complete list of batches. A session opened to reopen a waiting batch measures that criterion alone: `lab batch wait --done <Cn>` (or one postponement), then this skill as for an intermediate batch — never an acceptance. Then run yourself, from your session, the single next command, with no prompt to copy nor options to guess:

    lab next <project> <lane>

State in one sentence that it works out what follows on its own (execution, next batch after delivery or lane acceptance), then replaces this session in its tab with the next one, with the same agent: the user has nothing to type. It neither merges nor deletes anything. A refusal kills nothing and names the cause and the document: fix it, then run it again. Outside cmux, it stays the action to type after the session is closed.
