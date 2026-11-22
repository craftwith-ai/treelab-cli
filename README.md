# Treelab

Treelab installs the LAB method on a Mac: one project, isolated work lanes, batches delivered one by one by Claude Code or Codex, and guards that keep both the machine and the repository from breaking.

## The promise

    vague need on main
            │
            ▼
    lab new <project> <lane>      short qualification, overall goal, first batch
            │
            ▼
    lab next <project> <lane>     the agent runs the batch, checks it and prepares the delivery
            │
            └─ lab next: next batch after delivery, or the final trial together
                        │
                        └─ lab close <project> <lane> after approval and confirmation

The lane stays open for trials and fixes. Only an explicit closing removes it. The other commands (`lab status`, `lab doctor`, `lab merge`, `lab sweep`, `lab handoff`) are for checking and repairing.

## Install

    curl -fsSL https://treelab.sh/install | bash

The installer asks one question per screen. Its default choice starts a free 14-day trial: enter an email address, and the trial key appears in the terminal and arrives by email. No card is needed; there is one trial per email address and per Mac. No telemetry.

## Subscription

Treelab is sold as a subscription to updates, monthly or yearly, per seat; prices are on [treelab.sh](https://treelab.sh). Subscribe from the installer or with `lab subscribe`: payment happens in the browser and your trial key becomes a paid key, with nothing to reinstall. If the subscription stops, you keep the installed version and nothing breaks; only new versions (`lab update`) stop.

## First steps

    lab setup      install, after agreement in the terminal
    lab doctor     check the installation
    cd <repository>
    lab onboard    three screens, repository registered, agent opened in the main tab

`lab onboard` runs inside a git repository. It presents the words (project, lane, batch), the cycle and the guarantees, registers the repository without touching its files, then opens an agent that guides you to your first batch delivered as a pull request. Running it again creates nothing twice; without cmux, it prints the command to run (`NEXT_COMMAND`).

`lab help` gives the useful commands by moment (install, start, move forward, finish); `lab help <command>` details one command; `lab help glossary` gives each English word with its former French word; `lab --help` stays the technical reference. `treelab uninstall` undoes the installation.

From an earlier lab installation: `~/.lab/current/bin/lab setup --import <copy> --dry-run` shows the plan, the data to copy in figures, the remaining references (`LEFT=`) and the sessions to close; the same command without `--dry-run` installs in one go, never writing into the copy.

Codex settings, limits and backup: [Codex notifications](docs/codex-notifications.md).

## Licence

Treelab's source code is visible under the [Functional Source License, version 1.1, with Apache 2.0 as the future licence](LICENSE) (FSL-1.1-ALv2). In plain words:

- you may read the code, use it and change it, for yourself or inside your company;
- you may not sell it, or offer a product or service that competes with Treelab;
- each version becomes Apache 2.0 open source two years after it is published.

## Issues and pull requests

Issues are welcome: report a bug or ask a question in the Issues tab of the repository. Pull requests are not accepted: the repository is a mirror that receives one commit per published version. Details in [CONTRIBUTING.md](CONTRIBUTING.md); release notes in [CHANGELOG.md](CHANGELOG.md).

## Requirements

macOS, git, jq, cmux, and Claude Code or Codex.
