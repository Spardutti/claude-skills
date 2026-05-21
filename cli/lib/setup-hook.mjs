import { mkdir, writeFile, readFile, chmod, unlink } from "node:fs/promises";
import { join, resolve } from "node:path";

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

# Find the first loaded-but-unacked skill (handle one at a time; the next
# blocked write will surface the next skill).
UNACKED=""
for marker in /tmp/claude-skill-loaded-$SESSION_ID-*; do
  [ ! -f "$marker" ] && continue
  skill_name="\${marker##/tmp/claude-skill-loaded-$SESSION_ID-}"
  if [ ! -f "/tmp/claude-skill-acked-$SESSION_ID-$skill_name" ]; then
    UNACKED="$skill_name"
    break
  fi
done

if [ -z "$UNACKED" ]; then
  exit 0
fi

SKILL_MD="$PROJECT_DIR/.claude/skills/$UNACKED/SKILL.md"
RULES=""
if [ -f "$SKILL_MD" ]; then
  RULES=$(awk '/^## Rules/{flag=1} /^## /{if(flag && !/^## Rules/)exit} flag' "$SKILL_MD")
fi
if [ -z "$RULES" ]; then
  RULES="(Rules section not found in $SKILL_MD — refer to the loaded skill content already in context.)"
fi

MSG="BLOCKED: skill '$UNACKED' was loaded but not yet applied to your work.

Before this Write/Edit, you must:

1. State the specific rules from '$UNACKED' that apply to the file you're about to write.
2. State how your next write respects each rule.
3. Then ack the application by running this Bash tool call:
     touch /tmp/claude-skill-acked-$SESSION_ID-$UNACKED

One ack per skill per session. After acking, retry the Write/Edit.

Rules from $UNACKED/SKILL.md:

$RULES"

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

const GATE_FILENAME = "skill-gate.sh";
const AUTO_MARK_FILENAME = "skill-gate-automark.sh";
const APPLICATION_GATE_FILENAME = "skill-application-gate.sh";
const LEGACY_EVAL_FILENAME = "skill-forced-eval-hook.sh";
const LEGACY_AUDIT_RUNNER_FILENAME = "skill-audit-runner.sh";

export async function setupHook(targetDir = process.cwd()) {
  const resolved = resolve(targetDir);
  const hooksDir = join(resolved, ".claude", "hooks");
  const gatePath = join(hooksDir, GATE_FILENAME);
  const autoMarkPath = join(hooksDir, AUTO_MARK_FILENAME);
  const applicationGatePath = join(hooksDir, APPLICATION_GATE_FILENAME);
  const settingsPath = join(resolved, ".claude", "settings.json");

  await mkdir(hooksDir, { recursive: true });
  await writeFile(gatePath, GATE_SCRIPT, { mode: 0o755 });
  await chmod(gatePath, 0o755);
  await writeFile(autoMarkPath, AUTO_MARK_SCRIPT, { mode: 0o755 });
  await chmod(autoMarkPath, 0o755);
  await writeFile(applicationGatePath, APPLICATION_GATE_SCRIPT, { mode: 0o755 });
  await chmod(applicationGatePath, 0o755);

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

  await writeFile(settingsPath, JSON.stringify(settings, null, 2) + "\n", { mode: 0o644 });

  console.log(`  Hook installed: .claude/hooks/${GATE_FILENAME}`);
  console.log(`  Hook installed: .claude/hooks/${AUTO_MARK_FILENAME}`);
  console.log(`  Hook installed: .claude/hooks/${APPLICATION_GATE_FILENAME}`);
  console.log(`  Settings updated: .claude/settings.json`);
}
