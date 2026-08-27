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
# Runs when Claude finishes a turn. Silent when green. Blocks the turn when a
# gate is red, handing the failure back to Claude to fix before the user sees it.
#
# Only cheap gates belong here (target: under ~30s). Mutation testing, deep
# review, and the spec checklist are the /gauntlet command's job, not this hook's.
#
# Skip ladder, cheapest first — quits at the first "no":
#   1. no changed files
#   2. no changed *code* files (docs/config only)
#   3. this exact diff already passed
#   4. no test runner detected
#
# Config, both optional and both KEY=value files that get sourced in this order:
#   ~/.claude/gauntlet.conf          your defaults for every project
#   <project>/.claude/gauntlet.conf  overrides for this one; wins key by key
#   GAUNTLET_OFF=1                 disable entirely
#   GAUNTLET_TYPECHECK="cmd"       override the typecheck command ("" to skip)
#   GAUNTLET_TEST="cmd"            override the test command; $FILES = changed code files
#   GAUNTLET_CODE_EXT="ts|tsx|py"  override which extensions count as code

set -uo pipefail

INPUT=$(cat 2>/dev/null || true)

# Never re-block a turn we already blocked — this would loop forever.
case "$INPUT" in
  *'"stop_hook_active":true'*) exit 0 ;;
esac

PROJECT_DIR="\${CLAUDE_PROJECT_DIR:-}"
if [ -z "$PROJECT_DIR" ]; then PROJECT_DIR="$PWD"; fi
cd "$PROJECT_DIR" 2>/dev/null || exit 0

git rev-parse --git-dir >/dev/null 2>&1 || exit 0

GAUNTLET_OFF=""
GAUNTLET_TYPECHECK="__auto__"
GAUNTLET_TEST="__auto__"
GAUNTLET_CODE_EXT="ts|tsx|js|jsx|mjs|cjs|py|go|rs|java|kt|rb|php|c|h|cpp|hpp|cs|swift|sql"
# Global defaults first, then the project's on top — project wins, key by key.
if [ -n "\${HOME:-}" ] && [ -f "$HOME/.claude/gauntlet.conf" ]; then . "$HOME/.claude/gauntlet.conf"; fi
if [ -f "$PROJECT_DIR/.claude/gauntlet.conf" ]; then . "$PROJECT_DIR/.claude/gauntlet.conf"; fi
if [ -n "$GAUNTLET_OFF" ]; then exit 0; fi

# ---------------------------------------------------------------- skip rule 1
CHANGED=$( { git diff --name-only HEAD 2>/dev/null; \\
             git ls-files --others --exclude-standard 2>/dev/null; } | sort -u )
if [ -z "$CHANGED" ]; then exit 0; fi

# ---------------------------------------------------------------- skip rule 2
FILES=$(printf '%s\\n' "$CHANGED" | grep -E "\\.($GAUNTLET_CODE_EXT)$" || true)
if [ -z "$FILES" ]; then exit 0; fi

# ---------------------------------------------------------------- skip rule 3
DIFF_HASH=$( { git diff HEAD 2>/dev/null; printf '%s\\n' "$CHANGED"; } \\
             | git hash-object --stdin 2>/dev/null )
SESSION_ID=$(printf '%s' "$INPUT" | grep -o '"session_id":"[^"]*"' | head -1 \\
             | sed 's/"session_id":"//; s/"$//')
if [ -z "$SESSION_ID" ]; then SESSION_ID="nosession"; fi
MARKER="/tmp/claude-gauntlet-$SESSION_ID"
if [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$DIFF_HASH" ]; then exit 0; fi

# ---------------------------------------------------------------- skip rule 4
# Detect the stack once. Auto-detection is a default, not a decision — the conf
# file wins whenever a repo does something unusual.
detect() {
  if [ "$GAUNTLET_TEST" != "__auto__" ]; then return; fi
  GAUNTLET_TEST=""
  GAUNTLET_TYPECHECK=""
  if [ -f package.json ]; then
    if grep -q '"vitest"' package.json; then
      GAUNTLET_TEST='npx --no-install vitest related --run $FILES'
    elif grep -q '"jest"' package.json; then
      GAUNTLET_TEST='npx --no-install jest --findRelatedTests $FILES --passWithNoTests'
    fi
    if [ -f tsconfig.json ]; then
      GAUNTLET_TYPECHECK='npx --no-install tsc --noEmit'
    fi
  fi
  if [ -z "$GAUNTLET_TEST" ] && { [ -f pyproject.toml ] || [ -f pytest.ini ] || [ -f setup.cfg ]; }; then
    GAUNTLET_TEST='python -m pytest -q'
    if [ -f mypy.ini ] || grep -qs 'tool.mypy' pyproject.toml; then
      GAUNTLET_TYPECHECK='python -m mypy .'
    fi
  fi
}
detect
if [ -z "$GAUNTLET_TEST" ]; then exit 0; fi

# ------------------------------------------------------------------ the gates
# Cheapest first, stop at the first red. Most failures land in the first gate,
# so the expensive ones are usually never paid for.
export FILES=$(printf '%s' "$FILES" | tr '\\n' ' ')
FAILED=""
OUTPUT=""

run_gate() {
  GATE_NAME="$1"
  GATE_CMD="$2"
  if [ -z "$GATE_CMD" ]; then return 0; fi
  GATE_OUT=$(eval "$GATE_CMD" 2>&1)
  if [ $? -ne 0 ]; then
    FAILED="$GATE_NAME"
    OUTPUT="$GATE_OUT"
    return 1
  fi
  return 0
}

run_gate "typecheck" "$GAUNTLET_TYPECHECK" && run_gate "tests" "$GAUNTLET_TEST"

if [ -z "$FAILED" ]; then
  printf '%s' "$DIFF_HASH" > "$MARKER"
  exit 0
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

printf '{"decision":"block","reason":%s}\\n' "$(json_escape "$MSG")"
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
    if (await has("tsconfig.json")) typecheck = "tsc";
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
