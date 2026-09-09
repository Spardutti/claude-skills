#!/usr/bin/env bash
# Cases for which skills the gate makes mandatory, and for whom.
# Sourced by gauntlet-selftest.sh; shares its $HERE, $TMP, $N, $PASS, $FAIL.


# --------------------------------------------------------- mandatory skills
# The generic gate offers an all-SKIP escape, and a session took it: it rated
# every skill SKIP, touched the marker, and edited React files with none of the
# React rules loaded. A skill declaring both paths: and tracks: no longer gets
# that vote. These assert WHICH skills the deny names, not merely that it
# denied — a gate that denies for the wrong reason still reads as green.
echo "mandatory skills (paths + tracks)"
newrepo sg_must
mkdir -p .claude/skills/rx .claude/skills/api .claude/skills/plain
printf -- '---\nname: rx\ntracks: react@19.2\nmetadata:\n  gate-paths: "**/*.tsx, **/*.jsx"\n---\n## Rules\n- x\n' > .claude/skills/rx/SKILL.md
printf -- '---\nname: api\ntracks: fastapi@0.141 (pypi)\nmetadata:\n  gate-paths: "**/*.py"\n---\n## Rules\n- x\n' > .claude/skills/api/SKILL.md
# No paths:/tracks: — must stay advisory, or this change tightens skills that
# never opted in.
printf -- '---\nname: plain\n---\n## Rules\n- x\n' > .claude/skills/plain/SKILL.md
printf '%s\n' '{"dependencies":{"react":"19.2.0"}}' > package.json
printf '%s\n' '[project]' > pyproject.toml
printf '%s\n' 'dependencies = ["fastapi>=0.141"]' >> pyproject.toml
node -e "import('$HERE/../cli/lib/setup-hook.mjs').then(m=>m.setupHook('$PWD'))" >/dev/null 2>&1
SKG=".claude/hooks/skill-gate.sh"
MSID="ms$RUN"

# must <label> <allow|generic|comma-separated skill names> <file_path> [prime]
# prime: "marker" pre-touches the session gate marker; "loaded:a,b" pre-touches
# the per-skill loaded markers.
must() {
  N=$((N+1))
  rm -f /tmp/claude-skill-gate-$MSID /tmp/claude-skill-loaded-$MSID-*
  case "${4:-}" in
    marker) touch /tmp/claude-skill-gate-$MSID ;;
    loaded:*) touch /tmp/claude-skill-gate-$MSID
      for s in $(printf '%s' "${4#loaded:}" | tr ',' ' '); do
        touch "/tmp/claude-skill-loaded-$MSID-$s"
      done ;;
  esac
  out=$(printf '{"session_id":"%s","tool_name":"Write","tool_input":{"file_path":"%s"}}' "$MSID" "$3" | bash "$SKG")
  case "$out" in
    *"mandatory skills that are not loaded: "*)
      got=$(printf '%s' "$out" | sed 's/.*not loaded: //; s/\..*//; s/, /,/g') ;;
    *deny*) got=generic ;;
    *)      got=allow ;;
  esac
  if [ "$got" = "$2" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s — want %s, got %s\n' "$1" "$2" "$got"; fi
}

must "a tsx edit names the react skill"            rx      src/App.tsx
must "a touched marker does not excuse it"         rx      src/App.tsx        marker
must "loading the skill clears it"                 allow   src/App.tsx        loaded:rx
must "a py edit names the pypi-tracked skill"      api     app/main.py        marker
must "the wrong stack's skill is not demanded"     allow   app/main.py        loaded:api
must "a skill without paths stays advisory"        generic src/util.go
must "prose is still ungated"                      allow   NOTES.md           marker
must "a jsx edit matches the second glob"          rx      src/legacy/a.jsx

# The same file written through Bash must reach the same verdict, or the
# heredoc route walks past the mandatory skills the structured tools enforce.
N=$((N+1))
rm -f /tmp/claude-skill-gate-$MSID /tmp/claude-skill-loaded-$MSID-*
touch /tmp/claude-skill-gate-$MSID
bout=$(printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"cat > src/App.tsx <<EOF"}}' "$MSID" | bash "$SKG")
case "$bout" in
  *"not loaded: rx"*) PASS=$((PASS+1)); printf '  ok   %s\n' "a heredoc into tsx names the same skill" ;;
  *) FAIL=$((FAIL+1)); printf '  FAIL %s — got %s\n' "a heredoc into tsx names the same skill" "$bout" ;;
esac

# A .tsx file is not proof of React. Without the tracked dependency the skill
# must go back to being advisory, or every Astro and Solid repo is blocked on
# a React skill it should never load.
N=$((N+1))
printf '%s\n' '{"dependencies":{"astro":"5.0.0"}}' > package.json
rm -f /tmp/claude-skill-gate-$MSID /tmp/claude-skill-loaded-$MSID-*
touch /tmp/claude-skill-gate-$MSID
aout=$(printf '{"session_id":"%s","tool_name":"Write","tool_input":{"file_path":"src/App.tsx"}}' "$MSID" | bash "$SKG")
case "$aout" in
  *mandatory*) FAIL=$((FAIL+1)); printf '  FAIL %s — got %s\n' "no react dependency means no mandatory react skill" "$aout" ;;
  *) PASS=$((PASS+1)); printf '  ok   %s\n' "no react dependency means no mandatory react skill" ;;
esac
rm -f /tmp/claude-skill-gate-$MSID /tmp/claude-skill-loaded-$MSID-*

# A .sql file is SQL and a Dockerfile is a Dockerfile — no package declares
# either, so a skill naming paths and no tracks is taken at its word. This must
# not leak into the tracked skills: rx still needs its dependency.
echo "mandatory skills with no tracked package"
newrepo sg_pathonly
mkdir -p .claude/skills/dbq .claude/skills/dock .claude/skills/rx
printf -- '---\nname: dbq\nmetadata:\n  gate-paths: "**/*.sql"\n---\n## Rules\n- x\n' > .claude/skills/dbq/SKILL.md
printf -- '---\nname: dock\nmetadata:\n  gate-paths: "**/Dockerfile*, **/docker-compose*.yml"\n---\n## Rules\n- x\n' > .claude/skills/dock/SKILL.md
printf -- '---\nname: rx\ntracks: react@19.2\nmetadata:\n  gate-paths: "**/*.tsx"\n---\n## Rules\n- x\n' > .claude/skills/rx/SKILL.md
# Deliberately no package.json and no pyproject.toml: a repo with no manifest
# at all must still get its path-only skills.
node -e "import('$HERE/../cli/lib/setup-hook.mjs').then(m=>m.setupHook('$PWD'))" >/dev/null 2>&1
SKG=".claude/hooks/skill-gate.sh"
MSID="po$RUN"

must "a sql file needs no package to prove it"   dbq   db/migrate/001.sql   marker
must "a Dockerfile is matched by name"           dock  Dockerfile           marker
must "a compose file is matched too"             dock  docker-compose.yml   marker
must "loading it clears the path-only skill"     allow db/migrate/001.sql   loaded:dbq
must "a tracked skill still needs its package"   allow src/App.tsx          marker
rm -f /tmp/claude-skill-gate-$MSID /tmp/claude-skill-loaded-$MSID-*

N=$((N+1))
touch /tmp/claude-skill-gate-$MSID
dout=$(printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"cat > Dockerfile <<EOF"}}' "$MSID" | bash "$SKG")
case "$dout" in
  *"not loaded: dock"*) PASS=$((PASS+1)); printf '  ok   %s\n' "a heredoc into a Dockerfile names it too" ;;
  *) FAIL=$((FAIL+1)); printf '  FAIL %s — got %s\n' "a heredoc into a Dockerfile names it too" "$dout" ;;
esac
rm -f /tmp/claude-skill-gate-$MSID /tmp/claude-skill-loaded-$MSID-*

# code-structure and security-practices apply to every code file, so they claim
# **/*. That must reach every gated file and no ungated one — a universal skill
# that fired on prose too would gate every note the session writes.
echo "a universal skill claims every gated file"
newrepo sg_univ
mkdir -p .claude/skills/univ
printf -- '---\nname: univ\nmetadata:\n  gate-paths: "**/*"\n---\n## Rules\n- x\n' > .claude/skills/univ/SKILL.md
node -e "import('$HERE/../cli/lib/setup-hook.mjs').then(m=>m.setupHook('$PWD'))" >/dev/null 2>&1
SKG=".claude/hooks/skill-gate.sh"
MSID="uv$RUN"

must "a ts file is claimed"                univ  src/a.ts              marker
must "a python file is claimed"            univ  app/main.py           marker
must "a root config file is claimed"       univ  vite.config.ts        marker
must "prose is not claimed"                allow NOTES.md              marker
must "the settings file is not claimed"    allow .claude/settings.json marker
must "loading it clears every file"        allow src/a.ts              loaded:univ
rm -f /tmp/claude-skill-gate-$MSID /tmp/claude-skill-loaded-$MSID-*
. "$HERE/selftest-subagent-skills.sh"
