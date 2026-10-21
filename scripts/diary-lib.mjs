import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

// Asks gate-config.sh's diary_dir, so the hooks that write the diaries and the scripts that
// read them share one rule. argv[1] keeps a symlinked path the way bash sees it.
export function claudeDir() {
  const here = dirname(resolve(process.argv[1]));
  const run = spawnSync("bash", ["-c", '. "$1/gate-config.sh" && diary_dir "$1"', "_", here], { encoding: "utf8" });
  return run.stdout?.trim() || resolve(process.env.CLAUDE_PROJECT_DIR || process.cwd(), ".claude");
}

export function readLines(path) {
  try {
    return readFileSync(path, "utf-8").split("\n").filter(Boolean);
  } catch {
    return [];
  }
}

export function parseLine(line) {
  try {
    return JSON.parse(line);
  } catch {
    return null;
  }
}

export function verdictOf(reply) {
  try {
    return JSON.parse(reply.slice(reply.indexOf("{"), reply.lastIndexOf("}") + 1));
  } catch {
    return null;
  }
}

export function parseVerdict(line) {
  const entry = parseLine(line);
  const verdict = entry && verdictOf(entry.reply ?? "");
  return verdict ? { model: entry.model, verdict } : null;
}
