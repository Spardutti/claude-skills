# Upgrading a Project to TypeScript 7

TypeScript 7's `tsc` is the native Go compiler: the same project type-checks 4–5×
faster. It also ships **no stable JavaScript API** (`ts.createProgram`,
`ts.parseConfigFileTextToJson` are gone until 7.1), so any tool that calls
`require("typescript")` breaks the moment `typescript` resolves to 7.

## Who Still Needs TypeScript 6

Check `package.json` before bumping. Each of these loads the old API:

- `typescript-eslint` (and `eslint-config-next`, which pulls it in) — peer `<6.1`, fails with `typescript-eslint does not support TS 7.0.`
- `@astrojs/check` — peer `^5 || ^6`
- `@stryker-mutator/core` 10.x — crashes with `ts.parseConfigFileTextToJson is not a function` (stryker-js #6111, fix in PR #6231)
- `@stryker-mutator/typescript-checker` — no workaround
- Vue, Svelte and Angular template type-checkers

None present: bump `typescript` itself. Any present: install both, side by side.

## Side by Side

```jsonc
// BAD — eslint, astro check and Stryker now load a compiler with no API
"devDependencies": { "typescript": "7.0.2" }

// GOOD — tools keep 6's API, the typecheck runs on 7
"devDependencies": {
  "typescript": "6.0.3",
  "typescript7": "npm:typescript@7.0.2"
}
```

```jsonc
// BAD — both packages ship a `tsc` bin; which one .bin/tsc links to is not yours to pick
"typecheck": "tsc --noEmit"

// GOOD — name the compiler by path
"typecheck": "node node_modules/typescript7/bin/tsc --noEmit"
```

Drop the alias and bump `typescript` once every tool above supports 7.

## What 7 Rejects In An Old tsconfig

```jsonc
// BAD — each line is now an error, and it stops the check before your code is read
"baseUrl": ".",                  // TS5102: Option 'baseUrl' has been removed
"downlevelIteration": true,      // TS5102
"target": "ES5",                 // TS5108
"paths": { "@/*": ["src/*"] }    // TS5090: Non-relative paths are not allowed

// GOOD
"target": "ES2022",
"paths": { "@/*": ["./src/*"] }
```

`types` now defaults to `[]`, so no `@types/*` package loads by itself. The symptom
is a wall of `Cannot find name 'process'` or `Cannot find namespace 'google'`:

```jsonc
// GOOD — list every global types package the code uses
"types": ["node", "google.maps", "vitest/globals"]
```

A side-effect import of CSS is now checked (`TS2882`). Vite projects add
`"vite/client"` to `types`; anything else declares it once:

```ts
// src/css.d.ts
declare module "*.css";
```

## Stryker On TypeScript 7

Until stryker-js PR #6231 ships, point Stryker at a tsconfig that does not exist.
That skips the sandbox rewrite that calls the missing API:

```json
{ "tsconfigFile": "no-tsconfig-rewrite-typescript-7-has-no-compiler-api.json" }
```

The skipped rewrite only fixes `extends` and `references` that point outside the
project. With side-by-side installs Stryker loads 6, and needs none of this.

## Rules

- Always check for the tools above before bumping `typescript` to 7.
- Always call TypeScript 7 by path in a side-by-side setup, never as bare `tsc`.
- Always remove `baseUrl` and start every `paths` target with `./`.
- Always list global types in `types`; 7 loads none by default.
- Never count an error total until the tsconfig errors are gone — they stop the check early.
- Always add the `tsconfigFile` workaround when Stryker runs on 7, and remove it once Stryker fixes #6111.
