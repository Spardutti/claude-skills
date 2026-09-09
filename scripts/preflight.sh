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

step "3. The published package installs the real scripts"
# The hook scripts used to be pasted into setup-hook.mjs as template literals,
# and this step compared the two copies. They are read from disk now, so that
# drift cannot happen — but a new one can: `files` and the prepack copy decide
# what reaches the tarball, and a script that is in scripts/ and not in the
# package installs fine from a clone and is missing for every real user.
#
# Running from the repo cannot see that, because the reader falls back to
# scripts/. So this packs for real, installs from the tarball, and compares.
TMP=$(mktemp -d)
# The folder is the ARGUMENT, not --prefix: --prefix sets the install prefix and
# leaves npm packing the current directory, which from the repo root is the
# private dev-tooling package and fails with "must have name and version".
# `npm pack <folder>` is the same form the publish workflow uses.
if ! npm pack "$ROOT/cli" --pack-destination "$TMP" >/dev/null 2>&1; then
  bad "npm pack failed"
else
  tar -xzf "$TMP"/*.tgz -C "$TMP"
  node -e "
    import('$TMP/package/lib/setup-hook.mjs').then((m) => m.setupHook('$TMP/target'));
  " >/dev/null 2>&1
  for f in gauntlet.sh ship-gate.sh ship-gate-hook.sh version-check.sh \
           skill-gate.sh skill-gate-automark.sh skill-application-gate.sh; do
    if [ ! -f "$TMP/package/hooks/$f" ]; then
      bad "$f is not in the tarball — add it to cli/package.json prepack"
    elif [ ! -x "$TMP/target/.claude/hooks/$f" ]; then
      bad "$f was not installed executable from the package"
    elif cmp -s "$TMP/target/.claude/hooks/$f" "scripts/$f"; then
      ok "$f ships and installs from the package"
    else
      bad "$f installs from the package but differs from scripts/$f"
    fi
  done
fi
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
