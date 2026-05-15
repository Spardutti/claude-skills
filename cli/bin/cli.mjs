#!/usr/bin/env node

import { confirm } from "@inquirer/prompts";
import chalk from "chalk";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { fetchSkills, fetchCommands, fetchAgents } from "../lib/github.mjs";
import { promptSkillSelection, promptCommandSelection, promptRemoval } from "../lib/prompt.mjs";
import { installSkills, installCommands, installRequiredAgents } from "../lib/install.mjs";
import { setupHook } from "../lib/setup-hook.mjs";
import { setupClaudeMd } from "../lib/setup-claude-md.mjs";
import {
  readManifest, writeManifest, computeOrphans, computeRemovals, scanInstalled, removeArtifacts,
  MANIFEST_FILE,
} from "../lib/manifest.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const pkg = JSON.parse(readFileSync(join(__dirname, "..", "package.json"), "utf-8"));
const CWD = process.cwd();

// `--sync`: re-install everything the manifest records (refreshed to the latest
// catalog) and prune anything removed upstream — no interactive menu.
async function runSync(manifest, catalog) {
  if (!manifest) {
    console.log(`  ${chalk.yellow("Nothing to sync")} — no manifest in this project. Run without --sync first.\n`);
    return;
  }
  const orphans = computeOrphans(manifest, catalog);
  const orphanCount = orphans.skills.length + orphans.commands.length + orphans.agents.length;
  if (orphanCount > 0) {
    await removeArtifacts(CWD, orphans);
    console.log(`  ${chalk.green("✔")} Pruned ${orphanCount} item(s) removed from the catalog.`);
  }

  const skills = catalog.skills.filter((s) => manifest.skills.includes(s.dirName));
  const commands = catalog.commands.filter((c) => manifest.commands.includes(c.fileName));
  if (skills.length > 0) { console.log(); await installSkills(skills); }
  if (commands.length > 0) { console.log(); await installCommands(commands); }
  const { installed } = await installRequiredAgents(commands, catalog.agents, CWD);

  await writeManifest(CWD, {
    catalogVersion: pkg.version,
    skills: skills.map((s) => s.dirName),
    commands: commands.map((c) => c.fileName),
    agents: installed.map((a) => a.fileName),
  });
  console.log(`\n  ${chalk.green("✔")} ${chalk.bold(`Synced to catalog v${pkg.version}.`)}\n`);
}

async function main() {
  const isSync = process.argv.includes("--sync");
  console.log(`\n  ${chalk.bold.cyan("Claude Skills Installer")} ${chalk.dim(`v${pkg.version}`)}\n`);

  console.log(chalk.dim("  Fetching available skills, commands, and agents...\n"));
  const [skills, commands, agents] = await Promise.all([fetchSkills(), fetchCommands(), fetchAgents()]);
  const catalog = { skills, commands, agents };
  const manifest = await readManifest(CWD);

  if (isSync) return runSync(manifest, catalog);

  // --- Prune items renamed or removed from the catalog upstream ---
  const orphans = computeOrphans(manifest, catalog);
  const orphanNames = [...orphans.skills, ...orphans.commands, ...orphans.agents];
  if (orphanNames.length > 0) {
    console.log(`  ${chalk.yellow("!")} ${orphanNames.length} installed item(s) are no longer in the catalog (renamed or removed):`);
    for (const n of orphanNames) console.log(`    ${chalk.dim("-")} ${n}`);
    if (await confirm({ message: "Delete these stale items?", default: true })) {
      await removeArtifacts(CWD, orphans);
      console.log(`  ${chalk.green("✔")} Removed ${orphanNames.length} stale item(s).`);
    }
    console.log();
  }

  // --- Legacy projects (no manifest): offer to clean content not in the catalog ---
  if (!manifest) {
    const disk = await scanInstalled(CWD);
    const catSkills = new Set(skills.map((s) => s.dirName));
    const catCommands = new Set(commands.map((c) => c.fileName));
    const strayS = disk.skills.filter((d) => !catSkills.has(d));
    const strayC = disk.commands.filter((f) => !catCommands.has(f));
    if (strayS.length + strayC.length > 0) {
      console.log(`  ${chalk.yellow("!")} Untracked items in .claude/ that aren't in the catalog — possibly stale, possibly your own:`);
      const toRemove = await promptRemoval(
        [...strayS, ...strayC],
        "Select any to delete (leave unchecked to keep):",
        false,
      );
      if (toRemove.length > 0) {
        await removeArtifacts(CWD, {
          skills: toRemove.filter((n) => strayS.includes(n)),
          commands: toRemove.filter((n) => strayC.includes(n)),
        });
        console.log(`  ${chalk.green("✔")} Removed ${toRemove.length} item(s).`);
      }
      console.log();
    }
  }

  // --- Skills ---
  let selectedSkills = [];
  if (skills.length === 0) {
    console.log("  No skills found.");
  } else {
    selectedSkills = await promptSkillSelection(skills, manifest?.skills ?? []);
    if (selectedSkills.length > 0) {
      console.log();
      await installSkills(selectedSkills);
    }
  }

  // --- Commands ---
  let selectedCommands = [];
  let installedAgents = [];
  if (commands.length > 0) {
    console.log();
    selectedCommands = await promptCommandSelection(commands, manifest?.commands ?? []);
    if (selectedCommands.length > 0) {
      console.log();
      await installCommands(selectedCommands);
      const { installed, missing } = await installRequiredAgents(selectedCommands, agents, CWD);
      installedAgents = installed;
      if (missing.length > 0) {
        console.log(`  ${chalk.yellow("!")} Missing agents referenced by commands: ${missing.join(", ")}`);
      }
    }
  }

  // --- Remove items the user deselected (were installed, still in the catalog, now unchecked) ---
  const removals = computeRemovals(manifest, catalog, {
    skills: selectedSkills.map((s) => s.dirName),
    commands: selectedCommands.map((c) => c.fileName),
    agents: installedAgents.map((a) => a.fileName),
  });
  const removalCount = removals.skills.length + removals.commands.length + removals.agents.length;
  if (removalCount > 0) {
    await removeArtifacts(CWD, removals);
    console.log(`\n  ${chalk.dim(`Removed ${removalCount} deselected item(s): ${[...removals.skills, ...removals.commands].join(", ")}`)}`);
  }

  if (selectedSkills.length === 0 && selectedCommands.length === 0 && removalCount === 0) {
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

  // --- Record what is now installed ---
  await writeManifest(CWD, {
    catalogVersion: pkg.version,
    skills: selectedSkills.map((s) => s.dirName),
    commands: selectedCommands.map((c) => c.fileName),
    agents: installedAgents.map((a) => a.fileName),
  });

  const parts = [];
  if (selectedSkills.length > 0) parts.push(`${selectedSkills.length} skill(s)`);
  if (selectedCommands.length > 0) parts.push(`${selectedCommands.length} command(s)`);
  if (installedAgents.length > 0) parts.push(`${installedAgents.length} agent(s)`);
  console.log(`\n  ${chalk.green("✔")} ${chalk.bold(`${parts.join(", ")} installed.`)} ${chalk.dim(`Tracked in .claude/${MANIFEST_FILE}`)}\n`);
}

main().catch((err) => {
  if (err.name === "ExitPromptError") {
    console.log("\n  Cancelled.\n");
    process.exit(0);
  }
  console.error(`\n  ${chalk.red("Error:")} ${err.message}\n`);
  process.exit(1);
});
