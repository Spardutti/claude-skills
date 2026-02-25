# @spardutti/claude-skills

Interactive CLI to install reusable [Claude Code](https://docs.anthropic.com/en/docs/claude-code) skills into any project.

## Usage

```bash
npx @spardutti/claude-skills
```

Run this from your project's root directory. The CLI will:

1. Fetch the latest skills from [GitHub](https://github.com/Spardutti/claude-skills)
2. Let you interactively select which skills to install
3. Copy them into your project's `.claude/skills/` directory
4. Ask to set up **automatic skill evaluation** (hook + CLAUDE.md rule)

## Automatic Skill Evaluation

Skills alone don't guarantee Claude will use them. The CLI can optionally set up enforcement:

- **Hook** (`.claude/hooks/skill-forced-eval-hook.sh`) — Runs on every prompt, injects a mandatory skill evaluation sequence into Claude's context
- **CLAUDE.md rule** (`skill_evaluation` block) — Instructs Claude to list every skill as ACTIVATE/SKIP before writing any code

Together, these force Claude to explicitly evaluate and activate relevant skills instead of silently ignoring them.

## Available Skills

| Skill | Description |
|-------|-------------|
| `react-use-effect` | React 19 useEffect best practices and anti-patterns |
| `single-responsibility` | Single responsibility, file size limits, complexity rules |
| `react-query` | TanStack React Query with query-key-factory patterns |
| `tailwind-tokens` | Enforce Tailwind CSS design tokens — no arbitrary values when a token exists |
| `drf-best-practices` | Django REST Framework — thin serializers, service layer, queryset optimization, object-level permissions |
| `fastapi-best-practices` | FastAPI — async correctness, Pydantic validation, dependency injection, service layer, structured error handling |
| `security-practices` | Web security — OWASP Top 10 prevention, input validation, auth, SQL injection, XSS, CSRF, secure defaults |
| `alembic-migrations` | Alembic — naming conventions, autogenerate review, data migration safety, downgrades, production deployment |
| `testing-best-practices` | Testing — Arrange-Act-Assert, factory-based test data, test isolation, mocking boundaries, pyramid-balanced coverage |

## GitHub Authentication

The CLI fetches skills via the GitHub API. Unauthenticated requests are limited to 60/hour. To avoid rate limits:

- Install the [GitHub CLI](https://cli.github.com) and run `gh auth login` — the token is detected automatically
- Or set `GITHUB_TOKEN` / `GH_TOKEN` as an environment variable

## What are Claude Code Skills?

Skills are markdown files placed in `.claude/skills/` that give Claude Code domain-specific knowledge and guidelines. They help Claude follow your team's patterns and best practices automatically.

## License

MIT
