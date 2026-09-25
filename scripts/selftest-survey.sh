#!/usr/bin/env bash
# gauntlet-survey.sh against grouped folders. Sourced by gauntlet-selftest.sh.
# Repos moved into personal/ and work/ were skipped, and preflight passed a survey of 0 repos.

echo "gauntlet-survey"
SV="$TMP/survey-root"
rm -rf "$SV"; mkdir -p "$SV/solo" "$SV/personal/grouped" "$SV/personal/notes"
git init -q "$SV/solo"
git init -q "$SV/personal/grouped"
rows=$(bash "$HERE/gauntlet-survey.sh" "$SV" | tail -n +3 | awk '{print $1}' | sort | tr '\n' ' ')
N=$((N+1))
if [ "$rows" = "personal/grouped solo " ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "a repo inside a group folder is surveyed, a plain folder is not"
else FAIL=$((FAIL+1)); printf '  FAIL %s\n       want: personal/grouped solo\n       got:  %s\n' "a repo inside a group folder is surveyed, a plain folder is not" "$rows"; fi
