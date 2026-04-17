import { execSync } from "node:child_process";

const REPO_OWNER = "Spardutti";
const REPO_NAME = "claude-skills";
const CONTENTS_API = `https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/contents/skills`;
const COMMANDS_API = `https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/contents/commands`;
const AGENTS_API = `https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/contents/agents`;
const RAW_BASE = `https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main/skills`;
const RAW_COMMANDS_BASE = `https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main/commands`;
const RAW_AGENTS_BASE = `https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main/agents`;

function getAuthHeaders() {
  const headers = { "User-Agent": "claude-skills-cli" };

  const envToken = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
  if (envToken) {
    headers.Authorization = `Bearer ${envToken}`;
    return headers;
  }

  try {
    const token = execSync("gh auth token", {
      encoding: "utf-8",
      timeout: 5000,
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
    if (token) {
      headers.Authorization = `Bearer ${token}`;
    }
  } catch {
    // gh not installed or not authenticated — continue unauthenticated
  }

  return headers;
}

async function fetchListing({ apiUrl, label, entryFilter, buildRawUrl, mapEntry, allow404 = false }) {
  const headers = getAuthHeaders();
  const res = await fetch(apiUrl, { headers });

  if (!res.ok) {
    if (allow404 && res.status === 404) return [];
    if (res.status === 403 || res.status === 429) {
      throw new Error("GitHub API rate limit exceeded. Try again later or install gh CLI (https://cli.github.com).");
    }
    throw new Error(`Failed to list ${label}: ${res.status} ${res.statusText}`);
  }

  const entries = (await res.json()).filter(entryFilter);

  const results = await Promise.all(
    entries.map(async (entry) => {
      try {
        const r = await fetch(buildRawUrl(entry), { headers });
        if (!r.ok) {
          console.warn(`  Warning: Failed to fetch ${label} ${entry.name}, skipping`);
          return null;
        }
        return mapEntry(entry, await r.text());
      } catch {
        console.warn(`  Warning: Failed to fetch ${entry.name}, skipping`);
        return null;
      }
    })
  );

  return results.filter(Boolean);
}

export function fetchSkills() {
  return fetchListing({
    apiUrl: CONTENTS_API,
    label: "skills",
    entryFilter: (e) => e.type === "dir",
    buildRawUrl: (dir) => `${RAW_BASE}/${dir.name}/SKILL.md`,
    mapEntry: (dir, content) => {
      const { name, description, category } = parseFrontmatter(content, dir.name);
      return { dirName: dir.name, name, description, category, content };
    },
  });
}

export function fetchCommands() {
  return fetchListing({
    apiUrl: COMMANDS_API,
    label: "commands",
    allow404: true,
    entryFilter: (e) => e.type === "file" && e.name.endsWith(".md"),
    buildRawUrl: (file) => `${RAW_COMMANDS_BASE}/${file.name}`,
    mapEntry: (file, content) => {
      const { name, description, category, requiresAgents } = parseFrontmatter(content, file.name.replace(/\.md$/, ""));
      return { fileName: file.name, name, description, category, requiresAgents, content };
    },
  });
}

export function fetchAgents() {
  return fetchListing({
    apiUrl: AGENTS_API,
    label: "agents",
    allow404: true,
    entryFilter: (e) => e.type === "file" && e.name.endsWith(".md"),
    buildRawUrl: (file) => `${RAW_AGENTS_BASE}/${file.name}`,
    mapEntry: (file, content) => {
      const { name } = parseFrontmatter(content, file.name.replace(/\.md$/, ""));
      return { fileName: file.name, name, content };
    },
  });
}

function parseFrontmatter(content, fallbackName) {
  const match = content.match(/^---\s*\n([\s\S]*?)\n---/);
  if (!match) {
    return { name: fallbackName, description: "", category: "General", requiresAgents: [] };
  }

  const block = match[1];
  const name = block.match(/^name:\s*(.+)$/m)?.[1]?.trim() || fallbackName;
  const description = block.match(/^description:\s*(.+)$/m)?.[1]?.trim() || "";
  const category = block.match(/^category:\s*(.+)$/m)?.[1]?.trim() || "General";
  const requiresAgents = parseAgentList(block);

  return { name, description, category, requiresAgents };
}

function parseAgentList(block) {
  const inline = block.match(/^requires-agents:\s*\[([^\]]*)\]\s*$/m);
  if (inline) {
    return inline[1]
      .split(",")
      .map((s) => s.trim().replace(/^["']|["']$/g, ""))
      .filter(Boolean);
  }
  const multiline = block.match(/^requires-agents:\s*\n((?:\s{2,}-\s*.+\n?)+)/m);
  if (multiline) {
    return multiline[1]
      .split("\n")
      .map((l) => l.replace(/^\s*-\s*/, "").trim().replace(/^["']|["']$/g, ""))
      .filter(Boolean);
  }
  return [];
}
