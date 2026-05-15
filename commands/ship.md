---
name: ship
description: "Unified git delivery pipeline — commit → PR → merge → release. Run with no argument to step through interactively; `ship pr` runs through PR creation; `ship release` runs the full pipeline through the GitHub release."
category: Workflow
argument-hint: "[pr | release]"
---

# Ship — Commit → PR → Merge → Release

`/ship` is a four-stage git delivery pipeline. It detects where your work currently is, runs from there, and either stops at a target stage or asks you at each boundary.

Stages, in order: **commit → pr → merge → release**.

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

## Step 0 — Prechecks and Start Detection

### Prechecks (run first; abort cleanly on any)

```bash
git rev-parse --is-inside-work-tree   # not a git repo → STOP
git branch --show-current             # empty = detached HEAD → STOP, ask user to checkout a branch
git rev-parse HEAD                    # fails = repo has no commits
git remote                            # empty = no remote configured
```

- **Detached HEAD** (empty branch name) → STOP: "Detached HEAD — check out a branch first."
- **No commits yet** → if there are changes, the only possible stage is commit; otherwise STOP ("nothing to ship").
- **No remote** → the pr/merge/release stages cannot run; STOP before them with "No `origin` remote configured."
- **`gh` not installed or not authenticated** → required for the pr, merge, and release stages. Check `gh auth status` before any of them; if it fails, explain setup and STOP.

### Identify branches

```bash
git status --porcelain
git branch -r | grep -E 'origin/(main|master|develop|development|dev)$'
```

**main** branch: prefer `main` > `master`. **dev** branch: prefer `develop` > `development` > `dev`. The PR base is the dev branch if one exists, otherwise main.

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

## Stage: commit

Precondition: uncommitted changes exist; the current branch is **not** protected. If on a protected branch (`main`/`master`/`dev`/`develop`/`development`), STOP — ask whether this is a hotfix (create `hotfix/<desc>`) or which branch to create.

1. Review everything: `git status`, `git diff`, `git diff --staged`.
2. **Scan for secrets** before staging. Skip files by name (`.env`, `*.pem`, `*credentials*`, `*.key`) **and** scan the diff content for in-file secrets — high-entropy strings and key signatures (`AKIA…`, `-----BEGIN … KEY-----`, `xoxb-…`, bearer tokens). If anything matches, STOP and tell the user; recommend `gitleaks` / `git-secrets` as a pre-commit guard.
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

PR body sections: **Summary** (why — 1-3 bullets), **Changes** (grouped, notable only), **Test plan** (specific, checkable steps).

5. Show the PR URL.

## Stage: merge

Precondition: an open PR exists for the current branch; `gh` is authenticated.

1. Check it is safe to merge:

```bash
gh pr view --json number,title,isDraft,mergeable,reviewDecision,statusCheckRollup
```

2. STOP and report — do not merge — if: `isDraft` is true, `mergeable` is `CONFLICTING`, CI is failing, or required reviews are missing.
3. Confirm the merge method (squash is the default for feature → dev — one clean commit per PR).
4. Merge and clean up: `gh pr merge <number> --squash --delete-branch`.
5. Sync local: `git checkout <dev>` (or main if no dev), `git pull`.

## Stage: release

Precondition: a dev branch exists and is ahead of main; `gh` is authenticated. If there is no dev branch, the project merges features straight to main — skip the release PR and tag main directly after the feature merge (steps 1-3, then 6-7).

1. **Version** — `git fetch --tags`; `git tag --sort=-v:refname | head -5`; `git log <latest-tag>..HEAD --oneline`. If there are **no commits since the last tag**, STOP — nothing to release. Suggest the next semver:
   - **1.x and above:** MAJOR for any `!` / `BREAKING CHANGE`, MINOR for any `feat`, else PATCH.
   - **0.x (pre-1.0):** a breaking change bumps MINOR (`0.3.x → 0.4.0`); `feat` and `fix` bump PATCH. Reserve `v1.0.0` for the first stable release.
   - No tags yet → suggest `v0.1.0`.
   - **Always confirm the version with the user.**
2. If the project has a version file (`package.json`, `pyproject.toml`, `Cargo.toml`, …), update it — and its lockfile (`package-lock.json`, `uv.lock`, …) — to the new version.
3. **Changelog** — group commits since the last tag: Breaking Changes, Features (`feat`), Bug Fixes (`fix`), Performance (`perf`), Other. Short descriptions, include PR/issue numbers, skip merge and version-bump noise.
4. **Release PR** — `git checkout -b release/<version>`, push, then `gh pr create --base <main> --title 'release: <version>' --body-file <file>` (changelog + a checklist).
5. **Merge to main** — confirm with the user first (always). When CI is green, merge with **`gh pr merge --merge`** — a real merge commit, **not** `--squash`: squashing dev→main would collapse the feature commits and destroy the conventional-commit history that future version and changelog detection depends on.
6. **Tag + GitHub release**:

```bash
git checkout <main> && git pull
git tag -s -a <version> -m 'Release <version>'   # signed + annotated; -a alone if no signing key
git push --follow-tags
gh release create <version> --title '<version>' --notes-file <file>
```

7. Show the release URL.

---

## Flow Examples

- **`/ship` on a dirty feature branch** → commits, asks "create a PR?" → "merge it?" → "cut a release?". Decline at any point to stop.
- **`/ship pr`** → commits if needed, pushes, creates the PR, stops. If a PR already exists, reports its URL and stops.
- **`/ship release` with everything already merged** → starts at the release stage and runs version → changelog → release PR → merge → tag.
- **`/ship release` on a dirty branch** → one upfront confirmation, then commit → pr → merge → release straight through.

## Rules

- NEVER commit to `main`/`master`/`dev`/`develop`/`development` directly — feature branch, or `hotfix/<desc>`.
- NEVER `git add .` / `git add -A` — stage explicit files. Scan staged content for secrets, not just filenames.
- NEVER target `main` for a feature PR when a dev branch exists.
- NEVER tag or create a GitHub release before the release PR is merged into main.
- NEVER merge a PR that is a draft, has conflicts, has failing CI, or is missing required reviews — stop and report.
- NEVER squash the release PR into main — use a merge commit so the feature history survives for future changelog/version detection.
- NEVER interpolate a branch name, tag, version, or title containing shell metacharacters (`` ` ``, `$(`, `;`, `&&`, `|`) into a command — pass interpolated values as single-quoted literals, pass PR/release bodies via `--body-file`/stdin, and abort if such a value contains metacharacters.
- ALWAYS use conventional commits, imperative mood, atomic per logical unit.
- ALWAYS detect main/dev branches and the PR base automatically; apply 0.x semver rules for pre-1.0 projects.
- ALWAYS confirm the release version, and confirm before any merge into `main`.
- ALWAYS run stages in order — skip satisfied stages, never skip required ones; each stage re-verifies its precondition.
- With no `$ARGUMENTS`, ask before advancing to each next stage; with a target set, confirm once upfront then run through (a merge into `main` still asks).
- If a target is already satisfied, report the existing artifact (branch, PR URL, tag) — never a bare "nothing to do".
- Verify `gh auth status` before the pr, merge, and release stages; if it fails, explain setup and stop.
