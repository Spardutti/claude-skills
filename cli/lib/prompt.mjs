import { checkbox } from "@inquirer/prompts";

export async function promptSkillSelection(skills) {
  const selected = await checkbox({
    message: "Select skills to install:",
    choices: skills.map((skill) => ({
      name: `${skill.name} - ${skill.description}`,
      value: skill,
    })),
  });

  return selected;
}
