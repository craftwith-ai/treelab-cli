---
name: project-init
description: Migrates a project to the LAB layout without writing in its main checkout, then checks its context and its installation. Invoke it once per project.
disable-model-invocation: true
---

# project-init — register a project

Initial decision: `--docs repo` versions the documents through a worktree; `--docs local` keeps them under the LAB register and stays the default. Ownership of the repository never changes delivery: the target is `staging` if it exists, otherwise the main branch.

## 1. Register

`lab init <project> [--docs repo]` from the main checkout detects the base, `staging`, the merge method, the dependencies and the tests. It only writes the LAB register, the local exclusions and the Codex trust. Read the configuration produced.

## 2. Build the frame

- Inventory the old plans and logs.
- With `docs=repo`, first open `lab new <project> layout --kind chore`, then work only in that lane. With `docs=local`, use `LAB_DOCS`.
- Keep the why in `docs/masterplan.md`, order and intent in `docs/treeplans/<lane>.md`, the batch files in `docs/lots/<lane>/` and `docs/lots/<lane>/CHANGELOG.md`. State lives in the batch file only, `lab plan` computes it. The old layout stays readable with no forced migration; archive without losing the old stories.
- For a shared repository, keep `AGENTS.md` canonical at 80 lines at most and `CLAUDE.md = @AGENTS.md` plus 20 lines specific to Claude at most.

## 3. Local files

Secrets, local servers and machine-specific settings stay excluded from Git and are listed in `projects/<project>/include`. Personal notes stay in `projects/<project>/notes.md`, in 20 lines at most.

## 4. Check

`lab doctor <project>` must show no red, then `lab doctor <project> --freeze`. The main checkout stays without any added or modified versioned file.
