# Property Tests — Rules That Must Hold For Any Input

An example test checks the inputs you thought of. A property test states a rule
and lets a library hunt for the input that breaks it, then shrinks that input to
the smallest one that still fails. On pure code, one property kills far more
mutants than one example.

## Contents

- [When To Reach For One](#when-to-reach-for-one)
- [Five Rule Shapes](#five-rule-shapes)
- [fast-check — JS/TS](#fast-check--jsts)
  - [Fix The Seed Or Stryker Lies](#fix-the-seed-or-stryker-lies)
  - [Replaying A Failure](#replaying-a-failure)
- [Hypothesis — Python](#hypothesis--python)
- [A Shrunk Failure Becomes An Example](#a-shrunk-failure-becomes-an-example)
- [Traps](#traps)
- [Rules](#rules)

## When To Reach For One

Pure code with a large input space: parsers, serializers, formatters, money math,
validators, slug and id builders, anything with an `encode` and a `decode`.
Not UI rendering, not database queries, not code that is mostly I/O — keep
example tests there.

```ts
// BAD — three inputs the author already knew worked
test("escapes commas", () => {
  expect(unescapeField(escapeField("a,b"))).toBe("a,b");
  expect(unescapeField(escapeField(""))).toBe("");
  expect(unescapeField(escapeField('say "hi"'))).toBe('say "hi"');
});
```

```ts
// GOOD — every string, including the quote-only ones nobody writes by hand
test("escape round trip", () => {
  fc.assert(fc.property(fc.string(), (s) => {
    expect(unescapeField(escapeField(s))).toBe(s);
  }));
});
```

Keep the examples that document intent. Add the property next to them.

## Five Rule Shapes

Write the rule in one plain sentence first. If you cannot, there is no property.

```ts
// Round trip — decode undoes encode
expect(parse(serialize(x))).toEqual(x);

// Invariant — something is never lost or never out of range
expect(chunk(xs, n).flat()).toEqual(xs);
expect(cartTotal(items)).toBe(sum(items.map((i) => i.price)));

// Idempotent — doing it twice equals doing it once
expect(normalize(normalize(s))).toBe(normalize(s));

// Oracle — the fast version equals the slow, obviously right one
expect(fastMedian(xs)).toBe(xs.toSorted((a, b) => a - b)[mid(xs)]);

// Never throws, right type — on every valid input
expect(() => formatDuration(ms)).not.toThrow();
```

The cheap shapes matter most: "never throws", "stays in this set", "is this
type" kill more mutants per line than clever ones.

## fast-check — JS/TS

`fast-check` with `fc.assert` inside a plain Vitest `test`. Default is 100 inputs
per property.

### Fix The Seed Or Stryker Lies

fast-check seeds from `Date.now()`, so every run tries different inputs. Under
Stryker that gives a different survivor list on the same code: 2 lists in 10 runs
at 100 inputs, 8 lists in 10 at 20 inputs. A fixed seed gave one list every time.

```ts
// GOOD — vitest setup file; FC_SEED overrides it for a manual exploring run
import fc from "fast-check";

fc.configureGlobal({ seed: Number(process.env.FC_SEED ?? 42) });
```

```ts
// vitest.config.ts
export default defineConfig({ test: { setupFiles: ["./test/fast-check.setup.ts"] } });
```

`configureGlobal` replaces every earlier global setting. Call it once, in one file.

A fixed seed makes the result stable, not strong. Keep the default 100 inputs:
with a fixed seed at 20, Stryker let 15 mutants survive instead of 13, and
mutmut let 23 survive instead of 7 — the same weak verdict every run.

`@fast-check/vitest`'s `test.prop` puts the seed in the test name. With a random
seed the name changes between Stryker's first run and each mutant run, Stryker
finds no test to run, and every mutant reports **Survived**.

```ts
// BAD — no fixed seed: 36 of 37 mutants "survive", 0 tests ran on any of them
test.prop([fc.string()])("escape round trip", (s) => { /* … */ });
```

```ts
// GOOD — either plain fc.assert, or test.prop with the setup file above loaded
test("escape round trip", () => {
  fc.assert(fc.property(fc.string(), (s) => { /* … */ }));
});
```

Explore with new inputs by hand, never inside the gate:

```bash
FC_SEED=$RANDOM npx vitest run src/csv.test.ts
```

### Replaying A Failure

A failure prints the exact replay key. Paste it into the assertion, fix, remove it.

```
Property failed after 3 tests
{ seed: -1976533768, path: "2:0:1", endOnFailure: true }
Counterexample: ["\""]
```

```ts
fc.assert(fc.property(fc.string(), check), { seed: -1976533768, path: "2:0:1", endOnFailure: true });
```

## Hypothesis — Python

`@given` with strategies. Defaults: 100 inputs, a 200 ms limit per input, random
inputs, and failures saved to `.hypothesis/` in the working directory. Under
mutmut the defaults gave 2 survivor lists in 10 runs on the same code; at 20
inputs, 7 lists in 10. The profile below gave one list every time. The time
limit is a wall-clock check, so it is off too, as in Hypothesis's own CI profile.

```python
# GOOD — conftest.py; HYPOTHESIS_PROFILE=explore for a manual exploring run
import os
from hypothesis import settings

settings.register_profile("gate", derandomize=True, deadline=None, database=None)
settings.register_profile("explore", max_examples=1000)
settings.load_profile(os.getenv("HYPOTHESIS_PROFILE", "gate"))
```

```python
from hypothesis import given, strategies as st

@given(st.text())
def test_escape_round_trip(s):
    assert unescape_field(escape_field(s)) == s
```

`derandomize=True` derives the seed from the test itself: the inputs change when
the test changes, and never between two runs of the same tree.

```gitignore
.hypothesis/
```

## A Shrunk Failure Becomes An Example

The shrunk input is the regression test. Pin it so it runs first, on every seed.

```python
# GOOD — runs before any generated input, does not count toward max_examples
@given(st.text())
@example('"')
def test_escape_round_trip(s): ...
```

```ts
// GOOD
fc.assert(fc.property(fc.string(), check), { examples: [['"']] });
```

## Traps

```ts
// BAD — the test re-implements the code, so it agrees with the bug
expect(price(x)).toBe(x.base * (1 - x.discount) * TAX);
// GOOD — a rule the code must obey, written independently
expect(price(x)).toBeLessThanOrEqual(x.base * TAX);
```

```python
# BAD — the assertion can never fail
@given(st.text())
def test_parse(s):
    try:
        assert parse(render(s)) == s
    except Exception:
        pass
```

```ts
// BAD — most generated values are thrown away; fast-check fails the run
fc.property(fc.integer(), (n) => { fc.pre(n > 0 && n % 7 === 0); /* … */ });
// GOOD — generate only valid input
fc.property(fc.integer({ min: 1, max: 1000 }).map((k) => k * 7), (n) => { /* … */ });
```

A property derived from a guess is a false bug. Take the rule from the docs,
the types, the name, or the callers — and when it fails, check the rule before
you change the code.

## Rules

- Always write the property as one plain sentence before writing the test.
- Always fix the seed for any run the gate makes: `fc.configureGlobal({ seed })` in a Vitest setup file, a `derandomize=True, deadline=None, database=None` Hypothesis profile in `conftest.py`.
- Never use `test.prop` without that fixed seed — Stryker kills nothing.
- Never lower the input count below the default 100 to save time; a fixed seed keeps a weak run weak.
- Always pin a shrunk failure as an explicit example (`@example`, `examples:`).
- Never re-implement the code under test inside the property; assert a rule it must obey.
- Never wrap a property's assertion in `try`/`except` or `try`/`catch`.
- Always generate valid input directly instead of filtering it with `fc.pre` or `assume`.
- Always keep `.hypothesis/` in `.gitignore`.
- Explore with new seeds by hand (`FC_SEED=$RANDOM`, `HYPOTHESIS_PROFILE=explore`), never inside the gate.
