#!/usr/bin/env bash
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

stop plan-feature-reuse '{"skill":"react","violations":[],"checked":1}'
ok=0; [ "$(wc -l < "$FLAGLOG")" -eq 1 ] && ok=1
sf "other agents are not logged" $ok "$(cat "$FLAGLOG")"

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
