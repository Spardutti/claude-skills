#!/usr/bin/env node

import { fetchSkills } from "../lib/github.mjs";
import { promptSkillSelection } from "../lib/prompt.mjs";
import { installSkills } from "../lib/install.mjs";

async function main() {
  console.log("\n  Claude Skills Installer\n");

  console.log("  Fetching available skills...\n");
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
  console.log(`\n  Done! ${selected.length} skill(s) installed.\n`);
}

main().catch((err) => {
  if (err.name === "ExitPromptError") {
    console.log("\n  Cancelled.\n");
    process.exit(0);
  }
  console.error(`\n  Error: ${err.message}\n`);
  process.exit(1);
});
