#!/usr/bin/env bash
# gauntlet-selftest.sh — behavioural tests for scripts/gauntlet.sh.
#
# Every case builds a throwaway git repo, stubs the runners so nothing real is
# executed, runs the hook, and asserts on the outcome it recorded in its .why
# file. Run it before shipping any change to the hook:
#
#   bash scripts/gauntlet-selftest.sh
#
# Exits non-zero on the first failed assertion.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
G="$HERE/gauntlet.sh"
SG="$HERE/ship-gate.sh"
SGH="$HERE/ship-gate-hook.sh"
TMP=$(mktemp -d)
export HOME="$TMP/home"; mkdir -p "$HOME"
RUN="$$-$(date +%s 2>/dev/null || echo 0)"
LOG="$TMP/ran.log"
N=0
PASS=0
FAIL=0

newrepo() {
  R="$TMP/$1"; rm -rf "$R"; mkdir -p "$R/.claude" "$R/bin"; cd "$R" || exit 1
  git init -q .; git config user.email t@t.t; git config user.name t
  echo x > README.md; git add -A; git commit -qm init
  export CLAUDE_PROJECT_DIR="$R"
  case ":$PATH:" in *":$R/bin:"*) ;; *) export PATH="$R/bin:$PATH" ;; esac
}

# check <label> <expected substring in .why> [expected substring in the run log]
check() {
  N=$((N+1))
  rm -f "$LOG"
  echo "{\"session_id\":\"st$RUN-$N\"}" | "$G" >/dev/null 2>"$TMP/err"
  RC=$?
  got=$(cat "/tmp/claude-gauntlet-st$RUN-$N.why" 2>/dev/null)
  ok=1
  case "$got" in *"$2"*) ;; *) ok=0 ;; esac
  if [ -n "${3:-}" ]; then
    ran=$(cat "$LOG" 2>/dev/null)
    case "$ran" in *"$3"*) ;; *) ok=0 ;; esac
  fi
  if [ $ok = 1 ]; then
    PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL+1))
    printf '  FAIL %s\n       want why ~ %s\n       got  why = %s\n' "$1" "$2" "$got"
    [ -n "${3:-}" ] && printf '       want ran ~ %s\n       got  ran = %s\n' "$3" "$(cat "$LOG" 2>/dev/null)"
  fi
}

stub() { printf '#!/bin/sh\necho "%s" >> %s\n' "$2" "$LOG" > "bin/$1"; chmod +x "bin/$1"; }

echo "skip ladder"
newrepo r1
check "no changed files"        "no changed files"
echo hi >> README.md
check "docs only"               "docs/config only"
echo "const a=1" > a.ts
check "no gates detected"       "no gates detected"
printf "GAUNTLET_TYPECHECK=''\nGAUNTLET_TEST='echo ok'\n" > .claude/gauntlet.conf
check "green"                   "green: gates passed"
echo "// touch" >> a.ts
printf "GAUNTLET_TYPECHECK=''\nGAUNTLET_TEST='echo \"No test files found\"'\n" > .claude/gauntlet.conf
check "runner matched 0 tests"  "matched 0 test files"
echo "// touch2" >> a.ts
printf "GAUNTLET_TYPECHECK=''\nGAUNTLET_TEST='echo boom; exit 1'\n" > .claude/gauntlet.conf
check "red"                     "red: the tests gate failed"
# A red must exit 2 — that is the only exit code that both keeps the turn going
# and shows the user why. Exit 0 would let the turn end silently.
N_RED=$N
if [ "$RC" = 2 ]; then
  PASS=$((PASS+1)); echo "  ok   red exits 2 (visible to the user)"
else
  FAIL=$((FAIL+1)); echo "  FAIL red exits 2 — got exit $RC"
fi
N=$((N+1))
if grep -q "GAUNTLET FAILED" "$TMP/err" 2>/dev/null; then
  PASS=$((PASS+1)); echo "  ok   red writes the reason to stderr"
else
  FAIL=$((FAIL+1)); echo "  FAIL red writes the reason to stderr — got: $(cat "$TMP/err" 2>/dev/null)"
fi
N=$((N+1))
echo "GAUNTLET_OFF=1" >> .claude/gauntlet.conf
check "GAUNTLET_OFF"            "GAUNTLET_OFF is set"

echo "a missing tool is a skip, not a red"
newrepo r2
echo '{"devDependencies":{"vitest":"^4"}}' > package.json
echo "const a=1" > a.ts
check "vitest not installed"    "tool is not installed"
newrepo r3
printf '[project]\nname="x"\n' > pyproject.toml
echo "x=1" > a.py
check "pytest not installed"    "tool is not installed"

echo "a delegating monorepo root uses its own scripts"
newrepo r4
mkdir -p web
echo '{"scripts":{"test":"npm --prefix web run test","typecheck":"npm --prefix web run typecheck"}}' > package.json
echo '{"scripts":{"test":"vitest run"},"devDependencies":{"vitest":"^4"}}' > web/package.json
stub npm "npm-ran"
mkdir -p web/src; echo "export const a=1" > web/src/a.ts
check "root scripts win"        "green: gates passed" "npm-ran"

echo "more than one stack in one repo"
newrepo r5
echo '{"scripts":{"typecheck":"x"},"devDependencies":{"vitest":"^4"}}' > package.json
printf '[tool.mypy]\nstrict=true\n' > pyproject.toml
stub npm "js-typecheck"; stub npx "js-test"
printf '#!/bin/sh\ncase "$*" in *mypy*) echo py-typecheck >> %s;; *pytest*) echo py-test >> %s;; esac\n' "$LOG" "$LOG" > bin/python
chmod +x bin/python
echo "const a=1" > a.ts
check "js change runs js gates" "green: gates passed" "js-test"
rm a.ts; echo "x=1" > b.py
check "py change runs py gates" "green: gates passed" "py-test"

echo "a nested project with nothing at the root"
newrepo r6
mkdir -p web/src api
echo '{"scripts":{"typecheck":"tsc -b"},"devDependencies":{"vitest":"^4"}}' > web/package.json
printf '[project]\nname="api"\n' > api/pyproject.toml
stub npm "web-typecheck"; stub npx "web-test"
printf '#!/bin/sh\necho api-test >> %s\n' "$LOG" > bin/python; chmod +x bin/python
echo "export const a=1" > web/src/a.ts
check "web change runs web gates" "green: gates passed" "web-test"
rm web/src/a.ts; echo "x=1" > api/a.py
check "api change runs api gates" "green: gates passed" "api-test"

# A project whose tests need a database cannot run them on the host, and
# detection finds the host runner every time. GAUNTLET_TEST could override it,
# but that switches the WHOLE repo to explicit mode — so a monorepo needing a
# container for one stack had to hand-write commands for all of them. A
# per-project executable runner fixes exactly that, and only that.
echo "per-project runners"
newrepo r_runner
mkdir -p web api
printf '{"scripts":{"test":"x","typecheck":"y"},"devDependencies":{"vitest":"^4"}}\n' > web/package.json
printf '[project]\nname="api"\n' > api/pyproject.toml
# The runner and the host tool it must beat. Each logs which one ran, so this
# asserts WHICH command executed — a stub that only returned a verdict would
# agree with the bug and still come out green.
printf '#!/bin/sh\necho RUNNER-IN-CONTAINER >> %s\nexit 0\n' "$LOG" > api/.gauntlet-test
chmod +x api/.gauntlet-test
stub python "HOST-PYTEST"
stub npx "HOST-VITEST"
echo "print(1)" > api/main.py
check "the project runner replaces the host tool" "green: gates passed" "RUNNER-IN-CONTAINER"

newrepo r_runner_host
mkdir -p web api
printf '{"scripts":{"test":"x"},"devDependencies":{"vitest":"^4"}}\n' > web/package.json
printf '[project]\nname="api"\n' > api/pyproject.toml
printf '#!/bin/sh\necho RUNNER-IN-CONTAINER >> %s\nexit 0\n' "$LOG" > api/.gauntlet-test
chmod +x api/.gauntlet-test
stub python "HOST-PYTEST"
stub npx "HOST-VITEST"
echo "export const a = 1" > web/a.ts
# The other half of the monorepo declares no runner, so it keeps its detected
# host command. This is what GAUNTLET_TEST could not express.
check "the half with no runner still auto-detects" "green: gates passed" "HOST-VITEST"

newrepo r_runner_tc
mkdir -p api
printf '[project]\nname="api"\n[tool.mypy]\n' > api/pyproject.toml
printf '#!/bin/sh\necho RUNNER-TYPECHECK >> %s\nexit 0\n' "$LOG" > api/.gauntlet-typecheck
chmod +x api/.gauntlet-typecheck
stub python "HOST-MYPY"
echo "print(1)" > api/main.py
check "a typecheck runner replaces host mypy" "green: gates passed" "RUNNER-TYPECHECK"

newrepo r_runner_unexec
mkdir -p api
printf '[project]\nname="api"\n' > api/pyproject.toml
# Not executable: the gate cannot run it, so falling back to detection is the
# only safe reading. Silently gating on a file it cannot execute would be worse.
printf '#!/bin/sh\nexit 0\n' > api/.gauntlet-test
stub python "HOST-PYTEST"
echo "print(1)" > api/main.py
check "a non-executable runner is ignored" "green: gates passed" "HOST-PYTEST"

echo "a path containing a space stays one argument"
newrepo r7
echo '{"devDependencies":{"vitest":"^4"}}' > package.json
printf '#!/bin/sh\nfor a in "$@"; do echo "arg[$a]" >> %s; done\n' "$LOG" > bin/npx; chmod +x bin/npx
mkdir -p "src/my folder"; echo "const a=1" > "src/my folder/a.ts"
check "spaced path"             "green: gates passed" "arg[$TMP/r7/src/my folder/a.ts]"

# --------------------------------------------------------------- ship-gate.sh
sg() {  # sg <label> <expected substring in output> [expected exit code]
  N=$((N+1))
  out=$(bash "$SG" 2>&1); rc=$?
  ok=1
  case "$out" in *"$2"*) ;; *) ok=0 ;; esac
  [ -n "${3:-}" ] && [ "$rc" != "$3" ] && ok=0
  if [ $ok = 1 ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n       want ~ %s (exit ${3:-any})\n       got exit %s:\n%s\n' "$1" "$2" "$rc" "$out"
  fi
}
# The ship gate has its own files: it is a separate hook from the gauntlet,
# and together its cases were a third of this one.
. "$HERE/selftest-ship-gate-stryker.sh"
. "$HERE/selftest-ship-gate-mutmut.sh"


# ------------------------------------------------------------ the skill gates
# The application gate's BLOCKED text is one double-quoted bash string, so an
# unescaped " inside it closes the string early: the remainder runs as shell
# commands and the reason reaches the model EMPTY. That shipped in 2.16.1 and
# stood for five releases. Every denial since told the model nothing — not the
# rules, not even the ack command it was being asked to run — and the sessions
# that hit it were left guessing at what the gate wanted. Nothing caught it
# because no test had ever read the reason the hook actually emits.
echo "skill application gate message"
newrepo sag
mkdir -p .claude/skills/demo
printf -- '---\nname: demo\n---\n## Rules\n- always x\n' > .claude/skills/demo/SKILL.md
node -e "import('$HERE/../cli/lib/setup-hook.mjs').then(m=>m.setupHook('$PWD'))" >/dev/null 2>&1
SID="sag$RUN"
touch "/tmp/claude-skill-gate-$SID" "/tmp/claude-skill-loaded-$SID-demo"
SAG_OUT=$(printf '{"session_id":"%s","tool_name":"Write","tool_input":{"file_path":"%s/a.ts"}}' "$SID" "$PWD" \
          | bash .claude/hooks/skill-application-gate.sh 2>"$TMP/sag.err")
rm -f "/tmp/claude-skill-gate-$SID" "/tmp/claude-skill-loaded-$SID-demo"

sag() {  # sag <label> <node expression over r, the reason string>
  N=$((N+1))
  if printf '%s' "$SAG_OUT" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{const r=JSON.parse(d).hookSpecificOutput.permissionDecisionReason;process.exit(($2)?0:1)})" 2>/dev/null; then
    PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL+1)); printf '  FAIL %s\n       hook emitted: %s\n' "$1" "$SAG_OUT"
  fi
}

sag "the denial reason is not empty"   "r.length > 0"
sag "it names the ack command"         "r.includes('touch /tmp/claude-skill-acked-$SID-demo')"
sag "it carries the skill's rules"     "r.includes('always x')"
sag "a quoted phrase survives"         "r.includes('\"does not apply\"')"
sag "and the auto mode guidance"       "r.includes('Auto-Mode Bypass')"
# Exempting settings.json from the gate was not enough: the classifier denies an
# agent editing permission settings by any route. A peer session burned a round
# trip proving it. The message must say the user has to make the change.
sag "it says the user must add the rule"  "r.includes('The user has to add it')"
sag "and not to attempt it itself"        "r.includes('an agent editing permission settings')"
sag "and names the /permissions route"    "r.includes('/permissions, Auto mode tab')"

N=$((N+1))
if [ ! -s "$TMP/sag.err" ]; then
  PASS=$((PASS+1)); printf '  ok   %s\n' "the hook writes nothing to stderr"
else
  FAIL=$((FAIL+1)); printf '  FAIL the hook writes to stderr:\n%s\n' "$(cat "$TMP/sag.err")"
fi

# .json is in CODE_EXT, so both gates blocked ~/.claude/settings.json — the one
# file that holds the autoMode allow rule the deny message tells the model to
# add. With the ack touch denied by the classifier and the settings edit denied
# by the gate, each fix needed the other first and the session deadlocked with
# no move the model could make.
echo "skill gates exempt the settings file"
newrepo sg_settings
mkdir -p .claude/skills/demo
printf -- '---\nname: demo\n---\n## Rules\n- x\n' > .claude/skills/demo/SKILL.md
node -e "import('$HERE/../cli/lib/setup-hook.mjs').then(m=>m.setupHook('$PWD'))" >/dev/null 2>&1
SSID="sgs$RUN"

esc() {  # esc <label> <allow|deny> <hook file> <tool_name+tool_input json>
  N=$((N+1))
  out=$(printf '{"session_id":"%s",%s}' "$SSID" "$4" | bash ".claude/hooks/$3")
  if [ "$2" = "allow" ] && [ -z "$out" ]; then
    PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  elif [ "$2" = "deny" ] && [ -n "$out" ]; then
    PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL+1)); printf '  FAIL %s\n       hook emitted: %s\n' "$1" "$out"
  fi
}

# Loading gate: marker absent, so it is actively gating.
esc "loading gate lets the settings edit through" allow skill-gate.sh \
  '"tool_name":"Edit","tool_input":{"file_path":"/home/u/.claude/settings.json"}'
esc "loading gate still stops a source edit" deny skill-gate.sh \
  '"tool_name":"Edit","tool_input":{"file_path":"/home/u/src/a.ts"}'

# Application gate: loading satisfied, skill loaded, nothing acked.
touch "/tmp/claude-skill-gate-$SSID" "/tmp/claude-skill-loaded-$SSID-demo"
esc "application gate lets the settings edit through" allow skill-application-gate.sh \
  '"tool_name":"Edit","tool_input":{"file_path":"/home/u/.claude/settings.json"}'
esc "and settings.local.json too" allow skill-application-gate.sh \
  '"tool_name":"Edit","tool_input":{"file_path":"/home/u/.claude/settings.local.json"}'
esc "and a heredoc writing the settings file" allow skill-application-gate.sh \
  '"tool_name":"Bash","tool_input":{"command":"cat > /home/u/.claude/settings.json <<EOF"}'
esc "application gate still stops a source edit" deny skill-application-gate.sh \
  '"tool_name":"Edit","tool_input":{"file_path":"/home/u/src/a.ts"}'
rm -f "/tmp/claude-skill-gate-$SSID" "/tmp/claude-skill-loaded-$SSID-demo"

# The project-level permissions.allow the installer writes never cleared auto
# mode: the classifier reads autoMode.allow, and only from the user's own
# ~/.claude/settings.json. So the gate was unsatisfiable there, and the session
# could not fix it either — an agent editing permission settings is denied by
# the same classifier. Only the installer runs as the user.
echo "auto mode allow rule"
newrepo automode
AMH="$PWD/home"
AMS="$AMH/.claude/settings.json"
mkdir -p "$AMH/.claude"

amrun() { node -e "import('$HERE/../cli/lib/setup-hook.mjs').then(m=>m.writeAutoModeRule('$AMH')).catch(e=>{console.error(e.message);process.exit(1)})"; }

am() {  # am <label> <node expression over s, the parsed global settings>
  N=$((N+1))
  if node -e "const s=JSON.parse(require('fs').readFileSync('$AMS','utf8'));process.exit(($2)?0:1)" 2>/dev/null; then
    PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL+1)); printf '  FAIL %s\n       settings: %s\n' "$1" "$(cat "$AMS" 2>&1)"
  fi
}

MARK="r.includes('/tmp/claude-skill-acked-')"

# No settings file at all.
amrun >/dev/null 2>&1
am "the rule is written from nothing"  "s.autoMode.allow.some(r=>$MARK)"
am "and \$defaults comes first"         "s.autoMode.allow[0]==='\$defaults'"

# Re-running is the upgrade path, and it must not stack entries.
amrun >/dev/null 2>&1
am "a second run adds no duplicate"     "s.autoMode.allow.filter(r=>$MARK).length===1"
am "and leaves one \$defaults"           "s.autoMode.allow.filter(r=>r==='\$defaults').length===1"

# A real settings file has the user's own content in it.
printf '{"env":{"FOO":"bar"},"autoMode":{"allow":["$defaults","my own rule"]}}' > "$AMS"
amrun >/dev/null 2>&1
am "an unrelated setting survives"      "s.env.FOO==='bar'"
am "the user's own allow rule survives" "s.autoMode.allow.includes('my own rule')"

# An older wording must be corrected in place, not left beside the new one.
# A fresh-install test never sees this.
printf '{"autoMode":{"allow":["$defaults","old text about /tmp/claude-skill-acked- files"]}}' > "$AMS"
amrun >/dev/null 2>&1
am "a stale rule is replaced, not doubled" "s.autoMode.allow.filter(r=>$MARK).length===1"
am "and the stale wording is gone"         "!s.autoMode.allow.some(r=>r.includes('old text about'))"

# Never rewrite a file we cannot parse.
printf 'not json {{{' > "$AMS"
N=$((N+1))
if amrun >/dev/null 2>&1; then
  FAIL=$((FAIL+1)); printf '  FAIL %s\n' "an unparseable settings file is overwritten"
elif [ "$(cat "$AMS")" = "not json {{{" ]; then
  PASS=$((PASS+1)); printf '  ok   %s\n' "an unparseable settings file is refused, not rewritten"
else
  FAIL=$((FAIL+1)); printf '  FAIL %s\n       became: %s\n' "an unparseable settings file was altered" "$(cat "$AMS")"
fi

# Write|Edit|MultiEdit is not the only way to change a file. A session edited
# twelve source files through `python3 - <<'PY'` in Bash and neither gate fired.
echo "skill gate covers Bash"
newrepo sg_bash
mkdir -p .claude/skills/demo
printf -- '---\nname: demo\n---\n## Rules\n- x\n' > .claude/skills/demo/SKILL.md
node -e "import('$HERE/../cli/lib/setup-hook.mjs').then(m=>m.setupHook('$PWD'))" >/dev/null 2>&1
SKG=".claude/hooks/skill-gate.sh"

gate() {  # gate <label> <deny|allow> <tool> <command>
  N=$((N+1))
  rm -f /tmp/claude-skill-gate-gt$RUN
  out=$(printf '%s' "{\"session_id\":\"gt$RUN\",\"tool_name\":\"$3\",\"tool_input\":{\"command\":\"$4\"}}" | bash "$SKG")
  got=allow; case "$out" in *deny*) got=deny ;; esac
  if [ "$got" = "$2" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s — want %s, got %s\n' "$1" "$2" "$got"; fi
}

gate "a heredoc into python is gated" deny Bash "python3 - <<'PY'"
gate "a redirect into a file is gated" deny Bash "cat > src/foo.ts"
gate "sed -i is gated" deny Bash "sed -i 's/a/b/' x.ts"
gate "a read-only command is not gated" allow Bash "git status --short"
gate "a redirect to /dev/null is not a write" allow Bash "npm test 2>/dev/null"
gate "the command that clears the gate is never gated" allow Bash "touch /tmp/claude-skill-gate-gt$RUN"

# Skills are about code. A repo full of PLAN_*.md hit this gate on every write.
gatef() {  # gatef <label> <deny|allow> <file_path>
  N=$((N+1))
  rm -f /tmp/claude-skill-gate-gt$RUN
  out=$(printf '%s' "{\"session_id\":\"gt$RUN\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$3\"}}" | bash "$SKG")
  got=allow; case "$out" in *deny*) got=deny ;; esac
  if [ "$got" = "$2" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s — want %s, got %s\n' "$1" "$2" "$got"; fi
}

gatef "writing a plan document is not gated" allow "PLAN_notas.md"
gatef "writing a source file is gated" deny "src/lib/expenses.ts"
gatef "config files stay gated" deny "tsconfig.json"
gate "a heredoc writing markdown is not gated" allow Bash "cat > PREPLAN_x.md <<EOF"
gate "a heredoc writing source is gated" deny Bash "cat > src/a.ts <<EOF"
. "$HERE/selftest-mandatory-skills.sh"


# The 200-line ratchet has its own file: adding these cases here pushed this
# one past its own baseline, which is the rule working.
. "$HERE/selftest-line-limit.sh"
. "$HERE/selftest-structure.sh"

. "$HERE/selftest-fetch.sh"

# --------------------------------------------- a skill that GAINS a reference file
# A bundle grows: react gained FORMS.md and SHADCN.md. A project that installed
# the skill before those existed has to receive them, or it keeps a SKILL.md
# routing to files that are not there.
echo "upgrading a skill that gained reference files"
newrepo skillupg
mkdir -p .claude/skills/react
printf -- '---\nname: react\n---\n# old copy, no references\n' > .claude/skills/react/SKILL.md
node -e "
  const src = '$HERE/..';
  Promise.all([import(src + '/cli/lib/local.mjs'), import(src + '/cli/lib/install.mjs')])
    .then(async ([local, install]) => {
      const skills = await local.makeLocalSource(src).fetchSkills();
      const react = skills.find((s) => s.dirName === 'react');
      await install.installSkills([react], '$PWD');
    });
" >/dev/null 2>&1

have() {  # have <label> <path>
  N=$((N+1))
  if [ -s "$2" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s — %s missing or empty\n' "$1" "$2"; fi
}

have "a newly added reference file arrives" .claude/skills/react/FORMS.md
have "a second one does too"                .claude/skills/react/SHADCN.md
have "the existing references are still there" .claude/skills/react/COMPONENT-DESIGN.md
N=$((N+1))
if grep -q 'FORMS.md' .claude/skills/react/SKILL.md; then
  PASS=$((PASS+1)); echo "  ok   SKILL.md was replaced, not left stale"
else
  FAIL=$((FAIL+1)); echo "  FAIL SKILL.md still the old copy — it does not route to FORMS.md"
fi

# ------------------------------------------------------------ upgrade, not just install
# Every hook bug that reached a release survived because it was only ever tested
# as a FRESH install. A project that already had an older version kept whatever
# settings.json it was first written with — which is how the skill gates went on
# watching Write|Edit|MultiEdit after they learned to cover Bash.
echo "upgrading an existing install"
newrepo upg
mkdir -p .claude/skills/demo .claude/hooks
printf -- '---\nname: demo\n---\n## Rules\n- x\n' > .claude/skills/demo/SKILL.md
cat > .claude/settings.json <<'OLD'
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Write|Edit|MultiEdit",
        "hooks": [{ "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/skill-gate.sh" }] }
    ]
  }
}
OLD
node -e "import('$HERE/../cli/lib/setup-hook.mjs').then(m=>m.setupHook('$PWD'))" >/dev/null 2>&1

check_json() {  # check_json <label> <node expression returning true>
  N=$((N+1))
  if node -e "const s=require('$PWD/.claude/settings.json'); process.exit(($2)?0:1)" 2>/dev/null; then
    PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL+1)); printf '  FAIL %s\n       settings.json: %s\n' "$1" "$(cat "$PWD/.claude/settings.json" | tr -d '\n ')"
  fi
}

check_json "a stale matcher is corrected, not left alone" \
  "s.hooks.PreToolUse.find(e=>e.hooks[0].command.endsWith('skill-gate.sh')).matcher==='Write|Edit|MultiEdit|Bash'"
check_json "the hook is not registered twice" \
  "s.hooks.PreToolUse.filter(e=>e.hooks[0].command.endsWith('skill-gate.sh')).length===1"
check_json "hooks missing from the old file are added" \
  "s.hooks.Stop && s.hooks.Stop.some(e=>e.hooks[0].command.endsWith('gauntlet.sh'))"
check_json "an upgrade gains the SessionStart version check" \
  "s.hooks.SessionStart && s.hooks.SessionStart.some(e=>e.hooks[0].command.endsWith('version-check.sh'))"

# Both gates clear by touching a marker under /tmp, and auto mode's classifier
# refuses a touch whose only purpose is to unlock a gate — so the application
# gate could not be satisfied there at all, and the model ended up asking its
# user to run the touch by hand. The old settings.json here has no permissions
# key at all, which is what every install before this looked like.
check_json "an upgrade gains the marker allowlist" \
  "s.permissions && s.permissions.allow.includes('Bash(touch /tmp/claude-skill-acked-*)')"
check_json "all three markers are allowed" \
  "['gate','acked','loaded'].every(k=>s.permissions.allow.includes('Bash(touch /tmp/claude-skill-'+k+'-*)'))"

node -e "import('$HERE/../cli/lib/setup-hook.mjs').then(m=>m.setupHook('$PWD'))" >/dev/null 2>&1
check_json "reinstalling does not duplicate the rules" \
  "s.permissions.allow.filter(r=>r==='Bash(touch /tmp/claude-skill-acked-*)').length===1"

# A version nudge that costs a network round trip at session start is a version
# nudge that hangs the session on a bad connection. This one only ever reads a
# cache, and says nothing at all until it has one.
echo "version check"
VC="$HERE/version-check.sh"
vc() {  # vc <label> <expected substring, or empty for no output> [setup...]
  N=$((N+1))
  out=$(bash "$VC" 2>&1)
  ok=1
  if [ -z "$2" ]; then
    [ -n "$out" ] && ok=0
  else
    case "$out" in *"$2"*) ;; *) ok=0 ;; esac
  fi
  if [ $ok = 1 ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n       want ~ %s\n       got: %s\n' "$1" "${2:-<nothing>}" "$out"
  fi
}

newrepo vc1
export HOME="$TMP/vchome"; mkdir -p "$HOME/.claude"
vc "no manifest, so nothing is said" ""

printf '{"catalogVersion":"2.0.0","skills":[]}\n' > .claude/.claude-skills.json
vc "no cache yet, so nothing is said" ""

echo "2.1.0" > "$HOME/.claude/.claude-skills-version"
vc "a newer published version is reported" "2.0.0 installed, 2.1.0 published"
vc "and not reported twice the same day" ""

rm -f "$HOME/.claude/.claude-skills-version-told"
echo "2.0.0" > "$HOME/.claude/.claude-skills-version"
vc "the same version is not an update" ""

echo "1.9.0" > "$HOME/.claude/.claude-skills-version"
vc "a cache behind the install is not an update" ""

echo "2.10.0" > "$HOME/.claude/.claude-skills-version"
vc "versions compare numerically, not as text" "2.0.0 installed, 2.10.0 published"

rm -f "$HOME/.claude/.claude-skills-version-told"
CLAUDE_SKILLS_NO_VERSION_CHECK=1 bash "$VC" > "$TMP/vc.out" 2>&1
N=$((N+1))
if [ ! -s "$TMP/vc.out" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "the opt-out silences it"
else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "the opt-out silences it"; fi
export HOME="$TMP/home"

# ------------------------------------------- build output is not a project
# Next.js writes a package.json into .next/, .next/dev/ and .next/standalone/.
# The tool-needs scan skipped only a hardcoded list of build dirs, so it walked
# into all three and told the user to install Stryker in each — and then dropped
# the real repo root, because those phantoms made it look like a root that
# delegates to a workspace. It asks git what is ignored now.
echo "tool needs, against build output"
newrepo toolneeds
printf '{"name":"app"}\n' > package.json
printf '.next/\n' > .gitignore
mkdir -p .next/standalone .next/dev
printf '{"name":"next"}\n' > .next/package.json
printf '{"name":"sa"}\n'   > .next/standalone/package.json
printf '{"name":"dev"}\n'  > .next/dev/package.json
node -e "
  import('$HERE/../cli/lib/local.mjs').then(async (local) => {
    const needs = await local.reportToolNeeds('$PWD');
    console.log(needs.map((n) => n.label).join(' '));
  });
" > "$TMP/needs.out" 2>&1
needs=$(cat "$TMP/needs.out")

N=$((N+1))
case "$needs" in
  *.next*) FAIL=$((FAIL+1)); printf '  FAIL %s\n       got %s\n' "gitignored build output is not a project" "$needs" ;;
  *)       PASS=$((PASS+1)); printf '  ok   %s\n' "gitignored build output is not a project" ;;
esac

N=$((N+1))
case "$needs" in
  *"<repo root>"*) PASS=$((PASS+1)); printf '  ok   %s\n' "the real root is still reported" ;;
  *)               FAIL=$((FAIL+1)); printf '  FAIL %s\n       got %s\n' "the real root is still reported" "$needs" ;;
esac
# The installer itself, and the Stryker scaffolding it runs — the CLI, not the
# gauntlet hook this file is named for.
. "$HERE/selftest-cli.sh"
. "$HERE/selftest-stryker.sh"
