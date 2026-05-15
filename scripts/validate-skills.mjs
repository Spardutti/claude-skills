#!/usr/bin/env node
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

const SKILLS_DIR = "skills";
const MD_REF_RE = /\b([A-Za-z][A-Za-z0-9_-]*\.md)\b/g;

// Length caps (see CLAUDE.md "Skill File Guidelines").
const SKILL_MD_MAX = 350; // SKILL.md is always-loaded — keep it tight
const REF_MD_MAX = 500; // reference files load on demand — Anthropic's documented limit

let errors = 0;
let warnings = 0;

const skillDirs = readdirSync(SKILLS_DIR).filter((name) => {
  const p = join(SKILLS_DIR, name);
  return statSync(p).isDirectory();
});

for (const skillName of skillDirs) {
  const skillDir = join(SKILLS_DIR, skillName);
  const skillMdPath = join(skillDir, "SKILL.md");

  let skillMd;
  try {
    skillMd = readFileSync(skillMdPath, "utf-8");
  } catch {
    continue;
  }

  const skillMdLines = skillMd.split("\n").length;
  if (skillMdLines > SKILL_MD_MAX) {
    console.error(
      `✗ ${skillName}/SKILL.md is ${skillMdLines} lines — exceeds the ${SKILL_MD_MAX}-line cap for SKILL.md`,
    );
    errors++;
  }

  const allMdFiles = readdirSync(skillDir).filter((f) => f.endsWith(".md"));
  const siblings = new Set(allMdFiles.filter((f) => f !== "SKILL.md"));

  const refs = new Set();
  for (const match of skillMd.matchAll(MD_REF_RE)) {
    const name = match[1];
    if (name === "SKILL.md") continue;
    refs.add(name);
  }

  for (const ref of refs) {
    if (!siblings.has(ref)) {
      console.error(
        `✗ ${skillName}/SKILL.md references missing file: ${ref}`,
      );
      errors++;
    }
  }

  for (const sib of siblings) {
    if (!refs.has(sib)) {
      console.warn(
        `⚠ ${skillName}/${sib} exists but is not referenced from SKILL.md`,
      );
      warnings++;
    }
  }

  for (const ref of refs) {
    if (!siblings.has(ref)) continue;
    const refPath = join(skillDir, ref);
    const refContent = readFileSync(refPath, "utf-8");
    const refLines = refContent.split("\n");

    const nestedRefs = new Set();
    for (const match of refContent.matchAll(MD_REF_RE)) {
      const name = match[1];
      if (name === ref || name === "SKILL.md") continue;
      nestedRefs.add(name);
    }
    for (const nested of nestedRefs) {
      console.error(
        `✗ ${skillName}/${ref} contains nested reference to ${nested} — references must be one level deep from SKILL.md`,
      );
      errors++;
    }

    if (refLines.length > 100) {
      const firstChunk = refLines.slice(0, 30).join("\n").toLowerCase();
      if (!firstChunk.includes("## contents")) {
        console.error(
          `✗ ${skillName}/${ref} is ${refLines.length} lines but missing "## Contents" TOC in first 30 lines`,
        );
        errors++;
      }
    }

    if (refLines.length > REF_MD_MAX) {
      console.error(
        `✗ ${skillName}/${ref} is ${refLines.length} lines — exceeds the ${REF_MD_MAX}-line cap for reference files`,
      );
      errors++;
    }
  }
}

const summary = `${errors} error(s), ${warnings} warning(s)`;
if (errors > 0) {
  console.error(`\n✗ Validation failed: ${summary}`);
  process.exit(1);
}
console.log(`✓ All skill references valid (${summary})`);
