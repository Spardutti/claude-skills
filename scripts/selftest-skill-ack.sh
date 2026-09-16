#!/usr/bin/env bash
# Cases for handing the model its ack command before a write is ever blocked.
# Sourced by gauntlet-selftest.sh; shares its $HERE, $TMP, $N, $PASS, $FAIL.

# The ack path carries the session id, which the model cannot know. Until the
# automark printed it, a denial was the only place it appeared, so every session
# took one red BLOCKED per skill before its first write.
echo "the ack command arrives when a skill loads"
newrepo sg_ack
mkdir -p .claude/skills/rx
printf -- '---\nname: rx\ntracks: react@19.2\nmetadata:\n  gate-paths: "**/*.tsx"\n---\n## Rules\n- x\n' > .claude/skills/rx/SKILL.md
printf '%s\n' '{"dependencies":{"react":"19.2.0"}}' > package.json
node -e "import('$HERE/../cli/lib/setup-hook.mjs').then(m=>m.setupHook('$PWD'))" >/dev/null 2>&1
AKID="ak$RUN"
AK_CLEAN="/tmp/claude-skill-gate-$AKID /tmp/claude-skill-loaded-$AKID-rx /tmp/claude-skill-acked-$AKID-rx"

ack() {  # ack <label> <0|1 passed>
  N=$((N+1))
  if [ "$2" = 1 ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n       got: %s\n' "$1" "$3"; fi
}

rm -f $AK_CLEAN
MOUT=$(printf '{"session_id":"%s","tool_name":"Write","tool_input":{"file_path":"src/App.tsx"}}' "$AKID" \
       | bash .claude/hooks/skill-gate.sh)
ok=0; case "$MOUT" in *"touch /tmp/claude-skill-acked-$AKID-rx"*) ok=1 ;; esac
ack "the mandatory denial names the ack command too" $ok "$MOUT"

AOUT=$(printf '{"session_id":"%s","tool_name":"Skill","tool_input":{"skill":"rx"}}' "$AKID" \
       | bash .claude/hooks/skill-gate-automark.sh 2>"$TMP/ak.err")
CTX=$(printf '%s' "$AOUT" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{const h=JSON.parse(d).hookSpecificOutput;if(h.hookEventName==='PostToolUse')process.stdout.write(h.additionalContext)})" 2>/dev/null)
ok=0; [ -n "$CTX" ] && ok=1
ack "loading a skill returns PostToolUse context" $ok "$AOUT"
ok=0; [ ! -s "$TMP/ak.err" ] && ok=1
ack "the automark writes nothing to stderr" $ok "$(cat "$TMP/ak.err")"

# Run the command the model is handed, verbatim, then ask the real gate. A text
# check alone agrees with a typo in the path.
ACK_LINE=$(printf '%s\n' "$CTX" | grep -o 'touch /tmp/claude-skill-acked-[A-Za-z0-9_ -]*' | head -1)
[ -n "$ACK_LINE" ] && bash -c "$ACK_LINE"
GOUT=$(printf '{"session_id":"%s","tool_name":"Write","tool_input":{"file_path":"%s/src/App.tsx"}}' "$AKID" "$PWD" \
       | bash .claude/hooks/skill-application-gate.sh)
ok=0; [ -n "$ACK_LINE" ] && [ -z "$GOUT" ] && ok=1
ack "running that command lets the first write through" $ok "ctx=$CTX gate=$GOUT"

AOUT=$(printf '{"session_id":"%s","tool_name":"Skill","tool_input":{"skill":"rx"}}' "$AKID" \
       | bash .claude/hooks/skill-gate-automark.sh)
ok=0; [ -z "$AOUT" ] && ok=1
ack "an already acked skill is not asked again" $ok "$AOUT"
rm -f $AK_CLEAN

# A subagent keys on agent_id; handing it the session key would ack a marker
# its gate never reads.
SUB=$(printf '{"session_id":"%s","agent_id":"sub%s","tool_name":"Skill","tool_input":{"skill":"rx"}}' "$AKID" "$RUN" \
      | bash .claude/hooks/skill-gate-automark.sh)
SUBKEY=$(printf 'sub%s' "$RUN" | tr -cd 'A-Za-z0-9_-')
ok=0; case "$SUB" in *"claude-skill-acked-$SUBKEY-rx"*) ok=1 ;; esac
ack "a subagent is handed its own key" $ok "$SUB"
rm -f "/tmp/claude-skill-gate-$SUBKEY" "/tmp/claude-skill-loaded-$SUBKEY-rx"
