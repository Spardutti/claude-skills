---
name: tailwind-tokens
description: Enforce Tailwind CSS design tokens. Never hardcode arbitrary values — always use the predefined spacing scale, color palette, typography tokens, and theme variables.
---

# Tailwind CSS Design Tokens

Always use Tailwind's predefined utility classes and design tokens. Never use arbitrary bracket values (`[...]`) for properties that have a token available in the theme.

## Spacing

Use the numeric spacing scale (`0`, `0.5`, `1`, `1.5`, `2`, `3`, `4`, `5`, `6`, `8`, `10`, `12`, `16`, `20`, `24`, `32`, `40`, `48`, `64`, `80`, `96`) for all spacing utilities — padding, margin, gap, width, height, inset, etc.

```html
<!-- GOOD: uses spacing tokens -->
<div class="p-4 mt-6 gap-3 w-64">...</div>

<!-- BAD: arbitrary pixel values -->
<div class="p-[15px] mt-[23px] gap-[13px] w-[267px]">...</div>
```

If no predefined value fits, extend the theme rather than using arbitrary values:

```css
/* v4: @theme directive */
@theme {
  --spacing: 0.25rem; /* base multiplier */
}

/* v3: tailwind.config.js */
module.exports = {
  theme: {
    extend: {
      spacing: {
        '18': '4.5rem',
        '88': '22rem',
      },
    },
  },
}
```

## Colors

Use the built-in color palette (`slate`, `gray`, `zinc`, `neutral`, `stone`, `red`, `orange`, `amber`, `yellow`, `lime`, `green`, `emerald`, `teal`, `cyan`, `sky`, `blue`, `indigo`, `violet`, `purple`, `fuchsia`, `pink`, `rose`) with their shade scales (`50`–`950`).

```html
<!-- GOOD: uses color tokens -->
<p class="text-gray-700 bg-blue-100 border-red-500">...</p>

<!-- BAD: arbitrary hex/rgb values -->
<p class="text-[#374151] bg-[rgb(219,234,254)] border-[#ef4444]">...</p>
```

For brand or custom colors, define them as theme tokens:

```css
/* v4 */
@theme {
  --color-brand-50: oklch(0.97 0.01 250);
  --color-brand-500: oklch(0.55 0.18 250);
  --color-brand-900: oklch(0.25 0.10 250);
}

/* Then use: bg-brand-500, text-brand-900, etc. */
```

```js
// v3: tailwind.config.js
module.exports = {
  theme: {
    extend: {
      colors: {
        brand: {
          50: '#f0f4ff',
          500: '#3b5bdb',
          900: '#1c2d5a',
        },
      },
    },
  },
}
```

## Typography

Use the predefined font-size scale (`text-xs`, `text-sm`, `text-base`, `text-lg`, `text-xl`, `text-2xl`, `text-3xl`, `text-4xl`, `text-5xl`, `text-6xl`, `text-7xl`, `text-8xl`, `text-9xl`).

Use predefined font-weight tokens (`font-thin`, `font-light`, `font-normal`, `font-medium`, `font-semibold`, `font-bold`, `font-extrabold`, `font-black`).

Use predefined line-height tokens (`leading-none`, `leading-tight`, `leading-snug`, `leading-normal`, `leading-relaxed`, `leading-loose`) or the numeric scale (`leading-3` through `leading-10`).

```html
<!-- GOOD -->
<h1 class="text-3xl font-bold leading-tight">Title</h1>

<!-- BAD -->
<h1 class="text-[28px] font-[700] leading-[1.15]">Title</h1>
```

## Border Radius

Use the predefined radius tokens (`rounded-none`, `rounded-sm`, `rounded`, `rounded-md`, `rounded-lg`, `rounded-xl`, `rounded-2xl`, `rounded-3xl`, `rounded-full`).

```html
<!-- GOOD -->
<div class="rounded-lg">...</div>

<!-- BAD -->
<div class="rounded-[10px]">...</div>
```

## Shadows

Use the predefined shadow tokens (`shadow-sm`, `shadow`, `shadow-md`, `shadow-lg`, `shadow-xl`, `shadow-2xl`, `shadow-none`).

```html
<!-- GOOD -->
<div class="shadow-lg">...</div>

<!-- BAD -->
<div class="shadow-[0_4px_12px_rgba(0,0,0,0.15)]">...</div>
```

## Opacity

Use the predefined opacity scale (`opacity-0`, `opacity-5`, `opacity-10`, `opacity-15`, `opacity-20`, `opacity-25`, `opacity-30`, ..., `opacity-100`).

```html
<!-- GOOD -->
<div class="opacity-75">...</div>

<!-- BAD -->
<div class="opacity-[0.73]">...</div>
```

## Z-Index

Use the predefined z-index tokens (`z-0`, `z-10`, `z-20`, `z-30`, `z-40`, `z-50`, `z-auto`).

```html
<!-- GOOD -->
<div class="z-10">...</div>

<!-- BAD -->
<div class="z-[15]">...</div>
```

## Transitions & Durations

Use the predefined duration tokens (`duration-75`, `duration-100`, `duration-150`, `duration-200`, `duration-300`, `duration-500`, `duration-700`, `duration-1000`).

```html
<!-- GOOD -->
<button class="transition-colors duration-200">...</button>

<!-- BAD -->
<button class="transition-colors duration-[250ms]">...</button>
```

## When Arbitrary Values Are Acceptable

Arbitrary values are **only** acceptable when:

1. **Dynamic data** — values come from a CMS, API, or user input at runtime and cannot be known ahead of time (e.g., `bg-[var(--user-color)]`)
2. **CSS functions** — `calc()`, `clamp()`, `min()`, `max()` expressions that combine tokens (e.g., `h-[calc(100vh-4rem)]`, `w-[min(100%,48rem)]`)
3. **One-off layout constraints** — viewport-relative or container-based calculations that have no token equivalent

Even in these cases, prefer extracting the value into a theme token if it's reused more than once.

## Rules

1. **Never** use arbitrary bracket values when a Tailwind token exists — spacing, colors, font sizes, radii, shadows, etc.
2. **Never** hardcode hex colors, rgb values, or pixel measurements in class names
3. **Always** extend the theme for project-specific values instead of using `[...]` syntax
4. **Always** use the closest token value — if the design calls for `15px` padding, use `p-4` (16px) and align with the design system
5. **Always** define custom design tokens in `@theme` (v4) or `tailwind.config.js` (v3) when the default scale doesn't cover your needs
6. **Always** prefer semantic color names (via theme extension) over raw color values for brand-specific colors
