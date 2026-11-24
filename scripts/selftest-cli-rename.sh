#!/usr/bin/env bash
[ -n "${SELFTEST_SANDBOX:-}" ] || { echo "$(basename "$0"): run it through scripts/gauntlet-selftest.sh, never on its own" >&2; exit 1; }

echo "cli --sync: a renamed command"
CN="$TMP/cli_rename"; rm -rf "$CN"; mkdir -p "$CN/.claude/commands"
printf '{ "catalogVersion": "2.77.0", "skills": [], "commands": ["ship.md"], "agents": [] }\n' > "$CN/.claude/.claude-skills.json"
printf 'old\n' > "$CN/.claude/commands/ship.md"
cli_run "$CN" --sync >/dev/null
have_file "/ship becomes /deliver on sync" "$CN/.claude/commands/deliver.md"
N=$((N+1))
if [ ! -e "$CN/.claude/commands/ship.md" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "the old ship.md is deleted, so it no longer clashes"
else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "the old ship.md is deleted, so it no longer clashes"; fi
N=$((N+1))
if grep -q '"deliver.md"' "$CN/.claude/.claude-skills.json" && ! grep -q '"ship.md"' "$CN/.claude/.claude-skills.json"; then
  PASS=$((PASS+1)); printf '  ok   %s\n' "the manifest records deliver.md, not ship.md"
else FAIL=$((FAIL+1)); printf '  FAIL %s — %s\n' "the manifest records deliver.md, not ship.md" "$(cat "$CN/.claude/.claude-skills.json")"; fi
