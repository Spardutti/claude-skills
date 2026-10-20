import { readFile } from "node:fs/promises";
import { join } from "node:path";

// Stryker rewrites tsconfig through TypeScript's JS API, which 7 no longer has
// (stryker-js#6111). Naming a file that does not exist skips the rewrite.
export const TS7_TSCONFIG = "no-tsconfig-rewrite-typescript-7-has-no-compiler-api.json";

async function readJson(p) {
  try {
    return JSON.parse(await readFile(p, "utf-8"));
  } catch {
    return null;
  }
}

// A range like "catalog:" or "workspace:*" carries no number, so the installed copy wins.
export async function usesTs7(...dirs) {
  for (const d of dirs) {
    const installed = await readJson(join(d, "node_modules", "typescript", "package.json"));
    const pkg = await readJson(join(d, "package.json"));
    const version = installed?.version ?? pkg?.devDependencies?.typescript ?? pkg?.dependencies?.typescript;
    const major = Number(version?.match(/\d+/)?.[0]);
    if (major) return major >= 7;
  }
  return false;
}
