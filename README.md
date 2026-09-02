# Claude Skills

Guardrails for Claude Code — best-practice skills, planning commands, and delivery gates.

[![npm version](https://img.shields.io/npm/v/@spardutti/claude-skills)](https://www.npmjs.com/package/@spardutti/claude-skills)
[![npm downloads](https://img.shields.io/npm/dm/@spardutti/claude-skills)](https://www.npmjs.com/package/@spardutti/claude-skills)
[![license](https://img.shields.io/npm/l/@spardutti/claude-skills)](./LICENSE)

Coding agents are good at writing code. They are much worse at holding to
engineering discipline — reading the codebase before changing it, keeping to
current idioms, proving a test would actually catch a break.

This installs both halves into your project: **current technical guidance**, and
**the enforcement that makes it stick**. Guidance your agent can skip is a
suggestion. Every skill here loads behind a hook that requires it to be applied,
and nothing reaches a PR without passing a gate that ran for real.

## Contents

- [Quick Start](#quick-start)
- [Why This Exists](#why-this-exists)
- [Skill Catalog](#skill-catalog)
- [Commands](#commands)
- [How It Works](#how-it-works)
- [Hooks & Internals](./HOOKS.md)
- [Repository Layout](#repository-layout)
- [Getting Help](#getting-help)
- [Contributing](#contributing)

## Quick Start

Run from any project directory:

```bash
npx @spardutti/claude-skills
```

```text
  Claude Skills Installer v2.25.0

  ── Frontend ──────────────────────────────
  ◉ react              ◯ tanstack-query
  ◯ tanstack-router
  ── Backend ───────────────────────────────
  ◉ fastapi            ◯ docker-best-practices
  ◯ drf-best-practices ◯ drizzle-orm
  ── Database ──────────────────────────────
  ◉ sql

  ↑↓ move · space select · enter confirm
```

The CLI will:

1. Fetch the latest skills, commands, and agents from GitHub
2. Let you pick skills to install → `.claude/skills/`
3. Let you pick commands to install → `.claude/commands/`
4. Auto-install any subagents the selected commands declare → `.claude/agents/`
5. Optionally set up the **hooks** — skill evaluation before edits, verification after (recommended)

## Why This Exists

**A model's knowledge is frozen and averaged.** Ask for React and it reaches for
`useEffect` and manual `useMemo`. Ask for TypeScript and it assumes 5.x. The code
compiles, passes review, and is two years out of date. Skills fix that: tight,
opinionated playbooks pinned to current practice for one tool each — React 19.2 and
the Compiler, TypeScript 7.0, TanStack Query v5, Drizzle, FastAPI, SQL. They track
the changelogs so you don't.

**But guidance nobody checks is a suggestion.** An agent under deadline pressure
skips the playbook, writes the test after the code, and reports a pass. So the same
install adds the part that does not negotiate:

- A gate that blocks the first edit until your skills have been applied to the file
  being written — not just read.
- A `Stop` hook that runs your typecheck and tests on the changed files every turn,
  and refuses to let the turn end red.
- A delivery gate that **changes your code on purpose and checks whether any test
  notices.** When none do, the PR does not open.

That last one is the difference. Your agent says the tests pass. This finds out.

## Skill Catalog

**16 skills**, grouped the same way the installer presents them.

> [!NOTE]
> Skills marked **📦 Bundle** ship a concise always-loaded entry point plus reference files Claude reads only when a task needs them — comprehensive coverage at a low context cost.

### Frontend

| Skill | What it covers |
|-------|----------------|
| `react` 📦 | React 19.2 — `use`, Actions, `ref` as prop, Rules of Hooks, React Compiler v1.0, component splitting, `useEffect` avoidance, performance, loading/empty states, Zustand, Tailwind v4 tokens; bundle covers forms (React Hook Form + Zod) and shadcn/ui (Base UI vs Radix, `cva`, `cn()`) |
| `tanstack-query` 📦 | TanStack Query v5 — queries, mutations (pessimistic & optimistic), `useInfiniteQuery`/`useSuspenseQuery`, query-key factories, v4→v5 migration |
| `tanstack-router` | File-based routing, type-safe navigation, loaders & caching, search params, `beforeLoad` auth guards, pending UI that prevents frozen-feeling navigation |

### Backend

| Skill | What it covers |
|-------|----------------|
| `fastapi` 📦 | FastAPI — async correctness, `Annotated` dependency injection, `lifespan`, response models, testing with dependency overrides; bundle covers Pydantic, Alembic, Celery, and list endpoints (pagination/filtering/search/sorting) |
| `express` 📦 | Express 5 — automatic async error forwarding, the four-argument error handler, named wildcards, `req.query` as a getter, validation at the boundary, thin routes, the helmet/CORS/rate-limit baseline; bundle covers tRPC v11 on Express |
| `drf-best-practices` | Django REST Framework — thin serializers, service layer, queryset optimization, object-level permissions |
| `drizzle-orm` | Drizzle ORM — schema design, identity columns, relations, migration safety, type inference |
| `docker-best-practices` | Multi-stage builds, layer caching, security hardening, Compose Watch, health checks |

### Database

| Skill | What it covers |
|-------|----------------|
| `sql` 📦 | Schema design, data types, indexing & `EXPLAIN`, joins & subqueries, ORM patterns (N+1, transactions, locking), safe migrations |

### Foundations

Cross-cutting craft — applies to any stack, any language.

| Skill | What it covers |
|-------|----------------|
| `code-structure` 📦 | Single Responsibility (when to split) + Avoid Hasty Abstractions (when *not* to extract) — hard size limits, separation of concerns, the Rule of Three |
| `debugging` | Root cause before patching — reproduce, trace the failure backward to its origin, one hypothesis at a time, the 3-attempts-then-question-the-design rule |
| `git-merge-conflicts` | Resolve a merge/rebase conflict by intent, not by side — `zdiff3` to see the merge base, the inverted meaning of `ours`/`theirs` during a rebase, the semantic and tree conflicts git never marks, lockfiles and migrations you regenerate instead of merging |
| `research` | Open the source, don't recall it — route to the tool that owns the answer, primary sources only, pin the version you're actually on, run the validator instead of guessing, and mark every claim VERIFIED / INFERRED / UNVERIFIED |
| `typescript-best-practices` | TypeScript 7.x — type design, generics, type guards, `satisfies`, `using`, error handling, `tsconfig` |
| `testing-best-practices` 📦 | Arrange-Act-Assert, factory-based test data, isolation, mocking boundaries, a pyramid-balanced suite; bundle covers mutation testing — Stryker and mutmut setup, `ignoreStatic`, diff-scoped runs, the traps, and working score thresholds |
| `security-practices` | OWASP Top 10 prevention, input validation, auth, SQL injection, XSS, CSRF, secure defaults |

## Commands

Portable slash commands installed to `.claude/commands/`. Some orchestrate parallel subagents — those are pulled in automatically.

| Command | What it does |
|---------|--------------|
| `/ship` | Unified delivery pipeline — commit → gate → PR → merge → release. The gate is the one enforcement moment: it checks the diff's file lengths, audits it against the skills installed in the project, and mutation-tests the changed lines to prove the tests would catch a break — **fixing what it finds** rather than handing you a list. It runs before the **PR**, not before every commit: its scope is the whole branch, so gating each commit re-mutated every file the branch had ever touched. `--force` skips it. No argument steps through interactively; `/ship pr` runs through PR creation; `/ship release` runs the full pipeline |
| `/discover` | Find the right problem before deciding what to build — diverges first: generates competing framings through blind subagents under forced constraints, stress-tests the winner with a blind critic, and refuses to converge until every open question is answered or deferred, then drafts scope, non-goals, edge cases and success criteria for you to correct. Run before `/plan-feature` |
| `/plan-feature` | Integration-first feature planning — 3 parallel subagents scan for reusable code, patterns, and touch points before producing a short plan |
| `/refactor` | Detect size / complexity / duplication / coupling issues via 4 parallel subagents, then refactor |
| `/deep-review` | Multi-agent deep code review — 5 parallel subagents catch guard bypasses, lost async state, wrong-table queries, dead references, protocol violations |
| `/test-review` | Write-then-verify test review — scopes to the diff, runs red-green + mutation gates, then an isolated read-only subagent proves each test would catch a regression instead of rubber-stamping it |
| `/handoff` | Write a handoff doc so a fresh session picks the work up — captures what auto-compaction loses: decisions made and rejected, dead ends already ruled out, why the tree is dirty, and the one next step |
| `/lockdown` | Per-repo supply-chain hardening — detects the package managers, Dockerfiles, and CI in use, then guides you through and applies install-time, deploy, and pipeline hardening for npm/pnpm, pip/uv, Docker, and GitHub Actions |

## How It Works

The CLI installs three kinds of artifact into your project's `.claude/` directory:

- **Skills** → `.claude/skills/` — playbooks Claude loads while coding.
- **Commands** → `.claude/commands/` — slash commands you invoke directly.
- **Subagents** → `.claude/agents/` — declared by commands via `requires-agents`, installed for you.

It then offers to install the hooks. Two guard the **front**: nothing is written
until your skills have been evaluated *and* applied to the file being written.
Two guard the **back**: a `Stop` hook runs your typecheck and tests on the changed
files every turn, and a `PreToolUse` gate refuses to open or merge a PR without a
receipt proving the delivery gate passed on exactly that code.

Full details — every hook, every marker, every config key, and what to do when one
blocks something it shouldn't — are in **[HOOKS.md](./HOOKS.md)**.

### Tracking & Updates

Every install writes a manifest at `.claude/.claude-skills.json` recording what the CLI installed and the catalog version. On the next run it uses the manifest to:

- **Pre-check what you already have** in the picker — re-running doubles as an update screen; toggle to add or remove.
- **Detect stale items** — skills/commands renamed or removed from the catalog upstream are flagged, and the CLI offers to delete them.
- **Never touch what it didn't install** — the manifest is the CLI's own record; hand-written skills are invisible to it and always safe.

```bash
npx @spardutti/claude-skills --sync
```

`--sync` refreshes every tracked item to the latest catalog and prunes stale ones in one shot — no menu. For a project that predates the manifest, the first normal run offers a one-time cleanup of `.claude/` content no longer in the catalog.

`--local[=path]` reads the catalog from a working copy instead of GitHub, so an unreleased change can be installed and tried without publishing it first:

```bash
node ~/projects/claude-skills/cli/bin/cli.mjs --local
```

## Repository Layout

```text
skills/        Skill playbooks — some are bundles (SKILL.md + on-demand reference files)
commands/      Slash commands installed to .claude/commands/
agents/        Subagent definitions — commands declare which they need via requires-agents
scripts/       validate-skills.mjs — checks skill length caps and reference integrity
               gauntlet.sh — the Stop-hook verification gates, embedded by the CLI
               ship-gate.sh — /ship's file-length and mutation checks, behind an exit code
               ship-gate-hook.sh — refuses gh pr create/merge without a ship-gate receipt
               version-check.sh — SessionStart nudge when a newer catalog is published
               gauntlet-selftest.sh — behavioural tests for the hooks (runs on pre-push)
               gauntlet-survey.sh — what the hook would do in every repo under a directory
               preflight.sh — everything that must pass before a release
               check-freshness.mjs — compares each skill's `tracks:` versions to the registries
cli/           The npm installer (npx @spardutti/claude-skills); version in cli/package.json
.husky/        pre-push hook running the skill validator
package.json   Private dev-tooling package (claude-skills-dev) — not the published one
```

## Getting Help

- **Something broken, or a skill teaching something stale?** [Open an issue](https://github.com/Spardutti/claude-skills/issues).
- **A hook not firing, or a gate blocking something it shouldn't?** [HOOKS.md](./HOOKS.md) covers the markers, the matchers, and the escape hatches — including the auto-mode permission rule the gates need.
- **Want a skill for a tool that isn't here?** Issues are the place; see [Contributing](#contributing) for what a good one looks like.

## Contributing

Skills live in `skills/<name>/SKILL.md`. Authoring conventions are in [CLAUDE.md](./CLAUDE.md) — the short version:

- BAD/GOOD code pairs are the primary teaching tool; end every skill with a **Rules** section.
- `SKILL.md` ≤ 350 lines; reference files ≤ 500 and need a `## Contents` TOC past 100 lines.
- References are one level deep — `SKILL.md` links them, they don't link each other.
- `npm run validate-skills` enforces this; it also runs on `pre-push`.
- Before any release, run `bash scripts/preflight.sh` — validator, self-tests, a check that the
  hook scripts embedded in the CLI still match `scripts/`, detection against every repo under
  `~/projects`, and that the version is ahead of the registry. Do not publish while it is red.
- Changing `scripts/gauntlet.sh`? Run `bash scripts/gauntlet-selftest.sh` (also on `pre-push`),
  and run `bash scripts/gauntlet-survey.sh ~/projects` before releasing. Detection is where
  this hook keeps breaking, because real repos are shaped in ways invented test repos aren't —
  the survey is a dry run that reports what each of your repos would get without executing
  anything. Read the rows that say `nothing`.

To get the validator on **every turn** instead of only on push, drop this into
this repo's `.claude/gauntlet.conf`. It has to be the project file, not
`~/.claude/gauntlet.conf`: these settings are only right for a skills repo:

```bash
GAUNTLET_CODE_EXT='md|mjs|js|json|sh'   # markdown IS the product here
GAUNTLET_TYPECHECK=''
GAUNTLET_TEST='node scripts/validate-skills.mjs'
```

Without the `CODE_EXT` line the hook treats a skill edit as a docs-only change and skips.

## License

MIT
