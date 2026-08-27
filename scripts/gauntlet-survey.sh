#!/usr/bin/env bash
# gauntlet-survey.sh — report what the gauntlet would do in every repo under a
# directory, without running a single gate.
#
#   bash scripts/gauntlet-survey.sh ~/projects
#
# Detection is where this hook keeps going wrong: real repos are shaped in ways
# no invented test repo is. Run this against your actual projects before shipping
# a change to detection, and read the rows that say "nothing".

set -uo pipefail

ROOT="${1:-$HOME/projects}"
G="$(cd "$(dirname "$0")" && pwd)/gauntlet.sh"
i=0

printf '%-26s %s\n' "PROJECT" "WOULD RUN"
printf '%-26s %s\n' "--------------------------" "---------"

for d in "$ROOT"/*/; do
  p="${d%/}"
  [ -d "$p/.git" ] || continue
  i=$((i+1))
  out=$(cd "$p" && CLAUDE_PROJECT_DIR="$p" GAUNTLET_DEBUG=1 GAUNTLET_DRYRUN=1 \
        bash "$G" <<< "{\"session_id\":\"survey-$$-$i\"}" 2>&1 >/dev/null | head -1)
  out=${out#gauntlet: }
  printf '%-26s %s\n' "$(basename "$p")" "${out#would run: }"
done
