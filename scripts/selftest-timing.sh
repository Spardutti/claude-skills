#!/usr/bin/env bash
# How long the Stop hook and the ship gate took. Sourced by gauntlet-selftest.sh.
# Past 600s Claude Code kills the Stop hook and the turn passes, so a slow run must be said out loud.

timed() {  # timed <label> <text> <extended regex it must match, or "" for empty>
  N=$((N+1))
  if { [ -z "$3" ] && [ -z "$2" ]; } || { [ -n "$3" ] && printf '%s\n' "$2" | grep -qE "$3"; }; then
    PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n       want ~ %s\n       got  = %s\n' "$1" "${3:-<nothing>}" "$2"
  fi
}

hookrun() {  # hookrun <session id>: the hook's stdout, and its .why in $WHYGOT
  OUTGOT=$(echo "{\"session_id\":\"$1\"}" | "$G" 2>/dev/null)
  WHYGOT=$(cat "/tmp/claude-gauntlet-$1.why" 2>/dev/null)
  rm -f "/tmp/claude-gauntlet-$1" "/tmp/claude-gauntlet-$1.why"
}

echo "timing: the Stop hook"
newrepo timing_hook
echo "export const a = 1" > a.ts
printf 'GAUNTLET_TYPECHECK=""\nGAUNTLET_TEST="true"\nGAUNTLET_SLOW=0\n' > .claude/gauntlet.conf
hookrun "time$RUN-slow"
timed "a slow run warns the user" "$OUTGOT" '^\{"systemMessage":"gauntlet took [0-9]+s, target 0s: green: gates passed \(tests \)"\}$'
timed "and records its seconds" "$WHYGOT" '^green: gates passed \(tests \) \([0-9]+s\)$'
printf 'GAUNTLET_TYPECHECK=""\nGAUNTLET_TEST="true"\nGAUNTLET_SLOW=60\n' > .claude/gauntlet.conf
hookrun "time$RUN-fast"
timed "a fast run says nothing" "$OUTGOT" ""
timed "but still records its seconds" "$WHYGOT" '^green: gates passed \(tests \) \([0-9]+s\)$'
printf 'GAUNTLET_TYPECHECK=""\nGAUNTLET_TEST="false"\n' > .claude/gauntlet.conf
hookrun "time$RUN-red"
timed "a red run records its seconds" "$WHYGOT" '^red: the tests gate failed \([0-9]+s\)$'

echo "timing: the ship gate"
newrepo timing_gate
printf 'GAUNTLET_MUTATE="sleep 1"\n' > .claude/gauntlet.conf
echo '{}' > package.json
git add -A; git commit -qm manifest; git branch develop
mkdir -p src/shared/utils
echo "export const a = 1" > src/shared/utils/a.ts
out=$(bash "$SG" 2>&1)
timed "each mutation run is timed" "$out" '^  <repo root> config \([0-9]+s\) — ok, nothing survived'
timed "and so is the whole gate" "$out" '^ship-gate: PASS in [0-9]+s$'
mkdir -p src/components
echo "export const a = 1" > src/components/Loose.ts
out=$(bash "$SG" 2>&1)
timed "a gate that stops early is timed too" "$out" '^ship-gate: FAIL in [0-9]+s — '
