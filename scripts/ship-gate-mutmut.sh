#!/usr/bin/env bash

mutmut_judge() {  # uses OUT MLOG SCOPE_RE MODS label base MODE from ship-gate.sh; sets SURVIVED FIXED NOTE STATUS; false means skip the rest
  BL="$base.mutmut-baseline"
  # A glob that matches no mutant aborts the run, so nothing in scope was tested.
  if [ -n "$SCOPE_RE" ] && grep -qs "nothing matches" "$MLOG"; then
    echo "  $label mutmut — UNPROVEN: no mutant in the changed module(s): $(printf '%s ' $MODS)"
    [ "$STATUS" = 0 ] && STATUS=2; rm -f "$MLOG"; return 1
  fi
  NOWF=$(mktemp)
  printf '%s\n' "$OUT" \
    | sed -n 's/^[[:space:]]*\([^[:space:]]*\): survived$/\1/p' | sort -u > "$NOWF"

  # "not checked" means a needed service was unreachable and nothing ran; it prints like a clean run.
  NOTCHECKED=$(printf '%s\n' "$OUT" | grep -c ': not checked$')
  if [ "$NOTCHECKED" -gt 0 ]; then
    mutmut_unchecked "$label" "$base" "$NOTCHECKED" "$MLOG"
    [ "$STATUS" = 0 ] && STATUS=2
    rm -f "$NOWF" "$MLOG"
    return 1
  fi

  [ "$MODE" != baseline ] && baseline_first "$BL" "$NOWF" "$MODS" "$label" && [ "$STATUS" = 0 ] && STATUS=2
  if [ "$MODE" = baseline ]; then
    baseline_write "$BL" "$NOWF" "$SCOPE_RE" "$MODS"
    NOTE="  $label mutmut — baseline set: $(wc -l < "$BL") survivor(s) accepted. Commit $BL."
    SURVIVED=""
  elif [ -f "$BL" ]; then
    SURVIVED=$(grep -Fxv -f "$BL" "$NOWF" | head -20)
    FIXED=$(grep -E "^(${SCOPE_RE:-.*})\.x" "$BL" | grep -Fxvc -f "$NOWF")
  else
    cp "$NOWF" "$BL"
    NOTE="  $label mutmut — no baseline, so nothing could be compared. Recorded
      $(wc -l < "$BL") existing survivor(s) in $BL — commit it, then run the
      gate again. From here only NEW survivors fail; --baseline accepts more."
    SURVIVED=""
    [ "$STATUS" = 0 ] && STATUS=2
  fi
  rm -f "$NOWF" "$MLOG"
}
