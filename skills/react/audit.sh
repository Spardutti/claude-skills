#!/bin/bash
# React layout audit. Path-only check (no repo-state inspection).
#
# Contract:
#   $1 = file path being written/edited (absolute or relative)
#
# Exit codes:
#   0 = pass (path is in an allowed location, or not applicable to react)
#   2 = violation (hook blocks the write with the stderr message)

FILE_PATH="$1"
if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# Not applicable if the path isn't under any src/ tree.
case "$FILE_PATH" in
  *src/*) ;;
  *) exit 0 ;;
esac

# Strip everything up to and including the last "src/" — this is the path
# relative to the React source root, regardless of monorepo nesting.
# Prefix "/" so the pattern matches when the path begins with "src/".
REL="/${FILE_PATH}"
REL="${REL##*/src/}"

# Allowed: root-allowlist files, or under features/<name>/, shared/, app/.
case "$REL" in
  main.tsx|App.tsx|App.css|index.css|vite-env.d.ts)
    exit 0
    ;;
  features/*/*|shared/*|app/*)
    exit 0
    ;;
esac

cat >&2 <<EOF
React layout violation: $FILE_PATH

This file would land at \`src/$REL\`, which doesn't match the layout the react
skill prescribes:

  src/
    features/<name>/...   # feature-scoped code (components, hooks, api, types)
    shared/...            # cross-feature reusable code
    app/...               # app composition (routes, providers, layout shell)
    main.tsx              # entry
    App.tsx               # root component
    index.css | App.css | vite-env.d.ts

Move the file before writing:
  - Belongs to one feature       → src/features/<feature>/...
  - Needed by 2+ features        → src/shared/...
  - App composition / routing    → src/app/...

If this project intentionally uses a different layout, opt out of the react
audit for this repo:
  echo react >> .claude/skill-audit-ignore
EOF
exit 2
