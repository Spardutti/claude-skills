---
name: deep-review
category: Quality
description: "Multi-agent deep code review on the current branch. Spawns 5 parallel subagents to catch cross-system bugs that unit tests miss: guard bypasses, lost state across async boundaries, wrong-table queries, dead references, and protocol violations."
---

# Deep Review — Multi-Agent Code Review

Invoke with `/deep-review`. Catches bugs that unit tests miss — cross-system state issues, lost flags, wrong table queries, bypassed guards, stale references to deleted code.

## Step 1 — Gather the Diff

```bash
# detect base branch
BASE=$(git merge-base HEAD develop 2>/dev/null || git merge-base HEAD main 2>/dev/null || echo "main")
git diff $BASE...HEAD --name-only          # changed files list
git diff $BASE...HEAD                       # full diff
```

Read every changed/created file in full. The diff alone is not enough — agents need surrounding context to trace callers, check tables, and verify interfaces.

## Step 2 — Spawn 5 Parallel Subagents

Launch all 5 agents in a **single message** so they run concurrently. Each agent receives: the full diff, the list of changed files, and instructions to read any additional files it needs.

### Agent 1 — Guard Bypass Audit

**Goal:** For every function that enforces a constraint (capacity check, permission check, rate limit, validation), trace every caller. Flag any code path that reaches the protected resource WITHOUT going through the guard.

```
Prompt the agent:
- Identify every guard function in the changed code (permission checks, rate limits,
  capacity checks, validation functions)
- For each guard, grep for all call sites of the resource it protects
- Flag any caller that reaches the resource without passing through the guard
- Check retry paths, fallback paths, and async dispatch paths — these are where
  bypasses hide
```

**Example bug it catches:** "retry path calls `dispatch_job` directly instead of `try_dispatch_or_queue`, bypassing the per-user capacity check."

**Do NOT flag:** Intentional admin/superuser bypasses that are clearly marked. Internal helper functions called only from guarded parents.

### Agent 2 — State Persistence Audit

**Goal:** For every flag, status, or mode passed as a function parameter, check if it survives across async boundaries (Celery task dispatch, `transaction.on_commit`, signals, Beat scheduling, queue-then-promote patterns).

```
Prompt the agent:
- List every parameter that carries state (flags like resume=True, mode="partial",
  status enums, config dicts)
- Trace each parameter through async boundaries: task.delay(), .apply_async(),
  transaction.on_commit(), signal handlers, scheduled jobs
- Flag any parameter that is used at the call site but not serialized into the
  async payload
- Check queue/promote patterns where a job is queued then later dispatched —
  verify all original parameters survive the round-trip
```

**Example bug it catches:** "`resume=True` is passed to `try_dispatch_or_queue` but when the job is queued and later promoted, the flag is lost and `setup_fn` runs again creating duplicate subtasks."

**Do NOT flag:** Parameters intentionally dropped (documented with a comment). Boolean flags with matching defaults that make the omission safe.

### Agent 3 — Cross-Table Consistency Audit

**Goal:** For every query that counts or filters rows, verify it queries the correct table for the context. When multiple models share a pattern, flag any query that only checks one table but claims to cover both.

```
Prompt the agent:
- Identify every .count(), .filter(), .exists(), .aggregate() in changed code
- For each query, check: does it target the right model for the context?
- Look for parallel model pairs (DataImportSubTask/EnrichmentSubTask,
  UserNotification/SystemNotification, DraftOrder/Order) — flag queries
  that only check one when the logic applies to both
- Check slot/capacity calculations: are all contributing tables included?
```

**Example bug it catches:** "`compute_dispatch_slots` queries `DataImportSubTask` but enrichment subtasks live in `EnrichmentSubTask`, so enrichment concurrency is never enforced."

**Do NOT flag:** Queries that are intentionally scoped to one model (e.g., a view that only shows import tasks). Queries behind an `if` branch that already discriminates by type.

### Agent 4 — Dead Reference Audit

**Goal:** After any deletion or rename, search for every import, string reference, `patch()` target, and Celery task name that still points at the old name. Only flag executable code — not comments or docstrings.

```
Prompt the agent:
- From the diff, identify every function/class/module that was deleted or renamed
- For each, grep the entire repo for: imports, string references in patch(),
  task decorators @shared_task(name=...), URL routes, signal connections,
  factory registrations
- Exclude comments, docstrings, and migration files (historical references)
- Flag any executable reference to the old name
```

**Example bug it catches:** "`api/tasks.py` still imports `dispatch_enrichment_orchestrator` which was deleted in the current branch."

**Do NOT flag:** References in git history, comments explaining what was removed, migration files, changelog entries.

### Agent 5 — Protocol/Interface Conformance

**Goal:** For every Protocol, ABC, or interface, verify all concrete implementations match the required signatures. For every place the protocol is consumed, verify the method exists on all registered implementations.

```
Prompt the agent:
- Identify every Protocol, ABC, or TypedDict in changed code
- For each, find all concrete implementations (classes that inherit or register)
- Verify method signatures match: name, parameter count, parameter types, return type
- Check consumption sites: where the protocol type is used, verify all called
  methods exist on every implementation
- Check test mocks: MagicMock/patch setups must configure every method the
  production code calls
```

**Example bug it catches:** "Orchestrator calls `job.count_active_subtasks()` but the `MagicMock` in tests doesn't set it up, causing `AttributeError` in test runs."

**Do NOT flag:** Optional protocol methods marked with `@runtime_checkable` and guarded with `hasattr`. Methods only used behind feature flags that are currently off.

## Step 3 — Severity Classification

Each agent classifies findings as:

| Level | Meaning | Examples |
|-------|---------|---------|
| **CRITICAL** | Will cause data corruption, silent failures, or bypassed security in production | Guard bypass on auth check, lost flag causing duplicate writes, wrong-table query miscounting capacity |
| **WARNING** | Edge case that could cause issues under specific conditions | State lost only on retry after timeout, dead reference in rarely-used admin command |
| **INFO** | Cosmetic or low-impact observation | Unused import from renamed module, mock missing a method only used in skipped test |

## Step 4 — Aggregate and Report

Collect all agent results. Present a single unified report:

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

- Always read changed files in full — never review from diff alone.
- Always spawn all 5 agents in a single message for parallel execution.
- Always include negative examples in each agent prompt to reduce false positives.
- Always classify every finding as CRITICAL, WARNING, or INFO.
- Always report file paths with line numbers (`file.py:42`).
- Always include a concrete fix suggestion for CRITICAL findings.
- Never flag intentional bypasses that are clearly documented.
- Never flag references in comments, docstrings, or migration files.
- Never report more than 3 INFO items per agent — keep signal-to-noise ratio high.
- If no issues are found, say so explicitly — don't invent findings.
