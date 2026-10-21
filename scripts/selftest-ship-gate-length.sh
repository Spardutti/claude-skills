#!/usr/bin/env bash

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
