#!/usr/bin/env bash
# Sourced by ship-gate.sh: which changed files a Stryker run can skip, and what its output says.

TEST_RE='(\.|_)(test|spec)\.[^.]+$|(^|/)tests?/'

stryker_owner() {  # stryker_owner <owner> <owned files>
  b=""; [ "$1" != "." ] && b="$1/"
  [ -z "$GAUNTLET_MUTATE" ] && ! grep -q '\.py$' <<< "$2" \
    && grep -qs '@stryker-mutator/core' "${b}package.json"
}

changed_tests() {  # changed_tests <family>
  printf '%s\n' "$CHANGED" | grep -E "$TEST_RE" | while IFS= read -r t; do
    [ -n "$t" ] && [ "$(family_of "$t")" = "$1" ] && printf '%s\n' "$t"
  done
}

# Everything a file's verdict rests on besides the file itself and the tests.
# Tests are left out: adding to them can only kill more, so only a lost line counts.
files_context() {  # files_context <owner> <owned files>
  fam=$(family_of "$1/.")
  { printf '%s\n' "$PROJECT_DIR" "$1" "$(git rev-parse "$BASE" 2>/dev/null)"
    cat "$HERE/ship-gate.sh" "$HERE/ship-gate-projects.sh" "$HERE/ship-gate-files.sh"
    printf '%s\n' "$CHANGED" | grep -vE '\.(md|mdx|txt|rst|adoc)$' | grep -vE "$TEST_RE" \
      | grep -vxF -f <(printf '%s\n' "$2") | while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$(family_of "$f")" in "$fam"|any) printf '%s\n' "$f"; [ -f "$f" ] && cat "$f" ;; esac
    done; } | git hash-object --stdin
}

file_receipt() {  # file_receipt <context> <file>
  printf '/tmp/claude-shipgate-file-%s\n' "$({ printf '%s\n' "$1" "$2"; cat "$2"; } | git hash-object --stdin)"
}

test_then() {  # test_then <snapshot> <test>: its content when the snapshot was taken
  if grep -qxF "$2" "$1/manifest"; then cat "$1/files/$2" 2>/dev/null
  else git show "$BASE:$2" 2>/dev/null; fi
}

# Never `| grep -q` under pipefail: diff exits 1 on any difference, and an early
# grep exit fails the writer, so a match reads as none.
tests_lost_lines() {  # tests_lost_lines <snapshot> <family>
  [ -f "$1/manifest" ] || return 0
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    case "$(diff <(test_then "$1" "$t") <(cat "$t" 2>/dev/null))" in *$'\n<'*) return 0 ;; esac
  done <<< "$({ cat "$1/manifest"; changed_tests "$2"; } | sort -u)"
  return 1
}

# Sets OWNED to the files that still need mutating.
files_split() {  # files_split <context> <owner> <label>
  fam=$(family_of "$2/."); kept=""; rest=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    r=$(file_receipt "$1" "$f")
    if [ -f "$r" ] && ! tests_lost_lines "$(cat "$r")" "$fam"; then kept="$kept ${f#"$2"/}"
    else rest="$rest$f"$'\n'; fi
  done <<< "$OWNED"
  OWNED=${rest%$'\n'}
  [ -n "$kept" ] || return 0
  echo "  $3 stryker — ok, not re-run: passed and unchanged since:$kept"
  echo "      A change in a file they call is not re-checked."
  b=""; [ "$2" != "." ] && b="$2/"
  [ -z "$OWNED" ] && stryker_page_tests "$b" "$3"
  return 0
}

# A finding with no location cannot be pinned on one file, so it keeps none.
files_record() {  # files_record <context> <owner> <findings>
  [ -n "$(printf '%s\n' "$3" | grep . | grep -vE ':[0-9]+:[0-9]+$')" ] && return 0
  fam=$(family_of "$2/.")
  snap="/tmp/claude-shipgate-tests-$({ printf '%s\n' "$1"; changed_tests "$fam" \
    | while IFS= read -r t; do printf '%s\n' "$t"; cat "$t" 2>/dev/null; done; } | git hash-object --stdin)"
  mkdir -p "$snap/files"; changed_tests "$fam" > "$snap/manifest"
  while IFS= read -r t; do
    [ -f "$t" ] && mkdir -p "$snap/files/$(dirname "$t")" && cp "$t" "$snap/files/$t"
  done < "$snap/manifest"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -qF "  ${f#"$2"/}:" <<< "$3" && continue
    printf '%s\n' "$snap" > "$(file_receipt "$1" "$f")"
  done <<< "$OWNED"
}

# Match a finding, never a summary row. Stryker prints a `# survived` COLUMN
# HEADER every run and repeats the word in its table, so a bare grep reports
# survivors on a clean run — worse than not running at all. Stryker marks each
# real finding `[Survived]`; table and border lines are excluded outright.
# NoCoverage is printed exactly like Survived and means something worse: not
# "a test missed this mutation" but "no test executes this line at all". The
# gate matched only [Survived], so a diff whose files have no tests came back
# PASS — 306 uncovered mutants reported as proven on one commit. It is judged
# only for files that went in WITH a range: a glob-shaped path is mutated
# whole, so its untouched lines would report uncovered forever, and a finding
# nobody can close is what teaches people to --force.
#
# The status line carries no file name; the line under it does, as
# file:line:column. They are paired here rather than grepped separately.
stryker_findings() {  # stryker_findings <output> <globbed paths, comma-wrapped>
  printf '%s\n' "$1" | awk -v globbed="$2" '
    /^\[Survived\]/   { pend = $0; kind = "s"; next }
    /^\[NoCoverage\]/ { pend = $0; kind = "n"; next }
    pend != "" {
      file = $0; sub(/:[0-9]+:[0-9]+$/, "", file)
      if (kind == "s" || index(globbed, "," file ",") == 0) print pend "  " $0
      pend = ""
    }
    # A survivor with no location under it is still a survivor, never dropped.
    END { if (pend != "" && kind == "s") print pend }
  '
}
