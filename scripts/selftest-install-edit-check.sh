#!/usr/bin/env bash
[ -n "${SELFTEST_SANDBOX:-}" ] || { echo "$(basename "$0"): run it through scripts/gauntlet-selftest.sh, never on its own" >&2; exit 1; }

echo "installing the edit check"
newrepo edit_install
mkdir -p src .claude/hooks
awk 'BEGIN { for (i=0;i<300;i++) print "export const x" i " = 1" }' > src/old.ts
cat > .claude/settings.json <<'OLD'
{ "hooks": { "PostToolUse": [ { "matcher": "Skill",
  "hooks": [{ "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/skill-gate-automark.sh" }] } ] } }
OLD
install_hooks() { node -e "import('$HERE/../cli/lib/setup-hook.mjs').then(m=>m.setupHook('$PWD'))" >/dev/null 2>&1; }
install_hooks

ie() {  # ie <label> <0|1 passed> <got>
  N=$((N+1))
  if [ "$2" = 1 ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n       got: %s\n' "$1" "$3"; fi
}
post() { node -e 'const s = require("./.claude/settings.json"); console.log(JSON.stringify(s.hooks.PostToolUse))'; }
edit() {  # edit <file> — runs the installed hook as Claude Code would after a Write
  printf '{"tool_input":{"file_path":"%s/%s"}}' "$PWD" "$1" | CLAUDE_PROJECT_DIR="$PWD" bash .claude/hooks/edit-check.sh 2>&1
}

ok=1; for f in edit-check.sh line-limit.sh lint-ratchet.mjs text-rules.mjs ratchet-baseline.mjs diary-check.mjs diary-lib.mjs ship-log.mjs ship-log-parse.mjs ship-log-report.mjs ship-mark.sh ship-prep.sh registry.mjs registry-lib.mjs; do [ -x ".claude/hooks/$f" ] || ok=0; done
ie "the edit-check files and the diary check are installed, executable" $ok "$(ls .claude/hooks)"
WANT='[{"matcher":"Skill","hooks":[{"type":"command","command":"$CLAUDE_PROJECT_DIR/.claude/hooks/skill-gate-automark.sh"}]},{"matcher":"Write|Edit|MultiEdit","hooks":[{"type":"command","command":"$CLAUDE_PROJECT_DIR/.claude/hooks/edit-check.sh"}]}]'
ie "an upgrade adds the edit hook beside the old PostToolUse entry" "$([ "$(post)" = "$WANT" ] && echo 1)" "$(post)"
ie "the first install records old code as baseline debt" "$(grep -qx '300 src/old.ts' .line-limit-baseline 2>/dev/null && echo 1)" "$(cat .line-limit-baseline 2>&1)"
ie "an empty .lint-baseline is still written, so a reinstall never re-baselines" "$([ -f .lint-baseline ] && echo 1)" "$(ls -a)"

echo '301 src/old.ts' > .line-limit-baseline
install_hooks
ie "installing again registers the edit hook once" "$([ "$(post)" = "$WANT" ] && echo 1)" "$(post)"
ie "installing again keeps the existing baseline" "$(grep -qx '301 src/old.ts' .line-limit-baseline && echo 1)" "$(cat .line-limit-baseline)"

awk 'BEGIN { for (i=0;i<250;i++) print "export const y" i " = 1" }' > src/new.ts
out=$(edit src/new.ts); rc=$?
ie "the installed hook blocks a new 250-line file" "$([ $rc = 2 ] && case "$out" in *"src/new.ts — 250 lines"*) echo 1 ;; esac)" "exit $rc: $out"
printf 'GAUNTLET_MAX_LINES=300\n' > .claude/gauntlet.conf
out=$(edit src/new.ts); rc=$?
ie "the hook follows the gate's GAUNTLET_MAX_LINES" "$([ $rc = 0 ] && echo 1)" "exit $rc: $out"
printf 'GAUNTLET_MAX_LINES=0\n' > .claude/gauntlet.conf
awk 'BEGIN { for (i=0;i<900;i++) print "x" }' > src/huge.ts
out=$(edit src/huge.ts); rc=$?
ie "GAUNTLET_MAX_LINES=0 turns the line check off" "$([ $rc = 0 ] && [ -z "$out" ] && echo 1)" "exit $rc: $out"

newrepo edit_mono
mkdir -p apps/web/src apps/web/.claude
awk 'BEGIN { for (i=0;i<400;i++) print "export const z" i " = 1" }' > apps/web/src/big.ts
git add -A; git commit -qm mono
node -e "import('$HERE/../cli/lib/setup-hook.mjs').then(m=>m.setupHook('$PWD/apps/web'))" >/dev/null 2>&1
ie "in a monorepo subfolder the length baseline sits at the git root, where the gate reads it" \
  "$(grep -qx '400 apps/web/src/big.ts' .line-limit-baseline 2>/dev/null && echo 1)" "$(ls -a; cat apps/web/.line-limit-baseline 2>&1)"

cd "$TMP/edit_install" || exit 1
out=$(env -u CLAUDE_PROJECT_DIR node .claude/hooks/diary-check.mjs 2>&1); rc=$?
ie "the installed diary check runs" "$([ $rc = 0 ] && [ -z "$out" ] && echo 1)" "exit $rc: $out"
out=$(env -u CLAUDE_PROJECT_DIR node .claude/hooks/skill-report.mjs 2>&1); rc=$?
ie "the installed /skill-report runs" "$([ $rc = 0 ] && case "$out" in *"No skill audits"*) echo 1 ;; esac)" "exit $rc: $out"
