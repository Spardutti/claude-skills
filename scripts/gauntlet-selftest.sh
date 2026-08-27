#!/usr/bin/env bash
# gauntlet-selftest.sh — behavioural tests for scripts/gauntlet.sh.
#
# Every case builds a throwaway git repo, stubs the runners so nothing real is
# executed, runs the hook, and asserts on the outcome it recorded in its .why
# file. Run it before shipping any change to the hook:
#
#   bash scripts/gauntlet-selftest.sh
#
# Exits non-zero on the first failed assertion.

set -uo pipefail

G="$(cd "$(dirname "$0")" && pwd)/gauntlet.sh"
TMP=$(mktemp -d)
export HOME="$TMP/home"; mkdir -p "$HOME"
RUN="$$-$(date +%s 2>/dev/null || echo 0)"
LOG="$TMP/ran.log"
N=0
PASS=0
FAIL=0

newrepo() {
  R="$TMP/$1"; rm -rf "$R"; mkdir -p "$R/.claude" "$R/bin"; cd "$R" || exit 1
  git init -q .; git config user.email t@t.t; git config user.name t
  echo x > README.md; git add -A; git commit -qm init
  export CLAUDE_PROJECT_DIR="$R"
  case ":$PATH:" in *":$R/bin:"*) ;; *) export PATH="$R/bin:$PATH" ;; esac
}

# check <label> <expected substring in .why> [expected substring in the run log]
check() {
  N=$((N+1))
  rm -f "$LOG"
  echo "{\"session_id\":\"st$RUN-$N\"}" | "$G" >/dev/null 2>&1
  got=$(cat "/tmp/claude-gauntlet-st$RUN-$N.why" 2>/dev/null)
  ok=1
  case "$got" in *"$2"*) ;; *) ok=0 ;; esac
  if [ -n "${3:-}" ]; then
    ran=$(cat "$LOG" 2>/dev/null)
    case "$ran" in *"$3"*) ;; *) ok=0 ;; esac
  fi
  if [ $ok = 1 ]; then
    PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL+1))
    printf '  FAIL %s\n       want why ~ %s\n       got  why = %s\n' "$1" "$2" "$got"
    [ -n "${3:-}" ] && printf '       want ran ~ %s\n       got  ran = %s\n' "$3" "$(cat "$LOG" 2>/dev/null)"
  fi
}

stub() { printf '#!/bin/sh\necho "%s" >> %s\n' "$2" "$LOG" > "bin/$1"; chmod +x "bin/$1"; }

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

echo "a path containing a space stays one argument"
newrepo r7
echo '{"devDependencies":{"vitest":"^4"}}' > package.json
printf '#!/bin/sh\nfor a in "$@"; do echo "arg[$a]" >> %s; done\n' "$LOG" > bin/npx; chmod +x bin/npx
mkdir -p "src/my folder"; echo "const a=1" > "src/my folder/a.ts"
check "spaced path"             "green: gates passed" "arg[$TMP/r7/src/my folder/a.ts]"

cd /
rm -rf "$TMP"
echo
echo "$PASS passed, $FAIL failed, $N total"
[ "$FAIL" = 0 ]
