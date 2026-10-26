#!/usr/bin/env bash
[ -n "${SELFTEST_SANDBOX:-}" ] || { echo "$(basename "$0"): run it through scripts/gauntlet-selftest.sh, never on its own" >&2; exit 1; }

echo "the /ship log: survivors fixed but never logged"
newrepo sg_settle
mkdir -p src "$HOME/.claude"; echo 'GAUNTLET_SHIP_LOG=1' > "$HOME/.claude/gauntlet.conf"
printf '{"devDependencies":{"@stryker-mutator/core":"8"}}\n' > package.json
printf 'export const a = 1\n' > src/a.ts
printf '#!/bin/sh\ncat "%s"\n' "$SLOUT" > .stryker-run; chmod +x .stryker-run
git add -A; git commit -qm base; git branch -q develop; git checkout -qb feat/s
SETTLE="$SLOGS/open/sg_settle__feat-s.json"
bash "$HERE/ship-mark.sh" begin
{ printf '[Survived] EqualityOperator\nsrc/a.ts:2:10\n'; sl_table 3 1; } > "$SLOUT"
printf 'export const a2 = a >= 1\n' >> src/a.ts
bash "$SG" >/dev/null 2>&1
sl_table 4 0 > "$SLOUT"; printf 'import { a2 } from "./a";\n' > src/a.test.ts
bash "$SG" >/dev/null 2>&1
node "$SL" pr 77 >/dev/null
sl_is "a FAIL a later PASS cleared is logged as fixed survivors when nobody logged them" "$SLOGS/sg_settle_${DAY}_pr77.json" \
  'const m = r.findings.filter((f) => f.by === "mutation"); m.length === 1 && m[0].what === "EqualityOperator at src/a.ts:2:10" && m[0].fixed && r.summary.findings.mutation.confirmed === 1'
rm -rf "$HOME/.claude/gauntlet.conf" "$SLOGS"
