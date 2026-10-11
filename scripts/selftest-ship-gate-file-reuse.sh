#!/usr/bin/env bash
# ship-gate cases for not re-mutating a file whose clean verdict still stands.
# Sourced by gauntlet-selftest.sh; shares its $HERE, $TMP, $N, $PASS, $FAIL.

echo "ship-gate reuses a clean file"

export FARGS="$TMP/file-reuse-args.log" FOUT="$TMP/file-reuse-stryker.out" FRC=0

# One JS app with two changed files and a test. The stub logs every argument it gets.
file_repo() {
  newrepo "$1"
  mkdir -p src
  printf '{"devDependencies":{"@stryker-mutator/core":"8"}}\n' > package.json
  echo "export const a = 1" > src/a.ts
  echo "export const b = 1" > src/b.ts
  printf 'one\ntwo\n' > src/a.test.ts
  cat > bin/npx <<'X'
#!/bin/sh
for a in "$@"; do printf 'arg[%s]\n' "$a"; done >> "$FARGS"
cat "$FOUT"
exit "$FRC"
X
  chmod +x bin/npx
  git add -A; git commit -qm base; git branch -q develop
  echo "export const a2 = 2" >> src/a.ts
  echo "export const b2 = 2" >> src/b.ts
  : > "$FOUT"
}

# mutated <label> <exit code> [--mutate value of each Stryker run, in order]
mutated() {
  N=$((N+1)); label=$1; code=$2; shift 2
  : > "$FARGS"
  out=$(bash "$SG" 2>&1); rc=$?
  want=$(for m in "$@"; do printf '%s\narg[--mutate]\narg[%s]\n' "$STRYKER_RUN" "$m"; done)
  got=$(cat "$FARGS")
  if [ "$got" = "$want" ] && [ "$rc" = "$code" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$label"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n       want (exit %s):\n%s\n       got (exit %s):\n%s\n%s\n' \
    "$label" "$code" "$want" "$rc" "$got" "$out"; fi
}
b() { echo "export const b$1 = $1" >> src/b.ts; }

touch "$TMP/file-reuse-mark"
file_repo sg_file_reuse
printf '[Survived] StringLiteral\nsrc/b.ts:2:1\n' > "$FOUT"
mutated "the first run mutates every changed file" 1 "src/a.ts:2-2,src/b.ts:2-2"
: > "$FOUT"
b 3
mutated "after fixing one file, only that file is mutated" 0 "src/b.ts:2-3"
sg "and the kept file is named with the gap it leaves" "A change in a file they call is not re-checked" 0

echo "three" >> src/a.test.ts
mutated "a test that only gained lines keeps every clean file" 0
b 4
mutated "a run after a test gained lines" 0 "src/b.ts:2-4"
git checkout -q src/a.test.ts
mutated "putting a test back loses the lines it gained" 0 "src/b.ts:2-4"
sed -i '1d' src/a.test.ts
mutated "a test that lost a line re-mutates every file" 0 "src/a.ts:2-2,src/b.ts:2-4"

b 5
mutated "a run that leaves a snapshot" 0 "src/b.ts:2-5"
find /tmp -maxdepth 1 -name 'claude-shipgate-tests-*' -newer "$TMP/file-reuse-mark" -exec rm -rf {} +
echo "three" >> src/a.test.ts
mutated "a receipt whose snapshot is gone keeps nothing" 0 "src/a.ts:2-2,src/b.ts:2-5"

echo "export default {}" > vitest.config.ts
mutated "a changed runner config re-mutates every file" 0 "src/a.ts:2-2,src/b.ts:2-5"
rm src/a.test.ts
mutated "a deleted test re-mutates every file" 0 "src/a.ts:2-2,src/b.ts:2-5"

# A survivor Stryker printed without a location cannot be pinned on one file.
echo "export const a3 = 3" >> src/a.ts; b 6
printf '[Survived] StringLiteral\n' > "$FOUT"
mutated "a survivor with no location is a finding" 1 "src/a.ts:2-3,src/b.ts:2-6"
: > "$FOUT"
mutated "and keeps no file from that run" 0 "src/a.ts:2-3,src/b.ts:2-6"

echo "export const a4 = 4" >> src/a.ts; b 7
FRC=1
mutated "a run that failed is reported" 2 "src/a.ts:2-4,src/b.ts:2-7"
FRC=0
mutated "and keeps no file from it" 0 "src/a.ts:2-4,src/b.ts:2-7"

# A verdict from an older gate is a verdict from whatever bugs it had.
b 8
mutated "a clean run before the gate changes" 0 "src/b.ts:2-8"
mkdir -p "$TMP/gate3"
cp "$SG" "$HERE/ship-gate-projects.sh" "$HERE/ship-gate-structure.sh" "$HERE/ship-gate-files.sh" "$TMP/gate3/"
echo "# a newer gate" >> "$TMP/gate3/ship-gate-files.sh"
SG_REAL=$SG; SG="$TMP/gate3/ship-gate.sh"
mutated "a changed gate keeps no file" 0 "src/a.ts:2-4,src/b.ts:2-8"
SG=$SG_REAL

# A rebase can bring in code the tests run through, so a moved base keeps nothing.
c=$(git commit-tree "$(printf '100644 blob %s\tb.ts\n' "$(git rev-parse develop:src/b.ts)" | git mktree \
  | xargs printf '040000 tree %s\tsrc\n' | cat - <(git ls-tree develop | grep -v 'src$') | git mktree)" -p develop -m moved)
git update-ref refs/heads/develop "$c"; git reset -q --soft "$c"
mutated "a moved base keeps nothing" 0 "src/a.ts:1-4,src/b.ts:2-8"

# Two apps share a kind: a change in one re-runs the other, as a whole project did.
file_repo sg_file_sibling
mkdir -p lib
printf '{"devDependencies":{"@stryker-mutator/core":"8"}}\n' > lib/package.json
echo "export const l = 1" > lib/l.ts
mutated "two apps' first run" 0 "src/a.ts:2-2,src/b.ts:2-2" "l.ts:1-1"
echo "export const l2 = 2" >> lib/l.ts
mutated "a change in a sibling app re-mutates this one" 0 "src/a.ts:2-2,src/b.ts:2-2" "l.ts:1-2"

# Page tests make every run UNPROVEN, including one that mutates nothing.
file_repo sg_file_page
echo "test" > src/a.test.tsx
mutated "page tests are UNPROVEN" 2 "src/a.ts:2-2,src/b.ts:2-2"
mutated "still UNPROVEN when every file is kept" 2
