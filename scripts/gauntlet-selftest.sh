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

HERE="$(cd "$(dirname "$0")" && pwd)"
G="$HERE/gauntlet.sh"
SG="$HERE/ship-gate.sh"
SGH="$HERE/ship-gate-hook.sh"
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
  echo "{\"session_id\":\"st$RUN-$N\"}" | "$G" >/dev/null 2>"$TMP/err"
  RC=$?
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

# Each file below owns one subject and is sourced in place, so it shares the
# helpers above and the $N/$PASS/$FAIL counters rather than keeping its own.
# Adding a case means editing the file that owns the subject, not this one.
. "$HERE/selftest-gauntlet-hook.sh"      # the Stop hook: skips, detection, runners
. "$HERE/selftest-ship-gate-stryker.sh"  # the JS half of the ship gate
. "$HERE/selftest-ship-gate-mutmut.sh"   # the Python half, and the git receipt
. "$HERE/selftest-skill-gate.sh"         # deny messages, exemptions, auto mode
. "$HERE/selftest-mandatory-skills.sh"   # which skills are not optional
. "$HERE/selftest-line-limit.sh"         # the 200-line ratchet
. "$HERE/selftest-structure.sh"          # what a file declares vs what exists
. "$HERE/selftest-fetch.sh"              # the CLI talking to GitHub
. "$HERE/selftest-install.sh"            # installing over an existing install
. "$HERE/selftest-cli.sh"                # the installer binary end to end
. "$HERE/selftest-stryker.sh"            # scaffolding Stryker into a project
