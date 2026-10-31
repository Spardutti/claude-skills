#!/usr/bin/env bash

INPUT=$(cat)
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
TOP=$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null) || exit 0
PREFIX=$(git -C "$PROJECT_DIR" rev-parse --show-prefix)
export GIT_OPTIONAL_LOCKS=0

changed_files() {
  { git -c core.quotepath=off diff --name-only --relative HEAD 2>/dev/null
    git -c core.quotepath=off ls-files --others --exclude-standard
  } | while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done | sort -u
}

# The seen list judges each file version once, so a known failure does not block every later command.
check_dir() (
  cd "$1" || exit 0
  local seen paths now fresh f hashes
  seen=$(git rev-parse --git-path claude-bash-check-seen)
  paths=$(changed_files)
  [ -n "$paths" ] && hashes=$(printf '%s\n' "$paths" | git hash-object --stdin-paths)
  now=$([ -n "$paths" ] && paste -d' ' <(printf '%s\n' "$hashes") <(printf '%s\n' "$paths"))
  fresh=$(printf '%s\n' "$now" | grep -Fxvf "$([ -f "$seen" ] && echo "$seen" || echo /dev/null)")
  printf '%s\n' "$now" > "$seen"
  printf '%s\n' "$fresh" | while read -r _ f; do
    [ -n "$f" ] || continue
    printf '{"tool_input":{"file_path":"%s/%s"}}' "$PWD" "$f" \
      | CLAUDE_PROJECT_DIR="$PWD" bash "$HERE/edit-check.sh" 2>&1 >/dev/null
  done
)

# A worktree counts only when this command names it, so another session's files never block this one.
FAILS=""
while IFS= read -r wt; do
  case "$INPUT $TOP" in *"$wt"*) ;; *) continue ;; esac
  dir="$wt/$PREFIX"
  [ -d "$dir" ] && FAILS="$FAILS$(check_dir "$dir")"
done < <(git -C "$TOP" worktree list --porcelain | sed -n 's/^worktree //p')

[ -z "$FAILS" ] && exit 0
printf 'A shell command changed files that break the edit rules:\n%s\n' "$FAILS" >&2
exit 2
