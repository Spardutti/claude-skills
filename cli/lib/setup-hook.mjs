import { mkdir, writeFile, readFile, chmod, unlink } from "node:fs/promises";
import { join, resolve, dirname } from "node:path";

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

1. For each skill listed above, state the specific rules that apply to the file you're about to write.
2. State how your next write respects each rule.
3. Then ack all of them in a single Bash tool call:
     $ACK_CMD

One ack per skill per session. After acking, retry the Write/Edit.
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
# Runs when Claude finishes a turn. Silent when green. On a red gate it returns
# {"decision":"continue"} so the turn does not end, handing the failure back to
# Claude to fix before the user sees it.
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
if [ -z "$CHANGED" ]; then quit "skipped: no changed files"; fi

# ---------------------------------------------------------------- skip rule 2
FILES_NL=$(printf '%s\\n' "$CHANGED" | grep -E "\\.($GAUNTLET_CODE_EXT)$" || true)
if [ -z "$FILES_NL" ]; then quit "skipped: no changed code files (docs/config only)"; fi

# ---------------------------------------------------------------- skip rule 3
# The repo path is part of the hash: one session can touch several repos, and two
# of them can legitimately hold an identical diff.
DIFF_HASH=$( { printf '%s\\n' "$PROJECT_DIR"; git diff HEAD 2>/dev/null; printf '%s\\n' "$CHANGED"; } \\
             | git hash-object --stdin 2>/dev/null )
if [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$DIFF_HASH" ]; then
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

JS_EXT='\\.(ts|tsx|js|jsx|mjs|cjs)$'

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

  # Without node_modules every npm/npx gate fails on a missing binary, which
  # would block every turn in a fresh clone. That is a missing tool, not a red.
  if [ -f package.json ] && [ ! -d node_modules ]; then
    SKIP_NOTE="node_modules is missing — run your install first"
  elif [ -f package.json ]; then
    # Prefer the repo's own typecheck script. In a workspace repo the root
    # tsconfig is often solution-style (references only), where bare
    # \`tsc --noEmit\` does not mean what \`tsc -b\` means.
    if grep -q '"typecheck"[[:space:]]*:' package.json; then
      add_gate typecheck "$JS_EXT" 'npm run --silent typecheck'
    elif [ -f tsconfig.json ]; then
      add_gate typecheck '\\.(ts|tsx)$' 'npx --no-install tsc --noEmit'
    fi
    if grep -q '"vitest"' package.json; then
      add_gate tests "$JS_EXT" 'npx --no-install vitest related --run $FILES'
    elif grep -q '"jest"' package.json; then
      add_gate tests "$JS_EXT" 'npx --no-install jest --findRelatedTests $FILES --passWithNoTests'
    fi
  fi

  if [ -f pyproject.toml ] || [ -f pytest.ini ] || [ -f setup.cfg ]; then
    if [ -f mypy.ini ] || grep -qs 'tool.mypy' pyproject.toml; then
      add_gate typecheck '\\.py$' 'python -m mypy .'
    fi
    add_gate tests '\\.py$' 'python -m pytest -q'
  fi
}
detect

# Typechecks before tests — cheapest first, so the slow gate is usually unpaid.
GATES="$TC_GATES$TEST_GATES"
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
  mapfile -t FILE_ARR <<< "$GFILES"
  export FILES=$(printf '%s' "$GFILES" | tr '\\n' ' ')
  GCMD_RUN=\${GCMD//"$PAT_BRACE"/$FILES_REPL}
  GCMD_RUN=\${GCMD_RUN//"$PAT_PLAIN"/$FILES_REPL}
  RAN="$RAN$GKIND "
  GATE_OUT=$(eval "$GCMD_RUN" 2>&1)
  if [ $? -ne 0 ]; then
    # A gate whose tool is not installed is a missing gate, not a failing one.
    # Blocking on it would wall off every turn until the user installs something.
    if printf '%s' "$GATE_OUT" | grep -qiE 'command not found|no module named|cannot find module|could not determine executable|canceled due to missing packages|is not recognized'; then
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

json_escape() {
  local s="$1"
  s="\${s//\\\\/\\\\\\\\}"
  s="\${s//\\"/\\\\\\"}"
  s="\${s//$'\\n'/\\\\n}"
  s="\${s//$'\\r'/\\\\r}"
  s="\${s//$'\\t'/\\\\t}"
  printf '"%s"' "$s"
}

printf '%s\\n' "red: the $FAILED gate failed" > "$WHY" 2>/dev/null
if [ -n "\${GAUNTLET_DEBUG:-}" ]; then printf 'gauntlet: red: the %s gate failed\\n' "$FAILED" >&2; fi
# A Stop hook's decision is "continue" / "stop" / "escalate" — "block" is not a
# valid value and would be ignored, letting the turn end on a red gate.
printf '{"decision":"continue","reason":%s}\\n' "$(json_escape "$MSG")"
exit 0
`;

const GATE_FILENAME = "skill-gate.sh";
const AUTO_MARK_FILENAME = "skill-gate-automark.sh";
const APPLICATION_GATE_FILENAME = "skill-application-gate.sh";
const GAUNTLET_FILENAME = "gauntlet.sh";
const LEGACY_EVAL_FILENAME = "skill-forced-eval-hook.sh";
const LEGACY_AUDIT_RUNNER_FILENAME = "skill-audit-runner.sh";

// Mirrors the detect() in scripts/gauntlet.sh. Kept in sync by hand: this one
// only reports what the hook will find, it never decides anything.
export async function detectStack(targetDir = process.cwd()) {
  const dir = resolve(targetDir);
  const has = async (f) => {
    try { await readFile(join(dir, f), "utf-8"); return true; } catch { return false; }
  };
  const read = async (f) => {
    try { return await readFile(join(dir, f), "utf-8"); } catch { return ""; }
  };

  let test = null;
  let typecheck = null;

  const pkg = await read("package.json");
  if (pkg) {
    if (pkg.includes('"vitest"')) test = "vitest";
    else if (pkg.includes('"jest"')) test = "jest";
    if (/"typecheck"\s*:/.test(pkg)) typecheck = "npm run typecheck";
    else if (await has("tsconfig.json")) typecheck = "tsc";
  }
  if (!test && (await has("pyproject.toml") || await has("pytest.ini") || await has("setup.cfg"))) {
    test = "pytest";
    if (await has("mypy.ini") || (await read("pyproject.toml")).includes("tool.mypy")) {
      typecheck = "mypy";
    }
  }
  return { test, typecheck };
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

export async function setupHook(targetDir = process.cwd()) {
  const resolved = resolve(targetDir);
  const hooksDir = join(resolved, ".claude", "hooks");
  const gatePath = join(hooksDir, GATE_FILENAME);
  const autoMarkPath = join(hooksDir, AUTO_MARK_FILENAME);
  const applicationGatePath = join(hooksDir, APPLICATION_GATE_FILENAME);
  const gauntletPath = join(hooksDir, GAUNTLET_FILENAME);
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
    matcher: "Write|Edit|MultiEdit",
    hooks: [{ type: "command", command: gateCommand }],
  };

  if (Array.isArray(settings.hooks.PreToolUse)) {
    const exists = settings.hooks.PreToolUse.some((entry) =>
      entry.hooks?.some((h) => h.command?.endsWith(GATE_FILENAME))
    );
    if (!exists) settings.hooks.PreToolUse.push(gateEntry);
  } else {
    settings.hooks.PreToolUse = [gateEntry];
  }

  // Register PreToolUse application gate (after the loading gate).
  const applicationCommand = `$CLAUDE_PROJECT_DIR/.claude/hooks/${APPLICATION_GATE_FILENAME}`;
  const applicationEntry = {
    matcher: "Write|Edit|MultiEdit",
    hooks: [{ type: "command", command: applicationCommand }],
  };
  const applicationAlreadyRegistered = settings.hooks.PreToolUse.some((entry) =>
    entry.hooks?.some((h) => h.command?.endsWith(APPLICATION_GATE_FILENAME))
  );
  if (!applicationAlreadyRegistered) settings.hooks.PreToolUse.push(applicationEntry);

  // Register PostToolUse auto-mark on Skill.
  const autoMarkCommand = `$CLAUDE_PROJECT_DIR/.claude/hooks/${AUTO_MARK_FILENAME}`;
  const autoMarkEntry = {
    matcher: "Skill",
    hooks: [{ type: "command", command: autoMarkCommand }],
  };

  if (Array.isArray(settings.hooks.PostToolUse)) {
    const exists = settings.hooks.PostToolUse.some((entry) =>
      entry.hooks?.some((h) => h.command?.endsWith(AUTO_MARK_FILENAME))
    );
    if (!exists) settings.hooks.PostToolUse.push(autoMarkEntry);
  } else {
    settings.hooks.PostToolUse = [autoMarkEntry];
  }

  // Register Stop gauntlet hook.
  const gauntletCommand = `$CLAUDE_PROJECT_DIR/.claude/hooks/${GAUNTLET_FILENAME}`;
  const gauntletEntry = { hooks: [{ type: "command", command: gauntletCommand }] };

  if (Array.isArray(settings.hooks.Stop)) {
    const exists = settings.hooks.Stop.some((entry) =>
      entry.hooks?.some((h) => h.command?.endsWith(GAUNTLET_FILENAME))
    );
    if (!exists) settings.hooks.Stop.push(gauntletEntry);
  } else {
    settings.hooks.Stop = [gauntletEntry];
  }

  await writeFile(settingsPath, JSON.stringify(settings, null, 2) + "\n", { mode: 0o644 });

  console.log(`  Hook installed: .claude/hooks/${GATE_FILENAME}`);
  console.log(`  Hook installed: .claude/hooks/${AUTO_MARK_FILENAME}`);
  console.log(`  Hook installed: .claude/hooks/${APPLICATION_GATE_FILENAME}`);
  console.log(`  Hook installed: .claude/hooks/${GAUNTLET_FILENAME}`);
  console.log(`  Settings updated: .claude/settings.json`);
}
