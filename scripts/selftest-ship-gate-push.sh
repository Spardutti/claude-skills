#!/usr/bin/env bash
[ -n "${SELFTEST_SANDBOX:-}" ] || { echo "$(basename "$0"): run it through scripts/gauntlet-selftest.sh, never on its own" >&2; exit 1; }

hook_in() {  # hook_in <label> <deny|allow> <cwd> <command>
  local out got=allow
  out=$(node -e 'process.stdout.write(JSON.stringify({ cwd: process.argv[1], tool_name: "Bash", tool_input: { command: process.argv[2] } }))' "$3" "$4" | bash "$H")
  case "$out" in *'"deny"'*) got=deny ;; esac
  N=$((N+1))
  if [ "$got" = "$2" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s — want %s, got %s\n' "$1" "$2" "$got"; fi
}

# A push to a feature branch ships nothing. A push while standing on a protected
# branch is a direct ship with no PR in front of it, so that one is gated. The
# branch comes from git, not from the command — `git push` names no branch.
BASEBR=$(git branch --show-current)
git checkout -qb feature/gate-scope 2>/dev/null
echo "const d=4" >> a.ts
hook "a push from a feature branch is not gated" allow "git push origin HEAD"
git checkout -q "$BASEBR" 2>/dev/null
hook "a push from the protected branch is gated" deny "git push origin HEAD"
hook "a push on the second line of a command is gated" deny 'git add -A\ngit push'
hook_in "a cwd git cannot read falls back to the main folder" deny /nonexistent/wt "git push origin HEAD"
hook_in "a quoted commit message does not hide the push after it" deny "$PWD" 'git commit -m "wip" && git push'
hook_in "a git -C path git cannot open falls back to the main folder" deny "$PWD" 'git -C ~/nowhere push'
git worktree add -q "$TMP/gs-wt" -b feature/wt-push >/dev/null 2>&1
sl_wt=$(git -C "$TMP/gs-wt" branch --show-current 2>/dev/null)
N=$((N+1)); if [ "$sl_wt" = feature/wt-push ]; then PASS=$((PASS+1)); echo "  ok   the push fixture's worktree exists"; else FAIL=$((FAIL+1)); echo "  FAIL the push fixture's worktree exists"; fi
hook_in "a worktree's push is read from the worktree, not the main folder's protected branch" allow "$TMP/gs-wt" "git push -u origin feature/wt-push"
hook_in "a push aimed at the protected main folder with git -C is still gated" deny "$TMP/gs-wt" "git -C $PWD push"
hook_in "a push with git -C into a feature worktree is read from that worktree" allow "$PWD" "git -C $TMP/gs-wt push -u origin feature/wt-push"
hook_in "a git -C commit whose message says push is not a push" allow "$PWD" "git -C $PWD commit -m fix-the-push-hook push"
hook_in "every push in a command is checked, not only the first" deny "$PWD" "git -C $TMP/gs-wt push && git -C $PWD push"
hook_in "a cd on its own line moves the push" deny "$TMP/gs-wt" "cd $PWD
git push"
git worktree remove --force "$TMP/gs-wt" >/dev/null 2>&1
git checkout -q feature/gate-scope 2>/dev/null
