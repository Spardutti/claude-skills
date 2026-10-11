#!/usr/bin/env bash
# ship-gate cases for a project whose Stryker runs elsewhere, through .stryker-run.
# Sourced by gauntlet-selftest.sh; shares its $HERE, $TMP, $N, $PASS, $FAIL.

echo "ship-gate .stryker-run"

export SRARGS="$TMP/stryker-run-args.log" SRNPX="$TMP/stryker-run-npx.log" SROUT="$TMP/stryker-run.out"

# An app whose node_modules is empty, as when Node lives only in Docker.
sr_repo() {
  newrepo "$1"
  mkdir -p api/src
  printf '{"devDependencies":{"@stryker-mutator/core":"8"}}\n' > api/package.json
  echo "export const a = 1" > api/src/a.ts
  echo "export const b = 1" > api/src/b.ts
  printf '#!/bin/sh\necho "npx $*" >> "$SRNPX"\necho "npm ERR! could not determine executable to run"\nexit 1\n' > bin/npx
  printf '#!/bin/sh\nfor a in "$@"; do printf "arg[%%s]\\n" "$a"; done >> "$SRARGS"\ncat "$SROUT"\n' > api/.stryker-run
  chmod +x bin/npx api/.stryker-run
  git add -A; git commit -qm base; git branch -q develop
  echo "export const a2 = 2" >> api/src/a.ts
  echo "export const b2 = 2" >> api/src/b.ts
  : > "$SROUT"
}

# ran_via <label> <exit code> <expected .stryker-run args, or "">
ran_via() {
  N=$((N+1))
  : > "$SRARGS"; : > "$SRNPX"
  out=$(bash "$SG" 2>&1); rc=$?
  got=$(cat "$SRARGS")
  if [ "$got" = "$3" ] && [ "$rc" = "$2" ] && [ ! -s "$SRNPX" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n       want (exit %s):\n%s\n       got (exit %s):\n%s\n       npx: %s\n%s\n' \
    "$1" "$2" "$3" "$rc" "$got" "$(cat "$SRNPX")" "$out"; fi
}
args() { printf 'arg[%s]\n' run --concurrency 4 --mutate "$1"; }

sr_repo sg_stryker_run
printf '[NoCoverage] StringLiteral\nsrc/b.ts:2:1\n' > "$SROUT"
ran_via "an executable .stryker-run replaces npx, with the same arguments" 1 "$(args src/a.ts:2-2,src/b.ts:2-2)"
sg "and its output is read as Stryker's, NoCoverage included" "[NoCoverage] StringLiteral  src/b.ts:2:1" 1
: > "$SROUT"
echo "export const b3 = 3" >> api/src/b.ts
ran_via "and a file that passed through it is kept" 0 "$(args src/b.ts:2-3)"

chmod -x api/.stryker-run
echo "export const a3 = 3" >> api/src/a.ts
sg "a .stryker-run that is not executable is ignored" "could not determine executable" 2
sg "and a Stryker the machine cannot run names .stryker-run" "api/.stryker-run" 2

mkdir -p node_modules/@stryker-mutator/core
sg "an installed Stryker that fails does not blame Docker" "the run failed" 2
N=$((N+1))
if grep -q 'stryker-run' <<< "$(bash "$SG" 2>&1)"; then FAIL=$((FAIL+1)); printf '  FAIL %s\n' "and does not name .stryker-run"
else PASS=$((PASS+1)); printf '  ok   %s\n' "and does not name .stryker-run"; fi

# no_hint <label>: the gate's output must not suggest .stryker-run
no_hint() {
  N=$((N+1))
  if grep -q 'stryker-run that' <<< "$(bash "$SG" 2>&1)"; then FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"
  else PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; fi
}
sr_repo sg_stryker_run_fails
printf '#!/bin/sh\nexit 1\n' > api/.stryker-run
no_hint "a .stryker-run that fails is not told to exist"
rm api/.stryker-run
echo "GAUNTLET_MUTATE='exit 1'" > .claude/gauntlet.conf
no_hint "a failing GAUNTLET_MUTATE is not told about Stryker"
