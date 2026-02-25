import { checkbox, Separator } from "@inquirer/prompts";
import chalk from "chalk";

const CATEGORY_ORDER = ["Frontend", "TypeScript", "Backend", "Quality", "General"];

function humanName(skill) {
  return skill.name
    .replace(/-/g, " ")
    .replace(/\b\w/g, (c) => c.toUpperCase());
}

function stripQuotes(str) {
  return str.replace(/^["']|["']$/g, "");
}

export async function promptSkillSelection(skills) {
  // Group skills by category preserving order
  const grouped = new Map();
  for (const cat of CATEGORY_ORDER) {
    const items = skills.filter((s) => s.category === cat);
    if (items.length > 0) grouped.set(cat, items);
  }

  // Build choices with separators
  const choices = [];
  for (const [category, items] of grouped) {
    choices.push(new Separator(`── ${category} ${"─".repeat(35 - category.length)}`));
    for (const skill of items) {
      choices.push({
        name: chalk.bold(humanName(skill)),
        value: skill,
        description: chalk.dim(stripQuotes(skill.description)),
      });
    }
  }

  const theme = {
    icon: { cursor: ">" },
    style: {
      highlight: (text) => chalk.cyan(text),
      renderSelectedChoices: (selected) =>
        selected.map((s) => chalk.cyan(humanName(s))).join(", "),
    },
  };

  const selected = await checkbox({
    message: "Select skills to install:",
    choices,
    theme,
  });

  return selected;
}
