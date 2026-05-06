import { mkdir, writeFile, readFile, chmod } from "node:fs/promises";
import { join, resolve } from "node:path";

// PreToolUse gate on Write|Edit|MultiEdit. Blocks the tool call unless
// the assistant has emitted the literal sentinel [skills-checked] since
// the most recent user prompt. Resets every user turn, runs once per
// turn (subsequent edits in the same turn pass through).
//
// Pass-through cases:
//   - project has no .claude/skills/*/SKILL.md files
//   - transcript_path missing or unreadable
//   - no user prompt found in transcript
//
// tool_result lines (which include the gate's own deny message) are
// filtered out of the sentinel scan to prevent self-satisfaction.
const GATE_SCRIPT = `#!/bin/bash
# PreToolUse gate: forces skill evaluation before file-writing tools run.

INPUT=$(cat)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

if ! find "$PROJECT_DIR" -path '*/.claude/skills/*/SKILL.md' 2>/dev/null | grep -q .; then
  exit 0
fi

TRANSCRIPT=$(printf '%s' "$INPUT" | grep -o '"transcript_path":"[^"]*"' | head -1 | sed 's/"transcript_path":"//; s/"$//')
if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  exit 0
fi

LAST_PROMPT=$(grep -n '"type":"user"' "$TRANSCRIPT" 2>/dev/null | grep -v 'tool_use_id' | tail -1 | cut -d: -f1)
if [ -z "$LAST_PROMPT" ]; then
  exit 0
fi

if tail -n +"$LAST_PROMPT" "$TRANSCRIPT" | grep -v 'tool_use_id' | grep -qF '[skills-checked]'; then
  exit 0
fi

cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Skill evaluation required before writing or editing code. List each available skill as ACTIVATE or SKIP with a one-line reason, call Skill() for any ACTIVATE entries, then emit the literal token [skills-checked] (square brackets included) on its own line. Then retry the tool call."}}
EOF
exit 0
`;

const GATE_FILENAME = "skill-gate.sh";
const LEGACY_EVAL_FILENAME = "skill-forced-eval-hook.sh";

export async function setupHook(targetDir = process.cwd()) {
  const resolved = resolve(targetDir);
  const hooksDir = join(resolved, ".claude", "hooks");
  const gatePath = join(hooksDir, GATE_FILENAME);
  const settingsPath = join(resolved, ".claude", "settings.json");

  await mkdir(hooksDir, { recursive: true });
  await writeFile(gatePath, GATE_SCRIPT, { mode: 0o755 });
  await chmod(gatePath, 0o755);

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

  await writeFile(settingsPath, JSON.stringify(settings, null, 2) + "\n", { mode: 0o644 });

  console.log(`  Hook installed: .claude/hooks/${GATE_FILENAME}`);
  console.log(`  Settings updated: .claude/settings.json`);
}
