#!/usr/bin/env bash
# preflight.sh — everything that must pass before a release.
#
#   bash scripts/preflight.sh
#
# This exists because a release checklist written in prose is a checklist that
# gets skipped under deadline, and every hook bug that reached a published
# version got there the same way: the happy path was tried on a freshly invented
# repo, and nothing else was. Each check below is one of those bugs, turned into
# something that fails out loud.
#
# Exits non-zero on the first failure.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
cd "$ROOT" || exit 1
FAILED=0

step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; FAILED=1; }

step "1. Skill references and length caps"
if node scripts/validate-skills.mjs; then ok "validator"; else bad "validator"; fi

step "2. Behavioural self-tests"
if bash scripts/gauntlet-selftest.sh; then ok "self-tests"; else bad "self-tests"; fi

step "3. Embedded scripts match their source"
# The CLI ships copies of the hook scripts as JS template literals. An edit to a
# script that is not re-embedded publishes the old one, and nothing else notices.
TMP=$(mktemp -d)
node -e "
  import('$ROOT/cli/lib/setup-hook.mjs').then(async (m) => {
    await m.setupHook('$TMP');
  });
" >/dev/null 2>&1
for f in gauntlet.sh ship-gate.sh ship-gate-hook.sh; do
  if [ ! -f "$TMP/.claude/hooks/$f" ]; then
    bad "$f was not installed at all"
  elif cmp -s "$TMP/.claude/hooks/$f" "scripts/$f"; then
    ok "$f is current"
  else
    bad "$f differs from scripts/$f — re-embed it in cli/lib/setup-hook.mjs"
  fi
done
rm -rf "$TMP"

step "4. Detection against real repositories"
# Detection breaks on the shapes real repos have and invented ones do not:
# a delegating root, a package two levels down, two stacks in one tree.
if [ -d "$HOME/projects" ]; then
  OUT=$(bash scripts/gauntlet-survey.sh "$HOME/projects" 2>&1)
  TOTAL=$(printf '%s\n' "$OUT" | tail -n +3 | grep -c .)
  NONE=$(printf '%s\n' "$OUT" | grep -c 'nothing')
  printf '  %s repo(s) surveyed, %s with no gates\n' "$TOTAL" "$NONE"
  printf '%s\n' "$OUT" | grep 'nothing' | sed 's/^/    /'
  ok "survey ran — read the rows above and confirm each is genuinely empty"
else
  printf '  skipped — no ~/projects to survey\n'
fi

step "5. Version claims against the registries"
# A skill that names a version goes stale silently — two react claims were a few
# minors behind and nothing noticed until someone checked by hand.
if node scripts/check-freshness.mjs; then ok "no skill is a major behind"; else bad "a skill teaches a superseded major"; fi

step "6. Version"
V=$(node -p "require('$ROOT/cli/package.json').version")
PUB=$(npm view @spardutti/claude-skills version --prefer-online 2>/dev/null || echo "?")
printf '  local %s · published %s\n' "$V" "$PUB"
if [ "$V" = "$PUB" ]; then
  bad "cli/package.json is not bumped — $V is already published"
else
  ok "version is ahead of the registry"
fi

printf '\n'
if [ "$FAILED" = 0 ]; then
  echo "preflight: PASS — safe to publish"
else
  echo "preflight: FAIL — fix the above before publishing"
fi
exit $FAILED
