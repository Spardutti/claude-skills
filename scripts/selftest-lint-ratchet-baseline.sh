#!/usr/bin/env bash

echo "baselines never bank growth"
LB="$TMP/lb"; rm -rf "$LB"; mkdir -p "$LB/src" "$LB/node_modules/.bin"
cp -r "$LR/scripts" "$LR/.claude" "$LB/"; cp "$LR/node_modules/.bin/eslint" "$LB/node_modules/.bin/"; rm -f "$LB/.edit-rules.json"
lb() {  # lb <label> <expected exit> <expected substring> <args...>
  local label="$1" want="$2" sub="$3"; shift 3
  N=$((N+1))
  out=$(env -C "$LB" node "$LB/scripts/lint-ratchet.mjs" "$@" 2>&1); rc=$?
  if [ "$rc" = "$want" ] && case "$out" in *"$sub"*) true ;; *) false ;; esac; then PASS=$((PASS+1)); printf '  ok   %s\n' "$label"
  else FAIL=$((FAIL+1)); printf '  FAIL %s — want exit %s ~ %s, got exit %s: %s\n' "$label" "$want" "$sub" "$rc" "$(printf '%s' "$out" | tr '\n' ' ')"; fi
}
printf '# rules: no-file-header\n' > "$LB/.lint-baseline"
printf '[{"filePath":"%s/src/u.ts","messages":[{"ruleId":"max-lines-per-function","line":3,"message":"too long"}]}]' "$LB" > "$LR/eslint.json"
lb "a rule with no baseline yet only notes, never blocks" 0 "max-lines-per-function has no baseline yet" --file src/u.ts

printf '# rules: max-lines-per-function\n2 max-lines-per-function src/a.ts\n' > "$LB/.lint-baseline"
printf '[{"filePath":"%s/src/a.ts","messages":[{"ruleId":"max-lines-per-function","line":3,"message":"m"}]},{"filePath":"%s/src/new.ts","messages":[{"ruleId":"max-lines-per-function","line":3,"message":"m"}]}]' "$LB" "$LB" > "$LR/eslint.json"
lb "--baseline on a known rule runs" 0 "baseline written" --baseline max-lines-per-function
N=$((N+1))
got=$(grep -v '^#' "$LB/.lint-baseline")
if [ "$got" = "1 max-lines-per-function src/a.ts" ]; then PASS=$((PASS+1)); echo "  ok   banking lowers old debt and never adds new"
else FAIL=$((FAIL+1)); echo "  FAIL banking lowers old debt and never adds new — $(tr '\n' '|' < "$LB/.lint-baseline")"; fi

printf '[]' > "$LR/eslint.json"
lb "--baseline-new records a rule switched on later" 0 "baseline written" --baseline-new
args_are "--baseline-new lints only the new rule" "$(printf 'arg[%s]\n' -f json --rule "$TYPES" .)"
rm -f "$LR/args.log"
lb "--baseline-new with every rule known does nothing" 0 "" --baseline-new
args_are "--baseline-new never runs eslint for known rules" ""
N=$((N+1))
case "$(head -1 "$LB/.lint-baseline")" in
  "# rules: @typescript-eslint/explicit-module-boundary-types max-lines-per-function") PASS=$((PASS+1)); echo "  ok   the header lists every rule baselined so far" ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL the header lists every rule baselined so far — $(head -1 "$LB/.lint-baseline")" ;;
esac

echo "edge cases from the final review"
NB="$TMP/nb"; rm -rf "$NB"; mkdir -p "$NB/src" "$NB/node_modules/.bin"
cp -r "$LR/scripts" "$LR/.claude" "$NB/"; cp "$LR/node_modules/.bin/eslint" "$NB/node_modules/.bin/"
printf '[{"filePath":"%s/src/v.ts","messages":[{"ruleId":"max-lines-per-function","line":2,"message":"m"}]}]' "$NB" > "$LR/eslint.json"
N=$((N+1))
out=$(env -C "$NB" node "$NB/scripts/lint-ratchet.mjs" --file src/v.ts 2>&1); rc=$?
case "$rc:$out" in
  "0:"*"no baseline yet"*) PASS=$((PASS+1)); echo "  ok   with no .lint-baseline at all, old findings only note" ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL with no .lint-baseline at all, old findings only note — exit $rc: $out" ;;
esac

mkdir -p "$NB/src/My Widget"
printf '[{"filePath":"%s/src/My Widget/w.ts","messages":[{"ruleId":"max-lines-per-function","line":2,"message":"m"}]}]' "$NB" > "$LR/eslint.json"
printf '# rules: max-lines-per-function\n1 max-lines-per-function src/My Widget/w.ts\n' > "$NB/.lint-baseline"
N=$((N+1))
out=$(env -C "$NB" node "$NB/scripts/lint-ratchet.mjs" --file "src/My Widget/w.ts" 2>&1); rc=$?
case "$rc:$out" in
  "0:"*"has 1 old"*) PASS=$((PASS+1)); echo "  ok   a path with a space matches its baseline entry" ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL a path with a space matches its baseline entry — exit $rc: $out" ;;
esac

git -C "$NB" init -q; printf 'dist/\n' > "$NB/.gitignore"; mkdir -p "$NB/dist"
printf '[{"filePath":"%s/dist/out.ts","messages":[{"ruleId":"max-lines-per-function","line":2,"message":"m"}]}]' "$NB" > "$LR/eslint.json"
N=$((N+1))
out=$(env -C "$NB" node "$NB/scripts/lint-ratchet.mjs" --file dist/out.ts 2>&1); rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then PASS=$((PASS+1)); echo "  ok   a git-ignored file is not judged"
else FAIL=$((FAIL+1)); echo "  FAIL a git-ignored file is not judged — exit $rc: $out"; fi

AN="$TMP/migrations/proj"; rm -rf "$TMP/migrations"; mkdir -p "$AN/scripts"
cp "$NB/scripts/"* "$HERE/line-limit.sh" "$AN/scripts/"
awk 'BEGIN { for (i=0;i<250;i++) print "x = 1" }' > "$AN/big.py"
N=$((N+1))
out=$(printf '{"tool_input":{"file_path":"%s/big.py"}}' "$AN" | CLAUDE_PROJECT_DIR="$AN" bash "$AN/scripts/edit-check.sh" 2>&1); rc=$?
case "$rc:$out" in
  "2:"*"big.py — 250 lines"*) PASS=$((PASS+1)); echo "  ok   a folder above the project never matches the skip list" ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL a folder above the project never matches the skip list — exit $rc: $out" ;;
esac

echo "a first install with nothing to record"
EB="$TMP/eb"; rm -rf "$EB"; mkdir -p "$EB/src"; cp -r "$LR/scripts" "$EB/"
N=$((N+1))
out=$(env -C "$EB" node "$EB/scripts/lint-ratchet.mjs" --baseline-new 2>&1); rc=$?
case "$rc:$out" in
  *"Recording old code"*) FAIL=$((FAIL+1)); echo "  FAIL no rule to record prints no empty \"Recording\" line — $out" ;;
  0:*) PASS=$((PASS+1)); echo "  ok   no rule to record prints no empty \"Recording\" line" ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL no rule to record prints no empty \"Recording\" line — exit $rc: $out" ;;
esac
