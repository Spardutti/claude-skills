# React Performance

## Contents

- React Compiler v1.0 — manual memoization is now an anti-pattern
- The 3 narrow exceptions where manual memo still applies
- Re-render causes and how to diagnose
- Stable keys — never index keys for dynamic lists
- List virtualization
- Code splitting with `lazy` + Suspense
- `useDeferredValue` and `useTransition`
- `<Activity>` for pre-rendering and keep-alive
- Profiling with React DevTools

## React Compiler v1.0 — Stop Manual Memoization

React Compiler reached **v1.0 (stable) in October 2025**. It is a build-time plugin
(Babel/SWC/Vite) that auto-memoizes components and hook values at a finer granularity
than hand-written memo. Next.js 16 ships it built-in.

**In a compiler-enabled project, `useMemo` / `useCallback` / `React.memo` are
boilerplate.** The compiler produces the equivalent automatically. Manual memo adds
maintenance cost, noise, and stale-dependency bugs for ~95% of components.

```tsx
// BAD: hand-written memoization in a compiler-enabled project
function ProductList({ products, query }: Props) {
  const filtered = useMemo(
    () => products.filter((p) => p.name.includes(query)),
    [products, query],
  );
  const handleSelect = useCallback((id: string) => select(id), []);
  return <List items={filtered} onSelect={handleSelect} />;
}

// GOOD: write it plainly — the compiler memoizes filtered and handleSelect
function ProductList({ products, query }: Props) {
  const filtered = products.filter((p) => p.name.includes(query));
  const handleSelect = (id: string) => select(id);
  return <List items={filtered} onSelect={handleSelect} />;
}
```

The compiler **coexists** with existing manual memo — adoption is gradual, not
big-bang. But new code should not add `useMemo`/`useCallback`/`React.memo`.

The compiler only optimizes code that follows the Rules of React (pure render, no
mutation of props/state). It silently skips components it cannot prove safe.
`eslint-plugin-react-hooks` v6+ flags the violations that block optimization — keep
it on.

**The compiler optimizes re-renders. It does not fix architecture.** You still must
derive state during render, use `key` to reset subtrees, and avoid unnecessary
Effects. Memoization is not a substitute for those.

## The 3 Narrow Exceptions

Manual memoization is still legitimate in exactly these cases:

```tsx
// 1. Passing a value to a NON-React system that compares by reference —
//    e.g. a third-party hook's dependency array, or a memoized selector.
const options = useMemo(() => ({ strict: true, locale }), [locale]);
useThirdPartyChart(data, options); // re-inits if options identity changes

// 2. A genuinely expensive computation where you MEASURED a real problem
//    the compiler's heuristics do not cover.
const histogram = useMemo(() => computeHistogram(millionRows), [millionRows]);

// 3. Code that cannot adopt the compiler (legacy bundler, gradual rollout).
```

If a `useMemo`/`useCallback` does not fall into one of these three, delete it.

## Re-render Causes and How to Diagnose

A component re-renders when: its state changes, its parent re-renders, or a Context
it consumes changes value. Most "performance problems" are unnecessary re-renders
caused by unstable values or state placed too high in the tree.

```tsx
// BAD: a new object every render — every consumer re-renders on any change
<ThemeContext value={{ theme, toggle }}>

// GOOD: split rarely-changing config from frequently-changing state,
//       or let the compiler stabilize the object (it will, if pure)
<ThemeContext value={{ theme, toggle }}>  // compiler memoizes this object
```

```tsx
// BAD: state lives too high — typing in the search box re-renders the whole page
function Page() {
  const [query, setQuery] = useState("");
  return (
    <>
      <ExpensiveSidebar />
      <SearchBox value={query} onChange={setQuery} />
      <Results query={query} />
    </>
  );
}

// GOOD: push state down so only the subtree that needs it re-renders
function Page() {
  return (
    <>
      <ExpensiveSidebar />
      <SearchSection />
    </>
  );
}
```

Move state down, or lift expensive siblings into `children` so they are not
re-created by the stateful parent.

## Stable Keys — Never Index Keys for Dynamic Lists

A list `key` is React's identity for a row. An array index is positional, not
identity — when the list reorders, inserts, or deletes, index keys make React
associate the wrong DOM and state with the wrong item.

```tsx
// BAD: index key — reordering corrupts row state (inputs, selection, focus)
{todos.map((todo, i) => <TodoRow key={i} todo={todo} />)}

// GOOD: stable key from the item's own identity
{todos.map((todo) => <TodoRow key={todo.id} todo={todo} />)}
```

Index keys are acceptable only for a static list that never reorders, never filters,
and has no per-row state. When in doubt, use a stable ID.

`key` also drives **resets**: changing `key={userId}` remounts a subtree and clears
its state — the correct way to reset state on a prop change.

## List Virtualization

Rendering thousands of DOM nodes is slow regardless of memoization. Virtualize long
lists so only the visible rows mount.

```tsx
// BAD: 10,000 rows all in the DOM
<ul>{rows.map((r) => <Row key={r.id} row={r} />)}</ul>

// GOOD: render only what is on screen (TanStack Virtual)
function VirtualList({ rows }: { rows: Row[] }) {
  const parentRef = useRef<HTMLDivElement>(null);
  const virtualizer = useVirtualizer({
    count: rows.length,
    getScrollElement: () => parentRef.current,
    estimateSize: () => 48,
  });
  return (
    <div ref={parentRef} className="h-96 overflow-auto">
      <div style={{ height: virtualizer.getTotalSize() }}>
        {virtualizer.getVirtualItems().map((item) => (
          <RowView key={rows[item.index].id} row={rows[item.index]} item={item} />
        ))}
      </div>
    </div>
  );
}
```

Virtualize any list that can grow past a few hundred rows.

## Code Splitting with `lazy` + Suspense

Ship less JavaScript up front. Split routes and heavy, rarely-used components.

```tsx
// BAD: the chart library is in the main bundle even on pages without a chart
import { AnalyticsDashboard } from "./AnalyticsDashboard";

// GOOD: load it only when rendered
const AnalyticsDashboard = lazy(() => import("./AnalyticsDashboard"));

function Reports() {
  return (
    <Suspense fallback={<DashboardSkeleton />}>
      <AnalyticsDashboard />
    </Suspense>
  );
}
```

Place Suspense boundaries per meaningful section — a granular fallback (skeleton)
beats one app-wide spinner. Boundaries also let independent sections stream in
without blocking each other.

## `useDeferredValue` and `useTransition`

Both keep the UI responsive during expensive updates by marking work as
non-urgent. The urgent update (typing, clicking) commits immediately; the heavy
re-render runs at lower priority and can be interrupted.

```tsx
// useDeferredValue: input stays snappy; the heavy list lags behind one render
function Search() {
  const [query, setQuery] = useState("");
  const deferredQuery = useDeferredValue(query);
  return (
    <>
      <input value={query} onChange={(e) => setQuery(e.target.value)} />
      <SlowResults query={deferredQuery} />
    </>
  );
}

// useTransition: mark a state update as non-urgent and read its pending flag
function TabBar({ tabs }: { tabs: Tab[] }) {
  const [active, setActive] = useState(tabs[0].id);
  const [isPending, startTransition] = useTransition();
  return (
    <div data-busy={isPending}>
      {tabs.map((t) => (
        <button key={t.id} onClick={() => startTransition(() => setActive(t.id))}>
          {t.label}
        </button>
      ))}
    </div>
  );
}
```

Use `useDeferredValue` when you only have the value; `useTransition` when you own the
state setter and want a pending flag.

## `<Activity>` for Pre-rendering and Keep-alive

`<Activity>` (React 19.2) renders a subtree in the background or keeps it alive
while hidden. `mode="hidden"` unmounts effects and defers updates, but **preserves
state** — unlike conditionally rendering `null`, which destroys it.

```tsx
// BAD: switching tabs destroys the inactive tab's state (scroll, form input)
{tab === "settings" ? <SettingsPanel /> : <ProfilePanel />}

// GOOD: keep both mounted; hidden one preserves state and pre-renders
<Activity mode={tab === "settings" ? "visible" : "hidden"}>
  <SettingsPanel />
</Activity>
<Activity mode={tab === "profile" ? "visible" : "hidden"}>
  <ProfilePanel />
</Activity>
```

Use it for tab panels, prefetched routes, and hidden modals — anywhere a subtree
will likely become visible soon and should not pay mount cost or lose state.

## Profiling with React DevTools

Measure before optimizing. The compiler removes most manual-memo decisions; what is
left is finding the real hotspot.

- **DevTools Profiler tab** — record an interaction, inspect the flamegraph. Wide
  bars are slow renders; check "why did this render?" in the component panel.
- **"Highlight updates when components render"** — visually flags components
  re-rendering on every keystroke or tick.
- **Performance Tracks** (React 19.2) — React-specific Chrome DevTools tracks
  (Scheduler, Components) show committed work against the browser timeline.

Profile a production build — dev builds carry extra checks that skew timings.

## Rules

1. **In compiler-enabled projects, never add `useMemo`/`useCallback`/`React.memo`** —
   write code plainly and let the compiler memoize.
2. **Keep manual memo only for the 3 exceptions** — a non-React reference-comparing
   consumer, a measured expensive computation, or code that cannot adopt the compiler.
3. **Keep `eslint-plugin-react-hooks` v6+ on** — it flags Rules-of-React violations
   that block the compiler.
4. **Never use array indices as keys** for lists that reorder, filter, or hold
   per-row state — use a stable ID.
5. **Use `key` to reset** a subtree's state on a prop change instead of an Effect.
6. **Push state down** and lift expensive siblings into `children` to limit
   re-render scope.
7. **Virtualize** any list that can exceed a few hundred rows.
8. **Code-split routes and heavy components** with `lazy` + granular Suspense
   boundaries.
9. **Use `useDeferredValue` / `useTransition`** to keep input responsive during
   expensive updates.
10. **Use `<Activity mode="hidden">`** to keep-alive or pre-render subtrees instead
    of conditionally rendering `null` and losing state.
11. **Profile before optimizing** — measure with the DevTools Profiler on a
    production build; never guess.
