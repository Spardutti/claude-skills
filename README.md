# Claude Skills

Personal collection of reusable Claude Code **skills**, **slash commands**, and **subagents**. Install them into any project with one command — pick what you want from an interactive menu, and any subagents declared by the commands you pick get installed automatically.

## Skills

### Frontend

| Skill | Description |
|-------|-------------|
| `react-best-practices` | React 19 — component design, state management, performance, React 19 features, TypeScript integration |
| `react-use-effect` | React 19 useEffect best practices and anti-patterns |
| `react-query` | TanStack React Query with @lukemorales/query-key-factory patterns |
| `react-single-responsibility` | React single responsibility — component splitting, hook isolation, file size limits, complexity rules |
| `tanstack-router-best-practices` | TanStack Router — file-based routing, type-safe navigation, loaders, search params, auth guards |
| `trpc-react-query` | tRPC v11 — queryOptions/mutationOptions patterns, router organization, middleware, cache invalidation, optimistic updates |
| `tailwind-tokens` | Enforce Tailwind CSS design tokens — no arbitrary values when a token exists |
| `zustand` | Zustand — store design, selectors, persist/immer middleware, slices pattern, devtools, transient updates |
| `dnd-kit` | @dnd-kit — sortable lists, sensors, collision detection, drag overlays, multi-container (kanban), accessibility |
| `framer-motion` | Motion (Framer Motion) — AnimatePresence, layout animations, variants, gestures, useAnimate, performance |

### Desktop

| Skill | Description |
|-------|-------------|
| `tauri-v2` | Tauri v2 — IPC commands, plugins, window management, system tray, global shortcuts, capabilities/permissions, events |

### TypeScript

| Skill | Description |
|-------|-------------|
| `typescript-best-practices` | TypeScript 5.x — type design, type safety, generics, error handling, tsconfig |

### Backend

| Skill | Description |
|-------|-------------|
| `express-best-practices` | Express.js — feature-based structure, 3-layer architecture, Zod validation, centralized error handling, security middleware |
| `fastify-best-practices` | Fastify — plugin architecture, encapsulation, TypeBox validation/serialization, services as decorators, reply helpers, hooks |
| `fastapi-best-practices` | FastAPI — async correctness, Pydantic validation, dependency injection, service layer, structured error handling |
| `pydantic-best-practices` | Pydantic v2 — model_config, field/model validators, Annotated types, discriminated unions, computed_field, strict mode, TypeAdapter |
| `celery-best-practices` | Celery — idempotency, acks_late, autoretry with backoff/jitter, canvas (chain/group/chord), routing, priorities, beat, time limits |
| `drf-best-practices` | Django REST Framework — thin serializers, service layer, queryset optimization, object-level permissions |
| `drizzle-orm` | Drizzle ORM — schema design, identity columns, relations, relational queries, migrations, drizzle-kit workflow, type inference |
| `alembic-migrations` | Alembic — naming conventions, autogenerate review, data migration safety, downgrades, production deployment |
| `docker-best-practices` | Docker — multi-stage builds, layer caching, security hardening, Compose Watch for local dev, health checks |

### Database

| Skill | Description |
|-------|-------------|
| `sql-joins` | SQL joins — LEFT JOIN traps, fan-out, NOT IN NULL bug, EXISTS vs IN, FK design, junction tables, CASCADE pitfalls |
| `sql-indexing` | SQL indexing — composite order, covering/partial/expression indexes, SARGability, EXPLAIN interpretation, keyset pagination |
| `sql-schema-design` | SQL schema — normalization, data types (TIMESTAMPTZ, NUMERIC), constraints, anti-patterns, safe migrations |
| `sql-orm-patterns` | SQL ORM — N+1 fixes for Prisma/Django/SQLAlchemy/ActiveRecord/TypeORM, transactions, isolation levels, locking |

### Architecture

| Skill | Description |
|-------|-------------|
| `single-responsibility` | Single Responsibility Principle — language-agnostic SRP, file size limits, CQS, separation of concerns, smell tests |
| `avoid-hasty-abstractions` | AHA / Rule of Three — prefer duplication over the wrong abstraction, boolean-parameter creep, undoing bad extractions |

### Quality

| Skill | Description |
|-------|-------------|
| `testing-best-practices` | Testing — Arrange-Act-Assert, factory-based test data, test isolation, mocking boundaries, pyramid-balanced coverage |
| `security-practices` | Web security — OWASP Top 10 prevention, input validation, auth, SQL injection, XSS, CSRF, secure defaults |

## Commands

Portable slash commands for common git workflows. Installed to `.claude/commands/` in your project.

| Command | Description |
|---------|-------------|
| `/commit` | Smart commit — branch safety, atomic staging, conventional commits |
| `/pr` | Create PR — auto-detect base branch, structured summary and test plan |
| `/release` | Release flow — dev→main PR with semver, changelog, tag, and GitHub release |
| `/refactor` | Detect size/complexity/duplication/coupling issues via 4 parallel Haiku subagents, then refactor |
| `/deep-review` | Multi-agent deep code review — 5 parallel Sonnet subagents catch guard bypasses, lost async state, wrong-table queries, dead references, protocol violations |
| `/plan-feature` | Integration-first feature planning — 3 parallel Haiku subagents scan for reusable code, established patterns, and touch points before producing a short integration plan |

## Quick Start

Run from any project directory:

```bash
npx @spardutti/claude-skills
```

The CLI will:

1. Fetch the latest skills, commands, and agents from GitHub
2. Let you pick which skills to install → `.claude/skills/`
3. Let you pick which commands to install → `.claude/commands/`
4. Auto-install any subagents declared by the selected commands → `.claude/agents/`
5. **Optionally set up automatic skill evaluation** (recommended — see below)

## Automatic Skill Evaluation

After installing skills, the CLI asks if you want to set up automatic skill evaluation. If you say yes, it will:

- **Install two hooks** in `.claude/hooks/`:
  - `skill-gate.sh` — PreToolUse gate on `Write|Edit|MultiEdit`
  - `skill-gate-automark.sh` — PostToolUse on `Skill` that auto-clears the gate
- **Update your `CLAUDE.md`** with the skill-evaluation rule

The gate hard-blocks `Write`, `Edit`, and `MultiEdit` until a per-session marker file exists at `/tmp/claude-skill-gate-<SESSION_ID>`. The marker is created automatically the first time Claude invokes any `Skill()` in the session — so the normal flow is: Claude lists skills as ACTIVATE/SKIP, calls `Skill()` for the ACTIVATE ones, and the gate clears for the rest of the session. If every skill is SKIP, Claude clears the gate by running `touch /tmp/claude-skill-gate-<SESSION_ID>`.

The marker is **per-session, not per-turn** — short follow-ups like "yes" don't re-lock the gate after evaluation has already happened.

Unlike a soft reminder injected into context (which Claude can ignore), the gate denies the tool call outright — so the only path forward is to actually evaluate skills.

The gate auto-passes when the project has no `.claude/skills/*/SKILL.md` files, so it's safe to leave on globally.

### What gets created

**`.claude/settings.json`** — Registers both hooks:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Write|Edit|MultiEdit",
        "hooks": [
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/skill-gate.sh"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Skill",
        "hooks": [
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/skill-gate-automark.sh"
          }
        ]
      }
    ]
  }
}
```

**`CLAUDE.md`** — Appends the skill-evaluation rule that tells Claude to enumerate skills as ACTIVATE/SKIP and call `Skill()` for ACTIVATE entries before writing code.

## Manual Install

If you don't want to use the CLI, copy files directly into your project:

```bash
# Skills
cp -r skills/<skill-name> /path/to/project/.claude/skills/

# Commands
cp commands/<command-name>.md /path/to/project/.claude/commands/

# Subagents (required by some commands — see the command's `requires-agents` frontmatter)
cp agents/<agent-name>.md /path/to/project/.claude/agents/
```

## Repository Layout

```
skills/           Reference playbooks loaded by Claude during coding tasks
commands/         Slash commands installed to .claude/commands/
agents/           Subagent definitions — commands declare which ones they need
cli/              The npm installer (npx @spardutti/claude-skills)
```
