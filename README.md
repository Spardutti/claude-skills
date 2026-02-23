# Claude Skills

Personal collection of reusable Claude Code skills.

## Skills

| Skill | Description |
|-------|-------------|
| `react-use-effect` | React 19 useEffect best practices and anti-patterns |
| `single-responsibility` | Single responsibility, file size limits, complexity rules |

## Usage

Copy a skill directory into your project's `.claude/skills/` folder:

```bash
cp -r skills/<skill-name> /path/to/project/.claude/skills/
```

Or symlink for automatic updates:

```bash
ln -s /path/to/claude-skills/skills/<skill-name> /path/to/project/.claude/skills/<skill-name>
```
