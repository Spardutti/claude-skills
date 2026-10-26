#!/usr/bin/env bash

echo "ship-prep.sh secrets, merge, land and release"
newrepo sg_stages
SP="$HERE/ship-prep.sh"
printf 'a\n' > a.ts; git add -A; git commit -qm "chore: base"
git init -q --bare "$TMP/stages-origin.git"; git remote add origin "$TMP/stages-origin.git"
git branch -q develop; git push -q origin develop develop:main 2>/dev/null
git checkout -qb feat/s
cat > bin/gh <<G
#!/bin/sh
printf '%s\n' "\$*" >> "$TMP/stages-gh-args"
case "\$1 \$2" in "pr view") echo "\${STAGES_PR:-7|false|MERGEABLE|APPROVED|||develop|feat/s}" ;; "pr merge") exit 0 ;; esac
G
chmod +x bin/gh
st_ok() {  # st_ok <label> <want exit> <want line> <got exit> <got output>
  N=$((N+1))
  if [ "$4" = "$2" ] && printf '%s\n' "$5" | grep -qF -- "$3"; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s — want exit %s and "%s"\n       got exit %s: %s\n' "$1" "$2" "$3" "$4" "$5"; fi
}

printf 'b\n' >> a.ts
out=$(bash "$SP" secrets 2>&1); st_ok "a clean diff has no secrets" 0 "secrets none" $? "$out"
printf 'key = "AKIAABCDEFGHIJKLMNOP"\n' > conf.ts
out=$(bash "$SP" secrets 2>&1); st_ok "an AWS key in a new file stops the commit" 1 "AKIAABCDEFGHIJKLMNOP" $? "$out"
rm conf.ts; printf 'X=1\n' > .env
out=$(bash "$SP" secrets 2>&1); st_ok "a .env file stops the commit by name" 1 "file .env" $? "$out"
rm .env; printf 'X=\n' > .env.example
out=$(bash "$SP" secrets 2>&1); st_ok "an env template is not a secret" 0 "secrets none" $? "$out"
git add .env.example; git commit -qm "chore: env template"; printf 'X=1\n' > .env; git add -f .env; git commit -qm "chore: oops"; git rm -q .env
out=$(bash "$SP" secrets 2>&1); st_ok "deleting a .env is not a secret" 0 "secrets none" $? "$out"
git commit -qm "chore: drop .env"; git checkout -q develop
out=$(bash "$SP" secrets 2>&1); st_ok "a commit on a protected branch stops" 1 "protected branch develop" $? "$out"
git checkout -q feat/s

rm -f "$TMP/stages-gh-args"
out=$(bash "$SP" merge 7 2>&1); st_ok "a clean PR may merge" 0 "merge ok #7" $? "$out"
st_ok "gh is asked for the PR's merge facts" 0 "pr view 7 --json number,isDraft,mergeable,reviewDecision,statusCheckRollup,baseRefName,headRefName -q" 0 "$(cat "$TMP/stages-gh-args")"
out=$(STAGES_PR='7|true|CONFLICTING|REVIEW_REQUIRED|lint|e2e|develop|feat/s' bash "$SP" merge 7 2>&1)
st_ok "every reason not to merge is named" 1 "merge STOP #7: draft; conflicts with the base; CI failing: lint; review: REVIEW_REQUIRED; CI still running: e2e;" $? "$out"

rm -f "$TMP/stages-gh-args"
git push -q -u origin feat/s 2>/dev/null
out=$(bash "$SP" land 7 2>&1); st_ok "land merges and returns to the base" 0 "landed #7; now on develop" $? "$out"
st_ok "a feature lands squashed, its branch deleted" 0 "pr merge 7 --squash --delete-branch" 0 "$(sed -n 2p "$TMP/stages-gh-args")"
rm -f "$TMP/stages-gh-args"
out=$(bash "$SP" land 8 merge 2>&1); st_ok "a release lands as a merge commit" 0 "landed #8" $? "$out"
st_ok "and keeps its branch" 0 "pr merge 8 --merge" 0 "$(sed -n 2p "$TMP/stages-gh-args")"
out=$(STAGES_PR='30|false|MERGEABLE|APPROVED|||main|hotfix/x' bash "$SP" land 30 2>&1); st_ok "a hotfix lands back on the PR's own base" 0 "now on main" $? "$out"
git checkout -q develop; git checkout -qb feat/wt; git worktree add -q "$TMP/stages-wt" -b feat/in-wt >/dev/null 2>&1
git -C "$TMP/stages-wt" push -q origin feat/in-wt 2>/dev/null; rm -f "$TMP/stages-gh-args"
out=$(STAGES_PR='9|false|MERGEABLE|APPROVED|||develop|feat/in-wt' CLAUDE_PROJECT_DIR="$TMP/stages-wt" bash "$SP" land 9 2>&1)
st_ok "a worktree lands without switching branch" 0 "this is a worktree" $? "$out"
st_ok "and merges without gh's local branch switch" 0 "pr merge 9 --squash" 0 "$(sed -n 2p "$TMP/stages-gh-args")"
N=$((N+1)); if [ -z "$(git ls-remote origin feat/in-wt)" ] && [ "$(sed -n 2p "$TMP/stages-gh-args")" = "pr merge 9 --squash" ]; then PASS=$((PASS+1)); echo "  ok   and deletes the merged branch on origin itself"; else FAIL=$((FAIL+1)); echo "  FAIL and deletes the merged branch on origin itself"; fi
git worktree remove --force "$TMP/stages-wt" >/dev/null 2>&1; git checkout -q develop
out=$(STAGES_PR='7|true|MERGEABLE|APPROVED|||develop|feat/s' bash "$SP" land 7 2>&1); st_ok "land refuses what merge refuses" 1 "draft" $? "$out"

git tag v1.2.3
out=$(bash "$SP" release 2>&1); st_ok "no commits since the tag stops the release" 1 "nothing to release" $? "$out"
git commit -q --allow-empty -m "fix: one"; out=$(bash "$SP" release 2>&1)
st_ok "a fix suggests a patch" 0 "suggest v1.2.4" $? "$out"
git commit -q --allow-empty -m "feat(ui): two"; out=$(bash "$SP" release 2>&1)
st_ok "a feat suggests a minor" 0 "suggest v1.3.0" $? "$out"
st_ok "and lists the commits since the tag" 0 "  feat(ui): two" 0 "$out"
git commit -q --allow-empty -m "refactor: three" -m "BREAKING CHANGE: gone"; out=$(bash "$SP" release 2>&1)
st_ok "a breaking change suggests a major" 0 "suggest v2.0.0" $? "$out"
printf '#!/bin/sh\nexit 1\n' > bin/bc; chmod +x bin/bc; out=$(bash "$SP" release 2>&1); rm -f bin/bc
st_ok "the version math needs no bc" 0 "suggest v2.0.0" $? "$out"
git checkout -qb side; git commit -q --allow-empty -m "chore: release on main"; git tag v2.4.0; git checkout -q develop
git commit -q --allow-empty -m "fix: after the release"; out=$(bash "$SP" release 2>&1)
st_ok "the newest tag counts even when it sits on another branch" 0 "suggest v2.4.1" $? "$out"
git tag -d v1.2.3 v2.4.0 >/dev/null; git tag v0.4.1; git commit -q --allow-empty -m "feat!: four"; out=$(bash "$SP" release 2>&1)
st_ok "before 1.0, a breaking change bumps the minor" 0 "suggest v0.5.0" $? "$out"
rm -f bin/gh
