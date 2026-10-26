import chalk from "chalk";
import { existsSync } from "node:fs";
import { readdir } from "node:fs/promises";
import { join, basename } from "node:path";
import { installSkills, installCommands, installRequiredAgents, withRequiredCommands } from "./install.mjs";
import { setupHook } from "./setup-hook.mjs";
import { setupClaudeMd } from "./setup-claude-md.mjs";
import { readManifest, writeManifest, computeOrphans, removeArtifacts, catalogIds, MANIFEST_FILE } from "./manifest.mjs";

const SEARCH_DEPTH = 5;

// Sync installs only what was picked, so a new skill or command would otherwise go unseen.
function announceNew(manifest, catalog, have) {
  if (!manifest.known) return;
  const known = new Set(manifest.known);
  const fresh = [
    ...catalog.skills.map((s) => ({ id: s.dirName, label: s.name, about: s.description })),
    ...catalog.commands.map((c) => ({ id: c.fileName, label: `/${c.name}`, about: c.description })),
  ].filter((x) => !known.has(x.id) && !have.has(x.id));
  if (fresh.length === 0) return;
  console.log();
  for (const x of fresh) console.log(`  ${chalk.cyan("new")} ${chalk.bold(x.label)} — ${x.about.split(" — ")[0].slice(0, 100)}`);
  console.log(chalk.dim("  Run the CLI without --sync to pick any of them."));
}

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
  const picked = catalog.commands.filter((c) => manifest.commands.includes(c.fileName));
  const commands = withRequiredCommands(picked, catalog.commands);
  for (const c of commands.slice(picked.length)) console.log(`  ${chalk.green("+")} Added ${chalk.bold(`/${c.name}`)} — a command you have needs it.`);
  if (skills.length > 0) { console.log(); await installSkills(skills, dir); }
  if (commands.length > 0) { console.log(); await installCommands(commands, dir); }
  const { installed } = await installRequiredAgents(commands, catalog.agents, dir);
  if (existsSync(join(dir, ".claude", "hooks", "skill-gate.sh"))) { console.log(); await setupHook(dir); await setupClaudeMd(dir); }
  announceNew(manifest, catalog, new Set([...skills.map((s) => s.dirName), ...commands.map((c) => c.fileName)]));

  await writeManifest(dir, {
    catalogVersion: version,
    skills: skills.map((s) => s.dirName),
    commands: commands.map((c) => c.fileName),
    agents: installed.map((a) => a.fileName),
    known: catalogIds(catalog),
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
