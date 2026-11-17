#!/usr/bin/env bash

GAUNTLET_MAX_LINES=200
GAUNTLET_KIND_FOLDERS="components|hooks|api|queries|schemas|types|utils|stores|test"
GAUNTLET_MUTATE=""
GAUNTLET_LAYOUT="${GAUNTLET_LAYOUT:-}"
GAUNTLET_SOURCE_EXT="ts|tsx|js|jsx|mjs|cjs|py|go|rs|java|kt|rb|php|c|h|cpp|hpp|cs|swift|gd"
GAUNTLET_IGNORE_EXT="md|mdx|txt|rst|adoc|jsonc?|ya?ml|toml|lock|cfg|ini|env|csv|tsv|sql|html|css|scss|svg|png|jpg|jpeg|gif|webp|ico|pdf|woff2?|ttf|otf|mp3|mp4|wav|zip|gz|tres|tscn|import|godot"
GAUNTLET_IGNORE_FILES="*.gen.ts *.gen.tsx *.generated.* */migrations/*.py */alembic/versions/*.py */components/ui/*.tsx */hooks/use-mobile.ts */*.config.*"
# Components are length-checked but not mutated: their mutants are class names and JSX, not
# behaviour. Override in .claude/gauntlet.conf to mutate them too.
GAUNTLET_NO_MUTATE='\.(tsx|jsx)$'
# The /ship log is off unless a conf sets GAUNTLET_SHIP_LOG=1; every project writes to one folder.
GAUNTLET_SHIP_LOG=""
GAUNTLET_SHIP_LOG_DIR="${HOME:-}/.claude/ship-logs"

load_gauntlet_conf() {  # load_gauntlet_conf <project conf> <fallback conf>
  [ -n "${HOME:-}" ] && [ -f "$HOME/.claude/gauntlet.conf" ] && . "$HOME/.claude/gauntlet.conf"
  local conf="$1"; [ -f "$conf" ] || conf="$2"
  if [ -f "$conf" ]; then . "$conf"; fi
  normalize_lists
}

# A list setting takes spaces, commas, | or new lines; regex lists are joined with |, glob lists with spaces.
normalize_lists() {
  local n
  for n in GAUNTLET_KIND_FOLDERS GAUNTLET_SOURCE_EXT GAUNTLET_IGNORE_EXT GAUNTLET_CODE_EXT; do
    [ -n "${!n:-}" ] && printf -v "$n" '%s' "$(printf '%s' "${!n}" | tr ', \n\t' '||||' | tr -s '|' | sed 's/^|//; s/|$//')"
  done
  for n in GAUNTLET_IGNORE_FILES GAUNTLET_LAYOUT; do
    [ -n "${!n:-}" ] && printf -v "$n" '%s' "$(printf '%s' "${!n}" | tr ',|\n\t' '    ')"
  done
  return 0
}

skill_field() {  # skill_field <SKILL.md> <key pattern> — its first value, quotes stripped
  sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1 | sed "s/^[\"']//; s/[\"']\$//"
}

# Claude Code writes gate-paths gitignore-style. A case glob has no **, but * already crosses /
# here, so dropping the **/ prefix is equivalent. set -f keeps the globs from matching real files.
skill_hits() {  # skill_hits <gate-paths> <files...> — the files those globs match
  local g t globs
  set -f
  globs=$(printf '%s' "$1" | tr ',' ' ' | sed 's!\*\*/!!g')
  for t in "${@:2}"; do
    for g in $globs; do
      case "$g" in \**|/*) ;; *) g="*$g" ;; esac
      case "$t" in $g) printf '%s\n' "$t"; break ;; esac
    done
  done
  set +f
}

json_field() {  # json_field <json> <key> — a flat string value; \" is unescaped, \n is kept as two characters
  printf '%s' "$1" | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"([^\"\\\\]|\\\\.)*\"" | head -1 \
    | sed -E 's/^[^:]*:[[:space:]]*"//; s/"$//; s/\\"/"/g'
}

# set -f: unquoted, the list is glob-expanded before it is split, and */components/ui/*.tsx
# expanded into the very path it should match.
matches_any() {  # matches_any <path> <globs>
  set -f
  for pat in $2; do
    case "$1" in $pat) set +f; return 0 ;; esac
  done
  set +f
  return 1
}

is_ignored() { matches_any "/$1" "$GAUNTLET_IGNORE_FILES"; }

# Every diary sits in the .claude that holds the hooks writing it, so a worktree or a
# subfolder session still shares one set. Outside .claude/hooks (this repo's scripts/), the project.
diary_dir() {  # diary_dir <script dir>
  case "$1" in */.claude/hooks) dirname "$1" ;; *) printf '%s/.claude' "${CLAUDE_PROJECT_DIR:-$PWD}" ;; esac
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

# Prints the changed code files whose content differs from the last green run, and stages
# this run's hashes in <marker>.next. A file reverted since then counts as changed too.
since_green() {  # since_green <marker> <project dir> <changed code files>
  local old="" f
  [ "$(head -1 "$1" 2>/dev/null)" = "$2" ] && old=$(tail -n +2 "$1")
  { printf '%s\n' "$2"
    { printf '%s\n' "$3"; printf '%s\n' "$old" | cut -f2 | while IFS= read -r f; do [ -e "$f" ] && printf '%s\n' "$f"; done; } \
      | sort -u | while IFS= read -r f; do
        [ -n "$f" ] && printf '%s\t%s\n' "$(git hash-object -- "$f" 2>/dev/null || echo gone)" "$f"
      done; } > "$1.next"
  awk -F'\t' 'NR == FNR { old[$2] = $1; next } FNR > 1 && old[$2] != $1 { print $2 }' \
    <(printf '%s\n' "$old") "$1.next" | grep .
}
