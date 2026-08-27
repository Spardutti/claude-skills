---
name: deep-review
description: "Multi-agent deep code review — spawns 5 parallel agents to catch guard bypasses, lost async state, wrong-table queries, dead references, and protocol violations"
category: Workflow
allowed-tools: Bash(git *), Read, Grep, Glob, Task
requires-agents: [deep-review-guard-bypass, deep-review-state-persistence, deep-review-cross-table, deep-review-dead-reference, deep-review-protocol-conformance]
argument-hint: "[base-branch] defaults to develop or main"
---

# Deep Review — Multi-Agent Code Review

You are a code review orchestrator. Catch bugs that unit tests miss — cross-system state issues, lost flags, wrong table queries, bypassed guards, stale references to deleted code.

## Step 1 — Gather the Diff

```bash
BASE=$ARGUMENTS  # if empty, auto-detect below
# auto-detect base branch
git merge-base HEAD develop 2>/dev/null || git merge-base HEAD main 2>/dev/null
git diff $BASE...HEAD --name-only          # changed files list
git diff $BASE...HEAD                       # full diff
```

Do **not** read the changed files yourself. Every agent has `Read`/`Grep`/`Glob` and pulls the
surrounding context its own lens needs — pre-reading here is serial work before any agent starts,
and each agent re-reads what it needs anyway. On a large diff that pre-read is the bulk of the
wall-clock, paid once by you and again by all five.

You pass the diff and the file list. They fetch the rest.

## Step 2 — Spawn 5 Parallel Subagents

Launch all 5 agents in a **single message** using the Task tool so they run concurrently. Pass each agent the full diff and the list of changed files in its prompt — nothing more. Each agent has its own system prompt, tool set, and model, and reads whatever else it needs itself.

| Agent type | Catches |
|------------|---------|
| `deep-review-guard-bypass` | Code paths that reach a protected resource without passing the guard (retries, fallbacks, async dispatch) |
| `deep-review-state-persistence` | Flags/modes lost across async boundaries (`task.delay`, `on_commit`, queue-then-promote) |
| `deep-review-cross-table` | Queries that check only one of a parallel model pair (e.g. `DataImportSubTask` but not `EnrichmentSubTask`) |
| `deep-review-dead-reference` | Executable references to deleted/renamed symbols (imports, `patch()` targets, task names) |
| `deep-review-protocol-conformance` | Implementations or test mocks that don't match a Protocol/ABC/interface signature |

Each agent returns a JSON array of findings with `severity`, `file`, `line`, `what`, `why`, `fix`.

The 5 agents run in the background. As soon as they are launched, tell the user what is running and
roughly how long it should take, and that they can keep working in the meantime — never sit idle in
front of the user waiting on them. Aggregate and report when they land.

## Step 3 — Severity Classification

Agents self-classify as CRITICAL / WARNING / INFO:

| Level | Meaning |
|-------|---------|
| **CRITICAL** | Data corruption, silent failures, or bypassed security in production |
| **WARNING** | Edge case that could cause issues under specific conditions |
| **INFO** | Cosmetic or low-impact observation |

## Step 4 — Aggregate and Report

Merge all 5 JSON arrays. Present a single unified report:

```markdown
# Deep Review Report

## CRITICAL (X issues)
### [Agent Name] — Short description
- **File:** path/to/file.py:42
- **What:** One sentence describing the bug
- **Why it matters:** One sentence on production impact
- **Fix:** Concrete suggestion

## WARNING (X issues)
...

## INFO (X issues)
...

## Summary
- X files reviewed
- X issues found (Y critical, Z warnings, W info)
- Agents: Guard Bypass ✓ | State Persistence ✓ | Cross-Table ✓ | Dead Reference ✓ | Protocol ✓
```

If any CRITICAL issues exist, end with a clear **"BLOCKING — fix before merge"** list.

## Rules

- Always pass the diff + file list and nothing else — never pre-read changed files for the agents; they read what they need, and pre-reading is serial time paid twice.
- Always spawn all 5 agents in a single message for parallel execution.
- Always classify every finding as CRITICAL, WARNING, or INFO.
- Always report file paths with line numbers (`file.py:42`).
- Always include a concrete fix suggestion for CRITICAL findings.
- Never flag intentional bypasses that are clearly documented.
- Never flag references in comments, docstrings, or migration files.
- Never report more than 3 INFO items per agent — keep signal-to-noise ratio high.
- If no issues are found, say so explicitly — don't invent findings.
