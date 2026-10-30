#!/usr/bin/env node
import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import {
  REGISTRY_SUFFIX, addedText, escape, insideLocation, isAllowed, loadRegistry, locationsOf, planMarks, projectFiles, projectRoot, symbolsOf, triggerHits,
} from "./registry-lib.mjs";
import { loadEditRules } from "./text-rules.mjs";

const root = projectRoot();
const files = projectFiles(root);
const entries = loadRegistry(root, files);
const uses = (text, word) => new RegExp(`\\b${escape(word)}\\b`).test(text);
// Code calls a method on a value (`e.chill(2)`), so `EnemyState.chill` is the type named plus `.chill` used.
const usesIn = (text, name) => {
  const parts = name.split(".");
  if (parts.length === 1 || uses(text, name)) return uses(text, name);
  return uses(text, parts[0]) && new RegExp(`\\.${escape(parts.at(-1))}\\b`).test(text);
};
const fromCwd = (f) => relative(root, resolve(f));
// `insert(events)` is code, not a word: it may follow a dot, never more letters.
const calls = (text, code) => new RegExp(`${/^\w/.test(code) ? "\\b" : ""}${escape(code)}`).test(text);

function list() {
  if (!entries.length) return console.log(`registry none — no *${REGISTRY_SUFFIX} in this project`);
  for (const e of entries) console.log(`== ${e.file} ==\n${e.text.trim()}\n`);
  stale();
}

function checkPlan(planPath, stubs) {
  if (!entries.length) return console.log("registry ok — no entries");
  const marks = planMarks(planPath);
  if (!marks) return fail([`registry FAIL ${planPath} not found — save the plan notes there first`]);
  const added = stubs.map((f) => addedText(root, fromCwd(f))).join("\n");
  const fails = [], asks = [];
  for (const name of marks.keys()) {
    if (!entries.some((e) => e.name === name)) fails.push(`registry FAIL ${name}: no such entry`);
  }
  for (const e of entries) {
    const mark = marks.get(e.name);
    if (!mark) fails.push(`registry FAIL ${e.name}: missing from ## Registry — mark it reuse or skip`);
    else if (mark === "reuse" && !symbolsOf(e.extend_by).some((s) => usesIn(added, s))) {
      fails.push(`registry FAIL ${e.name}: marked reuse, but no stub uses ${symbolsOf(e.extend_by).join(", ") || "a name from extend_by"}`);
    } else if (mark === "skip") {
      const hits = triggerHits(e, added);
      if (hits.length) asks.push(`registry ASK ${e.name}: skipped, but the stubs mention ${hits.join(", ")} — ask the user before stopping`);
    }
  }
  for (const line of asks) console.log(line);
  if (fails.length) return fail(fails);
  if (!asks.length) console.log("registry ok");
}

function planMissing() {
  if (entries.length && !planMarks(join(root, "PLAN.md"))?.size) console.log(`registry unplanned — ${entries.length} entries, no marks in PLAN.md`);
}

function evaluate() {
  if (!entries.length) return console.log(`registry none — no *${REGISTRY_SUFFIX} in this project`);
  for (const e of entries) {
    if (!e.does.length) { console.log(`registry eval ${e.name}: skipped, no does`); continue; }
    const outside = files.filter((f) => !insideLocation(e, f) && !isAllowed(e, f) && !f.endsWith(REGISTRY_SUFFIX));
    const hits = outside.flatMap((f) => readFileSync(join(root, f), "utf8").split("\n").flatMap((line, i) =>
      e.does.filter((code) => calls(line, code)).map((code) => `registry SUSPECT ${e.name} ${f}:${i + 1} ${code}`)));
    console.log(hits.length ? hits.join("\n") : `registry eval ${e.name}: nothing outside ${locationsOf(e).join(", ")} does its job`);
  }
}

function stale() {
  const problems = [];
  const seen = new Set();
  const ruleIds = entries.some((e) => e.rules.length) ? Object.values(loadEditRules(root)).flat().map((r) => r.id) : [];
  for (const e of entries) {
    const say = (why) => problems.push(`registry stale ${e.file}: ${why}`);
    for (const key of ["name", "summary", "location", "extend_by"]) {
      if (!e[key]) say(`no ${key}`);
      else if (/^[|>]/.test(e[key])) say(`${key} must sit on one line`);
    }
    if (!e.triggers.length) say("no triggers");
    for (const f of e.allowed) if (!existsSync(join(root, f))) say(`allowed ${f} not found`);
    for (const id of e.rules) if (!ruleIds.includes(id)) say(`rule ${id} not found in .edit-rules.json`);
    if (e.name && !/^[\w.-]+$/.test(e.name)) say(`name ${e.name} may hold only letters, digits, dashes and dots`);
    if (/^\s+-\s/m.test(e.text)) say("write lists on one line, like triggers: [aim, target]");
    if (seen.has(e.name)) say(`name ${e.name} is used twice`);
    seen.add(e.name);
    staleLocation(e, say);
    staleCode(e, say);
  }
  if (problems.length) fail(problems);
}

// A folder wide enough to hold another system hides that folder from eval.
function staleLocation(e, say) {
  const bare = (l) => l.replace(/\/$/, "");
  const own = locationsOf(e).map(bare);
  for (const other of entries) {
    if (other === e) continue;
    const held = locationsOf(other).map(bare).filter((l) => !own.includes(l) && insideLocation(e, l));
    if (held.length) say(`location holds ${other.name}'s ${held.join(", ")} — list this system's own files`);
  }
}

function staleCode(e, say) {
  const locs = locationsOf(e);
  const where = locs.join(", ");
  const gone = locs.filter((l) => !existsSync(join(root, l)));
  if (!locs.length || gone.length) return say(`location ${gone.join(", ") || e.location} not found`);
  const near = locs.map((l) => (statSync(join(root, l)).isDirectory() ? join(root, l) : dirname(join(root, l))));
  if (e.example && !near.some((n) => existsSync(join(n, e.example))) && !existsSync(join(root, e.example))) say(`example ${e.example} not found`);
  const syms = symbolsOf(e.extend_by);
  if (!syms.length) say("extend_by names no symbol — write names like `AimStrategy`");
  const code = files.filter((f) => insideLocation(e, f) && !f.endsWith(REGISTRY_SUFFIX))
    .map((f) => readFileSync(join(root, f), "utf8")).join("\n");
  for (const s of syms) {
    // A plain word like `first` matches `var first = enemies[0]`; `Aim.first` only matches real use.
    if (/^[a-z][a-z0-9]*$/.test(s)) say(`\`${s}\` is too common a word to prove use — name its owner, like \`Owner.${s}\``);
    else if (!s.split(".").every((part) => uses(code, part))) say(`${s} from extend_by is not found in ${where}`);
  }
  for (const c of e.does) if (!calls(code, c)) say(`does ${c} is not found in ${where}`);
}

function fail(lines) {
  for (const line of lines) console.log(line);
  process.exitCode = 1;
}

const [mode, ...rest] = process.argv.slice(2);
if (mode === undefined) list();
else if (mode === "--plan" && rest[0]) checkPlan(resolve(rest[0]), rest.slice(1));
else if (mode === "--plan-missing") planMissing();
else if (mode === "--stale") stale();
else if (mode === "--eval") evaluate();
else {
  console.error("usage: registry.mjs [--plan PLAN.md <stub files…> | --plan-missing | --stale | --eval]");
  process.exit(2);
}
