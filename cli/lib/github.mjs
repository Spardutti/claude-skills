const REPO_OWNER = "Spardutti";
const REPO_NAME = "claude-skills";
const CONTENTS_API = `https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/contents/skills`;
const RAW_BASE = `https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main/skills`;

export async function fetchSkills() {
  const res = await fetch(CONTENTS_API, {
    headers: { "User-Agent": "claude-skills-cli" },
  });

  if (!res.ok) {
    if (res.status === 403) {
      throw new Error("GitHub API rate limit exceeded. Try again later.");
    }
    throw new Error(`Failed to list skills: ${res.status} ${res.statusText}`);
  }

  const entries = await res.json();
  const dirs = entries.filter((e) => e.type === "dir");

  const results = await Promise.all(
    dirs.map(async (dir) => {
      try {
        const url = `${RAW_BASE}/${dir.name}/SKILL.md`;
        const r = await fetch(url, {
          headers: { "User-Agent": "claude-skills-cli" },
        });

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
