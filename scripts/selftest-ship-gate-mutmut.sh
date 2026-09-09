#!/usr/bin/env bash
# ship-gate cases for the Python half, and the receipt that gates git.
# Sourced by gauntlet-selftest.sh; shares its $HERE, $TMP, $N, $PASS, $FAIL.

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

# Tests that need a database cannot run on the host: mutmut generates every
# mutant and records it "not checked". No survivor lines come out, so the gate
# said "nothing survived" and, with no baseline yet, wrote an EMPTY one and
# told the user to commit it — after which that repo's Python gate could never
# fail again. Counting kills cannot catch this: `mutmut results` skips killed
# mutants, so a perfect suite prints nothing too.
newrepo sg_py_unchecked
mkdir -p apps/api/.venv/bin apps/api/app
printf '[project]\nname="api"\n[tool.mutmut]\nsource_paths=["app/"]\n' > apps/api/pyproject.toml
touch apps/api/uv.lock
cat > apps/api/.venv/bin/mutmut <<'M'
#!/bin/sh
case "$1" in
  run)     exit 0 ;;
  results) echo "    app.slugs.x_slugify__mutmut_1: not checked"
           echo "    app.slugs.x_slugify__mutmut_2: not checked"; exit 0 ;;
esac
M
chmod +x apps/api/.venv/bin/mutmut
echo "x=1" > apps/api/app/slugs.py
# Assert the sentence this change introduces, not the bare word UNPROVEN: the
# old gate reached exit 2 down the "no baseline" path and printed UNPROVEN for
# other reasons, so the looser assertion passed with the bug still in place.
sg "a run that checked nothing is UNPROVEN, not clean" "2 mutant(s) were never run" 2
N=$((N+1))
if [ -f apps/api/.mutmut-baseline ]; then
  FAIL=$((FAIL+1)); printf '  FAIL %s\n' "and no baseline is written from it"
else
  PASS=$((PASS+1)); printf '  ok   %s\n' "and no baseline is written from it"
fi

# The fix for that: an executable .mutmut-run in the project runs mutmut where
# the services are. It must win over .venv/bin/mutmut, which is the one that
# cannot reach them. A stub that merely returned a verdict would agree with the
# bug, so this asserts WHICH runner was executed.
newrepo sg_py_runner
mkdir -p apps/api/.venv/bin apps/api/app
printf '[project]\nname="api"\n[tool.mutmut]\nsource_paths=["app/"]\n' > apps/api/pyproject.toml
touch apps/api/uv.lock
cat > apps/api/.venv/bin/mutmut <<'M'
#!/bin/sh
case "$1" in
  results) echo "    app.host.x__mutmut_1: survived" ;;
esac
exit 0
M
cat > apps/api/.mutmut-run <<'M'
#!/bin/sh
case "$1" in
  results) echo "    app.container.x__mutmut_1: survived" ;;
esac
exit 0
M
chmod +x apps/api/.venv/bin/mutmut apps/api/.mutmut-run
echo "x=1" > apps/api/app/slugs.py
: > apps/api/.mutmut-baseline
sg ".mutmut-run wins over the host venv" "app.container.x__mutmut_1" 1

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