import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

function records(dir) {
  const read = (d) => (existsSync(d) ? readdirSync(d).filter((f) => f.endsWith(".json")).map((f) => join(d, f)) : []);
  return [...read(dir), ...read(join(dir, "open"))].flatMap((f) => {
    try {
      const r = JSON.parse(readFileSync(f, "utf8"));
      const log = r?.v === 1 && Array.isArray(r.gate) && Array.isArray(r.findings);
      // A /deliver that only merged opens a log and never fills it.
      return log && (r.gate.length || r.findings.length) ? [r] : [];
    } catch { return []; }
  });
}

export function tally(findings) {
  const by = {};
  for (const f of findings) {
    const s = (by[f.by.split(":")[0]] ??= { found: 0, confirmed: 0, refuted: 0, unconfirmed: 0, skipped: 0, fixed: 0 });
    s.found++; s[f.verdict]++; if (f.fixed) s.fixed++;
  }
  return by;
}

function findingCell(by = {}) {
  const parts = Object.entries(by).map(([src, s]) => `${src} ${s.found}/${s.confirmed}/${s.fixed}`);
  return parts.join(" · ") || "-";
}

function row(r) {
  const s = r.summary ?? { minutes: null, gateRuns: r.gate.length, gateSeconds: r.gate.reduce((n, g) => n + (g.seconds ?? 0), 0), findings: tally(r.findings) };
  const size = r.size ? `${r.size.files} +${r.size.added} -${r.size.removed}` : "-";
  return [r.app, (r.finished ?? r.started).slice(0, 10), r.pr ? `#${r.pr}` : r.branch, r.status, s.minutes ?? "-", s.gateRuns, `${s.gateSeconds}s`, size, findingCell(s.findings)];
}

const SHIPS = ["app", "date", "pr", "status", "min", "gate runs", "gate time", "files +/-", "findings found/confirmed/fixed"];

function table(rows, head = SHIPS) {
  const widths = head.map((h, i) => Math.max(h.length, ...rows.map((r) => String(r[i]).length)));
  for (const r of [head, ...rows]) console.log(r.map((c, i) => String(c).padEnd(widths[i])).join("  ").trimEnd());
}

export function printReport(dir) {
  const all = records(dir).sort((a, b) => (a.finished ?? a.started).localeCompare(b.finished ?? b.started));
  if (all.length === 0) {
    console.log(`ship-log: no logs in ${dir}. Turn logging on with GAUNTLET_SHIP_LOG=1 in ~/.claude/gauntlet.conf.`);
    return 0;
  }
  table(all.map(row));
  return 0;
}

const MUTATION = /^(stryker|mutmut)$/;
const ran = (p) => MUTATION.test(p.tool) && (p.result === "ok" || p.result === "survivors");

// Gaps on a branch's first mutation run: the tests Claude missed before the gate pointed at them.
function firstRunGaps(record) {
  const run = record.gate.find((g) => g.projects?.some(ran));
  return run ? run.projects.filter(ran).flatMap((p) => p.survivors ?? []) : null;
}

function weekOf(iso) {
  const d = new Date(iso.slice(0, 10));
  d.setUTCDate(d.getUTCDate() - ((d.getUTCDay() + 6) % 7));
  return d.toISOString().slice(0, 10);
}

// The kinds name the next checklist pattern to add in test-checks.mjs.
function topKinds(gaps) {
  const by = new Map();
  for (const g of gaps) by.set(g.mutator ?? "unnamed (mutmut)", (by.get(g.mutator ?? "unnamed (mutmut)") ?? 0) + 1);
  return [...by].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).slice(0, 5).map(([k, n]) => `${k} ${n}`).join(", ");
}

export function printGaps(dir) {
  const weeks = new Map();
  for (const r of records(dir)) {
    const gaps = firstRunGaps(r);
    if (gaps === null) continue;
    const w = weeks.get(weekOf(r.started)) ?? { branches: 0, withGaps: 0, gaps: [] };
    w.branches++; w.gaps.push(...gaps); if (gaps.length) w.withGaps++;
    weeks.set(weekOf(r.started), w);
  }
  if (weeks.size === 0) return console.log("ship-log: no mutation runs logged yet."), 0;
  const sorted = [...weeks].sort();
  table(sorted.map(([wk, w]) => [wk, w.branches, w.withGaps, (w.gaps.length / w.branches).toFixed(1)]), ["week of", "branches", "first run had gaps", "gaps per branch"]);
  console.log(`\ngap kinds, last 4 weeks: ${topKinds(sorted.slice(-4).flatMap(([, w]) => w.gaps)) || "none"}`);
  return 0;
}
