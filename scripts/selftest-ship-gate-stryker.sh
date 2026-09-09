#!/usr/bin/env bash
# ship-gate cases for the JS half: what Stryker is handed, and what its output means.
# Sourced by gauntlet-selftest.sh; shares its $HERE, $TMP, $N, $PASS, $FAIL.

echo "ship-gate"
newrepo sg1
echo "const a=1" > a.ts

# Stryker prints a `# survived` column header on EVERY run, including a clean
# one. Grepping for the bare word reported findings when there were none.
cat > .claude/gauntlet.conf <<'C'
GAUNTLET_MUTATE='printf "%s\n" "File | % score | # killed | # survived |" "All files | 100.00 | 12 | 0 |"'
C
sg "a clean run's summary header is not a finding" "nothing survived" 0

cat > .claude/gauntlet.conf <<'C'
GAUNTLET_MUTATE='printf "%s\n" "File | # survived |" "[Survived] StringLiteral" "src/a.ts:12:9"'
C
sg "a real [Survived] line is a finding" "[Survived] StringLiteral" 1

rm -f .claude/gauntlet.conf
echo "x" > a.test.ts; mkdir -p tests; echo "z" > tests/t.ts
sg "test files are never mutated" "1 changed code file"

seq 1 250 | sed 's/^/const x/' > big.ts
sg "a file over the limit stops the ship" "over the limit" 1

# The gate reported "I recognised nothing" and "there is nothing" identically,
# both as a PASS with a receipt. A Godot repo changing only .gd files was waved
# straight through work nothing had looked at.
echo "ship-gate finds nothing"
newrepo sg_unknown
echo "# notes" > NOTES.md
sg "a docs-only change is still a pass" "nothing to check" 0
seq 1 250 | sed 's/^/var x/' > player.gd
sg "gd is source, so a long one is caught" "over the limit" 1
rm -f player.gd
echo "const x = 1" > weird.zzz
sg "an extension the gate cannot place is never a pass" "does not know: zzz" 2

# Stryker's incremental file is mutmut's ./mutants cache wearing a different
# hat: --force reruns everything in scope, but the report still carries cached
# rows for everything OUT of scope, and this gate greps the whole report. The
# stub answers only when it is asked for incremental mode, so this test fails
# the moment the flag comes back.
echo "ship-gate stryker cache"
newrepo sg_stryker
printf '{"devDependencies":{"@stryker-mutator/core":"8"}}\n' > package.json
cat > bin/npx <<'X'
#!/bin/sh
case "$*" in *--incremental*) echo "[Survived] a mutant replayed from the cache" ;; esac
exit 0
X
chmod +x bin/npx
echo "const a=1" > a.ts
sg "stryker is not run in incremental mode" "nothing survived" 0

# Assert the ARGV, not the verdict. Every ship-gate bug so far hid from a test
# that only asked whether the gate said green: the stub is written from the same
# belief as the code, so it agrees with the bug and the verdict comes out right.
# The repeated --mutate — which mutated one file per run for four releases — and
# the --incremental cache before it were both a wrong argument list under a
# correct-looking verdict. This records exactly what the tool was handed, one
# line per argument, and compares the whole list. A flag that repeats, a flag
# that comes back, or a value that loses a file all fail here.
argv() {  # argv <label> <expected arg log, in full>
  N=$((N+1))
  rm -f "$LOG"
  bash "$SG" >/dev/null 2>&1
  got=$(cat "$LOG" 2>/dev/null)
  if [ "$got" = "$2" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n       want:\n%s\n       got:\n%s\n' "$1" "$2" "$got"; fi
}

echo "ship-gate stryker argv"
newrepo sg_argv
printf '{"devDependencies":{"@stryker-mutator/core":"10"}}\n' > package.json
printf '#!/bin/sh\nfor a in "$@"; do echo "arg[$a]" >> %s; done\n' "$LOG" > bin/npx
chmod +x bin/npx
echo "const a=1" > a.ts
echo "const b=2" > b.ts
argv "stryker is handed the whole diff in one --mutate, and nothing else" \
"arg[--no-install]
arg[stryker]
arg[run]
arg[--mutate]
arg[a.ts:1-1,b.ts:1-1]"

# Mutation pays on logic and burns time on presentation. A component's mutants
# are class names, copy and JSX shape — none of it behaviour — and one session
# spent an evening killing them. Components are still length-checked and
# skill-audited; they are only kept out of --mutate. Asserting the argv rather
# than the verdict is the point: a .tsx quietly included still reports PASS.
echo "ship-gate stryker argv, components out of scope"
newrepo sg_argv_tsx
printf '{"devDependencies":{"@stryker-mutator/core":"10"}}\n' > package.json
printf '#!/bin/sh\nfor a in "$@"; do echo "arg[$a]" >> %s; done\n' "$LOG" > bin/npx
chmod +x bin/npx
echo "const a=1" > a.ts
echo "export const B = () => <p/>" > B.tsx
argv "a .tsx in the diff is not mutated, the .ts beside it is" \
"arg[--no-install]
arg[stryker]
arg[run]
arg[--mutate]
arg[a.ts:1-1]"

# The other half of the same rule: out of --mutate is not out of the gate.
echo "ship-gate components are still length-checked"
newrepo sg_tsx_len
printf '{"devDependencies":{"@stryker-mutator/core":"10"}}\n' > package.json
mkdir -p .claude
printf "GAUNTLET_MUTATE='echo clean'\nGAUNTLET_MAX_LINES=5\n" > .claude/gauntlet.conf
for i in $(seq 1 20); do echo "// line $i" >> Big.tsx; done
bash "$SG" > "$TMP/tsxlen.out" 2>&1
N=$((N+1))
if grep -q "Big.tsx" "$TMP/tsxlen.out"; then
  PASS=$((PASS+1)); printf '  ok   %s\n' "an over-long .tsx is still reported"
else
  FAIL=$((FAIL+1)); printf '  FAIL an over-long .tsx escaped the length check\n       gate said: %s\n' "$(cat "$TMP/tsxlen.out")"
fi

# Stryker validates every --mutate entry with Minimatch and refuses a range on
# anything glob-shaped: "Cannot combine a glob expression with a mutation range".
# A Next.js route folder is exactly that, so one [id] directory in the diff
# failed the whole run — every other file included. The path goes in with each
# bracket swapped for ? and no range: still one file, mutated whole.
echo "ship-gate stryker argv, glob-shaped paths"
newrepo sg_argv_glob
printf '{"devDependencies":{"@stryker-mutator/core":"10"}}\n' > package.json
printf '#!/bin/sh\nfor a in "$@"; do echo "arg[$a]" >> %s; done\n' "$LOG" > bin/npx
chmod +x bin/npx
echo "const a=1" > a.ts
mkdir -p 'app/[[...slug]]'
echo "const p=1" > 'app/[[...slug]]/page.ts'
argv "a route folder loses its range, not the whole run" \
"arg[--no-install]
arg[stryker]
arg[run]
arg[--mutate]
arg[a.ts:1-1,app/??...slug??/page.ts]"

# NoCoverage means no test executes the line at all, which is strictly worse than
# a survivor, and the gate used to call it a PASS: one commit shipped with 306
# uncovered mutants reported as proven. The stub prints the status line and the
# file:line:column line under it, the way Stryker's clear-text reporter does.
echo "ship-gate stryker no coverage"
newrepo sg_nocov
printf '{"devDependencies":{"@stryker-mutator/core":"10"}}\n' > package.json
cat > bin/npx <<'X'
#!/bin/sh
echo "[NoCoverage] BooleanLiteral"
echo "a.ts:1:11"
exit 0
X
chmod +x bin/npx
echo "const a=1" > a.ts
sg "a changed line no test runs is a finding" "[NoCoverage] BooleanLiteral" 1

# A glob-shaped path goes in without a range, so the whole file is mutated and
# lines nobody touched report uncovered. Charging those to this diff would be a
# finding that can never be closed, which is what teaches --force.
newrepo sg_nocov_glob
printf '{"devDependencies":{"@stryker-mutator/core":"10"}}\n' > package.json
cat > bin/npx <<'X'
#!/bin/sh
echo "[NoCoverage] BooleanLiteral"
echo "app/[id]/page.ts:9:11"
exit 0
X
chmod +x bin/npx
mkdir -p 'app/[id]'
echo "const p=1" > 'app/[id]/page.ts'
sg "a whole-file glob path is not judged for coverage" "nothing survived" 0

# The detail list is capped at 20 so one bad file cannot bury the output, and the
# cap used to be the whole story: 22 findings from a.ts filled it and b.ts never
# appeared. On a real diff that hid the WORST file, 54 uncovered mutants, behind
# a file with fewer. Every file with findings must be named below the cut.
echo "ship-gate findings cap"
newrepo sg_cap
printf '{"devDependencies":{"@stryker-mutator/core":"10"}}\n' > package.json
cat > bin/npx <<'X'
#!/bin/sh
i=1
while [ $i -le 22 ]; do
  echo "[NoCoverage] BooleanLiteral"
  echo "a.ts:$i:1"
  i=$((i+1))
done
echo "[NoCoverage] BooleanLiteral"
echo "b.ts:1:1"
exit 0
X
chmod +x bin/npx
echo "const a=1" > a.ts
echo "const b=2" > b.ts
sg "a file past the cap is still named" "1  b.ts" 1
sg "and the count of what was hidden is stated" "3 more not shown" 1
. "$HERE/selftest-ship-gate-scope.sh"
