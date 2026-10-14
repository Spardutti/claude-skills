#!/usr/bin/env node
// Prints, per skill, how often the /ship skills audit applied it and flagged a violation.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const DEFAULT_LOG = fileURLToPath(new URL("../skill-flags.jsonl", import.meta.url));

function parseVerdict(line) {
  try {
    const { model, reply } = JSON.parse(line);
    return { model, verdict: JSON.parse(reply.slice(reply.indexOf("{"), reply.lastIndexOf("}") + 1)) };
  } catch {
    return null;
  }
}

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

let text = "";
try {
  text = readFileSync(process.argv[2] ?? DEFAULT_LOG, "utf-8");
} catch {
  // no log yet
}
console.log(render(tally(text.split("\n").filter(Boolean))));
