// The one parser for a SKILL.md / command / agent frontmatter block.
//
// There used to be two — one in github.mjs, one in local.mjs — written
// differently, and they disagreed on four of five inputs:
//
//   description: "d"        github kept the quotes, local stripped them
//   category: "Q"           same
//   requires-agents: p, q   github returned [], local returned ["p","q"]
//
// So `--local` and a real install read the same file differently. The quote
// difference was masked downstream by a stripQuotes() in prompt.mjs, which is
// what let it live: the picker looked right, so nobody looked further.
//
// Behaviour kept here is local.mjs's, because it was the correct one on every
// case: quotes stripped, and both `[a, b]` and `a, b` accepted for a list.
export function parseFrontmatter(content, fallbackName) {
  const match = content.match(/^---\n([\s\S]*?)\n---/);
  if (!match) {
    return { name: fallbackName, description: "", category: "General", requiresAgents: [] };
  }
  const block = match[1];

  // A value may be quoted or bare. Descriptions are quoted in every skill this
  // repo ships, so returning the quotes is wrong for the common case, not the
  // edge one.
  const pick = (key) => {
    const m = block.match(new RegExp(`^${key}:\\s*(.+)$`, "m"));
    return m ? m[1].trim().replace(/^["']|["']$/g, "") : "";
  };

  return {
    name: pick("name") || fallbackName,
    description: pick("description"),
    category: pick("category") || "General",
    requiresAgents: parseAgentList(pick("requires-agents")),
  };
}

// `requires-agents: [a, b]` is what every command in this repo writes, but the
// brackets are YAML flow syntax rather than part of the value, so a bare
// `a, b` means the same thing and must parse the same way.
export function parseAgentList(raw) {
  if (!raw) return [];
  return raw
    .replace(/[[\]]/g, "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
}
