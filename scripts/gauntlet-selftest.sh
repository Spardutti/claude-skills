#!/usr/bin/env bash
# gauntlet-selftest.sh — behavioural tests for scripts/gauntlet.sh.
#
# Every case builds a throwaway git repo, stubs the runners so nothing real is
# executed, runs the hook, and asserts on the outcome it recorded in its .why
# file. Run it before shipping any change to the hook:
#
#   bash scripts/gauntlet-selftest.sh
#
# Exits non-zero on the first failed assertion.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
G="$HERE/gauntlet.sh"
SG="$HERE/ship-gate.sh"
SGH="$HERE/ship-gate-hook.sh"
TMP=$(mktemp -d)
export HOME="$TMP/home"; mkdir -p "$HOME"
RUN="$$-$(date +%s 2>/dev/null || echo 0)"
LOG="$TMP/ran.log"
N=0
PASS=0
FAIL=0

newrepo() {
  R="$TMP/$1"; rm -rf "$R"; mkdir -p "$R/.claude" "$R/bin"; cd "$R" || exit 1
  git init -q .; git config user.email t@t.t; git config user.name t
  echo x > README.md; git add -A; git commit -qm init
  export CLAUDE_PROJECT_DIR="$R"
  case ":$PATH:" in *":$R/bin:"*) ;; *) export PATH="$R/bin:$PATH" ;; esac
}

# check <label> <expected substring in .why> [expected substring in the run log]
check() {
  N=$((N+1))
  rm -f "$LOG"
  echo "{\"session_id\":\"st$RUN-$N\"}" | "$G" >/dev/null 2>"$TMP/err"
  RC=$?
  got=$(cat "/tmp/claude-gauntlet-st$RUN-$N.why" 2>/dev/null)
  ok=1
  case "$got" in *"$2"*) ;; *) ok=0 ;; esac
  if [ -n "${3:-}" ]; then
    ran=$(cat "$LOG" 2>/dev/null)
    case "$ran" in *"$3"*) ;; *) ok=0 ;; esac
  fi
  if [ $ok = 1 ]; then
    PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL+1))
    printf '  FAIL %s\n       want why ~ %s\n       got  why = %s\n' "$1" "$2" "$got"
    [ -n "${3:-}" ] && printf '       want ran ~ %s\n       got  ran = %s\n' "$3" "$(cat "$LOG" 2>/dev/null)"
  fi
}

stub() { printf '#!/bin/sh\necho "%s" >> %s\n' "$2" "$LOG" > "bin/$1"; chmod +x "bin/$1"; }

echo "skip ladder"
newrepo r1
check "no changed files"        "no changed files"
echo hi >> README.md
check "docs only"               "docs/config only"
echo "const a=1" > a.ts
check "no gates detected"       "no gates detected"
printf "GAUNTLET_TYPECHECK=''\nGAUNTLET_TEST='echo ok'\n" > .claude/gauntlet.conf
check "green"                   "green: gates passed"
echo "// touch" >> a.ts
printf "GAUNTLET_TYPECHECK=''\nGAUNTLET_TEST='echo \"No test files found\"'\n" > .claude/gauntlet.conf
check "runner matched 0 tests"  "matched 0 test files"
echo "// touch2" >> a.ts
printf "GAUNTLET_TYPECHECK=''\nGAUNTLET_TEST='echo boom; exit 1'\n" > .claude/gauntlet.conf
check "red"                     "red: the tests gate failed"
# A red must exit 2 — that is the only exit code that both keeps the turn going
# and shows the user why. Exit 0 would let the turn end silently.
N_RED=$N
if [ "$RC" = 2 ]; then
  PASS=$((PASS+1)); echo "  ok   red exits 2 (visible to the user)"
else
  FAIL=$((FAIL+1)); echo "  FAIL red exits 2 — got exit $RC"
fi
N=$((N+1))
if grep -q "GAUNTLET FAILED" "$TMP/err" 2>/dev/null; then
  PASS=$((PASS+1)); echo "  ok   red writes the reason to stderr"
else
  FAIL=$((FAIL+1)); echo "  FAIL red writes the reason to stderr — got: $(cat "$TMP/err" 2>/dev/null)"
fi
N=$((N+1))
echo "GAUNTLET_OFF=1" >> .claude/gauntlet.conf
check "GAUNTLET_OFF"            "GAUNTLET_OFF is set"

echo "a missing tool is a skip, not a red"
newrepo r2
echo '{"devDependencies":{"vitest":"^4"}}' > package.json
echo "const a=1" > a.ts
check "vitest not installed"    "tool is not installed"
newrepo r3
printf '[project]\nname="x"\n' > pyproject.toml
echo "x=1" > a.py
check "pytest not installed"    "tool is not installed"

echo "a delegating monorepo root uses its own scripts"
newrepo r4
mkdir -p web
echo '{"scripts":{"test":"npm --prefix web run test","typecheck":"npm --prefix web run typecheck"}}' > package.json
echo '{"scripts":{"test":"vitest run"},"devDependencies":{"vitest":"^4"}}' > web/package.json
stub npm "npm-ran"
mkdir -p web/src; echo "export const a=1" > web/src/a.ts
check "root scripts win"        "green: gates passed" "npm-ran"

echo "more than one stack in one repo"
newrepo r5
echo '{"scripts":{"typecheck":"x"},"devDependencies":{"vitest":"^4"}}' > package.json
printf '[tool.mypy]\nstrict=true\n' > pyproject.toml
stub npm "js-typecheck"; stub npx "js-test"
printf '#!/bin/sh\ncase "$*" in *mypy*) echo py-typecheck >> %s;; *pytest*) echo py-test >> %s;; esac\n' "$LOG" "$LOG" > bin/python
chmod +x bin/python
echo "const a=1" > a.ts
check "js change runs js gates" "green: gates passed" "js-test"
rm a.ts; echo "x=1" > b.py
check "py change runs py gates" "green: gates passed" "py-test"

echo "a nested project with nothing at the root"
newrepo r6
mkdir -p web/src api
echo '{"scripts":{"typecheck":"tsc -b"},"devDependencies":{"vitest":"^4"}}' > web/package.json
printf '[project]\nname="api"\n' > api/pyproject.toml
stub npm "web-typecheck"; stub npx "web-test"
printf '#!/bin/sh\necho api-test >> %s\n' "$LOG" > bin/python; chmod +x bin/python
echo "export const a=1" > web/src/a.ts
check "web change runs web gates" "green: gates passed" "web-test"
rm web/src/a.ts; echo "x=1" > api/a.py
check "api change runs api gates" "green: gates passed" "api-test"

echo "a path containing a space stays one argument"
newrepo r7
echo '{"devDependencies":{"vitest":"^4"}}' > package.json
printf '#!/bin/sh\nfor a in "$@"; do echo "arg[$a]" >> %s; done\n' "$LOG" > bin/npx; chmod +x bin/npx
mkdir -p "src/my folder"; echo "const a=1" > "src/my folder/a.ts"
check "spaced path"             "green: gates passed" "arg[$TMP/r7/src/my folder/a.ts]"

# --------------------------------------------------------------- ship-gate.sh
sg() {  # sg <label> <expected substring in output> [expected exit code]
  N=$((N+1))
  out=$(bash "$SG" 2>&1); rc=$?
  ok=1
  case "$out" in *"$2"*) ;; *) ok=0 ;; esac
  [ -n "${3:-}" ] && [ "$rc" != "$3" ] && ok=0
  if [ $ok = 1 ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n       want ~ %s (exit ${3:-any})\n       got exit %s:\n%s\n' "$1" "$2" "$rc" "$out"
  fi
}

echo "ship-gate"
newrepo sg1
echo "const a=1" > a.ts

# Stryker prints a `# survived` column header on EVERY run, including a clean
# one. Grepping for the bare word reported findings when there were none.
cat > .claude/gauntlet.conf <<'C'
GAUNTLET_MUTATE='printf "%s\n" "File | % score | # killed | # survived |" "All files | 100.00 | 12 | 0 |"'
C
sg "a clean run's summary header is not a finding" "nothing survived" 0

cat > .claude/gauntlet.conf <<'C'
GAUNTLET_MUTATE='printf "%s\n" "File | # survived |" "[Survived] StringLiteral" "src/a.ts:12:9"'
C
sg "a real [Survived] line is a finding" "[Survived] StringLiteral" 1

rm -f .claude/gauntlet.conf
echo "x" > a.test.ts; mkdir -p tests; echo "z" > tests/t.ts
sg "test files are never mutated" "1 changed code file"

seq 1 250 | sed 's/^/const x/' > big.ts
sg "a file over the limit stops the ship" "over the limit" 1

# The gate reported "I recognised nothing" and "there is nothing" identically,
# both as a PASS with a receipt. A Godot repo changing only .gd files was waved
# straight through work nothing had looked at.
echo "ship-gate finds nothing"
newrepo sg_unknown
echo "# notes" > NOTES.md
sg "a docs-only change is still a pass" "nothing to check" 0
seq 1 250 | sed 's/^/var x/' > player.gd
sg "gd is source, so a long one is caught" "over the limit" 1
rm -f player.gd
echo "const x = 1" > weird.zzz
sg "an extension the gate cannot place is never a pass" "does not know: zzz" 2

# Stryker's incremental file is mutmut's ./mutants cache wearing a different
# hat: --force reruns everything in scope, but the report still carries cached
# rows for everything OUT of scope, and this gate greps the whole report. The
# stub answers only when it is asked for incremental mode, so this test fails
# the moment the flag comes back.
echo "ship-gate stryker cache"
newrepo sg_stryker
printf '{"devDependencies":{"@stryker-mutator/core":"8"}}\n' > package.json
cat > bin/npx <<'X'
#!/bin/sh
case "$*" in *--incremental*) echo "[Survived] a mutant replayed from the cache" ;; esac
exit 0
X
chmod +x bin/npx
echo "const a=1" > a.ts
sg "stryker is not run in incremental mode" "nothing survived" 0

# Assert the ARGV, not the verdict. Every ship-gate bug so far hid from a test
# that only asked whether the gate said green: the stub is written from the same
# belief as the code, so it agrees with the bug and the verdict comes out right.
# The repeated --mutate — which mutated one file per run for four releases — and
# the --incremental cache before it were both a wrong argument list under a
# correct-looking verdict. This records exactly what the tool was handed, one
# line per argument, and compares the whole list. A flag that repeats, a flag
# that comes back, or a value that loses a file all fail here.
argv() {  # argv <label> <expected arg log, in full>
  N=$((N+1))
  rm -f "$LOG"
  bash "$SG" >/dev/null 2>&1
  got=$(cat "$LOG" 2>/dev/null)
  if [ "$got" = "$2" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n       want:\n%s\n       got:\n%s\n' "$1" "$2" "$got"; fi
}

echo "ship-gate stryker argv"
newrepo sg_argv
printf '{"devDependencies":{"@stryker-mutator/core":"10"}}\n' > package.json
printf '#!/bin/sh\nfor a in "$@"; do echo "arg[$a]" >> %s; done\n' "$LOG" > bin/npx
chmod +x bin/npx
echo "const a=1" > a.ts
echo "const b=2" > b.ts
argv "stryker is handed the whole diff in one --mutate, and nothing else" \
"arg[--no-install]
arg[stryker]
arg[run]
arg[--mutate]
arg[a.ts:1-1,b.ts:1-1]"

# Stryker validates every --mutate entry with Minimatch and refuses a range on
# anything glob-shaped: "Cannot combine a glob expression with a mutation range".
# A Next.js route folder is exactly that, so one [id] directory in the diff
# failed the whole run — every other file included. The path goes in with each
# bracket swapped for ? and no range: still one file, mutated whole.
echo "ship-gate stryker argv, glob-shaped paths"
newrepo sg_argv_glob
printf '{"devDependencies":{"@stryker-mutator/core":"10"}}\n' > package.json
printf '#!/bin/sh\nfor a in "$@"; do echo "arg[$a]" >> %s; done\n' "$LOG" > bin/npx
chmod +x bin/npx
echo "const a=1" > a.ts
mkdir -p 'app/[[...slug]]'
echo "const p=1" > 'app/[[...slug]]/page.ts'
argv "a route folder loses its range, not the whole run" \
"arg[--no-install]
arg[stryker]
arg[run]
arg[--mutate]
arg[a.ts:1-1,app/??...slug??/page.ts]"

# NoCoverage means no test executes the line at all, which is strictly worse than
# a survivor, and the gate used to call it a PASS: one commit shipped with 306
# uncovered mutants reported as proven. The stub prints the status line and the
# file:line:column line under it, the way Stryker's clear-text reporter does.
echo "ship-gate stryker no coverage"
newrepo sg_nocov
printf '{"devDependencies":{"@stryker-mutator/core":"10"}}\n' > package.json
cat > bin/npx <<'X'
#!/bin/sh
echo "[NoCoverage] BooleanLiteral"
echo "a.ts:1:11"
exit 0
X
chmod +x bin/npx
echo "const a=1" > a.ts
sg "a changed line no test runs is a finding" "[NoCoverage] BooleanLiteral" 1

# A glob-shaped path goes in without a range, so the whole file is mutated and
# lines nobody touched report uncovered. Charging those to this diff would be a
# finding that can never be closed, which is what teaches --force.
newrepo sg_nocov_glob
printf '{"devDependencies":{"@stryker-mutator/core":"10"}}\n' > package.json
cat > bin/npx <<'X'
#!/bin/sh
echo "[NoCoverage] BooleanLiteral"
echo "app/[id]/page.ts:9:11"
exit 0
X
chmod +x bin/npx
mkdir -p 'app/[id]'
echo "const p=1" > 'app/[id]/page.ts'
sg "a whole-file glob path is not judged for coverage" "nothing survived" 0

# The detail list is capped at 20 so one bad file cannot bury the output, and the
# cap used to be the whole story: 22 findings from a.ts filled it and b.ts never
# appeared. On a real diff that hid the WORST file, 54 uncovered mutants, behind
# a file with fewer. Every file with findings must be named below the cut.
echo "ship-gate findings cap"
newrepo sg_cap
printf '{"devDependencies":{"@stryker-mutator/core":"10"}}\n' > package.json
cat > bin/npx <<'X'
#!/bin/sh
i=1
while [ $i -le 22 ]; do
  echo "[NoCoverage] BooleanLiteral"
  echo "a.ts:$i:1"
  i=$((i+1))
done
echo "[NoCoverage] BooleanLiteral"
echo "b.ts:1:1"
exit 0
X
chmod +x bin/npx
echo "const a=1" > a.ts
echo "const b=2" > b.ts
sg "a file past the cap is still named" "1  b.ts" 1
sg "and the count of what was hidden is stated" "3 more not shown" 1

# routeTree.gen.ts is regenerated on every route change and cannot be split, and
# a shadcn component is not ours to split either. The limit fired on both, every
# time, which teaches --force — and a gate that is always forced is not a gate.
echo "ship-gate ignore list"
newrepo sg_ignore
mkdir -p src/components/ui api/migrations
seq 1 250 | sed 's/^/const x/' > src/routeTree.gen.ts
seq 1 250 | sed 's/^/const y/' > src/components/ui/sidebar.tsx
seq 1 250 | sed 's/^/z = /' > api/migrations/0001_init.py
sg "generated and vendored files are not gated" "nothing to check" 0
sg "the skip is named, never silent" "  src/routeTree.gen.ts" 0
sg "a vendored component matches at any depth" "  src/components/ui/sidebar.tsx" 0
sg "a migration matches at any depth" "  api/migrations/0001_init.py" 0
# A config has no tests and never will, so once an uncovered line became a
# finding, every diff touching one reported findings nobody could close.
seq 1 250 | sed 's/^/const c/' > vitest.config.ts
seq 1 250 | sed 's/^/const n/' > src/next.config.mjs
sg "a config file is not gated" "  vitest.config.ts" 0
sg "a config matches at any depth and any extension" "  src/next.config.mjs" 0
seq 1 250 | sed 's/^/const w/' > src/app.ts
sg "a real file beside them is still caught" "src/app.ts — 250 lines" 1
cat > .claude/gauntlet.conf <<'C'
GAUNTLET_IGNORE_FILES=""
C
sg "an empty list gates everything again" "src/routeTree.gen.ts — 250 lines" 1
rm -f .claude/gauntlet.conf

# git prints paths from the repo root; CLAUDE_PROJECT_DIR can name a subdirectory
# of it. Testing those paths from the subdirectory found no files, so the gate
# wrote a PASS over a committed diff it never read.
echo "ship-gate under a subdirectory project dir"
newrepo sg_sub
mkdir -p project-x/src
git checkout -qb feature
seq 1 250 | sed 's/^/const x/' > project-x/src/big.ts
git add -A; git commit -qm big
export CLAUDE_PROJECT_DIR="$R/project-x"
sg "a committed change is found from a subdirectory" "project-x/src/big.ts" 1
export CLAUDE_PROJECT_DIR="$R"

# mutmut lives in the project's venv, not on PATH, and `mutmut run` prints 🙁 and
# exits 0 whatever it finds — parsing that reports clean with survivors sitting
# there. `mutmut results` is the readable source.
echo "ship-gate mutmut"
newrepo sg_py
mkdir -p apps/api/.venv/bin apps/api/app
printf '[project]\nname="api"\n[tool.mutmut]\nsource_paths=["app/"]\n' > apps/api/pyproject.toml
touch apps/api/uv.lock
cat > apps/api/.venv/bin/mutmut <<'M'
#!/bin/sh
case "$1" in
  run)     echo "🙁🙁🙁"; exit 0 ;;
  results) echo "app.slugs.x_slugify__mutmut_3: survived"; exit 0 ;;
esac
M
chmod +x apps/api/.venv/bin/mutmut
echo "x=1" > apps/api/app/slugs.py
# An empty baseline accepts nothing, so every survivor is charged.
: > apps/api/.mutmut-baseline
sg "mutmut in the venv is found and its survivors reported" "app.slugs.x_slugify__mutmut_3" 1

# mutmut replays cached verdicts for any function whose source did not change,
# so a test-only commit gets last run's survivors back. This mutmut answers
# straight out of the cache: if the gate does not clear it, the stale survivor
# is reported as a finding on a tree whose tests kill it.
newrepo sg_py_stale
mkdir -p apps/api/.venv/bin apps/api/app apps/api/mutants
printf '[project]\nname="api"\n[tool.mutmut]\nsource_paths=["app/"]\n' > apps/api/pyproject.toml
touch apps/api/uv.lock
cat > apps/api/.venv/bin/mutmut <<'M'
#!/bin/sh
case "$1" in
  run)     mkdir -p mutants; exit 0 ;;
  results) [ -f mutants/cached ] && cat mutants/cached; exit 0 ;;
esac
M
chmod +x apps/api/.venv/bin/mutmut
echo "app.old.x__mutmut_1: survived" > apps/api/mutants/cached
echo "x=1" > apps/api/app/slugs.py
: > apps/api/.mutmut-baseline
sg "a stale mutant cache is cleared before the run" "nothing survived" 0

# mutmut reports the whole repo's survivors, not the diff's, so without a
# baseline the Python half of the gate can never go green. Recorded survivors
# are accepted debt; only a name that is not in the baseline is a finding.
newrepo sg_py_base
mkdir -p apps/api/.venv/bin apps/api/app
printf '[project]\nname="api"\n[tool.mutmut]\nsource_paths=["app/"]\n' > apps/api/pyproject.toml
touch apps/api/uv.lock
cat > apps/api/.venv/bin/mutmut <<'M'
#!/bin/sh
case "$1" in
  run)     exit 0 ;;
  results) cat ../../survivors; exit 0 ;;
esac
M
chmod +x apps/api/.venv/bin/mutmut
printf 'app.old.x_a__mutmut_1: survived\napp.old.x_b__mutmut_2: survived\n' > survivors
echo "x=1" > apps/api/app/slugs.py
sg "with no baseline the repo's debt is recorded, not charged" "existing survivor(s)" 2
sg "a baselined survivor is not a finding" "nothing survived" 0

printf 'app.old.x_a__mutmut_1: survived\napp.old.x_b__mutmut_2: survived\napp.new.x_c__mutmut_1: survived\n' > survivors
sg "a survivor outside the baseline fails" "app.new.x_c__mutmut_1" 1

printf 'app.old.x_a__mutmut_1: survived\n' > survivors
sg "killing a baselined survivor is reported, not required" "1 baselined survivor(s) now killed" 0

printf 'app.old.x_a__mutmut_1: survived\napp.new.x_c__mutmut_1: survived\n' > survivors
bash "$SG" --baseline >/dev/null 2>&1
sg "--baseline accepts the new survivor" "nothing survived" 0

# The receipt is the part a model cannot talk its way past: there is no claim to
# make, only a file that exists for this exact content or does not.
echo "ship-gate receipt"
newrepo sg2
mkdir -p .claude/hooks
cp "$SG" "$SGH" .claude/hooks/
chmod +x .claude/hooks/*.sh
H=".claude/hooks/ship-gate-hook.sh"
echo "const a=1" > a.ts
printf "GAUNTLET_MUTATE='echo clean'\n" > .claude/gauntlet.conf

hook() {  # hook <label> <deny|allow> <command>
  N=$((N+1))
  out=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$3\"}}" | bash "$H")
  got=allow; case "$out" in *'"deny"'*) got=deny ;; esac
  if [ "$got" = "$2" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s — want %s, got %s\n' "$1" "$2" "$got"; fi
}

hook "opening a PR is blocked with no receipt" deny "gh pr create --fill"
hook "merging a PR is blocked with no receipt" deny "gh pr merge 3 --squash"
hook "an unrelated command is untouched" allow "ls -la"
# A commit publishes nothing, and gating it is what made this expensive: the
# gate's scope is the whole branch, so a 46-file branch re-mutated all 46 files
# on every commit — fifteen minutes, twenty times, for one branch.
hook "a commit is never gated" allow "git commit -m x"
bash .claude/hooks/ship-gate.sh >/dev/null 2>&1
hook "the PR is allowed after the gate passes" allow "gh pr create --fill"
echo "const b=2" >> a.ts
hook "editing again invalidates the receipt" deny "gh pr create --fill"
bash .claude/hooks/ship-gate.sh >/dev/null 2>&1
git add -A >/dev/null 2>&1; git commit -qm work >/dev/null 2>&1
hook "the receipt survives the commit" allow "gh pr create --fill"

# A push to a feature branch ships nothing. A push while standing on a protected
# branch is a direct ship with no PR in front of it, so that one is gated. The
# branch comes from git, not from the command — `git push` names no branch.
BASEBR=$(git branch --show-current)
git checkout -qb feature/gate-scope 2>/dev/null
echo "const d=4" >> a.ts
hook "a push from a feature branch is not gated" allow "git push origin HEAD"
git checkout -q "$BASEBR" 2>/dev/null
hook "a push from the protected branch is gated" deny "git push origin HEAD"
git checkout -q feature/gate-scope 2>/dev/null

printf "GAUNTLET_MUTATE='echo \"[Survived] x\"'\n" > .claude/gauntlet.conf
echo "const c=3" >> a.ts
bash .claude/hooks/ship-gate.sh >/dev/null 2>&1
hook "a FAIL leaves no receipt" deny "gh pr create --fill"
bash .claude/hooks/ship-gate.sh --force >/dev/null 2>&1
hook "--force writes a receipt without running" allow "gh pr create --fill"

# ------------------------------------------------------------ the skill gates
# The application gate's BLOCKED text is one double-quoted bash string, so an
# unescaped " inside it closes the string early: the remainder runs as shell
# commands and the reason reaches the model EMPTY. That shipped in 2.16.1 and
# stood for five releases. Every denial since told the model nothing — not the
# rules, not even the ack command it was being asked to run — and the sessions
# that hit it were left guessing at what the gate wanted. Nothing caught it
# because no test had ever read the reason the hook actually emits.
echo "skill application gate message"
newrepo sag
mkdir -p .claude/skills/demo
printf -- '---\nname: demo\n---\n## Rules\n- always x\n' > .claude/skills/demo/SKILL.md
node -e "import('$HERE/../cli/lib/setup-hook.mjs').then(m=>m.setupHook('$PWD'))" >/dev/null 2>&1
SID="sag$RUN"
touch "/tmp/claude-skill-gate-$SID" "/tmp/claude-skill-loaded-$SID-demo"
SAG_OUT=$(printf '{"session_id":"%s","tool_name":"Write","tool_input":{"file_path":"%s/a.ts"}}' "$SID" "$PWD" \
          | bash .claude/hooks/skill-application-gate.sh 2>"$TMP/sag.err")
rm -f "/tmp/claude-skill-gate-$SID" "/tmp/claude-skill-loaded-$SID-demo"

sag() {  # sag <label> <node expression over r, the reason string>
  N=$((N+1))
  if printf '%s' "$SAG_OUT" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{const r=JSON.parse(d).hookSpecificOutput.permissionDecisionReason;process.exit(($2)?0:1)})" 2>/dev/null; then
    PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL+1)); printf '  FAIL %s\n       hook emitted: %s\n' "$1" "$SAG_OUT"
  fi
}

sag "the denial reason is not empty"   "r.length > 0"
sag "it names the ack command"         "r.includes('touch /tmp/claude-skill-acked-$SID-demo')"
sag "it carries the skill's rules"     "r.includes('always x')"
sag "a quoted phrase survives"         "r.includes('\"does not apply\"')"
sag "and the auto mode guidance"       "r.includes('Auto-Mode Bypass')"
# Exempting settings.json from the gate was not enough: the classifier denies an
# agent editing permission settings by any route. A peer session burned a round
# trip proving it. The message must say the user has to make the change.
sag "it says the user must add the rule"  "r.includes('The user has to add it')"
sag "and not to attempt it itself"        "r.includes('an agent editing permission settings')"
sag "and names the /permissions route"    "r.includes('/permissions, Auto mode tab')"

N=$((N+1))
if [ ! -s "$TMP/sag.err" ]; then
  PASS=$((PASS+1)); printf '  ok   %s\n' "the hook writes nothing to stderr"
else
  FAIL=$((FAIL+1)); printf '  FAIL the hook writes to stderr:\n%s\n' "$(cat "$TMP/sag.err")"
fi

# .json is in CODE_EXT, so both gates blocked ~/.claude/settings.json — the one
# file that holds the autoMode allow rule the deny message tells the model to
# add. With the ack touch denied by the classifier and the settings edit denied
# by the gate, each fix needed the other first and the session deadlocked with
# no move the model could make.
echo "skill gates exempt the settings file"
newrepo sg_settings
mkdir -p .claude/skills/demo
printf -- '---\nname: demo\n---\n## Rules\n- x\n' > .claude/skills/demo/SKILL.md
node -e "import('$HERE/../cli/lib/setup-hook.mjs').then(m=>m.setupHook('$PWD'))" >/dev/null 2>&1
SSID="sgs$RUN"

esc() {  # esc <label> <allow|deny> <hook file> <tool_name+tool_input json>
  N=$((N+1))
  out=$(printf '{"session_id":"%s",%s}' "$SSID" "$4" | bash ".claude/hooks/$3")
  if [ "$2" = "allow" ] && [ -z "$out" ]; then
    PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  elif [ "$2" = "deny" ] && [ -n "$out" ]; then
    PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL+1)); printf '  FAIL %s\n       hook emitted: %s\n' "$1" "$out"
  fi
}

# Loading gate: marker absent, so it is actively gating.
esc "loading gate lets the settings edit through" allow skill-gate.sh \
  '"tool_name":"Edit","tool_input":{"file_path":"/home/u/.claude/settings.json"}'
esc "loading gate still stops a source edit" deny skill-gate.sh \
  '"tool_name":"Edit","tool_input":{"file_path":"/home/u/src/a.ts"}'

# Application gate: loading satisfied, skill loaded, nothing acked.
touch "/tmp/claude-skill-gate-$SSID" "/tmp/claude-skill-loaded-$SSID-demo"
esc "application gate lets the settings edit through" allow skill-application-gate.sh \
  '"tool_name":"Edit","tool_input":{"file_path":"/home/u/.claude/settings.json"}'
esc "and settings.local.json too" allow skill-application-gate.sh \
  '"tool_name":"Edit","tool_input":{"file_path":"/home/u/.claude/settings.local.json"}'
esc "and a heredoc writing the settings file" allow skill-application-gate.sh \
  '"tool_name":"Bash","tool_input":{"command":"cat > /home/u/.claude/settings.json <<EOF"}'
esc "application gate still stops a source edit" deny skill-application-gate.sh \
  '"tool_name":"Edit","tool_input":{"file_path":"/home/u/src/a.ts"}'
rm -f "/tmp/claude-skill-gate-$SSID" "/tmp/claude-skill-loaded-$SSID-demo"

# The project-level permissions.allow the installer writes never cleared auto
# mode: the classifier reads autoMode.allow, and only from the user's own
# ~/.claude/settings.json. So the gate was unsatisfiable there, and the session
# could not fix it either — an agent editing permission settings is denied by
# the same classifier. Only the installer runs as the user.
echo "auto mode allow rule"
newrepo automode
AMH="$PWD/home"
AMS="$AMH/.claude/settings.json"
mkdir -p "$AMH/.claude"

amrun() { node -e "import('$HERE/../cli/lib/setup-hook.mjs').then(m=>m.writeAutoModeRule('$AMH')).catch(e=>{console.error(e.message);process.exit(1)})"; }

am() {  # am <label> <node expression over s, the parsed global settings>
  N=$((N+1))
  if node -e "const s=JSON.parse(require('fs').readFileSync('$AMS','utf8'));process.exit(($2)?0:1)" 2>/dev/null; then
    PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL+1)); printf '  FAIL %s\n       settings: %s\n' "$1" "$(cat "$AMS" 2>&1)"
  fi
}

MARK="r.includes('/tmp/claude-skill-acked-')"

# No settings file at all.
amrun >/dev/null 2>&1
am "the rule is written from nothing"  "s.autoMode.allow.some(r=>$MARK)"
am "and \$defaults comes first"         "s.autoMode.allow[0]==='\$defaults'"

# Re-running is the upgrade path, and it must not stack entries.
amrun >/dev/null 2>&1
am "a second run adds no duplicate"     "s.autoMode.allow.filter(r=>$MARK).length===1"
am "and leaves one \$defaults"           "s.autoMode.allow.filter(r=>r==='\$defaults').length===1"

# A real settings file has the user's own content in it.
printf '{"env":{"FOO":"bar"},"autoMode":{"allow":["$defaults","my own rule"]}}' > "$AMS"
amrun >/dev/null 2>&1
am "an unrelated setting survives"      "s.env.FOO==='bar'"
am "the user's own allow rule survives" "s.autoMode.allow.includes('my own rule')"

# An older wording must be corrected in place, not left beside the new one.
# A fresh-install test never sees this.
printf '{"autoMode":{"allow":["$defaults","old text about /tmp/claude-skill-acked- files"]}}' > "$AMS"
amrun >/dev/null 2>&1
am "a stale rule is replaced, not doubled" "s.autoMode.allow.filter(r=>$MARK).length===1"
am "and the stale wording is gone"         "!s.autoMode.allow.some(r=>r.includes('old text about'))"

# Never rewrite a file we cannot parse.
printf 'not json {{{' > "$AMS"
N=$((N+1))
if amrun >/dev/null 2>&1; then
  FAIL=$((FAIL+1)); printf '  FAIL %s\n' "an unparseable settings file is overwritten"
elif [ "$(cat "$AMS")" = "not json {{{" ]; then
  PASS=$((PASS+1)); printf '  ok   %s\n' "an unparseable settings file is refused, not rewritten"
else
  FAIL=$((FAIL+1)); printf '  FAIL %s\n       became: %s\n' "an unparseable settings file was altered" "$(cat "$AMS")"
fi

# Write|Edit|MultiEdit is not the only way to change a file. A session edited
# twelve source files through `python3 - <<'PY'` in Bash and neither gate fired.
echo "skill gate covers Bash"
newrepo sg_bash
mkdir -p .claude/skills/demo
printf -- '---\nname: demo\n---\n## Rules\n- x\n' > .claude/skills/demo/SKILL.md
node -e "import('$HERE/../cli/lib/setup-hook.mjs').then(m=>m.setupHook('$PWD'))" >/dev/null 2>&1
SKG=".claude/hooks/skill-gate.sh"

gate() {  # gate <label> <deny|allow> <tool> <command>
  N=$((N+1))
  rm -f /tmp/claude-skill-gate-gt$RUN
  out=$(printf '%s' "{\"session_id\":\"gt$RUN\",\"tool_name\":\"$3\",\"tool_input\":{\"command\":\"$4\"}}" | bash "$SKG")
  got=allow; case "$out" in *deny*) got=deny ;; esac
  if [ "$got" = "$2" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s — want %s, got %s\n' "$1" "$2" "$got"; fi
}

gate "a heredoc into python is gated" deny Bash "python3 - <<'PY'"
gate "a redirect into a file is gated" deny Bash "cat > src/foo.ts"
gate "sed -i is gated" deny Bash "sed -i 's/a/b/' x.ts"
gate "a read-only command is not gated" allow Bash "git status --short"
gate "a redirect to /dev/null is not a write" allow Bash "npm test 2>/dev/null"
gate "the command that clears the gate is never gated" allow Bash "touch /tmp/claude-skill-gate-gt$RUN"

# Skills are about code. A repo full of PLAN_*.md hit this gate on every write.
gatef() {  # gatef <label> <deny|allow> <file_path>
  N=$((N+1))
  rm -f /tmp/claude-skill-gate-gt$RUN
  out=$(printf '%s' "{\"session_id\":\"gt$RUN\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$3\"}}" | bash "$SKG")
  got=allow; case "$out" in *deny*) got=deny ;; esac
  if [ "$got" = "$2" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s — want %s, got %s\n' "$1" "$2" "$got"; fi
}

gatef "writing a plan document is not gated" allow "PLAN_notas.md"
gatef "writing a source file is gated" deny "src/lib/expenses.ts"
gatef "config files stay gated" deny "tsconfig.json"
gate "a heredoc writing markdown is not gated" allow Bash "cat > PREPLAN_x.md <<EOF"
gate "a heredoc writing source is gated" deny Bash "cat > src/a.ts <<EOF"

# --------------------------------------------- a skill that GAINS a reference file
# A bundle grows: react gained FORMS.md and SHADCN.md. A project that installed
# the skill before those existed has to receive them, or it keeps a SKILL.md
# routing to files that are not there.
echo "upgrading a skill that gained reference files"
newrepo skillupg
mkdir -p .claude/skills/react
printf -- '---\nname: react\n---\n# old copy, no references\n' > .claude/skills/react/SKILL.md
node -e "
  const src = '$HERE/..';
  Promise.all([import(src + '/cli/lib/local.mjs'), import(src + '/cli/lib/install.mjs')])
    .then(async ([local, install]) => {
      const skills = await local.makeLocalSource(src).fetchSkills();
      const react = skills.find((s) => s.dirName === 'react');
      await install.installSkills([react], '$PWD');
    });
" >/dev/null 2>&1

have() {  # have <label> <path>
  N=$((N+1))
  if [ -s "$2" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s — %s missing or empty\n' "$1" "$2"; fi
}

have "a newly added reference file arrives" .claude/skills/react/FORMS.md
have "a second one does too"                .claude/skills/react/SHADCN.md
have "the existing references are still there" .claude/skills/react/COMPONENT-DESIGN.md
N=$((N+1))
if grep -q 'FORMS.md' .claude/skills/react/SKILL.md; then
  PASS=$((PASS+1)); echo "  ok   SKILL.md was replaced, not left stale"
else
  FAIL=$((FAIL+1)); echo "  FAIL SKILL.md still the old copy — it does not route to FORMS.md"
fi

# ------------------------------------------------------------ upgrade, not just install
# Every hook bug that reached a release survived because it was only ever tested
# as a FRESH install. A project that already had an older version kept whatever
# settings.json it was first written with — which is how the skill gates went on
# watching Write|Edit|MultiEdit after they learned to cover Bash.
echo "upgrading an existing install"
newrepo upg
mkdir -p .claude/skills/demo .claude/hooks
printf -- '---\nname: demo\n---\n## Rules\n- x\n' > .claude/skills/demo/SKILL.md
cat > .claude/settings.json <<'OLD'
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Write|Edit|MultiEdit",
        "hooks": [{ "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/skill-gate.sh" }] }
    ]
  }
}
OLD
node -e "import('$HERE/../cli/lib/setup-hook.mjs').then(m=>m.setupHook('$PWD'))" >/dev/null 2>&1

check_json() {  # check_json <label> <node expression returning true>
  N=$((N+1))
  if node -e "const s=require('$PWD/.claude/settings.json'); process.exit(($2)?0:1)" 2>/dev/null; then
    PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL+1)); printf '  FAIL %s\n       settings.json: %s\n' "$1" "$(cat "$PWD/.claude/settings.json" | tr -d '\n ')"
  fi
}

check_json "a stale matcher is corrected, not left alone" \
  "s.hooks.PreToolUse.find(e=>e.hooks[0].command.endsWith('skill-gate.sh')).matcher==='Write|Edit|MultiEdit|Bash'"
check_json "the hook is not registered twice" \
  "s.hooks.PreToolUse.filter(e=>e.hooks[0].command.endsWith('skill-gate.sh')).length===1"
check_json "hooks missing from the old file are added" \
  "s.hooks.Stop && s.hooks.Stop.some(e=>e.hooks[0].command.endsWith('gauntlet.sh'))"
check_json "an upgrade gains the SessionStart version check" \
  "s.hooks.SessionStart && s.hooks.SessionStart.some(e=>e.hooks[0].command.endsWith('version-check.sh'))"

# Both gates clear by touching a marker under /tmp, and auto mode's classifier
# refuses a touch whose only purpose is to unlock a gate — so the application
# gate could not be satisfied there at all, and the model ended up asking its
# user to run the touch by hand. The old settings.json here has no permissions
# key at all, which is what every install before this looked like.
check_json "an upgrade gains the marker allowlist" \
  "s.permissions && s.permissions.allow.includes('Bash(touch /tmp/claude-skill-acked-*)')"
check_json "all three markers are allowed" \
  "['gate','acked','loaded'].every(k=>s.permissions.allow.includes('Bash(touch /tmp/claude-skill-'+k+'-*)'))"

node -e "import('$HERE/../cli/lib/setup-hook.mjs').then(m=>m.setupHook('$PWD'))" >/dev/null 2>&1
check_json "reinstalling does not duplicate the rules" \
  "s.permissions.allow.filter(r=>r==='Bash(touch /tmp/claude-skill-acked-*)').length===1"

# A version nudge that costs a network round trip at session start is a version
# nudge that hangs the session on a bad connection. This one only ever reads a
# cache, and says nothing at all until it has one.
echo "version check"
VC="$HERE/version-check.sh"
vc() {  # vc <label> <expected substring, or empty for no output> [setup...]
  N=$((N+1))
  out=$(bash "$VC" 2>&1)
  ok=1
  if [ -z "$2" ]; then
    [ -n "$out" ] && ok=0
  else
    case "$out" in *"$2"*) ;; *) ok=0 ;; esac
  fi
  if [ $ok = 1 ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n       want ~ %s\n       got: %s\n' "$1" "${2:-<nothing>}" "$out"
  fi
}

newrepo vc1
export HOME="$TMP/vchome"; mkdir -p "$HOME/.claude"
vc "no manifest, so nothing is said" ""

printf '{"catalogVersion":"2.0.0","skills":[]}\n' > .claude/.claude-skills.json
vc "no cache yet, so nothing is said" ""

echo "2.1.0" > "$HOME/.claude/.claude-skills-version"
vc "a newer published version is reported" "2.0.0 installed, 2.1.0 published"
vc "and not reported twice the same day" ""

rm -f "$HOME/.claude/.claude-skills-version-told"
echo "2.0.0" > "$HOME/.claude/.claude-skills-version"
vc "the same version is not an update" ""

echo "1.9.0" > "$HOME/.claude/.claude-skills-version"
vc "a cache behind the install is not an update" ""

echo "2.10.0" > "$HOME/.claude/.claude-skills-version"
vc "versions compare numerically, not as text" "2.0.0 installed, 2.10.0 published"

rm -f "$HOME/.claude/.claude-skills-version-told"
CLAUDE_SKILLS_NO_VERSION_CHECK=1 bash "$VC" > "$TMP/vc.out" 2>&1
N=$((N+1))
if [ ! -s "$TMP/vc.out" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "the opt-out silences it"
else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "the opt-out silences it"; fi
export HOME="$TMP/home"

# ------------------------------------------- build output is not a project
# Next.js writes a package.json into .next/, .next/dev/ and .next/standalone/.
# The tool-needs scan skipped only a hardcoded list of build dirs, so it walked
# into all three and told the user to install Stryker in each — and then dropped
# the real repo root, because those phantoms made it look like a root that
# delegates to a workspace. It asks git what is ignored now.
echo "tool needs, against build output"
newrepo toolneeds
printf '{"name":"app"}\n' > package.json
printf '.next/\n' > .gitignore
mkdir -p .next/standalone .next/dev
printf '{"name":"next"}\n' > .next/package.json
printf '{"name":"sa"}\n'   > .next/standalone/package.json
printf '{"name":"dev"}\n'  > .next/dev/package.json
node -e "
  import('$HERE/../cli/lib/local.mjs').then(async (local) => {
    const needs = await local.reportToolNeeds('$PWD');
    console.log(needs.map((n) => n.label).join(' '));
  });
" > "$TMP/needs.out" 2>&1
needs=$(cat "$TMP/needs.out")

N=$((N+1))
case "$needs" in
  *.next*) FAIL=$((FAIL+1)); printf '  FAIL %s\n       got %s\n' "gitignored build output is not a project" "$needs" ;;
  *)       PASS=$((PASS+1)); printf '  ok   %s\n' "gitignored build output is not a project" ;;
esac

N=$((N+1))
case "$needs" in
  *"<repo root>"*) PASS=$((PASS+1)); printf '  ok   %s\n' "the real root is still reported" ;;
  *)               FAIL=$((FAIL+1)); printf '  FAIL %s\n       got %s\n' "the real root is still reported" "$needs" ;;
esac

# ------------------------------------------------- scaffolding Stryker's setup
# The CLI used to print five setup steps, so every project was configured by
# hand and the step people skipped was the class-name ignorer — the reason a
# first React run comes back with dozens of mutants on className strings that no
# test can honestly kill. Those get written now, and the two that touch the
# lockfile or someone's own vitest config stay printed.
echo "stryker scaffold"
newrepo strscaf
printf '{"name":"app"}\n' > package.json
printf 'node_modules\n' > .gitignore
node -e "
  import('$HERE/../cli/lib/scaffold-stryker.mjs').then(async (m) => {
    const r = await m.scaffoldStryker('$PWD', '');
    console.log(JSON.stringify(r));
  });
" > "$TMP/scaf.json" 2>&1

scaf() {  # scaf <label> <node expression over r>
  N=$((N+1))
  if node -e "const r=require('$TMP/scaf.json'); process.exit(($2)?0:1)" 2>/dev/null; then
    PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n       result: %s\n' "$1" "$(cat "$TMP/scaf.json")"; fi
}

have "the config is written"            stryker.config.json
have "the class-name ignorer is written" stryker-classname-ignorer.mjs
scaf "the config names the ignorer plugin" \
  "require('$PWD/stryker.config.json').ignorers.includes('tailwind-classnames')"
scaf "and loads it as a plugin" \
  "require('$PWD/stryker.config.json').plugins.includes('./stryker-classname-ignorer.mjs')"

N=$((N+1))
if grep -q '^\.stryker-tmp/$' .gitignore && grep -q '^node_modules$' .gitignore; then
  PASS=$((PASS+1)); printf '  ok   %s\n' "gitignore gains the temp dir and keeps what was there"
else
  FAIL=$((FAIL+1)); printf '  FAIL gitignore is %s\n' "$(cat .gitignore | tr '\n' ' ')"
fi

N=$((N+1))
if grep -q '@stryker-mutator/api' "$TMP/scaf.json"; then
  PASS=$((PASS+1)); printf '  ok   %s\n' "the install command carries the api package"
else
  FAIL=$((FAIL+1)); printf '  FAIL the install command omits @stryker-mutator/api\n'
fi

# npm hoists @stryker-mutator/api by accident and pnpm does not, so the command
# has to come from the lockfile that is actually there.
printf 'lockfileVersion: 9\n' > pnpm-lock.yaml
node -e "
  import('$HERE/../cli/lib/scaffold-stryker.mjs').then(async (m) => {
    console.log(JSON.stringify(await m.scaffoldStryker('$PWD', '')));
  });
" > "$TMP/scaf.json" 2>&1
scaf "a pnpm project gets a pnpm install command" "r.install.startsWith('pnpm ')"
scaf "and nothing is rewritten the second time" "r.wrote.length === 0 && r.kept.length === 3"

# The projects already running Stryker are the ones grinding through className
# mutants, and reportToolNeeds skipped them outright because they were not
# missing a tool. A setup written before the ignorer existed had no way to learn
# about it.
echo "stryker scaffold, already installed"
newrepo strhave
printf '{"devDependencies":{"@stryker-mutator/core":"10"}}\n' > package.json
printf '{"testRunner":"vitest","coverageAnalysis":"perTest","mutate":["src/**"]}\n' > stryker.config.json
node -e "
  import('$HERE/../cli/lib/local.mjs').then(async (l) => {
    const n = await l.reportToolNeeds('$PWD');
    console.log(JSON.stringify(n.map((x) => [x.label, x.ignorerOnly === true])));
  });
" > "$TMP/have.json" 2>&1
N=$((N+1))
if grep -q '\["<repo root>",true\]' "$TMP/have.json"; then
  PASS=$((PASS+1)); printf '  ok   %s\n' "an existing install is offered the ignorer"
else
  FAIL=$((FAIL+1)); printf '  FAIL an existing install is not offered the ignorer: %s\n' "$(cat "$TMP/have.json")"
fi

node -e "
  import('$HERE/../cli/lib/scaffold-stryker.mjs').then(async (m) => {
    console.log(JSON.stringify(await m.scaffoldStryker('$PWD', '')));
  });
" > "$TMP/scaf.json" 2>&1
scaf "the existing config is patched, not replaced" "r.patched.length === 1"
scaf "its own settings survive" \
  "require('$PWD/stryker.config.json').mutate[0] === 'src/**'"
scaf "the ignorer is wired in" \
  "require('$PWD/stryker.config.json').ignorers.includes('tailwind-classnames')"

node -e "
  import('$HERE/../cli/lib/local.mjs').then(async (l) => {
    console.log(JSON.stringify(await l.reportToolNeeds('$PWD')));
  });
" > "$TMP/have.json" 2>&1
N=$((N+1))
if [ "$(cat "$TMP/have.json")" = "[]" ]; then
  PASS=$((PASS+1)); printf '  ok   %s\n' "and it stops being offered once wired in"
else
  FAIL=$((FAIL+1)); printf '  FAIL still offered after wiring: %s\n' "$(cat "$TMP/have.json")"
fi

# A config this cannot parse is somebody's own file. Reporting it beats
# rewriting it from a guess.
printf '{ testRunner: "vitest" }\n' > stryker.config.json
node -e "
  import('$HERE/../cli/lib/scaffold-stryker.mjs').then(async (m) => {
    console.log(JSON.stringify(await m.scaffoldStryker('$PWD', '')));
  });
" > "$TMP/scaf.json" 2>&1
scaf "an unparseable config is reported, not rewritten" \
  "r.unreadable.length === 1 && r.patched.length === 0"
N=$((N+1))
if grep -q 'testRunner: "vitest"' stryker.config.json; then
  PASS=$((PASS+1)); printf '  ok   %s\n' "and is left exactly as it was"
else
  FAIL=$((FAIL+1)); printf '  FAIL the unparseable config was overwritten\n'
fi

# One table of 11 headings and 16 term rows produced 57 unkillable survivors and
# a fifteen-minute gate. The only test that kills 'Pizzas' -> 'Stryker was here!'
# asserts the table against a copy of the table. So string mutants inside a
# module-level data table are ignored — by where they sit, like the className
# rule, not by disabling the StringLiteral mutator everywhere.
echo "stryker data-table ignorer"

idt() {  # idt <label> <expected 1|0> <js defining `leaf`>
  N=$((N+1))
  if node -e "import('$HERE/../cli/lib/scaffold-stryker.mjs').then(m=>{const P=(k,node,parent)=>({isFunction:()=>k.includes('fn'),isVariableDeclarator:()=>k.includes('vd'),isStringLiteral:()=>k.includes('str'),node:node||{},parentPath:parent||null});$3;process.exit(m.inDataTable(leaf)===($2===1)?0:1)})" 2>/dev/null; then
    PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"
  fi
}

idt "a string in a module-level array is data" 1 \
  "const d=P(['vd'],{init:{type:'ArrayExpression'}});const leaf=P(['str'],{},d)"
idt "a string in a module-level object is data" 1 \
  "const d=P(['vd'],{init:{type:'ObjectExpression'}});const leaf=P(['str'],{},d)"
idt "a string inside a function is not data" 0 \
  "const f=P(['fn']);const d=P(['vd'],{init:{type:'ArrayExpression'}},f);const leaf=P(['str'],{},d)"
idt "a const built by a call is not data" 0 \
  "const d=P(['vd'],{init:{type:'CallExpression'}});const leaf=P(['str'],{},d)"
idt "a string in no declaration is not data" 0 \
  "const leaf=P(['str'],{},null)"

newrepo stridt
node -e "import('$HERE/../cli/lib/scaffold-stryker.mjs').then(m=>m.scaffoldStryker('$PWD',''))" >/dev/null 2>&1
N=$((N+1))
if grep -q 'inDataTable(path)' stryker-classname-ignorer.mjs; then
  PASS=$((PASS+1)); printf '  ok   %s\n' "the generated ignorer carries the rule"
else
  FAIL=$((FAIL+1)); printf '  FAIL the generated ignorer has no data-table rule\n'
fi

# The upgrade, not the install. A project holding the v1 ignorer kept it forever
# under the old "exists, so leave it" branch and never gained this rule.
printf '// old v1 ignorer\nexport const strykerPlugins = [];\n' > stryker-classname-ignorer.mjs
node -e "
  import('$HERE/../cli/lib/scaffold-stryker.mjs').then(async (m) => {
    console.log(JSON.stringify(await m.scaffoldStryker('$PWD', '')));
  });
" > "$TMP/scaf.json" 2>&1
scaf "an outdated ignorer is rewritten" \
  "r.patched.some(p=>p.includes('stryker-classname-ignorer.mjs'))"
N=$((N+1))
if grep -q 'inDataTable(path)' stryker-classname-ignorer.mjs; then
  PASS=$((PASS+1)); printf '  ok   %s\n' "and the upgraded file has the rule"
else
  FAIL=$((FAIL+1)); printf '  FAIL the outdated ignorer was left in place\n'
fi

node -e "
  import('$HERE/../cli/lib/scaffold-stryker.mjs').then(async (m) => {
    console.log(JSON.stringify(await m.scaffoldStryker('$PWD', '')));
  });
" > "$TMP/scaf.json" 2>&1
scaf "a current ignorer is left alone" \
  "r.kept.some(p=>p.includes('stryker-classname-ignorer.mjs'))"

cd /
rm -rf "$TMP"
echo
echo "$PASS passed, $FAIL failed, $N total"
[ "$FAIL" = 0 ]
