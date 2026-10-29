---
name: add-rule
description: "Turn a mistake Claude keeps making — from /code-review, the skills audit or the ship gate — into a check on every edit: a text rule when a pattern can catch it, a lesson shown on matching files when it needs judgment. Both live in .edit-rules.json, never in CLAUDE.md"
category: Workflow
allowed-tools: Bash(node .claude/hooks/lint-ratchet.mjs*), Bash(node scripts/lint-ratchet.mjs*), Bash(node .claude/hooks/diary-check.mjs*), Bash(node scripts/diary-check.mjs*), Bash(git *), Read, Grep, Glob, Edit, Write
argument-hint: "[the mistake, in plain words] — none reads the saved review findings"
---

# Add Rule — Make a Mistake Impossible to Repeat

The user names a mistake from a review, a gate, or their own reading. You turn it
into an entry in `.edit-rules.json` at the repo root. The edit hook reads that file
after every Write or Edit, so the next time Claude makes the mistake, it hears
about it at once instead of in review.

`RATCHET` below is `.claude/hooks/lint-ratchet.mjs`, or `scripts/lint-ratchet.mjs`
in the claude-skills repo itself.

## Step 0 — No argument: find what keeps coming back

Three diaries record findings: `.claude/review-findings.jsonl` (every `/code-review` run as a
subagent), `.claude/skill-flags.jsonl` (every `/ship` skills audit) and
`.claude/gate-findings.jsonl` (every ship gate FAIL: test gaps, surviving mutants, misplaced files).
Read them through the script, which drops clean audits and trunk re-runs, then reset the count:

```bash
node .claude/hooks/diary-check.mjs --entries
node .claude/hooks/diary-check.mjs --mark
```

(`scripts/diary-check.mjs` in the claude-skills repo.) Mark whatever you find, so `/ship` does
not offer these entries again.

Group the findings by the mistake behind them, not by wording. A surviving mutant
is a test that was never written, so group those by the kind of test missing: the
error path, both sides of a boundary, a default value, a removed call nobody
checks. Count a mistake once per `branch`: the same finding twice on one branch is
one mistake not fixed yet, not a pattern. List at most three that came up on **two
or more branches**, each with its count and one example, and ask which to turn
into a check. Nothing repeated → say so and stop.

A diary line is what a reviewer *said*, not proof. Before counting a finding, open
the code it names and confirm the mistake is really there; drop the ones that are not.

A test-gap lesson is scoped to test files, e.g. `"files": "\\.test\\.tsx?$"`, so
Claude reads it while writing the test, before the gate runs.

## Step 1 — Find real examples

Find two or three real places in this repo where the mistake happened, and one
place where the same code is written well. Use the review, `git log -p`, or Grep.
If you cannot find a real example, ask the user for one. Never invent the example.

## Step 2 — Decide: rule or lesson

- **Rule** — one regular expression over a single file finds every bad example
  and none of the good code. Example: a header comment, a test name with "and".
- **Lesson** — it needs judgment about meaning. Example: "route tests mock the
  data layer here", "check the session before any work".

When unsure, try the rule first. If Step 4 shows false positives you cannot
remove, make it a lesson.

## Step 3 — Write the entry

```json
{
  "text": [
    {
      "id": "one-behavior-per-test",
      "files": "\\.(test|spec)\\.[jt]sx?$",
      "pattern": "\\b(?:it|test)\\(\\s*[\"'`][^\"'`]*\\band\\b",
      "message": "The test name joins two behaviors with 'and'. Split it into two tests.",
      "bad": "it(\"scrolls and focuses\", () => {})",
      "good": "it(\"scrolls to the end\", () => {})"
    }
  ],
  "lessons": [
    {
      "id": "route-tests-mock-data",
      "files": "^app/api/.*\\.test\\.ts$",
      "message": "Route tests here mock the data layer; there is no database suite."
    }
  ]
}
```

- `files` is a regular expression over the path from the repo root.
- `bad` and `good` are copied from the real examples in Step 1, trimmed.
- `message` says what to do, in one sentence a tired person can act on.
- `pattern` takes optional `flags` (`m`, `i`, `s`); `g` is always added.
- A `*.registry.yaml` whose `never` is this mistake: end `message` with
  `see <that file>`, and add the id to the entry's `rules: [...]`.

## Step 4 — Prove it (rules only)

```bash
node RATCHET --selftest
node RATCHET --baseline <id>
```

1. `--selftest` must pass: the rule catches `bad` and passes `good`.
2. `--baseline <id>` records the old hits of this rule only. Read the new lines in
   `.lint-baseline`, then open three of the files. If any hit is not the mistake,
   tighten the pattern and run both commands again.

## Step 5 — Report

Say what was added, rule or lesson, and for a rule how many old hits the baseline
holds. Old hits are not blocked; Claude gets a note to fix them when it edits that
file.

## BAD / GOOD

```text
BAD:  "pattern": "and"                       ← flags every word "and" in every file
GOOD: "pattern": "\\b(?:it|test)\\(\\s*[\"'`][^\"'`]*\\band\\b"   ← only inside a test name
```

## Rules

- Never write a rule or a lesson into CLAUDE.md. It loads on every session.
- Always copy `bad` and `good` from real code in this repo.
- Never ship a rule whose `--selftest` fails.
- Always run `--baseline <id>`, never a bare `--baseline`, so other rules' debt cannot be banked.
- Always prefer a rule to a lesson; a lesson is the fallback, not the default.
- Always link a rule to the registry entry it guards: the file in `message`, the id in `rules`.
- Keep a lesson to one sentence, scoped by `files` to the code it is about.
