#!/usr/bin/env bash
# ship-gate on diffs with nothing of the project's to check. Sourced by gauntlet-selftest.sh.
# A repo that stopped committing .claude/ staged its hook deletions, and the gate called them UNPROVEN.

echo "ship-gate: installed tooling and deleted files"
newrepo sg_tooling
mkdir -p .claude/hooks
echo "echo gate" > .claude/hooks/ship-gate.sh
echo "old" > legacy.zzz
git add -A; git commit -qm "tooling committed"; git branch develop

git rm -q --cached .claude/hooks/ship-gate.sh
rm .claude/hooks/ship-gate.sh
sg "a diff that only removes .claude/ hooks checks nothing and passes" "no changed code files" 0

echo "echo new" > .claude/hooks/skill-gate.sh
sg "a new .claude/ hook is tooling, not unknown code" "no changed code files" 0

git rm -q legacy.zzz
sg "a deleted file of an unknown kind is not UNPROVEN" "no changed code files" 0
