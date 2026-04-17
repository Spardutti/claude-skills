import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import chalk from "chalk";

function humanName(item) {
  return item.name
    .replace(/-/g, " ")
    .replace(/\b\w/g, (c) => c.toUpperCase());
}

async function installFlat(items, subdir, targetDir) {
  const baseDir = join(targetDir, ".claude", subdir);
  await mkdir(baseDir, { recursive: true });
  for (const item of items) {
    await writeFile(join(baseDir, item.fileName), item.content);
    console.log(`  ${chalk.green("✔")} ${chalk.bold(humanName(item))} ${chalk.dim(`→ .claude/${subdir}/${item.fileName}`)}`);
  }
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

export function installCommands(commands, targetDir = process.cwd()) {
  return installFlat(commands, "commands", targetDir);
}

export function installAgents(agents, targetDir = process.cwd()) {
  return installFlat(agents, "agents", targetDir);
}

export async function installRequiredAgents(selectedCommands, availableAgents, targetDir = process.cwd()) {
  const requiredNames = new Set(
    selectedCommands.flatMap((c) => c.requiresAgents ?? [])
  );
  if (requiredNames.size === 0) return { installed: [], missing: [] };

  const installed = availableAgents.filter((a) => requiredNames.has(a.name));
  const missing = [...requiredNames].filter(
    (n) => !availableAgents.some((a) => a.name === n)
  );

  if (installed.length > 0) {
    console.log();
    await installAgents(installed, targetDir);
  }
  return { installed, missing };
}
