#!/bin/bash

INPUT=$(cat | tr -d '\n')

case "$INPUT" in
  *'"agent_type":"gauntlet-skills"'*) LOG=skill-flags.jsonl ;;
  *'\"failure_scenario\"'*) LOG=review-findings.jsonl ;;
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

. "$SCRIPT_DIR/gate-config.sh" 2>/dev/null || json_string() { tr -cd '[:alnum:]/._-'; }
BRANCH=$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null | json_string)
printf '{"ts":"%s","branch":"%s","model":"%s","reply":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BRANCH" "$MODEL" "$REPLY" \
  >> "$PROJECT_DIR/.claude/$LOG"

exit 0
