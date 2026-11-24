#!/usr/bin/env bash

STRUCTURE_KIND_FILE='(^|[._])(router|routes|controller|service|schema|model)s?\.[cm]?[jt]s$|(Router|Routes|Controller|Service|Schema|Model)s?\.[cm]?[jt]s$'

# --no-renames: a move must show up as an add, or renaming a misplaced file would slip through.
added_files() {
  { git diff --no-renames --diff-filter=A --name-only "$BASE"...HEAD 2>/dev/null
    git diff --no-renames --diff-filter=A --name-only HEAD 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null; } | sort -u
}

has_subject() {  # has_subject <test path>: a file the test is named for, beside it or above its __tests__/
  d=$(dirname "$1")
  [ "${d##*/}" = __tests__ ] && d=$(dirname "$d")
  stem=$(basename "$1" | sed -E 's/\.(test|spec)\.[^.]+$//')
  while :; do
    for e in ts tsx js jsx mjs cjs astro; do [ -f "$d/$stem.$e" ] && return 0; done
    case "$stem" in *.*) stem=${stem%.*} ;; *) return 1 ;; esac
  done
}

feature_misplaced() {  # feature_misplaced <path below features/<name>/>
  case "$1" in
    index.*) ;;
    */*) printf '%s' "${1%%/*}" | grep -qxE "$GAUNTLET_KIND_FOLDERS" \
           || echo "${1%%/*}/ is not a kind folder ($GAUNTLET_KIND_FOLDERS)" ;;
    *) echo "loose at the feature root, where only index.* belongs" ;;
  esac
}

js_misplaced() {  # js_misplaced <path> <owner>
  f=$1; b=${f##*/}; parent=$(basename "$(dirname "$f")")
  if printf '%s' "$b" | grep -qE '\.(test|spec)\.[^.]+$'; then
    printf '%s' "/$f" | grep -qE '/(e2e|tests?)/' && return
    has_subject "$f" || echo "a test sits beside the file it tests, and nothing here is named ${b%%.*}"
    return
  fi
  rest=$(printf '%s' "/$f" | sed -nE 's#.*/features/[^/]+/##p')
  if [ -n "$rest" ]; then feature_misplaced "$rest"; return; fi
  kinds="components|hooks|queries|api|schemas|types|utils"
  grep -qs '"express"' "$2/package.json" && kinds="$kinds|routes|controllers|services|middleware|models"
  if printf '%s' "/$f" | grep -qE "/src/($kinds)/"; then
    echo "sorted by kind first; it belongs in <domain>/<kind>/ or shared/<kind>/"
  elif printf '%s' "$b" | grep -qE '^use[A-Z].*\.[jt]sx?$' && ! printf '%s' "/$f" | grep -qE '/(hooks|queries)/'; then
    echo "a hook belongs in hooks/ or queries/"
  # Stimulus loads *_controller.js under controllers/ at any depth; Drizzle's default schema is db/schema.ts.
  elif printf '%s' "$b" | grep -qE "$STRUCTURE_KIND_FILE" \
       && ! printf '%s' "$parent" | grep -qxE 'routes|controllers|services|schemas|models|api|queries|types' \
       && ! printf '%s' "/$f" | grep -qE '/controllers/(.+/)?[^/]+_controller\.[jt]s$|/db/schema\.[jt]s$'; then
    echo "the kind is in the filename; it belongs in a kind folder"
  fi
}

py_misplaced() {  # py_misplaced <path>
  f=$1; b=${f##*/}; d=$(dirname "$f"); parent=${d##*/}
  case "$b" in
    test_*.py|*_test.py|conftest.py)
      printf '%s' "/$f" | grep -qE '/tests/' || echo "tests live under tests/, mirroring the app"
      return ;;
  esac
  k=$(printf '%s' "$b" | sed -nE 's/^(.*_)?(router|service|schema|model)s?\.py$/\2/p')
  if [ -n "$k" ] && [ "$parent" != "${k}s" ]; then
    echo "the kind is in the filename; it belongs in ${k}s/"
  elif printf '%s' "$parent" | grep -qxE 'routers|services|schemas|models' && [ -f "$(dirname "$d")/main.py" ]; then
    echo "sorted by kind first; it belongs in <domain>/$parent/"
  fi
}

LAYOUT_CODE='\.([cm]?[jt]sx?|astro|py)$'

# A file's place is the first folder below its project, two under src/, so a new feature folder is no new place.
layout_place() {  # stdin: paths; $LAYOUT_MANIFESTS: every project manifest, one per line
  awk 'BEGIN { n = split(ENVIRON["LAYOUT_MANIFESTS"], m, "\n"); for (j = 1; j <= n; j++) { sub(/\/?[^\/]*$/, "", m[j]); o[m[j]] = 1 } }
  { n = split($0, p, "/"); own = 0; pre = ""
    for (i = 1; i < n; i++) { pre = pre (i > 1 ? "/" : "") p[i]; if (pre in o) own = i }
    depth = own + 1 + (p[own + 1] == "src")
    k = ""; for (i = 1; i <= depth && i < n; i++) k = k (i > 1 ? "/" : "") p[i]
    print (k == "" ? "." : k) }'
}

# The trunk is the baseline: code may go where the trunk already has code, or where GAUNTLET_LAYOUT allows.
layout_known() {
  git rev-parse -q --verify "$BASE^{commit}" >/dev/null || { echo "*"; return; }
  git ls-tree -r --name-only "$BASE" | grep -E "$LAYOUT_CODE" | layout_place | sort -u
}

stray() {  # stray <path>: why a new code file sits where no code was, or nothing
  printf '%s' "$1" | grep -qE "$LAYOUT_CODE" || return 0
  [ "$KNOWN" = "*" ] && return 0
  matches_any "$1" "$GAUNTLET_LAYOUT" && return 0
  place=$(printf '%s\n' "$1" | layout_place)
  printf '%s\n' "$KNOWN" | grep -qxF "$place" && return 0
  echo "a new place for code ($place/); move it, or add it to GAUNTLET_LAYOUT in .claude/gauntlet.conf"
}

# Only ADDED files are judged, so a repo laid out the old way cannot get worse and need not move.
structure_check() {
  bad=""; count=0
  LAYOUT_MANIFESTS=$({ git ls-files; added_files; } | grep -E '(^|/)(package\.json|pyproject\.toml|pytest\.ini|setup\.cfg)$')
  export LAYOUT_MANIFESTS
  KNOWN=$(layout_known)
  while IFS= read -r f; do
    [ -f "$f" ] && ! is_ignored "$f" || continue
    printf '%s' "/$f" | grep -qE '/(node_modules|\.stryker-tmp|mutants)/' && continue
    o=$(owner_of "$f")
    why=$(stray "$f")
    if [ -n "$why" ]; then count=$((count+1)); bad="$bad  $f — $why
"; continue; fi
    case "$f" in
      *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.astro) why=$(js_misplaced "$f" "$o") ;;
      *.py) grep -qis fastapi "$o/pyproject.toml" || continue; why=$(py_misplaced "$f") ;;
      *) continue ;;
    esac
    count=$((count+1))
    [ -n "$why" ] && bad="$bad  $f — $why
"
  done <<< "$(added_files)"
  echo
  if [ -n "$bad" ]; then
    echo "STRUCTURE — new files outside their kind folder:"
    printf '%s' "$bad"
    echo "  Move them (Project Structure in the react, fastapi or express skill), or ship with --force."
    echo
    return 1
  fi
  echo "STRUCTURE — ok, $count new file(s) in their kind folder"
  echo
}

# Called when nothing else in the diff is gated, so the gate would otherwise pass it.
structure_fail() {
  echo "ship-gate: FAIL in ${SECONDS}s — deal with the findings above, then run this again."
  echo "           To ship anyway: bash .claude/hooks/ship-gate.sh --force"
  rm -f "$RECEIPT"
  exit 1
}

# An agent that pipes the gate through `tail` cuts the findings off; the last line still says where they are.
gate_report() {
  REPORT="/tmp/claude-shipgate-$1.log"
  exec 3>&1 4>&2 > >(tee "$REPORT") 2>&1
  TEE_PID=${!:-}  # bash before 4.4 does not set $! for process substitution
  trap 'gate_exit $?' EXIT
}

# A FAIL goes to the diary /add-rule reads, so a test gap the gate keeps finding can become a rule.
gate_exit() {
  echo "ship-gate: full output in $REPORT"
  [ "$1" = 1 ] || [ "$GAUNTLET_SHIP_LOG" = 1 ] || return 0
  exec 1>&3 2>&4
  # A child left running (a dev server) can hold tee open forever; give it 2s, not a hang.
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -n "$TEE_PID" ] && kill -0 "$TEE_PID" 2>/dev/null || break; sleep 0.2; done
  [ "$1" = 1 ] && gate_diary
  ship_log "$REPORT" "$1"
  return 0
}

gate_diary() {
  local diary; diary=$(diary_dir "$HERE")
  mkdir -p "$diary"
  printf '{"ts":"%s","branch":"%s","status":"FAIL","report":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(git branch --show-current 2>/dev/null | json_string)" "$(json_string < "$REPORT")" \
    >> "$diary/gate-findings.jsonl"
}

# Every run goes to the /deliver log when it is on; a broken log never changes the verdict.
ship_log() {  # ship_log <report> <exit code>
  [ "$GAUNTLET_SHIP_LOG" = 1 ] && command -v node >/dev/null || return 0
  SHIP_LOG_TEST_RE="$TEST_RE" SHIP_LOG_SOURCE_EXT="$GAUNTLET_SOURCE_EXT" node "$HERE/ship-log.mjs" gate "$1" "$2" "$SECONDS" "$BASE" >/dev/null 2>&1 || true
}

gate_force() {
  printf 'FORCED %s\n' "$(date -u +%FT%TZ)" > "$RECEIPT"
  echo "ship-gate: FORCED — receipt written without running any check."
  local r; r=$(mktemp); echo "ship-gate: FORCED" > "$r"
  ship_log "$r" 0; rm -f "$r"
  exit 0
}

# Nothing to mutate, but a Stryker trial run may still have been unable to start.
no_code_exit() {
  echo "ship-gate: no changed code files — nothing to check"
  if [ "$STATUS" = 2 ]; then
    printf 'ship-gate: UNPROVEN in %ss — nothing is wrong, but nothing was proven either\n' "$SECONDS"
    printf 'UNPROVEN %s setup-trial\n' "$(date -u +%FT%TZ)" > "$RECEIPT"; exit 2
  fi
  printf 'PASS %s no-code-changes\n' "$(date -u +%FT%TZ)" > "$RECEIPT"
  exit 0
}
