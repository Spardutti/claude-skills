#!/usr/bin/env bash
[ -n "${SELFTEST_SANDBOX:-}" ] || { echo "$(basename "$0"): run it through scripts/gauntlet-selftest.sh, never on its own" >&2; exit 1; }

echo "the registry of reusable systems"
newrepo registry
RG="$HERE/registry.mjs"
rg() {  # rg <label> <expected exit> <expected substring, empty for silence> -- <args>
  local label="$1" want="$2" sub="$3"; shift 4
  N=$((N+1))
  out=$(node "$RG" "$@" 2>&1); rc=$?
  ok=1
  [ "$rc" = "$want" ] || ok=0
  if [ -z "$sub" ]; then [ -z "$out" ] || ok=0; else case "$out" in *"$sub"*) ;; *) ok=0 ;; esac; fi
  if [ $ok = 1 ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$label"
  else FAIL=$((FAIL+1)); printf '  FAIL %s — exit %s: %s\n' "$label" "$rc" "$out"; fi
}

rg "a project with no entries says so" 0 "registry none" --
rg "a plan in a project with no entries passes" 0 "registry ok — no entries" -- --plan PLAN.md

mkdir -p src/combat/aiming src/inventory src/skills
cat > src/combat/aiming/aiming.registry.yaml <<'Y'
name: aiming-methods
summary: how skills pick a target  # read by /plan-feature
triggers: [aim, target, "nearest", random]
location: src/combat/aiming/
extend_by: implement AimStrategy, register in AimRegistry
example: NearestEnemyAim.ts
never: write targeting logic inside a skill
Y
printf 'name: inventory\nsummary: what a unit carries\ntriggers: [item, slot]\nlocation: src/inventory/\nextend_by: add an `ItemSlot`\n' > src/inventory/inventory.registry.yaml
printf 'export type ItemSlot = string;\n' > src/inventory/slot.ts
printf 'export interface AimStrategy {}\nexport const AimRegistry = {};\n' > src/combat/aiming/AimStrategy.ts
for k in Nearest Random Furthest; do printf 'export class %sEnemyAim {}\n' "$k" > "src/combat/aiming/${k}EnemyAim.ts"; done
printf 'export function cast() { return "target"; }\n' > src/skills/old.ts
git add -A; git commit -qm registry

rg "every entry is printed in full" 0 "never: write targeting logic inside a skill" --
rg "both entries are printed" 0 "== src/inventory/inventory.registry.yaml ==" --
rg "a plan with no notes file fails" 1 "PLAN.md not found" -- --plan PLAN.md

printf '# Plan notes\n\n## Registry\n- aiming-methods: reuse\n\n## Splits\n- inventory: skip\n' > PLAN.md
printf 'export class Fire {}\n' > src/skills/fire.ts
rg "an entry missing from ## Registry fails, even if named in another section" 1 "inventory: missing from ## Registry" -- --plan PLAN.md src/skills/fire.ts
printf '## Registry\n- aiming-methods: reuse\n- inventory: skip — no items\n- loot: skip\n' > PLAN.md
rg "an entry that does not exist fails" 1 "loot: no such entry" -- --plan PLAN.md src/skills/fire.ts
printf '## Registry\n- `aiming-methods`: reuse\n- inventory: skip — no items\n' > PLAN.md
rg "reuse with no stub using an extend_by name fails" 1 "marked reuse, but no stub uses AimStrategy, AimRegistry" -- --plan PLAN.md src/skills/fire.ts
printf 'import { AimStrategy } from "@/combat/aiming/AimStrategy";\nexport class Fire {}\n' > src/skills/fire.ts
rg "reuse passes when a stub uses the name, whatever the import path" 0 "registry ok" -- --plan PLAN.md src/skills/fire.ts
rg "an absolute stub path works too" 0 "registry ok" -- --plan PLAN.md "$PWD/src/skills/fire.ts"
printf '## Registry\n- aiming-methods: skip — not aiming\n- inventory: skip\n' > PLAN.md
printf 'export class Fire { pick() { return "nearest target"; } }\n' > src/skills/fire.ts
rg "a skip whose stubs use its triggers asks the user, without failing" 0 "aiming-methods: skipped, but the stubs mention target, nearest" -- --plan PLAN.md src/skills/fire.ts
printf 'export function cast() { return "target"; }\nexport const heal = 1;\n' > src/skills/old.ts
printf 'export class Fire {}\n' > src/skills/fire.ts
rg "an extended file is judged on its added lines, not its old code" 0 "registry ok" -- --plan PLAN.md src/skills/old.ts src/skills/fire.ts
printf 'export const targeting = aiming;\n' > src/skills/fire.ts
rg "triggers match whole words only" 0 "registry ok" -- --plan PLAN.md src/skills/fire.ts
printf '## Registry\n* aiming-methods: skip\n* inventory: skip\n' > PLAN.md
rg "a star bullet counts as a mark" 0 "registry ok" -- --plan PLAN.md src/skills/fire.ts
N=$((N+1))
out=$(cd src && node "$RG" --plan ../PLAN.md skills/fire.ts 2>&1)
case "$out" in "registry ok") PASS=$((PASS+1)); echo "  ok   paths are read from where the command runs, not the repo root" ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL paths are read from where the command runs, not the repo root — $out" ;; esac
git checkout -q -- src/skills/old.ts; rm -f src/skills/fire.ts PLAN.md


rg "a current registry is silent" 0 "" -- --stale
mkdir -p src/sim; printf 'class_name Aim\nenum Rule { NEAREST }\n' > src/sim/aim.gd
printf 'name: aim-rules\nsummary: how a skill picks what to hit\ntriggers: [nearest, enemy]\nlocation: src/sim/aim.gd\nextend_by: add a `Rule` to `Aim`\n' > src/sim/aim.registry.yaml
printf 'name: shapes\nsummary: what a skill looks like\nlocation: src/sim/\nextend_by: add a `Shape`\n' > src/sim/shapes.registry.yaml
printf 'class_name Shape\n' > src/sim/shape.gd
rg "a location can be one file, beside another system in its folder" 0 "" -- --stale
rg "two entries in one folder are both read" 0 "== src/sim/shapes.registry.yaml ==" --
rm -rf src/sim
sed -i 's/AimStrategy/AimPolicy/' src/combat/aiming/AimStrategy.ts
rg "a renamed extend_by symbol is stale" 1 "aiming/aiming.registry.yaml: AimStrategy from extend_by is not found in src/combat/aiming/" -- --stale
rg "the plan's listing names a stale entry after the entries" 1 "registry stale src/combat/aiming/aiming.registry.yaml" -- 
git checkout -q -- src/combat/aiming/AimStrategy.ts
printf 'name: inventory\nsummary: s\nlocation: src/gone/\nextend_by: add `ItemSlot`\n' > src/inventory/inventory.registry.yaml
rg "a location that is gone is stale" 1 "location src/gone/ not found" -- --stale
printf 'name: aiming-methods\nsummary: s\nlocation: src/inventory/\nextend_by: add an item\nexample: Nope.ts\n' > src/inventory/inventory.registry.yaml
rg "an extend_by with no symbol is stale" 1 "extend_by names no symbol" -- --stale
rg "a missing example is stale" 1 "example Nope.ts not found" -- --stale
rg "a name used twice is stale" 1 "name aiming-methods is used twice" -- --stale
printf 'location: src/inventory/\n' > src/inventory/inventory.registry.yaml
rg "missing fields are stale" 1 "no summary" -- --stale
printf 'name: inventory\nsummary: C# slots for a target\nlocation: src/inventory/\nextend_by: add an `ItemSlot`\n' > src/inventory/inventory.registry.yaml
rg "a # inside a value is kept" 0 "summary: C# slots for a target" -- 
printf 'name: inventory\nsummary: s\ntriggers:\n  - item\nlocation: src/inventory/\nextend_by: |\n  add an ItemSlot\n' > src/inventory/inventory.registry.yaml
rg "a block list is stale, not a trigger that matches everything" 1 "write lists on one line" -- --stale
rg "a block value is stale" 1 "extend_by must sit on one line" -- --stale
printf '## Registry\n- aiming-methods: reuse\n- inventory: skip\n' > PLAN.md
printf 'import { AimStrategy } from "x";\n' > src/skills/fire.ts
rg "an empty trigger list never asks" 0 "registry ok" -- --plan PLAN.md src/skills/fire.ts
rm -f src/skills/fire.ts PLAN.md
printf 'name: aim methods\nsummary: s\nlocation: src/inventory/\nextend_by: add an `ItemSlot`\n' > src/inventory/inventory.registry.yaml
rg "a name a plan cannot mark is stale" 1 "name aim methods may hold only" -- --stale
git checkout -q -- src/inventory/inventory.registry.yaml

rg "an unknown argument is an error" 2 "usage" -- --nope
