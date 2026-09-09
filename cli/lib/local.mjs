// Local catalog source — the same shape github.mjs returns, read from a working
// copy instead of GitHub. Testing an unreleased change should not require
// publishing it first.
import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { parseFrontmatter } from "./frontmatter.mjs";

export async function listDir(dir) {
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