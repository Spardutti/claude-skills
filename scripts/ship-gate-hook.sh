#!/usr/bin/env bash
# ship-gate-hook.sh — PreToolUse on Bash. Refuses `git commit` and `git push`
# unless ship-gate.sh has left a receipt for exactly these changes.
#
# A gate written as an instruction is a gate an agent can decide is not worth the
# time — and then report a pass it never earned, which is the part you cannot see
# from the outside. This removes the claim entirely: either the receipt exists for
# this exact content, or git does not run.
#
# The receipt key covers everything about to ship, so it survives `git commit`
# and still matches at push time, and it changes the moment any file is edited —
# a fix has to be re-gated instead of riding on the previous verdict.

INPUT=$(cat)

CMD=$(printf '%s' "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//')

# Only the two commands that publish work. Everything else passes untouched.
case "$CMD" in
  *"git commit"*|*"git push"*) ;;
  *) exit 0 ;;
esac

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
cd "$PROJECT_DIR" 2>/dev/null || exit 0

GATE="$PROJECT_DIR/.claude/hooks/ship-gate.sh"
[ -x "$GATE" ] || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Ask the gate for the key rather than recomputing it here. Two implementations
# of the same rule drift, and the drift is silent.
KEY=$(bash "$GATE" --key 2>/dev/null)
[ -z "$KEY" ] && exit 0

RECEIPT="/tmp/claude-shipgate-$KEY"
if [ -f "$RECEIPT" ]; then
  exit 0
fi

MSG="BLOCKED: no ship-gate receipt for these changes.

The quality gate has not run against the code you are about to publish, or the
code changed since it last did. Run it:

  bash .claude/hooks/ship-gate.sh

It checks file length and mutation-tests the changed lines, and writes a receipt
this hook can see. Fix what it reports and run it again — a fix invalidates the
previous receipt on purpose.

Do NOT hand-roll a substitute check: only ship-gate.sh writes a receipt, so a
weaker check you designed yourself cannot be passed off as this one.

To publish without the gate, say so out loud and run:

  bash .claude/hooks/ship-gate.sh --force"

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$(json_escape "$MSG")"
exit 0
