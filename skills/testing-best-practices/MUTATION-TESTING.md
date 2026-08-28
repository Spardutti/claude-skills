# Mutation Testing — Proving the Tests Are Real

A suite written alongside the code passes by construction. Coverage says the line
ran, not that anything checked the result. Mutation testing breaks the code on
purpose and reports which breaks no test noticed — the only check the author of
the tests cannot accidentally pass.

## Contents

- [What It Catches That Review Does Not](#what-it-catches-that-review-does-not)
- [Stryker — JS/TS](#stryker--jsts)
- [The Sandbox Trap](#the-sandbox-trap)
- [mutmut — Python](#mutmut--python)
- [Reading the Output](#reading-the-output)
- [Silencing Noise Without Going Blind](#silencing-noise-without-going-blind)
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

`coverageAnalysis: "perTest"` is the line that makes this usable: Stryker maps
which test covers which line and runs only those per mutant, instead of the whole
suite every time.

Scope it to what changed, one flag per range:

```bash
npx stryker run --incremental --force \
  --mutate 'src/a.ts:12-30' --mutate 'src/a.ts:58-61'
```

Ranges are `file:startLine[:startCol]-endLine[:endCol]`, and a range **cannot**
be combined with a glob in the same entry. `--force` is required alongside a
custom `--mutate`, or incremental mode reuses the cached verdict for those lines.

Never comma-join ranges across files: a file's own ranges are already
comma-separated (`a.ts:3-3,7-7`), so the two levels collide and Stryker reads
`7-7` as a filename.

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
// GOOD — stryker-classname-ignorer.js
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
{ "plugins": ["@stryker-mutator/vitest-runner", "./stryker-classname-ignorer.js"],
  "ignorers": ["tailwind-classnames"] }
```

`shouldIgnore` returns a reason string to ignore, `undefined` to keep. Ignored
mutants are reported as `ignored` and do not affect the score.

For a one-off, the comment escape hatch beats a global rule:

```ts
// Stryker disable next-line StringLiteral: the label is asserted in the e2e test
```

Block form is `// Stryker disable <Mutator>` … `// Stryker restore <Mutator>`.

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
- Always set `coverageAnalysis: "perTest"` — without it every mutant runs the whole suite.
- Always spread `configDefaults.exclude` when adding `.stryker-tmp`, and gitignore it.
- Always install the tool the way the project manages dependencies (uv, poetry, npm workspace).
- Always match `[Survived]` for Stryker findings — the summary header contains the word `survived` on a clean run.
- Always use `source_paths` / `pytest_add_cli_args_test_selection` for mutmut 3; `paths_to_mutate` and `tests_dir` are silently ignored.
- Always ignore a mutant by where it sits (Ignore plugin, disable comment), never by disabling a whole mutator globally.
- Never mutate test files — that only asks whether the tests test the tests.
- Never treat a surviving mutant as a fact about the code; it is a fact about the tests.
- Never chase 100%: equivalent mutants make the last stretch unkillable.
