#!/usr/bin/env node

import { confirm } from "@inquirer/prompts";
import chalk from "chalk";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { fetchSkills } from "../lib/github.mjs";
import { promptSkillSelection } from "../lib/prompt.mjs";
import { installSkills } from "../lib/install.mjs";
import { setupHook } from "../lib/setup-hook.mjs";
import { setupClaudeMd } from "../lib/setup-claude-md.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const pkg = JSON.parse(readFileSync(join(__dirname, "..", "package.json"), "utf-8"));

async function main() {
  console.log(`\n  ${chalk.bold.cyan("Claude Skills Installer")} ${chalk.dim(`v${pkg.version}`)}\n`);

  console.log(chalk.dim("  Fetching available skills...\n"));
  const skills = await fetchSkills();

  if (skills.length === 0) {
    console.log("  No skills found.");
    process.exit(0);
  }

  const selected = await promptSkillSelection(skills);

  if (selected.length === 0) {
    console.log("\n  No skills selected.");
    process.exit(0);
  }

  console.log();
  await installSkills(selected);

  console.log();
  const shouldSetup = await confirm({
    message: "Set up skill evaluation hook + CLAUDE.md rule? (Recommended)",
    default: true,
  });

  if (shouldSetup) {
    console.log();
    await setupHook();
    await setupClaudeMd();
  }

  console.log(`\n  ${chalk.green("✔")} ${chalk.bold(`${selected.length} skill(s) installed successfully.`)}\n`);
}

main().catch((err) => {
  if (err.name === "ExitPromptError") {
    console.log("\n  Cancelled.\n");
    process.exit(0);
  }
  console.error(`\n  ${chalk.red("Error:")} ${err.message}\n`);
  process.exit(1);
});
