#!/usr/bin/env node

import { confirm, input } from "@inquirer/prompts";
import chalk from "chalk";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { fetchSkills, fetchCommands, fetchAgents } from "../lib/github.mjs";
import { promptSkillSelection, promptCommandSelection, promptRemoval } from "../lib/prompt.mjs";
import { installSkills, installCommands, installRequiredAgents } from "../lib/install.mjs";
import { setupHook, detectStack, writeGauntletConf } from "../lib/setup-hook.mjs";
import { makeLocalSource, reportToolNeeds } from "../lib/local.mjs";
import { scaffoldStryker } from "../lib/scaffold-stryker.mjs";
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

  // --local[=path] reads the catalog from a working copy instead of GitHub, so an
  // unreleased change can be installed and tried without publishing it first.
  const localArg = process.argv.find((a) => a === "--local" || a.startsWith("--local="));
  const localRoot = localArg ? (localArg.split("=")[1] || join(__dirname, "..", "..")) : null;

  console.log(`\n  ${chalk.bold.cyan("Claude Skills Installer")} ${chalk.dim(`v${pkg.version}`)}\n`);

  let fetchers = { fetchSkills, fetchCommands, fetchAgents };
  if (localRoot) {
    fetchers = makeLocalSource(localRoot);
    console.log(`  ${chalk.yellow("LOCAL")} ${chalk.dim(`reading the catalog from ${localRoot}`)}\n`);
  } else {
    console.log(chalk.dim("  Fetching available skills, commands, and agents...\n"));
  }
  const [skills, commands, agents] = await Promise.all([
    fetchers.fetchSkills(), fetchers.fetchCommands(), fetchers.fetchAgents(),
  ]);
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

  // --- Hook setup ---
  // Offered whenever anything was installed: the skill gates need skills, but the
  // gauntlet guards any repo with a test runner, commands-only installs included.
  if (selectedSkills.length > 0 || selectedCommands.length > 0) {
    console.log();
    const shouldSetup = await confirm({
      message: "Set up hooks — skill evaluation before edits, verification after? (Recommended)",
      default: true,
    });
    if (shouldSetup) {
      console.log();
      await setupHook();
      await setupClaudeMd();

      // Report what the gauntlet will actually run, so a silent no-op is visible.
      // This asks the installed hook itself — never a second copy of its logic.
      const gates = await detectStack(CWD);
      if (gates) {
        for (const gate of gates.split(";").map((g) => g.trim()).filter(Boolean)) {
          console.log(`  ${chalk.dim(`Gauntlet gate: ${gate}`)}`);
        }
      } else {
        console.log(`  ${chalk.yellow("!")} ${chalk.dim("Gauntlet found no test runner here — it will stay asleep.")}`);
        console.log();
        const wantConf = await confirm({
          message: "Point it at your test command now?",
          default: false,
        });
        if (wantConf) {
          const cmd = (await input({ message: "Test command:" })).trim();
          if (cmd) {
            const written = await writeGauntletConf(CWD, cmd);
            console.log(`  Config written: ${written.replace(CWD + "/", "")}`);
          }
        }
      }
    }
  }

  // --- What the installed commands need that this project does not have ---
  // /ship's mutation check is per project, so a monorepo needs a tool per project.
  if (selectedCommands.some((c) => c.fileName === "ship.md")) {
    const needs = await reportToolNeeds(CWD);
    console.log();
    if (needs.length === 0) {
      console.log(`  ${chalk.dim("/ship's mutation check has a tool in every project here.")}`);
    } else {
      console.log(`  ${chalk.yellow("!")} ${chalk.bold("/ship needs a mutation tool per project")} ${chalk.dim("— without one it reports UNPROVEN, and never blocks.")}`);
      if (!selectedSkills.some((s) => s.dirName === "testing-best-practices")) {
        console.log(`    ${chalk.dim("Setting these up has traps — install the testing-best-practices skill for MUTATION-TESTING.md.")}`);
      }
      for (const n of needs.filter((n) => !n.ignorerOnly)) {
        console.log(`    ${chalk.bold(n.label)} needs ${n.tool}`);
        console.log(`      ${chalk.cyan(n.install)}`);
        console.log(`      ${chalk.dim(n.config)}`);
        for (const line of n.also ?? []) console.log(`      ${chalk.dim(line)}`);
      }
      for (const n of needs.filter((n) => n.ignorerOnly)) {
        console.log(`    ${chalk.bold(n.label)} runs ${n.tool} without the class-name ignorer`);
        console.log(`      ${chalk.dim("~40% of a first React run is mutants on className strings, which no test can honestly kill")}`);
      }

      // Printing five steps meant every project was set up by hand, and the one
      // step people skipped was the class-name ignorer — the reason a first run
      // comes back with dozens of mutants on className strings that no test can
      // honestly kill. Write the two files instead of describing them.
      const stryker = needs.filter((n) => n.tool === "Stryker");
      if (stryker.length > 0) {
        console.log();
        const doScaffold = await confirm({
          message: `Write Stryker's config and the class-name ignorer for ${stryker.length} project(s)?`,
          default: true,
        });
        if (doScaffold) {
          const installs = [];
          const vitest = [];
          for (const n of stryker) {
            const r = await scaffoldStryker(CWD, n.rel);
            for (const f of r.wrote) console.log(`  Wrote: ${f}`);
            for (const f of r.patched) console.log(`  Added the ignorer to: ${f}`);
            for (const f of r.kept) console.log(`  ${chalk.dim(`Kept yours: ${f}`)}`);
            for (const f of r.unreadable) {
              console.log(`  ${chalk.yellow("!")} ${f} is not readable as JSON — left alone, add the ignorer by hand`);
            }
            // A project that already runs Stryker needs neither the install nor
            // the vitest exclude repeated at it; it only lacked the ignorer.
            if (!n.ignorerOnly) {
              installs.push(r.install);
              vitest.push(r.vitest);
            }
          }
          // Left to the reader on purpose: installing touches the lockfile and
          // the network, and editing an existing vitest config means parsing
          // someone's plugins and aliases, where being wrong breaks their tests.
          if (installs.length > 0) {
            console.log(`\n  ${chalk.yellow("!")} ${chalk.bold("Two steps left, per project:")}`);
            for (const c of installs) console.log(`      ${chalk.cyan(c)}`);
            for (const v of vitest) console.log(`      ${chalk.dim(v)}`);
          }
          // The ignorer imports @stryker-mutator/api, which npm hoists by
          // accident and pnpm does not. Missing, it prints one WARN PluginLoader
          // line, loads nothing, and every className mutant comes back survived.
          if (stryker.some((n) => n.ignorerOnly)) {
            console.log(`\n  ${chalk.yellow("!")} ${chalk.bold("The ignorer needs its own dependency:")}`);
            console.log(`      ${chalk.cyan("add @stryker-mutator/api as a dev dependency")} ${chalk.dim("— pnpm does not hoist it, and without it the ignorer silently does not load")}`);
          }
        }
      }
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
