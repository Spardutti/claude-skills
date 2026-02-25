import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import chalk from "chalk";

function humanName(skill) {
  return skill.name
    .replace(/-/g, " ")
    .replace(/\b\w/g, (c) => c.toUpperCase());
}

export async function installSkills(skills, targetDir = process.cwd()) {
  const baseDir = join(targetDir, ".claude", "skills");

  for (const skill of skills) {
    const skillDir = join(baseDir, skill.dirName);
    await mkdir(skillDir, { recursive: true });
    await writeFile(join(skillDir, "SKILL.md"), skill.content);
    console.log(`  ${chalk.green("✔")} ${chalk.bold(humanName(skill))} ${chalk.dim(`→ .claude/skills/${skill.dirName}/`)}`);
  }
}
