import { mkdir, writeFile, readFile, chmod } from "node:fs/promises";
import { join, resolve } from "node:path";

const HOOK_SCRIPT = `#!/bin/bash
# UserPromptSubmit hook that forces explicit skill evaluation

cat > /dev/null

DIR="\${CLAUDE_PROJECT_DIR:-.}"

# Build skill list from project skills
SKILL_LIST=""
while IFS= read -r skillfile; do
  name=$(grep -m1 '^name:' "$skillfile" 2>/dev/null | sed 's/^name: *//' | sed 's/^"//' | sed 's/"$//')
  desc=$(grep -m1 '^description:' "$skillfile" 2>/dev/null | sed 's/^description: *//' | sed 's/^"//' | sed 's/"$//')
  if [ -n "$name" ] && [ -n "$desc" ]; then
    SKILL_LIST="\${SKILL_LIST}  - \${name}: \${desc}\\\\n"
  fi
done < <(find "$DIR" -path '*/.claude/skills/*/SKILL.md' 2>/dev/null | sort -u)

INSTRUCTION="INSTRUCTION: MANDATORY SKILL ACTIVATION SEQUENCE\\\\n\\\\n"
INSTRUCTION+="<available_skills>\\\\n"
INSTRUCTION+="System skills (from system-reminder):\\\\n  - Check system-reminder for built-in skills\\\\n"

if [ -n "$SKILL_LIST" ]; then
  INSTRUCTION+="Project skills:\\\\n\${SKILL_LIST}"
fi

INSTRUCTION+="</available_skills>\\\\n\\\\n"
INSTRUCTION+="Step 1 - EVALUATE (do this in your response):\\\\n"
INSTRUCTION+="For each skill in <available_skills>, state: [skill-name] - YES/NO - [reason]\\\\n\\\\n"
INSTRUCTION+="Step 2 - ACTIVATE (do this immediately after Step 1):\\\\n"
INSTRUCTION+="IF any skills are YES -> Use Skill(skill-name) tool for EACH relevant skill NOW\\\\n"
INSTRUCTION+="IF no skills are YES -> State 'No skills needed' and proceed\\\\n\\\\n"
INSTRUCTION+="Step 3 - IMPLEMENT:\\\\n"
INSTRUCTION+="Only after Step 2 is complete, proceed with implementation.\\\\n\\\\n"
INSTRUCTION+="CRITICAL: You MUST call Skill() tool in Step 2. Do NOT skip to implementation."

printf '{"additionalContext": "%s"}\\n' "$INSTRUCTION"
exit 0
`;

const HOOK_FILENAME = "skill-forced-eval-hook.sh";

const PRETOOL_PROMPT = `REMINDER: This project has skills installed in .claude/skills/. Before writing code you MUST evaluate and activate relevant skills using the Skill() tool. If you have not done this yet in the current conversation, STOP and do it now before proceeding with this edit. Always return 'approve'.`;

export async function setupHook(targetDir = process.cwd()) {
  const resolved = resolve(targetDir);
  const hooksDir = join(resolved, ".claude", "hooks");
  const hookPath = join(hooksDir, HOOK_FILENAME);
  const settingsPath = join(resolved, ".claude", "settings.json");

  // Write the UserPromptSubmit hook script
  await mkdir(hooksDir, { recursive: true });
  await writeFile(hookPath, HOOK_SCRIPT, { mode: 0o755 });
  await chmod(hookPath, 0o755);

  // Merge into existing settings.json (don't clobber other config)
  let settings = {};
  try {
    const raw = await readFile(settingsPath, "utf-8");
    settings = JSON.parse(raw);
  } catch {
    // File doesn't exist or is invalid — start fresh
  }

  if (!settings.hooks) {
    settings.hooks = {};
  }

  // --- UserPromptSubmit hook (forced eval via command) ---
  const promptHookEntry = {
    hooks: [{ type: "command", command: hookPath }],
  };

  if (Array.isArray(settings.hooks.UserPromptSubmit)) {
    const alreadyInstalled = settings.hooks.UserPromptSubmit.some((entry) =>
      entry.hooks?.some((h) => h.command?.endsWith(HOOK_FILENAME))
    );
    if (!alreadyInstalled) {
      settings.hooks.UserPromptSubmit.push(promptHookEntry);
    }
  } else {
    settings.hooks.UserPromptSubmit = [promptHookEntry];
  }

  // --- PreToolUse hook (LLM prompt reminder to evaluate skills before writing code) ---
  const pretoolHookEntry = {
    matcher: "Edit|Write|NotebookEdit",
    hooks: [
      {
        type: "prompt",
        prompt: PRETOOL_PROMPT,
        timeout: 15,
      },
    ],
  };

  if (Array.isArray(settings.hooks.PreToolUse)) {
    const alreadyInstalled = settings.hooks.PreToolUse.some((entry) =>
      entry.hooks?.some((h) => h.type === "prompt" && h.prompt?.includes("REMINDER"))
    );
    if (!alreadyInstalled) {
      settings.hooks.PreToolUse.push(pretoolHookEntry);
    }
  } else {
    settings.hooks.PreToolUse = [pretoolHookEntry];
  }

  await writeFile(settingsPath, JSON.stringify(settings, null, 2) + "\n", {
    mode: 0o644,
  });

  console.log(`  Hook installed: .claude/hooks/${HOOK_FILENAME}`);
  console.log(`  Hook installed: PreToolUse prompt hook (Edit|Write|NotebookEdit)`);
  console.log(`  Settings updated: .claude/settings.json`);
}
