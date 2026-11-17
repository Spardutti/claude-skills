import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative, resolve } from "node:path";

const bin = (root, name) => resolve(root, "node_modules/.bin", name);

function runJson(cmd, args, root) {
  const run = spawnSync(cmd, args, { cwd: root, encoding: "utf8", maxBuffer: 1 << 28 });
  try {
    return JSON.parse(run.stdout);
  } catch {
    return null;
  }
}

function eslintOnce(root, rules, target) {
  const args = ["-f", "json"];
  for (const r of rules) args.push("--rule", JSON.stringify({ [r.id]: r.config }));
  const results = runJson(bin(root, "eslint"), [...args, target], root);
  if (!Array.isArray(results)) return null;
  return results.flatMap((file) =>
    file.messages.map((m) => ({ rel: relative(root, file.filePath), rule: m.ruleId, line: m.line, message: m.message })),
  );
}

// A plugin rule the project's config cannot load makes ESLint crash, so retry without it.
function eslint(root, rules, target) {
  const found = eslintOnce(root, rules, target);
  const core = rules.filter((r) => !r.id.includes("/"));
  if (found || core.length === rules.length) return { found, ran: rules };
  return { found: core.length ? eslintOnce(root, core, target) : [], ran: core };
}

const oxlintName = (id) => id.replace(/^@typescript-eslint\//, "typescript/");

// oxlint reports "eslint(max-lines-per-function)" and "typescript(explicit-module-boundary-types)".
function eslintId(code) {
  const [, plugin, rule] = /^([\w-]+)\((.+)\)$/.exec(code) ?? [];
  if (plugin === "eslint") return rule;
  if (plugin === "typescript") return `@typescript-eslint/${rule}`;
  return code;
}

// oxlint takes rule options only from a config file; "correctness" is the category it turns on by default.
function oxlint(root, rules, target) {
  const dir = mkdtempSync(join(tmpdir(), "lint-ratchet-"));
  const config = join(dir, "oxlintrc.json");
  const ruleMap = Object.fromEntries(rules.map((r) => [oxlintName(r.id), r.config]));
  writeFileSync(config, JSON.stringify({ plugins: ["typescript"], categories: { correctness: "off" }, rules: ruleMap }));
  try {
    const out = runJson(bin(root, "oxlint"), ["-c", config, "-f", "json", target], root);
    if (!Array.isArray(out?.diagnostics)) return { found: null, ran: rules };
    const found = out.diagnostics.map((d) => ({
      rel: relative(root, resolve(root, d.filename)),
      rule: eslintId(d.code),
      line: d.labels?.[0]?.span?.line,
      message: d.message,
    }));
    return { found, ran: rules };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

export function pickLinter(root) {
  if (existsSync(bin(root, "oxlint"))) return { name: "oxlint", run: (rules, target) => oxlint(root, rules, target) };
  if (existsSync(bin(root, "eslint"))) return { name: "ESLint", run: (rules, target) => eslint(root, rules, target) };
  return null;
}
