#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { appendFileSync, existsSync, realpathSync } from "node:fs";
import { relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { brokenRules, loadEditRules, projectFiles, textFindings } from "./text-rules.mjs";
import { mergeBaseline, readBaseline, writeBaseline } from "./ratchet-baseline.mjs";

const ROOT = realpathSync(process.cwd());
const BASELINE = resolve(ROOT, ".lint-baseline");
const ESLINT = resolve(ROOT, "node_modules/.bin/eslint");
const SELF = relative(ROOT, fileURLToPath(import.meta.url));
let TEXT = [];
let LESSONS = [];

const isTest = (f) => /\.(test|spec)\.|(^|\/)(test|tests|__tests__)\//.test(f);

// A test's describe() callback is one long function by design, and React
// components are left unannotated by convention, so each rule names its files.
const RULES = [
  {
    id: "max-lines-per-function",
    skill: "code-structure",
    config: ["error", { max: 30, skipBlankLines: true, skipComments: true }],
    applies: (f) => /\.(m?js|jsx|ts|tsx)$/.test(f) && !isTest(f),
  },
  {
    id: "@typescript-eslint/explicit-module-boundary-types",
    skill: "typescript-best-practices",
    config: "error",
    applies: (f) => /\.ts$/.test(f) && !isTest(f),
  },
];

// skills/ is where this repo keeps the skills it ships; a consumer has them under .claude/skills/.
const hasSkill = (name) =>
  existsSync(resolve(ROOT, ".claude/skills", name, "SKILL.md")) || existsSync(resolve(ROOT, "skills", name, "SKILL.md"));
const LINT = RULES.filter((r) => hasSkill(r.skill));

// A plugin rule the project's config cannot load makes ESLint crash, so retry without it.
function eslint(rules, target) {
  const results = eslintOnce(rules, target);
  const core = rules.filter((r) => !r.id.includes("/"));
  if (results || core.length === rules.length) return { results, ran: rules };
  return { results: core.length ? eslintOnce(core, target) : [], ran: core };
}

function eslintOnce(rules, target) {
  const args = ["-f", "json"];
  for (const r of rules) args.push("--rule", JSON.stringify({ [r.id]: r.config }));
  args.push(target);
  const run = spawnSync(ESLINT, args, { cwd: ROOT, encoding: "utf8", maxBuffer: 1 << 28 });
  try {
    return JSON.parse(run.stdout);
  } catch {
    return null;
  }
}

function eslintFindings(results) {
  const out = [];
  for (const file of results) {
    const rel = relative(ROOT, file.filePath);
    for (const m of file.messages) {
      const rule = RULES.find((r) => r.id === m.ruleId);
      if (rule && rule.applies(rel)) out.push({ rel, rule: m.ruleId, line: m.line, message: m.message });
    }
  }
  return out;
}

function countBy(list) {
  const counts = new Map();
  for (const f of list) {
    const key = `${f.rule} ${f.rel}`;
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  return counts;
}

function baseline(only, newOnly) {
  const was = readBaseline(BASELINE);
  const pick = (r) => (only ? r.id === only : !newOnly || !was.rules.has(r.id));
  const lint = existsSync(ESLINT) ? LINT.filter(pick) : [];
  const text = TEXT.filter(pick);
  if (newOnly && was.exists && lint.length + text.length === 0) return 0;
  if (newOnly) console.log(`  Recording old code as baseline debt for: ${[...lint, ...text].map((r) => r.id).join(" ")}`);
  const { results, ran } = lint.length ? eslint(lint, ".") : { results: [], ran: [] };
  if (!results) {
    console.error("lint-ratchet: eslint gave no JSON; baseline not written.");
    return 1;
  }
  const cannot = lint.filter((r) => !ran.includes(r)).map((r) => r.id);
  if (cannot.length) console.log(`lint-ratchet: ESLint could not run ${cannot.join(" ")}; its plugin is not in the ESLint config.`);
  if (newOnly && was.exists && ran.length + text.length === 0) return 0;
  const found = [...eslintFindings(results), ...projectFiles(ROOT).flatMap((rel) => textFindings(text, ROOT, rel))];
  const judged = new Set([...ran, ...text].map((r) => r.id));
  const n = writeBaseline(BASELINE, mergeBaseline(was, countBy(found), judged), new Set([...was.rules, ...judged]));
  console.log(`lint-ratchet: baseline written — ${n} rule/file pair(s) accepted as debt.`);
  return 0;
}

function scan(rel) {
  const lint = existsSync(ESLINT) ? LINT.filter((r) => r.applies(rel)) : [];
  const { results, ran } = lint.length ? eslint(lint, rel) : { results: null, ran: [] };
  const text = TEXT.filter((r) => r.applies(rel));
  return {
    rules: [...(results ? ran : []), ...text],
    found: [...(results ? eslintFindings(results) : []), ...textFindings(text, ROOT, rel)],
  };
}

function checkFile(path) {
  const abs = resolve(ROOT, path);
  const rel = relative(ROOT, existsSync(abs) ? realpathSync(abs) : abs);
  if (rel.startsWith("..") || spawnSync("git", ["check-ignore", "-q", "--", rel], { cwd: ROOT }).status === 0) return 0;
  const { rules, found } = scan(rel);
  const was = readBaseline(BASELINE);
  let failed = 0;
  for (const rule of rules) {
    const hits = found.filter((f) => f.rule === rule.id);
    const before = was.counts.get(`${rule.id} ${rel}`) ?? 0;
    if (hits.length > before && !was.rules.has(rule.id)) {
      console.log(`NOTE — ${rule.id} has no baseline yet, so its ${hits.length} finding(s) in ${rel} do not block. Run node ${SELF} --baseline-new to record old code.`);
    } else if (hits.length > before) {
      failed = 1;
      if (process.env.LINT_RATCHET_BLOCKED) appendFileSync(process.env.LINT_RATCHET_BLOCKED, `${rule.id}\n`);
      console.log(`LINT — ${rel}: ${hits.length} × ${rule.id}, was ${before}. Fix the new one(s):`);
      for (const h of hits) console.log(`  ${rel}:${h.line}  ${h.message}`);
    } else if (hits.length > 0) {
      console.log(`NOTE — ${rel} has ${hits.length} old ${rule.id} finding(s). Fix them if this change allows.`);
    } else if (before > 0) {
      console.log(`NOTE — ${rel}: ${rule.id} debt paid down. Run node ${SELF} --baseline ${rule.id} to bank it.`);
    }
  }
  for (const lesson of LESSONS.filter((l) => l.applies(rel))) console.log(`LESSON — ${lesson.message}`);
  return failed;
}

function selftest() {
  const broken = brokenRules(TEXT);
  for (const b of broken) console.log(`RULE — ${b}`);
  if (broken.length === 0) console.log(`lint-ratchet: ${TEXT.length} text rule(s) catch their bad example and pass their good one.`);
  return broken.length ? 1 : 0;
}

function main(mode, arg) {
  ({ text: TEXT, lessons: LESSONS } = loadEditRules(ROOT));
  if (mode === "--baseline") return baseline(arg, false);
  if (mode === "--baseline-new") return baseline(undefined, true);
  if (mode === "--file") return checkFile(arg ?? "");
  if (mode === "--selftest") return selftest();
  console.error("usage: lint-ratchet.mjs --baseline [rule-id] | --baseline-new | --file <path> | --selftest");
  return 1;
}

const [mode, arg] = process.argv.slice(2);
try {
  process.exit(main(mode, arg));
} catch (err) {
  console.log(`NOTE — .edit-rules.json could not be used, so its rules did not run: ${err.message}`);
  process.exit(mode === "--file" ? 0 : 1);
}
