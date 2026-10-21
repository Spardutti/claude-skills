#!/usr/bin/env bash

echo "the lint ratchet"
LR="$TMP/lr"; rm -rf "$LR"; mkdir -p "$LR/scripts" "$LR/node_modules/.bin" "$LR/src"
for k in code-structure typescript-best-practices; do mkdir -p "$LR/.claude/skills/$k"; echo x > "$LR/.claude/skills/$k/SKILL.md"; done
printf '# rules: max-lines-per-function @typescript-eslint/explicit-module-boundary-types\n' > "$LR/.lint-baseline"
cp "$HERE/lint-ratchet.mjs" "$HERE/text-rules.mjs" "$HERE/ratchet-baseline.mjs" "$HERE/edit-check.sh" "$HERE/gate-config.sh" "$LR/scripts/"
printf '#!/bin/sh\nfor a in "$@"; do printf "arg[%%s]\\n" "$a"; done > "%s/args.log"\ncat "%s/eslint.json"\n' \
  "$LR" "$LR" > "$LR/node_modules/.bin/eslint"
chmod +x "$LR/node_modules/.bin/eslint"
MAXL='{"max-lines-per-function":["error",{"max":30,"skipBlankLines":true,"skipComments":true}]}'
TYPES='{"@typescript-eslint/explicit-module-boundary-types":"error"}'

lint() {  # lint <file> <max-lines hits> [other-rule hits]
  local msgs="" i
  for i in $(seq "$2"); do msgs="$msgs{\"ruleId\":\"max-lines-per-function\",\"line\":1$i,\"message\":\"too long\"},"; done
  for i in $(seq "${3:-0}"); do msgs="$msgs{\"ruleId\":\"no-unused-vars\",\"line\":9,\"message\":\"unused\"},"; done
  printf '[{"filePath":"%s/%s","messages":[%s]}]' "$LR" "$1" "${msgs%,}" > "$LR/eslint.json"
}

lr() {  # lr <label> <expected exit> <expected substring> <args...>
  local label="$1" want="$2" sub="$3"; shift 3
  N=$((N+1))
  out=$(env -C "$LR" node "$LR/scripts/lint-ratchet.mjs" "$@" 2>&1); rc=$?
  if [ "$rc" = "$want" ] && case "$out" in *"$sub"*) true ;; *) false ;; esac; then
    PASS=$((PASS+1)); printf '  ok   %s\n' "$label"
  else FAIL=$((FAIL+1)); printf '  FAIL %s — want exit %s ~ %s, got exit %s: %s\n' "$label" "$want" "$sub" "$rc" "$(printf '%s' "$out" | tr '\n' ' ')"; fi
}

args_are() {  # args_are <label> <expected arg list>
  N=$((N+1))
  got=$(cat "$LR/args.log" 2>/dev/null)
  if [ "$got" = "$2" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n       want %s\n       got  %s\n' "$1" "$(printf '%s' "$2" | tr '\n' ' ')" "$(printf '%s' "$got" | tr '\n' ' ')"; fi
}

lint src/a.ts 1 2
lr "a new long function is blocked, other rules ignored" 1 "src/a.ts:11  too long" --file src/a.ts
args_are "a .ts file gets both rules, and only that file" "$(printf 'arg[%s]\n' -f json --rule "$MAXL" --rule "$TYPES" src/a.ts)"
lint src/b.tsx 0
lr "a .tsx file passes when clean" 0 "" --file src/b.tsx
args_are "a .tsx file gets no return-type rule" "$(printf 'arg[%s]\n' -f json --rule "$MAXL" src/b.tsx)"
rm -f "$LR/args.log"
lr "a test file is not linted" 0 "" --file src/a.test.ts
args_are "eslint never runs for a test file" ""

lint src/a.ts 1; rm -f "$LR/.lint-baseline"
lr "--baseline records the debt" 0 "1 rule/file pair(s)" --baseline
args_are "--baseline lints the whole project" "$(printf 'arg[%s]\n' -f json --rule "$MAXL" --rule "$TYPES" .)"
lr "recorded debt passes, with a note to fix it" 0 "NOTE — src/a.ts has 1 old" --file src/a.ts
lint src/a.ts 2
lr "recorded debt that grew is blocked" 1 "2 × max-lines-per-function, was 1" --file src/a.ts
lint src/a.ts 0
lr "paid-down debt is a note, not a block" 0 "debt paid down. Run node scripts/lint-ratchet.mjs --baseline max-lines-per-function" --file src/a.ts
mv "$LR/.claude/skills/typescript-best-practices" "$LR/ts.off"
lr "without typescript-best-practices, no return-type rule" 0 "" --file src/a.ts
args_are "only the 30-line rule is sent" "$(printf 'arg[%s]\n' -f json --rule "$MAXL" src/a.ts)"
mv "$LR/.claude/skills/code-structure" "$LR/cs.off"; rm -f "$LR/args.log"
lr "without code-structure either, eslint is not run" 0 "" --file src/a.ts
args_are "no eslint call at all" ""
mv "$LR/ts.off" "$LR/.claude/skills/typescript-best-practices"; mv "$LR/cs.off" "$LR/.claude/skills/code-structure"
echo "not json" > "$LR/eslint.json"
lr "a broken eslint blocks nothing" 0 "" --file src/a.ts

mv "$LR/node_modules/.bin/eslint" "$LR/eslint.real"
printf '#!/bin/sh\ncase "$*" in *@typescript-eslint*) echo "could not find plugin"; exit 2 ;; esac\nexec "%s/eslint.real" "$@"\n' "$LR" > "$LR/node_modules/.bin/eslint"
chmod +x "$LR/node_modules/.bin/eslint"
lint src/d.ts 1
lr "without the TypeScript plugin, the core rule still runs" 1 "src/d.ts:11  too long" --file src/d.ts
args_are "the retry drops only the plugin rule" "$(printf 'arg[%s]\n' -f json --rule "$MAXL" src/d.ts)"
cp "$LR/.lint-baseline" "$LR/lb.keep"; printf '# rules: max-lines-per-function\n' > "$LR/.lint-baseline"; rm -f "$LR/args.log"
lr "--baseline-new says when the plugin rule cannot run" 0 "could not run @typescript-eslint/explicit-module-boundary-types" --baseline-new
args_are "with only the plugin rule new, no retry lints the whole repo" ""
mv "$LR/lb.keep" "$LR/.lint-baseline"
mv "$LR/eslint.real" "$LR/node_modules/.bin/eslint"

N=$((N+1))
lint src/c.ts 1
out=$(printf '{"tool_input":{"file_path":"%s/src/c.ts"}}' "$LR" | CLAUDE_PROJECT_DIR="$LR" bash "$LR/scripts/edit-check.sh" 2>&1); rc=$?
case "$rc:$out" in
  "2:"*"src/c.ts:11  too long"*) PASS=$((PASS+1)); echo "  ok   edit-check blocks the edit on a new lint finding" ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL edit-check blocks the edit on a new lint finding — exit $rc: $out" ;;
esac

echo "text rules"
git -C "$LR" init -q; echo node_modules > "$LR/.gitignore"
cp "$HERE/../.edit-rules.json" "$LR/.edit-rules.json"
printf '#!/usr/bin/env bash\n# what this file is\nx=1\n' > "$LR/src/old.sh"
printf '#!/usr/bin/env bash\n\nx=1\n' > "$LR/src/ok.sh"
rm -f "$LR/args.log"
lr "--baseline <new rule> records its old hits"  0 "rule/file pair(s)" --baseline no-file-header
args_are "--baseline <text rule> never runs eslint" ""
N=$((N+1))
case "$(cat "$LR/.lint-baseline")" in
  *"max-lines-per-function src/a.ts"*"no-file-header src/old.sh"*) PASS=$((PASS+1)); echo "  ok   --baseline <rule> keeps every other rule's debt" ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL --baseline <rule> keeps every other rule's debt — $(tr '\n' ' ' < "$LR/.lint-baseline")" ;;
esac
lr "recorded header debt is a note"             0 "NOTE — src/old.sh has 1 old no-file-header" --file src/old.sh
printf '#!/usr/bin/env bash\n# what this file is\nx=1\n' > "$LR/src/h.sh"
lr "a new header comment is blocked"            1 "src/h.sh:1  The file opens with a header" --file src/h.sh
lr "a file without one passes"                  0 "" --file src/ok.sh
lr "--selftest passes a rule that holds"        0 "1 text rule(s)" --selftest
node -e 'const fs = require("fs"), p = process.argv[1], r = JSON.parse(fs.readFileSync(p));
  r.text[0].good = "# x\nset -u\n"; fs.writeFileSync(p, JSON.stringify(r))' "$LR/.edit-rules.json"
lr "--selftest fails a rule that flags its good example" 1 "no-file-header: its good example is flagged" --selftest

node -e 'const fs = require("fs"), p = process.argv[1], r = JSON.parse(fs.readFileSync(p));
  r.lessons = [{ id: "mock-db", files: "\\.test\\.ts$", message: "Route tests mock the data layer here." }];
  fs.writeFileSync(p, JSON.stringify(r))' "$LR/.edit-rules.json"
lint src/e.test.ts 0
lr "a lesson shows on a file it names, as a note" 0 "LESSON — Route tests mock the data layer here." --file src/e.test.ts
N=$((N+1))
out=$(env -C "$LR" node "$LR/scripts/lint-ratchet.mjs" --file src/ok.sh 2>&1)
case "$out" in
  *LESSON*) FAIL=$((FAIL+1)); echo "  FAIL a lesson stays off files it does not name — $out" ;;
  *) PASS=$((PASS+1)); echo "  ok   a lesson stays off files it does not name" ;;
esac

node -e 'const fs = require("fs"), p = process.argv[1];
  fs.writeFileSync(p, JSON.stringify({ text: [{ id: "todo", files: "\\.sh$", pattern: "^# TODO", flags: "gm",
    message: "m", bad: "x\n# TODO\n", good: "x\n" }] }))' "$LR/.edit-rules.json"
lr "a rule may pass flags that already include g" 0 "1 text rule(s)" --selftest

echo '{"text":[{"id":"no-file-header","files":"\\.sh$","pattern":"^(?:#!.*\\n)?\\s*#(?!!)","message":"header","bad":"# x\n","good":"x\n"}]}' > "$LR/.edit-rules.json"
printf '# top\nx=1\n' > "$LR/src/s.sh"
ln -sfn "$LR" "$TMP/lrlink"
N=$((N+1))
out=$(printf '{"tool_input":{"file_path":"%s/src/s.sh"}}' "$TMP/lrlink" | CLAUDE_PROJECT_DIR="$TMP/lrlink" bash "$LR/scripts/edit-check.sh" 2>&1); rc=$?
case "$rc:$out" in
  "2:"*"src/s.sh:1  header"*) PASS=$((PASS+1)); echo "  ok   a project opened through a symlink is still checked" ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL a project opened through a symlink is still checked — exit $rc: $out" ;;
esac

mv "$LR/node_modules/.bin/eslint" "$LR/eslint.real"
printf '#!/bin/sh\ncase "$*" in *@typescript-eslint*) exit 2 ;; esac\nexec "%s/eslint.real" "$@"\n' "$LR" > "$LR/node_modules/.bin/eslint"
chmod +x "$LR/node_modules/.bin/eslint"
lint src/f.ts 0
printf '1 @typescript-eslint/explicit-module-boundary-types src/f.ts\n' >> "$LR/.lint-baseline"
N=$((N+1))
out=$(env -C "$LR" node "$LR/scripts/lint-ratchet.mjs" --file src/f.ts 2>&1)
case "$out" in
  *"paid down"*) FAIL=$((FAIL+1)); echo "  FAIL a rule eslint could not run is not judged — $out" ;;
  *) PASS=$((PASS+1)); echo "  ok   a rule eslint could not run is not judged" ;;
esac
mv "$LR/eslint.real" "$LR/node_modules/.bin/eslint"

NG="$TMP/nogit"; rm -rf "$NG"; mkdir -p "$NG/src"
cp "$LR/.edit-rules.json" "$NG/"; printf '# top\nx=1\n' > "$NG/src/old.sh"
env -C "$NG" node "$LR/scripts/lint-ratchet.mjs" --baseline no-file-header >/dev/null 2>&1
N=$((N+1))
if grep -qx '1 no-file-header src/old.sh' "$NG/.lint-baseline" 2>/dev/null; then PASS=$((PASS+1)); echo "  ok   --baseline finds old hits without git"
else FAIL=$((FAIL+1)); echo "  FAIL --baseline finds old hits without git — $(cat "$NG/.lint-baseline" 2>&1)"; fi

mkdir -p "$LR/src/components/ui"
lint src/components/ui/btn.tsx 1
N=$((N+1))
out=$(printf '{"tool_input":{"file_path":"%s/src/components/ui/btn.tsx"}}' "$LR" | CLAUDE_PROJECT_DIR="$LR" bash "$LR/scripts/edit-check.sh" 2>&1); rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then PASS=$((PASS+1)); echo "  ok   a file the gate skips (shadcn ui) is skipped by every edit check"
else FAIL=$((FAIL+1)); echo "  FAIL a file the gate skips (shadcn ui) is skipped by every edit check — exit $rc: $out"; fi
