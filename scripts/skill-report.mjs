#!/usr/bin/env node
import { statSync } from "node:fs";
import { dirname, resolve } from "node:path";
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

const audits = tally(readLines(resolve(DIR, "skill-flags.jsonl")));
console.log(render(audits) + renderBlocks(tallyBlocks(readLines(resolve(DIR, "edit-blocks.jsonl")))));
