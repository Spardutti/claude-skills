import { checkbox, Separator } from "@inquirer/prompts";
import chalk from "chalk";

const CATEGORY_ORDER = ["Frontend", "Desktop", "TypeScript", "Backend", "Database", "Architecture", "Quality", "General"];
const COMMAND_CATEGORY_ORDER = ["Workflow", "General"];

function humanName(skill) {
  return skill.name
    .replace(/-/g, " ")
    .replace(/\b\w/g, (c) => c.toUpperCase());
}

function stripQuotes(str) {
  return str.replace(/^["']|["']$/g, "");
}

export async function promptSkillSelection(skills, installed = []) {
  const installedSet = new Set(installed);

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
        checked: installedSet.has(skill.dirName), // pre-check what's already installed
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

export async function promptCommandSelection(commands, installed = []) {
  const installedSet = new Set(installed);
  const grouped = new Map();
  for (const cat of COMMAND_CATEGORY_ORDER) {
    const items = commands.filter((c) => c.category === cat);
    if (items.length > 0) grouped.set(cat, items);
  }

  // Include any categories not in the order list
  for (const cmd of commands) {
    if (!COMMAND_CATEGORY_ORDER.includes(cmd.category)) {
      if (!grouped.has(cmd.category)) grouped.set(cmd.category, []);
      grouped.get(cmd.category).push(cmd);
    }
  }

  const choices = [];
  for (const [category, items] of grouped) {
    choices.push(new Separator(`── ${category} ${"─".repeat(35 - category.length)}`));
    for (const cmd of items) {
      choices.push({
        name: chalk.bold(humanName(cmd)),
        value: cmd,
        description: chalk.dim(stripQuotes(cmd.description)),
        checked: installedSet.has(cmd.fileName), // pre-check what's already installed
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
    message: "Select commands to install:",
    choices,
    theme,
  });

  return selected;
}

// Checkbox of removable items — used for catalog orphans and untracked stale content.
// `preChecked` true when the items are known-stale (manifest orphans).
export async function promptRemoval(names, message, preChecked = false) {
  if (names.length === 0) return [];
  return checkbox({
    message,
    choices: names.map((n) => ({ name: n, value: n, checked: preChecked })),
    theme: { icon: { cursor: ">" }, style: { highlight: (t) => chalk.cyan(t) } },
  });
}
