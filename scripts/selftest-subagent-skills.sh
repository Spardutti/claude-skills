#!/usr/bin/env bash
# Cases for a subagent getting its own markers, and for the shipped skills
# declaring the triggers the gate reads.
# Sourced by gauntlet-selftest.sh; shares its $HERE, $TMP, $N, $PASS, $FAIL.


# A subagent reports the PARENT's session_id — measured with a probe hook that
# dumped its own stdin from the main thread and from inside a subagent. So a
# worker spawned to implement part of a plan inherited the main thread's
# cleared gate and edited with nothing loaded in its own context. agent_id is
# present only inside a subagent and holds steady across its turns, so the
# markers key on it instead. All three hooks must agree, or a loaded skill
# writes a marker the gate never reads and every edit is denied forever.
echo "a subagent gets its own markers"
newrepo sg_agent
mkdir -p .claude/skills/rx
printf -- '---\nname: rx\ntracks: react@19.2\nmetadata:\n  gate-paths: "**/*.tsx"\n---\n## Rules\n- x\n' > .claude/skills/rx/SKILL.md
printf '%s\n' '{"dependencies":{"react":"19.2.0"}}' > package.json
node -e "import('$HERE/../cli/lib/setup-hook.mjs').then(m=>m.setupHook('$PWD'))" >/dev/null 2>&1
SKG=".claude/hooks/skill-gate.sh"
AMK=".claude/hooks/skill-gate-automark.sh"
ASID="ag$RUN"
AGID="asub-agent-$RUN"

agate() {  # agate <label> <deny|allow> <agent_id or empty>
  N=$((N+1))
  if [ -n "$3" ]; then
    j=$(printf '{"session_id":"%s","agent_id":"%s","tool_name":"Write","tool_input":{"file_path":"src/App.tsx"}}' "$ASID" "$3")
  else
    j=$(printf '{"session_id":"%s","tool_name":"Write","tool_input":{"file_path":"src/App.tsx"}}' "$ASID")
  fi
  out=$(printf '%s' "$j" | bash "$SKG")
  got=allow; case "$out" in *deny*) got=deny ;; esac
  if [ "$got" = "$2" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s — want %s, got %s\n' "$1" "$2" "$got"; fi
}

rm -f /tmp/claude-skill-gate-$ASID /tmp/claude-skill-loaded-$ASID-* /tmp/claude-skill-gate-$AGID /tmp/claude-skill-loaded-$AGID-*

# The main thread loads the skill the way it always has: through the automark
# hook, not by hand — a stub that touches the file it believes in would agree
# with the bug.
printf '{"session_id":"%s","tool_name":"Skill","tool_input":{"skill":"rx"}}' "$ASID" | bash "$AMK"
agate "the main thread is cleared by its own load" allow ""
agate "the subagent does not inherit that"          deny  "$AGID"

# Now the subagent loads it. Its automark call carries agent_id too.
printf '{"session_id":"%s","agent_id":"%s","tool_name":"Skill","tool_input":{"skill":"rx"}}' "$ASID" "$AGID" | bash "$AMK"
agate "the subagent is cleared by its own load"     allow "$AGID"
agate "and the main thread still is"                allow ""

# A second subagent starts cold — one worker's load must not clear another's.
agate "a second subagent starts cold"               deny  "bsub-other-$RUN"

N=$((N+1))
if [ -f "/tmp/claude-skill-loaded-$AGID-rx" ]; then
  PASS=$((PASS+1)); printf '  ok   %s\n' "the automark wrote the marker under the agent key"
else
  FAIL=$((FAIL+1)); printf '  FAIL %s\n' "the automark wrote the marker under the agent key"
fi
rm -f /tmp/claude-skill-gate-$ASID /tmp/claude-skill-loaded-$ASID-* /tmp/claude-skill-gate-$AGID /tmp/claude-skill-loaded-$AGID-*

# The hook logic above is exercised against synthetic skills so it stays green
# when skill content changes. This asserts the shipped skills actually opt in —
# a paths: dropped from react/SKILL.md is silent everywhere else.
echo "shipped skills declare their triggers"
for s in sql docker-best-practices code-structure security-practices; do
  N=$((N+1))
  f="$HERE/../skills/$s/SKILL.md"
  if grep -q '^  gate-paths:' "$f"; then
    PASS=$((PASS+1)); printf '  ok   %s declares gate-paths\n' "$s"
  else
    FAIL=$((FAIL+1)); printf '  FAIL %s is missing metadata.gate-paths\n' "$s"
  fi
done
for s in react fastapi typescript-best-practices tanstack-query tanstack-router express drizzle-orm testing-best-practices drf-best-practices; do
  N=$((N+1))
  f="$HERE/../skills/$s/SKILL.md"
  if grep -q '^  gate-paths:' "$f" && grep -q '^tracks:' "$f"; then
    PASS=$((PASS+1)); printf '  ok   %s declares gate-paths and tracks\n' "$s"
  else
    FAIL=$((FAIL+1)); printf '  FAIL %s is missing metadata.gate-paths or tracks:\n' "$s"
  fi
done

# A bare `paths:` key makes Claude Code drop the skill from its registry
# outright: every Skill(name) returns "Unknown skill", and with no SKIP for a
# mandatory skill the session cannot edit code at all. Ten shipped skills went
# out that way. This is the assertion that was missing.
echo "no shipped skill carries a bare paths: key"
for f in "$HERE"/../skills/*/SKILL.md; do
  N=$((N+1))
  s=$(basename "$(dirname "$f")")
  if grep -q '^paths:' "$f"; then
    FAIL=$((FAIL+1)); printf '  FAIL %s has a bare paths: — Claude Code will not load it\n' "$s"
  else
    PASS=$((PASS+1)); printf '  ok   %s\n' "$s"
  fi
done