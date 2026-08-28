// Local catalog source — the same shape github.mjs returns, read from a working
// copy instead of GitHub. Testing an unreleased change should not require
// publishing it first.
import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";

function parseFrontmatter(content, fallbackName) {
  const match = content.match(/^---\s*\n([\s\S]*?)\n---/);
  if (!match) return { name: fallbackName, description: "", category: "General", requiresAgents: [] };
  const fm = match[1];
  const pick = (key) => {
    const m = fm.match(new RegExp(`^${key}:\\s*(.+)$`, "m"));
    return m ? m[1].trim().replace(/^["']|["']$/g, "") : "";
  };
  const raw = pick("requires-agents");
  return {
    name: pick("name") || fallbackName,
    description: pick("description"),
    category: pick("category") || "General",
    requiresAgents: raw ? raw.replace(/[[\]]/g, "").split(",").map((s) => s.trim()).filter(Boolean) : [],
  };
}

async function listDir(dir) {
  try { return await readdir(dir, { withFileTypes: true }); } catch { return []; }
}

export function makeLocalSource(root) {
  return {
    async fetchSkills() {
      const out = [];
      for (const d of await listDir(join(root, "skills"))) {
        if (!d.isDirectory()) continue;
        const dirPath = join(root, "skills", d.name);
        const files = (await listDir(dirPath)).filter((f) => f.isFile());
        const skillFile = files.find((f) => f.name === "SKILL.md");
        if (!skillFile) continue;
        const content = await readFile(join(dirPath, "SKILL.md"), "utf-8");
        const peerFiles = [];
        for (const f of files) {
          if (f.name === "SKILL.md") continue;
          peerFiles.push({
            name: f.name,
            content: await readFile(join(dirPath, f.name), "utf-8"),
            executable: f.name.endsWith(".sh"),
          });
        }
        const { name, description, category } = parseFrontmatter(content, d.name);
        out.push({ dirName: d.name, name, description, category, content, peerFiles });
      }
      return out;
    },

    async fetchCommands() {
      const out = [];
      for (const f of await listDir(join(root, "commands"))) {
        if (!f.isFile() || !f.name.endsWith(".md")) continue;
        const content = await readFile(join(root, "commands", f.name), "utf-8");
        const { name, description, category, requiresAgents } = parseFrontmatter(content, f.name.replace(/\.md$/, ""));
        out.push({ fileName: f.name, name, description, category, requiresAgents, content });
      }
      return out;
    },

    async fetchAgents() {
      const out = [];
      for (const f of await listDir(join(root, "agents"))) {
        if (!f.isFile() || !f.name.endsWith(".md")) continue;
        const content = await readFile(join(root, "agents", f.name), "utf-8");
        const { name } = parseFrontmatter(content, f.name.replace(/\.md$/, ""));
        out.push({ fileName: f.name, name, content });
      }
      return out;
    },
  };
}

// mutmut's config has to name the real source and test directories, and the
// install command has to match how the project actually manages dependencies —
// `pip install` into a uv project puts it somewhere the container rebuild loses.
async function pythonAdvice(dir, rel, entries) {
  const has = (n) => entries.some((e) => e.name === n);
  const pyproject = has("pyproject.toml") ? await readFile(join(dir, "pyproject.toml"), "utf-8") : "";

  let install = "pip install mutmut";
  if (has("uv.lock") || /^\[tool\.uv\]/m.test(pyproject)) install = "uv add --dev mutmut";
  else if (has("poetry.lock")) install = "poetry add --group dev mutmut";

  // Source: the package directory, not a guess. Skip the ones that are never it.
  const ignore = ["tests", "test", "alembic", "migrations", "db", "e2e", "__pycache__", ".venv", "venv", "scripts"];
  const dirs = entries.filter((e) => e.isDirectory() && !e.name.startsWith(".") && !ignore.includes(e.name));
  const source = (dirs.find((d) => d.name === "src") || dirs.find((d) => d.name === "app") || dirs[0])?.name || "src";

  // Tests: pytest already knows where they are.
  const testpaths = pyproject.match(/testpaths\s*=\s*\[([^\]]*)\]/);
  const tests = testpaths ? testpaths[1].replace(/["'\s]/g, "").split(",")[0] : "tests";

  return {
    install,
    config: `${rel ? rel + "/" : ""}pyproject.toml  [tool.mutmut] source_paths=["${source}/"] pytest_add_cli_args_test_selection=["${tests}/"]`,
  };
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
      await scan(rel ? `${rel}/${e.name}` : e.name, depth + 1);
    }
  }

  await scan("", 0);

  // A root package.json that delegates to a workspace (npm --prefix web run test)
  // has no tests of its own, so asking for a mutation tool there is noise.
  return needs.filter((n) => n.label !== "<repo root>" || !nested[n.tool]);
}
