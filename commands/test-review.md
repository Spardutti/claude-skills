---
name: test-review
description: "Write-then-verify test review — write tests in your normal flow, then mechanical gates (red-green + mutation) plus an isolated read-only reviewer subagent prove each test would actually catch a regression instead of rubber-stamping it"
category: Workflow
allowed-tools: Bash, Read, Grep, Glob, Edit, Write, Task
requires-agents: [test-review-gates, test-review-quality]
argument-hint: "[test file, source file, or empty for the diff]"
---

# Test Review — Write Then Verify

You orchestrate a test-verification loop. The point is NOT to approve tests — it's to
prove each test would fail if the behavior it claims to cover broke. You write tests in
your normal flow (code first, tests after — this is **not** TDD); deterministic gates and
an isolated reviewer do the proving. A green suite is never the finish line.

## Step 0 — Detect the stack

Identify the test runner and how to run (a) the whole suite and (b) a single file. Check
whether a mutation-testing tool is available:

| Stack | Mutation tool |
|-------|---------------|
| JS / TS | Stryker (`npx stryker run`) |
| Python | `mutmut` or Cosmic Ray |
| Java | PIT (`pitest`) |

If no mutation tool is installed, note it — Step 2 degrades to red-green-only. Do not
install tools without asking.

## Step 0.5 — Resolve scope

Decide what to review, in this order:

1. **Path argument given** → review exactly that. A test file is used as-is; a source
   file is mapped to its tests (mapping below).
2. **No argument, working tree has changes** → scope to the diff. Collect changed source
   and test files, then map each changed source file to its tests by (a) naming convention
   (`foo.ts`→`foo.test.ts`, `foo.py`→`test_foo.py`, etc.) and (b) tests that import the
   changed module.
3. **No argument, clean tree** → STOP and ask which file or directory to review. Never
   default to the whole suite.

Before running anything, print the resolved set:
`Reviewing N tests: <list> — pass a path to change this.`
Any changed source file with **no** matching test is reported as a coverage gap in Step 4
(a finding, not a silent skip).

## Step 1 — Confirm the tests exist

The code already exists; tests come after. Confirm the in-scope tests are written and the
suite is green. Do not require test-first. If tests are missing for in-scope code, note
the gap — don't block.

## Step 2 — Mechanical gates (objective, no judgment)

Run the in-scope suite — it must pass before verifying. Then run the **red-green**
(implementation-removal) and **mutation** gates per source unit. These gates fault source
files, and they're embarrassingly parallel — so **how** you run them depends on scope:

**One source unit → run inline (serial).** Spinning up a worktree isn't worth it for a
single file.

- **Red-green** — capture the source file's original content, apply a single fault to the
  unit (mutation tool preferred; otherwise manually break one function — invert a
  condition, return a constant, drop an error branch), run its targeting tests, and record
  any test that **stays green**. Restore by writing the captured original back — **never
  `git checkout`** in the real tree, which would discard uncommitted work. A test green
  without a working implementation asserts nothing.
- **Mutation** — if a tool is available, run it on the in-scope source and capture
  surviving mutants (`file:line` + the mutation).

Always restore every source file to its original state before continuing, even if a test
run errors. The working tree must be byte-identical to how you found it.

**More than one source unit → shard across `test-review-gates` (parallel).** Faulting
source in the real tree can't be parallelized safely, so spawn one `test-review-gates`
agent per shard via Task — each runs in its own disposable worktree and mutates only its
copy. Group units into roughly balanced shards (one unit per shard is fine). Pass each:

- **Shard** — its source files, each with targeting test file(s).
- **Sync list** — every changed file (source + tests) in the working tree, plus the
  absolute **repo root**, so the agent can sync its worktree to your uncommitted state.
- **Commands** — how to run the whole suite, a single test file, and the mutation tool
  (or `none`), from Step 0.

Merge `redGreenFailures` and `survivingMutants` across all shards. If any shard returns
`suiteGreen: false`, stop and surface its failure — gating a red suite is meaningless. The
worktrees are discarded on return, so the real tree is never mutated.

## Step 3 — Independent reviewer (isolated subagent)

Spawn the `test-review-quality` agent via Task. Pass it: the in-scope test and source
paths, the red-green failures (tests that stayed green), and the surviving mutants. It runs
read-only — it cannot see how you wrote the tests and cannot edit them — and returns a
per-test JSON verdict (`keep` / `rewrite` / `reject`) plus a `gaps` list.

## Step 4 — Report and revise

Present a unified report:

```markdown
# Test Review

## Reject (X) — these tests prove nothing
### <file::test name>
- **Verifies:** <behavior the reviewer derived from the body>
- **Catches:** <bug it would catch, or "nothing — stays green without the implementation">
- **Fix:** <what to change>

## Rewrite (X) — real but weak
...

## Gaps (X) — surviving mutants / untested behavior
- <file:line> — <mutation that no test killed>

## Summary
- N tests reviewed · K keep · R rewrite · J reject · G gaps
```

For every `reject` / `rewrite` and every gap, fix the tests (your normal writing flow,
Edit/Write). Then re-run **Step 2–3 on the changed tests only**. Stop when: the suite is
green, no test survives implementation-removal, no mutant survives, and the reviewer
returns all `keep`.

## Rules

- Always keep the roles separate: you write, the command runs the tools, the subagent judges.
- Always shard the gates across parallel `test-review-gates` worktrees when more than one source unit is in scope; run inline only for a single unit.
- Always restore inline-mutated source from a saved copy — never `git checkout` in the real tree (it loses uncommitted work). Inside a `test-review-gates` worktree, `git checkout` is safe.
- Always print the resolved scope before running, and surface in-scope code with no test as a gap.
- Never close the loop on a green suite alone — the red-green and mutation gates are the gate.
- Never ship a test the reviewer can't tie to a concrete bug it catches.
- Never default to reviewing the whole suite — scope to the argument or the diff, or ask.
- If no mutation tool is installed, run red-green only and say so in the report.
