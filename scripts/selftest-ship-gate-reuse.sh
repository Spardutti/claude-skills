#!/usr/bin/env bash
# ship-gate cases for not re-running a project whose last clean verdict still stands.
# Sourced by gauntlet-selftest.sh; shares its $HERE, $TMP, $N, $PASS, $FAIL.

echo "ship-gate reuses a clean verdict"

# Logs live outside the repo: a file that changes every run would change every key.
export RAN="$TMP/reuse-ran.log" STRYKER_OUT="$TMP/reuse-stryker.out"
: > "$STRYKER_OUT"

# Two JS apps and a Python API. Each stub logs the project it ran in.
reuse_repo() {
  newrepo "$1"
  mkdir -p apps/web/src apps/admin/src apps/api/app apps/api/.venv/bin
  for app in web admin; do
    printf '{"devDependencies":{"@stryker-mutator/core":"8"}}\n' > "apps/$app/package.json"
    echo "export const a = 1" > "apps/$app/src/a.ts"
  done
  printf '[project]\nname="api"\n[tool.mutmut]\nsource_paths=["app/"]\n' > apps/api/pyproject.toml
  touch apps/api/uv.lock
  echo "x=1" > apps/api/app/slugs.py
  cat > bin/npx <<'X'
#!/bin/sh
basename "$PWD" >> "$RAN"
cat "$STRYKER_OUT"
exit 0
X
  cat > apps/api/.venv/bin/mutmut <<'M'
#!/bin/sh
[ "$1" = run ] && echo api >> "$RAN"
exit 0
M
  chmod +x bin/npx apps/api/.venv/bin/mutmut
  git add -A; git commit -qm base; git branch -q develop
  for app in web admin; do echo "export const b = 2" >> "apps/$app/src/a.ts"; done
  echo "y=2" >> apps/api/app/slugs.py
  : > apps/api/.mutmut-baseline
}

ran_in() {  # ran_in <label> <projects the tools ran in, sorted> [gate flag]
  N=$((N+1))
  : > "$RAN"
  bash "$SG" ${3:-} >/dev/null 2>&1
  got=$(sort "$RAN" | tr '\n' ' ' | sed 's/ $//')
  if [ "$got" = "$2" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$got"; fi
}

# The catalog PR's fix rounds edited only API tests, and every round re-ran
# Stryker on web and back office, which had already passed.
reuse_repo sg_reuse
ran_in "the first run tests every project" "admin api web"
ran_in "an unchanged tree re-runs nothing" ""
sg "and says why each was not re-run" "not re-run: nothing of its kind changed" 0

echo "y=3" >> apps/api/app/slugs.py
ran_in "a Python change re-runs only the Python project" "api"

echo "export const c = 3" >> apps/admin/src/a.ts
ran_in "a change in one JS app re-runs every JS app" "admin web"

echo "test" > apps/web/src/a.test.ts
ran_in "a changed test re-runs its kind" "admin web"

echo "# notes" > apps/web/NOTES.md
ran_in "a docs change re-runs nothing" ""

echo "export const d = 4" >> apps/web/src/a.ts
printf '[Survived] StringLiteral\nsrc/a.ts:2:1\n' > "$STRYKER_OUT"
ran_in "a failing run is tested" "admin web"
: > "$STRYKER_OUT"
ran_in "and is not recorded, so the next run tests it again" "admin web"

ran_in "--baseline on an unchanged tree replays the last run" "" --baseline
echo "y=4" >> apps/api/app/slugs.py
ran_in "--baseline after a change asks mutmut, not a JS app that passed" "api" --baseline

# A verdict from an older gate is a verdict from whatever bugs it had.
mkdir -p "$TMP/gate2"
cp "$SG" "$HERE/ship-gate-projects.sh" "$HERE/ship-gate-structure.sh" "$TMP/gate2/"
echo "# a newer gate" >> "$TMP/gate2/ship-gate.sh"
SG_REAL=$SG; SG="$TMP/gate2/ship-gate.sh"
ran_in "a changed gate trusts no verdict an older one recorded" "admin api web"
SG=$SG_REAL

# A config command's scope is unknown, so it has no kind to key on.
newrepo sg_reuse_config
echo "const a=1" > a.ts
printf "GAUNTLET_MUTATE='echo x >> \"\$RAN\"'\n" > .claude/gauntlet.conf
: > "$RAN"
bash "$SG" >/dev/null 2>&1
bash "$SG" >/dev/null 2>&1
N=$((N+1))
if [ "$(grep -c x "$RAN")" = 2 ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "a GAUNTLET_MUTATE command is never skipped"
else FAIL=$((FAIL+1)); printf '  FAIL %s — ran %s time(s)\n' "a GAUNTLET_MUTATE command is never skipped" "$(grep -c x "$RAN")"; fi
