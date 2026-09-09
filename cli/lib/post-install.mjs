// Everything the installer does AFTER the user has chosen what to install:
// offer the hooks, then report what the installed commands need that this
// project does not have. Lifted out of a 270-line main() — these two are a
// phase of their own, they run only when something was installed, and neither
// decides what gets installed.
import { confirm, input } from "@inquirer/prompts";
import chalk from "chalk";
import {
  setupHook,
  detectStack,
  writeGauntletConf,
  autoModeRuleStatus,
  writeAutoModeRule,
} from "./setup-hook.mjs";
import { reportToolNeeds } from "./local.mjs";
import { scaffoldStryker } from "./scaffold-stryker.mjs";
import { setupClaudeMd } from "./setup-claude-md.mjs";

export async function runPostInstall({ CWD, selectedSkills, selectedCommands }) {
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

      // In auto mode the classifier denies the gate's ack, and it only reads
      // autoMode.allow from the user's own ~/.claude/settings.json. Without this
      // the gate cannot be satisfied at all, and the session cannot fix it
      // either — an agent editing permission settings is denied by the same
      // classifier. The installer is the only thing here running as the user.
      const autoModeStatus = await autoModeRuleStatus();
      if (autoModeStatus === "unreadable") {
        console.log();
        console.log(`  ${chalk.yellow("!")} ${chalk.dim("~/.claude/settings.json is not valid JSON — skipping the auto mode rule.")}`);
      } else if (autoModeStatus !== "current") {
        console.log();
        console.log(chalk.dim("  Auto mode's classifier denies the gate's acknowledgement files, and"));
        console.log(chalk.dim("  clearing that needs a rule in your own ~/.claude/settings.json. Claude"));
        console.log(chalk.dim("  cannot add it — editing permission settings is denied to agents too."));
        const addRule = await confirm({
          message:
            autoModeStatus === "stale"
              ? "Update the auto mode allow rule in ~/.claude/settings.json? (Recommended)"
              : "Add an auto mode allow rule to ~/.claude/settings.json? (Recommended)",
          default: true,
        });
        if (addRule) {
          try {
            const written = await writeAutoModeRule();
            console.log(`  Settings updated: ${written}`);
          } catch (err) {
            console.log(`  ${chalk.yellow("!")} ${chalk.dim(err.message)}`);
          }
        } else {
          console.log(`  ${chalk.dim("Skipped. In auto mode the gate will block until you add it via /permissions.")}`);
        }
      }

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
          const apiInstalls = [];
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
            if (n.ignorerOnly) {
              apiInstalls.push(r.apiInstall);
            } else {
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
          if (apiInstalls.length > 0) {
            console.log(`\n  ${chalk.yellow("!")} ${chalk.bold("The ignorer needs its own dependency:")}`);
            for (const c of apiInstalls) console.log(`      ${chalk.cyan(c)}`);
            console.log(`      ${chalk.dim("without it the ignorer silently does not load")}`);
          }
        }
      }
    }
  }

}
