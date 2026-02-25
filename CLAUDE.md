# Claude Skills Project

## Skill File Guidelines

- Skills live in `skills/<skill-name>/SKILL.md`
- Target **~250 lines** per skill (200-270 acceptable range). Beyond 300 the LLM loses focus; under 150 is too thin.
- Use BAD/GOOD code pairs as the primary teaching tool — they are more effective than prose explanations.
- Keep prose minimal. If the code example speaks for itself, don't explain it.
- End every skill with a **Rules** section: short imperative statements ("Always X", "Never Y").
- Markdown that helps: `##`/`###` headers (semantic anchors), code blocks, **bold** for emphasis.
- Markdown that doesn't help much: tables (unless compact), blockquotes, horizontal rules, deep nesting.

## Versioning

- Bump `cli/package.json` version when adding/changing skills.
- Use semver: new skills = minor bump, fixes to existing skills = patch bump.

## Structure

```
skills/
  <skill-name>/
    SKILL.md        # The skill content
cli/
  package.json      # CLI version
  bin/cli.mjs       # CLI entry point
  lib/              # CLI library code
README.md           # Project readme with skills table
CLAUDE.md           # This file
```

When adding a new skill, also add it to the README.md skills table.
