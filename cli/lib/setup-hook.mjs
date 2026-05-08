import { mkdir, writeFile, readFile, chmod } from "node:fs/promises";
import { join, resolve } from "node:path";

// PreToolUse gate on Write|Edit|MultiEdit. Blocks the tool call unless
// a per-prompt marker file exists at $PROJECT_DIR/.claude/.skill-gate-<UUID>,
// where <UUID> is the uuid of the most recent typed user prompt. The
// assistant creates the marker via Bash; Bash output is flushed
// synchronously, so the marker is race-free against the message-buffering
// behavior that broke the earlier text-sentinel approach (Claude Code
// writes assistant content blocks to JSONL only after the turn completes,
// so [skills-checked] text emitted in the same message as a tool_use is
// invisible to PreToolUse).
//
// LAST_PROMPT_UUID is detected by matching user-role lines whose content
// is a JSON string ("role":"user","content":"..."), which excludes
// tool_results, skill loads, task notifications, and slash-command
// payloads (all of which use array content).
//
// Pass-through cases:
//   - project has no .claude/skills/*/SKILL.md files
//   - transcript_path missing or unreadable
//   - no typed user prompt found in transcript
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

LAST_LINE=$(grep -E '"role":"user","content":"' "$TRANSCRIPT" 2>/dev/null | tail -1)
LAST_PROMPT_UUID=$(printf '%s' "$LAST_LINE" | grep -o '"uuid":"[^"]*"' | head -1 | sed 's/"uuid":"//;s/"$//')
if [ -z "$LAST_PROMPT_UUID" ]; then
  exit 0
fi

MARKER_DIR="$PROJECT_DIR/.claude"
MARKER="$MARKER_DIR/.skill-gate-$LAST_PROMPT_UUID"
if [ -f "$MARKER" ]; then
  find "$MARKER_DIR" -maxdepth 1 -name '.skill-gate-*' ! -name ".skill-gate-$LAST_PROMPT_UUID" -delete 2>/dev/null
  exit 0
fi

cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Skill evaluation required before file edits. (1) List each available skill as ACTIVATE or SKIP with a one-line reason. (2) Call Skill() for any ACTIVATE entries. (3) Run this exact Bash command to record approval: mkdir -p .claude && touch .claude/.skill-gate-$LAST_PROMPT_UUID  (4) Then retry the file edit. The marker is unique to this user prompt and is auto-cleaned on the next prompt."}}
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
