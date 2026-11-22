---
name: handoff
description: Writes a self-contained Handoff in the current batch and has lab handoff compute the next command. Apply it at the end of a batch or before an automatic resumption.
---

# handoff — make what follows independent of memory

1. `lab handoff --template` shows the structure; `lab batch current` gives the batch file.
2. Fill in `## Handoff` in this batch file: four short blocks, in this order, ≤ 15 lines in total.
   - `**Verified actual state** (<timestamp from lab now, YYYY-MM-DDTHH:MM:SSZ>):` commands, exit codes, figures and revisions measured in this session, never copied from another document;
   - `**Never do**:` dated and motivated decisions, established facts not to measure again;
   - `**Next batch** : <slug> — <title>` from `docs/treeplans/<lane>.md`, or `none` if the technical work is done and must go to acceptance (in a permanent lane, `PERMANENT=yes` in `lab status`, `none` opens a free session that waits for the request, never an acceptance; a criterion left waiting with `lab batch wait` changes nothing here: `lab next` reopens that batch at its date by itself) — at the start of a line, outside any bullet: `lab handoff` reads it there and nowhere else;
   - `**Links**:` evidence report `preuves/lot-NN-<slug>.md`, treeplan, CHANGELOG, code and test files to open first.
   Everything else is optional: the Handoff is the only document that must be complete; it points, it does not copy.
3. Run `lab handoff`. It rewrites in canonical form (`**State** : …`) a State line that is readable but written differently, checks the State, the Handoff and the `**Next batch**` line, records the lane's batch files (`DOCS_COMMIT`) and prints the single next command, `NEXT_COMMAND` (`lab next <project> <lane>`): the same from the lane's tab and from your still-live session, which it then replaces in its tab, with the same agent. It copies no prompt: the command reads the batch file again and works out what follows.
4. Exit code ≠ 0: the message is meant for you — it names the batch file, the line, the value read and the expected form. Fix the batch file yourself, then run `lab handoff` again, without asking the user anything; then run `NEXT_COMMAND` yourself.

Once the acceptance is approved, do not modify any other section of the batch file: it would invalidate the approval. The record stays in `## Lane acceptance`.

Never quote another project, a secret or an unproven assumption.
