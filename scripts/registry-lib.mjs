import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";
import { spawnSync } from "node:child_process";

export const REGISTRY_SUFFIX = ".registry.yaml";
const SKIP_DIRS = new Set(["node_modules", ".git", "dist", "build", ".venv", "venv", "__pycache__"]);

export function projectRoot() {
  const dir = process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const top = spawnSync("git", ["-C", dir, "rev-parse", "--show-toplevel"], { encoding: "utf8" });
  return top.status === 0 ? top.stdout.trim() : dir;
}

function walk(dir, root, out) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    if (e.isDirectory() && !SKIP_DIRS.has(e.name)) walk(join(dir, e.name), root, out);
    else if (e.isFile()) out.push(relative(root, join(dir, e.name)));
  }
  return out;
}

export function projectFiles(root) {
  const git = spawnSync("git", ["-C", root, "ls-files", "--cached", "--others", "--exclude-standard"],
    { encoding: "utf8", maxBuffer: 64 << 20 });
  if (git.status !== 0) return walk(root, root, []);
  return git.stdout.split("\n").filter((f) => f && existsSync(join(root, f)));
}

function value(raw) {
  const v = raw.trim();
  if (v.startsWith("[") && v.endsWith("]")) {
    return v.slice(1, -1).split(",").map((s) => s.trim().replace(/^["']|["']$/g, "")).filter(Boolean);
  }
  return v.replace(/^["']|["']$/g, "");
}

export function parseEntry(text) {
  const entry = {};
  for (const line of text.split("\n")) {
    const m = line.match(/^([a-z_]+):\s*(.*?)\s*(?:\s#.*)?$/);
    if (m) entry[m[1]] = value(m[2]);
  }
  for (const key of ["triggers", "does", "allowed", "rules"]) entry[key] = [].concat(entry[key] ?? []).filter(Boolean);
  return entry;
}

export function loadRegistry(root, files) {
  return files
    .filter((f) => f.endsWith(REGISTRY_SUFFIX))
    .sort()
    .map((file) => {
      const text = readFileSync(join(root, file), "utf8");
      return { file, text, ...parseEntry(text) };
    });
}

// Code-shaped words (AimStrategy, pick_target, aimRegistry) or `backticked` — never "implement".
export function symbolsOf(extendBy = "") {
  const ticked = [...extendBy.matchAll(/`([\w.]+)`/g)].map((m) => m[1]);
  const bare = extendBy.replace(/`[^`]*`/g, " ");
  const shaped = bare.match(/\b(?:[A-Z][a-z0-9]+[A-Z]\w*|[a-z]\w*[A-Z]\w*|\w+_\w+)\b/g) ?? [];
  return [...new Set([...ticked, ...shaped])];
}

export function planMarks(planPath) {
  const text = existsSync(planPath) ? readFileSync(planPath, "utf8") : null;
  if (text === null) return null;
  const section = text.split(/^## /m).find((s) => /^Registry\s*$/m.test(s.split("\n")[0])) ?? "";
  const marks = new Map();
  for (const m of section.matchAll(/^[-*]\s*`?([\w.-]+)`?\s*:\s*(reuse|skip)\b/gim)) marks.set(m[1], m[2].toLowerCase());
  return marks;
}

export const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

export function triggerHits(entry, text) {
  return entry.triggers.filter((t) => new RegExp(`\\b${escape(t)}\\b`, "i").test(text));
}

export const locationsOf = (entry) => [].concat(entry.location ?? []).map((l) => l.replace(/^\.\//, "")).filter(Boolean);

// A location is a folder or files, like sim/aim.gd beside unrelated systems in sim/.
export function insideLocation(entry, file) {
  return locationsOf(entry).some((loc) => file === loc || file.startsWith(loc.replace(/\/?$/, "/")));
}

export const isAllowed = (entry, file) => entry.allowed.some((a) => (a.endsWith("/") ? file.startsWith(a) : file === a));

// Only what the stub added: an extended file's old code would trip triggers it never wrote.
export function addedText(root, file) {
  const tracked = spawnSync("git", ["-C", root, "ls-files", "--error-unmatch", file], { encoding: "utf8" });
  if (tracked.status !== 0) return existsSync(join(root, file)) ? readFileSync(join(root, file), "utf8") : "";
  const diff = spawnSync("git", ["-C", root, "diff", "HEAD", "--", file], { encoding: "utf8" }).stdout ?? "";
  return diff.split("\n").filter((l) => l.startsWith("+") && !l.startsWith("+++")).map((l) => l.slice(1)).join("\n");
}
