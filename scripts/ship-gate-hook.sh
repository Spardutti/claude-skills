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
. "$(cd "$(dirname "$0")" && pwd)/gate-config.sh" 2>/dev/null || exit 0

CMD=$(json_field "$INPUT" command)
CWD=$(json_field "$INPUT" cwd)

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
cd "$PROJECT_DIR" 2>/dev/null || exit 0

# Opening or merging a PR publishes. So does pushing while standing on a
# protected branch — that is a direct ship with no PR in front of it. The branch
# is read from git rather than parsed out of the command, because `git push` with
# no arguments names no branch at all.
push_dirs() {  # one "<cd dir><TAB><-C dir>" line per push in the command
  local dir=. seg re_c='^git -C +"?([^" ]+)"? +push( |$)' re_cd='^cd +"?([^" ]+)"?$' re_push='^git push( |$)'
  while IFS= read -r seg; do
    seg=$(printf '%s' "$seg" | sed -E 's/^[[:space:]]*(\$\(|\()?[[:space:]]*//; s/[[:space:]]*$//')
    if [[ $seg =~ $re_cd ]]; then dir=${BASH_REMATCH[1]}
    elif [[ $seg =~ $re_c ]]; then printf '%s\t%s\n' "$dir" "${BASH_REMATCH[1]}"
    elif [[ $seg =~ $re_push ]]; then printf '%s\t\n' "$dir"
    fi
  done < <(printf '%s\n' "$CMD" | sed -E 's/\\n|&&|\|\||;|\|/\n/g')
}

push_branch() {  # push_branch <cd dir> <-C dir>; a folder git cannot read falls back to the main folder
  git -C "${CWD:-.}" -C "$1" ${2:+-C "$2"} branch --show-current 2>/dev/null || git branch --show-current 2>/dev/null
}

case "$CMD" in
  *"gh pr create"*|*"gh pr merge"*) ;;
  *)
    PUSHES=$(push_dirs); [ -n "$PUSHES" ] || exit 0
    PROTECTED=""
    while IFS=$'\t' read -r d c; do
      case "$(push_branch "$d" "$c")" in main|master|develop|development|dev) PROTECTED=1 ;; esac
    done <<< "$PUSHES"
    [ -n "$PROTECTED" ] || exit 0
    ;;
esac

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$(json_escape "$1")"
  exit 0
}

GATE="$PROJECT_DIR/.claude/hooks/ship-gate.sh"
[ -x "$GATE" ] || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

pr_branch() {
  case "$CMD" in
    *"gh pr create"*) printf '%s\n' "$CMD" | sed -nE 's/.*(--head[ =]|-H )"?([^ ;&|"]+).*/\2/p' ;;
    *"gh pr merge"*) merge_field headRefName ;;
  esac
}

pr_base() {
  case "$CMD" in
    *"gh pr create"*) printf '%s\n' "$CMD" | sed -nE 's/.*(--base[ =]|-B )"?([^ ;&|"]+).*/\2/p' ;;
    *"gh pr merge"*) merge_field baseRefName ;;
  esac
}

merge_field() {  # merge_field <gh pr field>
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
  gh pr view "$pr" ${repo:+-R "$repo"} --json "$1" -q ".$1" 2>/dev/null
}

worktree_of() {
  git worktree list --porcelain 2>/dev/null \
    | awk -v b="refs/heads/$1" '/^worktree /{w=substr($0,10)} $0=="branch " b {print w; exit}'
}

# A PR from a worktree ships that folder's diff, so its receipt is keyed there,
# not in the folder this session started in.
TARGET="$PROJECT_DIR"
case "$CMD" in *"gh pr create"*)
  CWD_TOP=$(git -C "${CWD:-.}" rev-parse --show-toplevel 2>/dev/null) && [ -n "$CWD_TOP" ] && TARGET="$CWD_TOP" ;;
esac
BRANCH=$(pr_branch)
# A release PR carries only work each feature PR already gated, and the gate on the
# trunk measures it against itself, so a receipt there proves nothing.
case "$BRANCH" in dev|develop|development)
  case "$(pr_base)" in main|master) exit 0 ;; esac ;;
esac
[ -n "$BRANCH" ] && WT=$(worktree_of "$BRANCH") && [ -n "$WT" ] && TARGET="$WT"

# Ask the gate for the key rather than recomputing it here. Two implementations
# of the same rule drift, and the drift is silent.
KEY=$(CLAUDE_PROJECT_DIR="$TARGET" bash "$GATE" --key 2>/dev/null)
[ -z "$KEY" ] && exit 0

# A gate run by hand skips /ship's audit and review, so the PR waits for /ship itself.
# A merge whose branch gh cannot name is left to the receipt alone.
MARKER="$PROJECT_DIR/.claude/hooks/ship-mark.sh"
case "$CMD" in *"gh pr create"*) MARK_BRANCH=${BRANCH:-$(git -C "$TARGET" branch --show-current)} ;; *) MARK_BRANCH=$BRANCH ;; esac
if [ -f "$MARKER" ] && [ -n "$MARK_BRANCH" ] && ! CLAUDE_PROJECT_DIR="$TARGET" bash "$MARKER" check "$MARK_BRANCH"; then
  deny "BLOCKED: /ship has not run on branch $MARK_BRANCH.

Load the /ship command with the Skill tool and follow it from the start. A gate run
by hand is not enough: /ship also runs the skills audit and the code review.
The gate's earlier pass is reused, so only those two steps cost time."
fi

SHIP_LOG="$PROJECT_DIR/.claude/hooks/ship-log.mjs"
log_ready() {
  case "$CMD" in *"gh pr create"*) ;; *) return 0 ;; esac
  [ -f "$SHIP_LOG" ] && command -v node >/dev/null || return 0
  TODO=$(SHIP_LOG_ROOT="$TARGET" node "$SHIP_LOG" ready 2>/dev/null) || [ -z "$TODO" ] || deny "BLOCKED: the ship log is not filled in for this /ship. Do these, then create the PR again:
$TODO

A finding's shape is in The ship log section of /ship. Log each one with the verdict
you already reached; never log a finding you did not settle."
}

RECEIPT="/tmp/claude-shipgate-$KEY"
if [ -f "$RECEIPT" ]; then
  log_ready
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

deny "$MSG"
