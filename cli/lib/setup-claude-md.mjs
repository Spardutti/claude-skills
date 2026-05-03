import { readFile, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";

const SKILL_BODY = `## Skills

BEFORE writing ANY code, you MUST:

1. List EVERY skill available: check \`.claude/skills/\` (project) and \`~/.claude/skills/\` (global). The system-reminder's available-skills section is a hint, not the source of truth — if it's missing or empty, still check the directories.
2. For each skill, write: [skill-name] → ACTIVATE / SKIP — [one-line reason]
3. Call Skill(name) for every skill marked ACTIVATE
4. Only THEN proceed to implementation

If you skip this evaluation, your response is INCOMPLETE and WRONG.`;

const FILE_SIZE_BODY = `## File Size Enforcement

- **Never write a file longer than 200 lines of code.** If a file would exceed 200 lines, split it into smaller modules before writing.
- This rule applies during skill evaluation: if the code you're about to write would exceed 200 lines in any single file, refactor into multiple files first.
- Skill evaluation must check this limit as part of every ACTIVATE decision.`;

const BLOCKS = [
  {
    id: "skill-evaluation",
    body: SKILL_BODY,
    legacyHeadings: ["## Skills"],
    legacyYamlMarker: "skill_evaluation:",
  },
  {
    id: "file-size",
    body: FILE_SIZE_BODY,
    legacyHeadings: ["## File Size Enforcement"],
  },
];

function wrap(id, body) {
  return `<!-- claude-skills:${id}:start -->\n${body}\n<!-- claude-skills:${id}:end -->`;
}

function spliceSentinels(content, id, replacement) {
  const start = `<!-- claude-skills:${id}:start -->`;
  const end = `<!-- claude-skills:${id}:end -->`;
  const startIdx = content.indexOf(start);
  if (startIdx === -1) return null;
  const endIdx = content.indexOf(end, startIdx);
  if (endIdx === -1) return null;
  return content.slice(0, startIdx) + replacement + content.slice(endIdx + end.length);
}

function spliceLegacyHeading(content, heading, replacement) {
  const lines = content.split("\n");
  const startIdx = lines.findIndex((l) => l.trim() === heading);
  if (startIdx === -1) return null;
  let endIdx = lines.length;
  for (let i = startIdx + 1; i < lines.length; i++) {
    if (lines[i].startsWith("## ")) {
      endIdx = i;
      break;
    }
  }
  return joinSplice(lines, startIdx, endIdx, replacement);
}

function spliceLegacyYaml(content, marker, replacement) {
  const lines = content.split("\n");
  const startIdx = lines.findIndex((l) => l.startsWith(marker));
  if (startIdx === -1) return null;
  let endIdx = lines.length;
  for (let i = startIdx + 1; i < lines.length; i++) {
    const line = lines[i];
    if (line.length > 0 && !/^\s/.test(line)) {
      endIdx = i;
      break;
    }
  }
  return joinSplice(lines, startIdx, endIdx, replacement);
}

function joinSplice(lines, startIdx, endIdx, replacement) {
  const before = lines.slice(0, startIdx).join("\n").replace(/\s+$/, "");
  const after = lines.slice(endIdx).join("\n").replace(/^\s+/, "");
  const parts = [before, replacement, after].filter((s) => s.length > 0);
  return parts.join("\n\n");
}

function applyBlock(content, block) {
  const wrapped = wrap(block.id, block.body);
  let next = spliceSentinels(content, block.id, wrapped);
  if (next !== null) return { content: next, action: `replaced ${block.id}` };
  for (const heading of block.legacyHeadings ?? []) {
    next = spliceLegacyHeading(content, heading, wrapped);
    if (next !== null) return { content: next, action: `migrated ${block.id}` };
  }
  if (block.legacyYamlMarker) {
    next = spliceLegacyYaml(content, block.legacyYamlMarker, wrapped);
    if (next !== null) return { content: next, action: `migrated ${block.id}` };
  }
  const base = content.replace(/\s+$/, "");
  const merged = base.length > 0 ? base + "\n\n" + wrapped : wrapped;
  return { content: merged, action: `added ${block.id}` };
}

export async function setupClaudeMd(targetDir = process.cwd()) {
  const claudeMdPath = join(resolve(targetDir), "CLAUDE.md");

  let content = "";
  try {
    content = await readFile(claudeMdPath, "utf-8");
  } catch {
    // File doesn't exist — will create
  }

  const actions = [];
  for (const block of BLOCKS) {
    const result = applyBlock(content, block);
    content = result.content;
    actions.push(result.action);
  }

  await writeFile(claudeMdPath, content.replace(/\s+$/, "") + "\n", { mode: 0o644 });
  console.log(`  CLAUDE.md: ${actions.join(", ")}.`);
}
