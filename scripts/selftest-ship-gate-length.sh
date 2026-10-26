#!/usr/bin/env bash
[ -n "${SELFTEST_SANDBOX:-}" ] || { echo "$(basename "$0"): run it through scripts/gauntlet-selftest.sh, never on its own" >&2; exit 1; }

echo "ship-gate length check and the baseline"
newrepo sg_length
mkdir -p .claude/hooks src
cp "$SG" "$HERE/gate-config.sh" "$HERE/line-limit.sh" "$HERE/ship-gate-projects.sh" \
   "$HERE/ship-gate-structure.sh" "$HERE/ship-gate-files.sh" .claude/hooks/
printf 'GAUNTLET_MUTATE="echo clean"\n' > .claude/gauntlet.conf
echo '{}' > package.json
awk 'BEGIN { for (i=0;i<300;i++) print "export const x" i " = 1" }' > src/old.ts
printf '300 src/old.ts\n' > .line-limit-baseline
git add -A; git commit -qm base; git branch develop

gl() {  # gl <label> <expected exit> <expected substring>
  N=$((N+1))
  out=$(bash .claude/hooks/ship-gate.sh 2>&1); rc=$?
  if [ "$rc" = "$2" ] && case "$out" in *"$3"*) true ;; *) false ;; esac; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s — want exit %s ~ %s, got exit %s:\n%s\n' "$1" "$2" "$3" "$rc" "$(printf '%s' "$out" | sed 's/^/       /')"; fi
}

sed -i '1s/.*/export const x0 = 2/' src/old.ts
gl "an old long file that did not grow passes the length check" 0 "FILE LENGTH — ok"
echo 'export const grew = 1' >> src/old.ts
gl "an old long file that grew fails it"                         1 "src/old.ts — 301 lines, was 300"
git checkout -q src/old.ts
awk 'BEGIN { for (i=0;i<250;i++) print "export const y" i " = 1" }' > src/new.ts
gl "a new file over the limit still fails"                       1 "src/new.ts — 250 lines (limit 200)"
awk 'BEGIN { for (i=0;i<230;i++) print "export const w" i " = 1" }' > src/two.ts
N=$((N+1))
out=$(bash .claude/hooks/ship-gate.sh 2>&1)
case "$out" in
  *"Split them."*) FAIL=$((FAIL+1)); echo "  FAIL the gate lists over-limit files without line-limit's own trailer — $out" ;;
  *"src/new.ts — 250 lines"*"src/two.ts — 230 lines"*) PASS=$((PASS+1)); echo "  ok   the gate lists over-limit files without line-limit's own trailer" ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL the gate lists over-limit files without line-limit's own trailer — $out" ;;
esac

WT="$TMP/sg_length_wt"; rm -rf "$WT"; mkdir -p "$WT"
git -C "$WT" init -q; git -C "$WT" config user.email t@t.t; git -C "$WT" config user.name t
echo '{}' > "$WT/package.json"; git -C "$WT" add -A; git -C "$WT" commit -qm base; git -C "$WT" branch develop
awk 'BEGIN { for (i=0;i<240;i++) print "export const q" i " = 1" }' > "$WT/long.ts"
before=$(wc -l < .claude/gate-findings.jsonl 2>/dev/null || echo 0)
N=$((N+1))
CLAUDE_PROJECT_DIR="$WT" bash .claude/hooks/ship-gate.sh >/dev/null 2>&1
after=$(wc -l < .claude/gate-findings.jsonl 2>/dev/null || echo 0)
if [ "$after" -gt "$before" ] && [ ! -e "$WT/.claude/gate-findings.jsonl" ]; then PASS=$((PASS+1)); echo "  ok   a gate run on a worktree writes its diary next to the hooks that ran it"
else FAIL=$((FAIL+1)); echo "  FAIL a gate run on a worktree writes its diary next to the hooks that ran it — hooks' diary $before→$after, worktree: $(ls -a "$WT/.claude" 2>&1 | tr '\n' ' ')"; fi
