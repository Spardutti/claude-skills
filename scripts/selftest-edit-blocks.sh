#!/usr/bin/env bash

echo "edit-hook blocks are logged and tallied"
EB="$TMP/eb"; rm -rf "$EB"; mkdir -p "$EB/.claude/hooks" "$EB/src"
cp "$HERE/edit-check.sh" "$HERE/line-limit.sh" "$HERE/gate-config.sh" "$HERE/lint-ratchet.mjs" "$HERE/text-rules.mjs" \
   "$HERE/ratchet-baseline.mjs" "$HERE/skill-report.mjs" "$HERE/diary-lib.mjs" "$EB/.claude/hooks/"
git -C "$EB" init -q -b feat/x
printf '{"text":[{"id":"no-todo","files":"\\\\.ts$","pattern":"TODO","message":"m","bad":"// TODO","good":"x"}]}' > "$EB/.edit-rules.json"
printf '# rules: no-todo\n' > "$EB/.lint-baseline"
BLOG="$EB/.claude/edit-blocks.jsonl"
eb() { printf '{"tool_input":{"file_path":"%s/%s"}}' "$EB" "$1" | CLAUDE_PROJECT_DIR="$EB" bash "$EB/.claude/hooks/edit-check.sh" >/dev/null 2>&1; }
ebt() {  # ebt <label> <0|1 passed> <got>
  N=$((N+1))
  if [ "$2" = 1 ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  FAIL %s — %s\n' "$1" "$3"; fi
}
field() { node -e 'const l = require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n"); const o = JSON.parse(l[+process.argv[2]]); process.stdout.write(o.file + "|" + [].concat(o.rules).join(" ") + "|" + o.branch)' "$BLOG" "$1" 2>&1; }

awk 'BEGIN { for (i=0;i<250;i++) print "export const x" i " = 1" }' > "$EB/src/big.ts"; eb src/big.ts
ebt "a block is logged with the file, the rule and the branch" "$([ "$(field 0)" = "src/big.ts|line-limit|feat/x" ] && echo 1)" "$(field 0)"
printf 'export const ok = 1\n' > "$EB/src/ok.ts"; eb src/ok.ts
ebt "an edit that passes logs nothing" "$([ "$(wc -l < "$BLOG")" = 1 ] && echo 1)" "$(cat "$BLOG")"
printf '// TODO later\nexport const t = 1\n' > "$EB/src/t.ts"; eb src/t.ts
ebt "a text-rule block names that rule" "$([ "$(field 1)" = "src/t.ts|no-todo|feat/x" ] && echo 1)" "$(field 1)"
eb src/big.ts
REPORT=$(env -u CLAUDE_PROJECT_DIR node "$EB/.claude/hooks/skill-report.mjs" 2>&1)
WANT='edit-hook blocks        count  branches
line-limit                  2         1
no-todo                     1         1'
ebt "/skill-report tallies blocks per rule, most first" "$(case "$REPORT" in *"$WANT"*) echo 1 ;; esac)" "$REPORT"

ln -sfn "$EB" "$TMP/eblink"
REPORT=$(env -u CLAUDE_PROJECT_DIR node "$TMP/eblink/.claude/hooks/skill-report.mjs" 2>&1)
ebt "/skill-report still prints when reached through a symlink" "$(case "$REPORT" in *"edit-hook blocks"*) echo 1 ;; esac)" "$REPORT"
mkdir -p "$EB/scripts"; cp "$HERE/skill-report.mjs" "$HERE/diary-lib.mjs" "$HERE/gate-config.sh" "$EB/scripts/"
REPORT=$(env -C "$EB" -u CLAUDE_PROJECT_DIR node "$EB/scripts/skill-report.mjs" 2>&1)
ebt "/skill-report run from scripts/ reads the project's .claude" "$(case "$REPORT" in *"edit-hook blocks"*) echo 1 ;; esac)" "$REPORT"

printf '{"text":[{"id":"no-\\"q\\"","files":"\\\\.ts$","pattern":"QQ","message":"m","bad":"QQ","good":"x"}]}' > "$EB/.edit-rules.json"
printf '# rules: no-"q"\n' > "$EB/.lint-baseline"
printf 'QQ\n' > "$EB/src/q.ts"; eb src/q.ts
got=$(node -e 'const l = require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n"); process.stdout.write([].concat(JSON.parse(l[l.length - 1]).rules).join(" "))' "$BLOG" 2>&1)
ebt "a rule id with a quote still makes a valid log line" "$([ "$got" = 'no-"q"' ] && echo 1)" "$got"

: > "$BLOG"
for i in 1 2 3; do printf '{"ts":"t","branch":"feat/x","file":"a","rules":"retried"}\n' >> "$BLOG"; done
for b in a b; do printf '{"ts":"t","branch":"feat/%s","file":"a","rules":"spread"}\n' "$b" >> "$BLOG"; done
REPORT=$(env -u CLAUDE_PROJECT_DIR node "$EB/.claude/hooks/skill-report.mjs" 2>&1)
ebt "a rule blocking on more branches ranks above one retried on a single branch" \
  "$(case "$REPORT" in *"spread"*"retried"*) echo 1 ;; esac)" "$REPORT"

mkdir -p "$EB/inner"; git -C "$EB/inner" init -q -b feat/inner
awk 'BEGIN { for (i=0;i<230;i++) print "export const z" i " = 1" }' > "$EB/inner/long.ts"; eb inner/long.ts
got=$(node -e 'const l = require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n"); process.stdout.write(JSON.parse(l[l.length - 1]).branch)' "$BLOG" 2>&1)
ebt "a block is logged with the branch of the repo holding the edited file" "$([ "$got" = feat/inner ] && echo 1)" "$got"

printf '{"text":[{"id":"no,comma","files":"\\\\.ts$","pattern":"CC","message":"m","bad":"CC","good":"x"}]}' > "$EB/.edit-rules.json"
printf '# rules: no,comma\n' > "$EB/.lint-baseline"
printf 'CC\n' > "$EB/src/c.ts"; eb src/c.ts
got=$(node -e 'const l = require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n"); process.stdout.write([].concat(JSON.parse(l[l.length - 1]).rules).join(" "))' "$BLOG" 2>&1)
ebt "a rule id with a comma is logged whole" "$([ "$got" = 'no,comma' ] && echo 1)" "$got"

OTHER="$TMP/eb-other"; rm -rf "$OTHER"; mkdir -p "$OTHER"
printf '{"ts":"t","branch":"feat/o","file":"a","rules":"from-other"}\n' > "$OTHER/edit-blocks.jsonl"
REPORT=$(env -u CLAUDE_PROJECT_DIR node "$EB/.claude/hooks/skill-report.mjs" "$OTHER" 2>&1)
ebt "/skill-report <folder> reads both logs from that folder" "$(case "$REPORT" in *from-other*) case "$REPORT" in *line-limit*) ;; *) echo 1 ;; esac ;; esac)" "$REPORT"

printf '{"text":[{"id":"no-*-here","files":"\\\\.ts$","pattern":"SS","message":"m","bad":"SS","good":"x"}]}' > "$EB/.edit-rules.json"
printf '# rules: no-*-here\n' > "$EB/.lint-baseline"
printf 'SS\n' > "$EB/src/s.ts"; eb src/s.ts
got=$(node -e 'const l = require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n"); process.stdout.write(JSON.stringify(JSON.parse(l[l.length - 1]).rules))' "$BLOG" 2>&1)
ebt "a rule id with a * is logged whole, never globbed" "$([ "$got" = '["no-*-here"]' ] && echo 1)" "$got"
N=$((N+1))
out=$(env -C "$EB" node "$EB/.claude/hooks/lint-ratchet.mjs" --selftest 2>&1 <<< "")
printf '{"text":[{"id":"no space","files":"x","pattern":"Q","message":"m","bad":"Q","good":"x"}]}' > "$EB/.edit-rules.json"
out=$(env -C "$EB" node "$EB/.claude/hooks/lint-ratchet.mjs" --selftest 2>&1); rc=$?
if [ "$rc" = 1 ] && case "$out" in *"no space: its id has whitespace"*) true ;; *) false ;; esac; then PASS=$((PASS+1)); echo "  ok   --selftest rejects a rule id with a space"
else FAIL=$((FAIL+1)); echo "  FAIL --selftest rejects a rule id with a space — exit $rc: $out"; fi
REPORT=$(env -u CLAUDE_PROJECT_DIR node "$EB/.claude/hooks/skill-report.mjs" "$OTHER/edit-blocks.jsonl" 2>&1)
ebt "/skill-report given a log file reads that file's folder" "$(case "$REPORT" in *from-other*) echo 1 ;; esac)" "$REPORT"
