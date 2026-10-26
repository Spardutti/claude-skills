#!/usr/bin/env bash
[ -n "${SELFTEST_SANDBOX:-}" ] || { echo "$(basename "$0"): run it through scripts/gauntlet-selftest.sh, never on its own" >&2; exit 1; }

echo "every test file refuses to run on its own"
SA="$TMP/standalone"; rm -rf "$SA"; mkdir -p "$SA"
git -C "$SA" init -q; git -C "$SA" config user.email t@t.t; git -C "$SA" config user.name t
echo keep > "$SA/README.md"; git -C "$SA" add -A; git -C "$SA" commit -qm keep
SA_MAIN=$(git -C "$SA" branch --show-current)
sa_state() { { git -C "$SA" rev-parse HEAD; git -C "$SA" branch --format='%(refname)'; git -C "$SA" status --porcelain --ignored; } 2>&1; }
SA_BEFORE=$(sa_state)
SA_BAD=""
for f in "$HERE"/selftest-*.sh; do
  b=$(basename "$f")
  out=$( cd "$SA" && env -u SELFTEST_SANDBOX -u TMP HOME="$SA/home" timeout 20 bash "$f" 2>&1 ); rc=$?
  # Only the guard's own line proves the guard stopped it; any other exit 1 is a crash that ran first.
  if [ "$rc" != 1 ] || [ "$out" != "$b: run it through scripts/gauntlet-selftest.sh, never on its own" ] || [ "$(sa_state)" != "$SA_BEFORE" ]; then
    SA_BAD="$SA_BAD $b"
  fi
  git -C "$SA" checkout -q -f "$SA_MAIN" 2>/dev/null
  git -C "$SA" reset -q --hard "$(printf '%s\n' "$SA_BEFORE" | head -1)"; git -C "$SA" clean -qfdx
  git -C "$SA" for-each-ref --format='%(refname:short)' refs/heads | while IFS= read -r br; do
    [ "$br" = "$SA_MAIN" ] || git -C "$SA" branch -qD "$br"
  done
done
N=$((N+1))
if [ -z "$SA_BAD" ]; then PASS=$((PASS+1)); echo "  ok   run alone, every test file stops at its guard and leaves the repo it was run in untouched"
else FAIL=$((FAIL+1)); echo "  FAIL these ran on their own or changed the repo:$SA_BAD"; fi
