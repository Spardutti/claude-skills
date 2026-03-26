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

const FILE_SIZE_BLOCK = `
## File Size Enforcement

- **Never write a file longer than 200 lines of code.** If a file would exceed 200 lines, split it into smaller modules before writing.
- This rule applies during skill evaluation: if the code you're about to write would exceed 200 lines in any single file, refactor into multiple files first.
- Skill evaluation must check this limit as part of every ACTIVATE decision.`;

const EVAL_MARKER = "skill_evaluation:";
const FILE_SIZE_MARKER = "## File Size Enforcement";

export async function setupClaudeMd(targetDir = process.cwd()) {
  const resolved = resolve(targetDir);
  const claudeMdPath = join(resolved, "CLAUDE.md");

  let existing = "";
  try {
    existing = await readFile(claudeMdPath, "utf-8");
  } catch {
    // File doesn't exist — will create
  }

  const hasEval = existing.includes(EVAL_MARKER);
  const hasFileSize = existing.includes(FILE_SIZE_MARKER);

  if (hasEval && hasFileSize) {
    console.log("  CLAUDE.md already has skill_evaluation and file size rules — skipped.");
    return;
  }

  let content = existing.trimEnd();

  if (!hasEval) {
    content = content.length > 0
      ? content + "\n" + SKILL_EVAL_BLOCK
      : SKILL_EVAL_BLOCK.trimStart();
  }

  if (!hasFileSize) {
    content = content + "\n" + FILE_SIZE_BLOCK;
  }

  await writeFile(claudeMdPath, content + "\n", { mode: 0o644 });

  if (!hasEval && !hasFileSize) {
    console.log("  CLAUDE.md updated with skill_evaluation and file size rules.");
  } else if (!hasEval) {
    console.log("  CLAUDE.md updated with skill_evaluation block.");
  } else {
    console.log("  CLAUDE.md updated with file size enforcement rule.");
  }
}
