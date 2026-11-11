#!/usr/bin/env bash
[ -n "${SELFTEST_SANDBOX:-}" ] || { echo "$(basename "$0"): run it through scripts/gauntlet-selftest.sh, never on its own" >&2; exit 1; }

echo "the correction scan /dream runs"
CS="$TMP/cs"; rm -rf "$CS"; mkdir -p "$CS/.claude/hooks" "$CS/chats"
cp "$HERE/correction-scan.mjs" "$HERE/diary-lib.mjs" "$HERE/gate-config.sh" "$CS/.claude/hooks/"
cs() { env -C "$TMP" -u CLAUDE_PROJECT_DIR node "$CS/.claude/hooks/correction-scan.mjs" "$@" 2>&1; }
said() { node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{process.stdout.write(d.trim().split("\n").filter(Boolean).map(l=>JSON.parse(l).said).join("|"))})'; }
check() {  # check <label> <want> <got>
  N=$((N+1))
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s — want [%s] got [%s]\n' "$1" "$2" "$3"; fi
}
user() { printf '{"type":"user","uuid":"u%s","timestamp":"%s","sessionId":"s1","gitBranch":"main","message":{"content":%s}%s}\n' "$1" "$1" "$2" "${3:-}" >> "$CS/chats/a.jsonl"; }
user 2000-01-01T00:00:01Z '"looks good, ship it"'
user 2000-01-01T00:00:02Z '"no, dont push yet"'
user 2000-01-01T00:00:03Z '"i dont know, what do you think?"'
user 2000-01-01T00:00:04Z '"<command-name>/clear</command-name> no"'
user 2000-01-01T00:00:04Z '"Another Claude session sent a message: no"'
user 2000-01-01T00:00:04Z '"This session is being continued from a previous conversation. stop"'
user 2000-01-01T00:00:05Z '"stop, wrong file"' ',"isMeta":true'
user 2000-01-01T00:00:06Z '"read this <pasted_content id=\"ab\">never do that</pasted_content id=\"ab\">"'
user 2000-01-01T00:00:07Z '[{"type":"text","text":"I said why, not change it"}]'
user 2000-01-01T00:00:08Z '[{"type":"tool_result","content":"no such file"}]'
echo 'not json' >> "$CS/chats/a.jsonl"
grep "dont push" "$CS/chats/a.jsonl" > "$CS/chats/resumed.jsonl"

check "keeps corrections, skips plain turns, meta, commands, other sessions, summaries, pastes, tool output and resumed copies" \
  "I said why, not change it|no, dont push yet" "$(cs --scan "$CS/chats" | said)"
check "--mark records that /dream looked" "" "$(cs --mark)"
user 2999-01-01T00:00:00Z '"never edit the lockfile"'
check "after --mark, only newer corrections come back" "never edit the lockfile" "$(cs --scan "$CS/chats" | said)"
N=$((N+1))
if cs --scan "$CS/missing" >/dev/null; then FAIL=$((FAIL+1)); echo "  FAIL a missing transcripts folder is an error"
else PASS=$((PASS+1)); echo "  ok   a missing transcripts folder is an error"; fi
