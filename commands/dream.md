---
name: dream
description: "Clean up this project's auto memory against what really happened — checks each memory note against the session transcripts and the repo, finds corrections no note covers yet, proposes adds, fixes, deletes and merges with a quoted proof for each, and changes nothing until you approve each one. Keeps MEMORY.md a short index"
category: Workflow
allowed-tools: Bash, Read, Grep, Glob, Edit, Write
argument-hint: "[topic to focus on, or empty for all memories]"
requires-commands: [add-rule]
---

# Dream — Check Memory Against What Happened

Memory notes are written in the moment, from one session's view. Some are wrong
from the start; some go stale as the project moves. The transcripts and the repo
are the ground truth. This pass checks the notes against them.

**You propose. The user decides.** Nothing in the memory folder changes until
the user approves that exact change.

## Step 1 — Find the memory and the transcripts

Your memory folder is named in your system prompt. The transcripts sit beside it.

```bash
MEM=~/.claude/projects/<slug>/memory      # the path from your system prompt
ls "$MEM"                                 # one note per file, plus MEMORY.md
ls -t "$MEM"/../*.jsonl | head -50        # session transcripts, newest first
wc -l "$MEM"/MEMORY.md
```

Transcripts older than the cleanup period are gone. **A note with no transcript
behind it is not a wrong note.** It may predate the oldest log.

If `$ARGUMENTS` is set, check only the notes about that topic.

## Step 2 — Check each note

For each note, look for evidence that confirms it, contradicts it, or makes it
moot. Search, don't read whole transcripts.

```bash
grep -l "survivor-town" "$MEM"/../*.jsonl             # which sessions mention it
grep -o ".\{0,200\}dev-ports.\{0,200\}" <file>.jsonl  # the words around a hit
```

Also check the repo. A note that names a file, function, flag, or script is
stale if that thing no longer exists — `ls`, `grep`, or `git log` proves it.

Sort each note into one bucket:

- **Keep** — confirmed, or no evidence either way.
- **Fix** — evidence shows part of it is wrong. You have the right version.
- **Delete** — evidence shows it is wrong, or the thing it names is gone, or it
  only restates what the repo or `CLAUDE.md` already says.
- **Merge** — two or more notes hold the same fact.

**No proof, no change.** A note goes in Fix or Delete only with a quote.

```markdown
<!-- BAD — a guess, the user cannot check it -->
3. Delete `project_old_api.md` — seems outdated.
```

```markdown
<!-- GOOD — the user can check it in ten seconds -->
3. Delete `project_old_api.md` — says the API lives in `server/api/`.
   Proof: `ls server/api` → No such file. Session 2026-10-02:
   "moved everything under apps/api, server/ is gone".
```

## Step 2b — Find corrections no note covers

`SCAN` is `.claude/hooks/correction-scan.mjs`, or `scripts/correction-scan.mjs` in the
claude-skills repo. It lists every message of the user's that might be a correction,
newest first, since the last pass:

```bash
node SCAN --scan "$MEM/.."
```

No `SCAN` (the file was copied in by hand) → grep the transcripts for
`"type":"user"` lines with "don't", "stop", "I said", "wrong", newest first.

Each line has `said` (the user's words) and `after` (the end of the reply before it).
Most hits are not corrections. Keep one only when the user told Claude it did, or was
about to do, the wrong thing, and the lesson holds beyond that one task.

Drop it if a memory note, `CLAUDE.md`, or `.edit-rules.json` already says it. Then sort:

- **Add** — about how Claude works: when to ask, push, release, how to write.
  Propose a new `feedback` note quoting the user's words.
- **Rule** — about code in certain files. Do not write it. Propose `/add-rule <the mistake>`.
  No `.claude/commands/add-rule.md` → make it an **Add** that names the files it is about.

Never propose adding any of it to `CLAUDE.md`.

## Step 3 — Check the index

`MEMORY.md` loads into every session, so it stays short. Only the first 200
lines load at all.

- One line per note, under ~150 characters. A longer line holds detail that
  belongs in the note file — propose moving it there.
- Every line points to a file that exists. Every note file has a line.

Then list every broken `[[link]]` — run this, don't eyeball it:

```bash
names=$(grep -h '^name:' "$MEM"/*.md | sed 's/^name: *//')
grep -o '\[\[[^]]*\]\]' "$MEM"/*.md | tr -d '[]' | while IFS=: read -r file link; do
  echo "$names" | grep -qx "$link" || echo "$(basename "$file") → [[$link]]"
done
```

Every line it prints goes in the proposal, even if the link was broken before
this pass. Point it at the note that now holds that fact, or drop the link.
The script's output is the proof.

## Step 4 — Show the proposal

Print one numbered list. Each entry: the action, the file, one line of why, the
proof. Put Keep last, as a count only — not one line per note.

```
Dream — 125 notes checked

1. Delete  feedback_use_yarn.md — says the repo uses yarn.
   Proof: `ls package-lock.json` exists, no yarn.lock. Session 2026-10-14:
   "switched to npm, drop yarn".
2. Merge   project_save_format.md + project_save_v2.md → project_save_format.md
   Proof: both describe the same JSON save file; v2 has the newer field list.
3. Fix     MEMORY.md line 41 — 310 characters; move the detail into its note.
4. Add     feedback_no_push_before_go.md — push only after the user says go.
   Proof: session 2026-11-02: "no, dont push yet, I want to read it first".
5. Rule    run `/add-rule route tests mock the data layer`
   Proof: session 2026-11-05: "why did you spin up a database in the route test".

Keep: 122 notes.

Reply with the numbers to apply ("all", "1 3", or "none").
```

Then stop and wait.

## Step 5 — Apply what was approved

Back up first, every time:

```bash
cp -r "$MEM" "$MEM-backup-$(date +%Y%m%d-%H%M)"
```

Then apply only the approved numbers. After applying, even "none", record the pass
so the same corrections are not offered again: `node SCAN --mark`. After a delete or merge, update
`MEMORY.md` and every `[[link]]` that pointed at the removed name.

Print what changed and the backup path, so the user can undo it:

```
Applied 1, 3. Skipped 2.
Backup: ~/.claude/projects/<slug>/memory-backup-20261107-1430
```

## Rules

- Never change a memory file before the user approves that exact change.
- Always back up the memory folder before applying anything.
- Never propose a fix or delete without a quoted proof.
- Always treat "no evidence" as keep, never as delete.
- Always check names of files, flags, and scripts against the repo as it is now.
- Always keep `MEMORY.md` one short line per note.
- Always run the broken-link script and propose a fix for every line it prints.
- Never write new notes about this pass itself.
- Never put a correction in `CLAUDE.md`; behaviour goes to a memory note, code goes to `/add-rule`.
- Always quote the user's own words for every Add or Rule.
