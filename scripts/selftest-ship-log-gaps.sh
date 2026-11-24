#!/usr/bin/env bash
[ -n "${SELFTEST_SANDBOX:-}" ] || { echo "$(basename "$0"): run it through scripts/gauntlet-selftest.sh, never on its own" >&2; exit 1; }

echo "the test-gap score from /deliver logs"
GD="$TMP/gaps-logs"; rm -rf "$GD"; mkdir -p "$GD/open"
gl() {  # gl <file> <started> <gate runs json>
  printf '{"v":1,"app":"a","branch":"b","started":"%s","gate":%s,"findings":[]}' "$2" "$3" > "$GD/$1"
}
S2='{"tool":"stryker","result":"survivors","survivors":[{"mutator":"StringLiteral"},{"mutator":"ConditionalExpression"}]}'
OK='{"tool":"stryker","result":"ok","survivors":[]}'
gl two.json 2026-11-04T10:00:00Z "[{\"projects\":[$S2]},{\"projects\":[$OK]}]"
gl config-first.json 2026-11-08T10:00:00Z "[{\"projects\":[{\"tool\":\"config\",\"result\":\"survivors\",\"survivors\":[{}]}]},{\"projects\":[$OK]}]"
gl none.json 2026-11-05T10:00:00Z '[{"projects":[{"tool":"stryker","result":"failed","survivors":[]}]}]'
gl open/mutmut.json 2026-11-10T10:00:00Z '[{"projects":[{"tool":"mutmut","result":"survivors","survivors":[{}]}]}]'
out=$(node "$HERE/ship-log.mjs" gaps "$GD" 2>&1)
WANT='week of     branches  first run had gaps  gaps per branch
2026-11-02  2         1                   1.0
2026-11-09  1         1                   1.0

gap kinds, last 4 weeks: ConditionalExpression 1, StringLiteral 1, unnamed (mutmut) 1'
N=$((N+1))
if [ "$out" = "$WANT" ]; then PASS=$((PASS+1)); echo "  ok   gaps counts each branch's first mutation run, by week"
else FAIL=$((FAIL+1)); printf '  FAIL gaps table — got:\n%s\n' "$out"; fi
