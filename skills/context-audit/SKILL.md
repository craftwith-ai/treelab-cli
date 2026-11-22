---
name: context-audit
description: Big clean-up of a project's agent context — measures what loads (lab doctor), sorts it with the routing table (AGENTS.md / skill / rule with paths / docs / nowhere), sets the ratchet (lab doctor --freeze). Invoke it when a project's context swells or before migrating a project.
disable-model-invocation: true
---

# context-audit — measure, sort, lock

Touch no other project and name none anywhere.

## 1. Measure before proposing
`lab doctor <project>`: AGENTS.md / CLAUDE.md (lines, bytes), rules without `paths:`, project skills, MEMORY.md, SessionStart injection, hermeticity, baseline. Return a table: item, bytes, estimated tokens (bytes/4), share of the total.

Two false remedies (official docs): an `@import` is expanded at launch; a rule **without** `paths:` always loads. Three real ones: skill (only `name`+`description` load, ~120 tokens), rule with `paths:`, `CLAUDE.md` nested in a subfolder.

## 2. Sort with the routing table
| Content | Destination |
|---|---|
| Rule true in **every** session (access, git, security, protocol) | `AGENTS.md`, one line |
| Gotchas of **one subsystem** | a project skill (`.claude/skills/<subsystem>/`), with a description naming paths, commands, symptoms |
| Rule attached to **files** | `.claude/rules/*.md` with `paths:` |
| Session story, incident measurement | `docs/` |
| Derivable from the code | nowhere |

Read each line before removing it; every deleted line is declared with its reason. One skill per subsystem, never one per topic.

## 3. Scope
A global skill or agent (`~/.claude/skills`, `~/.claude/agents`) that talks about this project belongs to this project. Judge on what the `SKILL.md` declares, not on the folder name.

## 4. Lock
- `lab doctor <project> --freeze` sets the baseline **on today's measurement, with no margin**; any rise turns red. Raising the baseline is a dated and motivated gesture.
- Mandatory negative check: deliberately inflate a file, show the red, repair.
- Proof of no loss: keep a copy of the old `CLAUDE.md` in `docs/archive/` and check that each removed line has a destination that really loads, or a reason.
