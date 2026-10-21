import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

export function loadEditRules(root) {
  const file = resolve(root, ".edit-rules.json");
  const { text = [], lessons = [] } = existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : {};
  const withFiles = (r) => ({ ...r, applies: (f) => new RegExp(r.files).test(f) });
  return { text: text.map(withFiles), lessons: lessons.map(withFiles) };
}

function matchLines(rule, content) {
  const re = new RegExp(rule.pattern, `g${(rule.flags ?? "").replace("g", "")}`);
  return [...content.matchAll(re)].map((m) => content.slice(0, m.index).split("\n").length);
}

export function textFindings(rules, root, rel) {
  const own = rules.filter((r) => r.applies(rel));
  const path = resolve(root, rel);
  if (own.length === 0 || !existsSync(path)) return [];
  const content = readFileSync(path, "utf8");
  return own.flatMap((r) => matchLines(r, content).map((line) => ({ rel, rule: r.id, line, message: r.message })));
}

export function projectFiles(root) {
  const args = ["ls-files", "--cached", "--others", "--exclude-standard"];
  const run = spawnSync("git", args, { cwd: root, encoding: "utf8", maxBuffer: 1 << 28 });
  return run.status === 0 ? run.stdout.split("\n").filter(Boolean) : walk(root, "");
}

function walk(root, dir) {
  return readdirSync(resolve(root, dir), { withFileTypes: true }).flatMap((e) => {
    if (e.name === "node_modules" || e.name === ".git") return [];
    const rel = dir ? `${dir}/${e.name}` : e.name;
    return e.isDirectory() ? walk(root, rel) : [rel];
  });
}

export function brokenRules(rules) {
  const broken = [];
  for (const r of rules) {
    if (matchLines(r, r.bad ?? "").length === 0) broken.push(`${r.id}: its bad example is not caught`);
    if (matchLines(r, r.good ?? "").length > 0) broken.push(`${r.id}: its good example is flagged`);
  }
  return broken;
}
