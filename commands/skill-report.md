---
name: skill-report
description: "Show how often each installed skill was flagged by /deliver's skills audit in this repo — which rules keep breaking and should become a script check, and which skills never catch anything and may be dead weight"
category: Workflow
allowed-tools: Bash(node .claude/hooks/skill-report.mjs*), Bash(node .claude/hooks/ship-log.mjs gaps*)
---

# Skill Report — Which Skills Earn Their Place

Every `/deliver` skills audit is logged to `.claude/skill-flags.jsonl`, and every edit the
edit hook blocks to `.claude/edit-blocks.jsonl`. This command reads both.

## Steps

1. Run `node .claude/hooks/skill-report.mjs`.
2. Show the table exactly as printed. Do not reformat it.
3. Below it, name at most three skills in each group, and only where the numbers support it:
   - **Make it a script** — flagged on half or more of at least 4 audits. Name the top rule
     and say whether a script could check it (a pattern in the diff) or not (it needs judgment).
   - **Try without it** — at least 5 audits and 0 flags. The model may already follow it;
     suggest removing it for a few `/deliver` runs and watching whether flags appear elsewhere.
4. If the `models:` line lists more than one model, say the numbers mix models and that a
   skill which only flags on the older one is the stronger "try without it" case.
5. If an `edit-hook blocks` table is printed (from `.claude/edit-blocks.jsonl`), name at
   most three rules that blocked on **three or more branches**. Each one is a rule Claude
   keeps writing wrong first: suggest where its skill should state it earlier — a BAD/GOOD
   pair near the top, or a line in Rules — so the first draft gets it right.
6. If a `skill load cost` table is printed, it shows how much each skill adds to the context when it loads, read
   from this project's session files. A `-` means no load could be measured on its own: say so, never guess a number.
   A skill that costs the most and is in **Try without it** is the strongest case to drop.
7. Run `node .claude/hooks/ship-log.mjs gaps` and show its table verbatim. It counts the test
   gaps mutation testing found on each branch's first run, per week, across every logged repo.
   A change to the testing skill works only if "gaps per branch" drops in the weeks after it.

## BAD / GOOD

```text
BAD:  "react looks important, keep it."            ← no numbers behind it
GOOD: "react: flagged 7 of 12 — top rule 'Never put fetch in useEffect'.
       A script can check that: grep the diff for fetch( inside useEffect."
```

## Rules

- Always show the script's table verbatim before any commentary.
- Never recommend deleting a skill with fewer than 5 audits — that is noise, not signal.
- Never edit or delete the log; it is the only record.
- If the report says no audits are recorded, say so and stop.
