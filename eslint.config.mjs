import globals from "globals";

// One rule: a name used but never defined or imported. Splitting a module once
// shipped a call to a function left behind in the old file.
export default [
  {
    files: ["cli/**/*.mjs", "scripts/**/*.mjs"],
    languageOptions: { globals: globals.node },
    rules: { "no-undef": "error" },
  },
];
