#!/usr/bin/env bash
# Structural checks on the repo itself: that what a file declares is what the
# repo actually has. Both of these caught a real gap the first time they ran.
# Sourced by gauntlet-selftest.sh; shares its $HERE, $TMP, $N, $PASS, $FAIL.


# --------------------------------------------- every embedded script has a source
# Four of the seven hook scripts had a file in scripts/ and were compared against
# it by preflight. The other three — the skill gate, its automark, and the
# application gate — existed ONLY as template literals inside setup-hook.mjs. So
# the most-edited hook in the repo was the one with no source of truth: every
# change to it was made by editing an escaped string, and no check could tell
# whether the installed copy still matched anything.
#
# preflight only compares the files it is told to. This asserts the list is
# complete, which is the part that was wrong.
echo "every installed hook has a source file, and ships"
SH="$HERE/../cli/lib/setup-hook.mjs"
PKG="$HERE/../cli/package.json"
for fn in $(grep -o '^const [A-Z_]*_FILENAME = "[^"]*"' "$SH" | grep -v 'LEGACY_' | sed 's/.*"\(.*\)"/\1/'); do
  N=$((N+1))
  if [ ! -f "$HERE/../scripts/$fn" ]; then
    FAIL=$((FAIL+1)); printf '  FAIL %s is installed with no scripts/%s behind it\n' "$fn" "$fn"
  # Reading from disk only works if the file is in the published tarball. A
  # script added to scripts/ and not to prepack installs from a clone and
  # 404s for everyone else, and no test that runs from the repo would notice.
  elif ! grep -q "scripts/$fn" "$PKG"; then
    FAIL=$((FAIL+1)); printf '  FAIL %s is not copied into the package by prepack\n' "$fn"
  else
    PASS=$((PASS+1)); printf '  ok   %s <- scripts/%s, packed\n' "$fn" "$fn"
  fi
done

# ------------------------------------------- a declared agent that nothing invokes
# ship.md declared gauntlet-skills, described the skills audit as one of "the three
# things nothing else does", and never contained a step that ran it. It shipped
# that way for months: the agent existed, the CLI installed it, and no command
# ever called it. Four forms went out on useActionState in a repo whose React
# skill routes to a FORMS.md naming React Hook Form as the default.
#
# A name in requires-agents that appears nowhere else in the file is the whole
# signature of that bug, and it is cheap to assert.
echo "every declared agent is actually invoked"
for f in "$HERE"/../commands/*.md; do
  req=$(sed -n 's/^requires-agents:[[:space:]]*\[\(.*\)\]/\1/p' "$f" | tr -d ' ' | tr ',' ' ')
  [ -z "$req" ] && continue
  for a in $req; do
    N=$((N+1))
    # One reference is the frontmatter declaring it. A command that uses the
    # agent names it again in the body.
    refs=$(grep -c -- "$a" "$f")
    if [ "$refs" -gt 1 ]; then
      PASS=$((PASS+1)); printf '  ok   %s invokes %s\n' "$(basename "$f")" "$a"
    else
      FAIL=$((FAIL+1)); printf '  FAIL %s declares %s and never invokes it\n' "$(basename "$f")" "$a"
    fi
  done
done

# Catalog fetching has its own file — it is about the CLI talking to GitHub,
# not about the gauntlet, and this file is the repo's largest debt.
# parseFrontmatter existed twice — once in github.mjs, once in local.mjs — with
# different implementations that disagreed on four of five inputs. A real
# install and a --local install read the same file differently, and the quote
# difference was masked downstream by a stripQuotes() in prompt.mjs, which is
# what let it live: the picker looked right, so nobody looked further.
#
# One parser now. These assert the behaviour that was kept, not merely that a
# function exists.
echo "frontmatter parsing"
fm() {  # fm <label> <content> <expected JSON>
  N=$((N+1))
  # Via the environment, not argv: a value starting with --- is read by node as
  # an option and the process dies before the test runs.
  got=$(FM_INPUT="$2" node -e "
    import('$HERE/../cli/lib/frontmatter.mjs').then((m) =>
      console.log(JSON.stringify(m.parseFrontmatter(process.env.FM_INPUT, 'fb'))));
  " 2>&1)
  if [ "$got" = "$3" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n       want %s\n       got  %s\n' "$1" "$3" "$got"; fi
}

fm "a quoted description loses its quotes" \
  '---
name: a
description: "d"
---' \
  '{"name":"a","description":"d","category":"General","requiresAgents":[]}'

fm "a quoted category loses its quotes too" \
  '---
name: c
category: "Q"
---' \
  '{"name":"c","description":"","category":"Q","requiresAgents":[]}'

# Both spellings mean one list. github.mjs used to return [] for the bare form,
# so a command written that way installed none of the agents it declares.
fm "a bracketed agent list parses" \
  '---
name: a
requires-agents: [p, q]
---' \
  '{"name":"a","description":"","category":"General","requiresAgents":["p","q"]}'

fm "and a bare one parses the same" \
  '---
name: b
requires-agents: p, q
---' \
  '{"name":"b","description":"","category":"General","requiresAgents":["p","q"]}'

fm "no frontmatter falls back to the filename" \
  'no frontmatter at all' \
  '{"name":"fb","description":"","category":"General","requiresAgents":[]}'

# The point of one parser is that both callers get the same answer. Assert it
# rather than trusting the import.
N=$((N+1))
same=$(node -e "
  Promise.all([
    import('$HERE/../cli/lib/github.mjs'),
    import('$HERE/../cli/lib/local.mjs'),
    import('$HERE/../cli/lib/frontmatter.mjs'),
  ]).then(() => {
    const fs = require('fs');
    const g = fs.readFileSync('$HERE/../cli/lib/github.mjs', 'utf8');
    const l = fs.readFileSync('$HERE/../cli/lib/local.mjs', 'utf8');
    const dup = /function parseFrontmatter/;
    console.log(dup.test(g) || dup.test(l) ? 'DUPLICATED' : 'single');
  });
" 2>&1)
if [ "$same" = "single" ]; then
  PASS=$((PASS+1)); printf '  ok   %s\n' "neither caller keeps its own copy"
else
  FAIL=$((FAIL+1)); printf '  FAIL %s — got: %s\n' "neither caller keeps its own copy" "$same"
fi
