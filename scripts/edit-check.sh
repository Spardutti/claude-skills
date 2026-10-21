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
BLOCKED=""  # one rule id per line

run() {  # run <rule id when it fails, or empty> <command...>
  local id="$1" out rc
  shift
  out=$("$@" 2>&1); rc=$?
  [ -z "$out" ] && return
  if [ "$rc" = 0 ]; then NOTES="$NOTES$out"$'\n'; else FAILS="$FAILS$out"$'\n'; [ -n "$id" ] && BLOCKED="$BLOCKED$id"$'\n'; fi
}

# The gate measures length from the git root, so a monorepo subfolder shares its baseline.
GIT_ROOT=$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PROJECT_DIR")
[ -f "$HERE/line-limit.sh" ] && run line-limit env LINE_LIMIT_ROOT="$GIT_ROOT" bash "$HERE/line-limit.sh" --file "$FILE"
if [ -f "$HERE/lint-ratchet.mjs" ] && command -v node >/dev/null; then
  IDS=$(mktemp); trap 'rm -f "$IDS"' EXIT TERM
  lint() { cd "$PROJECT_DIR" && LINT_RATCHET_BLOCKED="$IDS" node "$HERE/lint-ratchet.mjs" --file "$FILE"; }
  run "" lint
  BLOCKED="$BLOCKED$(cat "$IDS")"$'\n'
fi

# A rule that blocks on branch after branch is one its skill should teach up front.
log_block() {
  local rules diary
  rules=$(printf '%s' "$BLOCKED" | sort -u | while IFS= read -r id; do
    [ -n "$id" ] && printf '"%s",' "$(printf '%s' "$id" | json_string)"
  done)
  [ -n "$rules" ] || return 0
  diary=$(diary_dir "$HERE")
  mkdir -p "$diary"
  printf '{"ts":"%s","branch":"%s","file":"%s","rules":[%s]}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(git -C "$(dirname "$FILE")" branch --show-current 2>/dev/null | json_string)" \
    "$(printf '%s' "${FILE#"$PROJECT_DIR"/}" | json_string)" "${rules%,}" >> "$diary/edit-blocks.jsonl"
}

if [ -n "$FAILS" ]; then
  declare -F json_string >/dev/null && declare -F diary_dir >/dev/null && log_block
  printf '%s%s' "$FAILS" "$NOTES" >&2
  exit 2
fi
if [ -n "$NOTES" ] && declare -F json_string >/dev/null; then
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$(printf '%s' "$NOTES" | json_string)"
fi
exit 0
