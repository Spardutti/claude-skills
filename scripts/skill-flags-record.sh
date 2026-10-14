#!/bin/bash
# SubagentStop: appends each gauntlet-skills verdict to .claude/skill-flags.jsonl.

INPUT=$(cat | tr -d '\n')

case "$INPUT" in
  *'"agent_type":"gauntlet-skills"'*) ;;
  *) exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Kept JSON-escaped as it arrived, so the line stays valid JSON without a parser.
REPLY=$(printf '%s' "$INPUT" | sed -nE 's/.*"last_assistant_message":"(([^"\\]|\\.)*)".*/\1/p')
[ -z "$REPLY" ] && exit 0

TRANSCRIPT=$(printf '%s' "$INPUT" | grep -o '"agent_transcript_path":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//')
MODEL=""
[ -f "$TRANSCRIPT" ] && MODEL=$(grep -o '"model":"[^"]*"' "$TRANSCRIPT" | tail -1 | sed 's/.*:"//; s/"$//')

printf '{"ts":"%s","model":"%s","reply":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MODEL" "$REPLY" \
  >> "$PROJECT_DIR/.claude/skill-flags.jsonl"

exit 0
