#!/usr/bin/env bash
# Smoke tests for cli/bin/cli.mjs, which had no coverage at all.
# Sourced by gauntlet-selftest.sh; shares its $HERE, $TMP, $N, $PASS, $FAIL.
#
# main() is 270 lines of orchestration and nothing exercised it, so a refactor
# could break the installer and every test would still pass. --sync is the one
# non-interactive path through fetch, install, prune and manifest write, and
# --local reads the catalog from this working copy instead of GitHub, so these
# run offline against the code being changed.
#
# Not a substitute for the interactive path. It is the floor that makes moving
# code out of main() something other than a guess.

CLI="$HERE/../cli/bin/cli.mjs"
REPO="$HERE/.."

cli_run() {  # cli_run <project dir> [extra args...]
  ( cd "$1" && node "$CLI" --local="$REPO" "${@:2}" 2>&1 )
}

cli_case() {  # cli_case <label> <expected substring> <output>
  N=$((N+1))
  case "$3" in
    *"$2"*) PASS=$((PASS+1)); printf '  ok   %s\n' "$1" ;;
    *) FAIL=$((FAIL+1)); printf '  FAIL %s — want ~ %s, got: %s\n' "$1" "$2" "$(printf '%s' "$3" | tr '\n' ' ' | cut -c1-220)" ;;
  esac
}

# --sync never reaches runPostInstall, which is the interactive half and the
# part just lifted out of main(). Importing it resolves every one of its imports
# and proves the export cli.mjs calls exists — the failure mode of moving code
# between modules, and invisible to --sync.
echo "cli modules load"
N=$((N+1))
OUT=$(node -e "
  Promise.all([
    import('$REPO/cli/lib/post-install.mjs'),
    import('$REPO/cli/lib/setup-hook.mjs'),
  ]).then(([p]) => console.log(typeof p.runPostInstall))
   .catch((e) => console.log('ERR ' + e.message));
" 2>&1)
if [ "$OUT" = "function" ]; then
  PASS=$((PASS+1)); printf '  ok   %s\n' "post-install.mjs loads and exports runPostInstall"
else
  FAIL=$((FAIL+1)); printf '  FAIL %s — got: %s\n' "post-install.mjs loads and exports runPostInstall" "$OUT"
fi

N=$((N+1))
if node --check "$CLI" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ok   %s\n' "cli.mjs parses"
else
  FAIL=$((FAIL+1)); printf '  FAIL %s\n' "cli.mjs parses"
fi

echo "cli --sync"
CP="$TMP/cli_sync"; rm -rf "$CP"; mkdir -p "$CP/.claude"

# No manifest: --sync must say so rather than installing a guess.
cli_case "an empty project is told to run without --sync" \
  "Nothing to sync" "$(cli_run "$CP" --sync)"

# A manifest naming one real skill and one real command is the whole path:
# read the catalog, install both, pull in the agents the command declares,
# rewrite the manifest.
cat > "$CP/.claude/.claude-skills.json" <<'J'
{ "catalogVersion": "0.0.0", "skills": ["sql"], "commands": ["ship.md"], "agents": [] }
J
OUT=$(cli_run "$CP" --sync)
cli_case "a manifest syncs to the catalog version" "Synced to catalog v" "$OUT"

have_file() {  # have_file <label> <path>
  N=$((N+1))
  if [ -s "$2" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s — %s missing or empty\n' "$1" "$2"; fi
}

have_file "the named skill is installed"    "$CP/.claude/skills/sql/SKILL.md"
have_file "its reference files come too"    "$CP/.claude/skills/sql/INDEXING.md"
have_file "the named command is installed"  "$CP/.claude/commands/ship.md"
# ship.md declares gauntlet-skills in requires-agents; installing the command
# has to bring it, or /ship launches an agent that is not there.
have_file "the agents it requires arrive"   "$CP/.claude/agents/gauntlet-skills.md"

# --sync does NOT install or refresh the hooks — only the interactive path calls
# setupHook. Asserted so the boundary is deliberate rather than assumed: a
# session that "just syncs" after a hook fix keeps the old hooks, and the fix
# reaches it on the next full run instead.
N=$((N+1))
if [ -e "$CP/.claude/hooks/ship-gate.sh" ]; then
  FAIL=$((FAIL+1)); printf '  FAIL %s\n' "--sync leaves the hooks alone"
else
  PASS=$((PASS+1)); printf '  ok   %s\n' "--sync leaves the hooks alone"
fi

N=$((N+1))
if grep -q '"catalogVersion"' "$CP/.claude/.claude-skills.json" \
   && ! grep -q '"0.0.0"' "$CP/.claude/.claude-skills.json"; then
  PASS=$((PASS+1)); printf '  ok   %s\n' "the manifest is rewritten with the new version"
else
  FAIL=$((FAIL+1)); printf '  FAIL %s\n' "the manifest is rewritten with the new version"
fi

# An entry the catalog no longer has is pruned rather than left on disk.
mkdir -p "$CP/.claude/skills/gone-skill"
printf -- '---\nname: gone-skill\n---\n' > "$CP/.claude/skills/gone-skill/SKILL.md"
node -e "
  const f='$CP/.claude/.claude-skills.json', fs=require('fs');
  const m=JSON.parse(fs.readFileSync(f,'utf8'));
  m.skills.push('gone-skill');
  fs.writeFileSync(f, JSON.stringify(m));
"
OUT=$(cli_run "$CP" --sync)
cli_case "an item dropped upstream is pruned" "Pruned 1 item" "$OUT"
N=$((N+1))
if [ -d "$CP/.claude/skills/gone-skill" ]; then
  FAIL=$((FAIL+1)); printf '  FAIL %s\n' "and its directory is gone"
else
  PASS=$((PASS+1)); printf '  ok   %s\n' "and its directory is gone"
fi
