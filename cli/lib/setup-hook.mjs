import { mkdir, writeFile, readFile, chmod, unlink } from "node:fs/promises";
import { join, resolve, dirname } from "node:path";
import { spawn } from "node:child_process";
import { homedir } from "node:os";

// PreToolUse gate on Write|Edit|MultiEdit. Blocks the tool call unless
// a per-session marker file exists at /tmp/claude-skill-gate-<SESSION_ID>.
// Per-session (not per-prompt) so simple confirmations like "yes" don't
// re-lock the gate after evaluation has already happened in the session.
// The PostToolUse hook on Skill creates the marker automatically; for
// all-SKIP cases the model can `touch` the path manually.
//
// Pass-through cases:
//   - project has no .claude/skills/*/SKILL.md files
//   - session_id missing from hook input
const GATE_SCRIPT = `#!/bin/bash
# PreToolUse gate: forces skill evaluation before file-writing tools run.

INPUT=$(cat)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

if ! find "$PROJECT_DIR" -path '*/.claude/skills/*/SKILL.md' 2>/dev/null | grep -q .; then
  exit 0
fi

SESSION_ID=$(printf '%s' "$INPUT" | grep -o '"session_id":"[^"]*"' | head -1 | sed 's/"session_id":"//; s/"$//')
if [ -z "$SESSION_ID" ]; then
  exit 0
fi

MARKER="/tmp/claude-skill-gate-$SESSION_ID"
if [ -f "$MARKER" ]; then
  exit 0
fi

# Write|Edit|MultiEdit is not the only way to change a file. A session that edits
# through \`python3 - <<'PY'\` in Bash walked past this gate entirely — twelve
# source files, not one prompt — and some harnesses actively tell the model to
# prefer Bash for edits. So Bash is gated too, but only for commands that can
# write, and only until the gate is cleared once for the session.

# Skills are about code. Blocking a plan document to ask how the React rules
# apply is pure noise, and a repo full of PLAN_*.md hits it on every write.
# Config files stay gated — skills do have rules about tsconfig and compose.
PROSE_EXT='md|mdx|txt|rst|adoc|png|jpg|jpeg|gif|svg|webp|ico'
CODE_EXT='ts|tsx|js|jsx|mjs|cjs|py|go|rs|java|kt|rb|php|c|h|cpp|hpp|cs|swift|sql|sh|json|ya?ml|toml'

TOOL=$(printf '%s' "$INPUT" | grep -o '"tool_name":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//')

if [ "$TOOL" != "Bash" ]; then
  # The structured tools name their target outright.
  TARGET=$(printf '%s' "$INPUT" | grep -o '"file_path":[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//')
  case "$TARGET" in
    # The settings file that configures the escape hatch cannot sit behind the
    # gate, or a denied ack has no way to be un-denied.
    */.claude/settings.json|*/.claude/settings.local.json) exit 0 ;;
    *.*) printf '%s' "$TARGET" | grep -qiE "\.($PROSE_EXT)$" && exit 0 ;;
  esac
fi
if [ "$TOOL" = "Bash" ]; then
  CMD=$(printf '%s' "$INPUT" | grep -o '"command":[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//')

  # Never gate the command that clears the gate, or this deadlocks.
  case "$CMD" in
    *claude-skill-gate-*|*claude-skill-acked-*|*claude-skill-loaded-*) exit 0 ;;
    *.claude/settings.json*|*.claude/settings.local.json*) exit 0 ;;
  esac

  # /dev/null redirects are not file writes; drop them before looking for one.

  # A command that names a prose file and no code file is writing prose.
  if printf '%s' "$CMD" | grep -qiE "\.($PROSE_EXT)([^A-Za-z0-9]|$)" \
     && ! printf '%s' "$CMD" | grep -qiE "\.($CODE_EXT)([^A-Za-z0-9]|$)"; then
    exit 0
  fi
  STRIPPED=$(printf '%s' "$CMD" | sed 's![12]*>>*[[:space:]]*/dev/null!!g')
  WRITES=""
  case "$STRIPPED" in
    *">"*|*"tee "*|*"sed -i"*|*"cp "*|*"mv "*|*"truncate "*|*"dd "*) WRITES=1 ;;
  esac
  # An interpreter given inline code or a heredoc can write anything, and the
  # shell shows no redirect at all — this is the shape that got past the gate.
  case "$CMD" in
    *"<<"*|*python*" -c"*|*node*" -e"*|*perl*" -e"*|*ruby*" -e"*) WRITES=1 ;;
  esac
  [ -z "$WRITES" ] && exit 0
fi


cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: skill evaluation required before file edits in this session.\\n\\nStep 1 — evaluate every available skill as ACTIVATE or SKIP with a one-line reason.\\n\\nStep 2 — you MUST take EXACTLY ONE of these tool actions to clear the gate. Listing skills in text is NOT enough; retrying the edit without doing one of these will be denied again:\\n  (a) If any skill is ACTIVATE → call Skill(name) for it. This auto-clears the gate.\\n  (b) If ALL skills are SKIP → run this Bash tool call: touch /tmp/claude-skill-gate-$SESSION_ID\\n\\nStep 3 — only after Step 2 completes, retry the file edit."}}
EOF
exit 0
`;

// PostToolUse on Skill: auto-creates the per-session gate marker AND a
// per-skill "loaded" marker. The application gate uses the loaded marker
// to require the model to explicitly apply each loaded skill before the
// first Write/Edit in this session.
const AUTO_MARK_SCRIPT = `#!/bin/bash
# PostToolUse on Skill: marks gate satisfied + records loaded skill.

INPUT=$(cat)

SESSION_ID=$(printf '%s' "$INPUT" | grep -o '"session_id":"[^"]*"' | head -1 | sed 's/"session_id":"//; s/"$//')
if [ -z "$SESSION_ID" ]; then
  exit 0
fi

touch "/tmp/claude-skill-gate-$SESSION_ID"

SKILL_NAME=$(printf '%s' "$INPUT" | grep -o '"skill":"[^"]*"' | head -1 | sed 's/"skill":"//; s/"$//')
if [ -n "$SKILL_NAME" ]; then
  # Sanitize: only allow [A-Za-z0-9_-] in the marker filename.
  SAFE_NAME=$(printf '%s' "$SKILL_NAME" | tr -cd 'A-Za-z0-9_-')
  if [ -n "$SAFE_NAME" ]; then
    touch "/tmp/claude-skill-loaded-$SESSION_ID-$SAFE_NAME"
  fi
fi

exit 0
`;

// PreToolUse application gate: requires the model to explicitly apply each
// loaded skill before the first Write/Edit. Reads SKILL.md's Rules section
// and inlines it in the deny message. One ack per skill per session.
const APPLICATION_GATE_SCRIPT = `#!/bin/bash
# PreToolUse application gate: blocks file edits until each loaded skill
# has been explicitly applied (acked) for this session.

INPUT=$(cat)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

SESSION_ID=$(printf '%s' "$INPUT" | grep -o '"session_id":"[^"]*"' | head -1 | sed 's/"session_id":"//; s/"$//')
if [ -z "$SESSION_ID" ]; then
  exit 0
fi

# Defer to the loading gate until it's been satisfied this session.
if [ ! -f "/tmp/claude-skill-gate-$SESSION_ID" ]; then
  exit 0
fi

# Same reason as the loading gate: Bash can write files, and a heredoc into an
# interpreter shows no redirect at all.

# Skills are about code. Blocking a plan document to ask how the React rules
# apply is pure noise, and a repo full of PLAN_*.md hits it on every write.
# Config files stay gated — skills do have rules about tsconfig and compose.
PROSE_EXT='md|mdx|txt|rst|adoc|png|jpg|jpeg|gif|svg|webp|ico'
CODE_EXT='ts|tsx|js|jsx|mjs|cjs|py|go|rs|java|kt|rb|php|c|h|cpp|hpp|cs|swift|sql|sh|json|ya?ml|toml'

TOOL=$(printf '%s' "$INPUT" | grep -o '"tool_name":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//')

if [ "$TOOL" != "Bash" ]; then
  # The structured tools name their target outright.
  TARGET=$(printf '%s' "$INPUT" | grep -o '"file_path":[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//')
  case "$TARGET" in
    # The settings file that configures the escape hatch cannot sit behind the
    # gate, or a denied ack has no way to be un-denied.
    */.claude/settings.json|*/.claude/settings.local.json) exit 0 ;;
    *.*) printf '%s' "$TARGET" | grep -qiE "\.($PROSE_EXT)$" && exit 0 ;;
  esac
fi
if [ "$TOOL" = "Bash" ]; then
  CMD=$(printf '%s' "$INPUT" | grep -o '"command":[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//')
  case "$CMD" in
    *claude-skill-gate-*|*claude-skill-acked-*|*claude-skill-loaded-*) exit 0 ;;
    *.claude/settings.json*|*.claude/settings.local.json*) exit 0 ;;
  esac

  # A command that names a prose file and no code file is writing prose.
  if printf '%s' "$CMD" | grep -qiE "\.($PROSE_EXT)([^A-Za-z0-9]|$)" \
     && ! printf '%s' "$CMD" | grep -qiE "\.($CODE_EXT)([^A-Za-z0-9]|$)"; then
    exit 0
  fi
  STRIPPED=$(printf '%s' "$CMD" | sed 's![12]*>>*[[:space:]]*/dev/null!!g')
  WRITES=""
  case "$STRIPPED" in
    *">"*|*"tee "*|*"sed -i"*|*"cp "*|*"mv "*|*"truncate "*|*"dd "*) WRITES=1 ;;
  esac
  case "$CMD" in
    *"<<"*|*python*" -c"*|*node*" -e"*|*perl*" -e"*|*ruby*" -e"*) WRITES=1 ;;
  esac
  [ -z "$WRITES" ] && exit 0
fi


# Collect every loaded-but-unacked skill so a single ack clears them all.
UNACKED=""
for marker in /tmp/claude-skill-loaded-$SESSION_ID-*; do
  [ ! -f "$marker" ] && continue
  skill_name="\${marker##/tmp/claude-skill-loaded-$SESSION_ID-}"
  if [ ! -f "/tmp/claude-skill-acked-$SESSION_ID-$skill_name" ]; then
    UNACKED="$UNACKED $skill_name"
  fi
done
UNACKED="\${UNACKED# }"

if [ -z "$UNACKED" ]; then
  exit 0
fi

# One touch call with explicit paths — brace expansion is not used because
# bash leaves a single-element {name} literal, creating a garbage marker.
ACK_CMD="touch"
NAMES=""
RULES_BLOCKS=""
for skill in $UNACKED; do
  ACK_CMD="$ACK_CMD /tmp/claude-skill-acked-$SESSION_ID-$skill"
  NAMES="$NAMES, '$skill'"
  SKILL_MD="$PROJECT_DIR/.claude/skills/$skill/SKILL.md"
  RULES=""
  if [ -f "$SKILL_MD" ]; then
    RULES=$(awk '/^## Rules/{flag=1} /^## /{if(flag && !/^## Rules/)exit} flag' "$SKILL_MD")
  fi
  if [ -z "$RULES" ]; then
    RULES="(Rules section not found in $SKILL_MD — refer to the loaded skill content already in context.)"
  fi
  RULES_BLOCKS="$RULES_BLOCKS
### Rules from $skill/SKILL.md

$RULES
"
done
NAMES="\${NAMES#, }"

MSG="BLOCKED: loaded skills not yet applied to your work: $NAMES

Before this Write/Edit, you must:

1. For each skill listed above, say whether it applies to the file you're about to
   write. If it does not — a Python skill and a TypeScript file, say — write
   \\"does not apply\\" and move on. Do not invent a connection.
2. For the ones that do apply: state the specific rules that bear on this file, and
   how your next write respects each.
3. Then ack all of them in a single Bash tool call:
     $ACK_CMD

One ack per skill per session. After acking, retry the Write/Edit.

If that Bash call is denied by the auto mode classifier, STOP. Do not ask your
user to run it for you, do not look for another route to create the files, and
do not try to add the allow rule yourself — an agent editing permission settings
is denied by the same classifier, so that attempt fails too and costs a round
trip that ends in the same place. All three are what the classifier is there to
stop, and asking a human to run a command you were just denied makes them the
tool that performs it. Report this to them instead and let them decide:

  Auto mode's built-in Auto-Mode Bypass rule counts a hook's ack file as working
  around the permission system. It is a soft rule, so an allow entry clears it.
  The user has to add it — you cannot. The shortest route is for them to re-run
  npx @spardutti/claude-skills and accept the auto mode prompt, which writes it.
  Otherwise /permissions, Auto mode tab. Editing the file by hand works too, and
  it has to be ~/.claude/settings.json — the classifier does not read a
  project's .claude/settings.json. Keep the
  \\\$defaults line or every built-in allow rule is discarded:

  \\"autoMode\\": { \\"allow\\": [ \\"\\\$defaults\\",
    \\"Touching marker files under /tmp/claude-skill-gate-*, /tmp/claude-skill-acked-*
     and /tmp/claude-skill-loaded-* is allowed: they are acknowledgement files for
     the user's own PreToolUse skill gates. Creating one satisfies a workflow gate
     the user installed, grants no permission and executes no code, and is a false
     positive for Auto-Mode Bypass.\\" ] }
$RULES_BLOCKS"

json_escape() {
  local s="$1"
  s="\${s//\\\\/\\\\\\\\}"
  s="\${s//\\"/\\\\\\"}"
  s="\${s//$'\\n'/\\\\n}"
  s="\${s//$'\\r'/\\\\r}"
  s="\${s//$'\\t'/\\\\t}"
  printf '"%s"' "$s"
}

REASON=$(json_escape "$MSG")
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\\n' "$REASON"
exit 0
`;

// Stop hook: fast deterministic gates on the changed diff. Silent when green,
// blocks the turn when a gate is red so the model fixes it before the user sees
// it. Canonical source: scripts/gauntlet.sh in the claude-skills repo.
const GAUNTLET_SCRIPT = `#!/usr/bin/env bash
# gauntlet.sh — Stop hook: fast deterministic gates on the changed diff.
#
# Runs when Claude finishes a turn. Silent when green. On a red gate it exits 2:
# the turn keeps going, the user is shown why, and Claude is handed the failure.
#
# Two things the hook contract makes non-negotiable:
#   - stop_hook_active must short-circuit, or a red gate loops forever.
#   - A hook that hits its timeout (600s default for command hooks) is cancelled
#     and its output discarded, so the turn ends as if the hook never ran. Keep
#     the gates fast; that is a silent pass, not a block.
#
# Only cheap gates belong here (target: under ~30s). Mutation testing, deep
# review, and the spec checklist are the /gauntlet command's job, not this hook's.
#
# Skip ladder, cheapest first — quits at the first "no":
#   1. no changed files
#   2. no changed *code* files (docs/config only)
#   3. this exact diff already passed
#   4. no gates detected for this repo
#
# Config, both optional and both KEY=value files that get sourced in this order:
#   ~/.claude/gauntlet.conf          your defaults for every project
#   <project>/.claude/gauntlet.conf  overrides for this one; wins key by key
#   GAUNTLET_OFF=1                 disable entirely
#   GAUNTLET_TYPECHECK="cmd"       explicit typecheck command ("" to skip)
#   GAUNTLET_TEST="cmd"            explicit test command; $FILES = changed code files
#   GAUNTLET_CODE_EXT="ts|tsx|py"  override which extensions count as code
#   GAUNTLET_DEBUG=1               print the outcome to stderr on every run
#   GAUNTLET_REQUIRE_TESTS=1       block when a runner matched 0 test files
#
# Setting either command switches the whole repo to explicit mode — auto-detection
# is off, and only what you set runs.
#
# Every run records why it ended in /tmp/claude-gauntlet-<session>.why, so a green
# run and a skipped one are told apart without re-running the hook.

set -uo pipefail

INPUT=$(cat 2>/dev/null || true)

# Never re-block a turn we already blocked — this would loop forever.
case "$INPUT" in
  *'"stop_hook_active":true'*) exit 0 ;;
esac

SESSION_ID=$(printf '%s' "$INPUT" | grep -o '"session_id":"[^"]*"' | head -1 \\
             | sed 's/"session_id":"//; s/"$//')
if [ -z "$SESSION_ID" ]; then SESSION_ID="nosession"; fi
MARKER="/tmp/claude-gauntlet-$SESSION_ID"
WHY="$MARKER.why"

# Records why this run ended, so "green" and "never ran" stop looking identical.
quit() {
  printf '%s\\n' "$1" > "$WHY" 2>/dev/null
  if [ -n "\${GAUNTLET_DEBUG:-}" ]; then printf 'gauntlet: %s\\n' "$1" >&2; fi
  exit 0
}

PROJECT_DIR="\${CLAUDE_PROJECT_DIR:-}"
if [ -z "$PROJECT_DIR" ]; then PROJECT_DIR="$PWD"; fi
cd "$PROJECT_DIR" 2>/dev/null || quit "skipped: project dir unreadable"

git rev-parse --git-dir >/dev/null 2>&1 || quit "skipped: not a git repo"

GAUNTLET_OFF=""
GAUNTLET_TYPECHECK="__auto__"
GAUNTLET_TEST="__auto__"
GAUNTLET_CODE_EXT="ts|tsx|js|jsx|mjs|cjs|py|go|rs|java|kt|rb|php|c|h|cpp|hpp|cs|swift|sql"
# Global defaults first, then the project's on top — project wins, key by key.
if [ -n "\${HOME:-}" ] && [ -f "$HOME/.claude/gauntlet.conf" ]; then . "$HOME/.claude/gauntlet.conf"; fi
if [ -f "$PROJECT_DIR/.claude/gauntlet.conf" ]; then . "$PROJECT_DIR/.claude/gauntlet.conf"; fi
if [ -n "$GAUNTLET_OFF" ]; then quit "skipped: GAUNTLET_OFF is set"; fi

# ---------------------------------------------------------------- skip rule 1
CHANGED=$( { git diff --name-only HEAD 2>/dev/null; \\
             git ls-files --others --exclude-standard 2>/dev/null; } | sort -u )
if [ -z "$CHANGED" ] && [ -z "\${GAUNTLET_DRYRUN:-}" ]; then quit "skipped: no changed files"; fi

# ---------------------------------------------------------------- skip rule 2
# .stryker-tmp holds Stryker's sandbox — a full copy of the project. A crashed
# run leaves it behind, and then every file in it looks like a changed file.
FILES_NL=$(printf '%s\\n' "$CHANGED" | grep -E "\\.($GAUNTLET_CODE_EXT)$" \\
           | grep -vE '(^|/)\\.stryker-tmp/' || true)
if [ -z "$FILES_NL" ] && [ -z "\${GAUNTLET_DRYRUN:-}" ]; then
  quit "skipped: no changed code files (docs/config only)"
fi

# ---------------------------------------------------------------- skip rule 3
# The repo path is part of the hash: one session can touch several repos, and two
# of them can legitimately hold an identical diff.
DIFF_HASH=$( { printf '%s\\n' "$PROJECT_DIR"; git diff HEAD 2>/dev/null; printf '%s\\n' "$CHANGED"; } \\
             | git hash-object --stdin 2>/dev/null )
if [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$DIFF_HASH" ] \\
   && [ -z "\${GAUNTLET_DRYRUN:-}" ]; then
  quit "skipped: this diff already passed"
fi

# ---------------------------------------------------------------- skip rule 4
# A monorepo can hold more than one stack, so detection collects every gate it
# finds rather than stopping at the first. Each gate carries the file pattern it
# applies to, and is skipped entirely when the diff touched none of those files —
# so a Python-only change never runs the JS suite, and vice versa.
TC_GATES=""
TEST_GATES=""
SKIP_NOTE=""

add_gate() {  # kind (typecheck|tests), file regex, command
  LINE=$(printf '%s\\t%s\\t%s' "$1" "$2" "$3")
  if [ "$1" = "typecheck" ]; then
    TC_GATES="$TC_GATES$LINE
"
  else
    TEST_GATES="$TEST_GATES$LINE
"
  fi
}

JS_EXT='(ts|tsx|js|jsx|mjs|cjs)'

# Builds the gates for one directory. "" is the repo root; anything else is a
# nested project, and its gates match only files under that path. Commands run
# from inside the directory, which is why the file list is passed as absolute
# paths — a relative path would not survive the cd.
add_dir_gates() {
  d="$1"
  if [ -n "$d" ]; then pre="^$d/.*\\\\." ; run="cd $d && " ; else pre='\\.' ; run="" ; fi
  have_tc=""; have_test=""
  [ -n "$d" ] && [ -n "\${ROOT_TC:-}" ] && have_tc="skip"
  [ -n "$d" ] && [ -n "\${ROOT_TEST:-}" ] && have_test="skip"

  if [ -f "$d\${d:+/}package.json" ]; then
    pkg="$d\${d:+/}package.json"
    if [ -z "$have_tc" ]; then
      if grep -q '"typecheck"[[:space:]]*:' "$pkg"; then
        add_gate typecheck "$pre($JS_EXT)\\$" "\${run}npm run --silent typecheck"
      elif [ -f "$d\${d:+/}tsconfig.json" ]; then
        add_gate typecheck "$pre(ts|tsx)\\$" "\${run}npx --no-install tsc --noEmit"
      fi
    fi
    if [ -z "$have_test" ]; then
      if grep -q '"vitest"' "$pkg"; then
        add_gate tests "$pre($JS_EXT)\\$" "\${run}npx --no-install vitest related --run \\$FILES"
      elif grep -q '"jest"' "$pkg"; then
        add_gate tests "$pre($JS_EXT)\\$" "\${run}npx --no-install jest --findRelatedTests \\$FILES --passWithNoTests"
      elif grep -q '"test"[[:space:]]*:' "$pkg"; then
        add_gate tests "$pre($JS_EXT)\\$" "\${run}CI=1 npm run --silent test"
      fi
    fi
  fi

  if [ -f "$d\${d:+/}pyproject.toml" ] || [ -f "$d\${d:+/}pytest.ini" ] || [ -f "$d\${d:+/}setup.cfg" ]; then
    if [ -z "$have_tc" ]; then
      if [ -f "$d\${d:+/}mypy.ini" ] || grep -qs 'tool.mypy' "$d\${d:+/}pyproject.toml"; then
        add_gate typecheck "\${pre}py\\$" "\${run}python -m mypy ."
      fi
    fi
    if [ -z "$have_test" ]; then
      add_gate tests "\${pre}py\\$" "\${run}python -m pytest -q"
    fi
  fi
}

detect() {
  # Explicit config wins outright: auto-detection is off for the whole repo.
  if [ "$GAUNTLET_TEST" != "__auto__" ] || [ "$GAUNTLET_TYPECHECK" != "__auto__" ]; then
    if [ "$GAUNTLET_TYPECHECK" != "__auto__" ] && [ -n "$GAUNTLET_TYPECHECK" ]; then
      add_gate typecheck '.' "$GAUNTLET_TYPECHECK"
    fi
    if [ "$GAUNTLET_TEST" != "__auto__" ] && [ -n "$GAUNTLET_TEST" ]; then
      add_gate tests '.' "$GAUNTLET_TEST"
    fi
    return
  fi

  add_dir_gates ""

  # Many repos keep no manifest at the root — the code lives in web/, api/,
  # backend/, packages/*. Look two levels down, but only for the kind of gate the
  # root did not already provide, so a repo that works today keeps working.
  ROOT_TC="$TC_GATES"
  ROOT_TEST="$TEST_GATES"
  while IFS= read -r manifest; do
    [ -z "$manifest" ] && continue
    d=$(dirname "$manifest")
    d=\${d#./}
    [ "$d" = "." ] && continue
    add_dir_gates "$d"
  done <<< "$(find . -mindepth 2 -maxdepth 3 \\
               \\( -name package.json -o -name pyproject.toml -o -name pytest.ini \\) \\
               -not -path '*/node_modules/*' -not -path '*/.git/*' \\
               -not -path '*/dist/*' -not -path '*/build/*' \\
               -not -path '*/.venv/*' -not -path '*/venv/*' 2>/dev/null | sort)"
}
detect

# Typechecks before tests — cheapest first, so the slow gate is usually unpaid.
GATES="$TC_GATES$TEST_GATES"
if [ -n "\${GAUNTLET_DRYRUN:-}" ]; then
  if [ -z "$GATES" ]; then quit "would run: nothing — no gates detected"; fi
  quit "would run: $(printf '%s' "$GATES" | cut -f1,3 | tr '\\t' ' ' | tr '\\n' '; ')"
fi
if [ -z "$GATES" ]; then
  if [ -n "$SKIP_NOTE" ]; then quit "skipped: $SKIP_NOTE"; fi
  quit "skipped: no gates detected for this repo"
fi

# ------------------------------------------------------------------ the gates
FAILED=""
OUTPUT=""
NO_TEST_MATCH=""
RAN=""
# Kept in variables on purpose: a bare \`}\` inside a \${var//pat/repl} replacement
# closes the expansion early and silently mangles the command.
FILES_REPL='"\${FILE_ARR[@]}"'
PAT_BRACE='\${FILES}'
PAT_PLAIN='$FILES'

while IFS=$'\\t' read -r GKIND GEXT GCMD; do
  [ -z "$GKIND" ] && continue
  GFILES=$(printf '%s\\n' "$FILES_NL" | grep -E "$GEXT" || true)
  [ -z "$GFILES" ] && continue
  # $FILES is substituted as a real argument list, not a space-joined string —
  # word splitting would tear "src/my folder/a.ts" into two bogus paths.
  mapfile -t REL_ARR <<< "$GFILES"
  FILE_ARR=()
  for f in "\${REL_ARR[@]}"; do FILE_ARR+=("$PROJECT_DIR/$f"); done
  export FILES=$(printf '%s' "$GFILES" | tr '\\n' ' ')
  GCMD_RUN=\${GCMD//"$PAT_BRACE"/$FILES_REPL}
  GCMD_RUN=\${GCMD_RUN//"$PAT_PLAIN"/$FILES_REPL}
  RAN="$RAN$GKIND "
  GATE_OUT=$(eval "$GCMD_RUN" 2>&1)
  if [ $? -ne 0 ]; then
    # A gate whose tool is not installed is a missing gate, not a failing one.
    # Blocking on it would wall off every turn until the user installs something.
    if printf '%s' "$GATE_OUT" | grep -qiE 'command not found|no module named|cannot find module|could not determine executable|canceled due to missing packages|missing script|is not recognized'; then
      SKIP_NOTE="the $GKIND tool is not installed"
      RAN="\${RAN%"$GKIND "}"
      continue
    fi
    FAILED="$GKIND"
    OUTPUT="$GATE_OUT"
    break
  fi
  # A runner handed files it has no tests for exits 0 and looks exactly like a
  # pass. It is the loudest false green: the changed code was never executed.
  if [ "$GKIND" = "tests" ] \\
     && printf '%s' "$GATE_OUT" | grep -qiE 'no test files found|no tests found|no tests ran'; then
    NO_TEST_MATCH="$GCMD"
    OUTPUT="$GATE_OUT"
  fi
done <<< "$GATES"

if [ -z "$FAILED" ] && [ -n "$NO_TEST_MATCH" ] && [ -n "\${GAUNTLET_REQUIRE_TESTS:-}" ]; then
  FAILED="tests"
  OUTPUT="$OUTPUT

The runner matched 0 test files for the changed code, so nothing was executed.
Write a test that covers the change, or unset GAUNTLET_REQUIRE_TESTS."
fi

if [ -z "$FAILED" ]; then
  printf '%s' "$DIFF_HASH" > "$MARKER"
  if [ -z "$RAN" ]; then
    if [ -n "$SKIP_NOTE" ]; then quit "skipped: $SKIP_NOTE"; fi
    quit "skipped: no gate applied to the changed files"
  elif [ -n "$SKIP_NOTE" ]; then
    quit "green: gates passed ($RAN) — but $SKIP_NOTE"
  elif [ -n "$NO_TEST_MATCH" ]; then
    quit "green: gates passed, but a runner matched 0 test files — that code was never executed"
  fi
  quit "green: gates passed ($RAN)"
fi

# ------------------------------------------------------------------ block red
# Last 60 lines only — the hook's reason is read by a model, not archived.
TAIL=$(printf '%s\\n' "$OUTPUT" | tail -60)
MSG="GAUNTLET FAILED: the $FAILED gate is red on the changed files.

Fix it before ending the turn. Do not weaken or delete a test to make this pass.
If the failure is unrelated to your change, say so explicitly and stop.

Changed code files:
$FILES

--- $FAILED output (last 60 lines) ---
$TAIL"

printf '%s\\n' "red: the $FAILED gate failed" > "$WHY" 2>/dev/null

# Exit 2 is the only path where a red is visible to the user: its stderr is shown
# to them as the reason the turn is continuing. Exit 0 with {"decision":"continue"}
# also keeps the turn going, but the reason reaches Claude alone — so a failing
# gate looked, from the outside, exactly like a gauntlet that does nothing.
printf '%s\\n' "$MSG" >&2
exit 2
`;

// The deterministic half of /ship's quality gate: file length and mutation,
// behind an exit code rather than in prose a model can talk past.
// Canonical source: scripts/ship-gate.sh.
const SHIP_GATE_SCRIPT = `#!/usr/bin/env bash
# ship-gate.sh — the deterministic half of /ship's quality gate.
#
# File length and mutation are not judgement calls, so they do not live in prose
# where a model can decide they are not worth it. They live here, behind an exit
# code. /ship runs this and obeys the result; the skills audit stays in the
# command, because that one genuinely needs a model.
#
#   bash .claude/hooks/ship-gate.sh [base-ref]
#   bash .claude/hooks/ship-gate.sh --key      print the receipt key and stop
#   bash .claude/hooks/ship-gate.sh --force    write a FORCED receipt, run nothing
#   bash .claude/hooks/ship-gate.sh --baseline record today's mutmut survivors as
#                                              accepted debt, write no receipt
#
# On completion it writes a RECEIPT at /tmp/claude-shipgate-<key>, and the
# PreToolUse hook refuses \`git commit\` / \`git push\` without a matching one. The
# point is that a gate has to be evidence rather than an instruction: a sentence
# saying "run this first" is a sentence an agent can decide is not worth it, and
# then report a pass it never earned. A receipt cannot be reported, only produced.
#
# The key is the content of everything about to ship, so it is the same before
# and after \`git commit\` — and it changes the moment anything is edited, which is
# what makes a fix re-gate itself instead of riding on the previous verdict.
#
# Exit codes:
#   0  clean — nothing over the line limit, nothing survived, nothing uncovered
#   1  findings that must be dealt with before shipping
#   2  ran, but could not prove the tests (a mutation tool is missing) — report,
#      don't block; the output names exactly what to install and where
#
# Config: the same .claude/gauntlet.conf as the Stop hook.
#   GAUNTLET_MAX_LINES=200   the per-file limit; 0 turns the check off
#   GAUNTLET_SOURCE_EXT=...  which extensions count as source. Deliberately NOT
#                            GAUNTLET_CODE_EXT: the Stop hook's key answers a
#                            different question, and a docs repo sets it to .md
#   GAUNTLET_IGNORE_EXT=...  extensions that need no gate at all. An extension in
#                            neither list is reported UNPROVEN rather than passed
#   GAUNTLET_IGNORE_FILES=.. space-separated globs, matched against /<path>, for
#                            files nobody wrote: generated code and vendored
#                            components. They are named in the output, never
#                            dropped silently. Set it to "" to gate everything
#   GAUNTLET_MUTATE="cmd"    one explicit mutation command for the whole repo,
#                            replacing per-project detection. $MUTATE_FLAGS holds
#                            the --mutate flags, $FILES the changed files.

set -uo pipefail

MODE=""
case "\${1:-}" in
  --key)      MODE=key; shift ;;
  --force)    MODE=force; shift ;;
  --baseline) MODE=baseline; shift ;;
esac

PROJECT_DIR="\${CLAUDE_PROJECT_DIR:-$PWD}"
cd "$PROJECT_DIR" 2>/dev/null || { echo "ship-gate: cannot read $PROJECT_DIR"; exit 1; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "ship-gate: not a git repo"; exit 1; }

# \`git diff --name-only\` prints paths from the repo ROOT, but CLAUDE_PROJECT_DIR
# can point at a subdirectory of it. Testing those paths from the subdirectory
# found no files at all, so the gate said "nothing to check" and wrote a PASS
# receipt over a diff it never looked at. Work from the root and the paths git
# prints are the paths this script tests. The receipt key moves with it, and the
# PreToolUse hook asks this script for the key rather than computing its own, so
# the two cannot disagree.
ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -n "$ROOT" ]; then
  cd "$ROOT" || { echo "ship-gate: cannot read $ROOT"; exit 1; }
  PROJECT_DIR="$ROOT"
fi

GAUNTLET_MAX_LINES=200
GAUNTLET_MUTATE=""
GAUNTLET_SOURCE_EXT="ts|tsx|js|jsx|mjs|cjs|py|go|rs|java|kt|rb|php|c|h|cpp|hpp|cs|swift|gd"
GAUNTLET_IGNORE_EXT="md|mdx|txt|rst|adoc|json|ya?ml|toml|lock|cfg|ini|env|csv|tsv|sql|html|css|scss|svg|png|jpg|jpeg|gif|webp|ico|pdf|woff2?|ttf|otf|mp3|mp4|wav|zip|gz|tres|tscn|import|godot"
GAUNTLET_IGNORE_FILES="*.gen.ts *.gen.tsx *.generated.* */migrations/*.py */alembic/versions/*.py */components/ui/*.tsx */*.config.*"
[ -n "\${HOME:-}" ] && [ -f "$HOME/.claude/gauntlet.conf" ] && . "$HOME/.claude/gauntlet.conf"
[ -f ".claude/gauntlet.conf" ] && . ".claude/gauntlet.conf"

# ------------------------------------------------------------------- the scope
BASE="\${1:-}"
if [ -z "$BASE" ]; then
  BASE=$(git merge-base HEAD develop 2>/dev/null \\
         || git merge-base HEAD main 2>/dev/null \\
         || git rev-list --max-parents=0 HEAD | head -1)
fi

CHANGED=$( { git diff "$BASE"...HEAD --name-only 2>/dev/null
             git diff HEAD --name-only 2>/dev/null
             git ls-files --others --exclude-standard 2>/dev/null; } | sort -u )

# The repo path plus the names and contents of the changed files, in a fixed
# order. The path is in there because the key is otherwise pure content: two
# repos holding the same file would share a receipt, and one would be waved
# through on the other's verdict. Deliberately not a diff: a file moves from "untracked" to "in the diff" at commit time, so a
# diff-based key changes when the content did not, and the receipt would go stale
# the moment it was committed. This is identical either side of a commit, and
# changes the instant any of those files is edited.
RECEIPT_KEY=$( { printf '%s\\n' "$PROJECT_DIR"
                 printf '%s\\n' "$CHANGED" | while IFS= read -r f; do
                   [ -n "$f" ] || continue
                   printf '%s\\n' "$f"
                   [ -f "$f" ] && cat "$f"
                 done; } | git hash-object --stdin )
RECEIPT="/tmp/claude-shipgate-$RECEIPT_KEY"

if [ "$MODE" = key ]; then printf '%s\\n' "$RECEIPT_KEY"; exit 0; fi
if [ "$MODE" = force ]; then
  printf 'FORCED %s\\n' "$(date -u +%FT%TZ)" > "$RECEIPT"
  echo "ship-gate: FORCED — receipt written without running any check."
  exit 0
fi
SOURCED=$(printf '%s\\n' "$CHANGED" | grep -E "\\.($GAUNTLET_SOURCE_EXT)$" \\
        | grep -vE '(\\.|_)(test|spec)\\.[^.]+$|(^|/)tests?/|(^|/)\\.stryker-tmp/' | while read -r f; do
          [ -f "$f" ] && printf '%s\\n' "$f"
        done)

# A generated file cannot be split and a vendored one is not ours to split, so
# the length check fires on every route regeneration and teaches people to
# --force. A gate that is always forced is not a gate. These are held out of
# both checks — and printed, because a silent skip is the same lie as a fake
# PASS. The leading / is what lets one pattern match components/ui at the repo
# root and apps/web/src/components/ui alike.
#
# */*.config.* is here for the same reason, and became urgent the moment an
# uncovered line started failing the gate: vitest.config.ts has no tests, will
# never have tests, and is not a thing anyone writes a test for. Left in, every
# diff that touches a config reports findings nobody can close.
# set -f matters: an unquoted list is glob-expanded before it is split, so
# */components/ui/*.tsx turned itself into the very path it was meant to match
# and then matched nothing.
is_ignored() {
  set -f
  for pat in $GAUNTLET_IGNORE_FILES; do
    case "/$1" in $pat) set +f; return 0 ;; esac
  done
  set +f
  return 1
}
FILES=$(printf '%s\\n' "$SOURCED" | while IFS= read -r f; do
          [ -n "$f" ] && ! is_ignored "$f" && printf '%s\\n' "$f"
        done)
IGNORED=$(printf '%s\\n' "$SOURCED" | while IFS= read -r f; do
            [ -n "$f" ] && is_ignored "$f" && printf '%s\\n' "$f"
          done)
if [ -n "$IGNORED" ]; then
  echo "ship-gate: not gated, matched GAUNTLET_IGNORE_FILES:"
  printf '%s\\n' "$IGNORED" | sed 's/^/  /'
fi

if [ -z "$FILES" ]; then
  # "I recognised nothing" is not "there is nothing", and the gate used to report
  # both as a PASS. A Godot repo changed only .gd files, which no extension in
  # the list named, so zero source files were found and a PASS receipt was
  # written over work nothing had checked. An extension this gate cannot place is
  # UNPROVEN: it does not block, but it never claims a pass either.
  UNKNOWN=$(printf '%s\\n' "$CHANGED" | grep -E '\\.[A-Za-z0-9]+$' \\
            | grep -viE "\\.($GAUNTLET_SOURCE_EXT)$" \\
            | grep -viE "\\.($GAUNTLET_IGNORE_EXT)$" \\
            | sed 's/.*\\.//' | sort -u | tr '\\n' ' ')
  if [ -n "$UNKNOWN" ]; then
    echo "ship-gate: UNPROVEN — nothing here was checked. These changed files are"
    echo "  in a language this gate does not know: $UNKNOWN"
    echo "  If they are source, add the extension in .claude/gauntlet.conf:"
    echo "    GAUNTLET_SOURCE_EXT=\\"\\$GAUNTLET_SOURCE_EXT|\${UNKNOWN%% *}\\""
    echo "  If they are not, add it to GAUNTLET_IGNORE_EXT the same way."
    printf 'UNPROVEN %s unknown-extensions\\n' "$(date -u +%FT%TZ)" > "$RECEIPT"
    exit 2
  fi
  echo "ship-gate: no changed code files — nothing to check"
  printf 'PASS %s no-code-changes\\n' "$(date -u +%FT%TZ)" > "$RECEIPT"
  exit 0
fi

echo "ship-gate: $(printf '%s\\n' "$FILES" | wc -l) changed code file(s), base $(git rev-parse --short "$BASE")"
echo
STATUS=0

# ------------------------------------------------- check 1: file length (hard)
OVER=""
LARGEST=0
if [ "$GAUNTLET_MAX_LINES" -gt 0 ]; then
  while IFS= read -r f; do
    n=$(wc -l < "$f")
    [ "$n" -gt "$LARGEST" ] && LARGEST=$n
    [ "$n" -gt "$GAUNTLET_MAX_LINES" ] && OVER="$OVER  $f — $n lines (limit $GAUNTLET_MAX_LINES)
"
  done <<< "$FILES"
fi

if [ "$GAUNTLET_MAX_LINES" -le 0 ]; then
  echo "FILE LENGTH — off (GAUNTLET_MAX_LINES=0)"
elif [ -n "$OVER" ]; then
  echo "FILE LENGTH — over the limit:"
  printf '%s' "$OVER"
  echo "  Splitting a file is a design decision. Do it deliberately, or ship with --force."
  STATUS=1
else
  echo "FILE LENGTH — ok, largest is $LARGEST lines"
fi

# ---------------------------------------------------------- which project owns
# A monorepo holds several projects, each with its own runner and its own
# mutation tool. Walk up from each changed file to the nearest manifest.
# mutmut is installed into the project's environment, not onto PATH. Ask the
# project how to run its own tools before falling back to a bare binary.
py_mutmut() {
  d="$1"
  # Returned relative to the PROJECT, because the command runs from inside it.
  if [ -x "$d.venv/bin/mutmut" ]; then printf './.venv/bin/mutmut\\n'; return; fi
  if [ -f "$d""uv.lock" ] && command -v uv >/dev/null 2>&1; then printf 'uv run mutmut\\n'; return; fi
  if [ -f "$d""poetry.lock" ] && command -v poetry >/dev/null 2>&1; then printf 'poetry run mutmut\\n'; return; fi
  command -v mutmut >/dev/null 2>&1 && printf 'mutmut\\n'
}

owner_of() {
  d=$(dirname "$1")
  while :; do
    if [ -f "$d/package.json" ] || [ -f "$d/pyproject.toml" ] \\
       || [ -f "$d/pytest.ini" ] || [ -f "$d/setup.cfg" ]; then
      printf '%s\\n' "\${d#./}"; return
    fi
    [ "$d" = "." ] || [ "$d" = "/" ] && { printf '.\\n'; return; }
    d=$(dirname "$d")
  done
}

OWNERS=$(while IFS= read -r f; do owner_of "$f"; done <<< "$FILES" | sort -u)

# --------------------------------------------- check 2: mutation, per project
echo
echo "MUTATION — $(printf '%s\\n' "$OWNERS" | wc -l) project(s) in this diff"
MISSING=""

for owner in $OWNERS; do
  [ "$owner" = "." ] && label="<repo root>" || label="$owner/"
  OWNED=$(while IFS= read -r f; do
            [ "$(owner_of "$f")" = "$owner" ] && printf '%s\\n' "$f"
          done <<< "$FILES")
  [ -z "$OWNED" ] && continue

  # ONE comma-joined --mutate value, never a flag per range. Stryker's CLI
  # parses --mutate with \`(val) => val.split(",")\`, a coercion that ignores the
  # previous value, so a repeated flag OVERRIDES instead of appending and only
  # the last one survives. Measured on two files: the repeated form found 1 of
  # 1808 files and 28 mutants, the joined form 2 files and 51. Every run since
  # this gate shipped mutated exactly one file and called the rest proven — and
  # when that one file had no tests, Stryker exited on "No tests were executed"
  # and the gate reported UNPROVEN, which writes a receipt and blocks nothing.
  FLAGS=""
  GLOBBED=","
  while IFS= read -r f; do
    hunks=$(git diff -U0 "$BASE" -- "$f" 2>/dev/null \\
            | grep -oE '^@@ -[0-9,]+ \\+[0-9]+(,[0-9]+)?' | sed 's/.*+//' \\
            | while IFS=, read -r s l; do l=\${l:-1}; [ "$l" -gt 0 ] && echo "$s-$((s+l-1))"; done)
    [ -z "$hunks" ] && hunks="1-$(wc -l < "$f")"
    rel=\${f#$owner/}
    # A Next.js route folder — [id], [[...slug]] — is a glob expression to
    # Stryker, which refuses "Cannot combine a glob expression with a mutation
    # range" and fails the entire run, not just that file. Escaping the brackets
    # stops the path resolving at all. Replacing each with ? keeps it matching
    # that one file and drops the range, so the file is mutated whole: a
    # superset of the diff, slower than a range but never less than what changed.
    case "$rel" in
      *[][*?{}]*) FLAGS="$FLAGS,$(printf '%s' "$rel" | sed 's/[][*?{}]/?/g')"
                  GLOBBED="$GLOBBED$rel," ;;
      *) for r in $hunks; do FLAGS="$FLAGS,$rel:$r"; done ;;
    esac
  done <<< "$OWNED"

  base=""; RUN=""
  if [ "$owner" != "." ]; then base="$owner/"; RUN="cd '$owner' && "; fi
  if [ -n "$GAUNTLET_MUTATE" ]; then
    CMD="$GAUNTLET_MUTATE"; TOOL="config"
  elif [ -f "$base"package.json ] && grep -qs '@stryker-mutator/core' "$base"package.json; then
    TOOL="stryker"
    # From inside the owning package: npx resolves against ITS node_modules, and
    # stryker.config.json lives there too. A monorepo root usually has neither.
    #
    # Deliberately NOT --incremental. --force does rerun every mutant in scope,
    # so the diff itself was always judged fresh — but incremental mode still
    # merges reports/stryker-incremental.json into the REPORT for everything
    # out of scope, and this gate greps the whole report. Survivors recorded
    # months ago came back as findings against a diff that never touched them:
    # 8 of them on one commit, all long since killed. --mutate already scopes
    # the run to the changed hunks, so incremental buys nothing here and costs
    # a cache that goes stale exactly the way mutmut's did.
    CMD="\${RUN}npx --no-install stryker run --mutate '\${FLAGS#,}'"
  elif [ -f "$base"package.json ]; then
    MISSING="$MISSING  $label needs Stryker:
      npm --prefix \${owner} i -D @stryker-mutator/core @stryker-mutator/vitest-runner
      then \${base}stryker.config.json:
        {\\"testRunner\\":\\"vitest\\",\\"plugins\\":[\\"@stryker-mutator/vitest-runner\\"],\\"coverageAnalysis\\":\\"perTest\\"}
"
    continue
  elif [ -n "$(py_mutmut "$base")" ]; then
    TOOL="mutmut"
    # mutmut takes its scope from [tool.mutmut] in pyproject, not from a flag:
    # --paths-to-mutate was 2.x, and 3.x filters by fnmatch globs over mutant
    # NAMES (app.balance.reserve.*). There is no per-line scoping at all.
    #
    # \`mutmut run\` prints 🙁 for a survivor and exits 0 either way — parsing it
    # reports clean with survivors sitting there, which is a false green and
    # worse than reporting nothing. \`mutmut results\` is the readable source:
    # it prints "<mutant name>: survived" per survivor.
    M="$(py_mutmut "$base")"
    # mutmut caches verdicts in ./mutants and only invalidates one when the
    # SOURCE of that function changes. Adding a test does not, so it replays the
    # old "survived" and calls mutants the new tests kill still alive — measured
    # at 20 of them on one commit. \`results\` then prints that whole cache, so
    # survivors turn up for files nowhere near the diff. Deleting the dir first
    # makes both describe the tree being shipped; \`mutmut run\` rewrites it
    # anyway, and a cold run is ~35s for ~1000 mutants.
    # One cd for all three: they run in the same shell, already there.
    CMD="\${RUN}rm -rf mutants; $M run >/dev/null 2>&1; $M results"
  else
    MISSING="$MISSING  $label needs mutmut:
      uv add --dev mutmut     # or: poetry add --group dev mutmut, pip install mutmut
      then \${base}pyproject.toml:
        [tool.mutmut]
        source_paths = [\\"src/\\"]
        pytest_add_cli_args_test_selection = [\\"tests/\\"]
      (mutmut 3 renamed these — paths_to_mutate/tests_dir are 2.x and are ignored)
"
    continue
  fi

  OUT=$(eval "$CMD" 2>&1); RC=$?
  # Match a finding, never a summary row. Stryker prints a \`# survived\` COLUMN
  # HEADER every run and repeats the word in its table, so a bare grep reports
  # survivors on a clean run — worse than not running at all. Stryker marks each
  # real finding \`[Survived]\`; table and border lines are excluded outright.
  # NoCoverage is printed exactly like Survived and means something worse: not
  # "a test missed this mutation" but "no test executes this line at all". The
  # gate matched only [Survived], so a diff whose files have no tests came back
  # PASS — 306 uncovered mutants reported as proven on one commit. It is judged
  # only for files that went in WITH a range: a glob-shaped path is mutated
  # whole, so its untouched lines would report uncovered forever, and a finding
  # nobody can close is what teaches people to --force.
  #
  # The status line carries no file name; the line under it does, as
  # file:line:column. They are paired here rather than grepped separately.
  if [ "$TOOL" = stryker ]; then
    ALL=$(printf '%s\\n' "$OUT" | awk -v globbed="$GLOBBED" '
      /^\\[Survived\\]/   { pend = $0; kind = "s"; next }
      /^\\[NoCoverage\\]/ { pend = $0; kind = "n"; next }
      pend != "" {
        file = $0; sub(/:[0-9]+:[0-9]+$/, "", file)
        if (kind == "s" || index(globbed, "," file ",") == 0) print pend "  " $0
        pend = ""
      }
      # A survivor with no location under it is still a survivor, never dropped.
      END { if (pend != "" && kind == "s") print pend }
    ')
  else
    ALL=$(printf '%s\\n' "$OUT" | grep -E '[Ss]urvived' \\
          | grep -vE '^[[:space:]]*[#│|+-]|# *surviv')
  fi
  # The detail list is capped so one bad file cannot bury the output. The cap
  # used to be the whole story, and it hid the WORST file: 20 findings from one
  # file filled it, and a second file with 54 uncovered mutants never appeared
  # at all. A gate whose biggest finding is invisible gets under-fixed. Every
  # file with findings is now named below the cut, worst first.
  FOUND=$(printf '%s\\n' "$ALL" | grep -c .)
  SURVIVED=$(printf '%s\\n' "$ALL" | head -20)
  FIXED=0
  NOTE=""

  # Stryker takes --mutate per changed hunk, so it already answers "did YOUR
  # change get tested". mutmut cannot be asked that — 3.x dropped 1.x's
  # --use-patch-file and never replaced it — so it mutates all of source_paths
  # and reports the repo's entire backlog. Held to the same bar, the Python half
  # answers "is this repo perfect" instead, which it never is, so it could never
  # go green. The baseline supplies the missing half: survivors recorded once
  # are accepted debt, and only a name that is not in it fails the gate.
  #
  # A mutant name carries an index within its own function, not a line number,
  # so editing elsewhere in the file does not rename it — and editing the
  # function itself DOES, which correctly re-charges its survivors to that edit.
  if [ "$TOOL" = mutmut ]; then
    BL="$base.mutmut-baseline"
    NOWF=$(mktemp)
    printf '%s\\n' "$OUT" \\
      | sed -n 's/^[[:space:]]*\\([^[:space:]]*\\): survived$/\\1/p' | sort -u > "$NOWF"
    if [ "$MODE" = baseline ]; then
      cp "$NOWF" "$BL"
      NOTE="  $label mutmut — baseline set: $(wc -l < "$BL") survivor(s) accepted. Commit $BL."
      SURVIVED=""
    elif [ -f "$BL" ]; then
      # -Fxv against an empty baseline reports every survivor, which is right:
      # an empty baseline means nothing has been accepted.
      SURVIVED=$(grep -Fxv -f "$BL" "$NOWF" | head -20)
      FIXED=$(grep -Fxvc -f "$NOWF" "$BL")
    else
      cp "$NOWF" "$BL"
      NOTE="  $label mutmut — no baseline, so nothing could be compared. Recorded
      $(wc -l < "$BL") existing survivor(s) in $BL — commit it, then run the
      gate again. From here only NEW survivors fail; --baseline accepts more."
      SURVIVED=""
      [ "$STATUS" = 0 ] && STATUS=2
    fi
    rm -f "$NOWF"
  fi

  if [ -n "$SURVIVED" ]; then
    echo "  $label $TOOL — these lines can break and no test notices:"
    printf '%s\\n' "$SURVIVED" | sed 's/^/      /'
    if [ "$FOUND" -gt 20 ]; then
      echo "      ... $((FOUND - 20)) more not shown. Every file with findings:"
      if [ "$TOOL" = stryker ]; then
        printf '%s\\n' "$ALL" \\
          | awk '{ f = $NF; sub(/:[0-9]+:[0-9]+$/, "", f); n[f]++ }
                 END { for (k in n) printf "%8d  %s\\n", n[k], k }' \\
          | sort -rn | sed 's/^/      /'
      fi
    fi
    [ "$FIXED" -gt 0 ] && echo "      ($FIXED baselined survivor(s) now killed — --baseline banks them)"
    STATUS=1
  elif [ $RC -ne 0 ]; then
    echo "  $label $TOOL — the run failed:"
    printf '%s\\n' "$OUT" | tail -12 | sed 's/^/      /'
    [ "$STATUS" = 0 ] && STATUS=2
  elif [ -n "$NOTE" ]; then
    printf '%s\\n' "$NOTE"
  else
    echo "  $label $TOOL — ok, nothing survived and nothing was uncovered"
    [ "$FIXED" -gt 0 ] && echo "      ($FIXED baselined survivor(s) now killed — --baseline banks them)"
  fi
done

if [ -n "$MISSING" ]; then
  echo "  UNPROVEN — no mutation tool for these, so their tests were never shown"
  echo "  to catch a break. Install per project:"
  printf '%s' "$MISSING"
  [ "$STATUS" = 0 ] && STATUS=2
fi

if [ "$MODE" = baseline ]; then
  echo
  echo "ship-gate: baselines updated. No receipt written — run the gate for real."
  exit 0
fi

# The receipt is written by this script and nothing else. A hand-rolled check
# produces no receipt, which is the whole point: substituting a weaker check is
# a choice that can be argued for, but it cannot be passed off as this one.
echo
case $STATUS in
  0) echo "ship-gate: PASS"
     printf 'PASS %s\\n' "$(date -u +%FT%TZ)" > "$RECEIPT" ;;
  1) echo "ship-gate: FAIL — deal with the findings above, then run this again."
     echo "           To ship anyway: bash .claude/hooks/ship-gate.sh --force"
     rm -f "$RECEIPT" ;;
  2) echo "ship-gate: UNPROVEN — nothing is wrong, but nothing was proven either"
     printf 'UNPROVEN %s\\n' "$(date -u +%FT%TZ)" > "$RECEIPT" ;;
esac
exit $STATUS
`;

// PreToolUse on Bash: refuses git commit/push without a ship-gate receipt.
// Canonical source: scripts/ship-gate-hook.sh.
const SHIP_GATE_HOOK_SCRIPT = `#!/usr/bin/env bash
# ship-gate-hook.sh — PreToolUse on Bash. Refuses the commands that publish work
# unless ship-gate.sh has left a receipt for exactly these changes.
#
# A gate written as an instruction is a gate an agent can decide is not worth the
# time — and then report a pass it never earned, which is the part you cannot see
# from the outside. This removes the claim entirely: either the receipt exists for
# this exact content, or git does not run.
#
# The receipt key covers everything about to ship, so it survives \`git commit\`
# and still matches at push time, and it changes the moment any file is edited —
# a fix has to be re-gated instead of riding on the previous verdict.
#
# It gated \`git commit\` and \`git push\` until 2.23.0, and that was the wrong
# moment. The gate's scope is merge-base..HEAD — the whole branch, because the
# whole branch is what a PR ships — so a branch touching 46 files re-mutated all
# 46 on every commit. Fifteen minutes, twenty times, for one branch. Neither a
# commit nor a push to a feature branch publishes anything, so neither is gated
# now: the cost is paid once, at the point work actually ships.

INPUT=$(cat)

CMD=$(printf '%s' "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' \\
      | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//')

PROJECT_DIR="\${CLAUDE_PROJECT_DIR:-$PWD}"
cd "$PROJECT_DIR" 2>/dev/null || exit 0

# Opening or merging a PR publishes. So does pushing while standing on a
# protected branch — that is a direct ship with no PR in front of it. The branch
# is read from git rather than parsed out of the command, because \`git push\` with
# no arguments names no branch at all.
case "$CMD" in
  *"gh pr create"*|*"gh pr merge"*) ;;
  *"git push"*)
    BRANCH=$(git branch --show-current 2>/dev/null)
    case "$BRANCH" in
      main|master|develop|development|dev) ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac

GATE="$PROJECT_DIR/.claude/hooks/ship-gate.sh"
[ -x "$GATE" ] || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Ask the gate for the key rather than recomputing it here. Two implementations
# of the same rule drift, and the drift is silent.
KEY=$(bash "$GATE" --key 2>/dev/null)
[ -z "$KEY" ] && exit 0

RECEIPT="/tmp/claude-shipgate-$KEY"
if [ -f "$RECEIPT" ]; then
  exit 0
fi

MSG="BLOCKED: no ship-gate receipt for these changes.

The quality gate has not run against the code you are about to publish, or the
code changed since it last did. Run it:

  bash .claude/hooks/ship-gate.sh

It checks file length and mutation-tests the changed lines, and writes a receipt
this hook can see. Fix what it reports and run it again — a fix invalidates the
previous receipt on purpose.

Do NOT hand-roll a substitute check: only ship-gate.sh writes a receipt, so a
weaker check you designed yourself cannot be passed off as this one.

To publish without the gate, say so out loud and run:

  bash .claude/hooks/ship-gate.sh --force"

json_escape() {
  local s="$1"
  s="\${s//\\\\/\\\\\\\\}"
  s="\${s//\\"/\\\\\\"}"
  s="\${s//$'\\n'/\\\\n}"
  s="\${s//$'\\r'/\\\\r}"
  s="\${s//$'\\t'/\\\\t}"
  printf '"%s"' "$s"
}

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\\n' "$(json_escape "$MSG")"
exit 0
`;

// SessionStart: a once-a-day line when a newer catalog has been published.
// Canonical source: scripts/version-check.sh.
const VERSION_CHECK_SCRIPT = `#!/usr/bin/env bash
# version-check.sh — SessionStart. Says once a day when a newer catalog exists.
#
# SessionStart stdout is added to the model's context, so this does not draw a
# banner: it tells the assistant, and the assistant mentions it. That is the
# whole reach of this hook — it never installs anything and never asks a
# question the user has to answer before working.
#
# The rule that keeps it invisible: NEVER touch the network in the foreground.
# A session start that waits on npm is a session start that hangs on a bad
# connection, and a version nudge is not worth one second of that. So it reads
# a cache written by the PREVIOUS session's background refresh, and kicks off
# the next refresh detached. The first session after an install therefore says
# nothing, and after that the answer is at worst a day old — which is the right
# resolution for "there is a new version" anyway.
#
# Silent when: no manifest, no cache yet, offline, already current, or the user
# has already been told today.
#
#   CLAUDE_SKILLS_NO_VERSION_CHECK=1   turns it off entirely

set -uo pipefail

[ -n "\${CLAUDE_SKILLS_NO_VERSION_CHECK:-}" ] && exit 0

PKG="@spardutti/claude-skills"
PROJECT_DIR="\${CLAUDE_PROJECT_DIR:-$PWD}"
MANIFEST="$PROJECT_DIR/.claude/.claude-skills.json"

# No manifest means the CLI never installed here, so there is nothing to update.
[ -f "$MANIFEST" ] || exit 0

INSTALLED=$(sed -n 's/.*"catalogVersion"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' "$MANIFEST" | head -1)
[ -n "$INSTALLED" ] || exit 0

# One cache for the whole machine, not one per project: the answer is the same
# everywhere, and a developer with ten repos should still cost one request.
CACHE_DIR="\${HOME:-/tmp}/.claude"
CACHE="$CACHE_DIR/.claude-skills-version"
STAMP="$CACHE_DIR/.claude-skills-version-told"
mkdir -p "$CACHE_DIR" 2>/dev/null

NOW=$(date +%s 2>/dev/null || echo 0)
DAY=86400

# Refresh in the background, fully detached. Nothing downstream waits on it: all
# three streams are closed, or the session start blocks until curl gives up.
refresh() {
  AGE=$DAY
  if [ -f "$CACHE" ]; then
    MTIME=$(date -r "$CACHE" +%s 2>/dev/null || echo 0)
    AGE=$((NOW - MTIME))
  fi
  [ "$AGE" -lt "$DAY" ] && return
  command -v curl >/dev/null 2>&1 || return
  ( curl -fsS --max-time 5 "https://registry.npmjs.org/$PKG/latest" \\
      | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' \\
      | head -1 > "$CACHE.tmp" 2>/dev/null
    # Only replace the cache with something that parsed. A truncated reply that
    # overwrote it would nudge toward a version that does not exist.
    if [ -s "$CACHE.tmp" ]; then mv "$CACHE.tmp" "$CACHE"; else rm -f "$CACHE.tmp"; fi
  ) </dev/null >/dev/null 2>&1 &
}
refresh

[ -f "$CACHE" ] || exit 0
LATEST=$(head -1 "$CACHE" | tr -d '[:space:]')
[ -n "$LATEST" ] || exit 0
[ "$LATEST" = "$INSTALLED" ] && exit 0

# sort -V puts the newer one last. Equal versions were already handled, so the
# only case left to reject is a cache that is BEHIND the install — which happens
# normally right after publishing from the machine that publishes.
NEWER=$(printf '%s\\n%s\\n' "$INSTALLED" "$LATEST" | sort -V | tail -1)
[ "$NEWER" = "$LATEST" ] || exit 0

# Once a day, however many sessions that day holds.
if [ -f "$STAMP" ]; then
  TOLD=$(date -r "$STAMP" +%s 2>/dev/null || echo 0)
  [ $((NOW - TOLD)) -lt "$DAY" ] && exit 0
fi
: > "$STAMP"

echo "A newer version of the $PKG catalog is available: $INSTALLED installed, $LATEST published."
echo "Mention this to the user ONCE, in a single line, and only when the current task is done."
echo "Do not interrupt what they are doing, and do not run the installer unless they ask."
echo "To update, they run: npx $PKG"
exit 0
`;

const GATE_FILENAME = "skill-gate.sh";
const AUTO_MARK_FILENAME = "skill-gate-automark.sh";
const APPLICATION_GATE_FILENAME = "skill-application-gate.sh";
const GAUNTLET_FILENAME = "gauntlet.sh";
const SHIP_GATE_FILENAME = "ship-gate.sh";
const SHIP_GATE_HOOK_FILENAME = "ship-gate-hook.sh";
const VERSION_CHECK_FILENAME = "version-check.sh";
const LEGACY_EVAL_FILENAME = "skill-forced-eval-hook.sh";
const LEGACY_AUDIT_RUNNER_FILENAME = "skill-audit-runner.sh";

// Asks the installed hook what it would run, rather than reimplementing its
// detection here. A second copy drifts: the JS one reported "no test runner"
// for repos the shell script had already learned to handle.
export async function detectStack(targetDir = process.cwd()) {
  const dir = resolve(targetDir);
  const hook = join(dir, ".claude", "hooks", GAUNTLET_FILENAME);
  return new Promise((done) => {
    const child = spawn("bash", [hook], {
      cwd: dir,
      env: { ...process.env, CLAUDE_PROJECT_DIR: dir, GAUNTLET_DEBUG: "1", GAUNTLET_DRYRUN: "1" },
    });
    let err = "";
    child.stderr.on("data", (c) => { err += c; });
    child.on("error", () => done(null));
    child.on("close", () => {
      const line = err.split("\n").find((l) => l.startsWith("gauntlet: would run:"));
      if (!line) return done(null);
      const gates = line.slice("gauntlet: would run:".length).trim();
      done(gates && !gates.startsWith("nothing") ? gates : null);
    });
    child.stdin.end('{"session_id":"install"}');
  });
}

// Written only when detection finds nothing — otherwise the hook auto-detects and
// no config file is needed.
export async function writeGauntletConf(targetDir, testCommand) {
  const confPath = join(resolve(targetDir), ".claude", "gauntlet.conf");
  await mkdir(dirname(confPath), { recursive: true });
  await writeFile(confPath, [
    "# Gauntlet config. Read after ~/.claude/gauntlet.conf, and wins over it.",
    "# GAUNTLET_OFF=1 disables the hook in this project.",
    "",
    "GAUNTLET_TYPECHECK=''",
    `GAUNTLET_TEST='${testCommand.replace(/'/g, "'\\''")}'`,
    "",
  ].join("\n"), { mode: 0o644 });
  return confPath;
}

// Register the entry, or CORRECT the one already there. Skipping when a hook of
// this name exists leaves an existing install pinned to whatever matcher it was
// first written with — which is how the skill gates kept watching only
// Write|Edit|MultiEdit after they learned to cover Bash.
function upsert(list, filename, entry) {
  const existing = list.find((e) => e.hooks?.some((h) => h.command?.endsWith(filename)));
  if (!existing) return list.push(entry);
  if (entry.matcher === undefined) delete existing.matcher;
  else existing.matcher = entry.matcher;
  existing.hooks = entry.hooks;
}

export async function setupHook(targetDir = process.cwd()) {
  const resolved = resolve(targetDir);
  const hooksDir = join(resolved, ".claude", "hooks");
  const gatePath = join(hooksDir, GATE_FILENAME);
  const autoMarkPath = join(hooksDir, AUTO_MARK_FILENAME);
  const applicationGatePath = join(hooksDir, APPLICATION_GATE_FILENAME);
  const gauntletPath = join(hooksDir, GAUNTLET_FILENAME);
  const shipGatePath = join(hooksDir, SHIP_GATE_FILENAME);
  const shipGateHookPath = join(hooksDir, SHIP_GATE_HOOK_FILENAME);
  const versionCheckPath = join(hooksDir, VERSION_CHECK_FILENAME);
  const settingsPath = join(resolved, ".claude", "settings.json");

  await mkdir(hooksDir, { recursive: true });
  await writeFile(gatePath, GATE_SCRIPT, { mode: 0o755 });
  await chmod(gatePath, 0o755);
  await writeFile(autoMarkPath, AUTO_MARK_SCRIPT, { mode: 0o755 });
  await chmod(autoMarkPath, 0o755);
  await writeFile(applicationGatePath, APPLICATION_GATE_SCRIPT, { mode: 0o755 });
  await chmod(applicationGatePath, 0o755);
  await writeFile(gauntletPath, GAUNTLET_SCRIPT, { mode: 0o755 });
  await chmod(gauntletPath, 0o755);
  await writeFile(shipGatePath, SHIP_GATE_SCRIPT, { mode: 0o755 });
  await chmod(shipGatePath, 0o755);
  await writeFile(shipGateHookPath, SHIP_GATE_HOOK_SCRIPT, { mode: 0o755 });
  await chmod(shipGateHookPath, 0o755);
  await writeFile(versionCheckPath, VERSION_CHECK_SCRIPT, { mode: 0o755 });
  await chmod(versionCheckPath, 0o755);

  // Remove the legacy audit-runner hook file from prior installs (2.3.x).
  try {
    await unlink(join(hooksDir, LEGACY_AUDIT_RUNNER_FILENAME));
  } catch {
    // not present — fine
  }

  let settings = {};
  try {
    settings = JSON.parse(await readFile(settingsPath, "utf-8"));
  } catch {
    // missing or invalid — start fresh
  }
  if (!settings.hooks) settings.hooks = {};

  // Clean up legacy UserPromptSubmit eval hook (replaced by the gate).
  if (Array.isArray(settings.hooks.UserPromptSubmit)) {
    settings.hooks.UserPromptSubmit = settings.hooks.UserPromptSubmit.filter(
      (entry) => !entry.hooks?.some((h) => h.command?.endsWith(LEGACY_EVAL_FILENAME))
    );
    if (settings.hooks.UserPromptSubmit.length === 0) {
      delete settings.hooks.UserPromptSubmit;
    }
  }

  // Clean up legacy PreToolUse audit-runner hook (2.3.x — removed in 2.4.0).
  if (Array.isArray(settings.hooks.PreToolUse)) {
    settings.hooks.PreToolUse = settings.hooks.PreToolUse.filter(
      (entry) => !entry.hooks?.some((h) => h.command?.endsWith(LEGACY_AUDIT_RUNNER_FILENAME))
    );
  }

  // Register PreToolUse gate.
  const gateCommand = `$CLAUDE_PROJECT_DIR/.claude/hooks/${GATE_FILENAME}`;
  const gateEntry = {
    matcher: "Write|Edit|MultiEdit|Bash",
    hooks: [{ type: "command", command: gateCommand }],
  };

  if (Array.isArray(settings.hooks.PreToolUse)) {
    upsert(settings.hooks.PreToolUse, GATE_FILENAME, gateEntry);
  } else {
    settings.hooks.PreToolUse = [gateEntry];
  }

  // Register PreToolUse application gate (after the loading gate).
  const applicationCommand = `$CLAUDE_PROJECT_DIR/.claude/hooks/${APPLICATION_GATE_FILENAME}`;
  const applicationEntry = {
    matcher: "Write|Edit|MultiEdit|Bash",
    hooks: [{ type: "command", command: applicationCommand }],
  };
  upsert(settings.hooks.PreToolUse, APPLICATION_GATE_FILENAME, applicationEntry);

  // Register PreToolUse ship-gate receipt check on Bash.
  const shipGateCommand = `$CLAUDE_PROJECT_DIR/.claude/hooks/${SHIP_GATE_HOOK_FILENAME}`;
  const shipGateEntry = {
    matcher: "Bash",
    hooks: [{ type: "command", command: shipGateCommand }],
  };
  upsert(settings.hooks.PreToolUse, SHIP_GATE_HOOK_FILENAME, shipGateEntry);

  // Register PostToolUse auto-mark on Skill.
  const autoMarkCommand = `$CLAUDE_PROJECT_DIR/.claude/hooks/${AUTO_MARK_FILENAME}`;
  const autoMarkEntry = {
    matcher: "Skill",
    hooks: [{ type: "command", command: autoMarkCommand }],
  };

  if (Array.isArray(settings.hooks.PostToolUse)) {
    upsert(settings.hooks.PostToolUse, AUTO_MARK_FILENAME, autoMarkEntry);
  } else {
    settings.hooks.PostToolUse = [autoMarkEntry];
  }

  // Register SessionStart version check. No matcher: startup and resume both
  // want it, and the script's own daily stamp keeps a burst of resumes quiet.
  const versionCheckCommand = `$CLAUDE_PROJECT_DIR/.claude/hooks/${VERSION_CHECK_FILENAME}`;
  const versionCheckEntry = { hooks: [{ type: "command", command: versionCheckCommand }] };

  if (Array.isArray(settings.hooks.SessionStart)) {
    upsert(settings.hooks.SessionStart, VERSION_CHECK_FILENAME, versionCheckEntry);
  } else {
    settings.hooks.SessionStart = [versionCheckEntry];
  }

  // Register Stop gauntlet hook.
  const gauntletCommand = `$CLAUDE_PROJECT_DIR/.claude/hooks/${GAUNTLET_FILENAME}`;
  const gauntletEntry = { hooks: [{ type: "command", command: gauntletCommand }] };

  if (Array.isArray(settings.hooks.Stop)) {
    upsert(settings.hooks.Stop, GAUNTLET_FILENAME, gauntletEntry);
  } else {
    settings.hooks.Stop = [gauntletEntry];
  }

  // Both gates clear by touching a marker under /tmp. The hook scripts let those
  // commands through themselves, but auto mode's permission classifier does not:
  // a touch whose only purpose is to unlock a gate is exactly what it refuses.
  // So in auto mode the application gate could not be satisfied at all, and the
  // model was reduced to asking its user to run the touch by hand — which is
  // indistinguishable from the laundering the classifier exists to stop.
  // Allowlisting the three marker paths is what makes the gates workable there.
  // Only these literal prefixes are granted, and an existing entry is not
  // duplicated on reinstall.
  const MARKER_ALLOW = [
    "Bash(touch /tmp/claude-skill-gate-*)",
    "Bash(touch /tmp/claude-skill-acked-*)",
    "Bash(touch /tmp/claude-skill-loaded-*)",
  ];
  if (!settings.permissions) settings.permissions = {};
  if (!Array.isArray(settings.permissions.allow)) settings.permissions.allow = [];
  for (const rule of MARKER_ALLOW) {
    if (!settings.permissions.allow.includes(rule)) settings.permissions.allow.push(rule);
  }

  await writeFile(settingsPath, JSON.stringify(settings, null, 2) + "\n", { mode: 0o644 });

  console.log(`  Hook installed: .claude/hooks/${GATE_FILENAME}`);
  console.log(`  Hook installed: .claude/hooks/${AUTO_MARK_FILENAME}`);
  console.log(`  Hook installed: .claude/hooks/${APPLICATION_GATE_FILENAME}`);
  console.log(`  Hook installed: .claude/hooks/${GAUNTLET_FILENAME}`);
  console.log(`  Installed: .claude/hooks/${SHIP_GATE_FILENAME} (used by /ship)`);
  console.log(`  Hook installed: .claude/hooks/${SHIP_GATE_HOOK_FILENAME}`);
  console.log(`  Settings updated: .claude/settings.json`);
}

// The project-level permissions.allow written above does not clear auto mode.
// The classifier reads autoMode.allow, and only from the user's own
// ~/.claude/settings.json — it deliberately ignores a project's settings so a
// cloned repo cannot loosen it. So the gate's ack was denied, and the remedy the
// deny message named could not be applied by the agent either: the classifier
// refuses an agent editing permission settings by any route. That left a
// deadlock nothing in the session could break. The installer can, because npx
// runs as the user, not as an agent — but only ever behind an explicit prompt,
// since this is the user's global file.
export const AUTO_MODE_RULE =
  "Touching marker files under /tmp/claude-skill-gate-*, /tmp/claude-skill-acked-* " +
  "and /tmp/claude-skill-loaded-* is allowed: they are acknowledgement files for the " +
  "user's own PreToolUse skill gates. Creating one satisfies a workflow gate the user " +
  "installed, grants no permission and executes no code, and is a false positive for " +
  "Auto-Mode Bypass.";

// Any entry naming a marker path is ours, whatever wording it shipped with. An
// upgrade must correct that entry rather than add a second one beside it —
// a fresh-install test would never see the difference.
const AUTO_MODE_RULE_MARK = "/tmp/claude-skill-acked-";

function globalSettingsPath(homeDir) {
  return join(homeDir ?? homedir(), ".claude", "settings.json");
}

async function readGlobalSettings(homeDir) {
  try {
    return JSON.parse(await readFile(globalSettingsPath(homeDir), "utf-8"));
  } catch {
    return null;
  }
}

// "current" — the rule is present and matches. "stale" — an older wording is
// there. "missing" — nothing of ours. "unreadable" — the file exists but does
// not parse, so we must not rewrite it.
export async function autoModeRuleStatus(homeDir) {
  let raw;
  try {
    raw = await readFile(globalSettingsPath(homeDir), "utf-8");
  } catch {
    return "missing";
  }
  let settings;
  try {
    settings = JSON.parse(raw);
  } catch {
    return "unreadable";
  }
  const allow = settings?.autoMode?.allow;
  if (!Array.isArray(allow)) return "missing";
  if (allow.includes(AUTO_MODE_RULE)) return "current";
  if (allow.some((r) => typeof r === "string" && r.includes(AUTO_MODE_RULE_MARK))) return "stale";
  return "missing";
}

// Writes the rule into ~/.claude/settings.json, keeping "$defaults" first —
// dropping it discards every built-in allow. Everything else in the file is
// preserved. Refuses an unparseable file rather than replacing it.
export async function writeAutoModeRule(homeDir) {
  if ((await autoModeRuleStatus(homeDir)) === "unreadable") {
    throw new Error(`${globalSettingsPath(homeDir)} is not valid JSON — fix it, then re-run.`);
  }
  const settings = (await readGlobalSettings(homeDir)) ?? {};
  if (!settings.autoMode || typeof settings.autoMode !== "object") settings.autoMode = {};
  const existing = Array.isArray(settings.autoMode.allow) ? settings.autoMode.allow : [];

  const kept = existing.filter(
    (r) => r !== "$defaults" && !(typeof r === "string" && r.includes(AUTO_MODE_RULE_MARK)),
  );
  settings.autoMode.allow = ["$defaults", ...kept, AUTO_MODE_RULE];

  const path = globalSettingsPath(homeDir);
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, JSON.stringify(settings, null, 2) + "\n", { mode: 0o600 });
  return path;
}
