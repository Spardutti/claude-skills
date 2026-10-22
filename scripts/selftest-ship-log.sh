#!/usr/bin/env bash

echo "the /ship log"
SL="$HERE/ship-log.mjs"; SLOGS="$HOME/.claude/ship-logs"; SLOUT="$TMP/ship-log-stryker.out"; DAY=$(date -u +%F)
SLOPEN="$SLOGS/open/sg_log__feat-x.json"

sl_table() {  # sl_table <killed> <survived>
  printf 'File         |  total | covered | # killed | # timeout | # survived | # no cov | # errors |\n'
  printf 'All files    |  75.00 |   75.00 |       %s |         0 |          %s |        0 |        0 |\n' "$1" "$2"
}

sl_is() {  # sl_is <label> <json file> <JS expression over r>
  N=$((N+1))
  if node -e 'const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.exit(eval(process.argv[2]) ? 0 : 1)' "$2" "$3" 2>/dev/null; then
    PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s — %s\n       in %s\n' "$1" "$3" "$(head -c 1500 "$2" 2>/dev/null || echo missing)"; fi
}

sl_ok() {  # sl_ok <label> <condition command...>
  local label=$1; shift; N=$((N+1))
  if "$@"; then PASS=$((PASS+1)); printf '  ok   %s\n' "$label"; else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$label"; fi
}

newrepo sg_log
mkdir -p src
printf '{"devDependencies":{"@stryker-mutator/core":"8"}}\n' > package.json
printf 'export const a = 1\n' > src/a.ts
printf '#!/bin/sh\ncat "%s"\n' "$SLOUT" > .stryker-run; chmod +x .stryker-run
git remote add origin "git@github.com:acme/sg_log.git"
git add -A; git commit -qm base; git branch -q develop; git checkout -qb feat/x

{ printf '[Survived] EqualityOperator\nsrc/a.ts:2:10\n'; sl_table 3 1; } > "$SLOUT"
printf 'export const a2 = a >= 1\n' >> src/a.ts
printf 'notes\n' > NOTES.txt
bash "$SG" >/dev/null 2>&1
sl_ok "with the log off, the gate writes nothing" test ! -e "$SLOGS"

mkdir -p "$HOME/.claude"; echo 'GAUNTLET_SHIP_LOG=1' > "$HOME/.claude/gauntlet.conf"
bash "$SG" >/dev/null 2>&1; rc=$?
sl_ok "a FAIL keeps its exit code with the log on" test "$rc" = 1
sl_is "the run is logged under the app and branch" "$SLOPEN" 'r.app === "sg_log" && r.branch === "feat/x" && r.gate.length === 1 && r.gate[0].verdict === "FAIL" && r.gate[0].exit === 1'
sl_is "it names the files it mutated" "$SLOPEN" 'JSON.stringify(r.gate[0].projects[0].mutated) === "[\"src/a.ts\"]"'
sl_is "it keeps each survivor with its mutator and place" "$SLOPEN" 'const s = r.gate[0].projects[0].survivors[0]; s.mutator === "EqualityOperator" && s.at === "src/a.ts:2:10"'
sl_is "it keeps Stryker's counts" "$SLOPEN" 'const c = r.gate[0].projects[0].counts; c.total === 4 && c.killed === 3 && c.survived === 1'
sl_is "it measures the PR from the fork point" "$SLOPEN" 'r.size.files === 2 && r.size.code.files === 1 && r.size.code.added === 1 && r.size.other.files === 1 && r.size.tests.files === 0'
sl_is "it keeps the whole report" "$SLOPEN" 'r.gate[0].report.includes("ship-gate: FAIL")'

sl_table 4 0 > "$SLOUT"
printf 'import { a2 } from "./a";\n' > src/a.test.ts
bash "$SG" >/dev/null 2>&1
sl_is "a second run is added, not replaced" "$SLOPEN" 'r.gate.length === 2 && r.gate[1].verdict === "PASS"'
sl_is "test files are counted apart" "$SLOPEN" 'r.size.tests.files === 1 && r.size.tests.added === 1'
bash "$SG" >/dev/null 2>&1
sl_is "a file that passed is logged as reused, not mutated" "$SLOPEN" 'const p = r.gate[2].projects[0]; p.result === "cached" || p.reused.includes("src/a.ts")'

node "$SL" finding '{"by":"review","what":"null user crash","verdict":"refuted","fixed":false}' 2>/dev/null
node "$SL" finding '{"by":"mutation","what":"boundary 1","verdict":"confirmed","fixed":true}' 2>/dev/null
sl_is "findings are recorded" "$SLOPEN" 'r.findings.length === 2 && r.findings[0].verdict === "refuted"'
err=$(node "$SL" finding '{"by":"review","what":"x","verdict":"maybe","fixed":false}' 2>&1); rc=$?
sl_ok "a finding with an unknown verdict is refused" test "$rc" = 1 -a -n "$(printf '%s' "$err" | grep 'a finding needs')"
node "$SL" step review start; node "$SL" step review end
sl_is "a step is timed" "$SLOPEN" 'typeof r.steps.review.seconds === "number"'

node "$SL" pr 142 >/dev/null
SLPR="$SLOGS/sg_log_${DAY}_pr142.json"
sl_ok "the PR closes the log under app, date and PR number" test -f "$SLPR" -a ! -e "$SLOPEN"
sl_is "and sums it up" "$SLPR" 'r.status === "pr-opened" && r.summary.gateRuns === 3 && r.summary.findings.review.refuted === 1 && r.summary.findings.mutation.fixed === 1'

git add -A; git commit -qm x; git checkout -qb feat/y; printf 'export const y = 1\n' > src/y.ts
bash "$SG" --force >/dev/null 2>&1
sl_is "a forced receipt is logged too" "$SLOGS/open/sg_log__feat-y.json" 'r.gate[0].verdict === "FORCED"'
node "$SL" end "stopped at commit" >/dev/null
sl_is "a ship that stops before the PR is saved with why" "$SLOGS/sg_log_${DAY}_feat-y.json" 'r.status === "stopped" && r.reason === "stopped at commit"'
out=$(node "$SL" report)
sl_ok "the report lists every ship" test -n "$(printf '%s' "$out" | grep '#142')" -a -n "$(printf '%s' "$out" | grep 'feat/y')"

{ printf '[Survived] EqualityOperator\nsrc/y.ts:1:1\n'; sl_table 0 1; } > "$SLOUT"
: > "$TMP/not-a-dir"; echo "GAUNTLET_SHIP_LOG_DIR=$TMP/not-a-dir/logs" > .claude/gauntlet.conf
bash "$SG" >/dev/null 2>&1; rc=$?
sl_ok "a log that cannot be written never changes the verdict" test "$rc" = 1
echo 'GAUNTLET_SHIP_LOG=""' > .claude/gauntlet.conf
node "$SL" on; rc=$?
sl_ok "a project's own conf turns the log off" test "$rc" = 1
rm -f "$HOME/.claude/gauntlet.conf"

MM=$(printf '%s\n' 'MUTATION — 1 project(s) in this diff' '  api/ mutmut (12s) — these lines can break and no test notices:' \
  '      app.shipping.x_cost__mutmut_3' '      app.models.xǁOrderǁtotal__mutmut_1' \
  '      Only runs at import (app setup, router registration)? Then it is unreachable,' 'ship-gate: FAIL in 13s')
N=$((N+1))
if node --input-type=module -e "import { parseReport } from '$HERE/ship-log-parse.mjs'; const p = parseReport(process.argv[1]).projects[0]; process.exit(p.tool === 'mutmut' && p.seconds === 12 && p.survivors.length === 2 && p.survivors[1].at === 'app.models.xǁOrderǁtotal__mutmut_1' ? 0 : 1)" "$MM"; then
  PASS=$((PASS+1)); echo "  ok   mutmut survivors are logged, class methods included"
else FAIL=$((FAIL+1)); echo "  FAIL mutmut survivors are logged, class methods included"; fi

newrepo sg_log2
mkdir -p src
printf '{"devDependencies":{"@stryker-mutator/core":"8"}}\n' > package.json
printf 'export const r = 1\n' > src/r.ts
printf '#!/bin/sh\ncat "%s"\n' "$SLOUT" > .stryker-run; chmod +x .stryker-run
git remote add origin "git@github.com:acme/sg_log2.git"
git add -A; git commit -qm base; git branch -q develop; git checkout -qb feat/r
SL2="$SLOGS/open/sg_log2__feat-r.json"
printf 'echo noise\nGAUNTLET_SHIP_LOG=1\n[ -n "${SL_NOPE:-}" ] && GAUNTLET_MAX_LINES=300\n' > "$HOME/.claude/gauntlet.conf"
node "$SL" on; rc=$?
sl_ok "a conf that prints or ends on a false test still turns the log on" test "$rc" = 0
git mv src/r.ts src/renamed.ts; printf 'export const r2 = 2\n' >> src/renamed.ts; git commit -qam mv
sl_table 1 0 > "$SLOUT"; touch "$TMP/sl-mark"
bash "$SG" >/dev/null 2>&1
sl_is "a renamed file still counts as code" "$SL2" 'r.size.code.files === 2 && r.size.other.files === 0'
find /tmp -maxdepth 1 -name 'claude-shipgate-file-*' -newer "$TMP/sl-mark" -delete 2>/dev/null
bash "$SG" >/dev/null 2>&1
sl_is "a project reused from its receipt lists nothing as mutated" "$SL2" 'const p = r.gate[1].projects[0]; p.result === "cached" && p.mutated.length === 0'
node "$SL" finding '{"by":"review","what":"x","verdict":"confirmed","fixed":false}'
out=$(node "$SL" report 2>&1)
sl_ok "the report counts findings of a ship still open" test -n "$(printf '%s' "$out" | grep 'review 1/1/0')"
echo '{"something":"else"}' > "$SLOGS/foreign.json"
node "$SL" report >/dev/null 2>&1; rc=$?
sl_ok "a JSON file that is not a ship log never breaks the report" test "$rc" = 0
node "$SL" start
sl_is "start closes a ship left open as abandoned" "$SLOGS/sg_log2_${DAY}_feat-r.json" 'r.status === "abandoned" && r.gate.length === 2'
sl_is "and opens a fresh one" "$SL2" 'r.gate.length === 0 && r.findings.length === 0'
printf 'ship-gate: no changed code files — nothing to check\n' > "$TMP/sl-docs.log"
node "$SL" gate "$TMP/sl-docs.log" 0 0 ""
sl_is "a docs-only pass is logged as PASS" "$SL2" 'r.gate[0].verdict === "PASS"'
N=$((N+1))
if node --input-type=module -e "import { parseReport } from '$HERE/ship-log-parse.mjs'; process.exit(parseReport('ship-gate:        3 changed code file(s), base abc').scope === 3 ? 0 : 1)"; then
  PASS=$((PASS+1)); echo "  ok   a padded file count (macOS wc) is read"
else FAIL=$((FAIL+1)); echo "  FAIL a padded file count (macOS wc) is read"; fi
rm -f "$HOME/.claude/gauntlet.conf"
printf 'ship-gate: 1 changed code file(s), base abc\nMUTATION — 1 project(s) in this diff\n' > "$TMP/sl-cut.log"
echo 'GAUNTLET_SHIP_LOG=1' > "$HOME/.claude/gauntlet.conf"
node "$SL" gate "$TMP/sl-cut.log" 0 39 ""
sl_is "a run cut off before its verdict is logged as INTERRUPTED, never PASS" "$SL2" 'r.gate.at(-1).verdict === "INTERRUPTED"'
rm -f "$HOME/.claude/gauntlet.conf"
