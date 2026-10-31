#!/usr/bin/env bash
[ -n "${SELFTEST_SANDBOX:-}" ] || { echo "$(basename "$0"): run it through scripts/gauntlet-selftest.sh, never on its own" >&2; exit 1; }

echo "the check after shell commands"
newrepo bash_check
mkdir -p src .claude/hooks
cp "$HERE/bash-check.sh" "$HERE/edit-check.sh" "$HERE/line-limit.sh" "$HERE/gate-config.sh" \
   "$HERE/lint-ratchet.mjs" "$HERE/text-rules.mjs" "$HERE/ratchet-baseline.mjs" .claude/hooks/
printf '.claude/\n' > .gitignore
git add -A; git commit -qm hooks
BC_ROOT="$PWD"
pad() { awk -v n="$2" 'BEGIN { for (i=0;i<n;i++) print ": pad" }' > "$1"; }
bc() {  # bc <label> <command text> <expected exit> <expected substring, or empty for silent>
  N=$((N+1))
  out=$(printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"%s"}}' "$BC_ROOT" "$2" \
        | CLAUDE_PROJECT_DIR="$BC_ROOT" bash "$BC_ROOT/.claude/hooks/bash-check.sh" 2>&1); rc=$?
  ok=1
  [ "$rc" = "$3" ] || ok=0
  if [ -z "$4" ]; then [ -z "$out" ] || ok=0; else case "$out" in *"$4"*) ;; *) ok=0 ;; esac; fi
  if [ $ok = 1 ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s — want exit %s ~ %s, got exit %s: %s\n' "$1" "$3" "$4" "$rc" "$out"; fi
}

bc "a command that changes nothing is silent"         "ls" 0 ""
pad src/big.sh 210
bc "a file the shell pushed over the limit is blocked" "python3 patch.py" 2 "src/big.sh — 210 lines (limit 200)"
bc "the same version never blocks the next command"   "ls" 0 ""
pad src/big.sh 220
bc "a further change to that file blocks again"       "sed -i x" 2 "src/big.sh — 220 lines"
pad src/big.sh 10
bc "a fixed file passes"                              "sed -i y" 0 ""
pad src/other.sh 230; git add src/other.sh
bc "a staged file is judged too"                      "git add" 2 "src/other.sh — 230 lines"
git reset -q; rm src/other.sh src/big.sh

printf '{"text":[{"id":"no-foo","files":"\\\\.sh$","pattern":"foo","message":"no foo here","bad":"foo","good":"bar"}]}\n' > .edit-rules.json
printf '# rules: no-foo\n' > .lint-baseline
git add -A; git commit -qm rules
echo 'foo' > src/rule.sh
bc "a project text rule applies to shell writes"      "tee src/rule.sh" 2 "no foo here"
rm src/rule.sh

WT="$TMP/bash_check_wt"; rm -rf "$WT"
git worktree add -q "$WT" -b wt-branch
pad "$WT/far.sh" 240
bc "a worktree the command does not name is left alone" "ls" 0 ""
bc "a worktree the command names is judged"           "W=$WT; python3 x" 2 "far.sh — 240 lines"
git worktree remove --force "$WT"

N=$((N+1))
mkdir -p "$TMP/bash_check_plain"
out=$(printf '{}' | CLAUDE_PROJECT_DIR="$TMP/bash_check_plain" bash "$BC_ROOT/.claude/hooks/bash-check.sh" 2>&1); rc=$?
if [ "$rc:$out" = "0:" ]; then PASS=$((PASS+1)); echo "  ok   outside a git repo it does nothing"
else FAIL=$((FAIL+1)); echo "  FAIL outside a git repo it does nothing — exit $rc: $out"; fi
