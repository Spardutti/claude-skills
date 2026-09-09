#!/usr/bin/env bash
# Cases for the skill gates: the message they deny with, the files they must
# never gate, the auto-mode rule that lets them be cleared, and Bash as a way
# of writing files.
# Sourced by gauntlet-selftest.sh; shares its $HERE, $TMP, $N, $PASS, $FAIL.



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

amrun() { node -e "import('$HERE/../cli/lib/auto-mode.mjs').then(m=>m.writeAutoModeRule('$AMH')).catch(e=>{console.error(e.message);process.exit(1)})"; }

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