#!/usr/bin/env bash

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/gate-config.sh" || exit 1
ROOT="$(cd "${LINE_LIMIT_ROOT:-$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || echo "$HERE/..")}" && pwd -P)"
load_gauntlet_conf "$ROOT/.claude/gauntlet.conf" "$HERE/../gauntlet.conf"
LIMIT=$GAUNTLET_MAX_LINES
BASELINE="$ROOT/.line-limit-baseline"
SELF="${HERE#"$ROOT"/}/line-limit.sh"
if ! [ "$LIMIT" -gt 0 ] 2>/dev/null; then
  [ "${1:-}" = "--file" ] || echo "LINE LIMIT — off (GAUNTLET_MAX_LINES=$LIMIT)"
  exit 0
fi

is_code() {
  local ext="\\.($GAUNTLET_SOURCE_EXT|sh)$" skip="(^|/)node_modules/|^\\.claude/"
  [[ $1 =~ $ext ]] && ! [[ $1 =~ $skip ]] && ! is_ignored "$1"
}

# Paths are kept relative to ROOT so the baseline is portable between clones.
files() {
  { git -C "$ROOT" ls-files --cached --others --exclude-standard 2>/dev/null \
    || (cd "$ROOT" && find . -type f -not -path './.git/*' | sed 's|^\./||'); } \
    | while IFS= read -r f; do is_code "$f" && [ -f "$ROOT/$f" ] && printf '%s/%s\n' "$ROOT" "$f"; done | sort
}

counts() {
  while IFS= read -r f; do
    printf '%s %s\n' "$(wc -l < "$f" | tr -d ' ')" "${f#"$ROOT"/}"
  done
}

ONE=""
if [ "${1:-}" = "--file" ]; then
  ONE="$(cd "$(dirname -- "${2:-.}")" 2>/dev/null && pwd -P)/$(basename -- "${2:-.}")"
  REL="${ONE#"$ROOT"/}"
  [ "$REL" != "$ONE" ] && [ -f "$ONE" ] && is_code "$REL" || exit 0
  git -C "$ROOT" check-ignore -q -- "$REL" 2>/dev/null && exit 0
  NOW=$(printf '%s\n' "$ONE" | counts)
else
  NOW=$(files | counts)
fi

# On an existing baseline this only banks: an entry may drop or go, never appear or grow.
if [ "${1:-}" = "--baseline" ]; then
  if [ -f "$BASELINE" ]; then
    printf '%s\n' "$NOW" | awk -v lim="$LIMIT" '{ n = $1; p = $0; sub(/^[^ ]+ /, "", p) }
      NR == FNR { was[p] = n; next } (p in was) && n > lim { print (n < was[p] ? n : was[p]), p }' "$BASELINE" - > "$BASELINE.tmp" \
      && mv "$BASELINE.tmp" "$BASELINE"
  else
    printf '%s\n' "$NOW" | awk -v lim="$LIMIT" '$1 > lim' > "$BASELINE"
  fi
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
  was=$(awk -v p="$f" '{ n = $1; sub(/^[^ ]+ /, "") } $0 == p { print n }' "$BASELINE" 2>/dev/null)
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
  elif [ -n "$ONE" ]; then
    echo "LINE LIMIT — $f is $n lines, over $LIMIT (old debt). Split it if this change allows."
  fi
done <<EOF
$NOW
EOF

# A file in the baseline that no longer exists is debt that was paid by deleting
# or renaming it. Report it so the baseline can be trimmed, never fail on it.
GONE=""
if [ -z "$ONE" ] && [ -f "$BASELINE" ]; then
  while read -r was f; do
    [ -z "$f" ] && continue
    [ -f "$ROOT/$f" ] || GONE="$GONE  $f — gone (was $was lines)
"
  done < "$BASELINE"
fi

if [ -n "$NEW_OVER" ]; then
  echo "LINE LIMIT — over $LIMIT and not accepted debt:"
  printf '%s' "$NEW_OVER"
  echo "  Split them."
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
  echo "  Run: bash $SELF --baseline   to bank it."
fi

if [ "$FAILED" = 0 ] && [ -z "$SHRANK" ] && [ -z "$GONE" ] && [ -z "$ONE" ]; then
  over=$(wc -l < "$BASELINE" 2>/dev/null | tr -d ' ')
  echo "LINE LIMIT — ok. ${over:-0} file(s) of accepted debt, none grew."
fi

exit $FAILED
