#!/usr/bin/env bash
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/gate-config.sh" || { echo "ship-prep: cannot read $HERE/gate-config.sh"; exit 1; }
cd "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null || { echo "ship-prep: cannot read ${CLAUDE_PROJECT_DIR:-$PWD}"; exit 1; }

stop() { echo "ship-prep: STOP — $1"; exit 1; }

first_remote() {  # first_remote <branch...> — the first one origin has
  local b
  for b in "$@"; do git rev-parse -q --verify "origin/$b" >/dev/null && { echo "$b"; return; }; done
}

base_branch() { local dev; dev=$(first_remote develop development dev); echo "${dev:-$(first_remote main master)}"; }

start() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || stop "not a git repo."
  local branch base dirty behind ahead
  branch=$(git branch --show-current)
  [ -n "$branch" ] || stop "Detached HEAD — check out a branch first."
  if git remote | grep -qx origin; then git fetch -q origin 2>/dev/null; else echo "remote none: pr, merge and release cannot run"; fi
  base=$(base_branch)
  echo "branch $branch"
  echo "base ${base:-none} (main $(first_remote main master))"
  if ! git rev-parse -q --verify HEAD >/dev/null; then echo "commits none"
  elif [ -n "$base" ]; then
    read -r behind ahead < <(git rev-list --left-right --count "origin/$base...HEAD")
    echo "ahead $ahead, behind $behind of origin/$base"
  fi
  dirty=$(git status --porcelain)
  echo "uncommitted $(printf '%s' "$dirty" | grep -c .)"
  [ -n "$dirty" ] && printf '%s\n' "$dirty" | sed 's/^/  /'
  if gh auth status >/dev/null 2>&1; then
    echo "gh logged in"
    echo "pr $(gh pr view --json state,number,url -q '.state+" #"+(.number|tostring)+" "+.url' 2>/dev/null || echo none)"
  else
    echo "gh NOT logged in: pr, merge and release cannot run"
  fi
  bash "$HERE/ship-mark.sh" begin || stop "ship-mark.sh begin failed."
}

skills_report() {  # skills_report <files...>
  local f name paths hits
  for f in "$(diary_dir "$HERE")"/skills/*/SKILL.md; do
    [ -f "$f" ] || continue
    name=$(skill_field "$f" name); paths=$(skill_field "$f" '[[:space:]]*gate-paths')
    if [ -z "$paths" ]; then echo "skill $name: decide from its description"; continue; fi
    hits=$(skill_hits "$paths" "$@" | paste -sd' ' -)
    if [ -n "$hits" ]; then echo "skill $name: audit $hits"; else echo "skill $name: skip, no changed file matches $paths"; fi
  done
}

scope() {
  local branch scope base files=() diff f
  cd "$(git rev-parse --show-toplevel)" || stop "cannot find the repo root."
  branch=$(git branch --show-current)
  scope=$(bash "$HERE/ship-gate.sh" --scope) || stop "ship-gate.sh --scope failed: $scope"
  printf '%s\n' "$scope"
  base=$(printf '%s\n' "$scope" | sed -n '1s/^base //p')
  while IFS=$'\t' read -r f _; do [ -n "$f" ] && files+=("$f"); done < <(printf '%s\n' "$scope" | sed '1d')
  skills_report "${files[@]}"
  diff="/tmp/claude-ship-$(printf '%s %s' "$PWD" "$branch" | cksum | cut -d' ' -f1).diff"
  : > "$diff"
  if [ ${#files[@]} -gt 0 ]; then
    git diff "$base" -- "${files[@]}" >> "$diff"
    for f in "${files[@]}"; do
      git ls-files --error-unmatch "$f" >/dev/null 2>&1 || git diff --no-index /dev/null "$f" >> "$diff"
    done
  fi
  echo "diff $diff"
  echo "review /code-review medium origin/$(base_branch)...$branch"
  node "$HERE/ship-log.mjs" step audit start >/dev/null 2>&1
  node "$HERE/ship-log.mjs" step review start >/dev/null 2>&1
  return 0
}

secrets() {
  local branch names hits
  branch=$(git branch --show-current)
  case "$branch" in main|master|develop|development|dev) stop "on protected branch $branch — commit on a feature or hotfix/<desc> branch." ;; esac
  git status --short
  names=$({ git diff HEAD --name-only --diff-filter=d; git ls-files --others --exclude-standard; } 2>/dev/null \
    | grep -iE '(^|/)(\.env(\..*)?|[^/]*\.pem|[^/]*credentials[^/]*|[^/]*\.key)$' | grep -viE '\.(example|sample|template)$')
  hits=$({ git diff HEAD; git ls-files --others --exclude-standard -z | xargs -0 -r -I{} git diff --no-index /dev/null {}; } 2>/dev/null \
    | grep -E '^\+' | grep -E 'AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|xox[abprs]-[A-Za-z0-9-]{10,}|[Bb]earer [A-Za-z0-9._~+/-]{20,}' | cut -c1-120)
  [ -z "$names$hits" ] && { echo "secrets none"; return 0; }
  echo "secrets FOUND — STOP and tell the user; suggest gitleaks or git-secrets as a pre-commit guard:"
  [ -n "$names" ] && printf '%s\n' "$names" | sed 's/^/  file /'
  [ -n "$hits" ] && printf '%s\n' "$hits" | sed 's/^/  line /'
  return 1
}

CHECKS_FAILED='[.statusCheckRollup[]? | select(((.conclusion // .state) // "") | test("FAILURE|ERROR|CANCELLED|TIMED_OUT|ACTION_REQUIRED")) | (.name // .context)] | join(",")'
CHECKS_RUNNING='[.statusCheckRollup[]? | select((.status // .state // "") | test("IN_PROGRESS|QUEUED|PENDING|WAITING")) | (.name // .context)] | join(",")'
PR_JQ="[.number, .isDraft, .mergeable, (.reviewDecision // \"\"), ($CHECKS_FAILED), ($CHECKS_RUNNING), .baseRefName, .headRefName] | map(tostring) | join(\"|\")"

merge_check() {  # merge_check [pr]; sets PR_BASE and PR_HEAD
  local line n draft mergeable review failing pending why=""
  line=$(gh pr view ${1:+"$1"} --json number,isDraft,mergeable,reviewDecision,statusCheckRollup,baseRefName,headRefName -q "$PR_JQ") || stop "no open PR found."
  IFS='|' read -r n draft mergeable review failing pending PR_BASE PR_HEAD <<< "$line"
  [ "$draft" = true ] && why="$why draft;"
  [ "$mergeable" = CONFLICTING ] && why="$why conflicts with the base;"
  [ -n "$failing" ] && why="$why CI failing: $failing;"
  case "$review" in REVIEW_REQUIRED|CHANGES_REQUESTED) why="$why review: $review;" ;; esac
  [ -n "$pending" ] && why="$why CI still running: $pending;"
  [ -z "$why" ] && { echo "merge ok #$n"; return 0; }
  echo "merge STOP #$n:$why"; return 1
}

land() {  # land <pr> [squash|merge]
  local worktree=""
  [ -n "${1:-}" ] || stop "usage: ship-prep.sh land <pr> [squash|merge]"
  merge_check "$1" >/dev/null || { merge_check "$1"; exit 1; }
  [ "$(git rev-parse --git-dir)" != "$(git rev-parse --git-common-dir)" ] && worktree=1
  if [ "${2:-squash}" = merge ]; then gh pr merge "$1" --merge || stop "gh pr merge failed."
  elif [ -n "$worktree" ]; then
    # gh --delete-branch switches the local checkout, which a worktree cannot; delete the branch on origin instead.
    gh pr merge "$1" --squash || stop "gh pr merge failed."
    git push -q origin --delete "$PR_HEAD" 2>/dev/null
  else gh pr merge "$1" --squash --delete-branch || stop "gh pr merge failed."; fi
  if [ -n "$worktree" ]; then
    git fetch -q origin 2>/dev/null
    echo "landed #$1; this is a worktree, so it stays on its branch — close the session to remove it"
  else
    git checkout -q "$PR_BASE" && git pull -q --ff-only origin "$PR_BASE" 2>/dev/null
    echo "landed #$1; now on $(git branch --show-current) at $(git rev-parse --short HEAD)"
  fi
}

release() {
  local tag v major minor patch commits breaking feat next
  git fetch -q --tags origin 2>/dev/null
  tag=$(git tag --sort=-v:refname | head -1)
  [ -n "$tag" ] || { echo "tag none; suggest v0.1.0 (confirm with the user)"; return 0; }
  commits=$(git log "$tag"..HEAD --format='%s')
  [ -n "$commits" ] || stop "no commits since $tag — nothing to release."
  v=${tag##*[!0-9.]}; IFS=. read -r major minor patch <<< "$v"
  breaking=$(( $(printf '%s\n' "$commits" | grep -cE '^[a-z]+(\([^)]*\))?!:') + $(git log "$tag"..HEAD --format=%B | grep -c 'BREAKING CHANGE') ))
  feat=$(printf '%s\n' "$commits" | grep -cE '^feat(\([^)]*\))?!?:')
  if [ "$major" -ge 1 ]; then
    if [ "$breaking" -gt 0 ]; then next="$((major+1)).0.0"; elif [ "$feat" -gt 0 ]; then next="$major.$((minor+1)).0"; else next="$major.$minor.$((patch+1))"; fi
  elif [ "$breaking" -gt 0 ]; then next="0.$((minor+1)).0"
  else next="0.$minor.$((patch+1))"; fi
  echo "tag $tag"
  echo "suggest ${tag%"$v"}$next (confirm with the user)"
  printf '%s\n' "$commits" | sed 's/^/  /'
}

case "${1:-}" in
  start) start ;;
  scope) scope ;;
  secrets) secrets ;;
  merge) merge_check "${2:-}" ;;
  land) land "${2:-}" "${3:-}" ;;
  release) release ;;
  *) echo "usage: ship-prep.sh start | scope | secrets | merge [pr] | land <pr> [squash|merge] | release" >&2; exit 2 ;;
esac
