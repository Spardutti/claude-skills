#!/usr/bin/env bash
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null || exit 1
NO_LOG=""; [ "${2:-}" = "--no-log" ] && { NO_LOG=1; set -- "$1" "${@:3}"; }
# The shared .git dir, so a worktree's mark is found from the main folder.
COMMON=$(cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd) || exit 1
BRANCH=${2:-$(git branch --show-current 2>/dev/null)}
[ -n "$BRANCH" ] || exit 1
MARK="/tmp/claude-ship-$(printf '%s %s' "$COMMON" "$BRANCH" | cksum | cut -d' ' -f1)"

# A mark lasts 12 hours, so a branch reused later (dev, for a release) needs /ship again.
case "${1:-}" in
  begin)
    touch "$MARK"
    # The log opens here, not in ship.md: agents skipped that step. A failed log never fails the mark.
    [ -z "$NO_LOG" ] && command -v node >/dev/null && node "$HERE/ship-log.mjs" start >/dev/null 2>&1
    true ;;
  check) [ -n "$(find "$MARK" -mmin -720 2>/dev/null)" ] ;;
  *) echo "usage: ship-mark.sh begin [--no-log] | check [branch]" >&2; exit 2 ;;
esac
