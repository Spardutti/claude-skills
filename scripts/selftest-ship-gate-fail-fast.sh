#!/usr/bin/env bash
# ship-gate cases for stopping before mutation. Sourced by gauntlet-selftest.sh.
# A length or structure fix changes the files, so a mutation run before it is always thrown away.

failfast() {  # failfast <label> <exit code> <"ran" or "skipped">
  N=$((N+1))
  rm -f "$LOG"
  out=$(bash "$SG" 2>&1); rc=$?
  ran=skipped; [ -s "$LOG" ] && ran=ran
  if [ "$rc" = "$2" ] && [ "$ran" = "$3" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n       want exit %s, mutation %s\n       got exit %s, mutation %s\n%s\n' \
         "$1" "$2" "$3" "$rc" "$ran" "$out"
  fi
}

echo "ship-gate fail-fast"
newrepo sg_failfast
printf 'GAUNTLET_MAX_LINES=3\nGAUNTLET_MUTATE="echo mutated >> %s"\n' "$LOG" > .claude/gauntlet.conf
echo '{}' > package.json
git add -A; git commit -qm manifest; git branch develop
mkdir -p src/shared/utils
printf 'export const a = 1\n' > src/shared/utils/short.ts
failfast "a clean diff still runs mutation" 0 ran

printf 'export const a = 1\nexport const b = 2\nexport const c = 3\nexport const d = 4\n' > src/shared/utils/long.ts
failfast "a file over the limit stops before mutation" 1 skipped
rm src/shared/utils/long.ts

mkdir -p src/components
printf 'export const a = 1\n' > src/components/Loose.ts
failfast "a misplaced new file stops before mutation" 1 skipped
