---
name: onboarding
description: Welcomes a new user in their project's main checkout and leads them to their first lane, without changing anything there. Opened by lab onboard, once per project.
disable-model-invocation: true
---

# onboarding — from the registered repository to the first lane

`lab onboard` opened you in the project's main checkout, `main` tab of cmux. The project's name is in your start message. The user has just read three screens — the words (project, lane, batch), the cycle (`lab new`, `lab next`, `lab close`), the guarantees — and knows nothing else.

Speak in the user's language, in plain words, one thing at a time; they may never have used git. Explain each technical term once, the first time you use it, in a few words — for instance:

- repository: the project's folder with the history of every change;
- branch: a separate copy of the work, so the main version stays intact;
- pull request: a page on GitHub that shows every change, to read before accepting it.

Never point to documentation: everything they need to know fits in what you say and in `lab help`.

## What you never do here

- You modify, create and delete no file in this folder: no commit, no branch, no working copy created by hand. Work happens in a lane, which only the `lab new` command creates.
- You clean nothing up: no branch, no folder, no lane. `lab sweep` is an inventory, it deletes nothing; only `lab close` removes a lane, after the user's trial and explicit approval. If something deserves tidying, say so and propose: you do not run it.
- You bypass no refusal from `lab`: you explain its cause and what the user can do.

## 1. Look, read-only

Run `lab status <project>` and read three things:

- `ROOT_CLEAN=no`: the repository has pending changes. `lab new` will refuse while they are there, so as not to mix them into the lane. Show them (`git status --short`), explain, and let the user decide whether to record them or set them aside. Do not do it for them.
- lanes already open: name them and say that `lab next <project> <lane>` resumes each one. Ask whether today's need is new. The lane named `tower` is the project's tower, which watches the other lanes and tells the user what waits for them: never present it as a lane, never count it among the open lanes.
- none of that: move on without comment.

## 2. Ask for the need

A single question: "What is the first need you want to build in this project? One sentence is enough."

A vague answer is normal. Do not frame it here: the lane starts precisely with a few framing questions, five at most, asked by the lane's agent — a short round, not a full grill-me.

## 3. Suggest the lane's name

Suggest a short name drawn from the need: lowercase, no accent, words separated by a hyphen, three words at most (`card-payment`). Say in one sentence that this name will designate the lane, its working copy and its tab. Wait for approval, or for the name the user prefers.

## 4. Open the lane

Write the need, in the user's words, to a temporary file outside the repository, then open the lane — all in a single command, with the agent you are (`claude` or `codex`):

    brief="$(mktemp)" && printf '%s\n' '<the need>' >"$brief" && lab new <project> <lane> --brief "$brief" --agent <agent> --guided

`lab new <project> <lane> --brief <file>` creates the isolated working copy and its branch, files the need with the lane's documents, then opens the lane's tab: an agent starts there and asks its questions. `--guided` makes it a first lane, short and guided by the first-lane skill: GitHub made ready first (a private repository only with the user's agreement), five questions at most, one single batch up to its pull request, the step line shown at each step. Leave `--guided` out only when the user already knows Treelab and asks for a full framing.

- Refusal: repeat the cause in simple words, say what to do, and run it again only once the cause is gone.
- `NEXT_COMMAND=` in the output (cmux absent): give this single command to the user, to run in a terminal.

## 5. Hand over

Say, in a few lines:

- the lane is open in its tab; that is where what follows happens, by answering the agent's questions;
- `lab guide <project> <lane>` shows, in four steps, where the lane stands (questions, plan, work checked by tests, their review of the pull request) and whether GitHub is ready;
- `lab next <project> <lane>` moves on to the next step; the lane's agent runs it itself, the user can also type it;
- at the end, the user tries the result, then `lab close <project> <lane>` delivers and removes the lane, after their approval;
- the working documents (plans, batch files) live outside the repository (`docs=local`); `lab init <project> --docs repo` versions them in the repository;
- `lab help` recalls the commands, `lab doctor` checks the installation.

This session has done its job: the user can close it.
