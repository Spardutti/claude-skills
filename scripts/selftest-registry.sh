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
printf 'name: shapes\nsummary: what a skill looks like\ntriggers: [shape]\nlocation: src/sim/\nextend_by: add a `Shape`\n' > src/sim/shapes.registry.yaml
printf 'class_name Shape\n' > src/sim/shape.gd
rg "a location can be one file, beside another system in its folder" 0 "" -- --stale
rg "two entries in one folder are both read" 0 "== src/sim/shapes.registry.yaml ==" --
printf 'class_name Aim\nstatic func first(): pass\n' > src/sim/aim.gd
printf 'name: aim-rules\nsummary: s\ntriggers: [nearest]\nlocation: src/sim/aim.gd\nextend_by: call `Aim.first`\n' > src/sim/aim.registry.yaml
rg "a method named with its owner is found where it is defined" 0 "" -- --stale
printf '## Registry\n- aiming-methods: skip\n- inventory: skip\n- shapes: skip\n- aim-rules: reuse\n' > PLAN.md
printf 'func cast(enemies):\n\tvar first = enemies[0]\n' > src/sim/fire.gd
rg "a plain word of the same name is not use" 1 "aim-rules: marked reuse, but no stub uses Aim.first" -- --plan PLAN.md src/sim/fire.gd
printf 'func cast(enemies):\n\treturn Aim.first(enemies)\n' > src/sim/fire.gd
rg "a call through the owner is use; only the skipped aiming entry still asks" 0 "registry ASK aiming-methods" -- --plan PLAN.md src/sim/fire.gd
printf 'name: aim-rules\nsummary: s\nlocation: src/sim/aim.gd\nextend_by: call `first`\n' > src/sim/aim.registry.yaml
rg "a bare common word is stale" 1 "`first` is too common a word to prove use" -- --stale
printf 'name: aim-rules\nsummary: s\ntriggers: [chill]\nlocation: src/sim/aim.gd\nextend_by: apply through `EnemyState.chill`\n' > src/sim/aim.registry.yaml
printf 'class_name EnemyState\nfunc chill(s): pass\n' >> src/sim/aim.gd
rg "a type with its method passes the stale check" 0 "" -- --stale
printf 'func cast(e: EnemyState):\n\treturn e.hp\n' > src/sim/fire.gd
rg "naming the type without calling the method is not use" 1 "aim-rules: marked reuse, but no stub uses EnemyState.chill" -- --plan PLAN.md src/sim/fire.gd
printf 'func cast(e: EnemyState):\n\te.chill(2)\n' > src/sim/fire.gd
rg "the type named and its method called on a value is use" 0 "registry ok" -- --plan PLAN.md src/sim/fire.gd
rm -rf src/sim PLAN.md
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
printf 'name: inventory\nsummary: C# slots for a target\ntriggers: [item]\nlocation: src/inventory/\nextend_by: add an `ItemSlot`\n' > src/inventory/inventory.registry.yaml
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

mkdir -p src/events src/mcp scripts
ev() { printf 'name: events\nsummary: how a record is written\n%blocation: src/events/\nextend_by: call `createEvent`\ndoes: [%s]\nallowed: [%s]\n' "$1" "$2" "$3" > src/events/events.registry.yaml; }
ev 'triggers: [event]\n' 'insert(events)' scripts/seed.ts
printf 'export const createEvent = () => db.insert(events);\n' > src/events/save.ts
printf 'import x from "y";\nexport const tool = () => db.insert(events).values(x);\n' > src/mcp/tools.ts
printf 'export const ok = () => createEvent();\n' > src/mcp/ok.ts
printf 'db.bulkInsert(events);\n' > src/mcp/bulk.ts
printf 'db.insert(events);\n' > scripts/seed.ts
N=$((N+1))
out=$(node "$RG" --eval 2>&1); rc=$?
want='registry eval aiming-methods: skipped, no does
registry SUSPECT events src/mcp/tools.ts:2 insert(events)
registry eval inventory: skipped, no does'
if [ "$rc" = 0 ] && [ "$out" = "$want" ]; then PASS=$((PASS+1)); echo "  ok   eval names each file and line doing an entry's job outside its folder, and nothing else"
else FAIL=$((FAIL+1)); printf '  FAIL eval names each file and line doing an entry'"'"'s job outside its folder — exit %s:\n%s\n' "$rc" "$out"; fi
ev 'triggers: [event]\n' 'insert(events)' scripts/
N=$((N+1))
out=$(node "$RG" --eval 2>&1 | grep SUSPECT)
if [ "$out" = "registry SUSPECT events src/mcp/tools.ts:2 insert(events)" ]; then PASS=$((PASS+1)); echo "  ok   an allowed folder covers its files and no others"
else FAIL=$((FAIL+1)); printf '  FAIL an allowed folder covers its files and no others:\n%s\n' "$out"; fi
ev 'triggers: [event]\n' 'insert(events)' scripts
N=$((N+1))
out=$(node "$RG" --eval 2>&1 | grep -c 'SUSPECT events scripts/seed.ts')
if [ "$out" = 1 ]; then PASS=$((PASS+1)); echo "  ok   an allowed name with no slash is not a folder"
else FAIL=$((FAIL+1)); printf '  FAIL an allowed name with no slash is not a folder: %s\n' "$out"; fi
ev 'triggers: [event]\n' 'insert(events)' scripts/seed.ts
rm src/mcp/tools.ts
rg "eval says when nothing skips an entry" 0 "registry eval events: nothing outside src/events/ does its job" -- --eval
ev 'triggers: [event]\n' 'insert(users)' scripts/seed.ts
rg "a does call missing from its folder is stale" 1 "does insert(users) is not found in src/events/" -- --stale
ev 'triggers: [event]\n' 'insert(events)' scripts/gone.ts
rg "an allowed file that is gone is stale" 1 "allowed scripts/gone.ts not found" -- --stale
ev 'triggers: [event]\n' 'insert(events)' scripts/seed.ts; echo 'rules: [no-raw-insert]' >> src/events/events.registry.yaml
echo '{"lessons":[{"id":"no-raw-insert","files":"x","message":"m"}]}' > .edit-rules.json
rg "a rule the entry names may be a lesson" 0 "" -- --stale
echo '{"text":[]}' > .edit-rules.json
rg "a rule the entry names that is gone is stale" 1 "rule no-raw-insert not found in .edit-rules.json" -- --stale
rm .edit-rules.json
ev '' 'insert(events)' scripts/seed.ts
rg "an entry with no triggers is stale" 1 "no triggers" -- --stale
rm -rf src/events src/mcp scripts

rg "an unknown argument is an error" 2 "usage" -- --nope
