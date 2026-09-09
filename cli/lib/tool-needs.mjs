// What the installed commands need that this project does not have — a report,
// not an install. Nothing to do with reading a local catalog, which is what the
// rest of local.mjs was for; they shared a file and nothing else.
import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { listDir } from "./local.mjs";

const exec = promisify(execFile);


// Build output is not a project. Next.js writes a package.json into .next/,
// .next/dev/ and .next/standalone/, so a scan that skipped only a hardcoded
// list reported three phantom projects on a plain Next app — and then filtered
// the real repo root out as "a root that delegates to a workspace". A second
// list of build dirs drifts from .gitignore the moment a framework adds one, so
// ask git the way ship-gate.sh already does. --directory collapses a fully
// ignored tree to its own name, which is what keeps this output small.
async function gitIgnoredDirs(projectDir) {
  try {
    const { stdout } = await exec(
      "git",
      ["-C", projectDir, "ls-files", "--others", "--ignored", "--exclude-standard", "--directory"],
      { maxBuffer: 10 * 1024 * 1024 },
    );
    return new Set(
      stdout.split("\n").filter((l) => l.endsWith("/")).map((l) => l.slice(0, -1)),
    );
  } catch {
    return new Set();
  }
}



// What the installed commands need that this project does not have yet.
// ship-gate.sh's own detection drives a single-package repo; a monorepo whose
// tools need a workspace prefix or a container sets GAUNTLET_MUTATE instead. Only
// /ship needs anything: a mutation tool, per project, since a monorepo can hold
// several and they do not share one.
export async function reportToolNeeds(projectDir) {
  const needs = [];
  const seen = new Set();
  // Whether a nested project of each kind exists at all — not whether it still
  // needs a tool. A root that delegates is not the place to install, even once
  // the workspace it delegates to is already set up.
  const nested = { Stryker: false, mutmut: false };
  // Empty outside a git repo, so the hardcoded list below still carries those.
  const ignored = await gitIgnoredDirs(projectDir);

  async function scan(rel, depth) {
    if (depth > 2) return;
    const dir = rel ? join(projectDir, rel) : projectDir;
    const entries = await listDir(dir);
    const label = rel ? `${rel}/` : "<repo root>";

    const pkg = entries.find((e) => e.isFile() && e.name === "package.json");
    const pyp = entries.find((e) => e.isFile() && (e.name === "pyproject.toml" || e.name === "pytest.ini"));

    if (pkg && rel) nested.Stryker = true;
    if (pyp && rel) nested.mutmut = true;

    if (pkg && !seen.has(label)) {
      seen.add(label);
      const text = await readFile(join(dir, "package.json"), "utf-8");
      if (!text.includes("@stryker-mutator/core")) {
        const at = rel ? rel + "/" : "";
        needs.push({
          label,
          rel,
          tool: "Stryker",
          install: `npm --prefix ${rel || "."} i -D @stryker-mutator/core @stryker-mutator/vitest-runner`,
          config: `${at}stryker.config.json  {"testRunner":"vitest","plugins":["@stryker-mutator/vitest-runner"],"coverageAnalysis":"perTest"}`,
          // Stryker copies the whole project into .stryker-tmp/sandbox-*/, so
          // every test file briefly exists twice and the runner collects both.
          // The duplicates pass, so a doubled test count is the only symptom.
          // Spread configDefaults.exclude — assigning it drops node_modules.
          also: [
            `${at}vitest.config.ts  exclude: [...configDefaults.exclude, "**/.stryker-tmp/**"]`,
            `${at}.gitignore  .stryker-tmp/`,
          ],
        });
      } else {
        // Stryker is installed, so this project is not missing a tool — but the
        // projects that already run it are the ones grinding through mutants on
        // className strings, and a setup done before the ignorer existed has no
        // way to learn about it. Offer it here or it never reaches them.
        let cfg = "";
        try {
          cfg = await readFile(join(dir, "stryker.config.json"), "utf-8");
        } catch {
          // no config of its own — the scaffolder writes one
        }
        if (!cfg.includes("tailwind-classnames")) {
          needs.push({ label, rel, tool: "Stryker", ignorerOnly: true });
        }
      }
    }
    if (pyp && !seen.has(label + ":py")) {
      seen.add(label + ":py");
      const text = pyp.name === "pyproject.toml" ? await readFile(join(dir, "pyproject.toml"), "utf-8") : "";
      if (!text.includes("[tool.mutmut]")) {
        const advice = await pythonAdvice(dir, rel, entries);
        needs.push({ label, tool: "mutmut", ...advice });
      }
    }

    for (const e of entries) {
      if (!e.isDirectory()) continue;
      if (["node_modules", ".git", "dist", "build", ".venv", "venv", ".claude"].includes(e.name)) continue;
      const child = rel ? `${rel}/${e.name}` : e.name;
      if (ignored.has(child)) continue;
      await scan(child, depth + 1);
    }
  }

  await scan("", 0);

  // A root package.json that delegates to a workspace (npm --prefix web run test)
  // has no tests of its own, so asking for a mutation tool there is noise.
  return needs.filter((n) => n.label !== "<repo root>" || !nested[n.tool]);
}
