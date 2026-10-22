#!/usr/bin/env bash

echo "ship-gate: a change to Stryker's own setup"
newrepo sg-setup
mkdir -p src patches
printf '{"name":"x","version":"1.0.0","devDependencies":{"@stryker-mutator/core":"10"}}\n' > package.json
printf '{"testRunner":"vitest"}\n' > stryker.config.json
printf 'export const a = 1\n' > src/a.ts
printf 'old patch\n' > patches/vitest.patch
export SUARGS="$TMP/setup-args.log" SUOUT="$TMP/setup.out" SURC="$TMP/setup.rc"
printf '#!/bin/sh\nfor a in "$@"; do printf "arg[%%s]\\n" "$a"; done >> "$SUARGS"\ncat "$SUOUT"\nexit $(cat "$SURC")\n' > .stryker-run
chmod +x .stryker-run
git add -A; git commit -qm base; git branch -q develop; git checkout -qb feat/s
su_run() { rm -f "$SUARGS"; printf '%s\n' "$1" > "$SUOUT"; echo "$2" > "$SURC"; }

su_run 'INFO DryRunExecutor Initial test run succeeded.' 0
printf '{"testRunner":"vitest","timeoutMS":9000}\n' > stryker.config.json
sg "a Stryker config change with no code gets a trial run that passes" "trial run passed" 0
N=$((N+1)); want=$(printf 'arg[%s]\n' run --dryRunOnly --concurrency 4)
if [ "$(cat "$SUARGS" 2>/dev/null)" = "$want" ]; then PASS=$((PASS+1)); echo "  ok   the trial run is exactly: run --dryRunOnly --concurrency 4"
else FAIL=$((FAIL+1)); printf '  FAIL the trial run is exactly: run --dryRunOnly --concurrency 4\n       got %s\n' "$(cat "$SUARGS" 2>/dev/null)"; fi
rm -f "$SUARGS"; bash "$SG" >/dev/null 2>&1
sg_ok() { N=$((N+1)); if eval "$2"; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; fi; }
sg_ok "a trial run that passed is not repeated" '[ ! -f "$SUARGS" ]'

K1=$(bash "$SG" --key)
printf '{"testRunner":"vitest","timeoutMS":9500}\n' > stryker.config.json
sg_ok "editing the Stryker config after a pass needs the gate again" '[ "$K1" != "$(bash "$SG" --key)" ]'

git checkout -q stryker.config.json; git rm -q patches/vitest.patch
su_run 'ERROR DryRunExecutor One or more tests failed in the initial test run.' 1
sg "removing a patch that breaks Stryker's test run fails the gate" "breaks Stryker's own test run" 1

git checkout -q HEAD -- patches/vitest.patch
su_run 'sh: docker: not found' 127
printf '{"testRunner":"vitest","timeoutMS":9100}\n' > stryker.config.json
sg "a trial run that cannot start is UNPROVEN, not a FAIL" "UNPROVEN" 2

git checkout -q stryker.config.json
su_run 'INFO DryRunExecutor Initial test run succeeded.' 0
sed -i 's/"1.0.0"/"1.1.0"/' package.json
bash "$SG" >/dev/null 2>&1
sg_ok "a version bump alone runs no trial" '[ ! -f "$SUARGS" ]'

printf '{"testRunner":"vitest","timeoutMS":9300}\n' > stryker.config.json; printf 'export const a = 2\n' > src/a.ts
su_run 'INFO DryRunExecutor Initial test run succeeded.' 0
bash "$SG" >/dev/null 2>&1
sg_ok "a project with code to mutate gets no separate trial" '! grep -q dryRunOnly "$SUARGS"'

git checkout -q package.json src/a.ts
su_run "" 0; printf '{"devDependencies":{}}\n' > package.json; printf '{"testRunner":"vitest","timeoutMS":9200}\n' > stryker.config.json
bash "$SG" >/dev/null 2>&1
sg_ok "a project without Stryker runs no trial" '[ ! -f "$SUARGS" ]'
git checkout -q .

newrepo sg-setup-mono
mkdir -p apps/web/src
printf '{"devDependencies":{"@stryker-mutator/core":"10"}}\n' > apps/web/package.json
printf '{"testRunner":"vitest"}\n' > apps/web/stryker.config.json
printf '#!/bin/sh\nfor a in "$@"; do printf "arg[%%s]\\n" "$a"; done >> "$SUARGS"\necho ok\n' > apps/web/.stryker-run; chmod +x apps/web/.stryker-run
git add -A; git commit -qm base; git branch -q develop; git checkout -qb feat/m
rm -f "$SUARGS"; printf '{"testRunner":"vitest","timeoutMS":1}\n' > apps/web/stryker.config.json
bash "$SG" >/dev/null 2>&1
sg_ok "a package's own .stryker-run runs its trial" '[ -f "$SUARGS" ]'


mkdir -p apps/other/src/components; echo '{}' > apps/other/package.json
printf 'export const a = 1\n' > apps/other/src/components/Loose.ts
rm -f "$SUARGS"; printf '{"testRunner":"vitest","timeoutMS":2}\n' > apps/web/stryker.config.json
bash "$SG" >/dev/null 2>&1; rc=$?
sg_ok "a structure FAIL skips the trial run" '[ "$rc" = 1 ] && [ ! -f "$SUARGS" ]'
rm -rf apps/other

newrepo sg-mark-age
mkdir -p .claude/hooks
cp "$SG" "$SGH" "$HERE/ship-mark.sh" "$HERE/gate-config.sh" "$HERE/line-limit.sh" "$HERE/ship-gate-projects.sh" "$HERE/ship-gate-structure.sh" "$HERE/ship-gate-files.sh" .claude/hooks/
chmod +x .claude/hooks/*.sh; H=".claude/hooks/ship-gate-hook.sh"
printf "GAUNTLET_MUTATE='echo clean'\n" > .claude/gauntlet.conf
git checkout -qb feat/old; echo "const a=1" > a.ts; git add -A; git commit -qm w
bash .claude/hooks/ship-gate.sh >/dev/null 2>&1; bash .claude/hooks/ship-mark.sh begin
touch -d "13 hours ago" "$(ls -t /tmp/claude-ship-* | head -1)"
hook "a /ship mark from yesterday no longer opens a PR" deny "gh pr create --fill"
