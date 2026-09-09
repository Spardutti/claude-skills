// Registering the hooks in .claude/settings.json — which is a different job
// from writing the hook files, and the one with all the upgrade traps: a hook
// already registered under an old matcher stays on it unless corrected, and a
// legacy entry from an earlier version has to be removed rather than ignored.
import { readFile, writeFile } from "node:fs/promises";

const GATE_FILENAME = "skill-gate.sh";
const AUTO_MARK_FILENAME = "skill-gate-automark.sh";
const APPLICATION_GATE_FILENAME = "skill-application-gate.sh";
const GAUNTLET_FILENAME = "gauntlet.sh";
const SHIP_GATE_FILENAME = "ship-gate.sh";
const SHIP_GATE_HOOK_FILENAME = "ship-gate-hook.sh";
const VERSION_CHECK_FILENAME = "version-check.sh";
const LEGACY_EVAL_FILENAME = "skill-forced-eval-hook.sh";
const LEGACY_AUDIT_RUNNER_FILENAME = "skill-audit-runner.sh";


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

export async function registerHooks(settingsPath) {
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
}
