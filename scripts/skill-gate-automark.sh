#!/bin/bash
# PostToolUse on Skill: marks gate satisfied + records loaded skill.

INPUT=$(cat)

SESSION_ID=$(printf '%s' "$INPUT" | grep -o '"session_id":"[^"]*"' | head -1 | sed 's/"session_id":"//; s/"$//')
if [ -z "$SESSION_ID" ]; then
  exit 0
fi

# Keyed exactly as the gate keys it. A subagent carries the parent's
# session_id, so both scripts fall back to agent_id when one is present — and
# they must agree, or a loaded skill writes a marker the gate never looks for
# and every edit is denied forever.
AGENT_ID=$(printf '%s' "$INPUT" | grep -o '"agent_id":"[^"]*"' | head -1 | sed 's/"agent_id":"//; s/"$//')
KEY="$SESSION_ID"
if [ -n "$AGENT_ID" ]; then
  KEY=$(printf '%s' "$AGENT_ID" | tr -cd 'A-Za-z0-9_-')
fi

touch "/tmp/claude-skill-gate-$KEY"

SKILL_NAME=$(printf '%s' "$INPUT" | grep -o '"skill":"[^"]*"' | head -1 | sed 's/"skill":"//; s/"$//')
if [ -n "$SKILL_NAME" ]; then
  # Sanitize: only allow [A-Za-z0-9_-] in the marker filename.
  SAFE_NAME=$(printf '%s' "$SKILL_NAME" | tr -cd 'A-Za-z0-9_-')
  if [ -n "$SAFE_NAME" ]; then
    touch "/tmp/claude-skill-loaded-$KEY-$SAFE_NAME"
  fi
fi

exit 0
