#!/usr/bin/env bash
# Which branch ship-gate measures from. Sourced by gauntlet-selftest.sh.
# A repo whose trunk is `dev` got measured from main, so files already in dev were flagged.

echo "ship-gate base branch"
base_case() {
  newrepo "sg_base_$1"
  [ -n "$3" ] && echo "GAUNTLET_BASE='$3'" > .claude/gauntlet.conf
  git checkout -qb "$2"; echo "export const o = 1" > old.ts; git add -A; git commit -qm old
  git checkout -qb feat; echo "export const n = 1" > new.ts; git add -A; git commit -qm new
  N=$((N+1))
  got=$(bash "$SG" 2>&1 | grep -o '[0-9]* changed code file(s)')
  if [ "$got" = "1 changed code file(s)" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$4"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n       want: 1 changed code file(s)\n       got:  %s\n' "$4" "$got"
  fi
}
base_case dev dev "" "a branch off dev is measured from dev"
base_case conf staging staging "GAUNTLET_BASE names the trunk"
