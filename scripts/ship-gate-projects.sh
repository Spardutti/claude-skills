#!/usr/bin/env bash
# Sourced by ship-gate.sh: which project owns a file, how it runs mutmut, and
# whether a project's last clean verdict still stands.

# mutmut is installed into the project's environment, not onto PATH. Ask the
# project how to run its own tools before falling back to a bare binary.
py_mutmut() {
  d="$1"
  # Returned relative to the PROJECT, because the command runs from inside it.
  # Tests that need a database, a queue, or any other service cannot run on the
  # host: mutmut still generates every mutant and reports them all "not
  # checked", which prints exactly like a clean run. An executable .mutmut-run
  # in the project runs mutmut wherever those services are — typically
  # `docker compose run` against the app container — and takes precedence over
  # every host-local option below.
  if [ -x "$d.mutmut-run" ]; then printf './.mutmut-run\n'; return; fi
  if [ -x "$d.venv/bin/mutmut" ]; then printf './.venv/bin/mutmut\n'; return; fi
  if [ -f "$d""uv.lock" ] && command -v uv >/dev/null 2>&1; then printf 'uv run mutmut\n'; return; fi
  if [ -f "$d""poetry.lock" ] && command -v poetry >/dev/null 2>&1; then printf 'poetry run mutmut\n'; return; fi
  command -v mutmut >/dev/null 2>&1 && printf 'mutmut\n'
}

owner_of() {
  d=$(dirname "$1")
  while :; do
    if [ -f "$d/package.json" ] || [ -f "$d/pyproject.toml" ] \
       || [ -f "$d/pytest.ini" ] || [ -f "$d/setup.cfg" ]; then
      printf '%s\n' "${d#./}"; return
    fi
    [ "$d" = "." ] || [ "$d" = "/" ] && { printf '.\n'; return; }
    d=$(dirname "$d")
  done
}

# mutmut records every mutant "not checked" when it stops before testing one.
# Blaming an unreachable database for that sent one agent chasing Docker for 20 minutes.
mutmut_unchecked() {  # mutmut_unchecked <label> <base> <count> <run log>
  echo "  $1 mutmut — UNPROVEN: $3 mutant(s) were never run."
  stop='Failed to run clean test|failed to collect stats|Failed to collect list of tests|Stopping early'
  if grep -aqsE "$stop" "$4"; then
    echo "      mutmut stopped before testing a single mutant:"
    grep -aE "^(FAILED|ERROR) |^[A-Za-z]*Error: |$stop" "$4" | tail -8 | sed 's/^/        /'
    echo "      It runs the whole suite, then these tests again in one process, so a"
    echo "      test that passes alone can fail here on state an earlier test left."
    return
  fi
  echo "      They are recorded \"not checked\", so the suite proved nothing"
  echo "      about them. Usually the tests need a service this run cannot"
  echo "      reach — a database, a queue. Put an executable .mutmut-run in"
  echo "      ${2}that runs mutmut where those services are, typically"
  echo "      docker compose run against the app container; the gate uses"
  echo "      it ahead of every host-local option."
}

family_of() {  # js, py, or any when no manifest says
  o=$(owner_of "$1")
  if [ -f "$o/package.json" ]; then echo js
  elif [ -f "$o/pyproject.toml" ] || [ -f "$o/pytest.ini" ] || [ -f "$o/setup.cfg" ]; then echo py
  else echo any
  fi
}

# A project's verdict can only move when the gate or a changed file of its own
# kind moves, so fixing the API's tests no longer re-runs Stryker on two JS apps.
project_key() {  # project_key <owner> <tool>
  fam=$(family_of "$1/.")
  { printf '%s\n' "$PROJECT_DIR" "$1" "$2" "$(git rev-parse "$BASE" 2>/dev/null)" \
      "$GAUNTLET_NO_MUTATE" "$GAUNTLET_IGNORE_FILES"
    cat "$HERE/ship-gate.sh" "$HERE/ship-gate-projects.sh"
    printf '%s\n' "$CHANGED" | grep -vE '\.(md|mdx|txt|rst|adoc)$' | while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$(family_of "$f")" in "$fam"|any) printf '%s\n' "$f"; [ -f "$f" ] && cat "$f" ;; esac
    done; } | git hash-object --stdin
}
