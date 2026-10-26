#!/usr/bin/env bash
[ -n "${SELFTEST_SANDBOX:-}" ] || { echo "$(basename "$0"): run it through scripts/gauntlet-selftest.sh, never on its own" >&2; exit 1; }

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
printf 'notes\n' > NOTES.txt; printf 'old debt\n' > .lint-baseline
bash "$SG" >/dev/null 2>&1
sl_ok "with the log off, the gate writes nothing" test ! -e "$SLOGS"

mkdir -p "$HOME/.claude"; echo 'GAUNTLET_SHIP_LOG=1' > "$HOME/.claude/gauntlet.conf"
bash "$SG" >/dev/null 2>&1
sl_ok "a gate run outside /ship writes no log" test ! -e "$SLOPEN"
git checkout -qb feat/rel; bash "$HERE/ship-mark.sh" begin --no-log
sl_ok "a release's mark is set" bash "$HERE/ship-mark.sh" check
git checkout -q feat/x
sl_ok "a release's mark opens no log" test ! -e "$SLOGS/open/sg_log__feat-rel.json"
bash "$HERE/ship-mark.sh" begin
sl_ok "the /ship mark opens the log, so it never hangs on the agent" test -f "$SLOPEN"
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
node "$SL" finding '{"by":"review","what":"old cap","verdict":"skipped","fixed":false,"note":"skipped: old code"}' 2>/dev/null
sl_is "a finding sorted out before testing is logged as skipped" "$SLOPEN" 'r.findings.length === 3 && r.findings[2].verdict === "skipped"'
(cd / && CLAUDE_PROJECT_DIR="$OLDPWD" node "$SL" finding '{"by":"audit:x","what":"from a worktree session","verdict":"refuted","fixed":false}' 2>/dev/null)
sl_is "CLAUDE_PROJECT_DIR points the log at that folder, like the other ship scripts" "$SLOPEN" 'r.findings.length === 4 && r.findings[3].by === "audit:x"'
node "$SL" ready >/dev/null 2>&1; rc=$?
sl_ok "a ship with no review yet, like a release, is never held for the log" test "$rc" = 0
printf '%s\n' '{"ts":"2999-01-01T00:00:00Z","branch":"feat/x","reply":"```json\n{\"findings\":[1,2]}\n```"}' > .claude/review-findings.jsonl
node "$SL" ready >/dev/null 2>&1; rc=$?
sl_ok "a review reply that is not a list skips the whole check, not half of it" test "$rc" = 0
sleep 1
node -e 'const now = new Date().toISOString().replace(/\.\d+Z$/, "Z");
  const f = (ts, branch, n) => JSON.stringify({ ts, branch, reply: "```json\n" + JSON.stringify(Array.from({ length: n }, (_, i) => ({ summary: "bug " + i, failure_scenario: "x" }))) + "\n```" });
  process.stdout.write([f("2020-01-01T00:00:00Z", "feat/x", 9), f(now, "feat/x", 3), f(now, "feat/other", 9), JSON.stringify({ ts: now, branch: "feat/x" })].join("\n") + "\n")' > .claude/review-findings.jsonl
out=$(node "$SL" ready 2>&1); rc=$?
sl_ok "after a review, a PR waits for the review step" test "$rc" = 1 -a -n "$(printf '%s' "$out" | grep 'step review end')"
sl_ok "and for every finding of this branch's latest review, logged after it" test -n "$(printf '%s' "$out" | grep '0 of 3')"
sl_ok "and says how to log a duplicate" test -n "$(printf '%s' "$out" | grep 'duplicate of')"
sl_ok "and names a command that runs from any folder, with no cd" test -n "$(printf '%s' "$out" | grep -F "SHIP_LOG_ROOT='$PWD' node '$SL' step review end")" -a -z "$(printf '%s' "$out" | grep 'cd ')"
(cd / && SHIP_LOG_ROOT="$OLDPWD" node "$SL" step review start && SHIP_LOG_ROOT="$OLDPWD" node "$SL" step review end)
sl_is "a step is timed" "$SLOPEN" 'typeof r.steps.review.seconds === "number"'
node "$SL" step audit end
sl_is "a step that only logged its end starts where the last one ended" "$SLOPEN" 'r.steps.audit.start === r.steps.review.end && r.steps.audit.seconds >= 0'
for i in 0 1 2; do node "$SL" finding "{\"by\":\"review\",\"what\":\"bug $i\",\"verdict\":\"confirmed\",\"fixed\":true}" 2>/dev/null; done
node "$SL" ready >/dev/null 2>&1; rc=$?
sl_ok "and opens once they are" test "$rc" = 0
node "$SL" pr 142 >/dev/null
SLPR="$SLOGS/sg_log_${DAY}_pr142.json"
sl_ok "the PR closes the log under app, date and PR number" test -f "$SLPR" -a ! -e "$SLOPEN"
sl_is "and sums it up" "$SLPR" 'r.status === "pr-opened" && r.summary.gateRuns === 3 && r.summary.findings.review.refuted === 1 && r.summary.findings.review.skipped === 1 && r.summary.findings.review.unconfirmed === 0 && r.summary.findings.mutation.fixed === 1'

git add -A; git commit -qm x; git checkout -qb feat/y; printf 'export const y = 1\n' > src/y.ts
node "$SL" start; bash "$SG" --force >/dev/null 2>&1
sl_is "a forced receipt is logged too" "$SLOGS/open/sg_log__feat-y.json" 'r.gate[0].verdict === "FORCED"'
node "$SL" end "stopped at commit" >/dev/null
sl_is "a ship that stops before the PR is saved with why" "$SLOGS/sg_log_${DAY}_feat-y.json" 'r.status === "stopped" && r.reason === "stopped at commit"'
git checkout -qb feat/merge-only; bash "$HERE/ship-mark.sh" begin; git checkout -q feat/y
out=$(node "$SL" report)
sl_ok "the report lists every ship" test -n "$(printf '%s' "$out" | grep '#142')" -a -n "$(printf '%s' "$out" | grep 'feat/y')"
sl_ok "a ship that ran no check and found nothing is left out of the report" test -z "$(printf '%s' "$out" | grep 'feat/merge-only')"

git checkout -qb feat/z; printf 'export const z = 1\n' > src/z.ts
node "$SL" start; bash "$SG" --force >/dev/null 2>&1; git checkout -q feat/y
cat > bin/gh <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$TMP/gh-args"
case "\$*" in *"--head feat/z "*) echo '[{"number":151,"createdAt":"2999-01-02T03:04:05Z","state":"MERGED"}]' ;;
  *"--head feat/w "*) echo '[{"number":152,"createdAt":"2000-01-02T03:04:05Z","state":"OPEN"}]' ;;
  *"--head feat/v "*) echo '[{"number":150,"createdAt":"2000-01-02T03:04:05Z","state":"MERGED"}]' ;; *) echo '[]' ;; esac
EOF
chmod +x bin/gh; rm -f "$TMP/gh-args"
bash "$HERE/ship-mark.sh" begin
sl_is "a log left open after its PR opened is closed by the next /ship" "$SLOGS/sg_log_2999-01-02_pr151.json" 'r.status === "pr-opened" && r.pr === 151 && r.finished === "2999-01-02T03:04:05Z"'
sl_ok "and leaves open/" test ! -e "$SLOGS/open/sg_log__feat-z.json"
sl_ok "gh is asked once, for the logged branch only" test "$(cat "$TMP/gh-args")" = "pr list --head feat/z --state all --json number,createdAt,state --limit 1"
git checkout -qb feat/w; node "$SL" start; bash "$SG" --force >/dev/null 2>&1; git checkout -q feat/y
bash "$HERE/ship-mark.sh" begin
git checkout -qb feat/v; node "$SL" start; bash "$SG" --force >/dev/null 2>&1; git checkout -q feat/y
bash "$HERE/ship-mark.sh" begin
sl_ok "a PR merged before the log began is an old one, never this log's" test -f "$SLOGS/open/sg_log__feat-v.json" -a -z "$(ls "$SLOGS"/sg_log_*_pr150.json 2>/dev/null)"
sl_is "a ship on a branch whose PR already existed is an update, never a negative time" "$(ls "$SLOGS"/sg_log_*_pr152.json 2>/dev/null | head -1)" 'r.status === "pr-updated" && r.finished >= r.started && r.summary.minutes >= 0'
rm -f bin/gh

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
node "$SL" start; bash "$SG" >/dev/null 2>&1
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
