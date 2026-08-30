# shadcn/ui — The Copy-In Component Layer

shadcn is not a dependency. The CLI writes component source into your repo and
leaves; from then on the code is yours to edit, and there is no version to bump
or upstream API to fight. That is the whole model, and the mistakes below all
come from treating it like a package instead.

## Contents

- [Base UI Is the Default Now](#base-ui-is-the-default-now)
- [The Files Are Yours — Edit Them](#the-files-are-yours--edit-them)
- [Variants Live in cva, Not in Props](#variants-live-in-cva-not-in-props)
- [cn() Is Not Optional](#cn-is-not-optional)
- [data-slot, and Styling Someone Else's Insides](#data-slot-and-styling-someone-elses-insides)
- [Where Your Components Go](#where-your-components-go)
- [Rules](#rules)

## Base UI Is the Default Now

Since **3 July 2026**, `shadcn init` wires new projects to **Base UI**, not Radix.

Radix is **not** deprecated. Both get every update and every new component, and an
existing Radix project needs no migration. Base UI adds primitives Radix never
had — Combobox, Autocomplete, Number Field, Checkbox Group, object-valued Select.

```bash
pnpm dlx shadcn init            # Base UI
pnpm dlx shadcn init -b radix   # stay on Radix
```

To move an existing project, migrate **one component at a time** — the repo stays
green between steps:

```bash
pnpm dlx skills add shadcn/ui
# then ask your agent: "migrate accordion to base-ui"
```

The import is the tell for which one a file is on:

```tsx
import { Button as ButtonPrimitive } from "@base-ui/react/button";       // Base UI
import * as DialogPrimitive from "@radix-ui/react-dialog";               // Radix
```

**Check that import before editing a component.** A repo can be part-migrated —
props and behaviour differ between the two, and a Radix pattern pasted into a Base
UI component compiles and then misbehaves.

## The Files Are Yours — Edit Them

```tsx
// BAD — a wrapper around a file you are allowed to open
export function PrimaryButton(props: ButtonProps) {
  return <Button className="bg-brand hover:bg-brand/90" {...props} />;
}

// GOOD — add the variant to the component itself
const buttonVariants = cva("cn-button …", {
  variants: {
    variant: { default: "…", brand: "bg-brand text-brand-foreground hover:bg-brand/90" },
  },
});
```

The wrapper looks harmless and then multiplies: every new need becomes another
wrapper, and nobody can tell which one to use. Editing `ui/button.tsx` is the
supported path, not a hack.

The cost is real and worth stating: `shadcn add button` again will offer to
overwrite your edits. Re-adding a component you have changed is a merge, not an
install — read the diff.

## Variants Live in cva, Not in Props

```tsx
// BAD — boolean props that multiply and cannot be composed
<Button isPrimary isLarge isDanger />

// GOOD — named variants, typed from the cva definition
const buttonVariants = cva(base, {
  variants: {
    variant: { default: "…", destructive: "…", outline: "…", ghost: "…" },
    size: { default: "…", sm: "…", lg: "…", icon: "…" },
  },
  defaultVariants: { variant: "default", size: "default" },
});

type Props = ButtonPrimitive.Props & VariantProps<typeof buttonVariants>;
```

`VariantProps` derives the prop types from the variants, so adding one to the cva
call is the only edit needed. Three booleans are eight states, most of which mean
nothing.

Variant values are class names, and they follow the same token discipline as
everything else: semantic tokens, never raw colours. `bg-destructive`, not
`bg-red-500`.

## cn() Is Not Optional

```tsx
// BAD — template strings; a caller's px-2 loses to the built-in px-4 by source order
<div className={`px-4 py-2 ${className}`} />

// GOOD — tailwind-merge resolves the conflict in the caller's favour
<div className={cn("px-4 py-2", className)} />
```

`cn` is `clsx` plus `tailwind-merge`. Without the merge, an override silently
depends on which rule Tailwind emitted first — it works in one place and not the
next, which is worse than failing.

Every component takes `className` and passes it through `cn` last.

## data-slot, and Styling Someone Else's Insides

Current shadcn components mark their parts with `data-slot`:

```tsx
<ButtonPrimitive data-slot="button" className={cn(buttonVariants({ variant, size, className }))} />
```

That gives a parent a stable hook into a child's internals without reaching for a
ref or a class the child might rename:

```tsx
<div className="[&_[data-slot=field-label]]:font-medium">
```

Use it for layout adjustments from a parent. Do not use it as a general escape
hatch for styling — if you are targeting three slots of one component, open the
component.

The `Field` family (`Field`, `FieldLabel`, `FieldDescription`, `FieldError`,
`FieldSet`, `FieldGroup`) is the current primitive for form layout, and
`FieldError` already renders `role="alert"`. Do not rebuild that with a `<div>`.

## Where Your Components Go

`components.json` decides where the CLI writes. `ui` is shadcn's; everything
beside it is yours.

```
components/ui/       shadcn — overwritten by `shadcn add`, edit deliberately
components/          yours  — composed from ui/, never touched by the CLI
lib/utils.ts         cn()
```

```jsonc
{
  "tsx": true,          // false rewrites .tsx → .jsx on the way in
  "aliases": { "components": "@/components", "ui": "@/components/ui" }
}
```

A feature component belongs in `components/`, not `components/ui/`. Putting it in
`ui/` means the next `shadcn add` can offer to overwrite it, and it blurs the one
line that makes the copy-in model legible: `ui/` came from upstream, the rest
did not.

## Rules

- Always check whether a component imports from `@base-ui/react/*` or `@radix-ui/*` before editing it — a repo can be part-migrated, and the patterns are not interchangeable.
- Always migrate to Base UI one component at a time; Radix is supported indefinitely and there is no deadline.
- Always edit `components/ui/*.tsx` directly instead of wrapping it — that is the model, and wrappers multiply.
- Always read the diff when re-adding a component you have edited; `shadcn add` overwrites.
- Always express variation as a `cva` variant with `VariantProps`, never as boolean props.
- Always pass `className` through `cn()` last, so a caller's class wins over the built-in.
- Always use the `Field` family for form layout — `FieldError` already carries `role="alert"`.
- Never put your own components in `components/ui/` — that directory means "came from upstream".
- Never use raw colour classes in a variant; use the project's semantic tokens.
