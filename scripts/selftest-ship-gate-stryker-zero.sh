#!/usr/bin/env bash

# vitest-runner 10 on Vitest 5 filters every test out (stryker-js#6210), so each
# mutant "survives" with 0 tests run. That is a broken run, not a weak suite.
echo "ship-gate stryker ran no tests"
zero_run() {  # zero_run <killed> <tests per mutant> [extra finding lines]
  cat > bin/npx <<X
#!/bin/sh
echo "[Survived] EqualityOperator"
echo "a.ts:1:11"
${3:-}
echo "Ran $2 tests per mutant on average."
echo "All files    |   0.00 |    0.00 |        $1 |         0 |          1 |"
exit 0
X
  chmod +x bin/npx
}
newrepo sg_zero
printf '{"devDependencies":{"@stryker-mutator/core":"10"}}\n' > package.json
echo "const a=1" > a.ts
zero_run 0 0.00
sg "survivors from a run of 0 tests are UNPROVEN, not a FAIL" "ran 0 tests" 2

zero_run 0 1.40
sg "survivors from a run that tested them still fail" "[Survived] EqualityOperator" 1

# 400 mutants and one test run rounds to "Ran 0.00" too, but that run killed some.
zero_run 3 0.00
sg "a big run that rounds to 0.00 but killed mutants still fails" "[Survived] EqualityOperator" 1

zero_run 0 0.00 'echo "[NoCoverage] BooleanLiteral"; echo "a.ts:1:7"'
sg "an uncovered line in a run of 0 tests still fails" "[NoCoverage] BooleanLiteral" 1
