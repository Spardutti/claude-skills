import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";

const PROJECT = /^ {2}(\S.*?) (stryker|mutmut|config)(?: \((\d+)s\))? — (.*)$/;
const SURVIVOR = /^ {6}\[(Survived|NoCoverage)\] (\S+)\s+(\S+)$/;
const MUTMUT = /^ {6}(\S+__mutmut_\d+)$/;
const COUNTS = /^(\d+) mutants: (\d+) killed, (\d+) survived, (\d+) uncovered, (\d+) timed out, (\d+) errors$/;
const VERDICT = /^ship-gate: (PASS|FAIL|UNPROVEN|FORCED)(?: in (\d+)s)?/;

function projectFor(run, label, tool) {
  let p = run.projects.find((x) => x.label === label && x.tool === tool);
  if (!p) {
    p = { label, tool, seconds: null, result: null, reused: [], mutated: [], counts: null, survivors: [] };
    run.projects.push(p);
  }
  return p;
}

function applyProject(p, seconds, text) {
  if (seconds) p.seconds = Number(seconds);
  const counts = text.match(COUNTS);
  if (counts) {
    const [, total, killed, survived, uncovered, timedOut, errors] = counts.map(Number);
    p.counts = { total, killed, survived, uncovered, timedOut, errors };
  } else if (text.startsWith("mutated:")) p.mutated = text.slice(8).trim().split(/\s+/);
  else if (text.startsWith("ok, not re-run: passed and unchanged since:")) p.reused = text.split(":").pop().trim().split(/\s+/);
  else if (text.startsWith("ok, not re-run")) p.result = "cached";
  else if (text.startsWith("ok,")) p.result = "ok";
  else if (text.startsWith("these lines can break")) p.result = "survivors";
  else if (text.startsWith("the run failed")) p.result = "failed";
  else if (text.startsWith("UNPROVEN")) p.result = "unproven";
}

function readSection(run, line, state) {
  if (line.startsWith("STRUCTURE — ")) { run.structure = line.slice(12); state.list = line.includes("outside") ? run.misplaced : null; return; }
  if (line.startsWith("FILE LENGTH — ")) { run.length = line.slice(14); state.list = line.includes("over the limit") ? run.overLimit : null; return; }
  if (line.startsWith("ship-gate: not gated")) { state.list = run.ignored; return; }
  const scope = line.match(/^ship-gate:\s+(\d+) changed code file\(s\)/);
  if (scope) run.scope = Number(scope[1]);
  const verdict = line.match(VERDICT);
  if (verdict) run.verdict = verdict[1];
  if (line.startsWith("ship-gate: no changed code files")) run.verdict = "PASS";
  if (!/^ {2}\S/.test(line) || line.includes("Move them") || line.includes("Splitting a file")) state.list = null;
}

function readLine(run, line, state) {
  const project = line.match(PROJECT);
  if (project) {
    state.project = projectFor(run, project[1], project[2]);
    applyProject(state.project, project[3], project[4]);
    state.list = null;
    return;
  }
  const survivor = line.match(SURVIVOR) ?? line.match(MUTMUT);
  if (survivor && state.project) {
    state.project.survivors.push(survivor.length > 2 ? { kind: survivor[1], mutator: survivor[2], at: survivor[3] } : { kind: "Survived", at: survivor[1] });
    return;
  }
  if (state.list && /^ {2}\S/.test(line)) { state.list.push(line.trim()); return; }
  readSection(run, line, state);
}

export function parseReport(text) {
  const run = { verdict: null, scope: 0, ignored: [], structure: null, misplaced: [], length: null, overLimit: [], projects: [] };
  const state = { project: null, list: null };
  for (const line of text.split("\n")) readLine(run, line, state);
  // The verdict is the last line the gate prints; a run killed before it never earned one.
  run.verdict ??= "INTERRUPTED";
  return run;
}

export function git(args) {
  const r = spawnSync("git", args, { encoding: "utf8", maxBuffer: 1 << 26 });
  return r.status === 0 ? r.stdout.trim() : "";
}

function kindOf(path, testRe, sourceExt) {
  if (testRe && new RegExp(testRe).test(path)) return "tests";
  return sourceExt && new RegExp(`\\.(${sourceExt})$`).test(path) ? "code" : "other";
}

function untracked() {
  return git(["ls-files", "--others", "--exclude-standard"]).split("\n").filter(Boolean).map((f) => {
    let text = "";
    try { text = readFileSync(f, "utf8"); } catch { /* unreadable: count the file, not its lines */ }
    return [text ? text.split("\n").length - (text.endsWith("\n") ? 1 : 0) : 0, 0, f];
  });
}

// What the PR will hold: the fork point against the working tree, plus files not yet added.
export function prSize(base, testRe, sourceExt) {
  const fork = git(["merge-base", base, "HEAD"]).trim() || base;
  const rows = git(["diff", "--numstat", "--no-renames", fork]).split("\n").filter(Boolean).map((l) => l.split("\t"));
  const size = { files: 0, added: 0, removed: 0, code: { files: 0, added: 0, removed: 0 }, tests: { files: 0, added: 0, removed: 0 }, other: { files: 0, added: 0, removed: 0 } };
  for (const [a, r, f] of [...rows, ...untracked()]) {
    if (/(^|\/)\.claude\//.test(f)) continue;
    const add = Number(a) || 0, rem = Number(r) || 0, bucket = size[kindOf(f, testRe, sourceExt)];
    size.files++; size.added += add; size.removed += rem;
    bucket.files++; bucket.added += add; bucket.removed += rem;
  }
  return size;
}
