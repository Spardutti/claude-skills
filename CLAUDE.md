# Claude Skills Project

## What this repo is

This is the **source repository** for a collection of Claude Code skills that get
distributed via the `@spardutti/claude-skills` CLI and installed into other
projects. Skills are authored here, then consumed elsewhere.

**Skills are not meant to be invoked when working inside this repo.** The
auto-invocation hook (`skill-gate.sh`) is a build artifact — it's the thing
being shipped to consumer projects, not a workflow rule for editing the skills
themselves. When working in this repo, your job is to author and maintain
skill content, the CLI, and the hook — not to run skills against your own edits.

**The CLI is a picker, not a bulk installer.** Consumers run the CLI and
choose which skills to install per-project. So a full-stack project (e.g.
Python + React) will legitimately install many skills at once. When reasoning
about "skill bloat," assume the user already picked the minimal set they need —
the lever is not "install fewer" but "make each installed skill cheaper to keep
loaded" (tighter descriptions, bundling related skills, smarter gating).

## Skill File Guidelines

- Skills live in `skills/<skill-name>/SKILL.md`. A skill may be a **bundle** — `SKILL.md` plus reference files in the same directory that it routes to (see Structure below).
- **Frontmatter must include `category:`** (e.g. `Database`, `Frontend`, `Backend`, `Workflow`). The CLI picker (`cli/lib/prompt.mjs`) groups skills by category in the install UI — dropping this field breaks grouping. Anthropic's spec only requires `name` and `description`, but `category` is a project-level convention parsed by `cli/lib/github.mjs`.
- **Length targets differ by file role** — `SKILL.md` is loaded into context on every activation and stays there, so every line is recurring cost; reference files load on demand, one at a time, only when `SKILL.md` routes to them.
  - **`SKILL.md`**: target **~250 lines**, hard cap **350**. Under 150 is too thin.
  - **Reference files** (other `*.md` in a skill dir): target **~250 lines**, hard cap **500** (Anthropic's documented SKILL.md limit). They don't compete with conversation history the way `SKILL.md` does, so the cap is looser.
  - Reference files over 100 lines need a `## Contents` TOC near the top (validated by `scripts/validate-skills.mjs`).
- Use BAD/GOOD code pairs as the primary teaching tool — they are more effective than prose explanations.
- Keep prose minimal. If the code example speaks for itself, don't explain it.
- End every skill with a **Rules** section: short imperative statements ("Always X", "Never Y").
- Markdown that helps: `##`/`###` headers (semantic anchors), code blocks, **bold** for emphasis.
- Markdown that doesn't help much: tables (unless compact), blockquotes, horizontal rules, deep nesting.

## Versioning & Publishing

- Bump `cli/package.json` version on every shipped change.
- Semver: new skills or hook/CLI features = minor bump; fixes to existing skills, hook, or CLI = patch bump.
- Publish flow: bump version → commit → push to `main` → `npm publish ./cli --access public`.

## Structure

```
skills/
  <skill-name>/
    SKILL.md          # Entry point — loaded when the skill activates
    <REFERENCE>.md    # Optional reference files (bundles) — loaded on demand
commands/             # Slash commands — installed to consumers' .claude/commands/
agents/               # Subagent definitions — commands declare which they need
scripts/
  validate-skills.mjs # Skill length/reference validator — runs on pre-push
cli/
  package.json        # Published CLI version — bump on every release
  bin/cli.mjs         # CLI entry point
  lib/
    setup-hook.mjs    # Embeds skill-gate.sh + automark hook scripts
    install.mjs       # Skill installer
    ...
.husky/
  pre-push            # Runs the skill validator
package.json          # Private dev-tooling package (husky) — NOT the published CLI
README.md             # Project readme with the skills + commands tables
CLAUDE.md             # This file
```

A **bundle** is a skill whose `SKILL.md` routes to reference files in the same
directory (e.g. `skills/react/` → `COMPONENT-DESIGN.md`, `USE-EFFECT.md`, …).
`SKILL.md` carries the always-loaded 80% case; references hold the deep-dive
20% and load only when `SKILL.md` points to them.

When adding or renaming a skill or command, update the README's tables to match.

## Skill authoring rule: 200-line limit

Skills should teach consumers to **never write a single file longer than 200
lines of code**. If a skill includes code examples or generates code, that
guidance must be reflected in the skill's content. This is a rule *for the
skills*, not a rule for files in this repo.
