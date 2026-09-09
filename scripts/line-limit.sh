#!/usr/bin/env bash
# line-limit.sh — the 200-line rule, applied to this repo's own code.
#
#   bash scripts/line-limit.sh             check; exit 1 on a violation
#   bash scripts/line-limit.sh --baseline  record today's counts as accepted
#
# The skills teach consumers never to write a file longer than 200 lines, and
# CLAUDE.md used to exempt this repo from its own rule. That sentence is why
# setup-hook.mjs reached 1740 lines with nothing objecting.
#
# A hard cap would fail on eight files today, so this is a RATCHET instead:
# every file already over the limit is recorded once in .line-limit-baseline
# and may not grow. A file that is not in the baseline gets the real 200-line
# limit. Debt is visible and can only shrink — the same shape as the
# .mutmut-baseline the ship gate already uses, and for the same reason: a gate
# that cannot go green on day one is a gate people delete.
#
# Not covered here: skills/*.md, which have their own caps in
# validate-skills.mjs, and anything under node_modules or .git.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
LIMIT=200
BASELINE="$ROOT/.line-limit-baseline"

# `find | wc -l` prints paths relative to ROOT so the baseline is portable
# between clones.
counts() {
  find "$ROOT" -type f \( -name '*.mjs' -o -name '*.js' -o -name '*.sh' \) \
    -not -path '*/node_modules/*' -not -path '*/.git/*' \
    -not -path '*/.claude/*' 2>/dev/null | sort | while IFS= read -r f; do
    printf '%s %s\n' "$(wc -l < "$f" | tr -d ' ')" "${f#"$ROOT"/}"
  done
}

NOW=$(counts)

if [ "${1:-}" = "--baseline" ]; then
  printf '%s\n' "$NOW" | awk -v lim="$LIMIT" '$1 > lim' > "$BASELINE"
  n=$(wc -l < "$BASELINE" | tr -d ' ')
  echo "line-limit: baseline written — $n file(s) over $LIMIT accepted as debt."
  echo "Commit $BASELINE. From here they may shrink but never grow."
  exit 0
fi

FAILED=0
NEW_OVER=""
GREW=""
SHRANK=""

while read -r n f; do
  [ -z "$f" ] && continue
  was=$(awk -v p="$f" '$2 == p { print $1 }' "$BASELINE" 2>/dev/null)
  if [ -z "$was" ]; then
    # Not accepted debt, so the real limit applies.
    if [ "$n" -gt "$LIMIT" ]; then
      NEW_OVER="$NEW_OVER  $f — $n lines (limit $LIMIT)
"
      FAILED=1
    fi
  elif [ "$n" -gt "$was" ]; then
    GREW="$GREW  $f — $n lines, was $was
"
    FAILED=1
  elif [ "$n" -lt "$was" ]; then
    SHRANK="$SHRANK  $f — $n lines, was $was
"
  fi
done <<EOF
$NOW
EOF

# A file in the baseline that no longer exists is debt that was paid by deleting
# or renaming it. Report it so the baseline can be trimmed, never fail on it.
GONE=""
if [ -f "$BASELINE" ]; then
  while read -r was f; do
    [ -z "$f" ] && continue
    [ -f "$ROOT/$f" ] || GONE="$GONE  $f — gone (was $was lines)
"
  done < "$BASELINE"
fi

if [ -n "$NEW_OVER" ]; then
  echo "LINE LIMIT — over $LIMIT and not accepted debt:"
  printf '%s' "$NEW_OVER"
  echo "  Split them. This repo teaches the rule; it does not get an exemption."
fi

if [ -n "$GREW" ]; then
  echo "LINE LIMIT — accepted debt that grew:"
  printf '%s' "$GREW"
  echo "  The baseline is a ceiling, not a licence. Take the addition elsewhere."
fi

if [ -n "$SHRANK" ] || [ -n "$GONE" ]; then
  echo "LINE LIMIT — debt paid down (not a failure):"
  [ -n "$SHRANK" ] && printf '%s' "$SHRANK"
  [ -n "$GONE" ] && printf '%s' "$GONE"
  echo "  Run: bash scripts/line-limit.sh --baseline   to bank it."
fi

if [ "$FAILED" = 0 ] && [ -z "$SHRANK" ] && [ -z "$GONE" ]; then
  over=$(wc -l < "$BASELINE" 2>/dev/null | tr -d ' ')
  echo "LINE LIMIT — ok. ${over:-0} file(s) of accepted debt, none grew."
fi

exit $FAILED
