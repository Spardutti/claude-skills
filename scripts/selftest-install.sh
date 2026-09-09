#!/usr/bin/env bash
# Cases for installing over an EXISTING install rather than a fresh one: a
# skill that gained reference files, hooks registered under an old matcher,
# the once-a-day version notice, and what a project still needs.
# Sourced by gauntlet-selftest.sh; shares its $HERE, $TMP, $N, $PASS, $FAIL.

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
  import('$HERE/../cli/lib/tool-needs.mjs').then(async (local) => {
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