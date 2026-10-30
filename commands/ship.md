---
name: ship
description: "Unified git delivery pipeline — gate → commit → PR → merge → release. A quality gate runs first and fixes what it finds; run with no argument to step through interactively; `ship pr` runs through PR creation; `ship release` runs the full pipeline through the GitHub release."
category: Workflow
allowed-tools: Bash, Read, Grep, Glob, Edit, Write, Task, Skill
requires-agents: [gauntlet-skills]
argument-hint: "[pr | release] [--force to skip the gate]"
---

# Ship — Commit → PR → Merge → Release

`/ship` is a four-stage git delivery pipeline. It detects where your work currently is, runs from there, and either stops at a target stage or asks you at each boundary.

Stages, in order: **commit → pr → merge → release**, with a **gate** in front of all of them.

## How /ship Decides What to Do

**Start** — auto-detected from git state (Step 0).
**Stop** — set by `$ARGUMENTS`:

| Invocation | Behavior |
|---|---|
| `/ship` | Interactive — run the start stage, then ask "continue to `<next>`?" at every boundary. Stop when you decline. |
| `/ship pr` | Run through the **pr** stage, then stop. |
| `/ship release` | Run the full pipeline through the **release** stage. |
| `/ship commit` / `/ship merge` | Run through that stage, then stop. |

Rules that always hold:
- **Never re-do a satisfied stage** — already committed? start at pr.
- **Never skip a required stage** — `/ship release` with uncommitted work runs commit → pr → merge → release first.
- A merge into the **main** branch always asks for confirmation, even when a target is set.
- The **gate** (Step 0.5) runs once per invocation, immediately before the **pr** stage — not before commit — unless `--force`. A run that only commits never pays for it. A release gets no skills audit and no bug review: a `chore/release-*` PR gets only the script, and the dev → main PR gets no gate at all.

## Step 0 — Prechecks and Start Detection

### Prechecks — one call

```bash
bash .claude/hooks/ship-prep.sh start      # in a worktree: CLAUDE_PROJECT_DIR=<worktree> bash …
```

It fetches, prints the facts below, and sets the `/ship` mark (the PR hook opens and merges no
PR on a branch without it). Each command you run costs time to approve, so **read these facts
from its output; never look them up again**:

- `branch`, `base <dev or main> (main <main>)`, `ahead N, behind N of origin/<base>`
- `uncommitted N` and the files, `gh logged in` or not, `pr <STATE #N url>` or `pr none`

It stops on a detached HEAD or a folder that is not a git repo. `commits none` means only the
commit stage can run. `remote none` or `gh NOT logged in` → STOP before pr, merge and release.

### Detect the start — first match wins, in this order

1. **Uncommitted changes** (`git status --porcelain` non-empty) → start at **commit**.
2. Clean tree, **no PR** exists for the current branch, **commits ahead** of the base (`git log <base>..HEAD` non-empty) → start at **pr**.
3. An **open, unmerged PR** exists for the current branch → start at **merge**.
4. The current branch's PR is **already merged**, or you are on the **dev branch and it is ahead of main** → start at **release**.
5. Clean tree, no PR, nothing ahead of base → **done** — nothing to ship; say so and stop.

This order is exhaustive and the conditions do not overlap once evaluated top-down.

### Reconcile with the target

- If `$ARGUMENTS` names a target **earlier** than the detected start, the target is already satisfied. Do not say a bare "nothing to do" — show the existing artifact: e.g. `/ship pr` when a PR exists → "A PR already exists for this branch: `<URL>`." Then stop.
- If `$ARGUMENTS` names a target **later** than the start, state the plan and get **one** confirmation: *"You have uncommitted changes — `/ship release` will run commit → pr → merge → release. Proceed?"* Then run each stage to the target without further prompts — except a merge into main, which always confirms.
- If `$ARGUMENTS` is empty, run the start stage, then **ask before advancing** to each next stage.

Each stage below re-verifies its own precondition and aborts if Step 0 routed it wrong.

---

## Step 0.5 — The Gate

Runs **once**, immediately before the **pr** stage. `--force` in `$ARGUMENTS` skips it
entirely — no argument, no questions. Skip it too when there is nothing to check.

**Not before commit.** The gate's mutation scope is `merge-base..HEAD` — the whole branch,
because the whole branch is what a PR ships. Running it before every commit re-mutated
every file the branch had ever touched: a 46-file branch paid fifteen minutes on each of
twenty commits. A commit publishes nothing, so it is not gated. If a run stops at commit,
the gate never runs; the moment a run continues to pr or merge, it runs first.
Ask for it earlier with a bare `bash .claude/hooks/ship-gate.sh` when you want the
findings before the PR.

**Not in full before a release.** A release ships only commits that already passed this
gate in their own PRs; auditing them again started a skills agent over every file in it.
- **`chore/release-*` → dev** (the bump and changelog): run only the script, for the receipt
  the PR needs. Skip the skills audit and the bug review.
- **dev → main**: no gate at all, not even the script (release step 4).

This is the one enforcement moment. It does not re-run the test suite: the `gauntlet.sh`
Stop hook already ran types and tests on every turn. It checks the four things nothing
else does, and **it fixes what it finds** rather than handing you a list.

Two of the four live in `ship-gate.sh` behind an exit code, and two — the skills audit and the bug review —
live here, because they are the ones that genuinely need a model.

**Scope** — everything about to ship, and nothing else, in one call after any commits:

```bash
bash .claude/hooks/ship-prep.sh scope      # in a worktree: CLAUDE_PROJECT_DIR=<worktree> bash …
```

It prints `base <sha>`, one line per changed source file with its new-side lines
(`view/a.gd 8-21,75`, `(new)` for a new file), one `skill <name>: audit <files>` / `skip, …` /
`decide from its description` line per skill, `diff <file>` and the `review` command, and it
starts the audit and review steps in the ship log. Every check below uses exactly this scope;
never rebuild it, never scan the whole repo.

A `plan none` line means this branch adds files and skipped the registry. Ask the user once:
continue, or stop and run `/plan-feature`. It never stops the ship by itself.

Then run the checks **in this order, and no other** — run one after another,
they cost a ship 5 to 8 minutes:

1. **In one message**, launch every skills audit agent and the bug review.
   They run in the background. Do not wait for them.
2. **While they run**, run the gate script. Fix its survivors and re-run it until it passes.
   A file over the limit or in the wrong folder still stops the ship.
3. **When the audit and the review are back**, fix what they found, in one pass. Their
   steps end in the ship log by themselves.
4. **Run the gate script once more**, because those fixes changed files.

**Log every finding the moment you settle it** — survivor, audit point or review finding:
`node .claude/hooks/ship-log.mjs finding '<json>'` (shape in The ship log). With the log off
these commands do nothing, so never skip them.

The sections below say how to do each check. They are not an order.

### The gate script — file length, folder structure and mutation: obey the exit code

```bash
bash .claude/hooks/ship-gate.sh
```

In a git worktree, run this folder's gate against the worktree — `CLAUDE_PROJECT_DIR=<worktree> bash .claude/hooks/ship-gate.sh` — and
open the PR with `--head <branch>`, so the hook finds that worktree's receipt. Never `--force` here to cover a worktree.

These two are arithmetic and a tool invocation. They are deliberately **not** described
here as things to carry out, because a check written in prose is a check a model can
decide is not worth it — and that is exactly what happened the first time this gate ran.

So: run that command. Show its output verbatim. Obey its exit code.

- **0** — clean, continue.
- **1** — findings. A file over the limit stops you: splitting a file is a design
  decision, not something to do silently mid-ship. A new file outside its kind folder
  (`components/`, `hooks/`, `routers/` …) stops you too: move it. Surviving mutants are a gap in the
  tests, not in the code — write the test that closes each one (see below), then re-run
  the script.
- **2** — it ran but could not prove the tests, almost always because no mutation tool
  is installed. Report that plainly and continue. Do not describe this as passing.

A project that passed is not re-run until the gate or a changed file of its own kind
changes: fixing API tests does not re-run Stryker on the JS apps.

Python cannot be scoped to lines: mutmut has no per-line scoping, so the gate mutates
every function in each changed module, and a changed module's old survivors come back
with it. A `.mutmut-baseline` file holds the ones already accepted, and only a name
outside it fails. A module's first run records its survivors there and exits 2 —
commit the file and run the gate again. After that, `--baseline` rewrites only the changed
modules' entries, reuses the last run's results when nothing changed since, and writes
the receipt itself — do not run the gate again after it. **Never run `--baseline` to
make a finding go away.** It accepts a survivor as permanent debt, so it is for a mutant
that genuinely cannot be killed — an equivalent mutant, where the change alters nothing
observable. Say which mutant and why, in the commit, or write the test instead.
A survivor in code that only runs at import — app setup, router registration — is
neither: mutmut forks after import, so that mutant never runs. Call the function from a
test, or mark it `# pragma: no mutate block, <reason>`; never baseline it as harmless.

**Never substitute your own implementation of these checks.** Not a hand-rolled mutation
script, not a `wc -l` you ran yourself, not a judgement that the changed files look too
simple to be worth mutating. If the script cannot run, say so and stop — a gate you
route around is not a gate.

You cannot report your way past this one, and you do not have to be trusted not to try:
the script writes a **receipt** keyed to the exact content about to ship, and a PreToolUse
hook refuses `git commit` and `git push` without a matching one. A check you designed
yourself writes no receipt. Editing a file after the gate ran invalidates it, so a fix is
re-gated rather than riding on the previous verdict. To publish without the gate, say so
plainly and run `bash .claude/hooks/ship-gate.sh --force`.

When a mutant survives, write the test that kills it, then verify the new test **fails
when the implementation is removed**. A test that passes without the code asserts
nothing and is worse than the gap it filled: throw it out and report the gap instead.
Re-run the script rather than declaring it fixed. Stop after **two** attempts at a gap.

### The skills audit — one `gauntlet-skills` agent per applicable skill

This step was described in this file for months and never written, so it never ran. Four
forms shipped on `useActionState` in a repo whose React skill routes to a `FORMS.md`
saying React Hook Form is the default. Nothing opened it, because nothing was asked to.

**This is the only check that covers code the session did not write.** The `skill-gate.sh`
hook fires on Write/Edit/Bash, so a file that arrived in the tree some other way — written
before the gate existed, by another session, or by hand — reaches the commit having never
met a skill. The ship scope is where that is caught, or nowhere.

1. Take the skills from `ship-prep.sh scope`. No `skill` lines → say so and skip to Result.
   `audit` → run it on the files it names. `skip` → not run; say so in one line.
   `decide from its description` → read that skill's `description` and decide against the scope.
2. Launch every audited skill **in the same message as the bug review**, so
   they all run at once, one `gauntlet-skills` agent per skill. Pass each exactly what its Input section asks for:
   the `SKILL.md` path, the changed files that skill applies to with their line ranges,
   and the `diff` file. One skill per agent — an agent given two skills
   half-reads both.
3. Wait for all of them. Each returns JSON with `violations`.

Then **fix what they found**, in the code, the same way you fix what the
script found. Do not hand the user a list and continue.

- Apply each violation's `fix` where you agree with it. Editing a file invalidates the
  ship-gate receipt, so re-run `ship-gate.sh` afterwards — that is the design, not a
  problem.
- Where you disagree, say which violation and why, and leave the code alone. The agent
  audits a diff without knowing the conversation; it can be wrong.
- A violation you cannot fix without a design decision — a form that should be rebuilt on
  a different library, a file that needs splitting — **stops the ship**. That is the
  user's call, not a silent one.

Never audit a skill yourself instead of launching its agent. The point of the subagent is
that it reads the skill fresh, with no memory of having decided earlier that the skill did
not apply — which is exactly the failure this step exists to catch.

### The bug review — one `/code-review` round

The other checks ask whether the code follows the rules and whether the tests notice a
change. None asks whether the logic is right: a test that expects the wrong answer passes mutation.

Run it once, in the same message that launches the skills audit, through the Skill tool:

```
/code-review medium origin/<base>...<branch>
```

Pass the level and the range every time. With no level it reuses the one the user typed
last, and with no range it compares against `main`, not the dev branch. Use `origin/`: a local
base that is behind re-reviews work already merged. Name the branch, not `HEAD`: in a worktree,
`HEAD` is whatever folder the session sits in.

**Sort before you test.** A finding of one of these kinds gets no test. List it for the user
as `skipped: <kind>` with the one-line reason:

- **Decided** — it argues against a choice the plan, the ticket or the user made. Name where.
  A finding that the code does not do what was chosen is not decided: test it.
- **Old code** — it is in a file the diff does not touch.
- **Cost, not a wrong result** — slower or bigger, but the output is right.
- **Out of scope** — a new feature, or a change in another repo.
- **Tooling** — the CLAUDE.md block the sync writes. A grown baseline is never tooling.

If you are not sure it fits, it does not: test it.

**No proof, no fix.** A finding is what a reviewer said, not evidence. Before changing code
for one, write the test that shows the bug, and run it:

- **It fails** → confirmed. Fix the code; the test stays as the guard. Old bug or new, fix it here.
- **It passes** → refuted. The reviewer was wrong: change nothing and say why.
- **No test can show it** (it needs a real browser, exact timing, an outside service) →
  unconfirmed. List it for the user with that reason; never fix on a guess.

Stop the ship on a confirmed finding that needs a design decision.
**One round only** — do not review the fixes again. A reviewer re-run on its own fixes
keeps finding older code, not new bugs. Re-run `ship-gate.sh` if anything changed.

### Result

- **Everything fixed** → say what was fixed in one or two lines, then continue to the first stage. The fixes are part of the commit.
- **Stopped** → show what stopped you and why, and do not proceed. Offer `--force`.

---

## Stage: commit

Precondition: uncommitted changes exist; the current branch is **not** protected. If on a protected branch (`main`/`master`/`dev`/`develop`/`development`), STOP — ask whether this is a hotfix (create `hotfix/<desc>`) or which branch to create.

1. **Scan for secrets** before staging: `bash .claude/hooks/ship-prep.sh secrets`. It stops on a
   protected branch, prints `git status`, and checks files by name (`.env`, `*.pem`, `*credentials*`,
   `*.key`) and added lines for key signatures (`AKIA…`, `-----BEGIN … KEY-----`, `xoxb-…`, bearer
   tokens). Exit 1 → STOP and show the user its lines. It cannot judge a high-entropy string: while
   you read the diff to group it, stop on one.
2. Delete `PLAN.md` at the repo root if git does not track it — `/plan-feature` left it, and it is
   never committed. A tracked `PLAN.md` belongs to the project; leave it. Then read
   `git diff` and `git diff --staged` to group the work.
3. Group changes into **logical units of work**. Stage each group's files **explicitly** — never `git add .` / `git add -A`.
4. Commit each group: `type(scope): imperative description`. Types: `feat` `fix` `refactor` `docs` `style` `test` `chore` `perf` `ci` `build` `revert`. Breaking change → `type!:` + a `BREAKING CHANGE:` footer.
5. Show a summary — branch name and the commits created.

## Stage: pr

Precondition: changes committed, on a feature branch (not protected), commits ahead of the base, a remote exists, `gh` is authenticated.

1. Determine the base branch — the dev branch if one exists, otherwise main.
2. Review the whole branch: `git log <base>..HEAD --oneline`, `git diff <base>...HEAD --stat`.
3. Push: `git push -u origin HEAD`.
4. Create the PR. Pass the body via `--body-file` (or a stdin heredoc); pass the title as a single-quoted literal:

```bash
gh pr create --base <base> --title '<conventional title, ≤70 chars>' --body-file <file>
```

**The PR body is read by a reviewer who did not write the code.** They need the problem, what changed, and how to see it working. They do not need the reasoning behind every decision — that is a comment on the PR, not the body. Four sections, nothing else, under 250 words before the test plan:

- **Summary** — 1-3 bullets. What a person hit, and what they see now. Name the screen, the button, the report. Not the mechanism.
- **Changes** — one line per change, at most 8. A reason only where a reviewer would push back, and then one sentence. No paragraphs, no file tables.
- **Test plan** — numbered manual steps first: the page, the action, what you see. Then the commands that ran, with their counts. Every line a checkbox.
- **Ship gate** — one line. `clean`, or `forced — <what remains, in plain words>`. The finding list goes in a PR comment.

No other sections — no Review notes, Related, Decisions, Verification, Background. No tooling words a teammate would not know: say "a test gap the mutation tool found", not "a surviving mutant". A body that needs a sentence over 25 words is explaining, not describing — cut it.

5. Run `node .claude/hooks/ship-log.mjs pr <number>`, then show the PR URL.

## Stage: merge

Precondition: an open PR exists for the current branch; `gh` is authenticated.

1. `bash .claude/hooks/ship-prep.sh merge <number>` — one line: `merge ok #N`, or `merge STOP #N:` and
   every reason (draft, conflicts, CI failing or still running, review required). On STOP, report it — do not merge.
2. Confirm the merge method (squash is the default for feature → dev — one clean commit per PR).
3. `bash .claude/hooks/ship-prep.sh land <number>` — checks again, squash-merges, deletes the branch,
   and returns to the base. From a worktree it stays put; the session's exit removes the worktree.

## Stage: release

Precondition: a dev branch exists and is ahead of main; `gh` is authenticated. If there is no dev branch, the project merges features straight to main — skip the release PR and tag main directly after the feature merge (steps 1-3, then 6-7).

**The version bump reaches main only through dev.** A bump committed on a `release/*` branch lands in main and never in dev, and every release then needed a third PR to back-merge it. So steps 1-3 run before the release PR, on a branch that merges into dev:

- **`/ship release` from a feature branch** → run steps 1-3 on that branch before its **pr** stage and commit them as `chore(release): <version>`. The feature PR carries the bump into dev.
- **Everything already merged, on dev** → `git checkout -b chore/release-<version>`, run steps 1-3, commit, then pr → merge into dev as usual.

1. **Version** — `bash .claude/hooks/ship-prep.sh release` prints the last tag, the commits since it and
   a suggested version by these rules (it stops when nothing is new since the tag):
   - **1.x and above:** MAJOR for any `!` / `BREAKING CHANGE`, MINOR for any `feat`, else PATCH.
   - **0.x (pre-1.0):** a breaking change bumps MINOR (`0.3.x → 0.4.0`); `feat` and `fix` bump PATCH. Reserve `v1.0.0` for the first stable release.
   - No tags yet → suggest `v0.1.0`.
   - **Always confirm the version with the user.**
2. If the project has a version file (`package.json`, `pyproject.toml`, `Cargo.toml`, …), update it — and its lockfile (`package-lock.json`, `uv.lock`, …) — to the new version.
3. **Changelog** — for humans, not a commit log. Group commits since the last tag under Breaking Changes, Added, Changed, Fixed, Removed — only the groups that apply. One line per change, written as what a person can now do or what works now, with the PR number. No field names, file names, or commands in a bullet. Skip merge, version-bump, and internal-only noise. Steps someone must run after deploy go in an **After deploy** checklist at the end. No theme paragraph, no essay.
4. **Release PR** — straight from dev, no release branch: `git checkout <dev> && git pull`, then `gh pr create --base <main> --head <dev> --title 'release: <version>' --body-file <file>` (changelog + a checklist). No gate and no /ship mark: every change on dev passed the gate in its own PR, and the PR hook lets a dev → main PR through.
5. **Merge to main** — confirm with the user first (always). When CI is green, merge with **`bash .claude/hooks/ship-prep.sh land <number> merge`** — a real merge commit, **not** `--squash`: squashing dev→main would collapse the feature commits and destroy the conventional-commit history that future version and changelog detection depends on. **Never `--delete-branch`** here: the head branch is dev.
6. **Tag + GitHub release**:

```bash
git checkout <main> && git pull
git tag -s -a <version> -m 'Release <version>'   # signed + annotated; -a alone if no signing key
git push --follow-tags
gh release create <version> --title '<version>' --notes-file <file>
```

7. Show the release URL.

---

## Last, wherever the run stops — repeats worth a rule

At the end of every `/ship` run — after the last stage it reached, or the prompt the user
declined — run:

```bash
node .claude/hooks/diary-check.mjs
```

Silent → say nothing. A line → it names a date, or `(never)`, meaning every entry is new. Run
`node .claude/hooks/diary-check.mjs --mark` at once, then read `--entries` as `/add-rule` Step 0 does and name at most three mistakes
that came back on two or more branches **with at least one entry after that date** — an older
repeat was already offered. Nothing qualifies → say nothing. Otherwise ask which to turn into a
check; on a pick, run `/add-rule` with that mistake. Never write a rule here.

## The ship log

The log is on when the user set `GAUNTLET_SHIP_LOG=1`; when it is off, every call below does
nothing. The gate logs each of its own runs; you add what only you know, as it happens, with
`node .claude/hooks/ship-log.mjs`:

- `ship-prep.sh start` opens the log for you; never run `start` yourself. A ship left open
  by an interrupted run is saved as abandoned, so it never mixes into this one.
- `ship-prep.sh scope` logs `step audit start` and `step review start`; each finished audit and review logs its own end.
- `finding '<json>'` once for every finding you fixed, refuted or left, from any check:
  `{"by":"review","what":"<one line>","file":"<path>","verdict":"confirmed","fixed":true}`.
  `by` is `mutation`, `length`, `structure`, `audit:<skill>` or `review`. `verdict` is
  `confirmed` (a test or the gate proved it), `refuted` (a test showed it is not a bug, or
  you disagree with an audit point, with the reason in `"note"`), `unconfirmed` (no test can
  show it) or `skipped` (sorted out before testing, with `"note":"<kind> — <reason>"`).
- `pr <number>` right after the PR is created, or `end "<why>"` when the run stops before one.
  A log left open is closed at its PR by the next `/ship` in this repo.
- The PR hook refuses `gh pr create` until `step review end` and every review finding are
  logged, and names what is missing.

## Flow Examples

- **`/ship` on a dirty feature branch** → commits, asks "create a PR?" → "merge it?" → "cut a release?". Decline at any point to stop.
- **`/ship pr`** → commits if needed, pushes, creates the PR, stops. If a PR already exists, reports its URL and stops.
- **`/ship release` with everything already merged** → `chore/release-<version>` with the bump → PR into dev → merge → release PR dev → main → merge → tag.
- **`/ship release` on a dirty feature branch** → one upfront confirmation, then commit → version bump on the same branch → pr → merge into dev → release PR dev → main → merge → tag. Two PRs, no back-merge.

## Rules

- NEVER commit to `main`/`master`/`dev`/`develop`/`development` directly — feature branch, or `hotfix/<desc>`.
- NEVER `git add .` / `git add -A` — stage explicit files. Scan staged content for secrets, not just filenames.
- NEVER target `main` for a feature PR when a dev branch exists.
- NEVER tag or create a GitHub release before the release PR is merged into main.
- NEVER merge a PR that is a draft, has conflicts, has failing CI, or is missing required reviews — stop and report.
- NEVER squash the release PR into main — use a merge commit so the feature history survives for future changelog/version detection.
- NEVER cut a `release/*` branch or back-merge main into dev — the version bump reaches main only through dev, so main never holds a commit dev lacks.
- NEVER run the skills audit or the bug review on a `chore/release-*` branch or a dev → main PR — their commits already passed them.
- NEVER interpolate a branch name, tag, version, or title containing shell metacharacters (`` ` ``, `$(`, `;`, `&&`, `|`) into a command — pass interpolated values as single-quoted literals, pass PR/release bodies via `--body-file`/stdin, and abort if such a value contains metacharacters.
- ALWAYS run the skills audit — one `gauntlet-skills` agent per applicable skill, all launched in one message. NEVER audit a skill yourself instead: the agent reads it fresh, with no memory of having decided it did not apply.
- NEVER skip a skill because the diff "looks fine" — skip it only when no file in the ship scope matches it, and say which you skipped.
- ALWAYS fix what the audit finds, re-running `ship-gate.sh` afterwards because the edits invalidate its receipt; a violation needing a design decision stops the ship rather than being noted and passed.
- ALWAYS run `/code-review medium origin/<base>...<branch>` once after the skills audit, and NEVER a second round on its own fixes.
- NEVER change code for a review finding before a test shows the bug; a finding no test can show is listed, not fixed.
- ALWAYS sort review findings before testing: decided, old code, cost, out of scope and tooling are listed as skipped, never tested. Not sure it fits → test it.
- ALWAYS log every finding once, with its verdict, the moment you settle it, and close the log with `pr` or `end`. The calls do nothing when the log is off.
- ALWAYS run `diary-check.mjs` at the end of every run, `--mark` before asking, and hand a picked repeat to `/add-rule`; NEVER write a rule in `/ship`.
- ALWAYS use conventional commits, imperative mood, atomic per logical unit.
- ALWAYS detect main/dev branches and the PR base automatically; apply 0.x semver rules for pre-1.0 projects.
- ALWAYS confirm the release version, and confirm before any merge into `main`.
- ALWAYS run stages in order — skip satisfied stages, never skip required ones; each stage re-verifies its precondition.
- With no `$ARGUMENTS`, ask before advancing to each next stage; with a target set, confirm once upfront then run through (a merge into `main` still asks).
- If a target is already satisfied, report the existing artifact (branch, PR URL, tag) — never a bare "nothing to do".
- Verify `gh auth status` before the pr, merge, and release stages; if it fails, explain setup and stop.
