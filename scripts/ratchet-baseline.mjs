import { existsSync, readFileSync, writeFileSync } from "node:fs";

const ruleOf = (key) => key.split(" ")[0];

// "# rules:" names every rule baselined so far, since a rule with no hits leaves no other line.
// "# linter:" names who counted the lint debt; a file from before it was counted by ESLint.
export function readBaseline(path) {
  const counts = new Map();
  const rules = new Set();
  let linter = "ESLint";
  if (!existsSync(path)) return { counts, rules, linter, exists: false };
  for (const line of readFileSync(path, "utf8").split("\n")) {
    if (line.startsWith("# linter:")) linter = line.slice(9).trim();
    if (line.startsWith("# rules:")) {
      for (const id of line.slice(8).trim().split(/\s+/).filter(Boolean)) rules.add(id);
      continue;
    }
    const m = line.match(/^(\d+) (\S+) (.+)$/);
    if (!m) continue;
    counts.set(`${m[2]} ${m[3]}`, Number(m[1]));
    rules.add(m[2]);
  }
  return { counts, rules, linter, exists: true };
}

export function forget(was, ids) {
  const counts = new Map([...was.counts].filter(([key]) => !ids.includes(ruleOf(key))));
  return { ...was, counts, rules: new Set([...was.rules].filter((id) => !ids.includes(id))) };
}

// A rule baselined before only banks: its debt may drop or go, never appear or grow.
export function mergeBaseline(was, now, judged) {
  const merged = new Map([...was.counts].filter(([key]) => !judged.has(ruleOf(key))));
  for (const [key, n] of was.counts) {
    if (judged.has(ruleOf(key)) && now.has(key)) merged.set(key, Math.min(n, now.get(key)));
  }
  for (const [key, n] of now) {
    if (judged.has(ruleOf(key)) && !was.rules.has(ruleOf(key))) merged.set(key, n);
  }
  return merged;
}

export function writeBaseline(path, merged, rules, linter) {
  const lines = [...merged].map(([key, n]) => `${n} ${key}`).sort();
  const head = [`# rules: ${[...rules].sort().join(" ")}`, ...(linter ? [`# linter: ${linter}`] : [])];
  writeFileSync(path, [...head, ...lines, ""].join("\n"));
  return lines.length;
}
