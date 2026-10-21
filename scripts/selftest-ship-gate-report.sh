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

N=$((N+1))
got=$(node -e 'const l = require("fs").readFileSync(".claude/gate-findings.jsonl", "utf8").trim().split("\n");
  const o = JSON.parse(l[l.length - 1]); process.stdout.write(l.length + "|" + o.report.includes("src/a.ts: survived"))' 2>&1)
if [ "$got" = "1|true" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "a failed gate writes its findings to the diary"
else FAIL=$((FAIL+1)); printf '  FAIL %s\n       got: %s\n' "a failed gate writes its findings to the diary" "$got"; fi

printf 'GAUNTLET_MUTATE="true"\n' > .claude/gauntlet.conf
N=$((N+1))
bash "$SG" >/dev/null 2>&1; rc=$?
lines=$(wc -l < .claude/gate-findings.jsonl)
if [ "$rc" != 1 ] && [ "$lines" = 1 ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "a gate that does not fail writes nothing to the diary"
else FAIL=$((FAIL+1)); printf '  FAIL %s\n       exit %s, diary lines %s\n' "a gate that does not fail writes nothing to the diary" "$rc" "$lines"; fi

printf 'GAUNTLET_MUTATE="printf %s"\n' "'\\\\033[31msrc/a.ts: survived\\\\033[0m\\\\n'" > .claude/gauntlet.conf
bash "$SG" >/dev/null 2>&1
N=$((N+1))
got=$(node -e 'const l = require("fs").readFileSync(".claude/gate-findings.jsonl", "utf8").trim().split("\n");
  const o = JSON.parse(l[l.length - 1]); process.stdout.write(l.length + "|" + o.report.includes("src/a.ts: survived") + "|" + Boolean(o.branch))' 2>&1)
if [ "$got" = "2|true|true" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "color codes in the gate output still make valid JSON, with the branch"
else FAIL=$((FAIL+1)); printf '  FAIL %s\n       got: %s\n' "color codes in the gate output still make valid JSON, with the branch" "$got"; fi

