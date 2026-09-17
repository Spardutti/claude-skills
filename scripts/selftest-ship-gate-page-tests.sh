#!/usr/bin/env bash
# ship-gate cases for page tests inside a Stryker run.
# Sourced by gauntlet-selftest.sh; shares its $HERE, $TMP, $N, $PASS, $FAIL.

page_repo() {  # page_repo <name>: a Stryker project whose run comes back clean
  newrepo "$1"
  printf '{"devDependencies":{"@stryker-mutator/core":"10"}}\n' > package.json
  printf '#!/bin/sh\nexit 0\n' > bin/npx
  chmod +x bin/npx
  mkdir -p src/shared/utils
  echo "export const a = 1" > src/shared/utils/a.ts
}

beside() {  # beside <dir> <stem> <ext>: a test and the file it is named for
  mkdir -p "$1"
  echo "export const x = 1" > "$1/$2.$3"
  echo "render(<X/>)" > "$1/$2.test.$3"
}

# A page test calls the utils its screen uses, so their mutants read as killed
# when no logic test checks them. On one project that hid 104 findings in a 23-minute run.
echo "ship-gate stryker page tests"
page_repo sg_pages
beside src/shared/components Card tsx
sg "a component test in the run is reported" "page tests count as proof" 2
sg "and the file that tripped it is named" "src/shared/components/Card.test.tsx" 2

page_repo sg_pages_split
beside src/shared/components Card tsx
printf '{"vitest":{"configFile":"vitest.stryker.config.ts"}}\n' > stryker.config.json
sg "a project with its own Stryker test config is left alone" "nothing survived" 0

page_repo sg_pages_hooks
beside src/shared/hooks use-a tsx
beside src/shared/queries b tsx
sg "a hook test in .tsx is logic, not a page" "nothing survived" 0

newrepo sg_pages_mono
mkdir -p apps/web/src/shared/utils apps/api
printf '{"devDependencies":{"@stryker-mutator/core":"10"}}\n' > apps/web/package.json
printf '{"name":"api"}\n' > apps/api/package.json
printf '#!/bin/sh\nexit 0\n' > bin/npx
chmod +x bin/npx
echo "export const a = 1" > apps/web/src/shared/utils/a.ts
beside apps/api/src/shared/components Card tsx
sg "another project's page tests do not count against this one" "nothing survived" 0
