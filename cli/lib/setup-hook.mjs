import { registerHooks } from "./hook-settings.mjs";
import { mkdir, writeFile, readFile, chmod, unlink } from "node:fs/promises";
import { join, resolve, dirname } from "node:path";
import { spawn } from "node:child_process";
import { homedir } from "node:os";

// Installs the hook scripts and registers them in .claude/settings.json.
//
// The scripts themselves live in scripts/ at the repo root and are read from
// disk, never pasted in here. What each one does is documented at the top of
// its own file:
//
//   skill-gate.sh             PreToolUse — blocks edits until the skills the
//                             edited file's stack demands are loaded
//   skill-gate-automark.sh    PostToolUse on Skill — records what was loaded
//   skill-application-gate.sh PreToolUse — requires each loaded skill to be
//                             explicitly applied before the first edit
//   gauntlet.sh               Stop — fast typecheck and tests on the diff
//   ship-gate.sh              file length and mutation, behind an exit code
//   ship-gate-hook.sh         PreToolUse on Bash — no commit without a receipt
//   version-check.sh          SessionStart — a line when a newer catalog exists

const GATE_FILENAME = "skill-gate.sh";
const AUTO_MARK_FILENAME = "skill-gate-automark.sh";
const APPLICATION_GATE_FILENAME = "skill-application-gate.sh";
const GAUNTLET_FILENAME = "gauntlet.sh";
const SHIP_GATE_FILENAME = "ship-gate.sh";
const SHIP_GATE_HOOK_FILENAME = "ship-gate-hook.sh";
const VERSION_CHECK_FILENAME = "version-check.sh";
const LEGACY_EVAL_FILENAME = "skill-forced-eval-hook.sh";
const LEGACY_AUDIT_RUNNER_FILENAME = "skill-audit-runner.sh";

// The hook scripts used to live here as template literals — a second copy of
// every file in scripts/, which is why preflight needed a step to check the two
// had not drifted, why editing a hook meant escaping backslashes, backticks and
// ${, and why this file was 1740 lines. They are read from disk now, so there
// is one copy and nothing to drift.
//
// Two locations, because there are two ways this runs. `npm pack` copies
// scripts/*.sh into cli/hooks/ (see the prepack script), so the published
// package has them beside lib/. Running from a clone has no cli/hooks/, and
// falls back to the repo's scripts/ — which is the same file the self-tests and
// preflight read, so a test cannot pass against a copy the package would not
// ship.
async function readHookSource(name) {
  const packaged = new URL(`../hooks/${name}`, import.meta.url);
  try {
    return await readFile(packaged, "utf-8");
  } catch {
    return await readFile(new URL(`../../scripts/${name}`, import.meta.url), "utf-8");
  }
}

// Asks the installed hook what it would run, rather than reimplementing its
// detection here. A second copy drifts: the JS one reported "no test runner"
// for repos the shell script had already learned to handle.
export async function detectStack(targetDir = process.cwd()) {
  const dir = resolve(targetDir);
  const hook = join(dir, ".claude", "hooks", GAUNTLET_FILENAME);
  return new Promise((done) => {
    const child = spawn("bash", [hook], {
      cwd: dir,
      env: { ...process.env, CLAUDE_PROJECT_DIR: dir, GAUNTLET_DEBUG: "1", GAUNTLET_DRYRUN: "1" },
    });
    let err = "";
    child.stderr.on("data", (c) => { err += c; });
    child.on("error", () => done(null));
    child.on("close", () => {
      const line = err.split("\n").find((l) => l.startsWith("gauntlet: would run:"));
      if (!line) return done(null);
      const gates = line.slice("gauntlet: would run:".length).trim();
      done(gates && !gates.startsWith("nothing") ? gates : null);
    });
    child.stdin.end('{"session_id":"install"}');
  });
}

// Written only when detection finds nothing — otherwise the hook auto-detects and
// no config file is needed.
export async function writeGauntletConf(targetDir, testCommand) {
  const confPath = join(resolve(targetDir), ".claude", "gauntlet.conf");
  await mkdir(dirname(confPath), { recursive: true });
  await writeFile(confPath, [
    "# Gauntlet config. Read after ~/.claude/gauntlet.conf, and wins over it.",
    "# GAUNTLET_OFF=1 disables the hook in this project.",
    "",
    "GAUNTLET_TYPECHECK=''",
    `GAUNTLET_TEST='${testCommand.replace(/'/g, "'\\''")}'`,
    "",
  ].join("\n"), { mode: 0o644 });
  return confPath;
}

export async function setupHook(targetDir = process.cwd()) {
  const resolved = resolve(targetDir);
  const hooksDir = join(resolved, ".claude", "hooks");
  const settingsPath = join(resolved, ".claude", "settings.json");

  await mkdir(hooksDir, { recursive: true });
  for (const name of [
    GATE_FILENAME,
    AUTO_MARK_FILENAME,
    APPLICATION_GATE_FILENAME,
    GAUNTLET_FILENAME,
    SHIP_GATE_FILENAME,
    SHIP_GATE_HOOK_FILENAME,
    VERSION_CHECK_FILENAME,
  ]) {
    const dest = join(hooksDir, name);
    await writeFile(dest, await readHookSource(name), { mode: 0o755 });
    await chmod(dest, 0o755);
  }

  // Remove the legacy audit-runner hook file from prior installs (2.3.x).
  try {
    await unlink(join(hooksDir, LEGACY_AUDIT_RUNNER_FILENAME));
  } catch {
    // not present — fine
  }

  await registerHooks(settingsPath);

  console.log(`  Hook installed: .claude/hooks/${GATE_FILENAME}`);
  console.log(`  Hook installed: .claude/hooks/${AUTO_MARK_FILENAME}`);
  console.log(`  Hook installed: .claude/hooks/${APPLICATION_GATE_FILENAME}`);
  console.log(`  Hook installed: .claude/hooks/${GAUNTLET_FILENAME}`);
  console.log(`  Installed: .claude/hooks/${SHIP_GATE_FILENAME} (used by /ship)`);
  console.log(`  Hook installed: .claude/hooks/${SHIP_GATE_HOOK_FILENAME}`);
  console.log(`  Settings updated: .claude/settings.json`);
}