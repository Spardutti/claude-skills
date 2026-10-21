#!/usr/bin/env bash

INPUT=$(cat)

FILE=$(printf '%s' "$INPUT" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' \
       | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//')
[ -z "$FILE" ] && exit 0

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
if [ -f "$HERE/gate-config.sh" ]; then
  . "$HERE/gate-config.sh"
  load_gauntlet_conf "$PROJECT_DIR/.claude/gauntlet.conf" "$HERE/../gauntlet.conf"
  is_ignored "${FILE#"$PROJECT_DIR"/}" && exit 0
fi
FAILS=""
NOTES=""

run() {
  local out rc
  out=$("$@" 2>&1); rc=$?
  [ -z "$out" ] && return
  if [ "$rc" = 0 ]; then NOTES="$NOTES$out"$'\n'; else FAILS="$FAILS$out"$'\n'; fi
}

# The gate measures length from the git root, so a monorepo subfolder shares its baseline.
GIT_ROOT=$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PROJECT_DIR")
[ -f "$HERE/line-limit.sh" ] && run env LINE_LIMIT_ROOT="$GIT_ROOT" bash "$HERE/line-limit.sh" --file "$FILE"
lint() { cd "$PROJECT_DIR" && node "$HERE/lint-ratchet.mjs" --file "$FILE"; }
[ -f "$HERE/lint-ratchet.mjs" ] && command -v node >/dev/null && run lint

if [ -n "$FAILS" ]; then
  printf '%s%s' "$FAILS" "$NOTES" >&2
  exit 2
fi
if [ -n "$NOTES" ] && declare -F json_string >/dev/null; then
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$(printf '%s' "$NOTES" | json_string)"
fi
exit 0
