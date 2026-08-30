# Claude Skills

> **Make Claude Code write like a senior engineer who actually keeps up.**

[![npm version](https://img.shields.io/npm/v/@spardutti/claude-skills)](https://www.npmjs.com/package/@spardutti/claude-skills)
[![npm downloads](https://img.shields.io/npm/dm/@spardutti/claude-skills)](https://www.npmjs.com/package/@spardutti/claude-skills)
[![license](https://img.shields.io/npm/l/@spardutti/claude-skills)](./LICENSE)

Opinionated, always-current best-practice playbooks that load while Claude codes — so it writes today's idioms for the tools you actually use, not the averaged, two-years-stale code its training defaults to. This repo is the source catalog; the CLI installs exactly what each project needs from an interactive menu, pulling in any subagents your chosen commands depend on.

## Why This Exists

Coding agents don't fail because they can't code — they fail because they write **dated** code. A model's knowledge is frozen and averaged: ask for React and it reaches for `useEffect` and manual `useMemo`; ask for TypeScript and it assumes 5.x; it defaults to patterns that were fine two years ago and are wrong today.

The ecosystem's answer has been **process** — planning frameworks, spec-driven workflows, agent orchestration. Those steer *how* the agent works. None of them fix *what the code looks like*.

**This is the other half.** Each skill is a tight, opinionated playbook that pins Claude to current, senior-level practice for one tool — React 19.2 + the React Compiler, TypeScript 7.0, TanStack Query v5, Drizzle, FastAPI, SQL. Claude loads only the skills a task touches, so many can stay installed cheaply. Bring whatever planning framework you like on top; this makes sure the code that comes out isn't 2023-vintage.

**Freshness is the feature.** These track the changelogs as the tools move — the React Compiler going stable, TS 7.0's native compiler, Drizzle Relations v2 — so you don't have to.

## Quick Start

Run from any project directory:

```bash
npx @spardutti/claude-skills
```

```text
  Claude Skills Installer v2.6.0

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
5. Optionally set up the **hooks** — skill evaluation before edits, verification after (recommended — see [How It Works](#how-it-works))

## Skill Catalog

**14 skills**, grouped the same way the installer presents them.

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
| `typescript-best-practices` | TypeScript 7.x — type design, generics, type guards, `satisfies`, `using`, error handling, `tsconfig` |
| `testing-best-practices` 📦 | Arrange-Act-Assert, factory-based test data, isolation, mocking boundaries, a pyramid-balanced suite; bundle covers mutation testing — Stryker and mutmut setup, diff-scoped runs, the traps, and working score thresholds |
| `security-practices` | OWASP Top 10 prevention, input validation, auth, SQL injection, XSS, CSRF, secure defaults |

## Commands

Portable slash commands installed to `.claude/commands/`. Some orchestrate parallel subagents — those are pulled in automatically.

| Command | What it does |
|---------|--------------|
| `/ship` | Unified delivery pipeline — gate → commit → PR → merge → release. The gate is the one enforcement moment: it checks the diff's file lengths, audits it against the skills installed in the project, and mutation-tests the changed lines to prove the tests would catch a break — **fixing what it finds** rather than handing you a list. `--force` skips it. No argument steps through interactively; `/ship pr` runs through PR creation; `/ship release` runs the full pipeline |
| `/discover` | Find the right problem before deciding what to build — diverges first: names competing interpretations of what you said, stress-tests the framing with a blind critic subagent, then converges on a mental model. Run before `/preplan` |
| `/preplan` | Resolve a fuzzy feature idea into concrete decisions — 6 fixed phases, one question at a time, ends with a decision log. Run before `/plan-feature` |
| `/plan-feature` | Integration-first feature planning — 3 parallel subagents scan for reusable code, patterns, and touch points before producing a short plan |
| `/refactor` | Detect size / complexity / duplication / coupling issues via 4 parallel subagents, then refactor |
| `/deep-review` | Multi-agent deep code review — 5 parallel subagents catch guard bypasses, lost async state, wrong-table queries, dead references, protocol violations |
| `/test-review` | Write-then-verify test review — scopes to the diff, runs red-green + mutation gates, then an isolated read-only subagent proves each test would catch a regression instead of rubber-stamping it |
| `/lockdown` | Per-repo supply-chain hardening — detects the package managers, Dockerfiles, and CI in use, then guides you through and applies install-time, deploy, and pipeline hardening for npm/pnpm, pip/uv, Docker, and GitHub Actions |

## How It Works

The CLI installs three kinds of artifact into your project's `.claude/` directory:

- **Skills** → `.claude/skills/` — playbooks Claude loads while coding.
- **Commands** → `.claude/commands/` — slash commands you invoke directly.
- **Subagents** → `.claude/agents/` — declared by commands via `requires-agents`, installed for you.

### Tracking & Updates

Every install writes a manifest at `.claude/.claude-skills.json` recording what the CLI installed and the catalog version. On the next run it uses the manifest to:

- **Pre-check what you already have** in the picker — re-running doubles as an update screen; toggle to add or remove.
- **Detect stale items** — skills/commands renamed or removed from the catalog upstream (e.g. when several skills are merged into a bundle) are flagged, and the CLI offers to delete them.
- **Never touch what it didn't install** — the manifest is the CLI's own record; hand-written skills are invisible to it and always safe.

```bash
npx @spardutti/claude-skills --sync
```

`--local[=path]` reads the catalog from a working copy instead of GitHub, so an unreleased
change can be installed and tried without publishing it first:

```bash
node ~/projects/claude-skills/cli/bin/cli.mjs --local
```

`--sync` refreshes every tracked item to the latest catalog and prunes stale ones in one shot — no menu. For a project that predates the manifest, the first normal run offers a one-time cleanup of `.claude/` content no longer in the catalog.

### Automatic Skill Evaluation

After installing skills, the CLI offers to set up a hook that **guarantees** Claude evaluates your skills before writing code — instead of a soft reminder it can ignore.

It installs four hooks and appends a rule to your `CLAUDE.md`. Three guard the
**front** — nothing is written until your skills are considered:

- `skill-gate.sh` — a `PreToolUse` gate on `Write|Edit|MultiEdit|Bash`
- `skill-application-gate.sh` — a second `PreToolUse` gate requiring each loaded skill to be applied, not just read

Both cover **Bash**, not only the file-writing tools. A session that edits through
`python3 - <<'PY'` in Bash walked past the old matcher entirely — twelve source files, not
one prompt — and some harnesses actively tell the model to prefer Bash for edits. Only
commands that can write are gated (a redirect, `tee`, `sed -i`, `cp`/`mv`, or an
interpreter given inline code or a heredoc); `git status` and a redirect to `/dev/null`
pass untouched, and the command that clears the gate is never gated against itself.

Neither gate fires on **prose** — `.md`, `.mdx`, `.txt`, `.rst`, `.adoc`, images. Skills
are about code, and a repo full of `PLAN_*.md` otherwise hits the gate on every write.
Config files (`.json`, `.yml`, `.toml`) stay gated, because skills do have rules about
`tsconfig`, `package.json`, and Compose.
- `skill-gate-automark.sh` — a `PostToolUse` hook on `Skill` that clears the gate

The last two guard the **back** — nothing finishes or ships until the code passes:

- `gauntlet.sh` — a `Stop` hook running the fast gates on your changed files (see [Automatic Verification](#automatic-verification-gauntlet))
- `ship-gate-hook.sh` — a `PreToolUse` gate on `Bash` that refuses `git commit` and `git push` without a receipt from `ship-gate.sh`

One more hook stays out of the way entirely:

- `version-check.sh` — a `SessionStart` hook that mentions a newer catalog at most once a day. It never touches the network in the foreground: it reads a cache the previous session refreshed in the background, so it costs a file read. Silent when there is no cache, no network, or nothing new. `CLAUDE_SKILLS_NO_VERSION_CHECK=1` turns it off.

<details>
<summary>How the gate works</summary>

The gate hard-blocks `Write`, `Edit`, and `MultiEdit` until a per-session marker exists at `/tmp/claude-skill-gate-<SESSION_ID>`. The marker is created automatically the first time Claude invokes any `Skill()` in the session — so the normal flow is: Claude lists skills as ACTIVATE/SKIP, calls `Skill()` for the ACTIVATE ones, and the gate clears for the rest of the session. If every skill is SKIP, Claude clears the gate with `touch /tmp/claude-skill-gate-<SESSION_ID>`.

The marker is **per-session, not per-turn** — short follow-ups like "yes" don't re-lock it. The gate auto-passes when a project has no `.claude/skills/*/SKILL.md`, so it's safe to leave on globally.

It registers in `.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Write|Edit|MultiEdit|Bash", "hooks": [
        { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/skill-gate.sh" } ] },
      { "matcher": "Write|Edit|MultiEdit|Bash", "hooks": [
        { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/skill-application-gate.sh" } ] }
    ],
    "PostToolUse": [
      { "matcher": "Skill", "hooks": [
        { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/skill-gate-automark.sh" } ] }
    ]
  }
}
```

</details>

### Automatic Verification (Gauntlet)

The same install adds `gauntlet.sh` — a `Stop` hook that runs the cheap, deterministic
gates on your changed files every time Claude finishes a turn. Green is silent; red exits 2,
which keeps the turn from ending, shows you the failure, and hands it to Claude to fix.

Exit 2 matters: `{"decision":"continue"}` also keeps the turn going, but its reason reaches
Claude alone. A failing gate was then invisible from the outside — indistinguishable from a
gauntlet that does nothing.

Keep the gates fast for a reason beyond patience: a `command` hook that reaches its timeout
(600s by default) is cancelled and its **output discarded**, so the turn ends as if the hook
never ran. A stalled gate is a silent pass, not a block.

Only fast gates live here (target: under ~30s). Mutation testing and deep review stay
manual — they belong to `/test-review` and `/deep-review`, not to every turn.

At install time the CLI reports what it found, so a silent no-op is never a surprise:

```text
Gauntlet detected tsc + vitest — it will run those on changed files.
```

If no test runner is detected it says so, and offers to write a `.claude/gauntlet.conf`
pointing at your test command. Detection covers vitest, jest, pytest, `tsc`, and `mypy`;
everything else needs that one config line.

<details>
<summary>How the gauntlet hook works</summary>

It runs a skip ladder first, cheapest check first, and quits at the first "no":

1. no changed files (planning turns, questions)
2. no changed **code** files (docs/config only)
3. this exact diff already passed — the hash of a green run is cached per session and repo
4. no gates detected for this repo

Rule 3 is what makes repeated `/ship` runs free: the gates run once per distinct diff.

To confirm it is alive when everything is green — green prints nothing, by design:

```bash
ls -t /tmp/claude-gauntlet-*.why | head -1 | xargs cat
```

Every run records why it ended in `/tmp/claude-gauntlet-<session>.why`, so a green run
and a skipped one are told apart without re-running the hook. `GAUNTLET_DEBUG=1` prints
the same line to stderr:

```text
gauntlet: green: gates passed
gauntlet: skipped: no changed code files (docs/config only)
gauntlet: green: gates passed, but the runner matched 0 test files — the changed code was never executed
```

That last one is the false green worth knowing about. A test runner given files it has no
tests for exits 0 and looks exactly like a pass — in a monorepo whose vitest workspace
excludes a package, **no** change in that package can ever be covered. The hook names it
instead of reporting green. Set `GAUNTLET_REQUIRE_TESTS=1` to make it block instead.

The stack is auto-detected: vitest / jest / pytest for tests, and for typechecking the
repo's own `typecheck` script if it has one, else bare `tsc --noEmit` or `mypy`. The script
is preferred because a workspace root `tsconfig.json` is often solution-style, where
`tsc --noEmit` does not mean what the repo's `tsc -b` means.

**Monorepos work, including the ones with nothing at the root.** Detection collects every
gate it finds rather than stopping at the first, and each gate carries the file pattern it
applies to — so a JS + Python repo gets four gates, and a turn that touched only `.py` files
runs the Python two and skips the JS two entirely. Typechecks always run before tests, and
the first red stops the rest.

When the root has no manifest, detection looks two levels down for `package.json` /
`pyproject.toml` / `pytest.ini` — the `web/` + `api/`, `apps/*`, `packages/*` layouts — and
scopes each gate to that folder's files, running the command from inside it. Nested gates
are only added for the kind the root did not already provide, so a repo that works today
keeps working.

Setting `GAUNTLET_TEST` or `GAUNTLET_TYPECHECK` switches the repo to explicit mode:
auto-detection is off and only what you set runs.

**A missing tool is a skip, not a red.** A fresh clone with no `node_modules`, or a venv
without pytest, would otherwise fail every gate and block every turn — so the hook reports
`skipped: node_modules is missing — run your install first` and gets out of the way. Only
a gate that actually ran and actually failed blocks. Override anything in
a config file — two are read, in this order, and the project's wins key by key:

```text
~/.claude/gauntlet.conf          your defaults for every project
<project>/.claude/gauntlet.conf  overrides for this one
```

```bash
GAUNTLET_OFF=1                       # disable entirely
GAUNTLET_TYPECHECK='npm run check'   # "" to skip the gate
GAUNTLET_TEST='npm test -- $FILES'   # $FILES = changed code files
GAUNTLET_CODE_EXT='ts|tsx|py'        # what counts as a change worth checking
GAUNTLET_DEBUG=1                     # print the outcome to stderr every run
GAUNTLET_REQUIRE_TESTS=1             # block when the runner matched 0 test files

# /ship's gate reads its own keys from the same file
GAUNTLET_MAX_LINES=200               # per-file limit; 0 turns the check off
GAUNTLET_SOURCE_EXT='ts|tsx|py'      # what counts as SOURCE — not the same question
GAUNTLET_MUTATE='bash mutate.sh'     # replace per-project mutation detection
```

`GAUNTLET_SOURCE_EXT` is separate from `GAUNTLET_CODE_EXT` on purpose. The Stop hook asks
"did anything worth checking change", so a docs repo sets `CODE_EXT` to include `.md`. The
line limit and mutation ask about source code, where that answer is wrong.

Set your house rules once in `~/.claude/gauntlet.conf`; only reach for the project file
where a repo does something unusual (or set `GAUNTLET_OFF=1` there to opt one out).

It registers in `.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [
        { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/gauntlet.sh" } ] }
    ]
  }
}
```

</details>

<details>
<summary>Manual install (without the CLI)</summary>

```bash
# Skills
cp -r skills/<skill-name> /path/to/project/.claude/skills/

# Commands
cp commands/<command-name>.md /path/to/project/.claude/commands/

# Subagents — see the command's `requires-agents` frontmatter
cp agents/<agent-name>.md /path/to/project/.claude/agents/
```

</details>

## Repository Layout

```text
skills/        Skill playbooks — some are bundles (SKILL.md + on-demand reference files)
commands/      Slash commands installed to .claude/commands/
agents/        Subagent definitions — commands declare which they need via requires-agents
scripts/       validate-skills.mjs — checks skill length caps and reference integrity
               gauntlet.sh — the Stop-hook verification gates, embedded by the CLI
               ship-gate.sh — /ship's file-length and mutation checks, behind an exit code
               ship-gate-hook.sh — refuses git commit/push without a ship-gate receipt
               version-check.sh — SessionStart nudge when a newer catalog is published
               gauntlet-selftest.sh — behavioural tests for the hooks (runs on pre-push)
               gauntlet-survey.sh — what the hook would do in every repo under a directory
               preflight.sh — everything that must pass before a release
               check-freshness.mjs — compares each skill's `tracks:` versions to the registries
cli/           The npm installer (npx @spardutti/claude-skills); version in cli/package.json
.husky/        pre-push hook running the skill validator
package.json   Private dev-tooling package (claude-skills-dev) — not the published one
```

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
this repo's `.claude/gauntlet.conf` — `.claude/` is gitignored, so each contributor adds it
locally. It has to be the project file, not `~/.claude/gauntlet.conf`: these settings are
only right for a skills repo:

```bash
GAUNTLET_CODE_EXT='md|mjs|js|json|sh'   # markdown IS the product here
GAUNTLET_TYPECHECK=''
GAUNTLET_TEST='node scripts/validate-skills.mjs'
```

Without the `CODE_EXT` line the hook treats a skill edit as a docs-only change and skips.

## License

MIT
