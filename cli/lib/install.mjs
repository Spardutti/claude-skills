import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";

export async function installSkills(skills, targetDir = process.cwd()) {
  const baseDir = join(targetDir, ".claude", "skills");

  for (const skill of skills) {
    const skillDir = join(baseDir, skill.dirName);
    await mkdir(skillDir, { recursive: true });
    await writeFile(join(skillDir, "SKILL.md"), skill.content);
    console.log(`  Installed: ${skill.name} → .claude/skills/${skill.dirName}/SKILL.md`);
  }
}
