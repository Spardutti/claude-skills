#!/usr/bin/env bash
# ship-gate-hook.sh — PreToolUse on Bash. Refuses the commands that publish work
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
#
# It gated `git commit` and `git push` until 2.23.0, and that was the wrong
# moment. The gate's scope is merge-base..HEAD — the whole branch, because the
# whole branch is what a PR ships — so a branch touching 46 files re-mutated all
# 46 on every commit. Fifteen minutes, twenty times, for one branch. Neither a
# commit nor a push to a feature branch publishes anything, so neither is gated
# now: the cost is paid once, at the point work actually ships.

INPUT=$(cat)

CMD=$(printf '%s' "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//')

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
cd "$PROJECT_DIR" 2>/dev/null || exit 0

# Opening or merging a PR publishes. So does pushing while standing on a
# protected branch — that is a direct ship with no PR in front of it. The branch
# is read from git rather than parsed out of the command, because `git push` with
# no arguments names no branch at all.
case "$CMD" in
  *"gh pr create"*|*"gh pr merge"*) ;;
  *"git push"*)
    BRANCH=$(git branch --show-current 2>/dev/null)
    case "$BRANCH" in
      main|master|develop|development|dev) ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac

GATE="$PROJECT_DIR/.claude/hooks/ship-gate.sh"
[ -x "$GATE" ] || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

pr_branch() {
  case "$CMD" in
    *"gh pr create"*) printf '%s\n' "$CMD" | sed -nE 's/.*(--head[ =]|-H )([^ ;&|]+).*/\2/p' ;;
    *"gh pr merge"*) merge_branch ;;
  esac
}

merge_branch() {
  local pr="" repo="" next=""
  for t in $(printf '%s\n' "$CMD" | sed 's/.*gh pr merge//; s/[;&|].*//'); do
    if [ "$next" = repo ]; then repo=$t; next=""; continue; fi
    case "$t" in
      -R|--repo) next=repo ;;
      --repo=*) repo=${t#--repo=} ;;
      -*) ;;
      *) [ -z "$pr" ] && pr=$t ;;
    esac
  done
  [ -n "$pr" ] || return 0
  gh pr view "$pr" ${repo:+-R "$repo"} --json headRefName -q .headRefName 2>/dev/null
}

worktree_of() {
  git worktree list --porcelain 2>/dev/null \
    | awk -v b="refs/heads/$1" '/^worktree /{w=substr($0,10)} $0=="branch " b {print w; exit}'
}

# A PR from a worktree ships that folder's diff, so its receipt is keyed there,
# not in the folder this session started in.
TARGET="$PROJECT_DIR"
BRANCH=$(pr_branch)
[ -n "$BRANCH" ] && WT=$(worktree_of "$BRANCH") && [ -n "$WT" ] && TARGET="$WT"

# Ask the gate for the key rather than recomputing it here. Two implementations
# of the same rule drift, and the drift is silent.
KEY=$(CLAUDE_PROJECT_DIR="$TARGET" bash "$GATE" --key 2>/dev/null)
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

From a worktree, run the gate there and name the branch with --head:

  CLAUDE_PROJECT_DIR=<worktree> bash $GATE

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
