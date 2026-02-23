# @spardutti/claude-skills

Interactive CLI to install reusable [Claude Code](https://docs.anthropic.com/en/docs/claude-code) skills into any project.

## Usage

```bash
npx @spardutti/claude-skills
```

This will:

1. Fetch the latest skills from [GitHub](https://github.com/Spardutti/claude-skills)
2. Let you interactively select which skills to install
3. Copy them into your project's `.claude/skills/` directory

## Available Skills

| Skill | Description |
|-------|-------------|
| `react-use-effect` | React 19 useEffect best practices and anti-patterns |
| `single-responsibility` | Single responsibility, file size limits, complexity rules |
| `react-query` | TanStack React Query with query-key-factory patterns |
| `tailwind-tokens` | Enforce Tailwind CSS design tokens — no arbitrary values when a token exists |

## What are Claude Code Skills?

Skills are markdown files placed in `.claude/skills/` that give Claude Code domain-specific knowledge and guidelines. They help Claude follow your team's patterns and best practices automatically.

## License

MIT
