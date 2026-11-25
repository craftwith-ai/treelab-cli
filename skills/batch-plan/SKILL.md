---
name: batch-plan
description: Quickly qualifies a need, builds the lane roadmap and plans its next batch with a measurable Goal. Apply it in the first session opened by lab new, then at the start of each new batch.
---

# batch-plan — turn the need into a roadmap

Prerequisite: the start context shows a feature worktree and its current batch. Otherwise, explain the problem and only suggest `lab new <project> <lane>`; plan nothing in the main checkout.

## First batch of the lane

1. Read the context, the lane brief if one is named (`docs/lots/<lane>/brief-<date>.md`, filed by `lab new --brief`), the neighbouring flat batch files that are named (`FLAT_BATCHES=`), `docs/masterplan.md`, `docs/treeplans/<lane>.md`, the current batch and the code strictly needed, so as not to ask questions whose answer already exists.
2. Apply `grill-me` before any code: detailed questions without jargon (what the choice changes, each option in plain words, every technical term explained in its context); a first round of ten questions at most; one single extra round of five questions at most if an important decision is still open. Then summarise your understanding and get the user's confirmation. Guided lane (`guide=first` in `.lab/meta`, opened by `lab new --guided`): the first-lane skill replaces this round — five questions at most, no grill-me, one single batch.
3. With `use-goal`, check the overall goal and its evidence in the masterplan; complete them only during the initial framing of the project. An additional lane reads them without rewriting them.
4. Split the whole request into ordered batches, each one small enough to fit in a session without compaction. Write the order, the intent and the exit criterion of each batch in `docs/treeplans/<lane>.md`, with its links to `docs/lots/<lane>/`. No progress symbol: state lives in the batch file only and `lab plan` computes the view. Respect the batches already seeded and write in no other lane.

## Each batch

0. Start of batch, before any write: switch to plan mode when the tool offers it, then apply `grill-me` to the decisions of this batch that are still open — detailed questions without jargon, asked with the multiple-choice question tool (`AskUserQuestion` in Claude), as numbered text elsewhere (Codex). It is the only moment of the batch where the user is expected; everything else runs without them. A guided lane (`guide=first` in `.lab/meta`) asks no grill-me here, no second round: the first-lane skill already asked its questions, and what remains open takes the simplest option, written as a decision.
   Execution line, never a question: under the State line, write `**Execution** : cloud` by default, or `**Execution** : mac — <need>: <detail>` when the batch needs the Mac, the need taken from the closed list `secret` (an API key, `.env`, a production secret), `deploy` (`lab deploy`), `mac-tool` (chip acceleration, Mac app, keychain, Chrome extension), `human` (a human gesture during the batch), `resource` (a local resource declared in `resources=`, `lab lock`), `live` (an urgent or very interactive batch the user follows live, deduced from this grill-me). `lab next` reads it, keeps the Mac on `lab deploy` or `lab lock` in the Steps even under `cloud`, and announces its choice; `cloud=no` (`lab cloud <project> no`) remains the switch that keeps every batch on the Mac.
   Before writing that line, read the needs remembered for the project — `cloud-needs=` in the startup context, `NEED=` lines of `lab cloud <project>`: each one is a need a Cloud session ran into (`blocked: need <need>: <detail>`). A batch that will meet the same need gets `**Execution** : mac — <need>: <detail>`; one that will not gets `**Execution** : cloud`. A batch file left without a line goes to the Mac while a need is remembered; `lab cloud <project> needs reset` forgets them, never on your own initiative.
   Blind spots: before freezing the plan, name what could make it wrong (edge case, real data, another lane, environment) and file each one as a criterion, a risk or out of scope.
1. Read the Handoff of the last closed batch, `docs/lots/<lane>/CHANGELOG.md`, then measure the code concerned.
2. Apply `use-goal` to set a single result for the batch and its observable success criteria. Do not confuse activity ("modify the form") and result ("a person can send the form without error").
3. Fill in the batch file: goal, scope, out of scope, measurable criteria numbered `C1`, `C2`…, steps with test, tests to write, screens to check and risks. A batch that adds a test command also declares it in `.github/workflows/ci.yml` (`FAST_CMD`, `TARGETED_CMD`, `FULL_CMD`, `E2E_CMD`). If evidence files are expected (screenshots, measurements, outputs), plan the report `docs/lots/<lane>/preuves/lot-NN-<slug>.md` right now.
4. Read the line `Interface : <folders> · screens : <widths>` of the project's `AGENTS.md`; missing or still in a comment, fill it in first if the project has an interface. If the batch will change one of those folders, `better` is available for planning; write in "Screens / paths to check" the screens concerned and the sizes from that line, never a fixed pair. Otherwise, write "No screen".
5. Check `LAST_BATCH` in `lab status <project> <lane>` after completing the treeplan (intent written: a new lane no longer shows `unknown`). If this batch is the last one planned, announce that a check together will follow; prepare the lane's acceptance paths. A permanent lane (`PERMANENT=yes`) always shows `LAST_BATCH=no`: no acceptance follows, each batch is delivered by its own PR. If the batch needs a shared resource (simulator, local database, port) or produces generated files, check their declaration (`resources=`, `generated=`, `regen=` in the project config) and plan `lab lock`.
6. Leave the batch file planned, in the language of its State field (`planifié` under `**État**`, `planned` under `**State**`); no index to mark. Do not code in this planning session.

## Final report

Explain the confirmed goal, the complete roadmap, the first batch ready and what is left. Show all batches. Then run yourself, from your session — even if it does not run in the lane's tab:

```text
lab next <project> <lane>
```

No prompt to copy nor command to have typed: `lab next` records the batch files, builds the Goal and opens the execution session (from the lane's session, it replaces it; from elsewhere, it opens the lane's tab). A refusal names the cause and the document: fix it, then run it again. Only if `lab next` refuses for a reason you cannot fix, or outside cmux, give it to be typed.
