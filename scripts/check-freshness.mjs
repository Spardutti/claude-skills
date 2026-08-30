#!/usr/bin/env node
// check-freshness.mjs — compare the versions a skill teaches against npm/PyPI.
//
//   node scripts/check-freshness.mjs
//
// A skill that names a version goes stale silently. Two claims in the react
// bundle were a few minors behind and nothing noticed until someone checked by
// hand. This reads a `tracks:` line from each SKILL.md and asks the registry.
//
//   tracks: react@19.2, react-hook-form@7.87
//   tracks: fastapi@0.136 (pypi)
//
// Exit 1 when a skill is a MAJOR behind — it is teaching the wrong thing.
// Minors are reported and do not fail: a skill can lag one deliberately.

import { readdir, readFile } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SKILLS = join(ROOT, "skills");

async function latest(pkg, registry) {
  const url =
    registry === "pypi"
      ? `https://pypi.org/pypi/${pkg}/json`
      : `https://registry.npmjs.org/${encodeURIComponent(pkg)}/latest`;
  try {
    const res = await fetch(url);
    if (!res.ok) return null;
    const body = await res.json();
    return registry === "pypi" ? body.info.version : body.version;
  } catch {
    return null;
  }
}

// "19.2" vs "19.2.8" — compare only as many parts as the skill claimed, so a
// patch bump is never noise.
function compare(claimed, current) {
  const c = claimed.split(".").map(Number);
  const n = current.split(".").map(Number);
  if (c[0] !== n[0]) return "major";
  if (c.length > 1 && c[1] !== undefined && !Number.isNaN(c[1]) && c[1] !== n[1]) return "minor";
  return "ok";
}

const rows = [];
for (const entry of await readdir(SKILLS, { withFileTypes: true })) {
  if (!entry.isDirectory()) continue;
  let text;
  try {
    text = await readFile(join(SKILLS, entry.name, "SKILL.md"), "utf-8");
  } catch {
    continue;
  }
  const line = text.match(/^tracks:\s*(.+)$/m);
  if (!line) continue;

  for (const raw of line[1].split(",").map((s) => s.trim()).filter(Boolean)) {
    const m = raw.match(/^(.+?)@([0-9][0-9.x]*)\s*(?:\((\w+)\))?$/);
    if (!m) {
      rows.push({ skill: entry.name, pkg: raw, claimed: "?", current: "unparseable", state: "major" });
      continue;
    }
    const [, pkg, claimed, registry] = m;
    // "7.x" claims a major only.
    const claim = claimed.replace(/\.x$/, "");
    const current = await latest(pkg, registry);
    rows.push({
      skill: entry.name,
      pkg,
      claimed,
      current: current ?? "unreachable",
      state: current ? compare(claim, current) : "skip",
    });
  }
}

if (rows.length === 0) {
  console.log("  no skill declares a `tracks:` line — nothing to check");
  process.exit(0);
}

let failed = 0;
for (const r of rows.sort((a, b) => a.skill.localeCompare(b.skill))) {
  const mark = { ok: "ok  ", minor: "MINOR", major: "MAJOR", skip: "skip" }[r.state];
  if (r.state === "major") failed = 1;
  console.log(`  ${mark} ${r.skill.padEnd(26)} ${r.pkg}@${r.claimed}  →  ${r.current}`);
}

console.log();
if (failed) console.log("  A skill is a MAJOR version behind — it is teaching the wrong thing.");
else console.log("  No skill is a major version behind.");
process.exit(failed);
