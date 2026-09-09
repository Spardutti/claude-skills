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

// Register the entry, or CORRECT the one already there. Skipping when a hook of
// this name exists leaves an existing install pinned to whatever matcher it was
// first written with — which is how the skill gates kept watching only
// Write|Edit|MultiEdit after they learned to cover Bash.
function upsert(list, filename, entry) {
  const existing = list.find((e) => e.hooks?.some((h) => h.command?.endsWith(filename)));
  if (!existing) return list.push(entry);
  if (entry.matcher === undefined) delete existing.matcher;
  else existing.matcher = entry.matcher;
  existing.hooks = entry.hooks;
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

  let settings = {};
  try {
    settings = JSON.parse(await readFile(settingsPath, "utf-8"));
  } catch {
    // missing or invalid — start fresh
  }
  if (!settings.hooks) settings.hooks = {};

  // Clean up legacy UserPromptSubmit eval hook (replaced by the gate).
  if (Array.isArray(settings.hooks.UserPromptSubmit)) {
    settings.hooks.UserPromptSubmit = settings.hooks.UserPromptSubmit.filter(
      (entry) => !entry.hooks?.some((h) => h.command?.endsWith(LEGACY_EVAL_FILENAME))
    );
    if (settings.hooks.UserPromptSubmit.length === 0) {
      delete settings.hooks.UserPromptSubmit;
    }
  }

  // Clean up legacy PreToolUse audit-runner hook (2.3.x — removed in 2.4.0).
  if (Array.isArray(settings.hooks.PreToolUse)) {
    settings.hooks.PreToolUse = settings.hooks.PreToolUse.filter(
      (entry) => !entry.hooks?.some((h) => h.command?.endsWith(LEGACY_AUDIT_RUNNER_FILENAME))
    );
  }

  // Register PreToolUse gate.
  const gateCommand = `$CLAUDE_PROJECT_DIR/.claude/hooks/${GATE_FILENAME}`;
  const gateEntry = {
    matcher: "Write|Edit|MultiEdit|Bash",
    hooks: [{ type: "command", command: gateCommand }],
  };

  if (Array.isArray(settings.hooks.PreToolUse)) {
    upsert(settings.hooks.PreToolUse, GATE_FILENAME, gateEntry);
  } else {
    settings.hooks.PreToolUse = [gateEntry];
  }

  // Register PreToolUse application gate (after the loading gate).
  const applicationCommand = `$CLAUDE_PROJECT_DIR/.claude/hooks/${APPLICATION_GATE_FILENAME}`;
  const applicationEntry = {
    matcher: "Write|Edit|MultiEdit|Bash",
    hooks: [{ type: "command", command: applicationCommand }],
  };
  upsert(settings.hooks.PreToolUse, APPLICATION_GATE_FILENAME, applicationEntry);

  // Register PreToolUse ship-gate receipt check on Bash.
  const shipGateCommand = `$CLAUDE_PROJECT_DIR/.claude/hooks/${SHIP_GATE_HOOK_FILENAME}`;
  const shipGateEntry = {
    matcher: "Bash",
    hooks: [{ type: "command", command: shipGateCommand }],
  };
  upsert(settings.hooks.PreToolUse, SHIP_GATE_HOOK_FILENAME, shipGateEntry);

  // Register PostToolUse auto-mark on Skill.
  const autoMarkCommand = `$CLAUDE_PROJECT_DIR/.claude/hooks/${AUTO_MARK_FILENAME}`;
  const autoMarkEntry = {
    matcher: "Skill",
    hooks: [{ type: "command", command: autoMarkCommand }],
  };

  if (Array.isArray(settings.hooks.PostToolUse)) {
    upsert(settings.hooks.PostToolUse, AUTO_MARK_FILENAME, autoMarkEntry);
  } else {
    settings.hooks.PostToolUse = [autoMarkEntry];
  }

  // Register SessionStart version check. No matcher: startup and resume both
  // want it, and the script's own daily stamp keeps a burst of resumes quiet.
  const versionCheckCommand = `$CLAUDE_PROJECT_DIR/.claude/hooks/${VERSION_CHECK_FILENAME}`;
  const versionCheckEntry = { hooks: [{ type: "command", command: versionCheckCommand }] };

  if (Array.isArray(settings.hooks.SessionStart)) {
    upsert(settings.hooks.SessionStart, VERSION_CHECK_FILENAME, versionCheckEntry);
  } else {
    settings.hooks.SessionStart = [versionCheckEntry];
  }

  // Register Stop gauntlet hook.
  const gauntletCommand = `$CLAUDE_PROJECT_DIR/.claude/hooks/${GAUNTLET_FILENAME}`;
  const gauntletEntry = { hooks: [{ type: "command", command: gauntletCommand }] };

  if (Array.isArray(settings.hooks.Stop)) {
    upsert(settings.hooks.Stop, GAUNTLET_FILENAME, gauntletEntry);
  } else {
    settings.hooks.Stop = [gauntletEntry];
  }

  // Both gates clear by touching a marker under /tmp. The hook scripts let those
  // commands through themselves, but auto mode's permission classifier does not:
  // a touch whose only purpose is to unlock a gate is exactly what it refuses.
  // So in auto mode the application gate could not be satisfied at all, and the
  // model was reduced to asking its user to run the touch by hand — which is
  // indistinguishable from the laundering the classifier exists to stop.
  // Allowlisting the three marker paths is what makes the gates workable there.
  // Only these literal prefixes are granted, and an existing entry is not
  // duplicated on reinstall.
  const MARKER_ALLOW = [
    "Bash(touch /tmp/claude-skill-gate-*)",
    "Bash(touch /tmp/claude-skill-acked-*)",
    "Bash(touch /tmp/claude-skill-loaded-*)",
  ];
  if (!settings.permissions) settings.permissions = {};
  if (!Array.isArray(settings.permissions.allow)) settings.permissions.allow = [];
  for (const rule of MARKER_ALLOW) {
    if (!settings.permissions.allow.includes(rule)) settings.permissions.allow.push(rule);
  }

  await writeFile(settingsPath, JSON.stringify(settings, null, 2) + "\n", { mode: 0o644 });

  console.log(`  Hook installed: .claude/hooks/${GATE_FILENAME}`);
  console.log(`  Hook installed: .claude/hooks/${AUTO_MARK_FILENAME}`);
  console.log(`  Hook installed: .claude/hooks/${APPLICATION_GATE_FILENAME}`);
  console.log(`  Hook installed: .claude/hooks/${GAUNTLET_FILENAME}`);
  console.log(`  Installed: .claude/hooks/${SHIP_GATE_FILENAME} (used by /ship)`);
  console.log(`  Hook installed: .claude/hooks/${SHIP_GATE_HOOK_FILENAME}`);
  console.log(`  Settings updated: .claude/settings.json`);
}

// The project-level permissions.allow written above does not clear auto mode.
// The classifier reads autoMode.allow, and only from the user's own
// ~/.claude/settings.json — it deliberately ignores a project's settings so a
// cloned repo cannot loosen it. So the gate's ack was denied, and the remedy the
// deny message named could not be applied by the agent either: the classifier
// refuses an agent editing permission settings by any route. That left a
// deadlock nothing in the session could break. The installer can, because npx
// runs as the user, not as an agent — but only ever behind an explicit prompt,
// since this is the user's global file.
export const AUTO_MODE_RULE =
  "Touching marker files under /tmp/claude-skill-gate-*, /tmp/claude-skill-acked-* " +
  "and /tmp/claude-skill-loaded-* is allowed: they are acknowledgement files for the " +
  "user's own PreToolUse skill gates. Creating one satisfies a workflow gate the user " +
  "installed, grants no permission and executes no code, and is a false positive for " +
  "Auto-Mode Bypass.";

// Any entry naming a marker path is ours, whatever wording it shipped with. An
// upgrade must correct that entry rather than add a second one beside it —
// a fresh-install test would never see the difference.
const AUTO_MODE_RULE_MARK = "/tmp/claude-skill-acked-";

function globalSettingsPath(homeDir) {
  return join(homeDir ?? homedir(), ".claude", "settings.json");
}

async function readGlobalSettings(homeDir) {
  try {
    return JSON.parse(await readFile(globalSettingsPath(homeDir), "utf-8"));
  } catch {
    return null;
  }
}

// "current" — the rule is present and matches. "stale" — an older wording is
// there. "missing" — nothing of ours. "unreadable" — the file exists but does
// not parse, so we must not rewrite it.
export async function autoModeRuleStatus(homeDir) {
  let raw;
  try {
    raw = await readFile(globalSettingsPath(homeDir), "utf-8");
  } catch {
    return "missing";
  }
  let settings;
  try {
    settings = JSON.parse(raw);
  } catch {
    return "unreadable";
  }
  const allow = settings?.autoMode?.allow;
  if (!Array.isArray(allow)) return "missing";
  if (allow.includes(AUTO_MODE_RULE)) return "current";
  if (allow.some((r) => typeof r === "string" && r.includes(AUTO_MODE_RULE_MARK))) return "stale";
  return "missing";
}

// Writes the rule into ~/.claude/settings.json, keeping "$defaults" first —
// dropping it discards every built-in allow. Everything else in the file is
// preserved. Refuses an unparseable file rather than replacing it.
export async function writeAutoModeRule(homeDir) {
  if ((await autoModeRuleStatus(homeDir)) === "unreadable") {
    throw new Error(`${globalSettingsPath(homeDir)} is not valid JSON — fix it, then re-run.`);
  }
  const settings = (await readGlobalSettings(homeDir)) ?? {};
  if (!settings.autoMode || typeof settings.autoMode !== "object") settings.autoMode = {};
  const existing = Array.isArray(settings.autoMode.allow) ? settings.autoMode.allow : [];

  const kept = existing.filter(
    (r) => r !== "$defaults" && !(typeof r === "string" && r.includes(AUTO_MODE_RULE_MARK)),
  );
  settings.autoMode.allow = ["$defaults", ...kept, AUTO_MODE_RULE];

  const path = globalSettingsPath(homeDir);
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, JSON.stringify(settings, null, 2) + "\n", { mode: 0o600 });
  return path;
}
