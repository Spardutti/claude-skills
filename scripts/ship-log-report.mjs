import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

function records(dir) {
  const read = (d) => (existsSync(d) ? readdirSync(d).filter((f) => f.endsWith(".json")).map((f) => join(d, f)) : []);
  return [...read(dir), ...read(join(dir, "open"))].flatMap((f) => {
    try {
      const r = JSON.parse(readFileSync(f, "utf8"));
      return r?.v === 1 && Array.isArray(r.gate) && Array.isArray(r.findings) ? [r] : [];
    } catch { return []; }
  });
}

export function tally(findings) {
  const by = {};
  for (const f of findings) {
    const s = (by[f.by.split(":")[0]] ??= { found: 0, confirmed: 0, refuted: 0, unconfirmed: 0, fixed: 0 });
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

function table(rows) {
  const head = ["app", "date", "pr", "status", "min", "gate runs", "gate time", "files +/-", "findings found/confirmed/fixed"];
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
