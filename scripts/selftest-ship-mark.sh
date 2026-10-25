#!/usr/bin/env bash

echo "the /ship mark"
newrepo sg-mark
mkdir -p .claude/hooks
cp "$SG" "$SGH" "$HERE/ship-mark.sh" "$HERE/gate-config.sh" "$HERE/line-limit.sh" "$HERE/ship-gate-projects.sh" "$HERE/ship-gate-structure.sh" "$HERE/ship-gate-files.sh" .claude/hooks/
chmod +x .claude/hooks/*.sh
H=".claude/hooks/ship-gate-hook.sh"; MARK=".claude/hooks/ship-mark.sh"
printf "GAUNTLET_MUTATE='echo clean'\n" > .claude/gauntlet.conf
git checkout -qb feat/m; echo "const a=1" > a.ts; git add -A; git commit -qm work
printf '#!/bin/sh\necho "${GH_BRANCH:-}"\n' > bin/gh; chmod +x bin/gh

bash .claude/hooks/ship-gate.sh >/dev/null 2>&1
hook "a passed gate without /ship cannot open the PR" deny "gh pr create --fill"
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"gh pr create --fill"}}' | bash "$H")
N=$((N+1))
case "$out" in *"Load the /ship command"*) PASS=$((PASS+1)); echo "  ok   the block says to load /ship" ;;
  *) FAIL=$((FAIL+1)); printf '  FAIL the block says to load /ship\n       got %s\n' "$out" ;; esac
bash "$MARK" begin
hook "after /ship starts, the PR opens" allow "gh pr create --fill"
GH_BRANCH=feat/m hook "merging a /ship branch's PR is allowed" allow "gh pr merge 4 --squash"

git checkout -qb feat/other
hook "a new branch needs /ship again" deny "gh pr create --fill"
GH_BRANCH=feat/other hook "merging a PR whose branch never saw /ship is blocked" deny "gh pr merge 5 --squash"
GH_BRANCH="" hook "a merge whose branch gh cannot name is left to the receipt" allow "gh pr merge 5 --squash"

WT="$TMP/sg-mark-tree"
git worktree add -q "$WT" -b feat/wt >/dev/null 2>&1
echo "const w=1" > "$WT/w.ts"; git -C "$WT" add -A; git -C "$WT" commit -qm wt
CLAUDE_PROJECT_DIR="$WT" bash .claude/hooks/ship-gate.sh >/dev/null 2>&1
CLAUDE_PROJECT_DIR="$WT" bash "$MARK" begin
hook "a mark made in a worktree covers its PR" allow "gh pr create --head feat/wt --fill"
out=$(echo "{\"cwd\":\"$WT\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"gh pr create --fill\"}}" | bash "$H")
N=$((N+1)); case "$out" in *'"deny"'*) FAIL=$((FAIL+1)); printf '  FAIL a PR from a worktree session without --head is read from that worktree\n       got %s\n' "$out" ;;
  *) PASS=$((PASS+1)); echo "  ok   a PR from a worktree session without --head is read from that worktree" ;; esac

git checkout -q feat/m
cp "$HERE"/ship-log*.mjs .claude/hooks/
mkdir -p "$HOME/.claude"; echo 'GAUNTLET_SHIP_LOG=1' > "$HOME/.claude/gauntlet.conf"
bash "$MARK" begin; echo "const m2=1" >> a.ts
node -e 'process.stdout.write(JSON.stringify({ ts: new Date().toISOString().replace(/\.\d+Z$/, "Z"), branch: "feat/m", reply: "```json\n[{\"summary\":\"b\",\"failure_scenario\":\"x\"}]\n```" }) + "\n")' > .claude/review-findings.jsonl
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"gh pr create --fill"}}' | bash "$H")
N=$((N+1))
case "$out" in *"no ship-gate receipt"*) PASS=$((PASS+1)); echo "  ok   a PR missing the receipt and the log hears about the receipt first" ;;
  *) FAIL=$((FAIL+1)); printf '  FAIL a PR missing the receipt and the log hears about the receipt first\n       got %s\n' "$out" ;; esac
bash .claude/hooks/ship-gate.sh >/dev/null 2>&1
hook "with the log on, a PR waits for the log to be filled in" deny "gh pr create --fill"
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"gh pr create --fill"}}' | bash "$H")
N=$((N+1))
case "$out" in *"step review end"*) PASS=$((PASS+1)); echo "  ok   the block names the missing log step" ;;
  *) FAIL=$((FAIL+1)); printf '  FAIL the block names the missing log step\n       got %s\n' "$out" ;; esac
node .claude/hooks/ship-log.mjs step review end
node .claude/hooks/ship-log.mjs finding '{"by":"review","what":"b","verdict":"refuted","fixed":false}'
hook "and opens once it is" allow "gh pr create --fill"
printf '{' > "$HOME/.claude/ship-logs/open/sg-mark__feat-m.json"
hook "a log that cannot be read never blocks the PR with an empty list" allow "gh pr create --fill"
rm -rf "$HOME/.claude/gauntlet.conf" "$HOME/.claude/ship-logs" .claude/review-findings.jsonl
