// The permissions rule that lets the skill gates clear themselves under auto
// mode. Separate from installing the hooks: this writes the USER's global
// settings, that writes a project's, and only one of them can be done for you.
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { join, dirname } from "node:path";
import { homedir } from "node:os";


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
