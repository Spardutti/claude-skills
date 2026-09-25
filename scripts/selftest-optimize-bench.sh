#!/usr/bin/env bash
# The bench.sh template /optimize copies, run as shipped. Sourced by gauntlet-selftest.sh.
# Two real runs posted their prediction after the result; the template refusing to start is the fix.

ob_check() {  # ob_check <label> <0|1 passed>
  N=$((N+1))
  if [ "$2" = 1 ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n%s\n' "$1" "${3:-}"; fi
}

echo "/optimize bench.sh"
OB="$TMP/optimize-bench"
rm -rf "$OB"; mkdir -p "$OB/out" "$OB/work"
awk '/^## Step 1/{s=1} s&&/^```bash$/{b=1;next} b&&/^```$/{exit} b' "$HERE/../commands/optimize.md" \
  | sed "s#^OUT=.*#OUT=$OB/out#" > "$OB/out/bench.sh"
cat > "$OB/work/.mutmut-run" <<'M'
#!/bin/sh
echo "$*" >> ../ran.log
[ "$1" = results ] && cat ../results.fixture
exit 0
M
chmod +x "$OB/work/.mutmut-run"
printf '    app.a.x_f__mutmut_1: killed\n    app.a.x_f__mutmut_2: survived\n' > "$OB/results.fixture"

out=$(cd "$OB/work" && bash ../out/bench.sh round1 2>&1); rc=$?
ob_check "no prediction file: exit 3, and the job never runs" \
  "$([ "$rc" = 3 ] && [ ! -e "$OB/ran.log" ] && echo 1)" "exit $rc: $out"

echo "15-30% faster: one pool" > "$OB/out/round1.prediction"
out=$(cd "$OB/work" && bash ../out/bench.sh round1 2>&1); rc=$?
ob_check "with a prediction it runs the job exactly as written" \
  "$([ "$rc" = 0 ] && [ "$(head -1 "$OB/ran.log")" = "run app.expenses.commands.x* app.postings.earmark.x*" ] && echo 1)" \
  "exit $rc, ran: $(cat "$OB/ran.log" 2>/dev/null)"
line=$(cat "$OB/out/rounds.log" 2>/dev/null)
ob_check "rounds.log records the round, the item count and the prediction" \
  "$(printf '%s' "$line" | grep -qE '^round1	[0-9]+s	2 items	[0-9a-f]{12}	15-30% faster: one pool$' && echo 1)" "got: $line"
ob_check "the prediction is locked once the round starts" \
  "$([ ! -w "$OB/out/round1.prediction" ] && echo 1)"

: > "$OB/results.fixture"
echo "baseline" > "$OB/out/round2.prediction"
out=$(cd "$OB/work" && bash ../out/bench.sh round2 2>&1); rc=$?
ob_check "an empty invariant is refused and not logged" \
  "$([ "$rc" = 4 ] && [ "$(grep -c . "$OB/out/rounds.log")" = 1 ] && echo 1)" "exit $rc: $out"
chmod -R u+w "$OB"
