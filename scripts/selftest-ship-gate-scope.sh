#!/usr/bin/env bash
# ship-gate cases for what it refuses to judge and what moves the receipt key.
# Sourced by gauntlet-selftest.sh; shares its $HERE, $TMP, $N, $PASS, $FAIL.

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

# A release bumps a version and writes a changelog, and both used to throw the
# receipt away — so the gate demanded a full mutation pass at the exact moment a
# tag was going out, to prove nothing about the two files that moved. No check
# in this gate opens either one. The key has to ignore them, and still has to
# move the instant real code changes, or it is not a key at all.
# keycmp <label> <key a> <key b> <same|differ>
keycmp() {
  N=$((N+1))
  ok=0
  [ "$4" = same ] && [ "$2" = "$3" ] && ok=1
  [ "$4" = differ ] && [ "$2" != "$3" ] && ok=1
  if [ $ok = 1 ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n       want the keys to %s\n       a = %s\n       b = %s\n' "$1" "$4" "$2" "$3"
  fi
}

echo "ship-gate receipt key scope"
newrepo sg_key
echo "const a=1" > src.ts
k1=$(bash "$SG" --key)
printf '{"version":"8.3.0"}\n' > package.json
keycmp "a version bump does not invalidate the receipt" "$k1" "$(bash "$SG" --key)" same
echo "# v8.3.0" > CHANGELOG.md
keycmp "nor does a changelog entry"                     "$k1" "$(bash "$SG" --key)" same
echo "const a=2" > src.ts
k2=$(bash "$SG" --key)
keycmp "editing the code does invalidate it"            "$k1" "$k2" differ
# An unknown extension is what UNPROVEN is a verdict about, so it cannot be
# dropped from the key the way an ignored one is.
echo "pub fn main() {}" > main.zig
keycmp "so does an extension the gate cannot place"     "$k2" "$(bash "$SG" --key)" differ