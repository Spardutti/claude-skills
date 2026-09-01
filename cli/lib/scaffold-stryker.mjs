// Stryker setup, written rather than printed.
//
// The CLI used to print five steps and leave them to the reader. Every project
// then started with the same 40% of a first React run being class-name noise —
// mutants on `className` strings and `cn()` ternaries that cannot be killed
// without asserting on the stylesheet. Un-closeable findings are what teach
// people to --force, so the ignorer is not an optional extra; it is the
// difference between a gate that gets used and one that gets bypassed.
//
// Two things stay printed, deliberately. Installing the packages touches the
// lockfile and the network. Editing an existing vitest config means parsing
// someone's plugins, aliases and projects array, and getting it wrong breaks
// their test run rather than ours.
import { readFile, writeFile, access } from "node:fs/promises";
import { join } from "node:path";

const CONFIG = {
  $schema: "./node_modules/@stryker-mutator/core/schema/stryker-schema.json",
  testRunner: "vitest",
  plugins: ["@stryker-mutator/vitest-runner", "./stryker-classname-ignorer.mjs"],
  ignorers: ["tailwind-classnames"],
  coverageAnalysis: "perTest",
  tempDirName: ".stryker-tmp",
};

// .mjs, not .js: an app without "type": "module" in its package.json cannot
// load ESM from a .js file, and the plugin is ESM.
const IGNORER = `// Ignore by WHERE the mutant sits, not by what kind it is. Disabling the
// StringLiteral mutator globally would also stop mutating labels, keys and
// separators — strings whose value is behaviour.
import { PluginKind, declareValuePlugin } from "@stryker-mutator/api/plugin";

export const strykerPlugins = [
  declareValuePlugin(PluginKind.Ignore, "tailwind-classnames", {
    shouldIgnore(path) {
      if (path.find((p) => p.isJSXAttribute() && p.node.name.name === "className"))
        return "styling, not behaviour";
      if (path.find((p) => p.isCallExpression() && p.node.callee.name === "cn"))
        return "styling, not behaviour";
    },
  }),
];
`;

async function exists(p) {
  try {
    await access(p);
    return true;
  } catch {
    return false;
  }
}

// The ignorer imports @stryker-mutator/api, but nothing depends on it directly:
// npm's flat node_modules hoists it so the import resolves by accident, and
// pnpm's isolated store does not. The failure is one WARN PluginLoader line and
// an ignorer that never loads, so every class-name mutant comes back survived.
async function installCommand(dir, rel) {
  const pnpm = await exists(join(dir, "pnpm-lock.yaml"));
  const pkgs = "@stryker-mutator/core @stryker-mutator/vitest-runner @stryker-mutator/api";
  return pnpm
    ? `pnpm --dir ${rel || "."} add -D ${pkgs}`
    : `npm --prefix ${rel || "."} i -D ${pkgs}`;
}

// Writes only what is absent. A project that already configured Stryker its own
// way keeps it — reporting the skip is the point, so nobody thinks a file they
// are looking at came from here.
export async function scaffoldStryker(projectDir, rel) {
  const dir = rel ? join(projectDir, rel) : projectDir;
  const at = rel ? `${rel}/` : "";
  const wrote = [];
  const kept = [];
  const patched = [];
  const unreadable = [];

  // A project that already runs Stryker keeps every setting it chose. The two
  // entries that wire the ignorer in are added, because a config written before
  // the ignorer existed has no other way to learn about it — and that project is
  // the one grinding through className mutants. A config this cannot parse is
  // reported and left alone rather than rewritten from a guess.
  const configPath = join(dir, "stryker.config.json");
  if (await exists(configPath)) {
    let cfg = null;
    try {
      cfg = JSON.parse(await readFile(configPath, "utf-8"));
    } catch {
      cfg = null;
    }
    if (cfg === null) {
      unreadable.push(`${at}stryker.config.json`);
    } else if ((cfg.ignorers ?? []).includes("tailwind-classnames")) {
      kept.push(`${at}stryker.config.json`);
    } else {
      cfg.plugins = [...new Set([...(cfg.plugins ?? []), "./stryker-classname-ignorer.mjs"])];
      cfg.ignorers = [...new Set([...(cfg.ignorers ?? []), "tailwind-classnames"])];
      await writeFile(configPath, JSON.stringify(cfg, null, 2) + "\n");
      patched.push(`${at}stryker.config.json`);
    }
  } else {
    await writeFile(configPath, JSON.stringify(CONFIG, null, 2) + "\n");
    wrote.push(`${at}stryker.config.json`);
  }

  const ignorerPath = join(dir, "stryker-classname-ignorer.mjs");
  if (await exists(ignorerPath)) {
    kept.push(`${at}stryker-classname-ignorer.mjs`);
  } else {
    await writeFile(ignorerPath, IGNORER);
    wrote.push(`${at}stryker-classname-ignorer.mjs`);
  }

  // A crashed run leaves a full second copy of the project behind, so this one
  // matters even though it is one line.
  const gitignorePath = join(dir, ".gitignore");
  let gitignore = "";
  try {
    gitignore = await readFile(gitignorePath, "utf-8");
  } catch {
    // no .gitignore yet — one gets written below
  }
  if (/^\.stryker-tmp\/?$/m.test(gitignore)) {
    kept.push(`${at}.gitignore`);
  } else {
    const sep = gitignore === "" || gitignore.endsWith("\n") ? "" : "\n";
    await writeFile(gitignorePath, `${gitignore}${sep}.stryker-tmp/\n`);
    wrote.push(`${at}.gitignore`);
  }

  return {
    wrote,
    kept,
    patched,
    unreadable,
    install: await installCommand(dir, rel),
    // Stryker copies the whole project into .stryker-tmp/sandbox-*/, so every
    // test file briefly exists twice and the runner collects both. They pass,
    // so a doubled test count is the only symptom. Spread configDefaults.exclude
    // rather than assigning it, or node_modules stops being excluded.
    vitest: `${at}vitest.config.ts  exclude: [...configDefaults.exclude, "**/.stryker-tmp/**"]`,
  };
}
