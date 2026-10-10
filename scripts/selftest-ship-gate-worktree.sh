#!/usr/bin/env bash
# ship-gate cases for a PR shipped from a git worktree. Sourced by gauntlet-selftest.sh.
# A forced receipt in the main folder once let a worktree's PR through ungated.

echo "ship-gate from a worktree"
newrepo sg-wt
mkdir -p .claude/hooks
cp "$SG" "$SGH" "$HERE/ship-gate-projects.sh" "$HERE/ship-gate-structure.sh" .claude/hooks/
chmod +x .claude/hooks/*.sh
H=".claude/hooks/ship-gate-hook.sh"
printf "GAUNTLET_MUTATE='echo clean'\n" > .claude/gauntlet.conf
WT="$TMP/sg-wt-tree"
git worktree add -q "$WT" -b feat/x >/dev/null 2>&1
echo "const a=1" > "$WT/a.ts"
git -C "$WT" add -A; git -C "$WT" commit -qm work
GH_LOG="$TMP/gh.log"
printf '#!/bin/sh\nprintf "arg[%%s]\\n" "$@" >> %s\necho feat/x\n' "$GH_LOG" > bin/gh; chmod +x bin/gh

bash .claude/hooks/ship-gate.sh --force >/dev/null 2>&1
hook "a forced receipt in the main folder does not cover a worktree's PR" deny "gh pr create --head feat/x"
rm -f "/tmp/claude-shipgate-$(bash .claude/hooks/ship-gate.sh --key)"

CLAUDE_PROJECT_DIR="$WT" bash .claude/hooks/ship-gate.sh >/dev/null 2>&1
hook "the gate run in the worktree lets its PR through" allow "gh pr create --head feat/x --fill"
hook "-H names the branch too" allow "gh pr create -H feat/x"

rm -f "$GH_LOG"
hook "merging finds the worktree through the PR's branch" allow "gh pr merge 7 -R o/r --squash"
N=$((N+1))
want=$(printf 'arg[%s]\n' pr view 7 -R o/r --json headRefName -q .headRefName)
if [ "$(cat "$GH_LOG" 2>/dev/null)" = "$want" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "and asks gh for exactly that PR"
else FAIL=$((FAIL+1)); printf '  FAIL %s\n       want %s\n       got  %s\n' "and asks gh for exactly that PR" "$want" "$(cat "$GH_LOG" 2>/dev/null)"; fi

echo "const b=2" >> "$WT/a.ts"
hook "editing the worktree invalidates its receipt" deny "gh pr create --head feat/x"

printf "GAUNTLET_MUTATE='echo \"[Survived] x\"'\n" > .claude/gauntlet.conf
N=$((N+1))
case "$(CLAUDE_PROJECT_DIR="$WT" bash .claude/hooks/ship-gate.sh 2>&1)" in
  *"[Survived] x"*) PASS=$((PASS+1)); printf '  ok   %s\n' "a worktree uses the gate's own config" ;;
  *) FAIL=$((FAIL+1)); printf '  FAIL %s\n' "a worktree uses the gate's own config" ;;
esac
git worktree remove --force "$WT" >/dev/null 2>&1
rm -f bin/gh
