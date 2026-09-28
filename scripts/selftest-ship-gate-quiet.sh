#!/usr/bin/env bash
# ship-gate cases for how much of the machine a mutation run may take.
# Sourced by gauntlet-selftest.sh; shares its $HERE, $TMP, $N, $PASS, $FAIL.

echo "ship-gate quiet"

quiet_repo() {  # quiet_repo <name> <cores>
  newrepo "$1"
  cores "$2"
  printf '#!/bin/sh\necho "$*" >> %s/renice.args\n' "$R" > bin/renice
  chmod +x bin/renice
  mkdir -p app
  printf '[project]\nname="api"\n[tool.mutmut]\nsource_paths=["app/"]\n' > pyproject.toml
  printf '#!/bin/sh\n[ "$1" = run ] && echo "$*" >> %s/mutmut.args\nexit 0\n' "$R" > .mutmut-run
  chmod +x .mutmut-run
  : > .mutmut-baseline
  git add -A; git commit -qm base
  echo "x=1" > app/slugs.py
}

quiet_is() {  # quiet_is <label> <file> <expected content>
  N=$((N+1))
  got=$(cat "$2" 2>/dev/null)
  if [ "$got" = "$3" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$3" "$got"; fi
}

# mutmut starts one child per core by default. With three projects' gates at once
# that was 24 processes on 8 cores, and the editor froze.
quiet_repo sg_quiet_odd 5
bash "$SG" >/dev/null 2>&1
quiet_is "an odd core count rounds up to half" "$R/mutmut.args" "run --max-children 3 app.slugs.x*"
sed -i 's/-p [0-9][0-9]*$/-p PID/' "$R/renice.args" 2>/dev/null
quiet_is "the gate drops itself to the lowest priority" "$R/renice.args" "-n 19 -p PID"

quiet_repo sg_quiet_one 1
bash "$SG" >/dev/null 2>&1
quiet_is "one core still gets one worker" "$R/mutmut.args" "run --max-children 1 app.slugs.x*"
cores 8
