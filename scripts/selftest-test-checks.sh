#!/usr/bin/env bash
[ -n "${SELFTEST_SANDBOX:-}" ] || { echo "$(basename "$0"): run it through scripts/gauntlet-selftest.sh, never on its own" >&2; exit 1; }

echo "test files: a checklist from the code under test, and weak assertions blocked"
TC="$TMP/tc"; rm -rf "$TC"; mkdir -p "$TC/scripts" "$TC/skills/testing-best-practices" "$TC/src" "$TC/app/clientes" "$TC/tests/clientes"
cp "$HERE/edit-check.sh" "$HERE/lint-ratchet.mjs" "$HERE/lint-runners.mjs" "$HERE/text-rules.mjs" "$HERE/test-checks.mjs" "$HERE/ratchet-baseline.mjs" "$HERE/gate-config.sh" "$TC/scripts/"
echo x > "$TC/skills/testing-best-practices/SKILL.md"
git -C "$TC" init -q
printf 'export function search(rows, q) {\n  return rows\n    .filter((r) => r.name.includes(q))\n    .sort((a, b) => a.name.localeCompare(b.name))\n    .slice(0, 5);\n}\n' > "$TC/src/search.ts"
printf 'def search(session, q, limit=5):\n    if not q or len(q) > 50:\n        raise ValueError("query too long")\n    return session.query(C).filter(C.name.ilike(q)).order_by(C.name).limit(limit).all()\n' > "$TC/app/clientes/search.py"
(cd "$TC" && node scripts/lint-ratchet.mjs --baseline-new >/dev/null 2>&1)

tc_is() {  # tc_is <label> <want> <got>
  N=$((N+1))
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n       want:\n%s\n       got:\n%s\n' "$1" "$2" "$3"; fi
}
tests_lines() { (cd "$TC" && node scripts/lint-ratchet.mjs --file "$1" 2>&1) | sed -n '/^TESTS/,$p'; }
edit() { printf '{"tool_input":{"file_path":"%s/%s"}}' "$TC" "$1" | CLAUDE_PROJECT_DIR="$TC" bash "$TC/scripts/edit-check.sh" >/dev/null 2>&1; echo $?; }

echo "test('finds', () => { expect(search(rows, 'a')).toEqual([]) })" > "$TC/src/search.test.ts"
tc_is "a JS test gets the checklist of its subject, line by line" \
"TESTS — src/search.ts needs a test for each of these, or the mutation gate will find the gap:
  - two rows tied on the sort key, so a dropped tiebreak fails (src/search.ts:4)
  - more rows than the limit, so a dropped limit fails (src/search.ts:5)
  - a row that must not match, so a dropped filter fails (src/search.ts:3)" "$(tests_lines src/search.test.ts)"

echo "def test_finds(): assert search(s, 'a') == []" > "$TC/tests/clientes/test_search.py"
tc_is "a Python test under tests/ finds its module elsewhere" \
"TESTS — app/clientes/search.py needs a test for each of these, or the mutation gate will find the gap:
  - two rows tied on the sort key, so a dropped tiebreak fails (app/clientes/search.py:4)
  - more rows than the limit, so a dropped limit fails (app/clientes/search.py:4)
  - a row that must not match, so a dropped filter fails (app/clientes/search.py:4)
  - both sides of each comparison: exactly at the boundary and one past it (app/clientes/search.py:2)
  - each side of every && / || on its own: one case where only one side is true (app/clientes/search.py:2)
  - the exact error message or status, not only that it failed (app/clientes/search.py:3)" "$(tests_lines tests/clientes/test_search.py)"

echo "test('x', () => { expect(1).toBe(1) })" > "$TC/src/nothing.test.ts"
tc_is "a test with no subject gets no checklist" "" "$(tests_lines src/nothing.test.ts)"

echo "test('finds', () => { expect(search(rows, 'a')).toBeDefined() })" > "$TC/src/search.test.ts"
tc_is "a new toBeDefined() blocks the write" 2 "$(edit src/search.test.ts)"
echo "test('finds', () => { expect(screen.getByText('Ana')).toBeTruthy() })" > "$TC/src/search.test.ts"
tc_is "a Testing Library query names the exact text, so its presence check passes" 0 "$(edit src/search.test.ts)"
printf 'def test_finds():\n    assert search(s, "a") is not None\n' > "$TC/tests/clientes/test_search.py"
tc_is "a new 'assert x is not None' in pytest blocks the write" 2 "$(edit tests/clientes/test_search.py)"
printf 'def test_finds():\n    assert search(s, "a") == []\n' > "$TC/tests/clientes/test_search.py"
tc_is "an exact assertion passes" 0 "$(edit tests/clientes/test_search.py)"

mkdir -p "$TC/lib/api" "$TC/db/schema" "$TC/features/cart"
printf '{\n  // JSONC, with a glob that looks like a comment end\n  "compilerOptions": { "paths": { "@/*": ["./*"], }, },\n  "include": ["**/*.ts"]\n}\n' > "$TC/tsconfig.json"
for d in lib/api db/schema; do for m in a b c d e f g h; do echo "export const $m = 1" > "$TC/$d/$m.ts"; printf 'import { %s } from "./%s"\n' "$m" "$m" >> "$TC/$d/index.ts"; done; done
printf 'export * from "./cart"\nexport * from "./total"\n' > "$TC/features/cart/index.ts"
echo 'import { api } from "@/lib/api"' > "$TC/src/old.ts"
sed -i 's/ barrel-import//' "$TC/.lint-baseline"
(cd "$TC" && node scripts/lint-ratchet.mjs --baseline-new >/dev/null 2>&1)
tc_is "on upgrade, an old barrel import is debt, not a block" 0 "$(edit src/old.ts)"
printf 'import x from "y"\nimport { api } from "@/lib/api"\n' > "$TC/src/new.ts"
tc_is "a new import of an 8-file index blocks the write" 2 "$(edit src/new.ts)"
tc_is "the block names the line" "  src/new.ts:2  import the file you use, not a folder index that pulls in 8+ files: every test importing it reruns when any of them changes" \
  "$( (cd "$TC" && node scripts/lint-ratchet.mjs --file src/new.ts 2>&1) | grep '^  src/new.ts')"
echo 'import { api } from "../lib/api/index"' > "$TC/src/new.ts"
tc_is "a relative path to the same index blocks too" 2 "$(edit src/new.ts)"
printf 'import type { Api } from "@/lib/api"\nimport { a } from "@/lib/api/a"\nimport { users } from "@/db/schema"\nimport { cart } from "@/features/cart"\n' > "$TC/src/new.ts"
tc_is "a type import, a direct file, drizzle's schema and a small feature index pass" 0 "$(edit src/new.ts)"
echo 'import { b } from "./index"' > "$TC/lib/api/a.ts"
tc_is "a file inside the barrel's own folder passes" 0 "$(edit lib/api/a.ts)"

rm -rf "$TC/skills/testing-best-practices"
tc_is "without the testing skill there is no checklist" "" "$(tests_lines tests/clientes/test_search.py)"

mkdir -p "$TC/skills/testing-best-practices" "$TC/app/auth" "$TC/tests/auth" "$TC/web"
echo x > "$TC/skills/testing-best-practices/SKILL.md"
printf 'class Bad:\n    """never says which half was wrong,\n    or why"""\n    detail = "email or password"\n    # x or y\n' > "$TC/app/auth/errors.py"
echo "export const both = (a, b) => a && b" > "$TC/web/errors.ts"
echo "def test_detail(): assert Bad.detail == 'email or password'" > "$TC/tests/auth/test_errors.py"
tc_is "an 'or' in a docstring, string or comment, or a same-named file in another language, adds nothing" \
  "" "$(tests_lines tests/auth/test_errors.py)"
