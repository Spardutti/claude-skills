---
name: refactor
description: "Find code files over 200 lines and refactor them into smaller modules"
category: Workflow
allowed-tools: Glob, Bash(wc *), Read, Edit, Write, Grep
argument-hint: "[file-path] or leave empty to scan entire project"
---

# Refactor Oversized Files

You are a code refactoring assistant. Find code files exceeding 200 lines and split them into smaller, focused modules.

## Step 1 — Find Oversized Files

If the user passed a file path in `$ARGUMENTS`, skip the scan and go directly to Step 3 for that file.

Otherwise, scan the project. Use **Glob** to find source files, then **Bash `wc -l`** to count lines.

Glob patterns to search (one call per pattern):

```
**/*.ts  **/*.tsx  **/*.js  **/*.jsx
**/*.py  **/*.go   **/*.rs  **/*.java
**/*.rb  **/*.php  **/*.vue **/*.svelte
```

**Exclude** from results: `node_modules`, `dist`, `build`, `.next`, `__pycache__`, `vendor`, `target`, `.git`, `*.d.ts`, `*.min.*`, `*.gen.*`, lock files.

For each batch of matched files, count lines:

```bash
wc -l file1.ts file2.ts file3.ts
```

Collect all files where line count > 200.

## Step 2 — Report Findings

Present a sorted table (most oversized first):

```
Files exceeding 200 lines:

  File                              Lines   Over by
  src/services/api.ts                342     142
  src/components/Dashboard.tsx       267      67
  src/utils/helpers.py               215      15

  Total: 3 files need refactoring
```

If no files exceed 200 lines:

```
All files are within the 200-line limit. Nothing to refactor.
```

Stop here if nothing found.

## Step 3 — Plan the Refactor

**1–3 files**: propose fixing **all** in one pass.
**4+ files**: propose fixing **one at a time**, starting with the most oversized.

For each file, read it fully, then show a brief plan:

```
Plan for src/services/api.ts (342 lines):
  → Extract auth endpoints → src/services/auth-api.ts
  → Extract user endpoints → src/services/user-api.ts
  → Keep shared client setup → src/services/api.ts (~45 lines)
```

**Ask the user to confirm before proceeding.**

## Step 4 — Refactor

For each approved file:

1. **Read the full file** — understand every export, import, and dependency
2. **Group by responsibility** — related functions/classes/exports that belong together
3. **Create new files** — each under 200 lines, single clear purpose
4. **Update all imports** — use Grep to find every file importing from the refactored module, then fix paths
5. **Re-export only if needed** — if the original file was a public barrel, keep re-exports

### Split Patterns

**Service/API file** → by resource:
```
api.ts (340 lines) →
  auth-api.ts   (80 lines)
  user-api.ts   (90 lines)
  api-client.ts (40 lines)
```

**Component file** → by sub-component and hooks:
```
Dashboard.tsx (280 lines) →
  Dashboard.tsx        (60 lines)  ← composition
  DashboardHeader.tsx  (50 lines)
  DashboardStats.tsx   (70 lines)
  useDashboardData.ts  (55 lines)
```

**Utility file** → by domain:
```
helpers.py (250 lines) →
  string_helpers.py (70 lines)
  date_helpers.py   (80 lines)
```

**Class file** → extract collaborators:
```
OrderProcessor.java (300 lines) →
  OrderProcessor.java  (80 lines)  ← orchestration
  OrderValidator.java  (70 lines)
  PriceCalculator.java (60 lines)
```

## Step 5 — Verify

After each refactor:

1. Count lines in all new/modified files — confirm all under 200
2. Grep for old import paths — verify none are broken
3. Report:

```
Refactored src/services/api.ts (342 → 45 lines):
  ✔ Created src/services/auth-api.ts (80 lines)
  ✔ Created src/services/user-api.ts (90 lines)
  ✔ Updated 12 imports across 8 files
```

## Step 6 — Summary

```
Refactoring complete:
  Files refactored: 3
  New files created: 9
  Imports updated: 28
  All files now under 200 lines ✔
```

## Rules

- ALWAYS read the full file before proposing a split
- ALWAYS update every import referencing moved exports — use Grep to find them all
- ALWAYS keep resulting files under 200 lines
- ALWAYS ask the user before starting each refactor
- NEVER delete or rename exports — everything must remain importable
- NEVER change function signatures or behavior — structural refactor only
- NEVER refactor test files unless also over 200 lines
- NEVER create barrel files unless the original was already one
- If a file is only slightly over (201–220), extract one small piece instead of a full split
