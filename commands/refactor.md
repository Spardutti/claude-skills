---
name: refactor
description: "Find code files with size, complexity, duplication, or coupling issues and refactor them"
category: Workflow
allowed-tools: Glob, Bash(wc *), Read, Edit, Write, Grep
argument-hint: "[file-path] or leave empty to scan entire project"
---

# Refactor Code Issues

You are a code refactoring assistant. Find files with **size**, **complexity**, **duplication**, or **coupling** problems and refactor them into clean, focused modules.

## Refactoring Triggers

| Trigger        | Threshold                                                    |
|----------------|--------------------------------------------------------------|
| **Size**       | File exceeds 200 lines                                       |
| **Complexity** | Function has 3+ nesting levels, 5+ params, or 4+ branches   |
| **Duplication** | Near-identical code blocks (10+ lines) across 2+ files      |
| **Coupling**   | File imports from 8+ modules, or circular dependency exists  |

## Step 1 — Detect Issues

If the user passed a file path in `$ARGUMENTS`, skip the scan and go directly to Step 3 for that file.

Otherwise, scan the project. Use **Glob** to find source files:

```
**/*.ts  **/*.tsx  **/*.js  **/*.jsx
**/*.py  **/*.go   **/*.rs  **/*.java
**/*.rb  **/*.php  **/*.vue **/*.svelte
```

**Exclude**: `node_modules`, `dist`, `build`, `.next`, `__pycache__`, `vendor`, `target`, `.git`, `*.d.ts`, `*.min.*`, `*.gen.*`, lock files.

### Size check
Count lines with `wc -l` on matched files. Flag files > 200 lines.

### Complexity check
Read files and look for:
- **Deep nesting**: 3+ levels of `if/for/while/match/switch` inside a function
- **Too many params**: functions with 5+ parameters
- **Excessive branching**: functions with 4+ `if/else if/elif/case` branches

**BAD** — deeply nested, hard to follow:
```ts
function process(items) {
  for (const item of items) {
    if (item.active) {
      if (item.type === "order") {
        for (const line of item.lines) {
          if (line.qty > 0) {
            // actual logic buried 4 levels deep
          }
        }
      }
    }
  }
}
```

**GOOD** — early returns + extracted helpers:
```ts
function process(items) {
  const active = items.filter(i => i.active && i.type === "order");
  for (const item of active) {
    processOrderLines(item.lines);
  }
}

function processOrderLines(lines) {
  for (const line of lines.filter(l => l.qty > 0)) {
    // logic at 1 nesting level
  }
}
```

### Duplication check
Use **Grep** to find repeated patterns. Look for:
- Functions/methods with near-identical bodies across files (10+ matching lines)
- Copy-pasted blocks with only variable name differences

**BAD** — same logic in two files with different variable names:
```ts
// src/routes/users.ts
function formatUser(u) {
  const name = `${u.first} ${u.last}`.trim();
  const date = new Date(u.createdAt).toISOString().split("T")[0];
  return { name, date, active: u.status === "active" };
}

// src/routes/admins.ts
function formatAdmin(a) {
  const name = `${a.first} ${a.last}`.trim();
  const date = new Date(a.createdAt).toISOString().split("T")[0];
  return { name, date, active: a.status === "active" };
}
```

**GOOD** — shared module, single source of truth:
```ts
// src/utils/format-person.ts
export function formatPerson(p) {
  const name = `${p.first} ${p.last}`.trim();
  const date = new Date(p.createdAt).toISOString().split("T")[0];
  return { name, date, active: p.status === "active" };
}

// Both routes import from the shared module
import { formatPerson } from "../utils/format-person";
```

### Coupling check
Read import/require statements and flag:
- Files importing from **8+ different modules**
- **Circular dependencies**: A imports B and B imports A (use Grep to trace both directions)

**BAD** — circular dependency:
```ts
// src/services/order.ts
import { getUser } from "./user";      // order → user
export function createOrder(userId) { /* ... */ }

// src/services/user.ts
import { createOrder } from "./order";  // user → order  ← circular!
export function getUser(id) { /* ... */ }
```

**GOOD** — break the cycle with a third module:
```ts
// src/services/order.ts
import { getUser } from "./user";
export function createOrder(userId) { /* ... */ }

// src/services/user.ts              ← no longer imports order
export function getUser(id) { /* ... */ }

// src/services/user-orders.ts       ← new file owns the cross-cutting logic
import { getUser } from "./user";
import { createOrder } from "./order";
export function createUserOrder(userId) { /* ... */ }
```

## Step 2 — Report Findings

Present a sorted table (worst issues first):

```
Code issues found:

  File                              Issue         Detail
  src/services/api.ts               Size          342 lines (142 over)
  src/utils/helpers.py              Duplication   3 copies of parseDate() across files
  src/components/Dashboard.tsx      Complexity    renderStats() has 5 nesting levels
  src/controllers/order.ts          Coupling      imports from 12 modules

  Total: 4 files need refactoring
```

If no issues found:

```
All files look clean. No refactoring needed.
```

Stop here if nothing found.

## Step 3 — Plan the Refactor

**1–3 files**: propose fixing **all** in one pass.
**4+ files**: propose fixing **one at a time**, starting with the worst.

Read each file fully, then show a plan based on the issue type:

### Size → Split by responsibility
```
src/services/api.ts (342 lines):
  → Extract auth endpoints → src/services/auth-api.ts
  → Extract user endpoints → src/services/user-api.ts
  → Keep shared client setup → src/services/api.ts (~45 lines)
```

### Complexity → Extract and simplify
```
src/components/Dashboard.tsx — renderStats() has 5 nesting levels:
  → Extract validation logic → validateStats()
  → Extract formatting → formatStatDisplay()
  → Use early returns to flatten nesting
```

### Duplication → Extract shared module
```
parseDate() duplicated in 3 files:
  → Create src/utils/date-helpers.ts with shared parseDate()
  → Update imports in all 3 consuming files
```

### Coupling → Introduce facade or split
```
src/controllers/order.ts imports 12 modules:
  → Group related imports behind src/services/order-service.ts facade
  → Move validation logic to src/validators/order-validator.ts
  → Reduce direct imports to 4-5
```

**Ask the user to confirm before proceeding.**

## Step 4 — Refactor

For each approved file:

1. **Read the full file** — understand every export, import, and dependency
2. **Apply the fix** based on issue type:
   - **Size**: group by responsibility, create new files, each under 200 lines
   - **Complexity**: extract helper functions, flatten nesting with early returns, split large params into option objects
   - **Duplication**: create shared module, replace all copies with imports
   - **Coupling**: introduce facade/service layer, move logic to reduce import count
3. **Update all imports** — use Grep to find every file importing from changed modules, fix paths
4. **Re-export only if needed** — if the original file was a public barrel, keep re-exports

## Step 5 — Verify

After each refactor:

1. **Size**: count lines in all new/modified files — confirm all under 200
2. **Complexity**: confirm no function exceeds nesting/branching thresholds
3. **Duplication**: grep for the old duplicated code — confirm only one copy remains
4. **Coupling**: count imports in modified files — confirm under threshold
5. **Imports**: grep for old import paths — verify none are broken

Report:
```
Refactored src/services/api.ts (Size: 342 → 45 lines):
  ✔ Created src/services/auth-api.ts (80 lines)
  ✔ Created src/services/user-api.ts (90 lines)
  ✔ Updated 12 imports across 8 files
```

## Step 6 — Summary

```
Refactoring complete:
  Files refactored: 4
  New files created: 6
  Imports updated: 28
  Issues resolved:
    Size:        1 file  ✔
    Complexity:  1 file  ✔
    Duplication: 1 group ✔
    Coupling:    1 file  ✔
```

## Rules

- ALWAYS read the full file before proposing any refactor
- ALWAYS update every import referencing moved exports — use Grep to find them all
- ALWAYS keep resulting files under 200 lines
- ALWAYS ask the user before starting each refactor
- NEVER delete or rename exports — everything must remain importable
- NEVER change function signatures or behavior — structural refactor only
- NEVER refactor test files unless they also have detected issues
- NEVER create barrel files unless the original was already one
- If a file is only slightly over on size (201–220), extract one small piece instead of a full split
- For complexity, prefer early returns and extraction over rewriting logic
- For duplication, the shared module owns the code — all consumers import from it
- For coupling, aim to cut import count by at least 40%
