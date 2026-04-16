# Claude Skills

Personal collection of reusable Claude Code skills.

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
| `/refactor` | Find code files over 200 lines and refactor them into smaller modules |
| `/deep-review` | Multi-agent deep code review — 5 parallel agents catch guard bypasses, lost async state, wrong-table queries, dead references, protocol violations |

## Quick Start

Run from any project directory:

```bash
npx @spardutti/claude-skills
```

The CLI will:

1. Fetch the latest skills and commands from GitHub
2. Let you pick which skills to install → `.claude/skills/`
3. Let you pick which commands to install → `.claude/commands/`
4. **Optionally set up automatic skill evaluation** (recommended — see below)

## Automatic Skill Evaluation

After installing skills, the CLI asks if you want to set up automatic skill evaluation. If you say yes, it will:

- **Create a hook** at `.claude/hooks/skill-forced-eval-hook.sh` that runs on every prompt
- **Update your `CLAUDE.md`** with a `skill_evaluation` rule

This forces Claude to explicitly evaluate every installed skill before writing code — listing each skill as ACTIVATE or SKIP with a reason, then calling the relevant ones. Without this, Claude may silently ignore your skills.

### What gets created

**`.claude/settings.json`** — Registers the hook:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": ".claude/hooks/skill-forced-eval-hook.sh"
          }
        ]
      }
    ]
  }
}
```

**`CLAUDE.md`** — Appends the evaluation rule:

```yaml
skill_evaluation:
  mandatory: true
  rule: |
    BEFORE writing ANY code, you MUST:
    1. List EVERY skill from the system-reminder's available skills section
    2. For each skill, write: [skill-name] → ACTIVATE / SKIP — [one-line reason]
    3. Call Skill(name) for every skill marked ACTIVATE
    4. Only THEN proceed to implementation
    If you skip this evaluation, your response is INCOMPLETE and WRONG.
```

### GitHub Authentication

The CLI uses the GitHub API to fetch skills. To avoid rate limits:

- If you have the [GitHub CLI](https://cli.github.com) installed and authenticated (`gh auth login`), the token is picked up automatically
- Or set `GITHUB_TOKEN` / `GH_TOKEN` environment variable
- Without auth, GitHub allows 60 requests/hour (the CLI uses ~6 per run)

## Manual Install

Copy a skill directory into your project's `.claude/skills/` folder:

```bash
cp -r skills/<skill-name> /path/to/project/.claude/skills/
```
