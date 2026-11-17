#!/usr/bin/env bash
[ -n "${SELFTEST_SANDBOX:-}" ] || { echo "$(basename "$0"): run it through scripts/gauntlet-selftest.sh, never on its own" >&2; exit 1; }
# The Stop hook tests only code changed since the session's last green run.

echo "only code changed since the last green run is tested again"
newrepo r-delta
echo "export const a=1" > a.ts; echo "export const b=1" > b.ts
git add -A; git commit -qm base
printf '#!/bin/sh\nfor f in "$@"; do echo "${f##*/}" >> %s; done\n[ -z "${DELTA_RED:-}" ]\n' "$LOG" > bin/t; chmod +x bin/t
printf "GAUNTLET_TYPECHECK=''\nGAUNTLET_TEST='t \$FILES'\n" > .claude/gauntlet.conf

delta_check() {  # <label> <session> <expected why> <expected files, one per line>
  N=$((N+1)); rm -f "$LOG"
  echo "{\"session_id\":\"st$RUN-$2\"}" | "$G" >/dev/null 2>&1
  local why ran; why=$(cat "/tmp/claude-gauntlet-st$RUN-$2.why" 2>/dev/null); ran=$(cat "$LOG" 2>/dev/null)
  if [[ "$why" == *"$3"* ]] && [ "$ran" = "$4" ]; then PASS=$((PASS+1)); echo "  ok   $1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n       why = %s\n       ran = %s\n       want ran = %s\n' "$1" "$why" "$ran" "$4"; fi
}

echo "// 1" >> a.ts; echo "// 1" >> b.ts
delta_check "first run tests every changed file"      d1 "green" $'a.ts\nb.ts'
echo "// 2" >> b.ts
delta_check "a later run tests only the edited file"  d1 "green" "b.ts"
delta_check "no edit since green runs nothing"        d1 "no code changed since the last green run" ""
echo "// 3" >> a.ts
DELTA_RED=1 delta_check "a red run"                   d1 "red" "a.ts"
echo "// 3" >> b.ts
delta_check "a red run is not banked as green"        d1 "green" $'a.ts\nb.ts'
git checkout -q -- a.ts
delta_check "a file reverted to HEAD is tested again" d1 "green" "a.ts"
delta_check "a new session tests every changed file"  d2 "green" "b.ts"
rm -f /tmp/claude-gauntlet-st$RUN-d1* /tmp/claude-gauntlet-st$RUN-d2*
