#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { git, parseReport, prSize } from "./ship-log-parse.mjs";
import { printReport, tally } from "./ship-log-report.mjs";

const HERE = dirname(resolve(process.argv[1]));
const VERDICTS = ["confirmed", "refuted", "unconfirmed", "skipped"];
// A release ships only work its feature PRs already logged.
const RELEASE = /^(main|master|dev|develop|development|chore\/release-.*)$/;
const now = () => new Date().toISOString().replace(/\.\d+Z$/, "Z");

// gate-config.sh owns the config files and their order, so the gate and this agree on "on".
function conf() {
  const root = git(["rev-parse", "--show-toplevel"]) || process.cwd();
  const script = 'cd "$2" && . "$1/gate-config.sh" || exit 1; load_gauntlet_conf .claude/gauntlet.conf "$1/../gauntlet.conf"; printf "\\nSHIP_LOG_ON=%s\\nSHIP_LOG_DIR=%s\\nDIARY_DIR=%s\\n" "$GAUNTLET_SHIP_LOG" "$GAUNTLET_SHIP_LOG_DIR" "$(diary_dir "$1")"';
  const out = spawnSync("bash", ["-c", script, "_", HERE, root], { encoding: "utf8" }).stdout;
  const value = (key) => out.split("\n").findLast((l) => l.startsWith(`${key}=`))?.slice(key.length + 1) ?? "";
  return { on: value("SHIP_LOG_ON") === "1", dir: value("SHIP_LOG_DIR") || join(process.env.HOME ?? "", ".claude", "ship-logs"), diary: value("DIARY_DIR"), root };
}

function identity(root) {
  const origin = git(["remote", "get-url", "origin"]);
  const app = basename(origin || root).replace(/\.git$/, "");
  return { app, branch: git(["branch", "--show-current"]) || "detached" };
}

function openPath(dir, { app, branch }) {
  return join(dir, "open", `${app}__${branch.replace(/[^\w.-]+/g, "-")}.json`);
}

function load(path, id) {
  if (existsSync(path)) return JSON.parse(readFileSync(path, "utf8"));
  return { v: 1, ...id, started: now(), status: "open", pr: null, base: null, size: null, gate: [], steps: {}, findings: [] };
}

function save(path, record) {
  mkdirSync(dirname(path), { recursive: true });
  record.updated = now();
  writeFileSync(path, `${JSON.stringify(record, null, 2)}\n`);
}

function summarize(record) {
  const by = tally(record.findings);
  const minutes = (Date.parse(record.finished) - Date.parse(record.started)) / 60000;
  return { minutes: Math.round(minutes * 10) / 10, gateRuns: record.gate.length, gateSeconds: record.gate.reduce((n, r) => n + (r.seconds ?? 0), 0), findings: by };
}

// Survivors fixed but never logged: a FAIL that a later PASS cleared, with no mutation finding since.
function settleSurvivors(record) {
  const i = record.gate.findLastIndex((g) => g.verdict === "FAIL" && g.projects?.some((p) => p.survivors?.length));
  if (i < 0 || !record.gate.slice(i + 1).some((g) => g.verdict === "PASS")) return;
  if (record.findings.some((f) => f.by === "mutation" && f.ts >= record.gate[i].ts)) return;
  for (const s of record.gate[i].projects.flatMap((p) => p.survivors ?? [])) {
    record.findings.push({ ts: now(), by: "mutation", what: `${s.mutator ?? s.kind} at ${s.at}`, file: s.at.split(":")[0],
      verdict: "confirmed", fixed: true, note: "logged by ship-log: a later gate run passed" });
  }
}

function finalize(dir, path, record, tag, status, reason, at) {
  settleSurvivors(record);
  Object.assign(record, { status, reason: reason ?? null, finished: at ?? now() });
  record.summary = summarize(record);
  const stem = `${record.app}_${record.finished.slice(0, 10)}_${tag}`;
  let out = join(dir, `${stem}.json`);
  for (let i = 2; existsSync(out); i++) out = join(dir, `${stem}-${i}.json`);
  save(path, record);
  renameSync(path, out);
  console.log(`ship-log: saved ${out}`);
}

function prOf(branch) {
  const r = spawnSync("gh", ["pr", "list", "--head", branch, "--state", "all", "--json", "number,createdAt,closedAt,state", "--limit", "1"], { encoding: "utf8" });
  try { return r.status === 0 ? JSON.parse(r.stdout)[0] : undefined; } catch { return undefined; }
}

// Agents skip the `pr` call, so a log whose branch has a PR by now is closed at that PR.
// A PR older than the log was only updated by it, so that log ends at its own last event.
// A long-lived branch like dev keeps its merged PRs, so an old one that is not open is not this log's.
function closeOpened(dir, app) {
  const open = join(dir, "open");
  for (const f of existsSync(open) ? readdirSync(open).filter((n) => n.startsWith(`${app}__`)) : []) {
    const path = join(open, f), record = JSON.parse(readFileSync(path, "utf8"));
    const pr = prOf(record.branch), empty = !record.gate.length && !record.findings.length;
    // A /ship that only merged fills nothing, so once its PR closes there is nothing to keep.
    if (empty && pr?.closedAt >= record.started) { rmSync(path); continue; }
    if (empty) continue;
    const opened = pr && pr.createdAt >= record.started;
    if (!pr || (!opened && pr.state !== "OPEN")) continue;
    finalize(dir, path, Object.assign(record, { pr: pr.number }), `pr${pr.number}`,
      opened ? "pr-opened" : "pr-updated", null, opened ? pr.createdAt : lastEvent(record));
  }
}

// A ship that never reached pr or end was abandoned; keep it, but never fold it into the next one.
function restart(dir, path, record, id) {
  closeOpened(dir, id.app);
  if (existsSync(path)) finalize(dir, path, record, id.branch.replace(/[^\w.-]+/g, "-"), "abandoned");
  save(path, load(path, id));
}

function addGateRun(record, [report, exit, seconds, base]) {
  const text = readFileSync(report, "utf8");
  record.gate.push({ ts: now(), exit: Number(exit), seconds: Number(seconds), ...parseReport(text), report: text });
  if (base) { record.base = base; record.size = prSize(base, process.env.SHIP_LOG_TEST_RE ?? "", process.env.SHIP_LOG_SOURCE_EXT ?? ""); }
}

function addFinding(record, json) {
  const f = JSON.parse(json ?? "");
  if (typeof f.by !== "string" || typeof f.what !== "string" || !VERDICTS.includes(f.verdict) || typeof f.fixed !== "boolean") {
    throw new Error(`a finding needs by, what, verdict (${VERDICTS.join("|")}) and fixed (true|false)`);
  }
  record.findings.push({ ts: now(), ...f });
}

function lastEvent(record, skip) {
  const ends = Object.entries(record.steps).filter(([k]) => k !== skip).map(([, s]) => s.end);
  return [record.started, ...record.gate.map((g) => g.ts), ...ends].filter(Boolean).sort().at(-1);
}

function addStep(record, [name, edge]) {
  if (!name || !["start", "end"].includes(edge)) throw new Error("usage: step <name> start|end");
  const step = (record.steps[name] ??= {});
  step[edge] = now();
  if (edge === "end" && !step.start) step.start = lastEvent(record, name);
  if (step.start && step.end) step.seconds = Math.round((Date.parse(step.end) - Date.parse(step.start)) / 1000);
}

// Worktrees share one diary, so only this branch's latest review since the ship started counts.
function lastReview(diary, branch, since) {
  const file = join(diary, "review-findings.jsonl");
  const rows = existsSync(file) ? readFileSync(file, "utf8").split("\n").filter(Boolean) : [];
  const last = rows.map((l) => { try { return JSON.parse(l); } catch { return null; } })
    .filter((r) => r?.branch === branch && r.ts >= since && typeof r.reply === "string").at(-1);
  const json = last?.reply.match(/```json\s*([\s\S]*?)```/)?.[1];
  try {
    const list = json && JSON.parse(json);
    return Array.isArray(list) ? { ts: last.ts, count: list.length } : null;
  } catch { return null; }
}

// Agents skipped the log's steps even when the text sat inside them, so the PR hook asks this.
// A ship with no review (a release, a forced run) is never held.
function missing(record, c) {
  const review = lastReview(c.diary, record.branch, record.started);
  if (!review) return [];
  const quote = (s) => `'${s.replaceAll("'", "'\\''")}'`;
  const cmd = (args) => `SHIP_LOG_ROOT=${quote(c.root)} node ${quote(join(HERE, "ship-log.mjs"))} ${args}`;
  const out = [];
  if (!record.steps.review?.end) out.push(cmd("step review end"));
  const have = record.findings.filter((f) => f.by === "review" && f.ts >= review.ts).length;
  if (have < review.count) out.push(`${cmd("finding '<json>'")} for every review finding: ${have} of ${review.count} logged; a duplicate is verdict "skipped", note "duplicate of <what>"`);
  return out;
}

function run(mode, args) {
  const c = conf();
  if (mode === "report") return printReport(args[0] ?? c.dir);
  if (mode === "on") return c.on ? 0 : 1;
  if (!c.on) return 0;
  const id = identity(c.root), path = openPath(c.dir, id), record = load(path, id);
  if (mode === "start" && RELEASE.test(id.branch)) {
    closeOpened(c.dir, id.app);
    if (existsSync(path)) rmSync(path);
    return 0;
  }
  if (mode === "start") return restart(c.dir, path, record, id), 0;
  if (mode === "ready") {
    const todo = existsSync(path) ? missing(record, c) : [];
    if (todo.length) console.log(todo.map((t) => `  - ${t}`).join("\n"));
    return todo.length ? 1 : 0;
  }
  // A gate run or a review outside /ship is not a ship; only /ship's start opens one.
  if ((mode === "gate" || mode === "step") && !existsSync(path)) return 0;
  if (mode === "gate") addGateRun(record, args);
  else if (mode === "finding") addFinding(record, args[0]);
  else if (mode === "step") addStep(record, args);
  else if (mode === "pr" && /^\d+$/.test(args[0] ?? "")) {
    record.pr = Number(args[0]);
    return finalize(c.dir, path, record, `pr${args[0]}`, "pr-opened"), 0;
  }
  else if (mode === "end") return finalize(c.dir, path, record, id.branch.replace(/[^\w.-]+/g, "-"), "stopped", args.join(" ") || null), 0;
  else throw new Error("usage: ship-log.mjs on | start | ready | gate <report> <exit> <seconds> <base> | step <name> start|end | finding '<json>' | pr <number> | end [reason] | report [dir]");
  save(path, record);
  return 0;
}

try {
  // Like ship-mark, ship-gate and ship-prep, a worktree ship names its folder in CLAUDE_PROJECT_DIR.
  const root = process.env.SHIP_LOG_ROOT || process.env.CLAUDE_PROJECT_DIR;
  if (root) process.chdir(root);
  process.exit(run(process.argv[2], process.argv.slice(3)) ?? 0);
} catch (err) {
  console.error(`ship-log: ${err.message}`);
  process.exit(1);
}
