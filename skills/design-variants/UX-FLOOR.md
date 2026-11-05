# UX Floor — What Every Variant Must Pass

Every variant is built to this. Cite rules by ID.

## Contents

1. Clarity (C)
2. States (S)
3. Forms (F)
4. Feedback and destructive actions (D)
5. Accessibility (A)
6. Responsive (R)
7. The contrast contract

## 1. Clarity (C)

- **C1** A stranger can say what the view is for within five seconds. The heading names it in the users' words.
- **C2** One primary action per view. It looks different from every other control.
- **C3** Every icon has a visible text label, or a tooltip **and** an `aria-label` when space forbids text. Never icon-only for a rare action.
- **C4** Buttons name the outcome: "Hide all layers", not "Submit" or "OK".
- **C5** System status is visible: counts, what is on, what changed.
- **C6** Recognition over recall: show options, do not make people remember codes or names.
- **C7** Long names never lose the part that tells them apart. Drop a repeated suffix before truncating; show the full name on hover and to screen readers.

```html
<!-- BAD: the distinguishing part is cut, the repeated part survives -->
<span class="name">San Telmo (Buenos A…</span>
<!-- GOOD: repeated context moves to the group header, full name stays available -->
<span class="name" title="San Telmo (Buenos Aires)">San Telmo</span>
```

## 2. States (S)

- **S1** Build all five: ideal, empty, loading, error, partial. Reachable from a small "Preview state" control outside the component, so a reviewer can see each.
- **S2** Empty says whether it is still working or done, what will appear, and links to the first task.
- **S3** Loading under 1s shows no spinner. 2–10s: spinner with a text label. 10s+: progress ("3 of 50").
- **S4** Error says what went wrong and how to fix it, with a retry.
- **S5** Survives stress: a name 3× longer, 100+ rows, 200% zoom.

## 3. Forms (F)

- **F1** Labels sit outside the field and stay visible. A placeholder is never the label.
- **F2** Validate **on submit**. Show an error summary at the top, move focus to it, link each item to its field. Never clear what was typed.
- **F3** Error text says what is wrong and how to fix it, in the label's words. No "please", "oops", "invalid", "This field is required".
- **F4** Mark optional fields "(optional)". No asterisks.
- **F5** Every input has `<label for="id">` or an `aria-label`. Wrapping a label does not count (the check cannot see it).

## 4. Feedback and destructive actions (D)

- **D1** Prefer undo over confirm. Confirm only what cannot be undone.
- **D2** Confirm buttons name the outcome: "Delete layer" / "Keep layer". Never Yes/No, never a default "Yes".
- **D3** Status messages live in `role="status"` so they are announced without stealing focus.
- **D4** Bulk actions say how many they touch: "Hide 14 layers".

## 5. Accessibility (A)

- **A1** Text contrast 4.5:1; large text, borders that carry meaning and control states 3:1. Measured, see section 7.
- **A2** Visible focus on every control, never hidden under a sticky header.
- **A3** Targets at least 24×24 CSS px, or spaced so a 24px circle around each touches no other.
- **A4** Everything works by keyboard. Toggles are `<button aria-pressed>` or `<input type="checkbox" role="switch">`.
- **A5** Semantic HTML first: `<button>` for actions, `<a>` for navigation, lists for lists, headings in order.
- **A6** Colour is never the only signal. A colour swatch has a name or shape beside it.
- **A7** `<html lang>`, a `<title>`, and alt text on every image.
- **A8** Respect `prefers-reduced-motion`.

```html
<!-- BAD: a div that looks like a switch -->
<div class="toggle on" onclick="flip()"></div>
<!-- GOOD: a real control with a name and a state -->
<button class="toggle" aria-pressed="true" aria-label="Show Palermo">…</button>
```

## 6. Responsive (R)

- **R1** No sideways scroll at 320 CSS px wide.
- **R2** Inputs use a 16px font or larger, or iOS zooms in.
- **R3** Dense layouts stay dense on desktop and stack, not shrink, on phones.

## 7. The contrast contract

Contrast is measured by `check.mjs`, not judged by eye. Every variant declares
which token pairs carry text or meaning:

```html
<meta name="contrast-pairs" content="--fg/--bg --muted/--bg --on-accent/--accent --border/--bg:3">
```

- `fg/bg` needs 4.5:1. Add `:3` for large text, borders and control states.
- Pair tokens are hex or `rgb()` — the script cannot read `oklch()` or `color-mix()`.
- Every `:root` block (light, dark, `[data-theme]`) is checked, so both themes must pass.
- Run `node <skill-dir>/check.mjs <file>...`. Exit 1 means a failure. Fix it, do not argue with it.
