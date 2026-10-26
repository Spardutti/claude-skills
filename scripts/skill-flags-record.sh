#!/bin/bash

INPUT=$(cat | tr -d '\n')

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
TRANSCRIPT=$(printf '%s' "$INPUT" | grep -o '"agent_transcript_path":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//')

# A named agent reports its name as agent_type; the meta file beside its transcript keeps the type.
TYPES="$INPUT"
[ -f "${TRANSCRIPT%.jsonl}.meta.json" ] && TYPES="$TYPES$(tr -d '\n' < "${TRANSCRIPT%.jsonl}.meta.json")"
AUDIT=0
case "$TYPES" in *'"agent_type":"gauntlet-skills"'*|*'"agentType":"gauntlet-skills"'*) AUDIT=1 ;; esac

# The SubagentHandback tool carries the report and leaves last_assistant_message empty.
handback() {
  node -e 'for (const s of require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n").reverse()) {
    let c; try { c = JSON.parse(s).message; } catch { continue; }
    const h = Array.isArray(c?.content) && c.content.find((x) => x.type === "tool_use" && x.name === "SubagentHandback");
    if (h?.input?.message) { process.stdout.write(JSON.stringify(h.input.message).slice(1, -1)); break; }
  }' "$1" 2>/dev/null
}

record() {  # record <reply, JSON-escaped>
  local reply="$1" log model cwd branch step
  if [ "$AUDIT" = 1 ]; then log=skill-flags.jsonl
  else case "$reply" in *'\"failure_scenario\"'*) log=review-findings.jsonl ;; *) return ;; esac; fi
  model=""
  [ -f "$TRANSCRIPT" ] && model=$(grep -o '"model":"[^"]*"' "$TRANSCRIPT" | tail -1 | sed 's/.*:"//; s/"$//')
  . "$SCRIPT_DIR/gate-config.sh" 2>/dev/null || return
  cwd=$(json_field "$INPUT" cwd)
  # A review run in a worktree belongs to the worktree's branch, not the main folder's.
  branch=$(git -C "${cwd:-$PROJECT_DIR}" branch --show-current 2>/dev/null | json_string)
  printf '{"ts":"%s","branch":"%s","model":"%s","reply":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$branch" "$model" "$reply" \
    >> "$(diary_dir "$SCRIPT_DIR")/$log"
  case "$log" in skill-flags.jsonl) step=audit ;; *) step=review ;; esac
  SHIP_LOG_ROOT="${cwd:-$PROJECT_DIR}" node "$SCRIPT_DIR/ship-log.mjs" step "$step" end >/dev/null 2>&1
}

# Kept JSON-escaped as it arrived, so the line stays valid JSON without a parser.
REPLY=$(printf '%s' "$INPUT" | sed -nE 's/.*"last_assistant_message":"(([^"\\]|\\.)*)".*/\1/p')
if [ -n "$REPLY" ]; then record "$REPLY"; exit 0; fi
[ -f "$TRANSCRIPT" ] || exit 0

# Measured: the hook fires before the handback reaches the transcript, so wait off the hot path.
( for _ in $(seq 1 40); do
    r=$(handback "$TRANSCRIPT"); [ -n "$r" ] && { record "$r"; exit 0; }
    sleep 0.25
  done ) </dev/null >/dev/null 2>&1 &
exit 0
