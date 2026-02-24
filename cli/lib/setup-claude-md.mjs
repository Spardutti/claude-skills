import { readFile, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";

const SKILL_EVAL_BLOCK = `
skill_evaluation:
  mandatory: true
  rule: |
    BEFORE writing ANY code, you MUST:
    1. List EVERY skill from the system-reminder's available skills section
    2. For each skill, write: [skill-name] → ACTIVATE / SKIP — [one-line reason]
    3. Call Skill(name) for every skill marked ACTIVATE
    4. Only THEN proceed to implementation
    If you skip this evaluation, your response is INCOMPLETE and WRONG.`;

const MARKER = "skill_evaluation:";

export async function setupClaudeMd(targetDir = process.cwd()) {
  const resolved = resolve(targetDir);
  const claudeMdPath = join(resolved, "CLAUDE.md");

  let existing = "";
  try {
    existing = await readFile(claudeMdPath, "utf-8");
  } catch {
    // File doesn't exist — will create
  }

  // Don't add duplicate block
  if (existing.includes(MARKER)) {
    console.log("  CLAUDE.md already has skill_evaluation block — skipped.");
    return;
  }

  // Append the block (after trailing ``` if the file uses a yaml code fence)
  const trimmed = existing.trimEnd();
  const content = trimmed.length > 0
    ? trimmed + "\n" + SKILL_EVAL_BLOCK + "\n"
    : SKILL_EVAL_BLOCK.trimStart() + "\n";

  await writeFile(claudeMdPath, content, { mode: 0o644 });
  console.log("  CLAUDE.md updated with skill_evaluation block.");
}
