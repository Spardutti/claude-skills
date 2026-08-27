#!/usr/bin/env bash
# gauntlet.sh — Stop hook: fast deterministic gates on the changed diff.
#
# Runs when Claude finishes a turn. Silent when green. Blocks the turn when a
# gate is red, handing the failure back to Claude to fix before the user sees it.
#
# Only cheap gates belong here (target: under ~30s). Mutation testing, deep
# review, and the spec checklist are the /gauntlet command's job, not this hook's.
#
# Skip ladder, cheapest first — quits at the first "no":
#   1. no changed files
#   2. no changed *code* files (docs/config only)
#   3. this exact diff already passed
#   4. no test runner detected
#
# Config, both optional and both KEY=value files that get sourced in this order:
#   ~/.claude/gauntlet.conf          your defaults for every project
#   <project>/.claude/gauntlet.conf  overrides for this one; wins key by key
#   GAUNTLET_OFF=1                 disable entirely
#   GAUNTLET_TYPECHECK="cmd"       override the typecheck command ("" to skip)
#   GAUNTLET_TEST="cmd"            override the test command; $FILES = changed code files
#   GAUNTLET_CODE_EXT="ts|tsx|py"  override which extensions count as code

set -uo pipefail

INPUT=$(cat 2>/dev/null || true)

# Never re-block a turn we already blocked — this would loop forever.
case "$INPUT" in
  *'"stop_hook_active":true'*) exit 0 ;;
esac

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$PROJECT_DIR" ]; then PROJECT_DIR="$PWD"; fi
cd "$PROJECT_DIR" 2>/dev/null || exit 0

git rev-parse --git-dir >/dev/null 2>&1 || exit 0

GAUNTLET_OFF=""
GAUNTLET_TYPECHECK="__auto__"
GAUNTLET_TEST="__auto__"
GAUNTLET_CODE_EXT="ts|tsx|js|jsx|mjs|cjs|py|go|rs|java|kt|rb|php|c|h|cpp|hpp|cs|swift|sql"
# Global defaults first, then the project's on top — project wins, key by key.
if [ -n "${HOME:-}" ] && [ -f "$HOME/.claude/gauntlet.conf" ]; then . "$HOME/.claude/gauntlet.conf"; fi
if [ -f "$PROJECT_DIR/.claude/gauntlet.conf" ]; then . "$PROJECT_DIR/.claude/gauntlet.conf"; fi
if [ -n "$GAUNTLET_OFF" ]; then exit 0; fi

# ---------------------------------------------------------------- skip rule 1
CHANGED=$( { git diff --name-only HEAD 2>/dev/null; \
             git ls-files --others --exclude-standard 2>/dev/null; } | sort -u )
if [ -z "$CHANGED" ]; then exit 0; fi

# ---------------------------------------------------------------- skip rule 2
FILES=$(printf '%s\n' "$CHANGED" | grep -E "\.($GAUNTLET_CODE_EXT)$" || true)
if [ -z "$FILES" ]; then exit 0; fi

# ---------------------------------------------------------------- skip rule 3
DIFF_HASH=$( { git diff HEAD 2>/dev/null; printf '%s\n' "$CHANGED"; } \
             | git hash-object --stdin 2>/dev/null )
SESSION_ID=$(printf '%s' "$INPUT" | grep -o '"session_id":"[^"]*"' | head -1 \
             | sed 's/"session_id":"//; s/"$//')
if [ -z "$SESSION_ID" ]; then SESSION_ID="nosession"; fi
MARKER="/tmp/claude-gauntlet-$SESSION_ID"
if [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$DIFF_HASH" ]; then exit 0; fi

# ---------------------------------------------------------------- skip rule 4
# Detect the stack once. Auto-detection is a default, not a decision — the conf
# file wins whenever a repo does something unusual.
detect() {
  if [ "$GAUNTLET_TEST" != "__auto__" ]; then return; fi
  GAUNTLET_TEST=""
  GAUNTLET_TYPECHECK=""
  if [ -f package.json ]; then
    if grep -q '"vitest"' package.json; then
      GAUNTLET_TEST='npx --no-install vitest related --run $FILES'
    elif grep -q '"jest"' package.json; then
      GAUNTLET_TEST='npx --no-install jest --findRelatedTests $FILES --passWithNoTests'
    fi
    if [ -f tsconfig.json ]; then
      GAUNTLET_TYPECHECK='npx --no-install tsc --noEmit'
    fi
  fi
  if [ -z "$GAUNTLET_TEST" ] && { [ -f pyproject.toml ] || [ -f pytest.ini ] || [ -f setup.cfg ]; }; then
    GAUNTLET_TEST='python -m pytest -q'
    if [ -f mypy.ini ] || grep -qs 'tool.mypy' pyproject.toml; then
      GAUNTLET_TYPECHECK='python -m mypy .'
    fi
  fi
}
detect
if [ -z "$GAUNTLET_TEST" ]; then exit 0; fi

# ------------------------------------------------------------------ the gates
# Cheapest first, stop at the first red. Most failures land in the first gate,
# so the expensive ones are usually never paid for.
export FILES=$(printf '%s' "$FILES" | tr '\n' ' ')
FAILED=""
OUTPUT=""

run_gate() {
  GATE_NAME="$1"
  GATE_CMD="$2"
  if [ -z "$GATE_CMD" ]; then return 0; fi
  GATE_OUT=$(eval "$GATE_CMD" 2>&1)
  if [ $? -ne 0 ]; then
    FAILED="$GATE_NAME"
    OUTPUT="$GATE_OUT"
    return 1
  fi
  return 0
}

run_gate "typecheck" "$GAUNTLET_TYPECHECK" && run_gate "tests" "$GAUNTLET_TEST"

if [ -z "$FAILED" ]; then
  printf '%s' "$DIFF_HASH" > "$MARKER"
  exit 0
fi

# ------------------------------------------------------------------ block red
# Last 60 lines only — the hook's reason is read by a model, not archived.
TAIL=$(printf '%s\n' "$OUTPUT" | tail -60)
MSG="GAUNTLET FAILED: the $FAILED gate is red on the changed files.

Fix it before ending the turn. Do not weaken or delete a test to make this pass.
If the failure is unrelated to your change, say so explicitly and stop.

Changed code files:
$FILES

--- $FAILED output (last 60 lines) ---
$TAIL"

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

printf '{"decision":"block","reason":%s}\n' "$(json_escape "$MSG")"
exit 0
