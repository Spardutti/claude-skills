# Tailwind Design Tokens — Tokens Only, No Arbitrary Values

**Core rule: every visual value in a `className` must resolve to a defined design
token.** Colors, spacing, radius, typography, shadows — all of it. If no token
fits what you need, **add a token**. Never invent a raw value, never reach for an
arbitrary bracket value. This is non-negotiable: arbitrary values are how palettes
drift and rebrands become a file hunt.

## Contents

- Tailwind v4 CSS-first `@theme` config
- Locking down the palette with the `--color-*: initial` reset
- Semantic color tokens, never raw palette
- Banned: arbitrary values
- Spacing scale discipline
- Typography, radius, and shadow tokens
- `@theme inline` for layered semantic tokens
- When no token fits — add one
- The narrow arbitrary-value exceptions
- ESLint enforcement — make it machine-checked

## Tailwind v4 CSS-First `@theme` Config

Tailwind v4 has no `tailwind.config.js`. The theme lives in CSS. A single entry
file imports Tailwind and declares tokens in an `@theme` block. `@theme` does double
duty: it declares CSS variables **and** generates the matching utility classes.
A token only becomes a usable class if it lives in `@theme`.

```css
/* app.css */
@import "tailwindcss";

@theme {
  --color-background: oklch(1 0 0);
  --color-foreground: oklch(0.2 0.02 250);
  --color-primary: oklch(0.55 0.18 255);
  --color-muted: oklch(0.96 0.01 250);
  --radius-card: 0.75rem;
  --shadow-card: 0 1px 3px oklch(0 0 0 / 0.1);
}
```

Token namespaces determine which utilities are generated:

| Namespace | Generates | Example token |
|---|---|---|
| `--color-*` | `bg-`, `text-`, `border-`, `ring-` | `--color-primary` |
| `--spacing` / `--spacing-*` | `p-`, `m-`, `gap-`, `w-`, `h-` | `--spacing: 0.25rem` |
| `--radius-*` | `rounded-` | `--radius-lg` |
| `--text-*` | `text-` (size) | `--text-base` |
| `--font-*` | `font-` (family) | `--font-sans` |
| `--font-weight-*` | `font-` (weight) | `--font-weight-semibold` |
| `--leading-*` | `leading-` | `--leading-tight` |
| `--shadow-*` | `shadow-` | `--shadow-md` |
| `--breakpoint-*` | `sm:` `md:` … | `--breakpoint-md` |

## Locking Down the Palette — The `initial` Reset

By default Tailwind ships its full color palette (`red-500`, `gray-200`, `blue-600`
…). Those are exactly the random colors that must not appear in the codebase. **Reset
the namespace to `initial` so the entire default palette stops existing**, then
declare only your semantic tokens.

```css
/* GOOD: nuke the default palette — only defined tokens survive */
@theme {
  --color-*: initial; /* removes EVERY built-in color utility */

  --color-background: oklch(1 0 0);
  --color-foreground: oklch(0.2 0.02 250);
  --color-surface: oklch(0.98 0.005 250);
  --color-primary: oklch(0.55 0.18 255);
  --color-primary-foreground: oklch(0.99 0 0);
  --color-muted: oklch(0.96 0.01 250);
  --color-muted-foreground: oklch(0.5 0.02 250);
  --color-destructive: oklch(0.58 0.22 27);
  --color-border: oklch(0.92 0.01 250);
}
```

After this reset, `bg-red-500` simply **does not compile** — the strongest possible
enforcement. The same `initial` trick works for `--spacing-*`, `--text-*`, etc. if
you want to constrain those namespaces too.

## Semantic Color Tokens, Never Raw Palette

Name colors by **role**, not by hue. `bg-surface` survives a rebrand; `bg-gray-200`
does not. Light/dark is handled by redefining the underlying variables under a
`.dark` selector — components never change.

```tsx
// BAD: raw palette — hardcoded, ignores the theme, breaks on rebrand
<div className="bg-gray-200 text-gray-700 border-gray-300">
  <p className="text-red-600">Payment failed</p>
</div>

// GOOD: semantic role tokens — one CSS change re-themes the whole app
<div className="bg-surface text-foreground border-border">
  <p className="text-destructive">Payment failed</p>
</div>
```

```tsx
// BAD: hue-named, no meaning
<span className="text-green-600">Active</span>

// GOOD: role-named
<span className="text-success">Active</span>
```

## Banned: Arbitrary Values

**Arbitrary bracket values are forbidden.** `text-[#3a3a3a]`, `p-[13px]`,
`w-[437px]`, `font-[700]`, `rounded-[9px]` — every one of these bypasses the token
system and is a future drift bug. They are the exact failure mode this skill exists
to stop. Always map an arbitrary value to a token.

```tsx
// BAD: arbitrary color — invents a value outside the system
<button className="bg-[#3b82f6] text-[#ffffff]">Save</button>
// GOOD: map to tokens
<button className="bg-primary text-primary-foreground">Save</button>

// BAD: arbitrary spacing — 13px belongs to no scale
<div className="p-[13px] mt-[27px] gap-[5px]">
// GOOD: snap to the spacing scale
<div className="p-3 mt-6 gap-1">

// BAD: arbitrary size, radius, weight
<div className="w-[437px] rounded-[9px] font-[650]">
// GOOD: tokens
<div className="w-md rounded-card font-semibold">
```

If you catch yourself typing a `[` inside a `className`, stop — find or add a token.

## Spacing Scale Discipline

Tailwind v4 derives the whole spacing scale from one `--spacing` base; `p-4` =
`4 × --spacing`. Pick the **semantic step**, not an arbitrary number.

| Step | Class | Use for |
|---|---|---|
| xs | `1` | Icon gaps, tight nav items |
| sm | `2` | Label↔input, inline groups |
| md | `4` | Component padding, grid gaps, card grids |
| lg | `6` | Sub-section separation |
| xl | `8` | Top-level page sections |
| 2xl | `12` | Hero / landing section separation |

```tsx
// GOOD: semantic spacing — consistent rhythm
<section className="space-y-8">
  <header className="space-y-2">
    <h1>Title</h1>
    <p>Subtitle</p>
  </header>
  <div className="grid gap-4">{/* cards */}</div>
</section>

// BAD: odd values fall between semantic steps — inconsistency
<section className="space-y-7">
  <header className="space-y-3">{/* ... */}</header>
  <div className="grid gap-5">{/* ... */}</div>
</section>
```

Avoid `3`, `5`, `7` for layout spacing — they sit between semantic steps. `3` is
acceptable only for component-internal padding (`px-3`) where an existing pattern
already uses it (table cells, nav links).

## Typography, Radius, and Shadow Tokens

Use the predefined scales — never arbitrary sizes.

```tsx
// GOOD
<h1 className="text-3xl font-bold leading-tight">Title</h1>
<div className="rounded-lg shadow-md" />

// BAD: arbitrary typography and radius
<h1 className="text-[28px] font-[700] leading-[1.15]">Title</h1>
<div className="rounded-[10px] shadow-[0_2px_8px_rgba(0,0,0,0.12)]" />
```

Font size: `text-xs`…`text-4xl`. Weight: `font-normal`/`medium`/`semibold`/`bold`.
Line height: `leading-none`…`leading-loose`. Radius: `rounded-sm`…`rounded-full`.
Shadow: `shadow-sm`…`shadow-2xl`.

## `@theme inline` for Layered Semantic Tokens

When a theme token references another variable — a semantic token layered over a raw
value, or a value that changes per theme — use `@theme inline`. It makes the
generated utilities emit the resolved variable instead of a frozen snapshot, so
`.dark` overrides take effect.

```css
@theme inline {
  --color-primary: var(--brand);
  --color-surface: var(--surface);
}

:root {
  --brand: oklch(0.55 0.18 255);
  --surface: oklch(0.98 0.005 250);
}

.dark {
  --brand: oklch(0.68 0.16 255);
  --surface: oklch(0.22 0.01 250);
}
```

`bg-primary` and `bg-surface` now follow `.dark` automatically — no component change.

## When No Token Fits — Add One

The answer to "there is no token for this" is **add a token**, never an arbitrary
value.

```css
/* A new role appeared. Add it to @theme — now it is a first-class token. */
@theme inline {
  --color-warning: var(--warning);
}
:root  { --warning: oklch(0.75 0.15 75); }
.dark  { --warning: oklch(0.80 0.14 75); }
```

```tsx
// Now usable everywhere, theme-aware, rebrand-safe
<div className="bg-warning text-foreground">Quota almost reached</div>
```

## The Narrow Arbitrary-Value Exceptions

Arbitrary values are acceptable in **only** two cases, and even then extract a token
if the value repeats:

```tsx
// 1. calc()/clamp()/min()/max() that COMBINE existing tokens
<div className="h-[calc(100vh-var(--spacing)*16)]" />

// 2. Genuine runtime data — a value not knowable at build time
<div className="bg-[var(--user-accent)]" /> // user-chosen color from an API
```

A hardcoded hex, px, or weight is never one of these exceptions.

## ESLint Enforcement — Make It Machine-Checked

A guideline humans (and AI) can ignore is not enforcement. Add a lint rule so
arbitrary values fail CI.

```js
// eslint.config.js — v4-native, theme-aware rules
import tailwind from "@poupe/eslint-plugin-tailwindcss";

export default [
  {
    plugins: { tailwindcss: tailwind },
    rules: {
      "tailwindcss/no-arbitrary-value-overuse": "error",
      "tailwindcss/prefer-theme-tokens": "error",
    },
  },
];
```

Other options: `oxlint-tailwindcss` ships `no-hardcoded-colors`, which blocks
`bg-[#ff5733]` and arbitrary color brackets outright; `eslint-plugin-better-tailwindcss`
provides `no-unnecessary-arbitrary-value`, which rewrites `m-[1.25rem]` → `m-5`.
Pick one and run it in CI so the no-arbitrary-values rule is enforced by the build,
not by review.

## Rules

1. **NEVER use arbitrary bracket values** for colors, spacing, sizes, radius,
   typography, or shadows — `text-[#hex]`, `p-[13px]`, `w-[437px]`, `font-[700]` are
   forbidden. Map every one to a token.
2. **NEVER use Tailwind's raw palette** — `red-500`, `gray-200`, `blue-600` are
   banned; use semantic role tokens.
3. **Always reset `--color-*: initial`** in `@theme` so the default palette cannot
   compile — make the constraint structural.
4. **Always name colors by role**, not hue — `bg-surface`, `text-muted-foreground`,
   `bg-destructive`, never `bg-gray-200`.
5. **When no token fits, add a token to `@theme`** — never substitute an arbitrary
   value.
6. **Always pick spacing from the semantic scale** (`1, 2, 4, 6, 8, 12`); avoid
   `3, 5, 7` for layout.
7. **Always use the predefined typography, radius, and shadow scales** — no
   arbitrary sizes.
8. **Use `@theme inline`** for semantic tokens layered over raw variables so
   light/dark overrides apply.
9. **Arbitrary values are allowed only** for `calc()`/`clamp()` combining tokens or
   genuine runtime data — never a hardcoded hex or px.
10. **Enforce no-arbitrary-values in ESLint/CI** — a token rule that is not
    machine-checked will be violated.
11. **Apply the rebrand test:** if changing `app.css` alone cannot re-theme the app,
    a raw value is hiding in a component — find and tokenize it.
