# Claude Skills

Personal collection of reusable Claude Code skills.

## Skills

| Skill | Description |
|-------|-------------|
| `react-use-effect` | React 19 useEffect best practices and anti-patterns |
| `single-responsibility` | Single responsibility, file size limits, complexity rules |
| `react-query` | TanStack React Query with @lukemorales/query-key-factory patterns |
| `tailwind-tokens` | Enforce Tailwind CSS design tokens — no arbitrary values when a token exists |

## Usage

### Quick Install (recommended)

Run from any project directory to interactively select and install skills:

```bash
npx @spardutti/claude-skills
```

This fetches the latest skills from GitHub, lets you pick which ones to install, and copies them into your project's `.claude/skills/` directory.

### Manual Install

Copy a skill directory into your project's `.claude/skills/` folder:

```bash
cp -r skills/<skill-name> /path/to/project/.claude/skills/
```

Or symlink for automatic updates:

```bash
ln -s /path/to/claude-skills/skills/<skill-name> /path/to/project/.claude/skills/<skill-name>
```
