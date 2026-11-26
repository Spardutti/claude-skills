#!/usr/bin/env bash
[ -n "${SELFTEST_SANDBOX:-}" ] || { echo "$(basename "$0"): run it through scripts/gauntlet-selftest.sh, never on its own" >&2; exit 1; }
# ship-gate cases for the batch runner: when Stryker is handed it, and when it is left out.
# Sourced by gauntlet-selftest.sh after selftest-ship-gate-stryker.sh, whose argv() it uses.

batch_repo() {  # batch_repo <name> <testRunner>
  newrepo "$1"
  printf '{"devDependencies":{"@stryker-mutator/core":"10"}}\n' > package.json
  printf '{"testRunner": "%s", "coverageAnalysis": "perTest"}\n' "$2" > stryker.config.json
  mkdir -p node_modules/@stryker-mutator/vitest-runner/dist/src
  echo '{"name":"@stryker-mutator/vitest-runner"}' > node_modules/@stryker-mutator/vitest-runner/package.json
  : > node_modules/@stryker-mutator/vitest-runner/dist/src/vitest-test-runner.js
  printf '#!/bin/sh\nfor a in "$@"; do echo "arg[$a]" >> %s; done\n' "$LOG" > bin/npx
  chmod +x bin/npx
  echo "const a=1" > a.ts
}

echo "ship-gate stryker batch runner"
batch_repo sg_batch vitest
argv "a local Vitest project gets the batch runner, by absolute path" \
"$STRYKER_RUN
arg[--testRunner]
arg[vitest-batch]
arg[--appendPlugins]
arg[$HERE/stryker-batch-runner.mjs]
arg[--mutate]
arg[a.ts:1-1]"

batch_repo sg_batch_jest jest
argv "a Jest project keeps its own runner" \
"$STRYKER_RUN
arg[--mutate]
arg[a.ts:1-1]"

batch_repo sg_batch_missing vitest
rm -rf node_modules/@stryker-mutator/vitest-runner/dist
argv "a vitest-runner without the file the batch runner extends is left alone" \
"$STRYKER_RUN
arg[--mutate]
arg[a.ts:1-1]"

batch_repo sg_batch_docker vitest
printf '#!/bin/sh\nfor a in "$@"; do echo "arg[$a]" >> %s; done\n' "$LOG" > .stryker-run
chmod +x .stryker-run
argv "Stryker run through .stryker-run never gets a host path" \
"arg[run]
arg[--concurrency]
arg[4]
arg[--mutate]
arg[a.ts:1-1]"
