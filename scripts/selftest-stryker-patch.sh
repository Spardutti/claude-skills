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

# TypeScript 7 has no JS compiler API, and Stryker's tsconfig rewrite calls it, so
# every run crashed and the gate said UNPROVEN on a project that did nothing wrong.
echo "stryker on TypeScript 7"
scaffold_here() {
  node -e "
    import('$HERE/../cli/lib/scaffold-stryker.mjs').then(async (m) => {
      console.log(JSON.stringify(await m.scaffoldStryker('$PWD', '')));
    });
  " > "$TMP/scaf.json" 2>&1
}
newrepo strts7
printf '{"devDependencies":{"typescript":"^7.0.2"}}\n' > package.json
scaffold_here
scaf "a fresh config on TypeScript 7 skips the tsconfig rewrite" \
  "require('$PWD/stryker.config.json').tsconfigFile.startsWith('no-tsconfig-rewrite')"
newrepo strts7up
printf '{"devDependencies":{"typescript":"7.0.2"}}\n' > package.json
printf '{"testRunner":"vitest","ignorers":["tailwind-classnames"],"coverageAnalysis":"perTest","ignoreStatic":true}\n' > stryker.config.json
scaffold_here
scaf "an existing config on TypeScript 7 gains it too" \
  "require('$PWD/stryker.config.json').tsconfigFile.startsWith('no-tsconfig-rewrite')"
newrepo strts7root
printf '{"devDependencies":{"typescript":"^7.0.2"}}\n' > package.json
mkdir -p apps/web && printf '{"name":"web"}\n' > apps/web/package.json
node -e "
  import('$HERE/../cli/lib/scaffold-stryker.mjs').then(async (m) => {
    console.log(JSON.stringify(await m.scaffoldStryker('$PWD', 'apps/web')));
  });
" > "$TMP/scaf.json" 2>&1
scaf "a sub-project finds TypeScript 7 at the workspace root" \
  "require('$PWD/apps/web/stryker.config.json').tsconfigFile.startsWith('no-tsconfig-rewrite')"
newrepo strts7catalog
printf '{"devDependencies":{"typescript":"catalog:"}}\n' > package.json
mkdir -p node_modules/typescript && printf '{"version":"7.0.2"}\n' > node_modules/typescript/package.json
scaffold_here
scaf "a range with no number is read from the installed version" \
  "require('$PWD/stryker.config.json').tsconfigFile.startsWith('no-tsconfig-rewrite')"
newrepo strts7own
printf '{"devDependencies":{"typescript":"7.0.2"}}\n' > package.json
printf '{"testRunner":"vitest","ignorers":["tailwind-classnames"],"coverageAnalysis":"perTest","ignoreStatic":true,"tsconfigFile":"tsconfig.app.json"}\n' > stryker.config.json
scaffold_here
scaf "a tsconfigFile the project chose is kept" \
  "require('$PWD/stryker.config.json').tsconfigFile === 'tsconfig.app.json'"
newrepo strts6
printf '{"devDependencies":{"typescript":"^6.0.2"}}\n' > package.json
scaffold_here
scaf "TypeScript 6 keeps the rewrite" \
  "require('$PWD/stryker.config.json').tsconfigFile === undefined"
