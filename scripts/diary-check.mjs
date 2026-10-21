#!/usr/bin/env node
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { claudeDir, parseLine, readLines, verdictOf } from "./diary-lib.mjs";

const DIR = claudeDir();
const STAMP = resolve(DIR, "add-rule-checked");
const TRUNKS = new Set(["main", "master", "dev", "develop", "development"]);
const lines = (name) => readLines(resolve(DIR, name));

function entries() {
  const parsed = (name) => lines(name).map(parseLine).filter(Boolean);
  const audits = parsed("skill-flags.jsonl").filter((e) => verdictOf(e.reply ?? "")?.violations?.length > 0);
  const all = [...parsed("review-findings.jsonl"), ...parsed("gate-findings.jsonl"), ...audits];
  return all.filter((e) => e.branch && !TRUNKS.has(e.branch));
}

function check() {
  const since = existsSync(STAMP) ? readFileSync(STAMP, "utf8").trim() : "";
  const fresh = entries().filter((e) => (e.ts ?? "") > since);
  const branches = new Set(fresh.map((e) => e.branch));
  if (branches.size < 2) return;
  console.log(`${fresh.length} diary entries from ${branches.size} branches since /add-rule last looked (${since || "never"}). Offer only repeats with an entry after that.`);
}

const mode = process.argv[2];
if (mode === "--mark") {
  mkdirSync(DIR, { recursive: true });
  writeFileSync(STAMP, `${new Date().toISOString().replace(/\.\d+Z$/, "Z")}\n`);
} else if (mode === "--entries") {
  for (const e of entries()) console.log(JSON.stringify(e));
} else if (mode === undefined) {
  check();
} else {
  console.error("usage: diary-check.mjs [--mark | --entries]");
  process.exit(1);
}
