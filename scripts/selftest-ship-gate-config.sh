#!/usr/bin/env bash
# ship-gate with a repo's own GAUNTLET_MUTATE command. Sourced by gauntlet-selftest.sh.
# It once got no $FILES at all, so a wrapper script mutated nothing and every run passed.

echo "ship-gate config command"
newrepo sg_config
printf '#!/bin/sh\necho "$FILES|$MUTATE_FLAGS" >> %s\n' "$LOG" > bin/mutate-stub; chmod +x bin/mutate-stub
echo "GAUNTLET_MUTATE='mutate-stub'" > .claude/gauntlet.conf
mkdir -p web api
echo '{}' > web/package.json
printf '[project]\nname = "api"\n' > api/pyproject.toml
git add -A; git commit -qm manifests; git branch develop
mkdir -p web/src/shared/utils api/app
echo "export const a = 1" > web/src/shared/utils/a.ts
echo "export const b = 1" > web/src/shared/utils/b.ts
echo "x = 1" > api/app/x.py
rm -f "$LOG"
bash "$SG" >/dev/null 2>&1
N=$((N+1))
got=$(cat "$LOG" 2>/dev/null)
want="api/app/x.py|--mutate app/x.py:1-1
web/src/shared/utils/a.ts web/src/shared/utils/b.ts|--mutate src/shared/utils/a.ts:1-1,src/shared/utils/b.ts:1-1"
if [ "$got" = "$want" ]; then PASS=$((PASS+1)); printf '  ok   each project hands the command its own files and flags\n'
else FAIL=$((FAIL+1)); printf '  FAIL each project hands the command its own files and flags\n       want:\n%s\n       got:\n%s\n' "$want" "$got"
fi
