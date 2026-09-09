#!/usr/bin/env bash
# Cases for scripts/line-limit.sh, the 200-line ratchet.
# Sourced by gauntlet-selftest.sh; shares its $HERE, $TMP, $N, $PASS, $FAIL.

echo "the 200-line ratchet"
LL="$TMP/ll"; rm -rf "$LL"; mkdir -p "$LL/scripts"
cp "$HERE/line-limit.sh" "$LL/scripts/line-limit.sh"
mklines() { awk -v n="$2" 'BEGIN { for (i=0;i<n;i++) print ": pad" }' > "$LL/$1"; }

mklines big.sh 300
mklines small.sh 10
bash "$LL/scripts/line-limit.sh" --baseline >/dev/null 2>&1

ll() {  # ll <label> <expected exit> <expected substring>
  N=$((N+1))
  out=$(bash "$LL/scripts/line-limit.sh" 2>&1); rc=$?
  ok=1
  [ "$rc" = "$2" ] || ok=0
  case "$out" in *"$3"*) ;; *) ok=0 ;; esac
  if [ $ok = 1 ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s — want exit %s ~ %s, got exit %s: %s\n' "$1" "$2" "$3" "$rc" "$(printf '%s' "$out" | tr '\n' ' ')"; fi
}

ll "recorded debt passes unchanged"       0 "none grew"
mklines big.sh 320
ll "recorded debt that grows fails"       1 "big.sh — 320 lines, was 300"
mklines big.sh 300
mklines fresh.sh 250
ll "a new file over the limit fails"      1 "fresh.sh — 250 lines (limit 200)"
rm "$LL/fresh.sh"
mklines big.sh 150
ll "paying debt down is not a failure"    0 "debt paid down"
rm "$LL/big.sh"
ll "a deleted file is reported, not red"  0 "gone (was 300 lines)"

