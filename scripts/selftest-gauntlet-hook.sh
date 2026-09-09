#!/usr/bin/env bash
# Cases for gauntlet.sh itself — the Stop hook: its skip ladder, detection
# across monorepo shapes, and the per-project runners.
# Sourced by gauntlet-selftest.sh; shares its $HERE, $TMP, $N, $PASS, $FAIL
# and its newrepo/check/stub helpers.

echo "skip ladder"
newrepo r1
check "no changed files"        "no changed files"
echo hi >> README.md
check "docs only"               "docs/config only"
echo "const a=1" > a.ts
check "no gates detected"       "no gates detected"
printf "GAUNTLET_TYPECHECK=''\nGAUNTLET_TEST='echo ok'\n" > .claude/gauntlet.conf
check "green"                   "green: gates passed"
echo "// touch" >> a.ts
printf "GAUNTLET_TYPECHECK=''\nGAUNTLET_TEST='echo \"No test files found\"'\n" > .claude/gauntlet.conf
check "runner matched 0 tests"  "matched 0 test files"
echo "// touch2" >> a.ts
printf "GAUNTLET_TYPECHECK=''\nGAUNTLET_TEST='echo boom; exit 1'\n" > .claude/gauntlet.conf
check "red"                     "red: the tests gate failed"
# A red must exit 2 — that is the only exit code that both keeps the turn going
# and shows the user why. Exit 0 would let the turn end silently.
N_RED=$N
if [ "$RC" = 2 ]; then
  PASS=$((PASS+1)); echo "  ok   red exits 2 (visible to the user)"
else
  FAIL=$((FAIL+1)); echo "  FAIL red exits 2 — got exit $RC"
fi
N=$((N+1))
if grep -q "GAUNTLET FAILED" "$TMP/err" 2>/dev/null; then
  PASS=$((PASS+1)); echo "  ok   red writes the reason to stderr"
else
  FAIL=$((FAIL+1)); echo "  FAIL red writes the reason to stderr — got: $(cat "$TMP/err" 2>/dev/null)"
fi
N=$((N+1))
echo "GAUNTLET_OFF=1" >> .claude/gauntlet.conf
check "GAUNTLET_OFF"            "GAUNTLET_OFF is set"

echo "a missing tool is a skip, not a red"
newrepo r2
echo '{"devDependencies":{"vitest":"^4"}}' > package.json
echo "const a=1" > a.ts
check "vitest not installed"    "tool is not installed"
newrepo r3
printf '[project]\nname="x"\n' > pyproject.toml
echo "x=1" > a.py
check "pytest not installed"    "tool is not installed"

echo "a delegating monorepo root uses its own scripts"
newrepo r4
mkdir -p web
echo '{"scripts":{"test":"npm --prefix web run test","typecheck":"npm --prefix web run typecheck"}}' > package.json
echo '{"scripts":{"test":"vitest run"},"devDependencies":{"vitest":"^4"}}' > web/package.json
stub npm "npm-ran"
mkdir -p web/src; echo "export const a=1" > web/src/a.ts
check "root scripts win"        "green: gates passed" "npm-ran"

echo "more than one stack in one repo"
newrepo r5
echo '{"scripts":{"typecheck":"x"},"devDependencies":{"vitest":"^4"}}' > package.json
printf '[tool.mypy]\nstrict=true\n' > pyproject.toml
stub npm "js-typecheck"; stub npx "js-test"
printf '#!/bin/sh\ncase "$*" in *mypy*) echo py-typecheck >> %s;; *pytest*) echo py-test >> %s;; esac\n' "$LOG" "$LOG" > bin/python
chmod +x bin/python
echo "const a=1" > a.ts
check "js change runs js gates" "green: gates passed" "js-test"
rm a.ts; echo "x=1" > b.py
check "py change runs py gates" "green: gates passed" "py-test"

echo "a nested project with nothing at the root"
newrepo r6
mkdir -p web/src api
echo '{"scripts":{"typecheck":"tsc -b"},"devDependencies":{"vitest":"^4"}}' > web/package.json
printf '[project]\nname="api"\n' > api/pyproject.toml
stub npm "web-typecheck"; stub npx "web-test"
printf '#!/bin/sh\necho api-test >> %s\n' "$LOG" > bin/python; chmod +x bin/python
echo "export const a=1" > web/src/a.ts
check "web change runs web gates" "green: gates passed" "web-test"
rm web/src/a.ts; echo "x=1" > api/a.py
check "api change runs api gates" "green: gates passed" "api-test"

# A project whose tests need a database cannot run them on the host, and
# detection finds the host runner every time. GAUNTLET_TEST could override it,
# but that switches the WHOLE repo to explicit mode — so a monorepo needing a
# container for one stack had to hand-write commands for all of them. A
# per-project executable runner fixes exactly that, and only that.
echo "per-project runners"
newrepo r_runner
mkdir -p web api
printf '{"scripts":{"test":"x","typecheck":"y"},"devDependencies":{"vitest":"^4"}}\n' > web/package.json
printf '[project]\nname="api"\n' > api/pyproject.toml
# The runner and the host tool it must beat. Each logs which one ran, so this
# asserts WHICH command executed — a stub that only returned a verdict would
# agree with the bug and still come out green.
printf '#!/bin/sh\necho RUNNER-IN-CONTAINER >> %s\nexit 0\n' "$LOG" > api/.gauntlet-test
chmod +x api/.gauntlet-test
stub python "HOST-PYTEST"
stub npx "HOST-VITEST"
echo "print(1)" > api/main.py
check "the project runner replaces the host tool" "green: gates passed" "RUNNER-IN-CONTAINER"

newrepo r_runner_host
mkdir -p web api
printf '{"scripts":{"test":"x"},"devDependencies":{"vitest":"^4"}}\n' > web/package.json
printf '[project]\nname="api"\n' > api/pyproject.toml
printf '#!/bin/sh\necho RUNNER-IN-CONTAINER >> %s\nexit 0\n' "$LOG" > api/.gauntlet-test
chmod +x api/.gauntlet-test
stub python "HOST-PYTEST"
stub npx "HOST-VITEST"
echo "export const a = 1" > web/a.ts
# The other half of the monorepo declares no runner, so it keeps its detected
# host command. This is what GAUNTLET_TEST could not express.
check "the half with no runner still auto-detects" "green: gates passed" "HOST-VITEST"

newrepo r_runner_tc
mkdir -p api
printf '[project]\nname="api"\n[tool.mypy]\n' > api/pyproject.toml
printf '#!/bin/sh\necho RUNNER-TYPECHECK >> %s\nexit 0\n' "$LOG" > api/.gauntlet-typecheck
chmod +x api/.gauntlet-typecheck
stub python "HOST-MYPY"
echo "print(1)" > api/main.py
check "a typecheck runner replaces host mypy" "green: gates passed" "RUNNER-TYPECHECK"

newrepo r_runner_unexec
mkdir -p api
printf '[project]\nname="api"\n' > api/pyproject.toml
# Not executable: the gate cannot run it, so falling back to detection is the
# only safe reading. Silently gating on a file it cannot execute would be worse.
printf '#!/bin/sh\nexit 0\n' > api/.gauntlet-test
stub python "HOST-PYTEST"
echo "print(1)" > api/main.py
check "a non-executable runner is ignored" "green: gates passed" "HOST-PYTEST"

echo "a path containing a space stays one argument"
newrepo r7
echo '{"devDependencies":{"vitest":"^4"}}' > package.json
printf '#!/bin/sh\nfor a in "$@"; do echo "arg[$a]" >> %s; done\n' "$LOG" > bin/npx; chmod +x bin/npx
mkdir -p "src/my folder"; echo "const a=1" > "src/my folder/a.ts"
check "spaced path"             "green: gates passed" "arg[$TMP/r7/src/my folder/a.ts]"

# --------------------------------------------------------------- ship-gate.sh
sg() {  # sg <label> <expected substring in output> [expected exit code]
  N=$((N+1))
  out=$(bash "$SG" 2>&1); rc=$?
  ok=1
  case "$out" in *"$2"*) ;; *) ok=0 ;; esac
  [ -n "${3:-}" ] && [ "$rc" != "$3" ] && ok=0
  if [ $ok = 1 ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n       want ~ %s (exit ${3:-any})\n       got exit %s:\n%s\n' "$1" "$2" "$rc" "$out"
  fi
}
# The ship gate has its own files: it is a separate hook from the gauntlet,
# and together its cases were a third of this one.