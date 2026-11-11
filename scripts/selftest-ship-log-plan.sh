#!/usr/bin/env bash
[ -n "${SELFTEST_SANDBOX:-}" ] || { echo "$(basename "$0"): run it through scripts/gauntlet-selftest.sh, never on its own" >&2; exit 1; }

echo "the /ship log: registry marks and edit-rule blocks"
newrepo sg_plan
mkdir -p "$HOME/.claude"; echo 'GAUNTLET_SHIP_LOG=1' > "$HOME/.claude/gauntlet.conf"
git checkout -qb feat/p
printf '# Plan\n\n## Registry\n\n- `aiming`: reuse — extends AimStrategy\n- queue: skip — no jobs here\n' > PLAN.md
BLOCKS="$R/.claude/edit-blocks.jsonl"
printf '{"ts":"2020-01-01T00:00:00Z","branch":"feat/p","file":"old.sh","rules":["no-file-header"]}\n' > "$BLOCKS"
printf '{"ts":"%s","branch":"feat/p","file":"written.sh","rules":["no-file-header"]}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$BLOCKS"
sleep 1  # log timestamps are whole seconds, and this block must fall before the ship starts
bash "$HERE/ship-mark.sh" begin
rm PLAN.md
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '{"ts":"%s","branch":"feat/p","file":"a.sh","rules":["no-file-header"]}\n' "$NOW" >> "$BLOCKS"
printf '{"ts":"%s","branch":"feat/other","file":"b.sh","rules":["x"]}\n' "$NOW" >> "$BLOCKS"
node "$SL" pr 78 >/dev/null
PLANLOG="$SLOGS/sg_plan_${DAY}_pr78.json"
sl_is "the plan's registry marks are kept after PLAN.md is deleted" "$PLANLOG" \
  'JSON.stringify(r.registry) === JSON.stringify({ aiming: "reuse", queue: "skip" })'
sl_is "only this branch's rule blocks since it was created are kept, from before /ship too" "$PLANLOG" \
  'r.rules.map((b) => b.file).join() === "written.sh,a.sh" && r.rules[0].rules[0] === "no-file-header"'

git checkout -qb feat/oldplan; printf '# Plan\n\n## Build order\n' > PLAN.md; bash "$HERE/ship-mark.sh" begin; rm PLAN.md; node "$SL" pr 80 >/dev/null
sl_is "a plan with no Registry section logs not checked, not an empty list of marks" "$SLOGS/sg_plan_${DAY}_pr80.json" 'r.registry === null'

git checkout -qb feat/noreflog --no-track; rm -f ".git/logs/refs/heads/feat/noreflog"; bash "$HERE/ship-mark.sh" begin
printf '{"ts":"2020-01-01T00:00:00Z","branch":"feat/noreflog","file":"old.sh","rules":["x"]}\n' >> "$BLOCKS"; node "$SL" pr 81 >/dev/null
sl_is "a branch with no reflog counts from the ship's start" "$SLOGS/sg_plan_${DAY}_pr81.json" 'r.branchStarted === null && r.rules.length === 0'

git checkout -qb feat/none; bash "$HERE/ship-mark.sh" begin; node "$SL" pr 79 >/dev/null
sl_is "a ship with no PLAN.md logs no registry and no rules" "$SLOGS/sg_plan_${DAY}_pr79.json" \
  'r.registry === null && Array.isArray(r.rules) && r.rules.length === 0'
rm -rf "$HOME/.claude/gauntlet.conf" "$SLOGS"
