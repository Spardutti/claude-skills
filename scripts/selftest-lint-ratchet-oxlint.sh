#!/usr/bin/env bash
[ -n "${SELFTEST_SANDBOX:-}" ] || { echo "$(basename "$0"): run it through scripts/gauntlet-selftest.sh, never on its own" >&2; exit 1; }

echo "the lint ratchet on oxlint"
OX="$TMP/ox"; rm -rf "$OX"; mkdir -p "$OX/scripts" "$OX/node_modules/.bin" "$OX/src" "$OX/tmp"
for k in code-structure typescript-best-practices; do mkdir -p "$OX/.claude/skills/$k"; echo x > "$OX/.claude/skills/$k/SKILL.md"; done
cp "$HERE/lint-ratchet.mjs" "$HERE/lint-runners.mjs" "$HERE/text-rules.mjs" "$HERE/test-checks.mjs" "$HERE/ratchet-baseline.mjs" "$OX/scripts/"
cat > "$OX/oxlint.stub" <<STUB
#!/bin/sh
: > "$OX/args.log"
while [ \$# -gt 0 ]; do
  if [ "\$1" = -c ]; then printf 'arg[-c]\narg[CONFIG]\n' >> "$OX/args.log"; cp "\$2" "$OX/config.json"; shift 2; continue; fi
  printf 'arg[%s]\n' "\$1" >> "$OX/args.log"; shift
done
cat "$OX/ox.json"
STUB
printf '#!/bin/sh\nfor a in "$@"; do printf "arg[%%s]\\n" "$a"; done > "%s/eslint-args.log"\ncat "%s/eslint.json"\n' "$OX" "$OX" > "$OX/eslint.stub"
chmod +x "$OX/oxlint.stub" "$OX/eslint.stub"
ox_use() { rm -f "$OX/node_modules/.bin/"*; for t in "$@"; do cp "$OX/$t.stub" "$OX/node_modules/.bin/$t"; done; }
ox_use oxlint
MAXL='"max-lines-per-function":["error",{"max":30,"skipBlankLines":true,"skipComments":true}]'
CFG_TS="{\"plugins\":[\"typescript\"],\"categories\":{\"correctness\":\"off\"},\"rules\":{$MAXL,\"typescript/explicit-module-boundary-types\":\"error\"}}"
CFG_TSX="{\"plugins\":[\"typescript\"],\"categories\":{\"correctness\":\"off\"},\"rules\":{$MAXL}}"

ox() {  # ox <file> <max-lines hits> [return-type hits] [no-debugger hits]
  local d="" i
  for i in $(seq "$2"); do d="$d{\"message\":\"too long\",\"code\":\"eslint(max-lines-per-function)\",\"filename\":\"$1\",\"labels\":[{\"span\":{\"line\":1$i}}]},"; done
  for i in $(seq "${3:-0}"); do d="$d{\"message\":\"no return type\",\"code\":\"typescript(explicit-module-boundary-types)\",\"filename\":\"$1\",\"labels\":[{\"span\":{\"line\":2$i}}]},"; done
  for i in $(seq "${4:-0}"); do d="$d{\"message\":\"debugger\",\"code\":\"eslint(no-debugger)\",\"filename\":\"$1\",\"labels\":[{\"span\":{\"line\":3$i}}]},"; done
  printf '{"diagnostics":[%s],"number_of_files":1}' "${d%,}" > "$OX/ox.json"
}

lr() {  # lr <label> <expected exit> <expected substring> <args...>
  local label="$1" want="$2" sub="$3"; shift 3
  N=$((N+1))
  out=$(env -C "$OX" TMPDIR="$OX/tmp" node "$OX/scripts/lint-ratchet.mjs" "$@" 2>&1); rc=$?
  if [ "$rc" = "$want" ] && case "$out" in *"$sub"*) true ;; *) false ;; esac; then
    PASS=$((PASS+1)); printf '  ok   %s\n' "$label"
  else FAIL=$((FAIL+1)); printf '  FAIL %s — want exit %s ~ %s, got exit %s: %s\n' "$label" "$want" "$sub" "$rc" "$(printf '%s' "$out" | tr '\n' ' ')"; fi
}

ox_same() {  # ox_same <label> <want> <got>
  N=$((N+1))
  if [ "$3" = "$2" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n       want %s\n       got  %s\n' "$1" "$(printf '%s' "$2" | tr '\n' ' ')" "$(printf '%s' "$3" | tr '\n' ' ')"; fi
}
ox_args() { cat "$OX/args.log" 2>/dev/null; }

printf '# rules: max-lines-per-function @typescript-eslint/explicit-module-boundary-types\n# linter: oxlint\n' > "$OX/.lint-baseline"
ox src/a.ts 1 0 2
lr "oxlint: a new long function is blocked, as with ESLint" 1 "src/a.ts:11  too long" --file src/a.ts
ox_same "oxlint gets the config, JSON output and only that file" "$(printf 'arg[%s]\n' -c CONFIG -f json src/a.ts)" "$(ox_args)"
ox_same "the config holds both rules and turns oxlint's defaults off" "$CFG_TS" "$(cat "$OX/config.json")"
N=$((N+1)); case "$out" in *debugger*) FAIL=$((FAIL+1)); echo "  FAIL oxlint's own default rules never show — $out" ;; *) PASS=$((PASS+1)); echo "  ok   oxlint's own default rules never show" ;; esac
ox src/b.tsx 0 0 3
lr "a .tsx file passes on default-rule hits alone" 0 "" --file src/b.tsx
ox_same "a .tsx file's config has no return-type rule" "$CFG_TSX" "$(cat "$OX/config.json")"
ox src/c.ts 0 1
lr "the return-type rule maps back to its ESLint name" 1 "1 × @typescript-eslint/explicit-module-boundary-types, was 0" --file src/c.ts
rm -f "$OX/args.log"
lr "a test file is not linted" 0 "" --file src/a.test.ts
ox_same "oxlint never runs for a test file" "" "$(ox_args)"
ox_same "no oxlint config file is left behind" "" "$(ls "$OX/tmp")"

echo "not json" > "$OX/ox.json"
lr "a broken oxlint blocks nothing and says so" 0 "NOTE — oxlint crashed or printed no JSON, so max-lines-per-function" --file src/a.ts

ox_use oxlint eslint; rm -f "$OX/eslint-args.log"; ox src/a.ts 0
lr "with both linters installed, the edit passes on oxlint's word" 0 "" --file src/a.ts
ox_same "with both installed, ESLint is never called" "" "$(cat "$OX/eslint-args.log" 2>/dev/null)"

ox src/a.ts 1; rm -f "$OX/.lint-baseline"
lr "--baseline with oxlint records the debt" 0 "1 rule/file pair(s)" --baseline
ox_same "--baseline lints the whole project" "$(printf 'arg[%s]\n' -c CONFIG -f json .)" "$(ox_args)"
ox_same "the baseline names oxlint as its counter" "# linter: oxlint" "$(sed -n 2p "$OX/.lint-baseline")"

echo "switching linters"
ox_use oxlint
printf '# rules: max-lines-per-function @typescript-eslint/explicit-module-boundary-types\n1 max-lines-per-function src/a.ts\n' > "$OX/.lint-baseline"
ox src/a.ts 2
lr "ESLint-counted debt does not block an oxlint count" 0 "max-lines-per-function has no baseline yet" --file src/a.ts
lr "--baseline-new re-counts the lint debt with oxlint" 0 "Re-counting lint debt with oxlint; ESLint counted it before." --baseline-new
ox_same "the re-count replaces ESLint's numbers, not keeps the lower" "$(printf '%s\n' '# rules: @typescript-eslint/explicit-module-boundary-types max-lines-per-function' '# linter: oxlint' '2 max-lines-per-function src/a.ts')" "$(cat "$OX/.lint-baseline")"
ox src/a.ts 3
lr "after the re-count, growth blocks again" 1 "3 × max-lines-per-function, was 2" --file src/a.ts

ox_use eslint
printf '# rules: max-lines-per-function\n1 max-lines-per-function src/a.ts\n' > "$OX/.lint-baseline"
printf '[{"filePath":"%s/src/a.ts","messages":[{"ruleId":"max-lines-per-function","line":11,"message":"too long"}]}]' "$OX" > "$OX/eslint.json"
lr "an old baseline with no linter line still counts as ESLint's" 0 "NOTE — src/a.ts has 1 old max-lines-per-function" --file src/a.ts
printf '# rules: max-lines-per-function\n# linter: oxlint\n1 max-lines-per-function src/a.ts\n' > "$OX/.lint-baseline"
lr "moving back to ESLint does not judge oxlint's counts either" 0 "has no baseline yet" --file src/a.ts
echo "not json" > "$OX/eslint.json"
lr "a crashed ESLint says so instead of skipping quietly" 0 "NOTE — ESLint crashed or printed no JSON" --file src/a.ts
