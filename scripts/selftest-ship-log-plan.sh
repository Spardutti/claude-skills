#!/usr/bin/env bash
[ -n "${SELFTEST_SANDBOX:-}" ] || { echo "$(basename "$0"): run it through scripts/gauntlet-selftest.sh, never on its own" >&2; exit 1; }

echo "the /ship log: registry marks and edit-rule blocks"
newrepo sg_plan
mkdir -p "$HOME/.claude"; echo 'GAUNTLET_SHIP_LOG=1' > "$HOME/.claude/gauntlet.conf"
git checkout -qb feat/p
printf '# Plan\n\n## Registry\n\n- `aiming`: reuse — extends AimStrategy\n- queue: skip — no jobs here\n' > PLAN.md
BLOCKS="$R/.claude/edit-blocks.jsonl"
printf '{"ts":"2020-01-01T00:00:00Z","branch":"feat/p","file":"old.sh","rules":["no-file-header"]}\n' > "$BLOCKS"
bash "$HERE/ship-mark.sh" begin
rm PLAN.md
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '{"ts":"%s","branch":"feat/p","file":"a.sh","rules":["no-file-header"]}\n' "$NOW" >> "$BLOCKS"
printf '{"ts":"%s","branch":"feat/other","file":"b.sh","rules":["x"]}\n' "$NOW" >> "$BLOCKS"
node "$SL" pr 78 >/dev/null
PLANLOG="$SLOGS/sg_plan_${DAY}_pr78.json"
sl_is "the plan's registry marks are kept after PLAN.md is deleted" "$PLANLOG" \
  'JSON.stringify(r.registry) === JSON.stringify({ aiming: "reuse", queue: "skip" })'
sl_is "only this branch's rule blocks during the ship are kept" "$PLANLOG" \
  'r.rules.length === 1 && r.rules[0].file === "a.sh" && r.rules[0].rules[0] === "no-file-header"'

git checkout -qb feat/none; bash "$HERE/ship-mark.sh" begin; node "$SL" pr 79 >/dev/null
sl_is "a ship with no PLAN.md logs no registry and no rules" "$SLOGS/sg_plan_${DAY}_pr79.json" \
  'r.registry === null && Array.isArray(r.rules) && r.rules.length === 0'
rm -rf "$HOME/.claude/gauntlet.conf" "$SLOGS"
