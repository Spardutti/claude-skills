# Loading, Error & Empty States

Every component that renders async data must handle **three** outcomes, not
one. Shipping only the happy path is the most common data-UI bug.

## Contents

- The loading / error / empty trio
- Skeletons vs spinners
- A reusable Skeleton primitive
- Avoiding layout shift
- Suspense + error boundary pairing
- Empty states
- Accessibility
- Rules

## The Loading / Error / Empty Trio

```tsx
// BAD: only the happy path — blank screen while loading, crash on error,
// confusing empty render when the list has no items
function MissionList() {
  const { data: missions } = useMissions();
  return <ul>{missions.map((m) => <MissionCard key={m.id} mission={m} />)}</ul>;
}

// GOOD: all three outcomes handled explicitly
function MissionList() {
  const { data: missions, isPending, isError } = useMissions();

  if (isPending) return <MissionListSkeleton />;
  if (isError) return <ErrorState onRetry={...} />;
  if (missions.length === 0) return <EmptyState />;

  return <ul>{missions.map((m) => <MissionCard key={m.id} mission={m} />)}</ul>;
}
```

Order matters: loading → error → empty → data. Each branch returns early so
the data render only runs when data genuinely exists.

## Skeletons vs Spinners

| Use a **skeleton** | Use a **spinner** |
|---|---|
| Content with known layout (lists, cards, tables, profile headers) | Unknown-shape or full-page transitions |
| First load of a data-driven view | A button's in-flight action |
| You want to communicate *what* is coming | Brief waits where layout is irrelevant |

Skeletons reduce perceived wait and prevent layout shift because they occupy
the final layout's space. A spinner communicates "busy" but nothing about the
result.

**The 200ms rule:** for fast actions, don't flash a loading indicator at all
under ~200ms — it reads as a flicker. Show the indicator only once the wait
crosses the threshold.

## A Reusable Skeleton Primitive

Build one token-styled primitive; compose page-specific skeletons from it.
Never hand-roll ad-hoc gray boxes per screen.

```tsx
// skeleton.tsx — the single primitive
function Skeleton({ className }: { className?: string }) {
  return (
    <div
      className={`animate-pulse rounded-md bg-muted ${className ?? ""}`}
      aria-hidden="true"
    />
  );
}

// mission-list-skeleton.tsx — composed from the primitive
function MissionListSkeleton() {
  return (
    <ul className="space-y-3" aria-busy="true" aria-live="polite">
      {Array.from({ length: 5 }).map((_, i) => (
        <li key={i} className="flex gap-3">
          <Skeleton className="size-12 rounded-full" />
          <div className="flex-1 space-y-2">
            <Skeleton className="h-4 w-3/4" />
            <Skeleton className="h-4 w-1/2" />
          </div>
        </li>
      ))}
    </ul>
  );
}
```

`bg-muted` and `animate-pulse` are design tokens / theme utilities — no
arbitrary colors. The skeleton is `aria-hidden`; the *container* carries the
`aria-busy` / `aria-live` (see Accessibility).

## Avoiding Layout Shift

A skeleton must occupy the **same dimensions** as the content it stands in
for. If the real card is `h-20`, the skeleton row is `h-20`. Mismatched sizes
cause a jump when data arrives — worse than a plain spinner.

```tsx
// BAD: skeleton is shorter than the real card → content jumps on load
<Skeleton className="h-8 w-full" />   // real card is h-20

// GOOD: skeleton matches the final layout box
<Skeleton className="h-20 w-full" />
```

Reserve space for images and async content with fixed dimensions or
aspect-ratio utilities so the page never reflows.

## Suspense + Error Boundary Pairing

`<Suspense>` handles the *loading* fallback; an error boundary handles the
*error* fallback. They are a pair — a Suspense boundary without an error
boundary leaves thrown errors uncaught.

```tsx
import { Suspense } from "react";
import { ErrorBoundary } from "react-error-boundary";

function MissionsPanel() {
  return (
    <ErrorBoundary fallback={<ErrorState />}>
      <Suspense fallback={<MissionListSkeleton />}>
        <MissionList />  {/* reads data with use() or useSuspenseQuery */}
      </Suspense>
    </ErrorBoundary>
  );
}
```

**Boundary placement:** wrap a *meaningful unit* of UI, not every leaf. One
boundary per independently-loading section — a dashboard widget, a route
segment — so the rest of the page stays interactive. Too granular and the page
flickers with many fallbacks; too coarse and one slow query blanks everything.

## Empty States

An empty result is a *designed* state, not a blank `<ul>`. It tells the user
why there's nothing and what to do next.

```tsx
// BAD: empty array renders nothing — looks broken
return <ul>{missions.map(...)}</ul>;

// GOOD: a purposeful empty state
function EmptyState() {
  return (
    <div className="flex flex-col items-center gap-3 py-12 text-center">
      <InboxIcon className="size-12 text-muted-foreground" />
      <p className="text-muted-foreground">No missions yet.</p>
      <Button onClick={openCreateDialog}>Create your first mission</Button>
    </div>
  );
}
```

Distinguish **empty** (no data exists — offer a create action) from **no
results** (a filter/search excluded everything — offer to clear the filter).
They are different messages.

## Accessibility

Loading and async UI must be announced, not just shown.

```tsx
// Loading region: announce busy state to assistive tech
<div aria-busy="true" aria-live="polite">
  <MissionListSkeleton />
</div>

// Status / spinner: role="status" announces politely on change
<div role="status">
  <Spinner />
  <span className="sr-only">Loading missions…</span>
</div>

// Error: assertive so it interrupts
<div role="alert">Could not load missions. <button>Retry</button></div>
```

- **`aria-busy="true"`** on the container while data loads; remove it when done.
- **`aria-live="polite"`** (or `role="status"`) so the resolved content is announced.
- **`role="alert"`** for errors — announced immediately.
- A visual-only spinner needs an `sr-only` text label.
- After an async transition, **move focus** to the new content (or its heading)
  so keyboard and screen-reader users land in the right place.

## Rules

1. **Handle the loading / error / empty trio** in every data-driven component — never ship only the happy path.
2. **Branch in order:** loading → error → empty → data, each as an early return.
3. **Skeletons for known layouts, spinners for unknown-shape or brief waits.**
4. **Build one `Skeleton` primitive** styled with design tokens; compose page skeletons from it — no ad-hoc gray boxes.
5. **Match skeleton dimensions to the final content** — mismatched sizes cause layout shift.
6. **Don't flash a loading indicator under ~200ms** — it reads as a flicker.
7. **Pair every `<Suspense>` with an error boundary** — Suspense covers loading, the boundary covers errors.
8. **Place boundaries around meaningful units** — one per independently-loading section, not per leaf.
9. **Design the empty state** — explain why it's empty and offer the next action; distinguish "empty" from "no filter results".
10. **Announce async UI:** `aria-busy` while loading, `aria-live` / `role="status"` for status, `role="alert"` for errors, `sr-only` labels for icon-only spinners.
11. **Move focus to new content** after an async transition.
