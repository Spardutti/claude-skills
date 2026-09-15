#!/usr/bin/env bash
# ship-gate cases for scoping mutmut to the modules a diff changed.
# Sourced by gauntlet-selftest.sh; shares its $HERE, $TMP, $N, $PASS, $FAIL.

echo "ship-gate mutmut scope"

# One committed module the diff leaves alone, two it changes. The stub logs
# every call's arguments and answers `results` from ../../survivors.
scoped_repo() {
  newrepo "$1"
  mkdir -p apps/api/.venv/bin apps/api/app/orders apps/api/app/auth
  printf '[project]\nname="api"\n[tool.mutmut]\nsource_paths=["app/"]\n' > apps/api/pyproject.toml
  touch apps/api/uv.lock
  cat > apps/api/.venv/bin/mutmut <<'M'
#!/bin/sh
echo "$*" >> ../../mutmut.args
[ "$1" = run ] && [ -f ../../nomatch ] && { echo "AssertionError: Filtered for specific mutants, but nothing matches"; exit 1; }
[ "$1" = run ] && [ -f ../../cleanfail ] && { printf 'FAILED tests/test_log.py::test_logs\nAssertionError: assert [] == [1]\nFailed to run clean test\n'; exit 1; }
[ "$1" = results ] && cat ../../survivors
exit 0
M
  chmod +x apps/api/.venv/bin/mutmut
  echo "x=1" > apps/api/app/auth/login.py
  git add -A; git commit -qm base; git branch -q develop
  echo "x=1" > apps/api/app/slugs.py
  echo "x=1" > apps/api/app/orders/__init__.py
  : > survivors
  : > apps/api/.mutmut-baseline
}

run_args() {  # run_args <label> <expected mutmut run argument list> [gate flag]
  N=$((N+1))
  rm -f mutmut.args
  bash "$SG" ${3:-} >/dev/null 2>&1
  got=$(grep '^run' mutmut.args 2>/dev/null)
  if [ "$got" = "$2" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$got"; fi
}

lacks() {  # lacks <label> <substring the output must not contain> <substring it must>
  N=$((N+1))
  out=$(bash "$SG" 2>&1)
  case "$out" in
    *"$2"*) FAIL=$((FAIL+1)); printf '  FAIL %s\n%s\n' "$1" "$out" ;;
    *"$3"*) PASS=$((PASS+1)); printf '  ok   %s\n' "$1" ;;
    *) FAIL=$((FAIL+1)); printf '  FAIL %s — missing: %s\n%s\n' "$1" "$3" "$out" ;;
  esac
}

# Unscoped, one PR that changed three API modules re-ran all 1810 mutants of
# the API on every gate run, auth included.
scoped_repo sg_scope
run_args "the run names one glob per changed module" "run app.orders.__init__.x* app.slugs.x*"

printf '    app.auth.login.x_check__mutmut_1: survived\n    app.auth.login.x_check__mutmut_2: not checked\n' > survivors
sg "a module the diff left alone is neither charged nor UNPROVEN" "nothing survived" 0

printf '    app.slugs_extra.x_f__mutmut_1: survived\n' > survivors
sg "a module that only shares a changed module's prefix is out of scope" "nothing survived" 0

printf '    app.slugs.x_slugify__mutmut_3: survived\n' > survivors
sg "a survivor in a changed module still fails" "app.slugs.x_slugify__mutmut_3" 1

printf '    app.slugs.x_slugify__mutmut_1: not checked\n' > survivors
sg "an unrun mutant in a changed module is still UNPROVEN" "1 mutant(s) were never run" 2

# The baseline is the whole repo's debt, so a scoped run leaves most of it out
# without anything having been killed.
printf 'app.auth.login.x_check__mutmut_1\n' > apps/api/.mutmut-baseline
: > survivors
lacks "a baselined survivor outside the scope is not reported killed" "now killed" "nothing survived"

# mutmut aborts before a single test when no glob matches, and every result
# then falls outside the scope, which would otherwise read as clean.
touch nomatch
sg "a scope that matched no mutant is UNPROVEN, not clean" "no mutant in the changed module(s)" 2
rm -f nomatch

# A test that leaks state fails only in mutmut's second in-process pass. The gate
# blamed an unreachable database, and an agent chased Docker instead of the test.
touch cleanfail
printf '    app.slugs.x_slugify__mutmut_1: not checked\n' > survivors
sg "mutmut stopping early shows the test that stopped it" "FAILED tests/test_log.py::test_logs" 2
lacks "and does not blame a database" "a database, a queue" "Failed to run clean test"
rm -f cleanfail
: > survivors

# Rebuilding the whole baseline re-mutated an entire API to accept eleven names.
run_args "--baseline runs only the changed modules" "run app.orders.__init__.x* app.slugs.x*" --baseline

# Scoped, it must still keep every other module's accepted debt, or the next diff
# touching one of them is charged for survivors it did not create.
printf 'app.auth.login.x_check__mutmut_1\napp.slugs.x_old__mutmut_1\n' > apps/api/.mutmut-baseline
printf '    app.slugs.x_new__mutmut_2: survived\n' > survivors
bash "$SG" --baseline >/dev/null 2>&1
N=$((N+1))
want=$(printf 'app.auth.login.x_check__mutmut_1\napp.slugs.x_new__mutmut_2')
got=$(cat apps/api/.mutmut-baseline)
if [ "$got" = "$want" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "a scoped --baseline keeps other modules and replaces the changed ones"
else FAIL=$((FAIL+1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "a scoped --baseline keeps other modules and replaces the changed ones" "$want" "$got"; fi
: > survivors
rm -f apps/api/.mutmut-baseline
run_args "with no baseline the whole repo is recorded" "run"

# mutmut strips a leading src. from module names.
scoped_repo sg_scope_src
rm -f apps/api/app/slugs.py apps/api/app/orders/__init__.py
mkdir -p apps/api/src/pkg
echo "x=1" > apps/api/src/pkg/core.py
run_args "a src layout's glob drops the src. prefix" "run pkg.core.x*"

# Accepting survivors re-ran mutmut on the tree the last run had just tested, then
# wrote no receipt, so one PR paid for four full runs.
echo "ship-gate --baseline reuses the last run"
scoped_repo sg_scope_accept
printf '    app.slugs.x_slugify__mutmut_3: survived\n' > survivors
sg "a survivor fails the run before it is accepted" "app.slugs.x_slugify__mutmut_3" 1
run_args "--baseline on the tree that just ran does not run mutmut" "" --baseline
N=$((N+1))
if grep -qx "app.slugs.x_slugify__mutmut_3" apps/api/.mutmut-baseline; then PASS=$((PASS+1)); printf '  ok   %s\n' "and still accepts that run's survivor"
else FAIL=$((FAIL+1)); printf '  FAIL %s\n       baseline: %s\n' "and still accepts that run's survivor" "$(cat apps/api/.mutmut-baseline)"; fi
N=$((N+1))
if [ -f "/tmp/claude-shipgate-$(bash "$SG" --key)" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "and writes the receipt, so the gate need not run again"
else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "and writes the receipt, so the gate need not run again"; fi
sg "the next run is clean" "nothing survived" 0
mkdir -p apps/api/tests
echo "def test_slug(): pass" > apps/api/tests/test_slugs.py
run_args "--baseline after a test changed runs mutmut again" "run app.orders.__init__.x* app.slugs.x*" --baseline

# The replayed log is what marks a run that matched no mutant; without it the
# replay reads as clean and writes a PASS over a run that tested nothing.
scoped_repo sg_scope_replay_nomatch
touch nomatch
sg "a scope that matched nothing is UNPROVEN" "no mutant in the changed module(s)" 2
rm -f mutmut.args
N=$((N+1))
out=$(bash "$SG" --baseline 2>&1)
case "$out" in *"no mutant in the changed module(s)"*) ok=1 ;; *) ok=0 ;; esac
[ -f mutmut.args ] && ok=0
if [ $ok = 1 ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "a replayed run that matched nothing is still UNPROVEN"
else FAIL=$((FAIL+1)); printf '  FAIL %s\n%s\n' "a replayed run that matched nothing is still UNPROVEN" "$out"; fi
