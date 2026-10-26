#!/usr/bin/env node
import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import {
  REGISTRY_SUFFIX, addedText, escape, insideLocation, loadRegistry, projectFiles, projectRoot, symbolsOf, triggerHits,
} from "./registry-lib.mjs";

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

function list() {
  if (!entries.length) return console.log(`registry none — no *${REGISTRY_SUFFIX} in this project`);
  for (const e of entries) console.log(`== ${e.file} ==\n${e.text.trim()}\n`);
  stale();
}

function planMarks(planPath) {
  const text = existsSync(planPath) ? readFileSync(planPath, "utf8") : null;
  if (text === null) return null;
  const section = text.split(/^## /m).find((s) => /^Registry\s*$/m.test(s.split("\n")[0])) ?? "";
  const marks = new Map();
  for (const m of section.matchAll(/^[-*]\s*`?([\w.-]+)`?\s*:\s*(reuse|skip)\b/gim)) marks.set(m[1], m[2].toLowerCase());
  return marks;
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

function stale() {
  const problems = [];
  const seen = new Set();
  for (const e of entries) {
    const say = (why) => problems.push(`registry stale ${e.file}: ${why}`);
    for (const key of ["name", "summary", "location", "extend_by"]) {
      if (!e[key]) say(`no ${key}`);
      else if (/^[|>]/.test(e[key])) say(`${key} must sit on one line`);
    }
    if (e.name && !/^[\w.-]+$/.test(e.name)) say(`name ${e.name} may hold only letters, digits, dashes and dots`);
    if (/^\s+-\s/m.test(e.text)) say("write lists on one line, like triggers: [aim, target]");
    if (seen.has(e.name)) say(`name ${e.name} is used twice`);
    seen.add(e.name);
    const loc = join(root, e.location ?? "");
    if (!e.location || !existsSync(loc)) { say(`location ${e.location} not found`); continue; }
    const near = statSync(loc).isDirectory() ? loc : dirname(loc);
    if (e.example && !existsSync(join(near, e.example)) && !existsSync(join(root, e.example))) say(`example ${e.example} not found`);
    const syms = symbolsOf(e.extend_by);
    if (!syms.length) say("extend_by names no symbol — write names like `AimStrategy`");
    const code = files.filter((f) => insideLocation(e, f) && !f.endsWith(REGISTRY_SUFFIX))
      .map((f) => readFileSync(join(root, f), "utf8")).join("\n");
    for (const s of syms) {
      // A plain word like `first` matches `var first = enemies[0]`; `Aim.first` only matches real use.
      if (/^[a-z][a-z0-9]*$/.test(s)) say(`\`${s}\` is too common a word to prove use — name its owner, like \`Owner.${s}\``);
      else if (!s.split(".").every((part) => uses(code, part))) say(`${s} from extend_by is not found in ${e.location}`);
    }
  }
  if (problems.length) fail(problems);
}

function fail(lines) {
  for (const line of lines) console.log(line);
  process.exitCode = 1;
}

const [mode, ...rest] = process.argv.slice(2);
if (mode === undefined) list();
else if (mode === "--plan" && rest[0]) checkPlan(resolve(rest[0]), rest.slice(1));
else if (mode === "--stale") stale();
else {
  console.error("usage: registry.mjs [--plan PLAN.md <stub files…> | --stale]");
  process.exit(2);
}
