import { parseFrontmatter } from "./frontmatter.mjs";
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

// raw.githubusercontent.com is not the API and the token buys nothing there, so
// it is not sent. This is hygiene, not a fix: it was first committed as the
// cause of a wave of 503s, and that was wrong. Measured after: bare requests
// returned 503 at the same rate as authenticated ones, and both went back to
// 200 once the window passed. raw was simply unwell for a few minutes.
function getRawHeaders() {
  return { "User-Agent": "claude-skills-cli" };
}

// What actually cost the user seven skills was the handling below, not the
// headers: a failed fetch printed a warning, returned null, and the install
// exited 0 having quietly dropped whatever it could not get. A 503 that clears
// in two seconds should never reach the user, and one that does not clear must
// not look like success.
const RETRIES = 4;

async function fetchRaw(url) {
  let last = "";
  for (let attempt = 0; attempt < RETRIES; attempt++) {
    // 400ms, 800ms, 1600ms. The outage that prompted this cleared well inside
    // that; a longer wait would only make a real outage slower to report.
    if (attempt > 0) await new Promise((r) => setTimeout(r, 400 * 2 ** (attempt - 1)));
    try {
      const r = await fetch(url, { headers: getRawHeaders() });
      if (r.ok) return await r.text();
      last = `${r.status} ${r.statusText}`;
      // A missing file is an answer, not a hiccup. Retrying it wastes the
      // user's time and still ends in the same place.
      if (r.status === 404) break;
    } catch (e) {
      last = e.message;
    }
  }
  throw new Error(`${url} — ${last || "unreachable"} after ${RETRIES} attempts`);
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

  // No try/catch: a file this listing named and the network could not deliver
  // is a failed install, not a smaller one. Promise.all rejects on the first
  // failure and the error carries the URL and the last status.
  const results = await Promise.all(
    entries.map(async (entry) =>
      mapEntry(entry, await fetchRaw(buildRawUrl(entry)))
    )
  );

  return results.filter(Boolean);
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

  const dirs = (await res.json()).filter((e) => e.type === "dir");

  // A transient raw outage used to land here as seven "skipping" warnings and
  // an exit code of 0 — the catalog simply came back smaller, and the picker
  // offered whatever survived. Every failure now throws, after fetchRaw has
  // already retried it.
  const skills = await Promise.all(
    dirs.map(async (dir) => {
      const listRes = await fetch(`${CONTENTS_API}/${dir.name}`, { headers });
      if (!listRes.ok) {
        throw new Error(`Failed to list skill ${dir.name}: ${listRes.status} ${listRes.statusText}`);
      }
      const files = (await listRes.json()).filter((e) => e.type === "file");

      const fetched = await Promise.all(
        files.map(async (f) => ({
          name: f.name,
          content: await fetchRaw(`${RAW_BASE}/${dir.name}/${f.name}`),
          executable: f.name.endsWith(".sh"),
        }))
      );

      const skillMd = fetched.find((f) => f.name === "SKILL.md");
      // Now genuinely a repo problem rather than a lost download, so it is
      // still a skip — but the listing said this directory exists, so say so.
      if (!skillMd) {
        console.warn(`  Warning: ${dir.name} has no SKILL.md in the repo, skipping`);
        return null;
      }
      const peerFiles = fetched.filter((f) => f.name !== "SKILL.md");
      const { name, description, category } = parseFrontmatter(skillMd.content, dir.name);
      return { dirName: dir.name, name, description, category, content: skillMd.content, peerFiles };
    })
  );

  return skills.filter(Boolean);
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
