#!/usr/bin/env bash
[ -n "${SELFTEST_SANDBOX:-}" ] || { echo "$(basename "$0"): run it through scripts/gauntlet-selftest.sh, never on its own" >&2; exit 1; }

echo "cli --sync: required commands and new items"
CR="$TMP/cli_requires"; rm -rf "$CR"; mkdir -p "$CR/.claude"
printf '{ "catalogVersion": "2.59.0", "skills": [], "commands": ["plan-feature.md"], "agents": [] }\n' > "$CR/.claude/.claude-skills.json"
OUT=$(cli_run "$CR" --sync)
cli_case "a command another one requires is added by a sync" "Added /registry" "$OUT"
have_file "and installed" "$CR/.claude/commands/registry.md"
N=$((N+1))
if grep -q '"registry.md"' "$CR/.claude/.claude-skills.json"; then PASS=$((PASS+1)); printf '  ok   %s\n' "and recorded, so the next sync keeps it"
else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "and recorded, so the next sync keeps it"; fi
N=$((N+1))
case "$OUT" in *" new "*) FAIL=$((FAIL+1)); printf '  FAIL %s — %s\n' "an old manifest is not flooded with every catalog item as new" "$OUT" ;;
  *) PASS=$((PASS+1)); printf '  ok   %s\n' "an old manifest is not flooded with every catalog item as new" ;; esac

node -e "
  const f='$CR/.claude/.claude-skills.json', fs=require('fs');
  const m=JSON.parse(fs.readFileSync(f,'utf8'));
  m.known=m.known.filter((k)=>k!=='handoff.md' && k!=='registry.md');
  fs.writeFileSync(f, JSON.stringify(m));
"
OUT=$(cli_run "$CR" --sync)
cli_case "a command added to the catalog since the last sync is named" "new /handoff" "$OUT"
N=$((N+1))
case "$OUT" in *"new /registry"*) FAIL=$((FAIL+1)); printf '  FAIL %s\n' "one already installed is not named as new" ;;
  *) PASS=$((PASS+1)); printf '  ok   %s\n' "one already installed is not named as new" ;; esac
OUT=$(cli_run "$CR" --sync)
N=$((N+1))
case "$OUT" in *"new /handoff"*) FAIL=$((FAIL+1)); printf '  FAIL %s\n' "and it is named once, not on every sync" ;;
  *) PASS=$((PASS+1)); printf '  ok   %s\n' "and it is named once, not on every sync" ;; esac

for f in "$HERE"/../commands/*.md; do
  for c in $(sed -n 's/^requires-commands:[[:space:]]*\[\(.*\)\]/\1/p' "$f" | tr -d ' ' | tr ',' ' '); do
    N=$((N+1))
    if [ -f "$HERE/../commands/$c.md" ]; then PASS=$((PASS+1)); printf '  ok   %s requires /%s, which exists\n' "$(basename "$f")" "$c"
    else FAIL=$((FAIL+1)); printf '  FAIL %s requires /%s, which is not in commands/\n' "$(basename "$f")" "$c"; fi
  done
done
