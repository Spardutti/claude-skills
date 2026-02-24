import { execSync } from "node:child_process";

const REPO_OWNER = "Spardutti";
const REPO_NAME = "claude-skills";
const CONTENTS_API = `https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/contents/skills`;
const RAW_BASE = `https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main/skills`;

function getAuthHeaders() {
  const headers = { "User-Agent": "claude-skills-cli" };

  // 1. Explicit env var
  const envToken = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
  if (envToken) {
    headers.Authorization = `Bearer ${envToken}`;
    return headers;
  }

  // 2. Try gh CLI token
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

export async function fetchSkills() {
  const headers = getAuthHeaders();

  const res = await fetch(CONTENTS_API, { headers });

  if (!res.ok) {
    if (res.status === 403 || res.status === 429) {
      throw new Error("GitHub API rate limit exceeded. Try again later or install gh CLI (https://cli.github.com).");
    }
    throw new Error(`Failed to list skills: ${res.status} ${res.statusText}`);
  }

  const entries = await res.json();
  const dirs = entries.filter((e) => e.type === "dir");

  const results = await Promise.all(
    dirs.map(async (dir) => {
      try {
        const url = `${RAW_BASE}/${dir.name}/SKILL.md`;
        const r = await fetch(url, { headers });

        if (!r.ok) {
          console.warn(`  Warning: No SKILL.md found in ${dir.name}, skipping`);
          return null;
        }

        const content = await r.text();
        const { name, description } = parseFrontmatter(content, dir.name);

        return { dirName: dir.name, name, description, content };
      } catch {
        console.warn(`  Warning: Failed to fetch ${dir.name}, skipping`);
        return null;
      }
    })
  );

  return results.filter(Boolean);
}

function parseFrontmatter(content, fallbackName) {
  const match = content.match(/^---\s*\n([\s\S]*?)\n---/);
  if (!match) {
    return { name: fallbackName, description: "" };
  }

  const block = match[1];
  const name =
    block.match(/^name:\s*(.+)$/m)?.[1]?.trim() || fallbackName;
  const description =
    block.match(/^description:\s*(.+)$/m)?.[1]?.trim() || "";

  return { name, description };
}
