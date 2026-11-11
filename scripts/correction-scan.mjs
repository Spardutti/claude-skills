#!/usr/bin/env node
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { claudeDir, parseLine, readLines } from "./diary-lib.mjs";

const STAMP = resolve(claudeDir(), "dream-corrections-checked");
// Loose on purpose: Claude judges each hit, a missed correction is the costlier mistake.
const CORRECTION = /\b(no|nope|don'?t|stop|never|wrong|revert|undo|not what|i (said|asked|told|meant)|why did you|you (didn'?t|forgot|should)|should(n'?t)? have)\b/i;
const NOT_A_CORRECTION = /\bi don'?t (know|mind|think)\b/gi;
const NOT_THE_USER = /^(<|Another Claude session sent a message|This session is being continued)/;
const PASTED =/<pasted_content[^>]*>[\s\S]*?<\/pasted_content[^>]*>/g;

function textOf(message) {
  const c = message?.content;
  if (typeof c === "string") return c;
  if (!Array.isArray(c)) return "";
  return c.filter((p) => p.type === "text").map((p) => p.text).join("\n");
}

function hitsIn(path, since) {
  const hits = [];
  let lastReply = "";
  for (const e of readLines(path).map(parseLine)) {
    if (!e || e.isSidechain) continue;
    if (e.type === "assistant") lastReply = textOf(e.message) || lastReply;
    if (e.type !== "user" || e.isMeta) continue;
    const said = textOf(e.message).replace(PASTED, "[pasted]").trim();
    if (!said || NOT_THE_USER.test(said) || !CORRECTION.test(said.replace(NOT_A_CORRECTION, ""))) continue;
    if ((e.timestamp ?? "") > since) {
      hits.push({ uuid: e.uuid, ts: e.timestamp, session: e.sessionId, branch: e.gitBranch, said: said.slice(0, 300), after: lastReply.slice(-200) });
    }
  }
  return hits;
}

function scan(dir) {
  const since = existsSync(STAMP) ? readFileSync(STAMP, "utf8").trim() : "";
  const files = readdirSync(dir).filter((f) => f.endsWith(".jsonl"));
  const seen = new Set();
  // A resumed chat copies the earlier messages, uuid and all.
  const hits = files.flatMap((f) => hitsIn(resolve(dir, f), since)).filter((h) => !seen.has(h.uuid) && seen.add(h.uuid));
  hits.sort((a, b) => (b.ts ?? "").localeCompare(a.ts ?? ""));
  for (const h of hits) console.log(JSON.stringify(h));
}

const [mode, dir] = process.argv.slice(2);
if (mode === "--mark") {
  mkdirSync(claudeDir(), { recursive: true });
  writeFileSync(STAMP, `${new Date().toISOString().replace(/\.\d+Z$/, "Z")}\n`);
} else if (mode === "--scan" && dir && existsSync(dir)) {
  scan(dir);
} else {
  console.error("usage: correction-scan.mjs --scan <transcripts dir> | --mark");
  process.exit(1);
}
