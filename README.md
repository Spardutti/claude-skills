# Claude Skills

Personal collection of reusable Claude Code skills.

## Skills

| Skill | Description |
|-------|-------------|
| `react-best-practices` | React 19 — component design, state management, performance, React 19 features, TypeScript integration |
| `react-use-effect` | React 19 useEffect best practices and anti-patterns |
| `react-query` | TanStack React Query with @lukemorales/query-key-factory patterns |
| `tanstack-router-best-practices` | TanStack Router — file-based routing, type-safe navigation, loaders, search params, auth guards |
| `typescript-best-practices` | TypeScript 5.x — type design, type safety, generics, error handling, tsconfig |
| `single-responsibility` | Single responsibility, file size limits, complexity rules |
| `tailwind-tokens` | Enforce Tailwind CSS design tokens — no arbitrary values when a token exists |
| `drf-best-practices` | Django REST Framework — thin serializers, service layer, queryset optimization, object-level permissions |
| `fastapi-best-practices` | FastAPI — async correctness, Pydantic validation, dependency injection, service layer, structured error handling |
| `security-practices` | Web security — OWASP Top 10 prevention, input validation, auth, SQL injection, XSS, CSRF, secure defaults |
| `alembic-migrations` | Alembic — naming conventions, autogenerate review, data migration safety, downgrades, production deployment |
| `testing-best-practices` | Testing — Arrange-Act-Assert, factory-based test data, test isolation, mocking boundaries, pyramid-balanced coverage |

## Quick Start

Run from any project directory:

```bash
npx @spardutti/claude-skills
```

The CLI will:

1. Fetch the latest skills from GitHub
2. Let you pick which ones to install
3. Copy them into your project's `.claude/skills/` directory
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
            "command": "/absolute/path/.claude/hooks/skill-forced-eval-hook.sh"
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
