---
name: optimize
description: "Make one measured thing faster: fix a benchmark and a result that must not change, then change one thing per round until the goal is met"
category: Workflow
allowed-tools: Task, Bash, Read, Edit, Write, Grep, Glob
requires-agents: [optimize-suspect]
argument-hint: "<what is slow> [target, e.g. 'under 190s' or '2x']"
---

# Optimize

You make one measured job faster without changing what it proves. The method: fix a benchmark, fix a result that must not move, predict, change one thing, measure, keep or revert. Stop at the goal.

`$ARGUMENTS` names the slow job and, ideally, a target. With no target, use **2× faster** and say so.

Work in this project only. Never read into, check or change another project.

## Step 1 — The benchmark

Copy this script to `/tmp/claude-optimize-<slug>/bench.sh`, outside the repo so no round can edit it by accident. Change only `OUT`, `job` and `invariant`; the rest is what makes a round evidence rather than a claim.

```bash
#!/usr/bin/env bash
# Usage: bench.sh <round>, after writing <round>.prediction. Change only OUT, job and invariant.
OUT=/tmp/claude-optimize-api
ROUND=${1:?usage: bench.sh <round>}
P="$OUT/$ROUND.prediction"
[ -s "$P" ] || { echo "no prediction for $ROUND: write $P before running" >&2; exit 3; }
chmod a-w "$P"

job() {
  rm -rf mutants
  ./.mutmut-run run 'app.expenses.commands.x*' 'app.postings.earmark.x*' > "$OUT/$ROUND.log" 2>&1
}
invariant() {
  ./.mutmut-run results --all true | grep -E '^ +app\.' | sort
}

SECONDS=0
job
T=$SECONDS
invariant > "$OUT/$ROUND.results"
N=$(grep -c . "$OUT/$ROUND.results")
[ "$N" -gt 0 ] || { echo "empty invariant: $ROUND not recorded" >&2; exit 4; }
H=$(sha256sum < "$OUT/$ROUND.results" | cut -c1-12)
printf '%s\t%ss\t%s items\t%s\t%s\n' "$ROUND" "$T" "$N" "$H" "$(cat "$P")" | tee -a "$OUT/rounds.log"
```

- **No prediction file, no run.** It exits 3 before timing anything, and locks the file read-only once the round starts.
- **An empty invariant is refused,** with exit 4 and nothing logged.
- **`rounds.log` is the record.** One line per run: round, seconds, item count, invariant hash, prediction. The report copies it; nothing is written from memory.

- **Keep it short: 2–5 minutes a run.** Every round costs one run, so a 15-minute benchmark makes a four-round session an hour of waiting. When the whole job is longer, benchmark a fixed slice of it that shows the same slowness — a handful of modules, one test directory.
- **Fix the input.** A benchmark over "whatever changed" measures a different job each round.
- **Clear what the real job would not have.** A leftover cache (`mutants/`, `.pytest_cache`, a warm build) turns a run into a replay that tests nothing.
- Record `sha256sum bench.sh` once the baseline is set. Check it before every round; a changed benchmark ends the run.
- Run it **twice** before touching anything, as rounds `base1` and `base2`, each with a prediction file that says `baseline`. If the two times differ by more than 10%, the benchmark is noise: find why (another job running, a cold cache, a container starting) before any round.

## Step 2 — The invariant

Name the result the job produces that must be **identical** after every change: each mutant's status, tests passed, rows exported. Record it as counts **and** a hash of the full list.

**Reject an empty invariant.** `bench.sh` refuses one with exit 4 — never work around that. A hash of nothing (`e3b0c442…` is SHA-256 of empty input) matches every future run, so it would wave any change through.

A faster run with a different invariant is not faster — it does less. Revert it (Step 4 covers a flaky one).

## Step 3 — Where the time goes

Two views, gathered together while baseline run 2 is going:

1. **Suspects (parallel, read-only).** Spawn the `optimize-suspect` agent **four times in one message**, one lens each: `contention`, `parallelism`, `repeated setup`, `scope`. Give each the job, the benchmark command and the baseline numbers. Merge their JSON, most likely first. Drop any suspect without a file and line, and any change that tests less.
2. **A profile.** Suspects are guesses; a profile is a measurement. Sample once during a short run of the job: CPU per process (`docker stats --no-stream`, `top`), what the database waits on (`pg_stat_activity` in Postgres), and a plain run of the suite under the language's profiler (`python -m cProfile -s tottime -m pytest`, `node --cpu-prof`).

Rank by what the profile shows, not by how convincing the story is. A CPU-bound job gains nothing from removing a lock; a lock-bound one gains nothing from cheaper code.

## Step 4 — Rounds (one at a time)

Never run two rounds, or a round beside anything else heavy: parallel benchmarks skew each other.

For each round:

1. **Predict — before anything runs.** Write one line to `$OUT/<round>.prediction`: a range the benchmark can prove wrong, and why: "10–25% faster: the DELETE queue goes, the fixed admin email becomes the next one."
2. **Change one thing.** Two changes in one round cannot be told apart.
3. **Run the benchmark:** `bash $OUT/bench.sh <round>`. Without the prediction file it will not start.
4. **Judge.** Keep the change only if the time beats the baseline by more than the noise from Step 1 **and** the invariant is identical.
5. **An invariant that moved by one or two items: rerun once before judging.** Run those items alone too. If the rerun matches the baseline, the flip was a flaky test — name it in the report as a bug of its own, and judge the round on the rerun. If it moves again, revert.
6. **Log.** `bench.sh` appends the round to `rounds.log`; add what changed and whether it was kept:

```
base1   179s  389 items  28a22b0e1fca  baseline
base2   184s  389 items  28a22b0e1fca  baseline
round1  103s  389 items  28a22b0e1fca  15-30% faster: one engine per session ends a Postgres login per test
```

**Build the table from `rounds.log`, never from memory.** Its prediction column is the locked file, written before the run. A prediction written after the result proves nothing, and a table that looks predicted when it was not is a false record.

**After a wrong prediction, measure before the next guess.** Profile again (Step 3, view 2). A wrong prediction usually means the job is limited by something else — and fixing the real limit can make a rejected change right later: a lock that cost nothing while the CPUs were full becomes the limit once they are free. Say what the miss rules out.

## Step 5 — Stop

Stop at the first of:

- the target is met;
- two kept rounds in a row each gained under 5%;
- no suspect is left.

Then run the project's full test suite, its linter and its type check once. The invariant covers the benchmark; these cover everything a kept change touched.

## Step 6 — The lesson

If the cause is a **pattern**, not a one-off, write it as one rule the way a skill states one — "Hash test passwords with the cheapest cost settings" — with a BAD/GOOD pair, and say which installed skill it belongs in (`ls .claude/skills/`). Hand it to the user. Skills are authored upstream: do not edit the installed copy, and do not go looking for the pattern in other projects.

## Step 7 — Report

1. The round log, copied from `rounds.log`.
2. Before and after, with the invariant beside each.
3. The files changed, uncommitted, and anything left behind outside the repo (a database created, a container). Do not commit — the user reviews a faster job the same way as any other change.
4. Any flaky test found on the way.
5. The rule from Step 6.

## Rules

- NEVER edit the benchmark or the invariant once the baseline is recorded.
- NEVER record an empty invariant.
- NEVER make it faster by testing less: fewer tests, a narrower scope, a skipped check, a lower threshold.
- NEVER change two things in one round.
- NEVER run a benchmark beside another benchmark or a full test run.
- NEVER write or change a prediction after its run, or chmod its file back to writable.
- NEVER read into or change another project.
- ALWAYS run a round through `bench.sh <round>`, never the job by hand.
- ALWAYS profile after a wrong prediction, before the next round.
- ALWAYS rerun once before judging an invariant that moved by one or two items.
- ALWAYS revert a change that did not beat the noise.
- ALWAYS run the full suite, lint and type check before reporting.
