#!/usr/bin/env bash
# ship-gate cases for its saved output. Sourced by gauntlet-selftest.sh.

echo "ship-gate report"
newrepo sg_report
printf 'GAUNTLET_MUTATE="echo src/a.ts: survived"\n' > .claude/gauntlet.conf
echo '{}' > package.json
git add -A; git commit -qm manifest; git branch develop
mkdir -p src; printf 'export const a = 1\n' > src/a.ts
N=$((N+1))
last=$(bash "$SG" 2>&1 | tail -1)
report=${last#ship-gate: full output in }
if [ "$report" != "$last" ] && grep -q 'src/a.ts: survived' "$report" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ok   %s\n' "a tailed gate still names the file holding its findings"
else
  FAIL=$((FAIL+1)); printf '  FAIL %s\n       last line: %s\n' "a tailed gate still names the file holding its findings" "$last"
fi
