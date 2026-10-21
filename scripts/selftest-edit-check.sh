#!/usr/bin/env bash

echo "the edit-time check"
EC="$TMP/ec"; rm -rf "$EC"; mkdir -p "$EC/scripts" "$EC/skills/x"
cp "$HERE/line-limit.sh" "$HERE/edit-check.sh" "$HERE/lint-ratchet.mjs" "$HERE/text-rules.mjs" "$HERE/ratchet-baseline.mjs" "$HERE/gate-config.sh" "$EC/scripts/"
mkl() { awk -v n="$2" 'BEGIN { for (i=0;i<n;i++) print ": pad" }' > "$EC/$1"; }

mkl old.sh 300
bash "$EC/scripts/line-limit.sh" --baseline >/dev/null 2>&1

ec() {  # ec <label> <file> <expected exit> <expected substring>
  N=$((N+1))
  out=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s","content":"x"}}' "$EC/$2" \
        | CLAUDE_PROJECT_DIR="$EC" bash "$EC/scripts/edit-check.sh" 2>&1); rc=$?
  ok=1
  [ "$rc" = "$3" ] || ok=0
  case "$out" in *"$4"*) ;; *) ok=0 ;; esac
  if [ $ok = 1 ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s — want exit %s ~ %s, got exit %s: %s\n' "$1" "$3" "$4" "$rc" "$(printf '%s' "$out" | tr '\n' ' ')"; fi
}

mkl new.sh 210
ec "a new file over 200 lines is blocked"        new.sh 2 "new.sh — 210 lines (limit 200)"
mkl new.sh 150
ec "a new file under the limit passes"           new.sh 0 ""
ec "recorded debt passes, with a note to split it" old.sh 0 '"additionalContext":"LINE LIMIT — old.sh is 300 lines'
mkl old.sh 310
ec "recorded debt that grew is blocked"          old.sh 2 "old.sh — 310 lines, was 300"
mkl other.sh 250
ec "only the edited file is judged"              new.sh 0 ""
mkl skills/x/SKILL.md 400
ec "a file the limit does not cover passes"      skills/x/SKILL.md 0 ""
mkl new.sh 210
ec "a path spelled with ./ and .. is still judged" "./skills/../new.sh" 2 "new.sh — 210 lines"
mv "$EC/scripts/line-limit.sh" "$EC/ll.bak"
ec "a project without the rule blocks nothing"   new.sh 0 ""
mv "$EC/ll.bak" "$EC/scripts/line-limit.sh"

git -C "$EC" init -q; printf '.venv\n' > "$EC/.gitignore"
mkdir -p "$EC/.venv/lib"; mkl .venv/lib/big.py 400
ec "a git-ignored file is never judged"          .venv/lib/big.py 0 ""
echo '{ not json' > "$EC/.edit-rules.json"
mkl new.sh 10
ec "a broken rules file is a note, not a block"  new.sh 0 "edit-rules"
rm "$EC/.edit-rules.json"

WT="$TMP/wt/.claude/worktrees/r"; rm -rf "$TMP/wt"; mkdir -p "$WT/scripts"
cp "$EC/scripts/"* "$WT/scripts/"
awk 'BEGIN { for (i=0;i<210;i++) print ": pad" }' > "$WT/w.sh"
N=$((N+1))
out=$(printf '{"tool_input":{"file_path":"%s/w.sh"}}' "$WT" | CLAUDE_PROJECT_DIR="$WT" bash "$WT/scripts/edit-check.sh" 2>&1); rc=$?
case "$rc:$out" in
  "2:"*"w.sh — 210 lines"*) PASS=$((PASS+1)); echo "  ok   a project inside a .claude worktree is still judged" ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL a project inside a .claude worktree is still judged — exit $rc: $out" ;;
esac
