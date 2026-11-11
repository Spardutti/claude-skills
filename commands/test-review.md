---
name: test-review
description: "Check how this project's tests are set up against the installed testing-best-practices rules — every break with a file, a line and the fix, slow-test breaks first. Reads only; runs nothing and changes nothing"
category: Workflow
allowed-tools: Read, Grep, Glob, Bash(ls*), Bash(cat*), Bash(grep*), Bash(wc*), Bash(sed -n*), Bash(awk*), Bash(git ls-files*), Bash(git -C * ls-files*)
argument-hint: "[speed] optional — check only the slow-test rules in FAST-TESTS.md"
---

# Test Review

You check this project's tests against the rules the testing skill already states. Most slow suites break a rule that is written down, and finding that takes reading, not a benchmark.

`$ARGUMENTS` is empty or `speed`. With `speed`, check only `FAST-TESTS.md`.

Work in this project only. Never run a test, a benchmark or the suite, and never edit a file.

## Step 1 — The rules

Read `.claude/skills/testing-best-practices/FAST-TESTS.md`, and `.claude/skills/testing-best-practices/SKILL.md` unless the argument is `speed`. If one you need is missing, say which and stop: the review checks the skill's rules, and it has no copy of its own.

The checklist is each file's `## Rules` section. Quote a rule's text as written. The BAD/GOOD pairs above a rule show what a break looks like. Never check a rule that is not in those sections.

A rule with several parts ("time one empty test, and cut pytest's cache, bytecode…") gets a verdict per part. When both files state the same rule, report its break once, under `FAST-TESTS.md`.

## Step 2 — The setup

Find every way the tests run before reading any test file. A slow suite almost always starts here. Read the ones present:

- runner config: `pyproject.toml`, `pytest.ini`, `package.json` scripts, `vitest.config.*`, `jest.config.*`, `stryker.config.*`, mutmut settings
- framework settings tests load: Django `settings.py` (`TEST_RUNNER`, `DATABASES`, `MIDDLEWARE`), a custom runner class
- shared setup: `conftest.py`, `setupFiles`, `globalSetup`, the database setup module, fixtures, factories, test builders
- launchers: `.husky/`, `lefthook.yml`, `.github/workflows/`, `Makefile`, `.mutmut-run`, `.gauntlet-test`, `.claude/gauntlet.conf`, the gate scripts in `.claude/hooks/`, the compose file, Dockerfile or entrypoint tests run in

Read config and setup files in full. In a large settings file, read the test-relevant parts. Skip baselines, lockfiles, `mutants/` and generated files.

Then write down, for each runner: what launches it, how many workers, and whether the workers share one database. The lock rules (unique values, `DELETE`) only cost time where workers share a database.

## Step 3 — Check every rule

For each rule, give one verdict:

- **breaks** — with `file:line`, after reading that line, and the break costs something here
- **letter only** — the line breaks the text, but the cost cannot happen here, such as a fixed email in a schema only one process uses. Say why.
- **follows** — with the line that shows it
- **not here** — the project has nothing the rule is about, such as no database
- **not readable** — only a run shows it ("time one empty test", "fix flaky tests"), or it is about how work is done, not code

When the skill's fix would change what a test is about, such as a fixed date the test checks, report the break and leave the fix to the user.

Rules about the setup are judged from Step 2. For rules about single tests, such as "one behavior per test", grep the suite for the BAD pattern and read at most 10 hits. Report how many of those 10 break, with at most 3 places. Never report the raw grep count as breaks.

A false break costs more than a miss. When a line does not clearly break the rule, it is not **breaks**.

## Step 4 — Report

When the project has more than one suite, such as pytest and Vitest, group the breaks by suite. Breaks of `FAST-TESTS.md` come first, then the rest. One entry each:

```
1. Always set `jit=off` on a Postgres test database.
   api/tests/database_setup.py:63 — the test database is created and migrated, and JIT stays on
   fix: run `ALTER DATABASE "<name>" SET jit = off` once after it is created
```

Then one short list each for **letter only** (with the reason), **follows**, **not here** and **not readable**.

End with the next step:
- breaks found: offer to fix them one at a time, slow-test breaks first, cheapest first;
- no `FAST-TESTS.md` breaks, and the suite is still slow: `/optimize`, which measures.

## Rules

- NEVER run a test, the suite, a benchmark or a mutation run.
- NEVER edit a file. The user picks what gets fixed.
- NEVER check a rule that is not in the skill's Rules sections.
- NEVER report a break without a `file:line` you read.
- NEVER call a lock rule a break where no two workers share a database; that is **letter only**.
- NEVER read into another project.
- ALWAYS read every launcher and setup file before the test files.
- ALWAYS put `FAST-TESTS.md` breaks first.
