#!/usr/bin/env bash
[ -n "${SELFTEST_SANDBOX:-}" ] || { echo "$(basename "$0"): run it through scripts/gauntlet-selftest.sh, never on its own" >&2; exit 1; }

echo "ship-gate structure: no stray code outside the trunk's places"
structrepo sg_layout package.json '{}'
echo "GAUNTLET_LAYOUT=''" >> .claude/gauntlet.conf
mkdir -p src/pages apps/web/src
echo "export const x = 1" > src/pages/index.ts
echo '{}' > apps/web/package.json
echo "export const x = 1" > apps/web/src/a.ts
git add -A; git commit -qm trunk; git branch develop; git checkout -qb feature
mkdir -p src/pages/admin src/server/db lib apps/web/lib
for f in src/pages/about.ts src/pages/admin/users.ts src/random.ts src/server/db/schema.ts \
         lib/x.ts apps/web/src/b.ts apps/web/lib/c.ts; do
  echo "export const x = 1" > "$f"
done
echo notes > src/notes.md
S=" — a new place for code"; T="; move it, or add it to GAUNTLET_LAYOUT in .claude/gauntlet.conf"
structure "a new code file where the trunk has no code is a stray, deeper folders are not" \
"  apps/web/lib/c.ts$S (apps/web/lib/)$T
  lib/x.ts$S (lib/)$T
  src/random.ts$S (src/)$T
  src/server/db/schema.ts$S (src/server/)$T" 1

echo "GAUNTLET_LAYOUT='src/server/*, lib/*'" >> .claude/gauntlet.conf
structure "GAUNTLET_LAYOUT opens a place, and Drizzle's db/schema.ts is not a misplaced kind file" \
"  apps/web/lib/c.ts$S (apps/web/lib/)$T
  src/random.ts$S (src/)$T" 1

echo "every list setting takes spaces, commas, | or new lines"
lists=$(cd "$R" && printf 'GAUNTLET_KIND_FOLDERS="components, hooks|api\nutils"\nGAUNTLET_IGNORE_FILES="*.gen.ts,*/ui/*|a.ts"\n' > .claude/gauntlet.conf \
  && bash -c '. "$1/gate-config.sh"; load_gauntlet_conf .claude/gauntlet.conf x; printf "%s;%s" "$GAUNTLET_KIND_FOLDERS" "$GAUNTLET_IGNORE_FILES"' _ "$HERE")
N=$((N+1))
if [ "$lists" = "components|hooks|api|utils;*.gen.ts */ui/* a.ts" ]; then PASS=$((PASS+1)); echo "  ok   regex lists join with |, glob lists with spaces"
else FAIL=$((FAIL+1)); echo "  FAIL list settings — got: $lists"; fi
