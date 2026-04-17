#!/usr/bin/env node

import { confirm } from "@inquirer/prompts";
import chalk from "chalk";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { fetchSkills, fetchCommands, fetchAgents } from "../lib/github.mjs";
import { promptSkillSelection, promptCommandSelection } from "../lib/prompt.mjs";
import { installSkills, installCommands, installRequiredAgents } from "../lib/install.mjs";
import { setupHook } from "../lib/setup-hook.mjs";
import { setupClaudeMd } from "../lib/setup-claude-md.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const pkg = JSON.parse(readFileSync(join(__dirname, "..", "package.json"), "utf-8"));

async function main() {
  console.log(`\n  ${chalk.bold.cyan("Claude Skills Installer")} ${chalk.dim(`v${pkg.version}`)}\n`);

  console.log(chalk.dim("  Fetching available skills, commands, and agents...\n"));
  const [skills, commands, agents] = await Promise.all([fetchSkills(), fetchCommands(), fetchAgents()]);

  // --- Skills ---
  let selectedSkills = [];
  if (skills.length === 0) {
    console.log("  No skills found.");
  } else {
    selectedSkills = await promptSkillSelection(skills);
    if (selectedSkills.length > 0) {
      console.log();
      await installSkills(selectedSkills);
    }
  }

  // --- Commands ---
  let selectedCommands = [];
  let installedAgentCount = 0;
  if (commands.length > 0) {
    console.log();
    selectedCommands = await promptCommandSelection(commands);
    if (selectedCommands.length > 0) {
      console.log();
      await installCommands(selectedCommands);

      const { installed, missing } = await installRequiredAgents(selectedCommands, agents);
      installedAgentCount = installed.length;
      if (missing.length > 0) {
        console.log(
          `  ${chalk.yellow("!")} Missing agents referenced by commands: ${missing.join(", ")}`
        );
      }
    }
  }

  if (selectedSkills.length === 0 && selectedCommands.length === 0) {
    console.log("\n  Nothing selected.");
    process.exit(0);
  }

  // --- Hook setup (only if skills were installed) ---
  if (selectedSkills.length > 0) {
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
  }

  const parts = [];
  if (selectedSkills.length > 0) parts.push(`${selectedSkills.length} skill(s)`);
  if (selectedCommands.length > 0) parts.push(`${selectedCommands.length} command(s)`);
  if (installedAgentCount > 0) parts.push(`${installedAgentCount} agent(s)`);
  console.log(`\n  ${chalk.green("✔")} ${chalk.bold(`${parts.join(", ")} installed successfully.`)}\n`);
}

main().catch((err) => {
  if (err.name === "ExitPromptError") {
    console.log("\n  Cancelled.\n");
    process.exit(0);
  }
  console.error(`\n  ${chalk.red("Error:")} ${err.message}\n`);
  process.exit(1);
});
