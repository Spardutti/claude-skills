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
SELFTEST_SANDBOX="$TMP"
cd "$TMP" || exit 1
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
cores() { printf '#!/bin/sh\necho %s\n' "$1" > "$TMP/sysbin/getconf"; chmod +x "$TMP/sysbin/getconf"; }
mkdir -p "$TMP/sysbin"; export PATH="$TMP/sysbin:$PATH"; cores 8
STRYKER_RUN=$(printf 'arg[%s]\n' --no-install stryker run --concurrency 4)

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
. "$HERE/selftest-ship-gate-glob.sh"     # a [id] route is judged on its changed lines only
. "$HERE/selftest-ship-gate-stryker-zero.sh"  # survivors from a run that tested nothing
. "$HERE/selftest-ship-gate-page-tests.sh"  # page tests passed off as proof for logic
. "$HERE/selftest-ship-gate-mutmut.sh"   # the Python half, and the git receipt
. "$HERE/selftest-ship-gate-worktree.sh"  # a PR shipped from a git worktree
. "$HERE/selftest-ship-gate-mutmut-scope.sh"  # the Python half scoped to changed modules
. "$HERE/selftest-ship-gate-quiet.sh"    # half the cores, lowest priority
. "$HERE/selftest-ship-gate-mutmut-first.sh"  # a module's first run tests only the diff
. "$HERE/selftest-ship-gate-reuse.sh"    # not re-running a project that already passed
. "$HERE/selftest-ship-gate-file-reuse.sh"  # not re-mutating a file that already passed
. "$HERE/selftest-ship-gate-stryker-run.sh"  # Stryker run elsewhere, through .stryker-run
. "$HERE/selftest-ship-gate-setup.sh"    # a change to Stryker's own setup gets a trial run
. "$HERE/selftest-ship-gate-structure.sh"  # where a new file may live
. "$HERE/selftest-ship-gate-fail-fast.sh"  # no mutation run after a cheap check fails
. "$HERE/selftest-ship-gate-length.sh"  # the length check honours .line-limit-baseline
. "$HERE/selftest-ship-gate-report.sh"    # the last line names the saved output
. "$HERE/selftest-timing.sh"             # how long the Stop hook and the ship gate took
. "$HERE/selftest-ship-gate-config.sh"   # what a repo's own mutation command is handed
. "$HERE/selftest-ship-gate-base.sh"     # which branch the ship gate measures from
. "$HERE/selftest-ship-log.sh"           # the /ship log: every gate run, findings, PR size
. "$HERE/selftest-ship-log-settle.sh"    # survivors fixed but never logged
. "$HERE/selftest-ship-prep.sh"         # ship-gate --scope and the one-call /ship setup
. "$HERE/selftest-ship-prep-stages.sh"  # commit, merge and release facts in one call each
. "$HERE/selftest-ship-mark.sh"          # a PR opens only after /ship starts on its branch
. "$HERE/selftest-optimize-bench.sh"     # /optimize's benchmark refuses a round with no prediction
. "$HERE/selftest-survey.sh"             # the real-repo survey finds repos inside group folders
. "$HERE/selftest-ship-gate-tooling.sh"  # .claude/ tooling and deleted files are never UNPROVEN
. "$HERE/selftest-skill-gate.sh"         # deny messages, exemptions, auto mode
. "$HERE/selftest-skill-gate-bash.sh"    # Bash commands that write files, and which files are gated
. "$HERE/selftest-mandatory-skills.sh"   # which skills are not optional
. "$HERE/selftest-skill-ack.sh"          # the ack command, before any denial
. "$HERE/selftest-skill-flags.sh"        # logging skills-audit verdicts, and /skill-report
. "$HERE/selftest-line-limit.sh"         # the 200-line ratchet
. "$HERE/selftest-edit-check.sh"         # the 200-line ratchet on each edited file
. "$HERE/selftest-lint-ratchet.sh"       # the ESLint ratchet on each edited file
. "$HERE/selftest-lint-ratchet-baseline.sh"  # baselines never bank growth, and edge cases
. "$HERE/selftest-diary-check.sh"       # when /ship suggests /add-rule
. "$HERE/selftest-edit-blocks.sh"       # edit-hook blocks, logged and tallied
. "$HERE/selftest-registry.sh"          # *.registry.yaml: the listing, the plan check and stale entries
. "$HERE/selftest-structure.sh"          # what a file declares vs what exists
. "$HERE/selftest-fetch.sh"              # the CLI talking to GitHub
. "$HERE/selftest-install.sh"            # installing over an existing install
. "$HERE/selftest-install-edit-check.sh"  # the edit check, installed and upgraded
. "$HERE/selftest-claude-md.sh"           # the blocks written into CLAUDE.md
. "$HERE/selftest-cli.sh"                # the installer binary end to end
. "$HERE/selftest-cli-requires.sh"       # commands that need another, and new catalog items
. "$HERE/selftest-stryker.sh"            # scaffolding Stryker into a project
. "$HERE/selftest-standalone.sh"         # no test file runs on its own, in a real repo

cd /
rm -rf "$TMP"
echo
echo "$PASS passed, $FAIL failed, $N total"
[ "$FAIL" = 0 ]
