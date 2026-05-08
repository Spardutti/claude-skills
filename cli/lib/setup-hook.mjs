import { mkdir, writeFile, readFile, chmod } from "node:fs/promises";
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
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Skill evaluation required before file edits in this session. (1) List each available skill as ACTIVATE or SKIP with a one-line reason. (2) Call Skill() for any ACTIVATE entries — this auto-clears the gate for the rest of the session. If all skills are SKIP, run this exact Bash command instead: touch /tmp/claude-skill-gate-$SESSION_ID  (3) Then retry the file edit."}}
EOF
exit 0
`;

// PostToolUse on Skill: auto-creates the per-session gate marker.
const AUTO_MARK_SCRIPT = `#!/bin/bash
# PostToolUse on Skill: auto-marks the skill-gate as satisfied for the session.

INPUT=$(cat)

SESSION_ID=$(printf '%s' "$INPUT" | grep -o '"session_id":"[^"]*"' | head -1 | sed 's/"session_id":"//; s/"$//')
if [ -z "$SESSION_ID" ]; then
  exit 0
fi

touch "/tmp/claude-skill-gate-$SESSION_ID"
exit 0
`;

const GATE_FILENAME = "skill-gate.sh";
const AUTO_MARK_FILENAME = "skill-gate-automark.sh";
const LEGACY_EVAL_FILENAME = "skill-forced-eval-hook.sh";

export async function setupHook(targetDir = process.cwd()) {
  const resolved = resolve(targetDir);
  const hooksDir = join(resolved, ".claude", "hooks");
  const gatePath = join(hooksDir, GATE_FILENAME);
  const autoMarkPath = join(hooksDir, AUTO_MARK_FILENAME);
  const settingsPath = join(resolved, ".claude", "settings.json");

  await mkdir(hooksDir, { recursive: true });
  await writeFile(gatePath, GATE_SCRIPT, { mode: 0o755 });
  await chmod(gatePath, 0o755);
  await writeFile(autoMarkPath, AUTO_MARK_SCRIPT, { mode: 0o755 });
  await chmod(autoMarkPath, 0o755);

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
  console.log(`  Settings updated: .claude/settings.json`);
}
