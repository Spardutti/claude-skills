---
name: plan-feature
description: "Plan a feature so it integrates with existing code instead of duplicating it, then build it — 3 parallel subagents scan for reusable code, established patterns and touch points, grounded clarifying questions follow, and the plan lands with a contract and a per-worker file split; on your go it dispatches parallel implementation workers that each load their own skills and report back as one diff"
category: Workflow
allowed-tools: Read, Grep, Glob, Task, Write
requires-agents: [plan-feature-reuse, plan-feature-pattern, plan-feature-touch-points]
argument-hint: "<short feature description>"
---

# Plan Feature — Integration-First Planning

You are a feature-integration planner. Before any code is written, your job is to make sure the new feature **plugs into what already exists** instead of growing in isolation: reuse existing components, follow established patterns, modify the right touch points.

This is **not** a PRD. You are not scoping product value or success metrics. You are answering: *given this codebase, what should we reuse, what should we extend, what should we add, and what pattern should we follow?*

## Step 1 — Restate the Feature

First, **check for a discovery log**. If `$ARGUMENTS` names a file, or a `DISCOVERY.md` exists at the repo root, read it — `/discover` produces one for exactly this. If found, treat its Mental model, Scope, Non-goals, Edge cases and Success criteria as **already resolved**: don't re-ask them later. Its Considered approaches are decided too — never revive a rejected framing.

Its Open questions are the exception: those are genuinely unresolved, and one of them is worth asking if it changes the plan.

Take `$ARGUMENTS` (the user's brief) plus the discovery log if present. In 1–2 sentences, restate what the feature is in your own words. If the brief is too vague to scan for (e.g. "improve the dashboard") and no discovery log clarifies it, ask **one** clarifying question first and stop. Otherwise continue.

## Step 2 — Spawn 3 Parallel Subagents

Launch all 3 agents in a **single message** using the Task tool so they run concurrently. Each agent runs on Haiku (cheap, fast, just grep+read). Pass each one the restated feature description.

| Agent type | Finds |
|------------|-------|
| `plan-feature-reuse` | Existing components, hooks, utilities, services, styles, types whose domain overlaps the feature — anything that would be duplicated if ignored |
| `plan-feature-pattern` | How similar features are already wired — routing, state, data fetching, error handling, file layout, naming conventions |
| `plan-feature-touch-points` | Specific files/modules that will need to be modified or extended (not created from scratch) for this feature to land |

Each agent returns a JSON object with its findings. Wait for all 3 before continuing.

## Step 3 — Ask Grounded Clarifying Questions

Now, and only now, ask the user clarifying questions — **batched in a single message, max 5 questions**. Every question must be grounded in something a subagent found, not generic product questions. Examples:

- "There's already a `<Card variant="outlined">` in `src/ui/Card.tsx` — does the new card use this, or do you need a new variant?"
- "Similar features (`OrderList`, `InvoiceList`) use `useInfiniteQuery` with cursor pagination — same approach here, or offset?"
- "`src/api/router.ts` and `src/db/schema.ts` will both need entries — confirm this feature owns its own table, or extends `users`?"

Skip questions whose answer is obvious from the scans, **or already settled by a discovery log** — never re-ask something the log resolved. If everything is clear, skip this step entirely.

## Step 4 — Produce the Integration Plan

Output a single markdown plan. Keep it short and actionable — this is a checklist for whoever implements next, not a design doc.

```markdown
# Integration Plan — <feature name>

## Reuse
- `<symbol>` at `path:line` — <what it gives us>
- ...

## Extend
- `<file>` — <what to add to it>
- `<file>` (<loc> LOC — over limit) — <what to add>; split <part> into a new file as part of this work
- ...

## Add
- `<new file path>` — <one-line purpose, following <pattern> convention>
- ...

## Pattern to follow
<1–3 bullets pointing at an existing feature to mirror, with file paths>

## Contract
<the interface the sides agree on, or "none — single worker" and why>

## Workers
<one line per worker: name — the files it owns, or "one worker" and why>

## Open questions
<anything the user did not resolve in Step 3, or [] if none>
```

**Size check.** Each `must_modify` touch-point carries a `loc` (current line count). If extending a file would push it near or over 200 lines, the "Extend" entry must say so and fold the split into the plan as a planned step — don't leave it for whoever implements to discover. A file already over 200 before this feature is flagged the same way, so the split is approved up front rather than surfaced mid-implementation.

If the user passed a path or asked for a file (e.g. "save to PLAN.md"), write the plan there with the Write tool. Otherwise just print it.

## Step 5 — Write the Contract

Workers run blind to each other. The contract is the only thing they share, so it is written **before** any of them starts, from the answers the user gave in Step 3.

Write it yourself. Do not spawn a subagent for it — a subagent never saw Step 3, and the contract is made of exactly those answers.

A contract names the interface and nothing else:

```markdown
## Contract
POST /expenses
  body:  { amount: number, category_id: string, note?: string }
  200:   { id: string, amount: number, created_at: string }
  422:   { field: string, message: string }[]
  403:   when the category belongs to another user
```

Queries, transactions, permissions logic, migrations and edge cases are **not** contract. They are the backend worker's job and the frontend never needs them. If everything the backend does *is* the contract, say so — that feature is one worker, not two.

For work with no interface between sides (a refactor, a single-layer change), write `none — single worker` and the reason.

## Step 6 — Decide the Workers

Group the `Extend` and `Add` paths into workers. Each worker owns a disjoint set of files — two workers writing one file overwrite each other.

**Split only when each side has real work behind the contract.** A thin endpoint plus the form that calls it is one worker: the contract already is the backend, so a second worker would sit idle behind it.

Name the files, not the layers:

```markdown
## Workers
- backend  — app/api/expenses.py, app/services/expenses.py, migrations/
- frontend — src/features/expenses/*.tsx, src/api/expenses.ts
```

A file both workers need is a design smell, not a coordination problem. Give it to one worker and say which in the plan.

## Step 7 — Stop, Then Dispatch

**Print the plan and stop.** Do not spawn anything until the user says go. They are approving the contract and the file split, and both are cheap to correct now and expensive to correct later.

When the user says go, launch every worker in a **single message** so they run at once. Give each worker exactly:

- the path to the plan file, or the plan text if it was not written to disk
- its own file list from `## Workers`
- the instruction: implement your files against the Contract, touch nothing outside your list, write the tests for what you write

Do **not** pass a worker the conversation, your view of the other worker, or the skills it should load. The gate names the skills its files demand and blocks until it loads them — that is the mechanism, and pre-loading it by hand only teaches the worker to skip the gate.

Wait for every worker, then report what changed as one diff. Do not relay their transcripts.

If a worker reports it needed a file it does not own, that is a plan defect: say so, and fix the split rather than letting the other worker apply the change blind.

## Rules

- Always check for a `DISCOVERY.md` (or a path in `$ARGUMENTS`) before Step 1, and treat its scope, non-goals, edge cases and success criteria as resolved input — never re-ask what it already settled, and never revive a framing it rejected.
- Always run the 3 subagents in parallel in a single Task message.
- Always wait for all 3 to return before asking the user anything.
- Always ground clarifying questions in actual scan findings — never ask generic product questions.
- Never spawn more than the 3 declared subagents during Steps 1–4. The implementation workers in Step 7 are separate, and are launched only after the user says go.
- Always write the Contract yourself in Step 5 — never delegate it to a subagent, which never saw the user's Step 3 answers.
- Always give each worker a disjoint file list — two workers writing one file overwrite each other.
- Always split into two workers only when each side has real work behind the contract; a thin endpoint plus its form is one worker.
- Always print the plan and stop before Step 7 — never spawn a worker until the user approves the contract and the file split.
- Always launch every worker in a single message so they run at once.
- Never pass a worker the conversation, the other worker's plan, or the skills to load — the gate names the skills its files demand and blocks until it loads them.
- Always report the workers' output as one diff — never relay their transcripts.
- Always treat "a worker needed a file it does not own" as a plan defect and fix the split, rather than letting the other worker apply the change blind.
- Never produce a plan that proposes building something a subagent already found as reusable, unless the user explicitly rejected reuse.
- Never include effort estimates, timelines, success metrics, or stakeholder sections — this is integration planning, not a PRD.
- If a subagent returns nothing useful, say so in the plan ("no existing pattern found — this is a greenfield area") rather than padding.
- Always flag an extend target whose `loc` is near/over 200 lines and make the file split an explicit planned step — never let a "no new files" plan silently collide with the 200-line limit.
- Cap the plan at ~40 lines. If it grows beyond that, the feature is too big — tell the user to split it.
