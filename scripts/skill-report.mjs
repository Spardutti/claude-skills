#!/usr/bin/env node
import { readdirSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { claudeDir, parseLine, parseVerdict, readLines } from "./diary-lib.mjs";

const given = process.argv[2] && resolve(process.argv[2]);
const DIR = !given ? claudeDir() : statSync(given, { throwIfNoEntry: false })?.isFile() ? dirname(given) : given;

function tally(lines) {
  const skills = new Map();
  const models = new Map();
  let unreadable = 0;
  for (const line of lines) {
    const parsed = parseVerdict(line);
    if (!parsed?.verdict?.skill) { unreadable++; continue; }
    const { model, verdict } = parsed;
    if (!(verdict.checked > 0)) continue;
    const s = skills.get(verdict.skill) ?? { audits: 0, flagged: 0, rules: new Map() };
    s.audits++;
    const violations = Array.isArray(verdict.violations) ? verdict.violations : [];
    if (violations.length) s.flagged++;
    for (const v of violations) s.rules.set(v.rule, (s.rules.get(v.rule) ?? 0) + 1);
    skills.set(verdict.skill, s);
    if (model) models.set(model, (models.get(model) ?? 0) + 1);
  }
  return { skills, models, unreadable };
}

function topRule(rules) {
  const [rule] = [...rules].sort((a, b) => b[1] - a[1])[0] ?? ["-"];
  return rule.length > 60 ? rule.slice(0, 57) + "..." : rule;
}

function render({ skills, models, unreadable }) {
  if (!skills.size) return "No skill audits recorded yet. Run /ship to record some.";
  const rows = [...skills].sort((a, b) => b[1].flagged - a[1].flagged || a[0].localeCompare(b[0]));
  const width = Math.max(5, ...rows.map(([name]) => name.length));
  const out = [`${"skill".padEnd(width)}  audits  flagged  top rule broken`];
  for (const [name, s] of rows) {
    out.push(`${name.padEnd(width)}  ${String(s.audits).padStart(6)}  ${String(s.flagged).padStart(7)}  ${topRule(s.rules)}`);
  }
  if (models.size) out.push("", "models: " + [...models].map(([m, n]) => `${m} (${n})`).join(", "));
  if (unreadable) out.push(`unreadable lines: ${unreadable}`);
  return out.join("\n");
}

function tallyBlocks(lines) {
  const rules = new Map();
  for (const line of lines) {
    const entry = parseLine(line);
    const ids = Array.isArray(entry?.rules) ? entry.rules : (entry?.rules ?? "").split(" ").filter(Boolean);
    for (const id of ids) {
      const r = rules.get(id) ?? { count: 0, branches: new Set() };
      r.count += 1;
      if (entry.branch) r.branches.add(entry.branch);
      rules.set(id, r);
    }
  }
  return rules;
}

function renderBlocks(rules) {
  if (rules.size === 0) return "";
  const rows = [...rules].sort((a, b) => b[1].branches.size - a[1].branches.size || b[1].count - a[1].count);
  const width = Math.max(22, ...rows.map(([id]) => id.length));
  const line = ([id, r]) => `${id.padEnd(width)}  ${String(r.count).padStart(5)}  ${String(r.branches.size).padStart(8)}`;
  return ["", `${"edit-hook blocks".padEnd(width)}  count  branches`, ...rows.map(line)].join("\n");
}

// The session file format is undocumented: a load we cannot measure cleanly counts, but gets no number.
const contextSize = (u) => u ? u.input_tokens + u.cache_read_input_tokens + u.cache_creation_input_tokens : NaN;

function sessionRows(file) {
  return readLines(file).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter((r) => r?.type === "assistant" && r.message?.id);
}

function measureLoads(rows, costs) {
  const calls = new Map();
  for (const r of rows) calls.set(r.message.id, [...(calls.get(r.message.id) ?? []), r]);
  const ids = [...calls.keys()];
  ids.forEach((id, i) => {
    const uses = calls.get(id).flatMap((r) => r.message.content ?? []).filter((c) => c.type === "tool_use");
    const before = calls.get(id)[0].message.usage;
    const delta = contextSize(calls.get(ids[i + 1])?.[0].message.usage) - contextSize(before) - before?.output_tokens;
    for (const use of uses.filter((u) => u.name === "Skill" && u.input?.skill)) {
      const c = costs.get(use.input.skill) ?? { loads: 0, tokens: [] };
      c.loads++;
      costs.set(use.input.skill, c);
      if (uses.length === 1 && delta > 0) c.tokens.push(delta);
    }
  });
}

function tallyCosts(projectDir) {
  const dir = join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), ".claude"), "projects", projectDir.replace(/[^a-zA-Z0-9]/g, "-"));
  const costs = new Map();
  let files = [];
  try { files = readdirSync(dir).filter((f) => f.endsWith(".jsonl")); } catch {}
  for (const f of files) if (readFileSync(join(dir, f), "utf8").includes('"name":"Skill"')) measureLoads(sessionRows(join(dir, f)), costs);
  return costs;
}

function median(xs) {
  const s = [...xs].sort((a, b) => a - b);
  return s.length ? Math.round(s.length % 2 ? s[(s.length - 1) / 2] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2) : null;
}

function renderCosts(costs) {
  if (costs.size === 0) return "";
  const rows = [...costs].map(([name, c]) => [name, c.loads, c.tokens.length, median(c.tokens)]).sort((a, b) => (b[3] ?? -1) - (a[3] ?? -1) || a[0].localeCompare(b[0]));
  const width = Math.max(15, ...rows.map(([name]) => name.length));
  const line = ([name, loads, measured, tokens]) => `${name.padEnd(width)}  ${String(loads).padStart(5)}  ${String(measured).padStart(8)}  ${String(tokens ?? "-").padStart(13)}`;
  return ["", `${"skill load cost".padEnd(width)}  loads  measured  median tokens`, ...rows.map(line)].join("\n");
}

const audits = tally(readLines(resolve(DIR, "skill-flags.jsonl")));
console.log(render(audits) + renderBlocks(tallyBlocks(readLines(resolve(DIR, "edit-blocks.jsonl")))) + renderCosts(tallyCosts(dirname(DIR))));
