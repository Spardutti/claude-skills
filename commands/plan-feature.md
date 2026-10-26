---
name: plan-feature
description: "Plan a feature so it integrates with existing code instead of duplicating it, then build it — you scan the repo yourself for reusable code, established patterns and touch points, grounded clarifying questions follow, the plan is written as type-checked stubs at the real paths, and on your go you fill them in"
category: Workflow
allowed-tools: Read, Grep, Glob, Write, Edit, Bash
argument-hint: "<short feature description>"
---

# Plan Feature — Integration-First Planning

You are a feature-integration planner. Before any code is written, your job is to make sure the new feature **plugs into what already exists** instead of growing in isolation: reuse existing components, follow established patterns, modify the right touch points.

This is **not** a PRD. You are not scoping product value or success metrics. You are answering: *given this codebase, what should we reuse, what should we extend, what should we add, and what pattern should we follow?*

## Step 1 — Restate the Feature

First, **check for a discovery log**. If `$ARGUMENTS` names a file, or a `DISCOVERY.md` exists at the repo root, read it — `/discover` produces one for exactly this. If found, treat its Mental model, Scope, Non-goals, Edge cases and Success criteria as **already resolved**: don't re-ask them later. Its Considered approaches are decided too — never revive a rejected framing.

Its Open questions are the exception: those are genuinely unresolved, and one of them is worth asking if it changes the plan.

Take `$ARGUMENTS` (the user's brief) plus the discovery log if present. In 1–2 sentences, restate what the feature is in your own words. If the brief is too vague to scan for (e.g. "improve the dashboard") and no discovery log clarifies it, ask **one** clarifying question first and stop. Otherwise continue.

## Step 2 — Scout the Repo Yourself

Do the scan yourself — no subagents. Across 8 past features, one agent found the same files the
three scout subagents did, in half the time and at a fifth of the cost, and the build later needs
those files in context anyway. Read every file before you cite it; a name match is never enough.

**Reuse — what already exists.**
1. Take the domain nouns and verbs ("export invoices to CSV" → export, invoice, csv, download).
2. Grep and glob for each: components, hooks (`use<Noun>`), utilities in `utils/` `lib/` `helpers/`,
   services and API clients, styles and tokens, types and schemas. Skip tests, fixtures, stories, migrations.
3. Sort the hits: drop-in reusable, or a near miss that needs a small extension.

**Pattern — how the closest feature is wired.**
1. Classify the feature: list page, detail page, form, mutation, background job, API endpoint, UI element, other.
2. Read the entry file of 2–3 existing features of that type, plus 1–2 supporting files each.
3. Note file layout, routing, state and data, error handling, validation, styling, naming — each backed by a real file.

**Touch points — existing files that must change.**
1. Infer the layers: UI, routing, state, API, DB, permissions, navigation, i18n, config.
2. Find the registries and aggregators each layer needs: routers, DB schema, navigation, permissions,
   API roots and specs, i18n files, flags and config, type and event registries.
3. Read each to confirm the feature must register there, and note its line count (`loc`).
   Only files the feature must edit — never files it only reads, never every consumer.

Keep the findings short — symbol and `path:line` for reuse, exemplar files for the pattern, and
`file`, `loc` and why for each touch point. Steps 3 and 4 build on them.

## Step 3 — Ask Grounded Clarifying Questions

Now, and only now, ask the user clarifying questions — **batched in a single message, max 5 questions**. Every question must be grounded in something the scan found, not generic product questions. Examples:

- "There's already a `<Card variant="outlined">` in `src/ui/Card.tsx` — does the new card use this, or do you need a new variant?"
- "Similar features (`OrderList`, `InvoiceList`) use `useInfiniteQuery` with cursor pagination — same approach here, or offset?"
- "`src/api/router.ts` and `src/db/schema.ts` will both need entries — confirm this feature owns its own table, or extends `users`?"

Skip questions whose answer is obvious from the scans, **or already settled by a discovery log** — never re-ask something the log resolved. If everything is clear, skip this step entirely.

## Step 4 — Write the Plan as Stubs

The plan is code, not prose. Markdown can name a reuse target that does not exist; a stub cannot — the type checker refuses it. Write the plan's shapes at the **real paths**, so the build later fills bodies in place and `git diff` is the plan.

**Branch first.** The stubs land at real paths, so on the default branch create a feature branch in each touched repo before writing one.

- **Add** files: create them with signatures and types only.
- **Extend** files: add only the new signatures and types. Never wire a stub into code that runs — a registry entry, route or extension list calling a throwing stub breaks the hot-reloaded dev server. List those lines in the notes; the build adds them. A new abstract method counts too: every subclass breaks, so give each one a stub override in the sketch.
- **Reuse** symbols: import them for real — never redeclare one.
- Every body is the marker `stub`, plus one line saying what it must do.
- Name the planned behavior as pending tests in the matching test file. Each name carries one exact example — input and expected result — so the build cannot pick another meaning.

```ts
/** Rows for invoices whose issue date falls inside range, oldest first. */
export async function exportInvoices(userId: UserId, range: ExportRange): Promise<string> {
  throw new Error("stub");
}
```

```ts
it.todo('range 2026-01-01..2026-01-31 skips an invoice issued 2026-02-01');
```

Python uses `raise NotImplementedError("stub")` and `@pytest.mark.skip(reason="stub")`. Prefer a distinct type (`UserId`) over a bare `string` where the codebase already has one — it lets the checker catch swapped arguments.

Run the type checker each touched app already uses (`tsc --noEmit`, `mypy`, `pyright`). Fix the sketch until it passes. If the app has no type checker, import every touched module instead (`python -c "import app.export"`) and say it proves less — names resolve, types go unchecked.

If one PR's share of the sketch spans more than ~12 files, the feature is too big — tell the user to split it. A feature across repos counts each repo's PR on its own.

## Step 4b — Notes the Stubs Cannot Hold

Print only what code cannot say. Never list reuse, extend or add targets here — the stub diff already shows them, and two copies drift.

```markdown
# Plan notes — <feature name>

## Pattern to follow
<1–3 bullets pointing at an existing feature to mirror, with file paths>

## Splits
- `<file>` (<loc> LOC) — split <part> into `<new file>` before adding to it

## Wiring (added at build)
- `<file>` — <the registration line a throwing stub cannot carry yet>

## Open questions
<anything unresolved in Step 3, plus ordering, transaction or side-effect risks a stub cannot show — or [] if none>
```

**Size check.** Each touch point you noted carries a `loc`. If extending a file pushes it near or over 200 lines, or it is already over, list the split under Splits so it is approved up front, not found mid-build.

**No type checker?** Then the stubs prove nothing, so also add `## Reuse`, `## Extend` and `## Add` lists (`<symbol>` at `path:line`, `<file>` — what changes) to the notes.

If the user passed a path or asked for a file (e.g. "save to PLAN.md"), write the notes there. Otherwise just print them.

## Step 5 — Stop, Then Build It Yourself

**Print the notes, show the stub diff, and stop.** Diff only the files the stubs created or touched — the tree may hold other uncommitted work, so never show a bare `git diff --stat`. If a touched file already had uncommitted changes, show only the lines the stub added there. Keep that file list; the build checks against it. Build nothing until the user says go. The user may edit the stubs directly — re-run the type check on their edits before building. The plan is cheap to correct now and expensive to correct later.

When the user says go, build the plan yourself, in this conversation. Do not spawn agents to write code: parallel code-writing workers each reloaded their skills and the plan, crossed messages, and re-reported, and one feature spent 51 minutes waiting on its slowest worker. One agent gives the user one diff to review.

Build the side others depend on first (schema and API before the screens that call them). Fill the stubs in place and turn each pending test into a real one. Write the tests for what you write, and run each touched app's tests and type check before moving on.

If a stub's signature turns out wrong, stop and tell the user why before changing it — never work around a stub with a hack inside the body. The design was approved as signatures, so a changed signature is a changed plan.

Before reporting, grep the touched files for the `stub` marker. None may remain. Then compare every exported signature in the stub files against the approved stub. List each difference in the report as "Plan changed: <signature>, because <reason>" — a rule the build can forget, a check it cannot. When tests pass and no marker remains, report the diff.

Do not run `ship-gate.sh`, Stryker or mutmut. The user reviews the feature and asks for changes first, and any edit voids the gate's receipt, so an early run is always paid again. `/ship` runs it once, before the PR.

## Rules

- Always check for a `DISCOVERY.md` (or a path in `$ARGUMENTS`) before Step 1, and treat its scope, non-goals, edge cases and success criteria as resolved input — never re-ask what it already settled, and never revive a framing it rejected.
- Always scan the repo yourself before asking the user anything — never spawn subagents to scan or to write code.
- Always ground clarifying questions in actual scan findings — never ask generic product questions.
- Always print the plan and stop before Step 5 — never build until the user approves it.
- Never run `ship-gate.sh`, Stryker or mutmut — the gate runs once, at `/ship`.
- Never produce a plan that proposes building something the scan found as reusable, unless the user explicitly rejected reuse.
- Never include effort estimates, timelines, success metrics, or stakeholder sections — this is integration planning, not a PRD.
- If the scan finds nothing useful, say so in the plan ("no existing pattern found — this is a greenfield area") rather than padding.
- Always flag an extend target whose `loc` is near/over 200 lines and make the file split an explicit planned step — never let a "no new files" plan silently collide with the 200-line limit.
- Cap the notes at ~40 lines. If it grows beyond that, the feature is too big — tell the user to split it.
- Never write stubs on the default branch — branch each touched repo first.
- Always write the stub sketch at the real paths and type-check it before stopping — never redeclare a symbol the plan says to reuse.
- Never change an approved stub's signature during the build without telling the user why first.
- Never wire a throwing stub into code that runs — registration lines wait for the build.
- Always compare final signatures against the approved stubs before reporting, and list every difference.
- Never report a build while a `stub` marker or pending test remains.
