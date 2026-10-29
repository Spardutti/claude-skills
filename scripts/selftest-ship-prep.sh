#!/usr/bin/env bash
[ -n "${SELFTEST_SANDBOX:-}" ] || { echo "$(basename "$0"): run it through scripts/gauntlet-selftest.sh, never on its own" >&2; exit 1; }

echo "ship-gate --scope and ship-prep.sh"
newrepo sg_prep
mkdir -p src .claude
printf 'l1\nl2\nl3\nl4\nl5\n' > src/a.ts
printf 'g\n' > src/routeTree.gen.ts
git add -A; git commit -qm base; git branch -q develop; git checkout -qb feat/p
PREP_BASE=$(git rev-parse develop)
sed -i '3s/.*/changed/' src/a.ts
printf 'b1\nb2\nb3\n' > src/b.ts
printf 't\n' > src/a.test.ts
printf 'g2\n' > src/routeTree.gen.ts
printf 'notes\n' >> README.md
mkdir -p db; printf 'FROM x\n' > Dockerfile; printf 'select 1;\n' > db/001.sql; printf 'm\n' > 'src/my file.ts'
printf '{}\n' > package-lock.json; printf '\211PNG\000\001' > logo.png
git add -A; git commit -qm work
printf 'c1\nc2\n' > src/c.ts
printf 'x\n' > .claude/x.ts

out=$(bash "$SG" --scope 2>&1)
want=$(printf 'base %s\n' "$PREP_BASE"; printf '%s\t%s\n' Dockerfile '1 (new)' README.md 2 db/001.sql '1 (new)' src/a.test.ts '1 (new)' \
  src/a.ts 3 src/b.ts '1-3 (new)' src/c.ts '1-2 (new)' 'src/my file.ts' '1 (new)' | sort)
got=$(printf '%s\n' "$out" | head -1; printf '%s\n' "$out" | sed 1d | sort)
N=$((N+1))
if [ "$got" = "$want" ]; then PASS=$((PASS+1)); echo "  ok   --scope names every changed text file with its new-side lines; generated, tooling, locks and binaries left out"
else FAIL=$((FAIL+1)); printf '  FAIL --scope output\n       want: %s\n       got:  %s\n' "$want" "$got"; fi

SP="$HERE/ship-prep.sh"
git init -q --bare "$TMP/prep-origin.git"; git remote add origin "$TMP/prep-origin.git"
git push -q origin develop develop:main 2>/dev/null
cat > bin/gh <<G
#!/bin/sh
printf '%s\n' "\$*" >> "$TMP/prep-gh-args"
case "\$1 \$2" in "auth status") exit \${PREP_GH_AUTH:-0} ;; "pr view") echo "OPEN #12 https://x/pull/12" ;; esac
G
chmod +x bin/gh; rm -f "$TMP/prep-gh-args"
mkdir -p "$HOME/.claude"; echo 'GAUNTLET_SHIP_LOG=1' > "$HOME/.claude/gauntlet.conf"
prep_has() {  # prep_has <label> <output> <expected line>
  N=$((N+1))
  if printf '%s\n' "$2" | grep -qxF -- "$3"; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n       want line: %s\n       got: %s\n' "$1" "$3" "$2"; fi
}

out=$(bash "$SP" start 2>&1); rc=$?
prep_has "start names the branch" "$out" "branch feat/p"
prep_has "and the base, preferring the dev branch" "$out" "base develop (main main)"
prep_has "and how far it is from the base" "$out" "ahead 1, behind 0 of origin/develop"
prep_has "and every uncommitted file" "$out" "uncommitted 3"
prep_has "and whether gh is logged in" "$out" "gh logged in"
prep_has "and this branch's PR" "$out" "pr OPEN #12 https://x/pull/12"
sl_ok "start exits 0" test "$rc" = 0
sl_ok "start sets the /ship mark" bash "$HERE/ship-mark.sh" check
sl_ok "and opens the ship log" test -f "$HOME/.claude/ship-logs/open/prep-origin__feat-p.json"
sl_ok "gh is asked exactly these, in order" test "$(cat "$TMP/prep-gh-args")" = "$(printf 'auth status\npr view --json state,number,url -q .state+" #"+(.number|tostring)+" "+.url')"
out=$(PREP_GH_AUTH=1 bash "$SP" start 2>&1)
prep_has "a missing gh login is named, not a stop" "$out" "gh NOT logged in: pr, merge and release cannot run"
rm -f "/tmp/claude-ship-$(printf '%s %s' "$(cd "$(git rev-parse --git-common-dir)" && pwd)" feat/p | cksum | cut -d' ' -f1)"
bash "$SP" start | head -1 >/dev/null
sl_ok "start piped into head still sets the mark" bash "$HERE/ship-mark.sh" check

mkdir -p .claude/skills/ts .claude/skills/sql .claude/skills/plain
printf -- '---\nname: ts\nmetadata:\n  gate-paths: "*.ts"\n---\n' > .claude/skills/ts/SKILL.md
printf -- '---\nname: sql\nmetadata:\n  gate-paths: "*.rb"\n---\n' > .claude/skills/sql/SKILL.md
printf -- '---\nname: plain\n---\n' > .claude/skills/plain/SKILL.md
out=$(bash "$SP" scope 2>&1); rc=$?
prep_has "scope prints the gate's scope" "$out" "$(printf 'src/b.ts\t1-3 (new)')"
prep_has "a skill whose paths match is audited, with its files" "$out" "skill ts: audit $(printf '%s\n' src/a.test.ts src/a.ts src/b.ts src/c.ts 'src/my file.ts' | sort | paste -sd' ' -)"
prep_has "a skill whose paths match nothing is skipped" "$out" "skill sql: skip, no changed file matches *.rb"
prep_has "a skill with no paths is left to its description" "$out" "skill plain: decide from its description"
prep_has "it names the review to run" "$out" "review /code-review medium origin/develop...feat/p"
DIFF=$(printf '%s\n' "$out" | sed -n 's/^diff //p')
sl_ok "the diff file holds a committed and an untracked file" test -n "$(grep -l 'b2' "$DIFF" 2>/dev/null)" -a -n "$(grep -l 'c2' "$DIFF" 2>/dev/null)"
sl_ok "a path with a space reaches the diff" test -n "$(grep -l '^+m$' "$DIFF" 2>/dev/null)"
out=$(CLAUDE_PROJECT_DIR="$PWD/src" bash "$SP" scope 2>&1); SUBDIFF=$(printf '%s\n' "$out" | sed -n 's/^diff //p')
sl_ok "from a project in a subfolder the diff still holds the files" test -n "$(grep -l 'b2' "$SUBDIFF" 2>/dev/null)"
sl_is "the audit and review steps are started" "$HOME/.claude/ship-logs/open/prep-origin__feat-p.json" 'r.steps.audit.start && r.steps.review.start'
git checkout -qb chore/release-v9; bash "$SP" start >/dev/null 2>&1; bash "$SP" scope >/dev/null 2>&1
sl_ok "a release branch opens no log, so it starts no audit or review step" test ! -e "$HOME/.claude/ship-logs/open/prep-origin__chore-release-v9.json"
git checkout -q feat/p
git checkout -q --detach
out=$(bash "$SP" start 2>&1); rc=$?
sl_ok "a detached HEAD stops start with ship.md's message" test "$rc" = 1 -a -n "$(printf '%s' "$out" | grep 'Detached HEAD')"
git checkout -q feat/p
rm -rf bin/gh "$HOME/.claude/gauntlet.conf" "$HOME/.claude/ship-logs"
