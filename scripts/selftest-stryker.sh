#!/usr/bin/env bash
# Cases for the CLI scaffolding Stryker into a project that has none.
# Sourced by gauntlet-selftest.sh; shares its $HERE, $TMP, $N, $PASS, $FAIL.

echo "stryker scaffold"
newrepo strscaf
printf '{"name":"app"}\n' > package.json
printf 'node_modules\n' > .gitignore
node -e "
  import('$HERE/../cli/lib/scaffold-stryker.mjs').then(async (m) => {
    const r = await m.scaffoldStryker('$PWD', '');
    console.log(JSON.stringify(r));
  });
" > "$TMP/scaf.json" 2>&1

scaf() {  # scaf <label> <node expression over r>
  N=$((N+1))
  if node -e "const r=require('$TMP/scaf.json'); process.exit(($2)?0:1)" 2>/dev/null; then
    PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n       result: %s\n' "$1" "$(cat "$TMP/scaf.json")"; fi
}

have "the config is written"            stryker.config.json
have "the class-name ignorer is written" stryker-classname-ignorer.mjs
scaf "the config names the ignorer plugin" \
  "require('$PWD/stryker.config.json').ignorers.includes('tailwind-classnames')"
scaf "and loads it as a plugin" \
  "require('$PWD/stryker.config.json').plugins.includes('./stryker-classname-ignorer.mjs')"

N=$((N+1))
if grep -q '^\.stryker-tmp/$' .gitignore && grep -q '^node_modules$' .gitignore; then
  PASS=$((PASS+1)); printf '  ok   %s\n' "gitignore gains the temp dir and keeps what was there"
else
  FAIL=$((FAIL+1)); printf '  FAIL gitignore is %s\n' "$(cat .gitignore | tr '\n' ' ')"
fi

N=$((N+1))
if grep -q '@stryker-mutator/api' "$TMP/scaf.json"; then
  PASS=$((PASS+1)); printf '  ok   %s\n' "the install command carries the api package"
else
  FAIL=$((FAIL+1)); printf '  FAIL the install command omits @stryker-mutator/api\n'
fi

# npm hoists @stryker-mutator/api by accident and pnpm does not, so the command
# has to come from the lockfile that is actually there.
printf 'lockfileVersion: 9\n' > pnpm-lock.yaml
node -e "
  import('$HERE/../cli/lib/scaffold-stryker.mjs').then(async (m) => {
    console.log(JSON.stringify(await m.scaffoldStryker('$PWD', '')));
  });
" > "$TMP/scaf.json" 2>&1
scaf "a pnpm project gets a pnpm install command" "r.install.startsWith('pnpm ')"
scaf "and nothing is rewritten the second time" "r.wrote.length === 0 && r.kept.length === 3"

# The projects already running Stryker are the ones grinding through className
# mutants, and reportToolNeeds skipped them outright because they were not
# missing a tool. A setup written before the ignorer existed had no way to learn
# about it.
echo "stryker scaffold, already installed"
newrepo strhave
printf '{"devDependencies":{"@stryker-mutator/core":"10"}}\n' > package.json
printf '{"testRunner":"vitest","coverageAnalysis":"perTest","mutate":["src/**"]}\n' > stryker.config.json
node -e "
  import('$HERE/../cli/lib/tool-needs.mjs').then(async (l) => {
    const n = await l.reportToolNeeds('$PWD');
    console.log(JSON.stringify(n.map((x) => [x.label, x.ignorerOnly === true])));
  });
" > "$TMP/have.json" 2>&1
N=$((N+1))
if grep -q '\["<repo root>",true\]' "$TMP/have.json"; then
  PASS=$((PASS+1)); printf '  ok   %s\n' "an existing install is offered the ignorer"
else
  FAIL=$((FAIL+1)); printf '  FAIL an existing install is not offered the ignorer: %s\n' "$(cat "$TMP/have.json")"
fi

node -e "
  import('$HERE/../cli/lib/scaffold-stryker.mjs').then(async (m) => {
    console.log(JSON.stringify(await m.scaffoldStryker('$PWD', '')));
  });
" > "$TMP/scaf.json" 2>&1
scaf "the existing config is patched, not replaced" "r.patched.length === 1"
scaf "its own settings survive" \
  "require('$PWD/stryker.config.json').mutate[0] === 'src/**'"
scaf "the ignorer is wired in" \
  "require('$PWD/stryker.config.json').ignorers.includes('tailwind-classnames')"

# This used to print an English sentence — "add @stryker-mutator/api as a dev
# dependency" — leaving every reader to guess their own package manager and
# path. It is a command now, and it asks for only the package that is missing.
scaf "an existing install gets a runnable command" \
  "/^(pnpm|npm) /.test(r.apiInstall)"
scaf "and it asks for only the api package" \
  "r.apiInstall.includes('@stryker-mutator/api') && !r.apiInstall.includes('@stryker-mutator/core')"

node -e "
  import('$HERE/../cli/lib/tool-needs.mjs').then(async (l) => {
    console.log(JSON.stringify(await l.reportToolNeeds('$PWD')));
  });
" > "$TMP/have.json" 2>&1
N=$((N+1))
if [ "$(cat "$TMP/have.json")" = "[]" ]; then
  PASS=$((PASS+1)); printf '  ok   %s\n' "and it stops being offered once wired in"
else
  FAIL=$((FAIL+1)); printf '  FAIL still offered after wiring: %s\n' "$(cat "$TMP/have.json")"
fi

# A config this cannot parse is somebody's own file. Reporting it beats
# rewriting it from a guess.
printf '{ testRunner: "vitest" }\n' > stryker.config.json
node -e "
  import('$HERE/../cli/lib/scaffold-stryker.mjs').then(async (m) => {
    console.log(JSON.stringify(await m.scaffoldStryker('$PWD', '')));
  });
" > "$TMP/scaf.json" 2>&1
scaf "an unparseable config is reported, not rewritten" \
  "r.unreadable.length === 1 && r.patched.length === 0"
N=$((N+1))
if grep -q 'testRunner: "vitest"' stryker.config.json; then
  PASS=$((PASS+1)); printf '  ok   %s\n' "and is left exactly as it was"
else
  FAIL=$((FAIL+1)); printf '  FAIL the unparseable config was overwritten\n'
fi
. "$HERE/selftest-stryker-patch.sh"
