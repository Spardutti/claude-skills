#!/usr/bin/env bash
[ -n "${SELFTEST_SANDBOX:-}" ] || { echo "$(basename "$0"): run it through scripts/gauntlet-selftest.sh, never on its own" >&2; exit 1; }
# Cases for logging /ship skills-audit verdicts and the /skill-report tally.
# Sourced by gauntlet-selftest.sh; shares its $HERE, $TMP, $N, $PASS, $FAIL.

echo "skills-audit verdicts are logged and tallied"
newrepo sg_flags
printf '%s\n' '{"hooks":{"PostToolUse":[{"matcher":"Skill","hooks":[{"type":"command","command":"$CLAUDE_PROJECT_DIR/.claude/hooks/skill-gate-automark.sh"}]}]}}' > .claude/settings.json
node -e "import('$HERE/../cli/lib/setup-hook.mjs').then(m=>m.setupHook('$PWD'))" >/dev/null 2>&1
node -e "import('$HERE/../cli/lib/setup-hook.mjs').then(m=>m.setupHook('$PWD'))" >/dev/null 2>&1
FLAGLOG=.claude/skill-flags.jsonl

sf() {  # sf <label> <0|1 passed> <got>
  N=$((N+1))
  if [ "$2" = 1 ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n       got: %s\n' "$1" "$3"; fi
}

STOPS=$(node -e "import('node:fs').then(m=>m.readFileSync('.claude/settings.json','utf8')).then(t=>console.log(JSON.stringify(JSON.parse(t).hooks.SubagentStop)))")
ok=0; [ "$STOPS" = '[{"hooks":[{"type":"command","command":"$CLAUDE_PROJECT_DIR/.claude/hooks/skill-flags-record.sh"}]}]' ] && ok=1
sf "an upgrade registers SubagentStop once, even installed twice" $ok "$STOPS"

printf '{"message":{"model":"claude-opus-5-5"}}\n' > "$TMP/agent.jsonl"
stop() {  # stop <agent_type> <reply>
  node -e 'process.stdout.write(JSON.stringify({session_id:"s",hook_event_name:"SubagentStop",agent_type:process.argv[1],agent_transcript_path:process.argv[3],last_assistant_message:process.argv[2],stop_hook_active:false}))' "$1" "$2" "$TMP/agent.jsonl" \
    | bash .claude/hooks/skill-flags-record.sh
}

V1='```json
{"skill":"react","violations":[{"file":"a.tsx","line":3,"rule":"Never X","what":"says \"no\"","fix":"f"}],"checked":4}
```'
stop gauntlet-skills "$V1"
LINE=$(cat "$FLAGLOG" 2>/dev/null)
GOT=$(printf '%s' "$LINE" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{const l=JSON.parse(d);process.stdout.write(l.model+'|'+l.reply)})" 2>&1)
ok=0; [ "$GOT" = "claude-opus-5-5|$V1" ] && ok=1
sf "a verdict with quotes, a fence and newlines is logged intact, with its model" $ok "$GOT"

stop discover-critic '{"skill":"react","violations":[],"checked":1}'
ok=0; [ "$(wc -l < "$FLAGLOG")" -eq 1 ] && ok=1
sf "other agents are not logged" $ok "$(cat "$FLAGLOG")"
node -e 'const fs=require("fs");fs.writeFileSync(process.argv[1],[{message:{role:"assistant",model:"claude-opus-5-5",content:[{type:"text",text:"thinking aloud"}]}},{message:{role:"assistant",model:"claude-opus-5-5",content:[{type:"tool_use",name:"SubagentHandback",input:{message:process.argv[2]}}]}},{type:"user",message:{role:"user",content:[{type:"tool_result",content:"Report delivered to your caller."}]}}].map(JSON.stringify).join("\n")+"\n")' "$TMP/handback.jsonl" "$V1"
node -e 'process.stdout.write(JSON.stringify({session_id:"s",hook_event_name:"SubagentStop",agent_type:"gauntlet-skills",agent_transcript_path:process.argv[1],last_assistant_message:"",stop_hook_active:false}))' "$TMP/handback.jsonl" | bash .claude/hooks/skill-flags-record.sh
GOT=$(tail -1 "$FLAGLOG" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{const l=JSON.parse(d);process.stdout.write(l.model+'|'+l.reply)})" 2>&1)
ok=0; [ "$GOT" = "claude-opus-5-5|$V1" ] && [ "$(wc -l < "$FLAGLOG")" -eq 2 ] && ok=1
sf "a verdict handed back through SubagentHandback is read from the transcript" $ok "$GOT"
sed -i '$d' "$FLAGLOG"

stop gauntlet-skills '{"skill":"react","violations":[{"rule":"Never X"}],"checked":2}'
stop gauntlet-skills '{"skill":"react","violations":[],"checked":3}'
stop gauntlet-skills '{"skill":"tanstack-query","violations":[],"checked":0}'
stop gauntlet-skills '{"skill":"python-testing","violations":[{"rule":"Always use fixtures"}],"checked":1}'
REPORT=$(node .claude/hooks/skill-report.mjs 2>&1)
WANT='skill           audits  flagged  top rule broken
react                3        2  Never X
python-testing       1        1  Always use fixtures

models: claude-opus-5-5 (4)'
ok=0; [ "$REPORT" = "$WANT" ] && ok=1
sf "the report counts applied audits only, most flagged first" $ok "$REPORT"

rm -f "$FLAGLOG"
REPORT=$(node .claude/hooks/skill-report.mjs 2>&1)
ok=0; [ "$REPORT" = "No skill audits recorded yet. Run /ship to record some." ] && ok=1
sf "no log yet says so instead of failing" $ok "$REPORT"

REVLOG=.claude/review-findings.jsonl
R1='[{"file":"a.ts","summary":"says \"no\"","failure_scenario":"x"}]'
stop general-purpose "$R1"
GOT=$(node -e "const l=JSON.parse(require('fs').readFileSync('$REVLOG','utf8'));process.stdout.write(l.reply)" 2>&1)
ok=0; [ "$GOT" = "$R1" ] && [ ! -f "$FLAGLOG" ] && ok=1
sf "a /code-review reply is logged to its own file, intact" $ok "$GOT"
stop general-purpose 'I read three files and found nothing.'
ok=0; [ "$(wc -l < "$REVLOG")" -eq 1 ] && ok=1
sf "a subagent reply with no findings is not logged" $ok "$(cat "$REVLOG")"
ok=0; grep -q '"branch":"' "$REVLOG" && ok=1
sf "a logged review names the branch it was run on" $ok "$(head -c 200 "$REVLOG")"
git worktree add -q "$TMP/sf-wt" -b feat/wt-review >/dev/null 2>&1
sf_lines=$(wc -l < "$REVLOG")
node -e 'process.stdout.write(JSON.stringify({session_id:"s",cwd:process.argv[1],hook_event_name:"SubagentStop",agent_type:"general-purpose",last_assistant_message:process.argv[2],stop_hook_active:false}))' "$TMP/sf-wt" "$R1" \
  | bash .claude/hooks/skill-flags-record.sh
ok=0; tail -1 "$REVLOG" | grep -q '"branch":"feat/wt-review"' && ok=1
sf "a review run in a worktree names the worktree's branch" $ok "$(tail -1 "$REVLOG" | head -c 200)"
head -n "$sf_lines" "$REVLOG" > "$REVLOG.tmp" && mv "$REVLOG.tmp" "$REVLOG"; git worktree remove --force "$TMP/sf-wt" >/dev/null 2>&1
stop general-purpose 'The review JSON has a failure_scenario field per finding.'
ok=0; [ "$(wc -l < "$REVLOG")" -eq 1 ] && ok=1
sf "a reply that only mentions failure_scenario in prose is not logged" $ok "$(tail -1 "$REVLOG")"

mkdir -p "$HOME/.claude"; echo 'GAUNTLET_SHIP_LOG=1' > "$HOME/.claude/gauntlet.conf"
node .claude/hooks/ship-log.mjs start; git checkout -qb feat/steps 2>/dev/null; node .claude/hooks/ship-log.mjs start
SFLOG="$HOME/.claude/ship-logs/open/sg_flags__feat-steps.json"
stop gauntlet-skills "$V1"
ok=0; node -e 'process.exit(require(process.argv[1]).steps.audit?.end ? 0 : 1)' "$SFLOG" 2>/dev/null && ok=1
sf "a finished audit agent ends the audit step by itself" $ok "$(cat "$SFLOG" 2>&1 | head -c 300)"
stop general-purpose "$R1"
ok=0; node -e 'process.exit(require(process.argv[1]).steps.review?.end ? 0 : 1)' "$SFLOG" 2>/dev/null && ok=1
sf "a finished review ends the review step by itself" $ok "$(cat "$SFLOG" 2>&1 | head -c 300)"
git checkout -qb feat/no-ship 2>/dev/null
stop general-purpose "$R1"
ok=0; [ ! -e "$HOME/.claude/ship-logs/open/sg_flags__feat-no-ship.json" ] && ok=1
sf "a review outside /ship opens no log" $ok "$(ls "$HOME/.claude/ship-logs/open" 2>&1)"
rm -rf "$HOME/.claude/gauntlet.conf" "$HOME/.claude/ship-logs"
