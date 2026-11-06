---
name: design-variants
category: Frontend
description: "Use when asked to design, redesign or explore a UI, screen, panel or component and the user wants options — 'give me some designs', 'redesign this', 'what could this look like', /design-variants. Sends one brief to three blind designer agents, each given only a goal and free to choose the whole layout, each building one working design against a shared UX floor (states, accessibility, clarity for strangers); one artifact page shows all three side by side so the user picks a base and the parts to steal."
---

# Design Variants — Three Designs, One Brief, Blind

Designing in the same session that built the context produces one idea that
only its author understands. This skill separates the people who design from
the conversation that asked, and makes the gaps visible by putting designs
side by side: what one variant has and the others lack is the missing piece.

## Contents

1. Files
2. Step 1 — Brief
3. Step 2 — Directions
4. Step 3 — Build
5. Step 4 — Verify
6. Step 5 — Compare page
7. Step 6 — Stop, then merge
8. Rules

## 1. Files

- `DESIGNER.md` — the designer's instructions. Each designer reads it first.
- `UX-FLOOR.md` — the rules every variant is built to.
- `check.mjs` — measured checks: contrast on declared token pairs, `lang`,
  title, alt text, labels, empty buttons and links. Node, no dependencies.

`<skill-dir>` below is the directory holding this file.

## 2. Step 1 — Brief

Write `brief.txt` in the work folder (the session scratchpad if one is listed,
else `.claude/design-variants/<slug>/`). It is the **only** context designers
get, so it must stand alone:

```markdown
# Brief: Map layers panel
**What it is:** Side panel listing map layers for a mission area; toggle, locate, manage.
**Who uses it:** Analysts on desktop, often with 10–50 layers.
**Main task:** Find one layer and show only it.
**Must change:** More layers visible at once; accessible toggles; names not truncated.
**Keep:** Dark UI, orange "on" accent, Map/Satellite switch, owner filter.
**Content:** (the real list, verbatim — never "some layers")
**Look today:** bg #141b2a, panel #1a2233, text #e8edf5, accent #f0a030, 8px radius.
**Out of scope:** The map itself.
```

- Copy real content from screenshots or code. Invented data is a last resort.
- From a screenshot, write down what is broken in plain words — designers
  cannot see your reasoning, only the brief.
- If the main task or the user is unknowable, ask one question. Otherwise go.

## 3. Step 2 — Directions

Write all three directions **in one pass** — one call writing three options
diverges more than three calls with one prompt. A direction is a **bet**: what
the page is really for. It never says where anything goes; the designer decides.

```markdown
## A
Bet: power users scan and compare layers, like a spreadsheet.

## B
Bet: a layer belongs to a place on the map; people find it by where it is.
```

```markdown
## A — BAD: the layout is decided before the designer starts
Bet: power users scan columns.
Layout: 28px rows, search top-left, filters in a toolbar row.
```

Nine variants built from layout-level directions came out as one page with
different list bodies: same toolbar, same header, same controls.

Ban across all three, unless the brief's existing look uses them: purple-to-blue
gradients, Inter or Space Grotesk as the only face, emoji markers, everything
centred, the same radius and shadow on every block.

Two bets that would lead to the same page are one bet. Rewrite one.

Keep the directions out of the work folder (a sibling `-private` folder), so no
designer can read the other two.

## 4. Step 3 — Build

Spawn **three** `general-purpose` agents in **one message**, one per direction.
Each prompt holds only:

1. "First read `<skill-dir>/DESIGNER.md` and follow it. Your UX floor is `<skill-dir>/UX-FLOOR.md`."
2. The skill directory path.
3. The brief's path, and "do not read any other file in that folder".
4. Its one direction — never the other two.
5. Its one output path: `A.html` (`B.html`, `C.html`) in the work folder.
6. "You decide the layout and where every control goes. Do not reach for the
   usual title row, toolbar row, content by habit." 

Never pass the conversation, your favourite, or why the user wants it.

## 5. Step 4 — Verify

Run `node <skill-dir>/check.mjs <work-folder>/*.html` yourself. A designer
saying "exit 0" is not evidence. Send failures back to that designer once; if
they persist, keep the variant and show the failure on the compare page.

## 6. Step 5 — Compare page

Write `index.html` in the work folder and publish it as **one** artifact with
the three designs as supporting files (`files: {"A.html": "<path>", …}`).

- One section per direction: its name and bet, then its card.
- Each card: an `<iframe src="A.html" title="Design A">` at the real
  component size, the ID, the designer's one-line idea and tradeoff, the
  `check.mjs` result, and anything the designer left unresolved.
- An "open full size" link per card (`href="A.html"`).
- No ranking and no scores. The user judges.
- Follow the artifact page contract. The page must pass `check.mjs` apart from
  `lang` and viewport, which the publish skeleton adds.

## 7. Step 6 — Stop, then merge

Stop and ask: which variant is the base, and which parts to steal. Never pick
for the user. On request, spawn one fresh designer with `DESIGNER.md`, `UX-FLOOR.md`, the brief,
the base file, the named parts and their source files, writing `merged.html`;
verify and republish.

## 8. Rules

- Always write the brief to a file before spawning anyone.
- Always write the three directions in one pass, as bets only — never say where anything goes.
- Always spawn the three designers in one message, blind to each other.
- Always run `check.mjs` yourself; never trust a reported exit code.
- Always publish one compare page, not three artifacts.
- Never design a variant yourself — you hold the context they must not have.
- Never rank the variants or pick the winner for the user.
