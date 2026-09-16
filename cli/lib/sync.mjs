import chalk from "chalk";
import { existsSync } from "node:fs";
import { readdir } from "node:fs/promises";
import { join, basename } from "node:path";
import { installSkills, installCommands, installRequiredAgents } from "./install.mjs";
import { setupHook } from "./setup-hook.mjs";
import { readManifest, writeManifest, computeOrphans, removeArtifacts, MANIFEST_FILE } from "./manifest.mjs";

const SEARCH_DEPTH = 5;

// Re-install everything the manifest records (refreshed to the latest catalog),
// refresh hooks the project already has, and prune anything removed upstream.
export async function runSync(dir, catalog, version) {
  const manifest = await readManifest(dir);
  if (!manifest) {
    console.log(`  ${chalk.yellow("Nothing to sync")} — no manifest in this project. Run without --sync first.\n`);
    return false;
  }
  const orphans = computeOrphans(manifest, catalog);
  const orphanCount = orphans.skills.length + orphans.commands.length + orphans.agents.length;
  if (orphanCount > 0) {
    await removeArtifacts(dir, orphans);
    console.log(`  ${chalk.green("✔")} Pruned ${orphanCount} item(s) removed from the catalog.`);
  }

  const skills = catalog.skills.filter((s) => manifest.skills.includes(s.dirName));
  const commands = catalog.commands.filter((c) => manifest.commands.includes(c.fileName));
  if (skills.length > 0) { console.log(); await installSkills(skills, dir); }
  if (commands.length > 0) { console.log(); await installCommands(commands, dir); }
  const { installed } = await installRequiredAgents(commands, catalog.agents, dir);
  if (existsSync(join(dir, ".claude", "hooks", "skill-gate.sh"))) { console.log(); await setupHook(dir); }

  await writeManifest(dir, {
    catalogVersion: version,
    skills: skills.map((s) => s.dirName),
    commands: commands.map((c) => c.fileName),
    agents: installed.map((a) => a.fileName),
  });
  console.log(`\n  ${chalk.green("✔")} ${chalk.bold(`Synced to catalog v${version}.`)}\n`);
  return true;
}

export async function findProjects(root, depth = SEARCH_DEPTH) {
  if (existsSync(join(root, ".claude", MANIFEST_FILE))) return [root];
  if (depth === 0) return [];
  let entries;
  try {
    entries = await readdir(root, { withFileTypes: true });
  } catch {
    return [];
  }
  const found = [];
  for (const e of entries) {
    if (!e.isDirectory() || e.name.startsWith(".") || e.name === "node_modules") continue;
    found.push(...(await findProjects(join(root, e.name), depth - 1)));
  }
  return found;
}

export async function runSyncAll(root, catalog, version) {
  const projects = await findProjects(root);
  if (projects.length === 0) {
    console.log(`  ${chalk.yellow("No projects found")} under ${root} with .claude/${MANIFEST_FILE}.\n`);
    return;
  }
  const failed = [];
  for (const dir of projects) {
    console.log(chalk.bold.cyan(`── ${dir}`));
    try {
      await runSync(dir, catalog, version);
    } catch (err) {
      failed.push(basename(dir));
      console.log(`  ${chalk.red("Error:")} ${err.message}\n`);
    }
  }
  const ok = projects.length - failed.length;
  console.log(`  ${chalk.green("✔")} ${chalk.bold(`${ok} of ${projects.length} project(s) synced to v${version}.`)}`);
  if (failed.length > 0) console.log(`  ${chalk.red("✘")} Failed: ${failed.join(", ")}`);
  console.log();
  if (failed.length > 0) process.exitCode = 1;
}
