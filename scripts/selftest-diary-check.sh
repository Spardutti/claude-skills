#!/usr/bin/env bash
[ -n "${SELFTEST_SANDBOX:-}" ] || { echo "$(basename "$0"): run it through scripts/gauntlet-selftest.sh, never on its own" >&2; exit 1; }

echo "the diary check /ship runs at the end"
DC="$TMP/dc"; rm -rf "$DC"; mkdir -p "$DC/.claude/hooks"
cp "$HERE/diary-check.mjs" "$HERE/diary-lib.mjs" "$HERE/gate-config.sh" "$DC/.claude/hooks/"
dc() {  # dc <label> <expected exit> <expected substring, empty for silence> [args]
  local label="$1" want="$2" sub="$3"; shift 3
  N=$((N+1))
  out=$(env -C "$TMP" -u CLAUDE_PROJECT_DIR node "$DC/.claude/hooks/diary-check.mjs" "$@" 2>&1); rc=$?
  if [ "$rc" = "$want" ] && { [ -z "$sub" ] && [ -z "$out" ] || [ -n "$sub" ] && case "$out" in *"$sub"*) true ;; *) false ;; esac; }; then
    PASS=$((PASS+1)); printf '  ok   %s\n' "$label"
  else FAIL=$((FAIL+1)); printf '  FAIL %s — exit %s: %s\n' "$label" "$rc" "$out"; fi
}
rev() { printf '{"ts":"%s","branch":"%s","reply":"[{\\"failure_scenario\\":\\"x\\"}]"}\n' "$1" "$2" >> "$DC/.claude/review-findings.jsonl"; }
gate() { printf '{"ts":"%s","branch":"%s","status":"FAIL","report":"x"}\n' "$1" "$2" >> "$DC/.claude/gate-findings.jsonl"; }
skill() { printf '{"ts":"%s","branch":"%s","reply":%s}\n' "$1" "$2" "$3" >> "$DC/.claude/skill-flags.jsonl"; }

dc "no diaries says nothing" 0 ""
rev 2000-01-01T00:00:00Z feat/a
dc "entries from one branch say nothing" 0 ""
skill 2000-01-01T00:00:00Z feat/c '"{\"skill\":\"react\",\"violations\":[],\"checked\":2}"'
skill 2000-01-01T00:00:00Z feat/d '"I could not finish the audit."'
dc "clean or unreadable skills audits are not findings" 0 ""
gate 2000-01-01T00:00:00Z dev
dc "a release run on dev never counts as a second branch" 0 ""
gate 2000-01-01T00:00:00Z feat/b
echo 'not json' >> "$DC/.claude/gate-findings.jsonl"
dc "entries from two branches suggest /add-rule, read from the hook's own project" 0 "2 diary entries from 2 branches since /add-rule last looked"
dc "--mark records that /add-rule looked" 0 "" --mark
dc "after --mark, old entries say nothing" 0 ""
rev 2999-01-01T00:00:00Z feat/e; gate 2999-01-01T00:00:00Z feat/f
dc "new entries from two branches after --mark suggest it again, naming the mark" 0 "2 diary entries from 2 branches since /add-rule last looked ("
dc "an unknown argument is an error, not a silent check" 1 "usage" --marks

N=$((N+1))
NOD="$TMP/dc-none"; rm -rf "$NOD"; mkdir -p "$NOD"
rm -f "$DC/.claude/add-rule-checked"
CLAUDE_PROJECT_DIR="$NOD" node "$DC/.claude/hooks/diary-check.mjs" --mark 2>/dev/null
if [ -f "$DC/.claude/add-rule-checked" ] && [ ! -e "$NOD/.claude" ]; then
  PASS=$((PASS+1)); echo "  ok   installed in .claude/hooks, it uses that .claude whatever CLAUDE_PROJECT_DIR says"
else FAIL=$((FAIL+1)); echo "  FAIL installed in .claude/hooks, it uses that .claude whatever CLAUDE_PROJECT_DIR says"; fi
N=$((N+1))
mkdir -p "$TMP/dc-repo/scripts"; cp "$HERE/diary-check.mjs" "$HERE/diary-lib.mjs" "$HERE/gate-config.sh" "$TMP/dc-repo/scripts/"
if CLAUDE_PROJECT_DIR="$NOD" node "$TMP/dc-repo/scripts/diary-check.mjs" --mark 2>/dev/null && [ -f "$NOD/.claude/add-rule-checked" ]; then
  PASS=$((PASS+1)); echo "  ok   run from scripts/, it uses CLAUDE_PROJECT_DIR and creates .claude"
else FAIL=$((FAIL+1)); echo "  FAIL run from scripts/, it uses CLAUDE_PROJECT_DIR and creates .claude"; fi

N=$((N+1))
SH="$TMP/dc-shared"; PS="$TMP/dc-sym"; rm -rf "$SH" "$PS"; mkdir -p "$SH" "$PS/.claude"
cp "$HERE/diary-check.mjs" "$HERE/diary-lib.mjs" "$HERE/gate-config.sh" "$SH/"; ln -s "$SH" "$PS/.claude/hooks"
env -C "$TMP" -u CLAUDE_PROJECT_DIR node "$PS/.claude/hooks/diary-check.mjs" --mark 2>/dev/null
if [ -f "$PS/.claude/add-rule-checked" ]; then PASS=$((PASS+1)); echo "  ok   a symlinked .claude/hooks still means that project's .claude, as in the bash hooks"
else FAIL=$((FAIL+1)); echo "  FAIL a symlinked .claude/hooks still means that project's .claude, as in the bash hooks"; fi

rm -f "$DC/.claude/add-rule-checked"
N=$((N+1))
got=$(env -C "$TMP" -u CLAUDE_PROJECT_DIR node "$DC/.claude/hooks/diary-check.mjs" --entries 2>&1 | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const b=d.trim().split("\n").map(l=>JSON.parse(l).branch).sort();process.stdout.write(b.join(","))})' 2>&1)
if [ "$got" = "feat/a,feat/b,feat/e,feat/f" ]; then PASS=$((PASS+1)); echo "  ok   --entries prints every finding, without trunk runs or clean audits"
else FAIL=$((FAIL+1)); echo "  FAIL --entries prints every finding, without trunk runs or clean audits — $got"; fi
