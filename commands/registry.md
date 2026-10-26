---
name: registry
description: "Record the project's reusable systems — aiming methods, a state machine, an effect pipeline — as small <name>.registry.yaml files next to their code, so /plan-feature reads every one before it plans and must say reuse or skip for each. The user names the system, you draft the entry, and the user approves it. Nothing reads the registry outside planning"
category: Workflow
allowed-tools: Bash(node .claude/hooks/registry.mjs*), Bash(node scripts/registry.mjs*), Read, Grep, Glob, Write, Edit
argument-hint: "<a file, a folder or a word, e.g. sim/aim.gd or aiming>"
---

# Registry — The Systems a Plan Must Not Rebuild

A project has a few systems that new code should extend, never copy: the aiming
methods of a game, a job queue, a form builder. Each one gets a `<name>.registry.yaml`
beside its code, so one folder can hold several. `/plan-feature` reads all of them before it plans, so a brief that
says "fires at the nearby enemy" still finds the aiming system, whatever words it uses.

This is not a map of the repo. A project holds 2 to 50 entries, and the user
decides which. Only `/plan-feature` reads them; no hook checks them while you edit.

`REG` below is `.claude/hooks/registry.mjs`, or `scripts/registry.mjs` in the
claude-skills repo itself.

## Step 0 — No argument: ask

Run `node REG` to print the entries that exist, then ask the user which system to record.
Never search the repo for candidates; the user decides what is a system.

## Step 1 — With an argument: read the system

Find the file or folder from the path or the word. Read the interface or base type, the
place new kinds are registered, and one complete example. Never draft from file
names alone.

## Step 2 — Write the entry

```yaml
# src/combat/aiming/aiming.registry.yaml
name: aiming-methods
summary: how skills and towers pick a target
triggers: [aim, aiming, target, nearest, random, fire]
location: src/combat/aiming/
extend_by: implement AimStrategy, register in AimRegistry
example: NearestEnemyAim.ts
never: write targeting logic inside a skill
```

- `name` — unique, lowercase, with dashes. Plans cite it.
- `summary` — what the system is *for*, in the words a feature brief would use.
  The plan matches briefs to entries by this line.
- `triggers` — words code of this kind uses. They catch a plan that skips the
  entry while its stubs talk about targets.
- `extend_by` — the steps, naming the real symbols (`AimStrategy`, or `` `Weapon` ``
  in backticks for a one-word name). A method goes with its owner, `` `Aim.first` ``, never
  a bare `` `first` ``: a plain word matches code that never touches the system.
- `location` — the folder, or the one file when the system shares its folder (`sim/aim.gd`).
- `example` — a file in `location` to copy from. Optional.
- `never` — the mistake this entry exists to stop. Optional.

Show the draft and wait for a yes before writing the file. Nothing is written
without one.

## Step 3 — Prove it

```bash
node REG --stale
```

It must print nothing about the new entry. A line means a symbol, the folder or the
example is not where the entry says. Fix the entry, never the code.

## BAD / GOOD

```yaml
# BAD: a brief about "the nearby enemy" will not match, and no symbol can be checked
summary: AimStrategy implementations
extend_by: add a new class in the folder
# GOOD
summary: how skills and towers pick a target
extend_by: implement AimStrategy, register in AimRegistry
```

## Rules

- Never write an entry the user has not approved.
- Never add an entry the user did not ask for, and never hunt the repo for candidates.
- Always name real symbols in `extend_by`, and run `--stale` before reporting.
- Always write `summary` in the words a feature request would use, not in class names.
- Never put entries in `.claude/` or CLAUDE.md — the file lives next to the code it describes.
