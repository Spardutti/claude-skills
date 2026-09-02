# Hooks & Internals

Everything the installer writes into `.claude/hooks/`, what each hook blocks, and
every knob for turning it down. The [README](./README.md) covers what the hooks
are for; this covers how they behave when one gets in your way.

## Contents

- [What Gets Installed](#what-gets-installed)
- [The Skill Gates](#the-skill-gates)
- [When The Gate Blocks Something It Shouldn't](#when-the-gate-blocks-something-it-shouldnt)
- [The Gauntlet (Stop Hook)](#the-gauntlet-stop-hook)
- [Configuration Reference](#configuration-reference)
- [The Ship Gate](#the-ship-gate)
- [Manual Install](#manual-install)

## What Gets Installed

Six hooks, plus a rule appended to your `CLAUDE.md`.

Three guard the **front** — nothing is written until your skills are considered:

- `skill-gate.sh` — a `PreToolUse` gate on `Write|Edit|MultiEdit|Bash`
- `skill-application-gate.sh` — a second `PreToolUse` gate requiring each loaded
  skill to be *applied*, not just read
- `skill-gate-automark.sh` — a `PostToolUse` hook on `Skill` that clears the gate

Two guard the **back** — nothing finishes or ships until the code passes:

- `gauntlet.sh` — a `Stop` hook running the fast gates on your changed files
- `ship-gate-hook.sh` — a `PreToolUse` gate on `Bash` that refuses `gh pr create`,
  `gh pr merge`, and a `git push` from a protected branch without a receipt from
  `ship-gate.sh`

One stays out of the way entirely:

- `version-check.sh` — a `SessionStart` hook that mentions a newer catalog at most
  once a day. It never touches the network in the foreground: it reads a cache the
  previous session refreshed in the background, so it costs a file read. Silent
  when there is no cache, no network, or nothing new.
  `CLAUDE_SKILLS_NO_VERSION_CHECK=1` turns it off.

## The Skill Gates

The gate hard-blocks `Write`, `Edit`, and `MultiEdit` until a per-session marker
exists at `/tmp/claude-skill-gate-<SESSION_ID>`. The marker is created
automatically the first time Claude invokes any `Skill()` in the session — so the
normal flow is: Claude lists skills as ACTIVATE/SKIP, calls `Skill()` for the
ACTIVATE ones, and the gate clears for the rest of the session. If every skill is
SKIP, Claude clears the gate with `touch /tmp/claude-skill-gate-<SESSION_ID>`.

The marker is **per-session, not per-turn** — short follow-ups like "yes" don't
re-lock it. The gate auto-passes when a project has no `.claude/skills/*/SKILL.md`,
so it is safe to leave on globally.

**Both gates cover Bash, not only the file-writing tools.** A session that edits
through `python3 - <<'PY'` in Bash walked past the old matcher entirely — twelve
source files, not one prompt — and some harnesses actively tell the model to
prefer Bash for edits. Only commands that can write are gated (a redirect, `tee`,
`sed -i`, `cp`/`mv`, or an interpreter given inline code or a heredoc);
`git status` and a redirect to `/dev/null` pass untouched, and the command that
clears the gate is never gated against itself.

**Neither gate fires on prose** — `.md`, `.mdx`, `.txt`, `.rst`, `.adoc`, images.
Skills are about code, and a repo full of `PLAN_*.md` otherwise hits the gate on
every write. Config files (`.json`, `.yml`, `.toml`) stay gated, because skills do
have rules about `tsconfig`, `package.json`, and Compose.

`.claude/settings.json` and `.claude/settings.local.json` are exempt from both
gates. That file configures the escape hatch below, and gating it left sessions
with no move to make.

It registers in `.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Write|Edit|MultiEdit|Bash", "hooks": [
        { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/skill-gate.sh" } ] },
      { "matcher": "Write|Edit|MultiEdit|Bash", "hooks": [
        { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/skill-application-gate.sh" } ] }
    ],
    "PostToolUse": [
      { "matcher": "Skill", "hooks": [
        { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/skill-gate-automark.sh" } ] }
    ]
  }
}
```

## When The Gate Blocks Something It Shouldn't

**In auto mode, the acknowledgement `touch` is denied by the permission
classifier.** Its built-in Auto-Mode Bypass rule counts a hook's marker file as
working around the permission system. It is a *soft* rule, so an allow entry
clears it — but the entry has to be in **your own** `~/.claude/settings.json`;
the classifier deliberately ignores a project's `.claude/settings.json` so a
cloned repo cannot loosen it.

Claude cannot add that entry for you — an agent editing permission settings is
denied by the same classifier. Three ways to add it yourself, shortest first:

1. Re-run `npx @spardutti/claude-skills` and accept the auto mode prompt.
2. `/permissions`, Auto mode tab.
3. Edit `~/.claude/settings.json` by hand. **Keep the `$defaults` entry** or every
   built-in allow rule is discarded:

```json
{
  "autoMode": {
    "allow": [
      "$defaults",
      "Touching marker files under /tmp/claude-skill-gate-*, /tmp/claude-skill-acked-* and /tmp/claude-skill-loaded-* is allowed: they are acknowledgement files for the user's own PreToolUse skill gates. Creating one satisfies a workflow gate the user installed, grants no permission and executes no code, and is a false positive for Auto-Mode Bypass."
    ]
  }
}
```

## The Gauntlet (Stop Hook)

`gauntlet.sh` runs the cheap, deterministic gates on your changed files every time
Claude finishes a turn. Green is silent; red exits 2, which keeps the turn from
ending, shows you the failure, and hands it to Claude to fix.

Exit 2 matters: `{"decision":"continue"}` also keeps the turn going, but its reason
reaches Claude alone. A failing gate was then invisible from the outside —
indistinguishable from a gauntlet that does nothing.

Keep the gates fast for a reason beyond patience: a `command` hook that reaches its
timeout (600s by default) is cancelled and its **output discarded**, so the turn
ends as if the hook never ran. A stalled gate is a silent pass, not a block.

Only fast gates live here (target: under ~30s). Mutation testing and deep review
stay manual — they belong to `/test-review` and `/deep-review`, not to every turn.

At install time the CLI reports what it found, so a silent no-op is never a
surprise:

```text
Gauntlet detected tsc + vitest — it will run those on changed files.
```

If no test runner is detected it says so, and offers to write a
`.claude/gauntlet.conf` pointing at your test command. Detection covers vitest,
jest, pytest, `tsc`, and `mypy`; everything else needs that one config line.

### The Skip Ladder

It runs a skip ladder first, cheapest check first, and quits at the first "no":

1. no changed files (planning turns, questions)
2. no changed **code** files (docs/config only)
3. this exact diff already passed — the hash of a green run is cached per session and repo
4. no gates detected for this repo

Rule 3 is what makes repeated `/ship` runs free: the gates run once per distinct diff.

To confirm it is alive when everything is green — green prints nothing, by design:

```bash
ls -t /tmp/claude-gauntlet-*.why | head -1 | xargs cat
```

Every run records why it ended in `/tmp/claude-gauntlet-<session>.why`, so a green
run and a skipped one are told apart without re-running the hook.
`GAUNTLET_DEBUG=1` prints the same line to stderr:

```text
gauntlet: green: gates passed
gauntlet: skipped: no changed code files (docs/config only)
gauntlet: green: gates passed, but the runner matched 0 test files — the changed code was never executed
```

That last one is the false green worth knowing about. A test runner given files it
has no tests for exits 0 and looks exactly like a pass — in a monorepo whose vitest
workspace excludes a package, **no** change in that package can ever be covered.
The hook names it instead of reporting green. Set `GAUNTLET_REQUIRE_TESTS=1` to
make it block instead.

### Detection

The stack is auto-detected: vitest / jest / pytest for tests, and for typechecking
the repo's own `typecheck` script if it has one, else bare `tsc --noEmit` or
`mypy`. The script is preferred because a workspace root `tsconfig.json` is often
solution-style, where `tsc --noEmit` does not mean what the repo's `tsc -b` means.

**Monorepos work, including the ones with nothing at the root.** Detection collects
every gate it finds rather than stopping at the first, and each gate carries the
file pattern it applies to — so a JS + Python repo gets four gates, and a turn that
touched only `.py` files runs the Python two and skips the JS two entirely.
Typechecks always run before tests, and the first red stops the rest.

When the root has no manifest, detection looks two levels down for `package.json` /
`pyproject.toml` / `pytest.ini` — the `web/` + `api/`, `apps/*`, `packages/*`
layouts — and scopes each gate to that folder's files, running the command from
inside it. Nested gates are only added for the kind the root did not already
provide, so a repo that works today keeps working.

Setting `GAUNTLET_TEST` or `GAUNTLET_TYPECHECK` switches the repo to explicit mode:
auto-detection is off and only what you set runs.

**A missing tool is a skip, not a red.** A fresh clone with no `node_modules`, or a
venv without pytest, would otherwise fail every gate and block every turn — so the
hook reports `skipped: node_modules is missing — run your install first` and gets
out of the way. Only a gate that actually ran and actually failed blocks.

It registers in `.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [
        { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/gauntlet.sh" } ] }
    ]
  }
}
```

## Configuration Reference

Two config files are read, in this order, and the project's wins key by key:

```text
~/.claude/gauntlet.conf          your defaults for every project
<project>/.claude/gauntlet.conf  overrides for this one
```

```bash
GAUNTLET_OFF=1                       # disable entirely
GAUNTLET_TYPECHECK='npm run check'   # "" to skip the gate
GAUNTLET_TEST='npm test -- $FILES'   # $FILES = changed code files
GAUNTLET_CODE_EXT='ts|tsx|py'        # what counts as a change worth checking
GAUNTLET_DEBUG=1                     # print the outcome to stderr every run
GAUNTLET_REQUIRE_TESTS=1             # block when the runner matched 0 test files

# /ship's gate reads its own keys from the same file
GAUNTLET_MAX_LINES=200               # per-file limit; 0 turns the check off
GAUNTLET_SOURCE_EXT='ts|tsx|py'      # what counts as SOURCE — not the same question
GAUNTLET_MUTATE='bash mutate.sh'     # replace per-project mutation detection
GAUNTLET_IGNORE_FILES='*.gen.ts'     # globs that are never gated — see below
GAUNTLET_NO_MUTATE='\.(tsx|jsx)$'    # gated and length-checked, but never mutated
```

`GAUNTLET_IGNORE_FILES` holds files nobody wrote, so the line limit and mutation
both skip them. It defaults to `*.gen.ts *.gen.tsx *.generated.* */migrations/*.py
*/alembic/versions/*.py */components/ui/*.tsx */*.config.*` — a TanStack
`routeTree.gen.ts`, a Django or Alembic migration, and a vendored shadcn component
are all over 200 lines, none of them can be split, and gating them only teaches
`--force`. Every skipped file is named in the output. Patterns match against
`/<path>`, so `*/components/ui/*.tsx` covers the repo root and `apps/web/src`
alike. Set it to `""` to gate everything.

`GAUNTLET_NO_MUTATE` is a different question: those files are still length-checked
and skill-audited, they are just never mutation-tested. It defaults to `.tsx` and
`.jsx`, because a component's mutants are class names, copy and JSX shape and none
of that is behaviour. Set it to `''` to mutate components too.

`GAUNTLET_SOURCE_EXT` is separate from `GAUNTLET_CODE_EXT` on purpose. The Stop
hook asks "did anything worth checking change", so a docs repo sets `CODE_EXT` to
include `.md`. The line limit and mutation ask about source code, where that answer
is wrong.

Set your house rules once in `~/.claude/gauntlet.conf`; only reach for the project
file where a repo does something unusual (or set `GAUNTLET_OFF=1` there to opt one
out).

## The Ship Gate

`ship-gate.sh` checks file length and mutation-tests the changed lines, behind an
exit code. It writes a receipt keyed to the exact content about to ship;
`ship-gate-hook.sh` refuses the publishing commands without a matching one.

**It gates the PR, not every commit.** Its mutation scope is `merge-base..HEAD` —
the whole branch, because the whole branch is what a PR ships. Gating each commit
re-mutated every file the branch had ever touched: one 46-file branch paid fifteen
minutes on every commit. Neither a commit nor a push to a feature branch publishes
anything, so neither is gated. `gh pr create`, `gh pr merge`, and a `git push` from
`main`/`master`/`develop` are.

Run it early when you want the findings before the PR:

```bash
bash .claude/hooks/ship-gate.sh
```

Editing a file invalidates the last receipt on purpose, so a fix is re-gated rather
than riding on the previous verdict. `ship-gate.sh --force` writes a FORCED
receipt, which makes skipping a visible command rather than a private judgement
call.

**Known hole:** a PR opened in the GitHub web UI meets no gate.

## Manual Install

```bash
# Skills
cp -r skills/<skill-name> /path/to/project/.claude/skills/

# Commands
cp commands/<command-name>.md /path/to/project/.claude/commands/

# Subagents — see the command's `requires-agents` frontmatter
cp agents/<agent-name>.md /path/to/project/.claude/agents/
```
