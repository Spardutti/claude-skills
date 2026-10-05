#!/usr/bin/env bash
# Cases for the loading gate: Bash as a way of writing files, and which files it gates.
# Sourced by gauntlet-selftest.sh; shares its $HERE, $TMP, $N, $PASS, $FAIL.

# Write|Edit|MultiEdit is not the only way to change a file. A session edited
# twelve source files through `python3 - <<'PY'` in Bash and neither gate fired.
echo "skill gate covers Bash"
newrepo sg_bash
mkdir -p .claude/skills/demo
printf -- '---\nname: demo\n---\n## Rules\n- x\n' > .claude/skills/demo/SKILL.md
node -e "import('$HERE/../cli/lib/setup-hook.mjs').then(m=>m.setupHook('$PWD'))" >/dev/null 2>&1
SKG=".claude/hooks/skill-gate.sh"

gate() {  # gate <label> <deny|allow> <tool> <command>
  N=$((N+1))
  rm -f /tmp/claude-skill-gate-gt$RUN
  out=$(printf '%s' "{\"session_id\":\"gt$RUN\",\"tool_name\":\"$3\",\"tool_input\":{\"command\":\"$4\"}}" | bash "$SKG")
  got=allow; case "$out" in *deny*) got=deny ;; esac
  if [ "$got" = "$2" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s — want %s, got %s\n' "$1" "$2" "$got"; fi
}

gate "a heredoc into python is gated" deny Bash "python3 - <<'PY'"
gate "a redirect into a file is gated" deny Bash "cat > src/foo.ts"
gate "sed -i is gated" deny Bash "sed -i 's/a/b/' x.ts"
gate "a read-only command is not gated" allow Bash "git status --short"
# "add api/x.py" holds the text "dd ", so every git add of code read as the dd tool.
gate "git add of a source file is not gated" allow Bash "git add api/x.py"
gate "cp is still gated" deny Bash "cp a.ts src/b.ts"
gate "dd is still gated" deny Bash "dd if=a.ts of=src/b.ts"
gate "a redirect to /dev/null is not a write" allow Bash "npm test 2>/dev/null"
gate "the command that clears the gate is never gated" allow Bash "touch /tmp/claude-skill-gate-gt$RUN"

# Skills are about code. A repo full of PLAN_*.md hit this gate on every write.
gatef() {  # gatef <label> <deny|allow> <file_path>
  N=$((N+1))
  rm -f /tmp/claude-skill-gate-gt$RUN
  out=$(printf '%s' "{\"session_id\":\"gt$RUN\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$3\"}}" | bash "$SKG")
  got=allow; case "$out" in *deny*) got=deny ;; esac
  if [ "$got" = "$2" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s — want %s, got %s\n' "$1" "$2" "$got"; fi
}

gatef "writing a plan document is not gated" allow "PLAN_notas.md"
gatef "writing a source file is gated" deny "src/lib/expenses.ts"
gatef "config files stay gated" deny "tsconfig.json"
gatef "an /optimize benchmark script is not gated" allow "/tmp/claude-optimize-api/bench.sh"
gatef "other scratch code in /tmp stays gated" deny "/tmp/scratch/bench.sh"
gate "a heredoc writing markdown is not gated" allow Bash "cat > PREPLAN_x.md <<EOF"
gate "a heredoc writing source is gated" deny Bash "cat > src/a.ts <<EOF"# An unescaped dot made "each" read as a .h file and "projects-" as a .ts file,
# so every prose heredoc looked like it named code.
gate "a heredoc writing an adoc is not gated" allow Bash "cat > docs/guide.adoc <<EOF each step"
gate "a doc under a projects- folder is not gated" allow Bash "cat > /home/u/projects-notes/README.md <<EOF"
gate "2>&1 is not a write" allow Bash "pytest -q 2>&1 | tail -3"
gate "a real redirect beside 2>&1 is still gated" deny Bash "make 2>&1 > src/out.ts"
gatef "a session scratchpad file is not gated" allow "/tmp/claude-1000/-home-u-p/abc/scratchpad/mock.html"
