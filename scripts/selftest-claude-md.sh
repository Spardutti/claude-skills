#!/usr/bin/env bash
# The blocks the installer writes into a project's CLAUDE.md. Sourced by gauntlet-selftest.sh.
# An agent asked to write a custom skill did not know it had to be listed under "custom".

echo "CLAUDE.md blocks"
newrepo claudemd
printf '# Mine\n\nKeep this.\n' > CLAUDE.md
for _ in 1 2; do
  node -e "import('$HERE/../cli/lib/setup-claude-md.mjs').then((m) => m.setupClaudeMd('$PWD'))" >/dev/null 2>&1
done
md_has() {  # md_has <label> <count> <fixed string>
  N=$((N+1)); got=$(grep -cF -- "$3" CLAUDE.md)
  if [ "$got" = "$2" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s — want %s, got %s\n' "$1" "$2" "$got"; fi
}
md_has "the tooling block is written once, even on a rerun" 1 "<!-- claude-skills:tooling:start -->"
md_has "it says custom skills go under \"custom\""           1 'to `"custom"` in `.claude/.claude-skills.json`'
md_has "it names GAUNTLET_BASE"                             1 'GAUNTLET_BASE'
md_has "the user's own text survives"                        1 "Keep this."
