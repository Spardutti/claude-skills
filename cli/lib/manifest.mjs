import { readFile, writeFile, rm, readdir, mkdir } from "node:fs/promises";
import { join } from "node:path";

export const MANIFEST_FILE = ".claude-skills.json";

function manifestPath(targetDir) {
  return join(targetDir, ".claude", MANIFEST_FILE);
}

// Read the install manifest, or null if this project has never been tracked.
export async function readManifest(targetDir = process.cwd()) {
  try {
    const data = JSON.parse(await readFile(manifestPath(targetDir), "utf-8"));
    return {
      catalogVersion: data.catalogVersion ?? null,
      skills: data.skills ?? [],
      commands: data.commands ?? [],
      agents: data.agents ?? [],
    };
  } catch {
    return null; // no manifest — a pre-manifest project or a fresh install
  }
}

// Record exactly what the CLI has installed. This is the CLI's source of truth —
// it never deletes anything not listed here.
export async function writeManifest(targetDir, { catalogVersion, skills, commands, agents }) {
  await mkdir(join(targetDir, ".claude"), { recursive: true });
  const data = {
    catalogVersion,
    installedAt: new Date().toISOString(),
    skills: [...new Set(skills)].sort(),
    commands: [...new Set(commands)].sort(),
    agents: [...new Set(agents)].sort(),
  };
  await writeFile(manifestPath(targetDir), JSON.stringify(data, null, 2) + "\n");
}

// Manifest entries that no longer exist in the current catalog (renamed or removed upstream).
export function computeOrphans(manifest, catalog) {
  if (!manifest) return { skills: [], commands: [], agents: [] };
  const has = {
    skills: new Set(catalog.skills.map((s) => s.dirName)),
    commands: new Set(catalog.commands.map((c) => c.fileName)),
    agents: new Set(catalog.agents.map((a) => a.fileName)),
  };
  return {
    skills: manifest.skills.filter((n) => !has.skills.has(n)),
    commands: manifest.commands.filter((n) => !has.commands.has(n)),
    agents: manifest.agents.filter((n) => !has.agents.has(n)),
  };
}

// Manifest entries still in the catalog but absent from the new selection — deliberate removals.
export function computeRemovals(manifest, catalog, selection) {
  if (!manifest) return { skills: [], commands: [], agents: [] };
  const inCatalog = {
    skills: new Set(catalog.skills.map((s) => s.dirName)),
    commands: new Set(catalog.commands.map((c) => c.fileName)),
    agents: new Set(catalog.agents.map((a) => a.fileName)),
  };
  const selected = {
    skills: new Set(selection.skills),
    commands: new Set(selection.commands),
    agents: new Set(selection.agents),
  };
  return {
    skills: manifest.skills.filter((n) => inCatalog.skills.has(n) && !selected.skills.has(n)),
    commands: manifest.commands.filter((n) => inCatalog.commands.has(n) && !selected.commands.has(n)),
    agents: manifest.agents.filter((n) => inCatalog.agents.has(n) && !selected.agents.has(n)),
  };
}

// Directories/files actually present in .claude/ — used to spot stale content
// in legacy (pre-manifest) projects.
export async function scanInstalled(targetDir = process.cwd()) {
  const list = async (subdir, dirsOnly) => {
    try {
      const entries = await readdir(join(targetDir, ".claude", subdir), { withFileTypes: true });
      return entries
        .filter((e) => (dirsOnly ? e.isDirectory() : e.isFile() && e.name.endsWith(".md")))
        .map((e) => e.name);
    } catch {
      return [];
    }
  };
  return {
    skills: await list("skills", true),
    commands: await list("commands", false),
    agents: await list("agents", false),
  };
}

// Delete skill directories and command/agent files. Only ever called with names
// the CLI knows it installed (from the manifest) or names the user explicitly picked.
export async function removeArtifacts(targetDir, { skills = [], commands = [], agents = [] }) {
  for (const dir of skills) {
    await rm(join(targetDir, ".claude", "skills", dir), { recursive: true, force: true });
  }
  for (const file of commands) {
    await rm(join(targetDir, ".claude", "commands", file), { force: true });
  }
  for (const file of agents) {
    await rm(join(targetDir, ".claude", "agents", file), { force: true });
  }
}
