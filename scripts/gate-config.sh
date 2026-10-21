#!/usr/bin/env bash

GAUNTLET_MAX_LINES=200
GAUNTLET_MUTATE=""
GAUNTLET_SOURCE_EXT="ts|tsx|js|jsx|mjs|cjs|py|go|rs|java|kt|rb|php|c|h|cpp|hpp|cs|swift|gd"
GAUNTLET_IGNORE_EXT="md|mdx|txt|rst|adoc|jsonc?|ya?ml|toml|lock|cfg|ini|env|csv|tsv|sql|html|css|scss|svg|png|jpg|jpeg|gif|webp|ico|pdf|woff2?|ttf|otf|mp3|mp4|wav|zip|gz|tres|tscn|import|godot"
GAUNTLET_IGNORE_FILES="*.gen.ts *.gen.tsx *.generated.* */migrations/*.py */alembic/versions/*.py */components/ui/*.tsx */hooks/use-mobile.ts */*.config.*"
# Components are length-checked but not mutated: their mutants are class names and JSX, not
# behaviour. Override in .claude/gauntlet.conf to mutate them too.
GAUNTLET_NO_MUTATE='\.(tsx|jsx)$'

load_gauntlet_conf() {  # load_gauntlet_conf <project conf> <fallback conf>
  [ -n "${HOME:-}" ] && [ -f "$HOME/.claude/gauntlet.conf" ] && . "$HOME/.claude/gauntlet.conf"
  local conf="$1"; [ -f "$conf" ] || conf="$2"
  if [ -f "$conf" ]; then . "$conf"; fi
}

# set -f: unquoted, the list is glob-expanded before it is split, and */components/ui/*.tsx
# expanded into the very path it should match.
is_ignored() {
  set -f
  for pat in $GAUNTLET_IGNORE_FILES; do
    case "/$1" in $pat) set +f; return 0 ;; esac
  done
  set +f
  return 1
}

json_string() {
  awk 'BEGIN { ORS = "" } {
    gsub(/\033\[[0-9;?]*[ -\/]*[@-~]/, "")
    gsub(/[\001-\010\013-\037\177]/, "")  # JSON forbids raw control characters
    gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t")
    if (NR > 1) print "\\n"
    print
  }'
}
