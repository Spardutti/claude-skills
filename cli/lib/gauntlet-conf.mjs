import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { input } from "@inquirer/prompts";

// The third column is an example, for settings the hook leaves unset by default.
const SETTINGS = [
  ["GAUNTLET_MAX_LINES", "max lines per file; 0 turns the check off"],
  ["GAUNTLET_KIND_FOLDERS", "the folders a feature may hold, split by |"],
  ["GAUNTLET_TEST", "the test command; set, it replaces detection", "npm test"],
  ["GAUNTLET_TYPECHECK", "the typecheck command; '' turns it off", "npx tsc --noEmit"],
  ["GAUNTLET_BASE", "the trunk branch, tried before develop, dev and main", "staging"],
  ["GAUNTLET_IGNORE_FILES", "globs never checked for length or mutated"],
  ["GAUNTLET_NO_MUTATE", "a regex of files checked for length but not mutated"],
  ["GAUNTLET_SLOW", "warn when a run takes this many seconds", "30"],
  ["GAUNTLET_REQUIRE_TESTS", "1 blocks when a runner matched 0 test files", "1"],
  ["GAUNTLET_SHIP_LOG", "1 keeps a log of every /ship", "1"],
  ["GAUNTLET_OFF", "1 turns every hook off in this project", "1"],
];

// The hook's own defaults, so the installer never keeps a second copy of them.
export function readDefaults(hooksDir) {
  const names = SETTINGS.map(([n]) => n).join(" ");
  const script = `. "$1/gate-config.sh" && for n in ${names}; do [ -n "\${!n+x}" ] && printf '%s=%s\\0' "$n" "\${!n}"; done`;
  const out = spawnSync("bash", ["-c", script, "_", hooksDir], { encoding: "utf8" }).stdout ?? "";
  return Object.fromEntries(out.split("\0").filter(Boolean).map((kv) => [kv.slice(0, kv.indexOf("=")), kv.slice(kv.indexOf("=") + 1)]));
}

const quote = (v) => `'${String(v).replace(/'/g, "'\\''")}'`;

export function buildConf(defaults, chosen) {
  const lines = ["# Gauntlet config. Read after ~/.claude/gauntlet.conf, and wins over it.", ""];
  for (const [name, what, example] of SETTINGS) {
    lines.push(`# ${what}`);
    const value = chosen[name];
    const changed = value !== undefined && value !== defaults[name];
    lines.push(changed ? `${name}=${quote(value)}` : `# ${name}=${quote(defaults[name] || example || "")}`);
  }
  return `${lines.join("\n")}\n`;
}

export async function writeGauntletConf(targetDir, defaults, chosen) {
  const confPath = join(resolve(targetDir), ".claude", "gauntlet.conf");
  if (existsSync(confPath)) return null;
  await mkdir(dirname(confPath), { recursive: true });
  await writeFile(confPath, buildConf(defaults, chosen), { mode: 0o644 });
  return confPath;
}

export const toKindFolders = (answer) => answer.split(/[\s,|]+/).filter(Boolean).join("|");

export async function askGauntletConf(defaults, needsTest) {
  const chosen = {};
  chosen.GAUNTLET_MAX_LINES = (await input({
    message: "Max lines per file (0 = off):",
    default: defaults.GAUNTLET_MAX_LINES,
    validate: (v) => /^\d+$/.test(v.trim()) || "A whole number, 0 or more",
  })).trim();
  chosen.GAUNTLET_KIND_FOLDERS = toKindFolders(await input({
    message: "Folders a feature may hold (comma-separated):",
    default: defaults.GAUNTLET_KIND_FOLDERS.split("|").join(", "),
    validate: (v) => /^[\w.-]+([\s,|]+[\w.-]+)*$/.test(v.trim()) || "Folder names split by commas",
  }));
  if (needsTest) {
    const cmd = (await input({ message: "Test command (empty to skip):" })).trim();
    if (cmd) Object.assign(chosen, { GAUNTLET_TEST: cmd, GAUNTLET_TYPECHECK: "" });
  }
  return chosen;
}
