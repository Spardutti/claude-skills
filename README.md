# Claude Skills

> An interactive CLI that installs a curated catalog of Claude Code **skills**, **slash commands**, and **subagents** into any project.

[![npm version](https://img.shields.io/npm/v/@spardutti/claude-skills)](https://www.npmjs.com/package/@spardutti/claude-skills)
[![npm downloads](https://img.shields.io/npm/dm/@spardutti/claude-skills)](https://www.npmjs.com/package/@spardutti/claude-skills)
[![license](https://img.shields.io/npm/l/@spardutti/claude-skills)](./LICENSE)

Skills are reference playbooks Claude Code loads while it codes — enforcing current best practices for the tools you actually use. This repo is the source catalog; the CLI lets you pick exactly what each project needs from an interactive menu, and pulls in any subagents your chosen commands depend on automatically.

## Quick Start

Run from any project directory:

```bash
npx @spardutti/claude-skills
```

```text
  Claude Skills Installer v2.0.0

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
5. Optionally set up the **skill-evaluation hook** (recommended — see [How It Works](#how-it-works))

## Skill Catalog

**13 skills**, grouped the same way the installer presents them.

> [!NOTE]
> Skills marked **📦 Bundle** ship a concise always-loaded entry point plus reference files Claude reads only when a task needs them — comprehensive coverage at a low context cost.

### Frontend

| Skill | What it covers |
|-------|----------------|
| `react` 📦 | React 19.2 — `use`, Actions, `ref` as prop, Rules of Hooks, React Compiler v1.0, component splitting, `useEffect` avoidance, performance, loading/empty states, Zustand, Tailwind v4 tokens |
| `tanstack-query` 📦 | TanStack Query v5 — queries, mutations (pessimistic & optimistic), `useInfiniteQuery`/`useSuspenseQuery`, query-key factories, v4→v5 migration |
| `tanstack-router` | File-based routing, type-safe navigation, loaders & caching, search params, `beforeLoad` auth guards, pending UI that prevents frozen-feeling navigation |

### Backend

| Skill | What it covers |
|-------|----------------|
| `fastapi` 📦 | FastAPI — async correctness, `Annotated` dependency injection, `lifespan`, response models, testing with dependency overrides; bundle covers Pydantic, Alembic, Celery, and list endpoints (pagination/filtering/search/sorting) |
| `drf-best-practices` | Django REST Framework — thin serializers, service layer, queryset optimization, object-level permissions |
| `drizzle-orm` | Drizzle ORM — schema design, identity columns, relations, migration safety, type inference |
| `docker-best-practices` | Multi-stage builds, layer caching, security hardening, Compose Watch, health checks |

### Database

| Skill | What it covers |
|-------|----------------|
| `sql` 📦 | Schema design, data types, indexing & `EXPLAIN`, joins & subqueries, ORM patterns (N+1, transactions, locking), safe migrations |

### Desktop

| Skill | What it covers |
|-------|----------------|
| `tauri-v2` | Tauri v2 — IPC commands, plugins, window management, system tray, global shortcuts, capabilities/permissions, events |

### Foundations

Cross-cutting craft — applies to any stack, any language.

| Skill | What it covers |
|-------|----------------|
| `code-structure` 📦 | Single Responsibility (when to split) + Avoid Hasty Abstractions (when *not* to extract) — hard size limits, separation of concerns, the Rule of Three |
| `typescript-best-practices` | TypeScript 6.x — type design, generics, type guards, `satisfies`, `using`, error handling, `tsconfig` |
| `testing-best-practices` | Arrange-Act-Assert, factory-based test data, isolation, mocking boundaries, a pyramid-balanced suite |
| `security-practices` | OWASP Top 10 prevention, input validation, auth, SQL injection, XSS, CSRF, secure defaults |

## Commands

Portable slash commands installed to `.claude/commands/`. Some orchestrate parallel subagents — those are pulled in automatically.

| Command | What it does |
|---------|--------------|
| `/ship` | Unified delivery pipeline — commit → PR → merge → release. No argument steps through interactively; `/ship pr` runs through PR creation; `/ship release` runs the full pipeline |
| `/preplan` | Resolve a fuzzy feature idea into concrete decisions — 6 fixed phases, one question at a time, ends with a decision log. Run before `/plan-feature` |
| `/plan-feature` | Integration-first feature planning — 3 parallel subagents scan for reusable code, patterns, and touch points before producing a short plan |
| `/refactor` | Detect size / complexity / duplication / coupling issues via 4 parallel subagents, then refactor |
| `/deep-review` | Multi-agent deep code review — 5 parallel subagents catch guard bypasses, lost async state, wrong-table queries, dead references, protocol violations |

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

`--sync` refreshes every tracked item to the latest catalog and prunes stale ones in one shot — no menu. For a project that predates the manifest, the first normal run offers a one-time cleanup of `.claude/` content no longer in the catalog.

### Automatic Skill Evaluation

After installing skills, the CLI offers to set up a hook that **guarantees** Claude evaluates your skills before writing code — instead of a soft reminder it can ignore.

It installs two hooks and appends a rule to your `CLAUDE.md`:

- `skill-gate.sh` — a `PreToolUse` gate on `Write|Edit|MultiEdit`
- `skill-gate-automark.sh` — a `PostToolUse` hook on `Skill` that clears the gate

<details>
<summary>How the gate works</summary>

The gate hard-blocks `Write`, `Edit`, and `MultiEdit` until a per-session marker exists at `/tmp/claude-skill-gate-<SESSION_ID>`. The marker is created automatically the first time Claude invokes any `Skill()` in the session — so the normal flow is: Claude lists skills as ACTIVATE/SKIP, calls `Skill()` for the ACTIVATE ones, and the gate clears for the rest of the session. If every skill is SKIP, Claude clears the gate with `touch /tmp/claude-skill-gate-<SESSION_ID>`.

The marker is **per-session, not per-turn** — short follow-ups like "yes" don't re-lock it. The gate auto-passes when a project has no `.claude/skills/*/SKILL.md`, so it's safe to leave on globally.

It registers in `.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Write|Edit|MultiEdit", "hooks": [
        { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/skill-gate.sh" } ] }
    ],
    "PostToolUse": [
      { "matcher": "Skill", "hooks": [
        { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/skill-gate-automark.sh" } ] }
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

## License

MIT
