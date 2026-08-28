#!/usr/bin/env bash
# ship-gate.sh — the deterministic half of /ship's quality gate.
#
# File length and mutation are not judgement calls, so they do not live in prose
# where a model can decide they are not worth it. They live here, behind an exit
# code. /ship runs this and obeys the result; the skills audit stays in the
# command, because that one genuinely needs a model.
#
#   bash .claude/hooks/ship-gate.sh [base-ref]
#   bash .claude/hooks/ship-gate.sh --key      print the receipt key and stop
#   bash .claude/hooks/ship-gate.sh --force    write a FORCED receipt, run nothing
#
# On completion it writes a RECEIPT at /tmp/claude-shipgate-<key>, and the
# PreToolUse hook refuses `git commit` / `git push` without a matching one. The
# point is that a gate has to be evidence rather than an instruction: a sentence
# saying "run this first" is a sentence an agent can decide is not worth it, and
# then report a pass it never earned. A receipt cannot be reported, only produced.
#
# The key is the content of everything about to ship, so it is the same before
# and after `git commit` — and it changes the moment anything is edited, which is
# what makes a fix re-gate itself instead of riding on the previous verdict.
#
# Exit codes:
#   0  clean — nothing over the line limit, no surviving mutants
#   1  findings that must be dealt with before shipping
#   2  ran, but could not prove the tests (a mutation tool is missing) — report,
#      don't block; the output names exactly what to install and where
#
# Config: the same .claude/gauntlet.conf as the Stop hook.
#   GAUNTLET_MAX_LINES=200   the per-file limit; 0 turns the check off
#   GAUNTLET_SOURCE_EXT=...  which extensions count as source. Deliberately NOT
#                            GAUNTLET_CODE_EXT: the Stop hook's key answers a
#                            different question, and a docs repo sets it to .md
#   GAUNTLET_MUTATE="cmd"    one explicit mutation command for the whole repo,
#                            replacing per-project detection. $MUTATE_FLAGS holds
#                            the --mutate flags, $FILES the changed files.

set -uo pipefail

MODE=""
case "${1:-}" in --key) MODE=key; shift ;; --force) MODE=force; shift ;; esac

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
cd "$PROJECT_DIR" 2>/dev/null || { echo "ship-gate: cannot read $PROJECT_DIR"; exit 1; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "ship-gate: not a git repo"; exit 1; }

GAUNTLET_MAX_LINES=200
GAUNTLET_MUTATE=""
GAUNTLET_SOURCE_EXT="ts|tsx|js|jsx|mjs|cjs|py|go|rs|java|kt|rb|php|c|h|cpp|hpp|cs|swift"
[ -n "${HOME:-}" ] && [ -f "$HOME/.claude/gauntlet.conf" ] && . "$HOME/.claude/gauntlet.conf"
[ -f ".claude/gauntlet.conf" ] && . ".claude/gauntlet.conf"

# ------------------------------------------------------------------- the scope
BASE="${1:-}"
if [ -z "$BASE" ]; then
  BASE=$(git merge-base HEAD develop 2>/dev/null \
         || git merge-base HEAD main 2>/dev/null \
         || git rev-list --max-parents=0 HEAD | head -1)
fi

CHANGED=$( { git diff "$BASE"...HEAD --name-only 2>/dev/null
             git diff HEAD --name-only 2>/dev/null
             git ls-files --others --exclude-standard 2>/dev/null; } | sort -u )

# The repo path plus the names and contents of the changed files, in a fixed
# order. The path is in there because the key is otherwise pure content: two
# repos holding the same file would share a receipt, and one would be waved
# through on the other's verdict. Deliberately not a diff: a file moves from "untracked" to "in the diff" at commit time, so a
# diff-based key changes when the content did not, and the receipt would go stale
# the moment it was committed. This is identical either side of a commit, and
# changes the instant any of those files is edited.
RECEIPT_KEY=$( { printf '%s\n' "$PROJECT_DIR"
                 printf '%s\n' "$CHANGED" | while IFS= read -r f; do
                   [ -n "$f" ] || continue
                   printf '%s\n' "$f"
                   [ -f "$f" ] && cat "$f"
                 done; } | git hash-object --stdin )
RECEIPT="/tmp/claude-shipgate-$RECEIPT_KEY"

if [ "$MODE" = key ]; then printf '%s\n' "$RECEIPT_KEY"; exit 0; fi
if [ "$MODE" = force ]; then
  printf 'FORCED %s\n' "$(date -u +%FT%TZ)" > "$RECEIPT"
  echo "ship-gate: FORCED — receipt written without running any check."
  exit 0
fi
FILES=$(printf '%s\n' "$CHANGED" | grep -E "\.($GAUNTLET_SOURCE_EXT)$" \
        | grep -vE '(\.|_)(test|spec)\.[^.]+$|(^|/)tests?/|(^|/)\.stryker-tmp/' | while read -r f; do
          [ -f "$f" ] && printf '%s\n' "$f"
        done)

if [ -z "$FILES" ]; then
  echo "ship-gate: no changed code files — nothing to check"
  printf 'PASS %s no-code-changes\n' "$(date -u +%FT%TZ)" > "$RECEIPT"
  exit 0
fi

echo "ship-gate: $(printf '%s\n' "$FILES" | wc -l) changed code file(s), base $(git rev-parse --short "$BASE")"
echo
STATUS=0

# ------------------------------------------------- check 1: file length (hard)
OVER=""
LARGEST=0
if [ "$GAUNTLET_MAX_LINES" -gt 0 ]; then
  while IFS= read -r f; do
    n=$(wc -l < "$f")
    [ "$n" -gt "$LARGEST" ] && LARGEST=$n
    [ "$n" -gt "$GAUNTLET_MAX_LINES" ] && OVER="$OVER  $f — $n lines (limit $GAUNTLET_MAX_LINES)
"
  done <<< "$FILES"
fi

if [ "$GAUNTLET_MAX_LINES" -le 0 ]; then
  echo "FILE LENGTH — off (GAUNTLET_MAX_LINES=0)"
elif [ -n "$OVER" ]; then
  echo "FILE LENGTH — over the limit:"
  printf '%s' "$OVER"
  echo "  Splitting a file is a design decision. Do it deliberately, or ship with --force."
  STATUS=1
else
  echo "FILE LENGTH — ok, largest is $LARGEST lines"
fi

# ---------------------------------------------------------- which project owns
# A monorepo holds several projects, each with its own runner and its own
# mutation tool. Walk up from each changed file to the nearest manifest.
owner_of() {
  d=$(dirname "$1")
  while :; do
    if [ -f "$d/package.json" ] || [ -f "$d/pyproject.toml" ] \
       || [ -f "$d/pytest.ini" ] || [ -f "$d/setup.cfg" ]; then
      printf '%s\n' "${d#./}"; return
    fi
    [ "$d" = "." ] || [ "$d" = "/" ] && { printf '.\n'; return; }
    d=$(dirname "$d")
  done
}

OWNERS=$(while IFS= read -r f; do owner_of "$f"; done <<< "$FILES" | sort -u)

# --------------------------------------------- check 2: mutation, per project
echo
echo "MUTATION — $(printf '%s\n' "$OWNERS" | wc -l) project(s) in this diff"
MISSING=""

for owner in $OWNERS; do
  [ "$owner" = "." ] && label="<repo root>" || label="$owner/"
  OWNED=$(while IFS= read -r f; do
            [ "$(owner_of "$f")" = "$owner" ] && printf '%s\n' "$f"
          done <<< "$FILES")
  [ -z "$OWNED" ] && continue

  # --mutate flags, one per changed hunk. Ranges inside a file are already
  # comma-separated, so they cannot share a comma-joined list across files.
  FLAGS=""
  while IFS= read -r f; do
    hunks=$(git diff -U0 "$BASE" -- "$f" 2>/dev/null \
            | grep -oE '^@@ -[0-9,]+ \+[0-9]+(,[0-9]+)?' | sed 's/.*+//' \
            | while IFS=, read -r s l; do l=${l:-1}; [ "$l" -gt 0 ] && echo "$s-$((s+l-1))"; done)
    [ -z "$hunks" ] && hunks="1-$(wc -l < "$f")"
    rel=${f#$owner/}
    for r in $hunks; do FLAGS="$FLAGS --mutate '$rel:$r'"; done
  done <<< "$OWNED"

  base=""; RUN=""
  if [ "$owner" != "." ]; then base="$owner/"; RUN="cd '$owner' && "; fi
  if [ -n "$GAUNTLET_MUTATE" ]; then
    CMD="$GAUNTLET_MUTATE"; TOOL="config"
  elif [ -f "$base"package.json ] && grep -qs '@stryker-mutator/core' "$base"package.json; then
    TOOL="stryker"
    # From inside the owning package: npx resolves against ITS node_modules, and
    # stryker.config.json lives there too. A monorepo root usually has neither.
    CMD="${RUN}npx --no-install stryker run --incremental --force $FLAGS"
  elif [ -f "$base"package.json ]; then
    MISSING="$MISSING  $label needs Stryker:
      npm --prefix ${owner} i -D @stryker-mutator/core @stryker-mutator/vitest-runner
      then ${base}stryker.config.json:
        {\"testRunner\":\"vitest\",\"plugins\":[\"@stryker-mutator/vitest-runner\"],\"coverageAnalysis\":\"perTest\"}
"
    continue
  elif command -v mutmut >/dev/null 2>&1; then
    TOOL="mutmut"
    # mutmut takes its scope from [tool.mutmut] in pyproject, not from a flag:
    # --paths-to-mutate was 2.x, and 3.x filters by fnmatch globs over mutant
    # NAMES (app.balance.reserve.*). There is no per-line scoping at all.
    CMD="${RUN}mutmut run"
  else
    MISSING="$MISSING  $label needs mutmut:
      pip install mutmut
      then ${base}pyproject.toml:
        [tool.mutmut]
        source_paths = [\"src/\"]
        pytest_add_cli_args_test_selection = [\"tests/\"]
      (mutmut 3 renamed these — paths_to_mutate/tests_dir are 2.x and are ignored)
"
    continue
  fi

  OUT=$(eval "$CMD" 2>&1); RC=$?
  # Match a finding, never a summary row. Stryker prints a `# survived` COLUMN
  # HEADER every run and repeats the word in its table, so a bare grep reports
  # survivors on a clean run — worse than not running at all. Stryker marks each
  # real finding `[Survived]`; table and border lines are excluded outright.
  case "$TOOL" in
    stryker) PATTERN='\[Survived\]' ;;
    *)       PATTERN='[Ss]urvived' ;;
  esac
  SURVIVED=$(printf '%s\n' "$OUT" | grep -E "$PATTERN" \
             | grep -vE '^[[:space:]]*[#│|+-]|# *surviv' | head -20)
  if [ -n "$SURVIVED" ]; then
    echo "  $label $TOOL — surviving mutants; these lines can break and no test notices:"
    printf '%s\n' "$SURVIVED" | sed 's/^/      /'
    STATUS=1
  elif [ $RC -ne 0 ]; then
    echo "  $label $TOOL — the run failed:"
    printf '%s\n' "$OUT" | tail -12 | sed 's/^/      /'
    [ "$STATUS" = 0 ] && STATUS=2
  else
    echo "  $label $TOOL — ok, no surviving mutants in the changed lines"
  fi
done

if [ -n "$MISSING" ]; then
  echo "  UNPROVEN — no mutation tool for these, so their tests were never shown"
  echo "  to catch a break. Install per project:"
  printf '%s' "$MISSING"
  [ "$STATUS" = 0 ] && STATUS=2
fi

# The receipt is written by this script and nothing else. A hand-rolled check
# produces no receipt, which is the whole point: substituting a weaker check is
# a choice that can be argued for, but it cannot be passed off as this one.
echo
case $STATUS in
  0) echo "ship-gate: PASS"
     printf 'PASS %s\n' "$(date -u +%FT%TZ)" > "$RECEIPT" ;;
  1) echo "ship-gate: FAIL — deal with the findings above, then run this again."
     echo "           To ship anyway: bash .claude/hooks/ship-gate.sh --force"
     rm -f "$RECEIPT" ;;
  2) echo "ship-gate: UNPROVEN — nothing is wrong, but nothing was proven either"
     printf 'UNPROVEN %s\n' "$(date -u +%FT%TZ)" > "$RECEIPT" ;;
esac
exit $STATUS
