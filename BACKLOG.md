# Skills Backlog

Captured 2026-07-13 from a 3-agent web-research sweep. Each item is a self-contained
unit of work. Check off as tackled.

---

## A. Freshness fixes (existing skills)

Update guidance that has gone stale. These are edits to skills that already exist.

### A1. `typescript` — TS 7.0 is out — ✅ DONE 2026-07-13
- [x] **What:** Frontmatter/content says "TypeScript 6.x." TS **7.0 GA'd 2026-07-08** — the
  Go-native compiler is now shipped as plain `tsc` (`npm i -D typescript` gets 7.0), ~8–12x
  faster type-checking.
- **Fix:** Bump version references to 7.0; drop any "tsgo is a separate preview" framing
  (`tsgo`/`@typescript/native-preview` is now just `tsc`). Note the caveat that 7.0 ships
  **without a stable programmatic compiler API** (some tooling waits for 7.1) if migration
  guidance touches that.
- **Source:** https://devblogs.microsoft.com/typescript/announcing-typescript-7-0-rc/

### A2. `react` — confirm Compiler-first memoization — ✅ DONE 2026-07-13
- [x] **Investigated:** Compiler-first memoization is already correct everywhere (SKILL gotcha
  #8 + rule #7; PERFORMANCE.md "Stop Manual Memoization" + 3 exceptions + ESLint; USE-EFFECT.md
  defers to it). Versions current (19.2, `<Activity>`, Performance Tracks). **One gap found &
  fixed:** USE-EFFECT.md "Non-Reactive Values in Effects" taught the manual `useRef`-latch
  workaround — added `useEffectEvent` (stable in 19.2, verified against react.dev) as the
  preferred pattern, ref-latch kept as pre-19.2 fallback. Updated heading, TOC, rule #9.
- [ ] ~~**What:** Skill already claims React Compiler v1.0 coverage (compiler went **stable~~
  2025-10-07**). Verify it doesn't still teach manual `useMemo`/`useCallback`/`memo` as the
  *default* — the compiler makes them largely unnecessary.
- **Fix:** Ensure manual memoization is framed as the exception, not the rule. Confirm
  version is 19.2.x and the new stable APIs (`useActionState`, `useOptimistic`, `<Activity>`,
  `useEffectEvent`) are current.
- **Source:** https://react.dev/blog/2025/10/07/react-compiler-1

### A3. `docker-best-practices` — Compose Watch as the dev default
- [ ] **What:** Ensure `docker compose watch` (with the `develop:` key, sync/rebuild) is
  presented as *the* stable local hot-reload workflow — it's no longer experimental.
- **Fix:** Verify Compose Watch is the recommended dev loop; confirm BuildKit defaults
  (`RUN --mount=type=cache`, `COPY --link`) are present.
- **Source:** https://docs.docker.com/compose/release-notes/

### A4. `drizzle-orm` — Relations v2 awareness — ✅ DONE 2026-07-13
- [x] **Investigated + fixed.** Confirmed **stable is still 0.45.x**, so the skill's `relations()`
  + `{ schema }` code is correct and stays the taught default (Relations v2 is only `@rc`,
  v1.0.0-rc — not GA). Added a compact forward-looking "Relations v2 — Landing in Drizzle v1.0"
  section: v1→v2 key mapping (`fields`→`from`, `references`→`to`, `relationName`→`alias`),
  `defineRelations` + `{ relations }`, native m2m via `.through()`, object-style `where`, and the
  `db.query`/`db._query` migration-window nuance. Verified against orm.drizzle.team/docs/relations-v1-v2.

> **`tauri-v2` skill deleted** (2026-07-13) — user doesn't use Tauri; it was a one-off. Removed the
> skill dir, both README rows (root README's now-empty "Desktop" section dropped), and this flag.

---

## B. New skills to add

Ranked. Each fills a gap adjacent to the existing stack (Vite SPA + Python backend).

### B1. Tailwind CSS (+ shadcn/ui) — `Frontend` — ⚠️ PARTIALLY COVERED
- **Already exists:** `react/TAILWIND-TOKENS.md` (301 lines) covers the design-token discipline —
  Tailwind v4 `@theme`, palette lockdown (`--color-*: initial`), semantic role tokens, no
  arbitrary values, spacing/type/radius scales, `@theme inline` light/dark, ESLint enforcement.
  **Do not duplicate it.**
- [ ] **Actual remaining gap:** the *non-token* Tailwind surface — layout (flex/grid), state &
  responsive variants, **shadcn/ui** copy-in component pattern, `cva` / `tailwind-variants` for
  component variants, dark-mode toggle mechanics. Add as a new `react/` reference (e.g.
  `SHADCN.md` / `STYLING.md`) that *references* TAILWIND-TOKENS.md, or a standalone styling skill.
- **Source:** https://jsdev.space/react-stack-2026/

### B2. Forms & validation: React Hook Form + Zod — `Frontend`
- [ ] **Why:** Teach components but have no form/validation story. RHF+Zod is *the* standard;
  Zod also guards API boundaries (shared schema between fetch layer and forms).
- **Content seeds:** `useForm` + `zodResolver`, schema-first design, `z.infer` types, field
  errors, async validation, Zod at every trust boundary (API responses too).
- **Source:** https://dev.to/marufrahmanlive/react-hook-form-with-zod-complete-guide-for-2026-1em1

### B3. Zustand (client state) — `Frontend` — ✅ CONTENT ALREADY EXISTS
- [x] **Already covered by `react/ZUSTAND.md`** (278 lines) — comprehensive: typed curried
  `create<T>()()`, atomic selectors + `useShallow`, custom-hook export, event-actions vs setters,
  persist / immer / devtools + composition order, slices pattern, transient updates, async, and
  the "server state → query library" rule. Every B3 content seed is present.
- [ ] **Open question is packaging only:** leave bundled in `react`, or **promote to a standalone
  `zustand` skill** for symmetry with the standalone `tanstack-query` skill (better auto-trigger
  when working on stores outside React-component context). Note: `cli/README.md` already advertises
  a standalone `zustand` skill that doesn't exist in `skills/` — a pre-existing inconsistency.
- **Source:** https://nextfuture.io.vn/blog/ultimate-guide-react-state-management-2026

### B4. Python tooling: uv (+ Alembic) — `Backend`
- [ ] **Why:** `uv` is the fastest-rising Python change (surpassed Poetry, ~75M monthly
  downloads). No Python migration story to match the Drizzle one — Alembic fills it.
- **Content seeds:** uv project/workspace/lockfile/`uv run`, replacing pip/Poetry/venv;
  Alembic with async SQLAlchemy 2.0, autogenerate caveats, safe migration patterns.
- **Sources:** https://cuttlesoft.com/blog/2026/01/27/python-dependency-management-in-2026/ ·
  https://testdriven.io/blog/fastapi-sqlmodel/
- **Note:** Decide whether uv + Alembic is one bundle or two skills.

### B5. Auth — `Backend`/`Security`
- [ ] **Why:** Every web+desktop app hits it; nothing covers it. High-stakes, easy to get
  wrong. Better Auth is ascendant; Auth.js/NextAuth is now maintenance-only.
- **Content seeds:** session vs JWT, secure cookie flags, refresh rotation, passkeys,
  Better Auth patterns.
- **Source:** https://blog.logrocket.com/best-auth-library-nextjs-2026/
- **Note:** Scope carefully vs the existing `security-practices` skill — avoid overlap.

### Honorable mention
- [ ] **Postgres-specific companion to `sql`** — JSONB, indexing depth, RLS. The current SQL
  skill is engine-generic; a Postgres bundle would add depth without bloating it.

---

## C. Workflow/meta skills — research complete, decisions pending

Ecosystem scan noted community collections lean heavily on workflow/meta skills, while this
repo covers the territory via **commands/agents**. Two research agents dug in. Summary below;
the reference implementation for this whole category is **obra/superpowers**
(https://github.com/obra/superpowers) — the "awesome" lists mostly just point at it, and the
official `anthropics/skills` repo has none of this kind (docs skills only).

### C1. Add `verification-before-completion` skill — **highest value, do first**
- [ ] **Why:** Lowest cost, highest leverage, stack-agnostic. A solo dev with no second
  reviewer is exactly who ships "should work" claims. Composes with existing `verify` /
  `/test-review` rather than duplicating.
- **Core rule:** "No completion claims without fresh verification evidence." 5-step gate:
  identify the validating command → run it fresh in full → read entire output *and exit code*
  → confirm it substantiates the claim → only then state done. Insufficient = "should pass" /
  prior run / partial checks; sufficient = current output, zero failures, exit code confirmed.
- **Source:** https://github.com/obra/superpowers/blob/main/skills/verification-before-completion/SKILL.md

### C2. Add `systematic-debugging` bundle — **strong second**
- [ ] **Why:** Daily solo-dev time sink; teaches a transferable *method*, not a ritual. Maps
  directly onto the JS-frontend ↔ Python-backend boundary and other cross-runtime seams where
  bugs cross layers.
- **Core method:** "No fixes without root-cause investigation first." 4 phases: root-cause
  (parse real error/stack, reproduce, instrument at component boundaries, trace data
  *backward* to origin) → pattern analysis (diff vs known-good) → hypothesis ("I think X
  because Y", minimal test) → fix once + failing test. **After 3 failed attempts, stop and
  question the architecture.**
- **Structure:** bundle — `SKILL.md` + `root-cause-tracing.md` + `defense-in-depth.md`.
- **Source:** https://github.com/obra/superpowers/blob/main/skills/systematic-debugging/SKILL.md

### C3. Add `test-driven-development` skill — **close third, more discretionary**
- [ ] **Why:** Well-teaching, stack-neutral (pytest/vitest). Ranked below the first two
  because TDD adoption is more discretionary than debugging/verification, which bite on every
  task. If adopted, bake in this repo's 200-line-per-file rule in examples.
- **Core rule:** "No production code without a failing test first." Red → *verify red* →
  Green → verify green → Refactor, where watching the test fail is mandatory. Include the
  rationalization table (debunks ~10 skip excuses).
- **Source:** https://github.com/obra/superpowers/blob/main/skills/test-driven-development/SKILL.md

### C4. Deprioritized (don't build as full skills)
- [ ] **`writing-plans` / `executing-plans` and `requesting`/`receiving-code-review`** assume a
  multi-agent/multi-person workflow; value drops sharply for a solo dev, and this repo already
  covers review via `/test-review` + reviewer agent and `/code-review`, and planning via
  `/plan-feature` + `/preplan`. **Cheap win instead:** adopt the *receiving-code-review*
  anti-sycophancy rule ("no 'you're absolutely right' — just fix it, push back with
  specifics") as a paragraph somewhere, not a whole skill.

### C5. Structural caveat for any adoption
- [ ] superpowers `SKILL.md` files are **long** (TDD ~1,200 lines, systematic-debugging ~600) —
  way over this repo's 250-line target / 350 cap. Port only the always-loaded core into a
  ≤250-line `SKILL.md`; push rationalization tables / anti-pattern catalogs into reference
  files (the same split superpowers uses for systematic-debugging).

### C6. Key mechanics finding — commands are now a *subset* of skills
- [ ] **This reframes the "skill vs command" question.** Per current Claude Code docs, a
  `.claude/commands/deploy.md` and a `.claude/skills/deploy/SKILL.md` both create `/deploy`
  and work the same way — **every skill is also `/`-invokable**, so commands are the legacy,
  thinner format (no bundling, no auto-invocation, no supporting files). Decision per workflow
  is now: **skill auto-ON** / **skill auto-OFF (`disable-model-invocation: true`)** / **fork to
  subagent**:
  - **Auto-ON skill** for safe, proactive, analysis-only workflows → `/deep-review`,
    `/test-review`, `/refactor` are candidates to convert (gain auto-invocation + bundling,
    keep `/` UX). Gate with tight `description` + optional `paths:`.
  - **Auto-OFF skill (`disable-model-invocation: true`)** for side-effecting/timing-sensitive
    → **`/ship`** (never let Claude decide to ship); its description also leaves context until
    invoked, so ~zero idle cost. `/plan-feature` is a judgment call.
  - **Keep a real subagent** only where context isolation is the goal — e.g. `/test-review`'s
    sharded-worktree fan-out. Wire via a skill with `context: fork` + `agent:`, or an agent
    that preloads skills via the `skills:` field.
- **Budget gotcha:** the always-loaded skill listing has a **~1% context budget**; when it
  overflows, Claude Code **silently drops least-used skills' descriptions** and they stop
  auto-triggering. Since this repo ships many skills, watch `/doctor`, keep descriptions tight
  (1,536-char cap), and consider `skillOverrides` "name-only" for low-priority skills.
- **Sources:** https://code.claude.com/docs/en/skills ·
  https://claude.com/blog/steering-claude-code-skills-hooks-rules-subagents-and-more

---

## D. Deferred — needs a decision (not yet triaged)

- [ ] **Distribution: custom npm CLI → native plugin marketplace.** Claude Code now ships a
  first-class plugin + marketplace system (`/plugin marketplace add`, `.claude-plugin/
  marketplace.json`) that covers the custom `@spardutti/claude-skills` picker natively —
  with auto-update, version pinning, native per-plugin `category`/`tags`, and a sanctioned
  home for the gate/automark hooks (plugin `hooks` component). The picker model survives (one
  manifest, many installable plugins). **Not in this pass's scope — flagged so it isn't lost.**
  Source: https://code.claude.com/docs/en/plugin-marketplaces

#### Plugin packaging — what a build-and-test pass on 2026-09-01 actually proved

Built the manifests, installed them for real, then reverted. Keep these — they were
expensive to learn and none are guessable from the docs alone.

- **`skills[]` scoping works.** A marketplace entry with `source: "./"` hits a documented
  exception where a declared `skills[]` *replaces* the default `skills/` scan instead of
  adding to it. Verified: the install cache held all 15 skill dirs, only the 3 declared
  ones loaded.
- **`commands`/`agents` scoping does NOT work from a marketplace entry.** The docs say
  declaring them replaces the default scan — that holds for `plugin.json`, not for a
  marketplace entry. All 9 commands shipped with `skills-frontend` regardless. An empty
  array reads as "not declared"; pointing at an empty directory was also ignored.
- **The plugin root is a full copy of the repo** (`cli/`, `node_modules/`, `BACKLOG.md`
  and all) when `source` is `"./"`. Anything conventional in the root gets discovered.
- **`agents` must be explicit `.md` paths.** A directory is a schema error:
  `Invalid string: must end with ".md"`.
- **A plugin root needs real content** — `SKILL.md`, `skills/`, `commands/`, `.mcp.json`,
  or `.lsp.json`. A directory holding only a `.gitkeep` fails to load, so per-stack roots
  cannot be empty shells pointing back at `./skills/` (and `../` outside the marketplace
  root is forbidden).
- **`claude plugin validate .` exists** and checks the schema. Wire it into preflight if
  this is ever revived.

**The cheap fix, if revisited:** move only `commands/` and `agents/` into `plugins/core/`
and leave `skills/` at the repo root. The stack plugins keep `source: "./"`, and with no
`commands/` in the root there is nothing to leak. Costs two directory moves plus the npm
CLI's fetch paths for commands and agents; `skills/` paths and the picker are untouched.

**Why it was dropped for now:** the whole stake is small — all 15 skill descriptions
together measure ~1,436 tokens, under 1% of a 200k context, so a wrong-stack skill costs
about one file read. Revisit when the skill count grows enough that granularity pays for
the restructure, or when shipping to `anthropics/claude-plugins-official` (submission form:
https://clau.de/plugin-directory-submission) becomes the goal.

- [ ] **Claude Mods: rebuild `skill-gate.sh` as a mod.** Added in Claude Code 2.1.287
  (2026-10-01). A mod is a TypeScript plugin with `tool.call`, `skill.prompt` and
  `prompt.compose` hooks, and `$.skill.prompt` to fetch a skill's text.
  - **Why:** the gate could hand Claude the skill text in the block message, saving the extra
    `Skill` call, and trim a skill to the parts that fit the edited file.
  - **Why not yet:** the API is new and may change; consumers need 2.1.287+; mods ship as
    plugins, so this rides on the distribution decision above.
  - **First step:** a local test mod that only inlines the skill text on block; measure turns
    and tokens. It must replace the bash gate, never run beside it.
  - **Revisit:** about 2026-12, or when the mod API stops changing between releases.
