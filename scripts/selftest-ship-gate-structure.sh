#!/usr/bin/env bash
# ship-gate cases for where a new file may live. Sourced by gauntlet-selftest.sh.
# Each case compares every flagged line, so a rule that stops firing fails here and not only the verdict.

structure() {  # structure <label> <every flagged line, or "ok"> <exit code>
  N=$((N+1))
  out=$(bash "$SG" 2>&1); rc=$?
  got=$(printf '%s\n' "$out" | sed -n '/^STRUCTURE — new files/,/^  Move them/p' | sed '1d;$d' | sort)
  [ -z "$got" ] && printf '%s\n' "$out" | grep -q '^STRUCTURE — ok' && got=ok
  want=$(printf '%s\n' "$2" | sort)
  if [ "$got" = "$want" ] && [ "$rc" = "$3" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n       want exit %s:\n%s\n       got exit %s:\n%s\n' "$1" "$3" "$want" "$rc" "$got"
  fi
}

structrepo() {  # structrepo <name> <manifest file> <manifest content>
  newrepo "$1"
  echo "GAUNTLET_MUTATE='true'" > .claude/gauntlet.conf
  printf '%s\n' "$3" > "$2"
}

echo "ship-gate structure: React"
structrepo sg_struct_js package.json '{}'
mkdir -p src/components
echo "export const Old = 1" > src/components/Old.tsx
git add -A; git commit -qm legacy; git branch develop
echo "export const Old = 2" > src/components/Old.tsx
structure "an edited file in the old layout is not judged" ok 0

git checkout -qb feature
echo "export const x = 1" > src/components/Committed.tsx
echo "export const x = 1" > src/components/Gone.tsx
git add -A; git commit -qm "added on the branch"
rm src/components/Gone.tsx
for k in components hooks api queries schemas types utils stores test; do
  mkdir -p "src/features/kinds/$k"; echo "export const x = 1" > "src/features/kinds/$k/x.ts"
done
mkdir -p src/features/destinos/components src/features/search/components-old src/features/legal/components \
         src/shared/utils src/components/ui src/hooks src/routes e2e .stryker-tmp/sandbox/src/components
for f in src/features/destinos/components/DestinoGlobe.tsx \
         src/features/destinos/components/DestinoGlobe.pointer.test.tsx \
         src/features/destinos/index.ts src/features/search/useDismiss.ts \
         src/features/search/components-old/Pill.tsx src/features/legal/components/components.test.ts \
         src/components/New.tsx src/components/New.js src/components/New.jsx src/components/New.mjs \
         src/components/New.cjs src/shared/useThing.ts src/shared/utils/user.ts \
         src/components/ui/button.tsx src/hooks/use-mobile.ts src/routes/login.tsx e2e/login.spec.ts \
         .stryker-tmp/sandbox/src/components/Copy.tsx; do
  echo "export const x = 1" > "$f"
done
git mv src/components/Old.tsx src/components/Renamed.tsx
structure "every misplaced new React file is named, and nothing else" \
"  src/components/Committed.tsx — sorted by kind first; it belongs in <domain>/<kind>/ or shared/<kind>/
  src/components/New.cjs — sorted by kind first; it belongs in <domain>/<kind>/ or shared/<kind>/
  src/components/New.js — sorted by kind first; it belongs in <domain>/<kind>/ or shared/<kind>/
  src/components/New.jsx — sorted by kind first; it belongs in <domain>/<kind>/ or shared/<kind>/
  src/components/New.mjs — sorted by kind first; it belongs in <domain>/<kind>/ or shared/<kind>/
  src/components/New.tsx — sorted by kind first; it belongs in <domain>/<kind>/ or shared/<kind>/
  src/components/Renamed.tsx — sorted by kind first; it belongs in <domain>/<kind>/ or shared/<kind>/
  src/features/legal/components/components.test.ts — a test sits beside the file it tests, and nothing here is named components
  src/features/search/useDismiss.ts — loose at the feature root, where only index.* belongs
  src/features/search/components-old/Pill.tsx — components-old/ is not a kind folder (components|hooks|api|queries|schemas|types|utils|stores|test)
  src/shared/useThing.ts — a hook belongs in hooks/ or queries/" 1
N=$((N+1))
first=$(bash "$SG" 2>&1 | grep -m1 -E '^(ship-gate: [0-9]|STRUCTURE)')
case "$first" in
  "ship-gate: "*) PASS=$((PASS+1)); printf '  ok   the file count prints before STRUCTURE\n' ;;
  *) FAIL=$((FAIL+1)); printf '  FAIL the file count prints before STRUCTURE — first was: %s\n' "$first" ;;
esac

echo "ship-gate structure: Express"
structrepo sg_struct_express package.json '{"dependencies":{"express":"5"}}'
git add -A; git commit -qm manifest; git branch develop
mkdir -p src/routes src/expenses/services src/expenses/types
for f in src/routes/expenses.ts src/expenses/services/expenses.ts \
         src/expenses/services/expenses.test.ts src/expenses/expenseService.ts \
         src/expenses/types/models.ts; do
  echo "export const x = 1" > "$f"
done
structure "every misplaced new Express file is named, and nothing else" \
"  src/expenses/expenseService.ts — the kind is in the filename; it belongs in a kind folder
  src/routes/expenses.ts — sorted by kind first; it belongs in <domain>/<kind>/ or shared/<kind>/" 1

echo "ship-gate structure: FastAPI"
structrepo sg_struct_py pyproject.toml '[project]
dependencies = ["fastapi"]'
mkdir -p app/destinos
echo "x = 1" > app/main.py
echo "x = 1" > app/destinos/router.py
git add -A; git commit -qm legacy; git branch develop
echo "y = 2" >> app/destinos/router.py
mkdir -p app/destinos/routers app/routers tests/destinos/routers
for f in app/destinos/public_router.py app/destinos/schemas.py app/destinos/routers/public.py \
         app/destinos/routers/__init__.py app/routers/users.py app/destinos/test_public.py \
         tests/destinos/routers/test_public.py app/destinos/exceptions.py app/destinos/conftest.py \
         app/destinos/public_test.py; do
  echo "x = 1" > "$f"
done
structure "every misplaced new FastAPI file is named, and nothing else" \
"  app/destinos/public_router.py — the kind is in the filename; it belongs in routers/
  app/destinos/conftest.py — tests live under tests/, mirroring the app
  app/destinos/public_test.py — tests live under tests/, mirroring the app
  app/destinos/schemas.py — the kind is in the filename; it belongs in schemas/
  app/destinos/test_public.py — tests live under tests/, mirroring the app
  app/routers/users.py — sorted by kind first; it belongs in <domain>/routers/" 1
printf '[project]\ndependencies = ["django"]\n' > pyproject.toml
structure "a Python project that is not FastAPI is not judged" ok 0

# The gate used to leave before this check when no changed file was source it mutates,
# so a diff of only tests or only .astro files skipped it and passed.
echo "ship-gate structure: a diff with no mutable source"
structrepo sg_struct_tests package.json '{}'
git add -A; git commit -qm manifest; git branch develop
mkdir -p src/features/legal
echo "export const x = 1" > src/features/legal/components.test.ts
structure "a misplaced test alone still fails" \
"  src/features/legal/components.test.ts — a test sits beside the file it tests, and nothing here is named components" 1
rm src/features/legal/components.test.ts
echo "<p>x</p>" > src/features/legal/ProbeLoose.astro
structure "a misplaced .astro alone still fails" \
"  src/features/legal/ProbeLoose.astro — loose at the feature root, where only index.* belongs" 1
rm src/features/legal/ProbeLoose.astro
mkdir -p src/test
echo "export const x = 1" > src/test/flow.test.ts
structure "a well-placed test alone passes" ok 0

# Shadowhawk keeps every test in __tests__/, one folder below the file it tests.
# Judging only the test's own folder failed each new test there and taught --force.
echo "ship-gate structure: __tests__ folders"
structrepo sg_struct_dunder package.json '{}'
git add -A; git commit -qm manifest; git branch develop
mkdir -p src/features/map/utils/__tests__ src/features/map/stores/__tests__
echo "export const x = 1" > src/features/map/utils/place-types.ts
echo "export const x = 1" > src/features/map/utils/__tests__/place-types.test.ts
echo "export const x = 1" > src/features/map/stores/__tests__/gone-store.test.ts
structure "a __tests__ test is judged against the folder above it" \
"  src/features/map/stores/__tests__/gone-store.test.ts — a test sits beside the file it tests, and nothing here is named gone-store" 1
