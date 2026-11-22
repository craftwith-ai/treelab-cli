---
name: first-lane
description: Guides a new user's first lane, short and in plain words — GitHub ready first (a private repository only with their agreement), five questions at most, one single batch up to its pull request. Apply it when the start message of a lane opened by lab new --guided names it.
---

# first-lane — the first lane, short and guided

The person in front of you may never have used git, GitHub or an agent. They want one thing to work; they do not want to learn a method. This lane goes from their need to a first pull request, in one single batch, then their trial.

## How you speak

- Plain words, short sentences, one thing at a time. Each technical term is explained once, the first time you use it, in a few words:
  - repository: the project's folder with the history of every change;
  - branch: a separate copy of the work, so the main version stays intact;
  - pull request: a page on GitHub that shows every change, to read before accepting it;
  - test: a small program that checks the result works, now and after every later change.
- Never frighten: no raw error dump. When a command refuses, say the cause in one sentence and what you do about it.
- The step line, at each step: run `lab guide <project> <lane>` and show the user its step lines as they are (the four lines marked ✓ done, ● current, ○ next, then the "Next:" line). The four steps: 1 Questions about your need, 2 The plan, 3 The work, checked by tests, 4 Your review (pull request).

## 1. GitHub first

Before any question, run `lab guide <project> <lane>` and read `GITHUB=`. The work will be proposed on GitHub as a pull request: say so in one sentence, then:

- `ready`: say it, move on.
- `no-remote`: the project is not on GitHub yet. Propose to create a private repository, visible to them only — never public — and ask for their explicit agreement with the multiple-choice question tool (`AskUserQuestion` in Claude, a numbered question elsewhere). Only after a yes, from the project's main checkout, run the command of `GITHUB_FIX=`: `gh repo create <name> --private --source <root> --remote origin --push`. It sends the main branch as it is today and writes nothing on it. If that sending is refused over SSH (`Permission denied (publickey)`: gh uses SSH and this Mac has no SSH key for GitHub), the repository already exists — never create it a second time: point the project at its HTTPS address, `git remote set-url origin https://github.com/<owner>/<name>.git`, let git use the gh sign-in with `gh auth setup-git`, then `git push -u origin <main branch>`. If gh answers that the name already exists on their account, create nothing: ask them for another name, or whether that existing repository is theirs to use. Then `lab guide <project> <lane>` again: it must say `ready`. A no is respected: the batch can still be planned and coded, but no pull request can be opened; say so, and the work stays on its branch.
- `gh-logged-out`: gh, GitHub's command-line tool, is not signed in. Ask the user to sign in themselves: `! gh auth login` typed in this session (Claude Code), or `gh auth login` in another terminal; it opens their browser. Never type a password or a token for them. Then `lab guide` again.
- `gh-missing`: gh is not installed. Ask them to install it (`brew install gh`, then `gh auth login`), or for their agreement to run `brew install gh` yourself; then the sign-in as above.
- `other-host`: the project lives elsewhere (GitLab, Bitbucket, a folder of this Mac). Explain in one sentence that Treelab opens pull requests on GitHub only and that the work would stay ready on its branch, then stop: no questions, no plan, until the user decides. Resuming later is `lab next <project> <lane>`.
- `unknown`: gh did not answer in time (network). Run `lab guide` again a little later; if it lasts, say so and go on with the questions.

## 2. Five questions at most

- Ask one single round of five questions at most, with the multiple-choice question tool, each option in plain words with a recommendation. Start from the brief when the start message names one.
- No second round and no second grill-me, at any moment of the lane (the batch-plan § 0 round included): what remains open takes the simplest option, written as a decision in the batch file.

## 3. One single batch

- The roadmap holds one single batch, the last one: one batch line in the lane's treeplan. Detail its batch file with the batch-plan and use-goal skills: a Goal in one sentence the user understands, criteria `C1`, `C2`…, steps with their tests.
- Keep it small: what fits in one session and one pull request. A larger wish is noted for a next lane.
- Show the plan in plain words — what will change, how it will be checked — and ask for confirmation. Then run `lab next <project> <lane>` yourself.

## 4. A first test if there is none

If the project has no test (no test folder, no test command), the batch adds a first small test adapted to the project — a check that the page loads, a unit test of the new function — with the command that runs it. Explain in one sentence what it is for: it checks the result now, and every later change keeps it working.

## 5. A short AGENTS.md in the pull request

If the project has no `AGENTS.md`, the batch adds a short one: the commands (install, test, style check) and the line `Interface : <folders> · screens : <widths>`. It is committed on the batch's branch, so it arrives in the pull request with the rest: nothing is written on the main branch without the user's agreement. Explain in one sentence: a short note that tells every agent how to install, test and check this project.

## 6. The pull request and the trial

- The batch-end skill opens the pull request. Give its link and say how to read it: the "Files changed" tab shows every change.
- Step 4 is the acceptance: the user tries the result, the acceptance skill records their agreement, then `lab close <project> <lane>` delivers the work (the pull request is merged into the main branch) and removes the lane. In a project with a tower, the tower closes it on its own after that agreement.
- Nothing is merged without their agreement.

## What you never do

- No public repository, and no repository created without an explicit yes.
- No password or token typed for the user.
- Nothing written on the main branch, no force push, no folder or branch removed.
