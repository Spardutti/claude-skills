# Mutation Testing — Proving the Tests Are Real

A suite written alongside the code passes by construction. Coverage says the line
ran, not that anything checked the result. Mutation testing breaks the code on
purpose and reports which breaks no test noticed — the only check the author of
the tests cannot accidentally pass.

## Contents

- [What It Catches That Review Does Not](#what-it-catches-that-review-does-not)
- [Stryker — JS/TS](#stryker--jsts)
- [The Sandbox Trap](#the-sandbox-trap)
- [Keep Page Tests Out Of The Run](#keep-page-tests-out-of-the-run)
- [Vitest Browser Mode — Stryker Cannot Run](#vitest-browser-mode--stryker-cannot-run)
- [mutmut — Python](#mutmut--python)
  - [A Parametrize Id With An Accent Aborts The Whole Run](#a-parametrize-id-with-an-accent-aborts-the-whole-run)
  - [Code That Runs At Import Never Sees A Mutant](#code-that-runs-at-import-never-sees-a-mutant)
- [Reading the Output](#reading-the-output)
- [Silencing Noise Without Going Blind](#silencing-noise-without-going-blind)
  - [`next-line` Means The Next Line, Literally](#next-line-means-the-next-line-literally)
  - [Prefer `ignoreStatic` Over Silencing A Data Table](#prefer-ignorestatic-over-silencing-a-data-table)
- [An Incremental Typecheck Can Lie](#an-incremental-typecheck-can-lie)
- [Scores and Thresholds](#scores-and-thresholds)
- [Rules](#rules)

## What It Catches That Review Does Not

A test that imports the constant it asserts on:

```ts
// BAD — the mutant changes both sides, so the test still passes
export const NO_CARD = "Débito o efectivo";
expect(metaSentence(row)).toContain(NO_CARD);
```

Mutating `NO_CARD` to `""` leaves the assertion comparing `""` to a string that
contains `""`. Green. The test asserts nothing, and reading it will not tell you.

```ts
// GOOD — the expectation is written out, so the mutant breaks it
expect(metaSentence(row)).toContain("Débito o efectivo");
```

The second class it catches: a fixture that satisfies an assertion two ways, so
the test passes against code that stopped checking one of them. No reviewer sees
that; the mutant does.

## Stryker — JS/TS

```bash
npm i -D @stryker-mutator/core @stryker-mutator/vitest-runner
```

```json
{
  "$schema": "./node_modules/@stryker-mutator/core/schema/stryker-schema.json",
  "testRunner": "vitest",
  "plugins": ["@stryker-mutator/vitest-runner"],
  "coverageAnalysis": "perTest"
}
```

Stryker maps which test covers which line and runs only those per mutant, instead
of the whole suite every time. The vitest runner **forces** `perTest` and ignores
whatever `coverageAnalysis` says; the key matters only if the runner changes.

Scope it to what changed with **one** comma-joined `--mutate`, repeating the
file name on every range:

```bash
# BAD — the second flag overrides the first; only src/b.ts is mutated
npx stryker run --mutate 'src/a.ts:12-30' --mutate 'src/b.ts:58-61'

# GOOD — one value, every range carries its own file name
npx stryker run --mutate 'src/a.ts:12-30,src/a.ts:44-51,src/b.ts:58-61'
```

Stryker's CLI coerces `--mutate` with `(val) => val.split(",")`, a function that
never reads the previous value, so a repeated flag **replaces** it rather than
appending. Nothing warns. The run reports a healthy score for the one file it
looked at, and if that file happens to have no tests it exits on `No tests were
executed` instead.

Ranges are `file:startLine[:startCol]-endLine[:endCol]`, and a range **cannot**
be combined with a glob in the same entry. Repeat the file name for a second
range in the same file — `a.ts:3-3,7-7` makes Stryker read `7-7` as a filename.

## The Sandbox Trap

Stryker copies the whole project into `.stryker-tmp/sandbox-XXXX/`. While a run is
in flight — or permanently, if one crashes before tidying up — **every test file
exists twice** and the runner collects both.

The duplicates pass, so nothing fails. The only symptom is a doubled test count:
34 files / 148 tests where the repo has 18 / 82.

```ts
// BAD — assigning exclude drops node_modules and dist along with it
export default defineConfig({ test: { exclude: ["**/.stryker-tmp/**"] } });

// GOOD — spread the defaults
import { configDefaults, defineConfig } from "vitest/config";
export default defineConfig({
  test: { exclude: [...configDefaults.exclude, "**/.stryker-tmp/**"] },
});
```

Add `.stryker-tmp/` to `.gitignore` too, or a crashed run leaves a full second
copy of the project in `git status`.

## Keep Page Tests Out Of The Run

A test that renders a page calls every util the page uses, so Stryker counts it as
covering them. Every mutant in those utils reruns slow render tests, and a util no
logic test checks reads as killed. On one back office: 23 minutes and 0 findings
with every test, 2 minutes and 104 findings with logic tests only.

```ts
// Survived once page tests were out — only a page test had checked the type
if (!PHOTO_TYPES.includes(file.type)) return wrongType(file);
```

Give Stryker its own Vitest config that runs logic tests only:

```ts
// vitest.stryker.config.ts
import { defineConfig } from "vitest/config";
import base from "./vitest.config"; // or ./vite.config, wherever `test` lives

export default defineConfig(async (env) => {
  const resolved = typeof base === "function" ? await base(env) : base;
  return {
    ...resolved,
    test: {
      ...resolved.test,
      include: ["src/**/*.test.ts", "src/**/{hooks,queries}/**/*.test.tsx"],
    },
  };
});
```

```json
{ "vitest": { "configFile": "vitest.stryker.config.ts" } }
```

```ts
// BAD — mergeConfig appends arrays, so a base that sets `include` keeps it and
// every page test is still collected; a base exported as a function cannot merge
export default mergeConfig(base, defineConfig({ test: { include: ["src/**/*.test.ts"] } }));
```

A hook test is logic even in `.tsx`. Keep it in `hooks/` or `queries/`, where the
include finds it; a `renderHook` test in `lib/` drops out and its hook reads
`NoCoverage`. Page tests still run in the normal suite — they prove wiring once,
not once per mutant. The ship gate reports UNPROVEN for a Stryker project with
`.test.tsx` files outside those folders and no `vitest.configFile`.

The first run after the split lists the logic only page tests were covering. That
is the debt the split exposed: write the logic test, never put the page back.

## Vitest Browser Mode — Stryker Cannot Run

Stryker's vitest runner does not support browser mode. Check for
`test.browser.enabled: true` before installing anything. When it is set, mutate
by hand, one mutant per test run:

1. Pick one operator on one changed line: `<`→`<=`, `&&`→`||`, `!x`→`x`,
   `return x`→`return null`, delete an early `return`, delete an `emit`/`save`/`push`.
2. Apply that single edit and run only the test files that cover it.
3. Record **killed** (a test failed) or **survived** (all passed).
4. Put the line back before the next mutant.

```bash
# BAD — also throws away the uncommitted change you are testing
git checkout -- src/settings.ts

# GOOD — undo the one edit you made, exactly as you made it
```

A mutant that does not parse is not a kill. Vitest does not typecheck, so a
broken edit fails the file on load and reads as killed — mutate valid code only.

Boundaries and removed side effects survive most. A settings test that asserted
the stored preference passed with `newMode === 'dark'` negated, because nothing
checked `document.documentElement.classList` — the thing browser mode exists to see.

## mutmut — Python

```bash
uv add --dev mutmut     # or: poetry add --group dev mutmut, pip install mutmut
```

Install it the way the project manages dependencies. `pip install` into a uv or
poetry project puts it somewhere a container rebuild will lose.

```toml
[tool.mutmut]
source_paths = ["app/"]
pytest_add_cli_args_test_selection = ["tests/"]
```

**mutmut 3 renamed these.** `paths_to_mutate` and `tests_dir` are 2.x and are
silently ignored — every older guide still shows them. Point `source_paths` at
the real package directory, which is often `app/`, not `src/`.

Scope is by **mutant name**, not by path. There is no `--paths-to-mutate` in 3.x
and no line-level scoping at all:

```bash
# BAD — 2.x syntax; the flag does not exist and the run mutates everything
mutmut run --paths-to-mutate app/balance.py

# GOOD — fnmatch globs over mutant names
mutmut run 'app.balance.reserve.*'
```

Names are `<module.path>.x_<function_name>__mutmut_<n>`, and filtering is
`key in names or fnmatch(key, name)` — so a bare prefix with no `*` matches
nothing and fails the assert.

If the tests need a service (a database reachable only as `db`), mutmut has to
run wherever the tests normally run — inside the container, not on the host.

mutmut runs from a `mutants/` copy of the project, so anything the tests read
from disk has to be copied with it:

```toml
[tool.mutmut]
also_copy = ["openapi.json"]
```

**`mutmut run` exits 0 whether or not anything survived, and prints `🙁` rather
than a word.** Scripting against its exit code or grepping its output reports
clean with survivors sitting there:

```bash
# BAD — always looks clean
mutmut run && echo "tests are proven"

# GOOD — results is the readable source
mutmut run >/dev/null 2>&1
mutmut results          # <mutant name>: survived, one per line
```

It is also installed into the project environment, not onto `PATH`. Reach it the
way the project does — `uv run mutmut`, `poetry run mutmut`, or
`./.venv/bin/mutmut` — or a script calling bare `mutmut` finds nothing.

### A Parametrize Id With An Accent Aborts The Whole Run

mutmut records the test ids covering each function and hands them back to pytest.
pytest escapes a non-ASCII id, so the one it gets back matches nothing:

```python
# BAD — pytest writes this id as `la m\xe1s pedida`; mutmut's rerun answers
# "ERROR: not found", exit code 4, and the run dies before one mutant is tested
ids=["renamed", "price moved", "la más pedida"]

# GOOD
ids=["renamed", "price moved", "la mas pedida"]
```

One accent in one id left 786 mutants "not checked" on a real API, which reads
exactly like a database the run could not reach. It only bites a scoped run —
the ids are collected per function — so mutating the whole repo hides it.

### Code That Runs At Import Never Sees A Mutant

mutmut imports the project once to collect stats, then forks one child per mutant
with that mutant switched on. The child inherits every module already loaded, so a
function called only at import never runs again. In one API all 39 mutants in
`routers.py` survived in about 0.08s each. That is **unreachable**, not equivalent:
the same file holds `if settings.dev_tools_enabled`, the guard that keeps the admin
endpoints out of production.

```python
# BAD — the only call is at import, so no test can reach these mutants
app = FastAPI(lifespan=lifespan)
register_routers(app, settings)

# GOOD — the test calls it after the fork, with the mutant live
def test_dev_routes_are_absent_when_the_flag_is_off():
    app = FastAPI()
    register_routers(app, Settings(dev_tools_enabled=False))
    assert not [route for route in app.routes if "/dev/" in route.path]
```

When there is nothing worth asserting, skip it at the source. A baseline entry comes
back every time the function is edited; the pragma does not. mutmut reads only the
first word after `no mutate`, so the reason goes after a comma:

```python
def configure_logging() -> None:  # pragma: no mutate block, runs only at import
```

## Reading the Output

Stryker prints a summary table on **every** run whose header contains a
`# survived` column. Grepping the raw output for the word reports survivors on a
clean run:

```
File      | % score | # killed | # timeout | # survived |
```

Match the finding marker instead — Stryker prefixes each real one with
`[Survived]`, followed by the location:

```
[Survived] StringLiteral
src/components/ExpenseRow.tsx:46:9
```

mutmut has the opposite problem: it prints `🙁` and never the word at all.
`mutmut results` prints `<mutant name>: survived`, which is the line to parse.

## Silencing Noise Without Going Blind

Roughly 40% of a first React run is class-name noise — mutating a `className`
string, or a `settled ? "text-foreground" : "text-muted-foreground"` ternary.
Killing those means asserting on CSS class names, which tests the stylesheet.
Un-closeable findings are what teach people to skip the gate.

```json
// BAD — also stops mutating real strings: labels, separators, keys
{ "mutator": { "excludedMutations": ["StringLiteral"] } }
```

Ignore by **where the mutant sits**, not by what kind it is. Stryker's Ignore
plugin takes a Babel `NodePath`; `path.find` tests the node and its ancestors:

```js
// GOOD — stryker-classname-ignorer.mjs — .mjs, not .js: an app without
// "type": "module" in its package.json cannot load ESM from a .js file.
import { PluginKind, declareValuePlugin } from "@stryker-mutator/api/plugin";

export const strykerPlugins = [
  declareValuePlugin(PluginKind.Ignore, "tailwind-classnames", {
    shouldIgnore(path) {
      if (path.find((p) => p.isJSXAttribute() && p.node.name.name === "className"))
        return "styling, not behaviour";
      if (path.find((p) => p.isCallExpression() && p.node.callee.name === "cn"))
        return "styling, not behaviour";
    },
  }),
];
```

```json
{ "plugins": ["@stryker-mutator/vitest-runner", "./stryker-classname-ignorer.mjs"],
  "ignorers": ["tailwind-classnames"] }
```

`shouldIgnore` returns a reason string to ignore, `undefined` to keep. Ignored
mutants are reported as `ignored` and do not affect the score.

**On pnpm, install `@stryker-mutator/api` yourself.** The ignorer imports it,
but nothing depends on it directly — npm hoists it into the flat `node_modules`
so the import resolves by accident, and pnpm's isolated store does not. The run
does not fail: it prints one `WARN PluginLoader` line, loads no ignorer, and
reports every class-name mutant as survived, exactly as if the plugin were
never written.

```
pnpm add -D @stryker-mutator/api
```

For a one-off, the comment escape hatch beats a global rule:

```ts
// Stryker disable next-line StringLiteral: the label is asserted in the e2e test
```

Block form is `// Stryker disable <Mutator>` … `// Stryker restore <Mutator>`.

### `next-line` Means The Next Line, Literally

It binds to the physical line below the comment, and three things routinely move
that line out from under it. One session lost three attempts to this before the
directive took.

```ts
// BAD — the formatter owns this line. Biome or Prettier re-wraps the const onto
// two lines and the directive now points at the opening bracket.
// Stryker disable next-line StringLiteral: copy, asserted in the e2e test
const label = buildLabel(prefix, suffix, separator, fallbackWhenEmpty)
```

```ts
// BAD — above a declaration it targets the signature, not the body. The mutant
// you meant to silence is inside the function and still gets generated.
// Stryker disable next-line MethodExpression: equivalent, both sides folded
function plain(text: string): string {
  return text.toLowerCase().normalize('NFD')
}
```

```ts
// BAD — Stryker reads `//` comments in the source. Inside JSX this is a text
// node, not a comment, and the directive is never seen.
<span>{/* Stryker disable next-line StringLiteral */}{label}</span>
```

```ts
// GOOD — hoist the expression to its own named const and put the comment
// directly above it. One short line the formatter will not re-wrap, and the
// mutant sits on exactly the line the directive names.
function plain(text: string): string {
  // Stryker disable next-line MethodExpression: equivalent, both sides folded
  return text.toLowerCase().normalize('NFD')
}
```

Re-run the gate after adding one. A directive that silently misses reads exactly
like a directive that worked — the survivor is still there, and the only symptom
is that your comment did nothing.

### Prefer `ignoreStatic` Over Silencing A Data Table

A string in a module-level array or object is a **static mutant** — evaluated
once at file load. Stryker's docs give the same shape as the example:
`const hi = '👋'` → `const hi = ''`. Testing one "often requires running all
tests", so a table of 11 headings and 16 term rows produced 57 survivors and a
ten-minute gate.

Do not silence those one by one, and do not write threshold tests
(`expect(TERMS.length).toBeGreaterThan(10)`) to kill them — that is a test
written for the gate, not for the code. Set the option instead:

```json
{ "coverageAnalysis": "perTest", "ignoreStatic": true }
```

`ignoreStatic` requires `perTest` coverage analysis. On one real project this
took the gate from timing out past 600s to 1m33s, and the `Stryker disable`
blocks around both tables became dead and were deleted.

**A mutant is only static if it never runs again after load.** A helper called
at runtime is not static even when it is declared at module level, so its
mutants still need a disable comment or a real test.

## An Incremental Typecheck Can Lie

`tsc -b` reuses `.tsbuildinfo`, so a second run can report a green the first run earned
and the code no longer does. An agent ran `npm run typecheck`, got exit 0, and said
"typecheck clean"; the same command from the gate returned two real `TS2532` errors on
the same files. The gate was right.

Treat a green from an incremental build as evidence only when it is the run that actually
compiled. In a gate, prefer a fresh build — or at least do not trust a pass that follows
one you already ran.

## Scores and Thresholds

70–85% on meaningful code is the working range. Past that you are mostly fighting
equivalent mutants — mutations that cannot change behaviour, so no test can kill
them. Below 60% means the suite has real gaps.

Do not adopt a repo-wide score first. Start with one module that matters, kill the
highest-value survivors, then set a break threshold so the number can only go up.
Raise it for code where a bug costs money or data; leave generated code, vendored
libraries, and pure-layout components out entirely.

Scope every run to the diff. Whole-repo mutation on a small change is the single
biggest source of wasted wall-clock, and it is why teams abandon this after a week.

## Rules

- Always run mutation scoped to the changed lines, never the whole repo.
- Always pass one comma-joined `--mutate`; a repeated flag overrides, it does not append.
- Always repeat the file name on every range inside that value.
- Always check for Vitest browser mode first — Stryker cannot run it; mutate by hand, one edit per run, restoring before the next.
- Never count a mutant that fails to parse as killed.
- Always spread `configDefaults.exclude` when adding `.stryker-tmp`, and gitignore it.
- Always install the tool the way the project manages dependencies (uv, poetry, npm workspace).
- Always match `[Survived]` for Stryker findings — the summary header contains the word `survived` on a clean run.
- Always read mutmut's verdict from `mutmut results`; `mutmut run` exits 0 either way and prints no word to grep.
- Never baseline a survivor in import-time code as equivalent — call the function from a test, or mark it `# pragma: no mutate block, <reason>`.
- Never put a non-ASCII character in a `parametrize` id — mutmut hands the escaped id back to pytest, which finds nothing, and the run dies with every mutant "not checked".
- Always invoke mutmut through the project's environment (`uv run`, `poetry run`, `./.venv/bin/`) — it is not on PATH.
- Always use `source_paths` / `pytest_add_cli_args_test_selection` for mutmut 3; `paths_to_mutate` and `tests_dir` are silently ignored.
- Always ignore a mutant by where it sits (Ignore plugin, disable comment), never by disabling a whole mutator globally.
- Always set `ignoreStatic: true` alongside `perTest` — a module-level table is static, and one static mutant can cost a full suite run.
- Always put `disable next-line` above a short line a formatter cannot re-wrap; hoist the expression to its own const when it is long.
- Never put `disable next-line` above `function foo() {` — it targets the signature, not the body — or inside a JSX `{/* */}` comment, where it is never read.
- Always re-run the gate after adding a disable comment; one that missed looks exactly like one that worked.
- Never write a threshold test (`expect(TERMS.length).toBeGreaterThan(10)`) to kill a mutant — that is a test written for the gate, not for the code.
- Always prefer mutating logic modules over presentation; component mutants are class names, copy and JSX shape, and none of it is behaviour.
- Always give Stryker a Vitest config that runs logic tests only; page tests make every mutant slow and pass off untested logic as killed.
- Always keep a hook test in `hooks/` or `queries/`, even as `.tsx`, so that config still runs it.
- Always add `@stryker-mutator/api` as a direct dependency on pnpm, or the Ignore plugin silently does not load.
- Never mutate test files — that only asks whether the tests test the tests.
- Never treat a surviving mutant as a fact about the code; it is a fact about the tests.
- Never chase 100%: equivalent mutants make the last stretch unkillable.
