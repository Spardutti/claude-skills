#!/bin/bash

INPUT=$(cat | tr -d '\n')

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
TRANSCRIPT=$(printf '%s' "$INPUT" | grep -o '"agent_transcript_path":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//')

# The SubagentHandback tool carries the report and leaves last_assistant_message empty.
handback() {
  node -e 'for (const s of require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n").reverse()) {
    let c; try { c = JSON.parse(s).message; } catch { continue; }
    if (c?.role !== "assistant" || !Array.isArray(c.content)) continue;
    const h = c.content.find((x) => x.type === "tool_use" && x.name === "SubagentHandback");
    const t = h ? h.input?.message : c.content.filter((x) => x.type === "text").map((x) => x.text).join("");
    if (t) { process.stdout.write(JSON.stringify(t).slice(1, -1)); break; }
  }' "$1" 2>/dev/null
}

# Kept JSON-escaped as it arrived, so the line stays valid JSON without a parser.
REPLY=$(printf '%s' "$INPUT" | sed -nE 's/.*"last_assistant_message":"(([^"\\]|\\.)*)".*/\1/p')
[ -z "$REPLY" ] && [ -f "$TRANSCRIPT" ] && REPLY=$(handback "$TRANSCRIPT")
[ -z "$REPLY" ] && exit 0

case "$INPUT" in
  *'"agent_type":"gauntlet-skills"'*) LOG=skill-flags.jsonl ;;
  *) case "$REPLY" in *'\"failure_scenario\"'*) LOG=review-findings.jsonl ;; *) exit 0 ;; esac ;;
esac

MODEL=""
[ -f "$TRANSCRIPT" ] && MODEL=$(grep -o '"model":"[^"]*"' "$TRANSCRIPT" | tail -1 | sed 's/.*:"//; s/"$//')

. "$SCRIPT_DIR/gate-config.sh" 2>/dev/null || exit 0
CWD=$(json_field "$INPUT" cwd)
# A review run in a worktree belongs to the worktree's branch, not the main folder's.
BRANCH=$(git -C "${CWD:-$PROJECT_DIR}" branch --show-current 2>/dev/null | json_string)
printf '{"ts":"%s","branch":"%s","model":"%s","reply":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BRANCH" "$MODEL" "$REPLY" \
  >> "$(diary_dir "$SCRIPT_DIR")/$LOG"

case "$LOG" in skill-flags.jsonl) STEP=audit ;; *) STEP=review ;; esac
SHIP_LOG_ROOT="${CWD:-$PROJECT_DIR}" node "$SCRIPT_DIR/ship-log.mjs" step "$STEP" end >/dev/null 2>&1

exit 0
