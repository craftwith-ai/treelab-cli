# {{PROJECT}}

<!-- Canonical file, read by Claude Code (through CLAUDE.md) and Codex. ≤ 80 lines.
     Content: commands, conventions, pitfalls. Nothing personal, no other project, no secret. -->

## Commands
- Install: `{{INSTALL}}`
- Develop: `scripts/dev.sh` (free port, prints the URL)
- Test: `{{TEST}}`
- Lint / typecheck: 
- CI: `.github/workflows/ci.yml` — fill in `FAST_CMD`, `TARGETED_CMD`, `FULL_CMD`, `E2E_CMD` at its top; the full suite runs once per lane (`full-suite` label), and at night.

## Architecture in three lines
- 

## Conventions
- Branches `feat|fix|chore/<slug>`, PR to `{{PR_BASE}}`, commits `type(scope): … (lot-NN)`.
- Docs: `docs/masterplan.md` (why), `docs/treeplans/<lane>.md` (order and intent), `docs/lots/<lane>/lot-NN-<slug>.md` (only state), `docs/lots/<lane>/CHANGELOG.md` (Unreleased).
- <!-- Interface : <folders> · screens : <widths> — line read by batch-plan and batch-end: a diff touching these folders requires a real check of the screens at these sizes; without an interface, remove the line. -->
- The final acceptance lives in the last batch file; `lab close` requires it to be currently valid plus an explicit confirmation. `next`, `sweep` and SessionStart remove nothing.

## Known pitfalls
- 

## Where to write what
Rule true in every session → here, one line · gotchas of a subsystem → `.claude/skills/<subsystem>/SKILL.md` · rule tied to files → `.claude/rules/*.md` with `paths:` · story or measurement → `docs/` · derivable from code → nowhere.
