#!/usr/bin/env bash

echo "ship-gate bracket paths"
# The whole file is mutated, so old lines report too; only the lines this diff changed are its findings.
newrepo sg_glob_lines
printf '{"devDependencies":{"@stryker-mutator/core":"10"}}\n' > package.json
mkdir -p 'app/[id]'; seq 1 50 | sed 's/^/const x/' > 'app/[id]/route.ts'
git add -A; git commit -qm base; git branch -q develop; git checkout -qb feat/g
sed -i '30s/.*/const changed = 1/' 'app/[id]/route.ts'
printf '#!/bin/sh\nprintf "%%s\\n" "[Survived] EqualityOperator" "app/[id]/route.ts:5:3" "[Survived] BooleanLiteral" "app/[id]/route.ts:30:7" "[NoCoverage] StringLiteral" "app/[id]/route.ts:30:9"\n' > bin/npx; chmod +x bin/npx
sg "a bracket path's changed line is still judged" "route.ts:30:7" 1
out=$(bash "$SG" 2>&1); N=$((N+1))
if printf '%s' "$out" | grep -q 'route.ts:30:9' && ! printf '%s' "$out" | grep -q 'route.ts:5:3'; then PASS=$((PASS+1)); echo "  ok   and only its changed lines: an old line's survivor is not this diff's"
else FAIL=$((FAIL+1)); printf '  FAIL and only its changed lines: an old line'"'"'s survivor is not this diff'"'"'s\n%s\n' "$out"; fi
