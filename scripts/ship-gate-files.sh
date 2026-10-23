#!/usr/bin/env bash

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

# Everything a file's verdict rests on besides the file itself and the tests: the base, the gate,
# and the test setup. Other code is left out, so one fix no longer re-mutates every clean file.
files_context() {  # files_context <owner> <owned files>
  fam=$(family_of "$1/.")
  { printf '%s\n' "$PROJECT_DIR" "$1" "$(git rev-parse "$BASE" 2>/dev/null)"
    cat "$HERE/ship-gate.sh" "$HERE/ship-gate-projects.sh" "$HERE/ship-gate-files.sh" "$HERE/gate-config.sh" "$HERE/line-limit.sh"
    printf '%s\n' "$CHANGED" | grep -E "$SETUP_RE" | while IFS= read -r f; do
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
# PASS — 306 uncovered mutants reported as proven on one commit. A glob-shaped
# path is mutated whole, so only its changed lines are judged: the rest would
# report forever, and a finding nobody can close is what teaches people to --force.
#
# The status line carries no file name; the line under it does, as
# file:line:column. They are paired here rather than grepped separately.
stryker_findings() {  # stryker_findings <output> <",path:ranges," per globbed file>
  printf '%s\n' "$1" | awk -v globbed="$2" '
    function changed(rs, l,   parts, ab, i) {
      for (i = split(rs, parts, " "); i > 0; i--) { split(parts[i], ab, "-"); if (l >= ab[1] + 0 && l <= ab[2] + 0) return 1 }
      return 0
    }
    BEGIN { for (i = split(globbed, g, ","); i > 0; i--) if (g[i] != "") { k = g[i]; sub(/:[^:]*$/, "", k); r = g[i]; sub(/^.*:/, "", r); ranges[k] = r } }
    /^\[Survived\]/   { pend = $0; kind = "s"; next }
    /^\[NoCoverage\]/ { pend = $0; kind = "n"; next }
    pend != "" {
      file = $0; sub(/:[0-9]+:[0-9]+$/, "", file)
      line = $0; sub(/:[0-9]+$/, "", line); sub(/^.*:/, "", line)
      if (!(file in ranges) || changed(ranges[file], line + 0)) print pend "  " $0
      pend = ""
    }
    # A survivor with no location under it is still a survivor, never dropped.
    END { if (pend != "" && kind == "s") print pend }
  '
}

# A survivor needs a test run against it. Survivors with 0 tests per mutant and
# nothing killed mean the runner filtered every test out (stryker-js#6210, Vitest 5).
stryker_zero_tests() {  # stryker_zero_tests <output> <label> <seconds>
  grep -q '^\[Survived\]' <<< "$1" && grep -q 'Ran 0\.00 tests per mutant' <<< "$1" || return 1
  [ "$(awk -F'|' '/^ *All files/ { gsub(/ /, "", $4); print $4 }' <<< "$1")" = 0 ] || return 1
  echo "  $2 stryker (${3}s) — its survivors ran 0 tests, so they prove nothing and are dropped."
  echo "      On Vitest 5 this is stryker-js#6210: pin vitest@4 until a fixed runner ships."
}

# Read by header name, so a reordered column cannot shift the numbers.
stryker_counts() {  # stryker_counts <output> <label>
  printf '%s\n' "$1" | awk -F'|' -v label="$2" '
    /# killed/ { for (i = 1; i <= NF; i++) { h = $i; gsub(/^ +| +$/, "", h); col[h] = i } next }
    /^ *All files/ && col["# killed"] {
      for (k in col) { v = $col[k]; gsub(/ /, "", v); n[k] = v + 0 }
      t = n["# killed"] + n["# survived"] + n["# timeout"] + n["# no cov"] + n["# errors"]
      printf "  %s stryker — %d mutants: %d killed, %d survived, %d uncovered, %d timed out, %d errors\n",
        label, t, n["# killed"], n["# survived"], n["# no cov"], n["# timeout"], n["# errors"]
      exit
    }'
}

# Sets ALL from a Stryker run. Fails when a broken run leaves nothing provable.
stryker_judge() {  # uses OUT GLOBBED FCTX RC owner label T from ship-gate.sh
  echo "  $label stryker — mutated: $(while IFS= read -r f; do printf '%s ' "${f#"$owner"/}"; done <<< "$OWNED")"
  stryker_counts "$OUT" "$label"
  ALL=$(stryker_findings "$OUT" "$GLOBBED")
  if stryker_zero_tests "$OUT" "$label" "$T"; then
    ALL=$(grep -v '^\[Survived\]' <<< "$ALL"); [ -n "$ALL" ]; return
  fi
  [ -n "$FCTX" ] && [ "$RC" -eq 0 ] && files_record "$FCTX" "$owner" "$ALL"
  return 0
}

# Files that decide whether Stryker can run the suite at all; none of them is code it mutates.
SETUP_RE='(^|/)(stryker\.conf[^/]*|stryker\.config\.[^/]*|vitest\.(config|workspace)\.[^/]*|vite\.config\.[^/]*|jest\.config\.[^/]*|tsconfig[^/]*\.json|package(-lock)?\.json|pnpm-(lock|workspace)\.yaml|yarn\.lock|bun\.lockb?|\.npmrc)$|(^|/)patches/'

# A version bump touches package.json on every release and proves nothing about Stryker.
setup_files() {
  printf '%s\n' "$CHANGED" | grep -E "$SETUP_RE" | while IFS= read -r f; do
    [ -n "$({ git diff "$BASE" -- "$f"; git ls-files --error-unmatch -- "$f" >/dev/null 2>&1 || sed 's/^/+/' "$f"; } 2>/dev/null \
      | grep -E '^[-+]' | grep -vE '^(\+\+\+|---) ' | grep -v '"version"')" ] && printf '%s\n' "$f"
  done
}

# A PR can break Stryker (a dropped patch, a test config) with no code to mutate, so a trial
# runs the suite under it. A project with code to mutate skips it: its real run starts the same way.
setup_check() {
  [ -z "$GAUNTLET_MUTATE" ] || return 0
  local o b bin label key out rc t0 mutated
  mutated=$(printf '%s\n' "$FILES" | grep -vE "$GAUNTLET_NO_MUTATE" | while IFS= read -r f; do [ -n "$f" ] && owner_of "$f"; done)
  for o in $(setup_files | while IFS= read -r f; do owner_of "$f"; done | sort -u); do
    grep -qxF "$o" <<< "$mutated" && continue
    b=""; [ "$o" != . ] && b="$o/"; [ "$o" = . ] && label="<repo root>" || label="$o/"
    grep -qs '@stryker-mutator/core' "${b}package.json" || continue
    key="/tmp/claude-shipgate-project-$(project_key "$o" dryrun)"
    [ -f "$key" ] && { echo "  $label stryker setup — ok, not re-run: its trial run passed"; continue; }
    bin=$(stryker_bin "$b"); t0=$SECONDS; out=$(cd "${b:-.}" && $bin run --dryRunOnly --concurrency "$(gate_workers)" 2>&1); rc=$?
    if [ $rc -eq 0 ]; then echo "  $label stryker setup ($((SECONDS - t0))s) — ok, its trial run passed"; touch "$key"
    elif grep -qE 'initial test run|DryRunExecutor' <<< "$out"; then
      echo "  $label stryker setup ($((SECONDS - t0))s) — this change breaks Stryker's own test run:"
      printf '%s\n' "$out" | tail -12 | sed 's/^/      /'; STATUS=1
    else
      echo "  $label stryker setup ($((SECONDS - t0))s) — UNPROVEN, the trial run could not start:"
      printf '%s\n' "$out" | tail -6 | sed 's/^/      /'; stryker_elsewhere stryker "$b"; [ "$STATUS" = 0 ] && STATUS=2
    fi
  done
}
