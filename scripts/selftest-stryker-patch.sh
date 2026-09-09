#!/usr/bin/env bash
# Cases for Stryker config the scaffold patches rather than writes.
# Sourced by gauntlet-selftest.sh; shares its $HERE, $TMP, $N, $PASS, $FAIL.

echo "stryker scaffold, workspace lockfile"
newrepo strws
printf 'lockfileVersion: 9\n' > pnpm-lock.yaml
mkdir -p apps/web
node -e "
  import('$HERE/../cli/lib/scaffold-stryker.mjs').then(async (m) => {
    console.log(JSON.stringify(await m.scaffoldStryker('$PWD', 'apps/web')));
  });
" > "$TMP/scaf.json" 2>&1
scaf "a root lockfile makes a sub-project a pnpm install" \
  "r.install.startsWith('pnpm --dir apps/web ')"
scaf "and the api command follows the same lockfile" \
  "r.apiInstall === 'pnpm --dir apps/web add -D @stryker-mutator/api'"

echo "stryker ignoreStatic"
newrepo strstatic
node -e "
  import('$HERE/../cli/lib/scaffold-stryker.mjs').then(async (m) => {
    console.log(JSON.stringify(await m.scaffoldStryker('$PWD', '')));
  });
" > "$TMP/scaf.json" 2>&1
scaf "a fresh config sets ignoreStatic" \
  "require('$PWD/stryker.config.json').ignoreStatic === true"
scaf "and keeps perTest, which it requires" \
  "require('$PWD/stryker.config.json').coverageAnalysis === 'perTest'"
N=$((N+1))
if grep -q 'inDataTable' stryker-classname-ignorer.mjs; then
  FAIL=$((FAIL+1)); printf '  FAIL the retired data-table rule is still generated\n'
else
  PASS=$((PASS+1)); printf '  ok   %s\n' "the retired data-table rule is gone"
fi

# The upgrade, not the install. This project already has the ignorer wired in,
# which is exactly the config the old code called "kept" and never touched
# again — so it would have run without ignoreStatic forever.
newrepo strstatic2
printf '{"testRunner":"vitest","coverageAnalysis":"perTest","ignorers":["tailwind-classnames"],"mutate":["src/**"]}\n' > stryker.config.json
node -e "
  import('$HERE/../cli/lib/scaffold-stryker.mjs').then(async (m) => {
    console.log(JSON.stringify(await m.scaffoldStryker('$PWD', '')));
  });
" > "$TMP/scaf.json" 2>&1
scaf "an already-wired config still gains ignoreStatic" \
  "r.patched.length === 1 && require('$PWD/stryker.config.json').ignoreStatic === true"
scaf "and its own settings survive" \
  "require('$PWD/stryker.config.json').mutate[0] === 'src/**'"

# ignoreStatic is only correct under perTest. A project that deliberately chose
# otherwise keeps its choice — switching it silently would change which mutants
# the project reports.
newrepo strstatic3
printf '{"testRunner":"vitest","coverageAnalysis":"all","ignorers":["tailwind-classnames"]}\n' > stryker.config.json
node -e "
  import('$HERE/../cli/lib/scaffold-stryker.mjs').then(async (m) => {
    console.log(JSON.stringify(await m.scaffoldStryker('$PWD', '')));
  });
" > "$TMP/scaf.json" 2>&1
scaf "a non-perTest config is left alone" \
  "r.kept.length === 1 && require('$PWD/stryker.config.json').ignoreStatic === undefined"
scaf "and its coverageAnalysis is not switched" \
  "require('$PWD/stryker.config.json').coverageAnalysis === 'all'"

cd /
rm -rf "$TMP"
echo
echo "$PASS passed, $FAIL failed, $N total"
[ "$FAIL" = 0 ]
