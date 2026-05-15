---
name: react
category: Frontend
description: "MUST USE when writing or editing React components, hooks, state management, effects, performance, loading/empty states, Zustand stores, or styling. Covers React 19.2 (use, Actions, useActionState, useOptimistic, useFormStatus, ref as prop, Context provider, Activity), the Rules of Hooks, React Compiler v1.0 memoization, component splitting and custom hooks, composition over boolean props, useEffect avoidance, re-render performance, list keys, loading skeletons and empty states, Zustand client-state stores, and Tailwind v4 design tokens."
---

# React — Components, Hooks, State, Styling

Modern React component, state, effect, and styling patterns. Baseline is React 19.2 + React Compiler v1.0 (stable since October 2025) and Tailwind v4.

## Quick Reference — When to Load What

| Working on… | Read |
|---|---|
| Splitting components, custom hooks, file size, prop drilling | COMPONENT-DESIGN.md |
| useEffect — whether you even need one, cleanup, dependency arrays | USE-EFFECT.md |
| Re-renders, memoization, React Compiler, list keys, `<Activity>` | PERFORMANCE.md |
| Loading skeletons, empty states, Suspense + error boundary pairing | LOADING-STATES.md |
| Client state stores — Zustand, selectors, middleware, slices | ZUSTAND.md |
| Styling — colors, spacing, design tokens, no arbitrary values | TAILWIND-TOKENS.md |

## Critical Gotchas (Always-Inline)

These are the highest-leverage React 19 mistakes. Memorize them.

### 1. `ref` Is a Normal Prop — No `forwardRef`

```tsx
// BAD: forwardRef is deprecated in React 19
const Input = forwardRef<HTMLInputElement, InputProps>((props, ref) => (
  <input ref={ref} {...props} />
));

// GOOD: ref is just a prop
function Input({ ref, ...props }: InputProps & { ref?: React.Ref<HTMLInputElement> }) {
  return <input ref={ref} {...props} />;
}
```

### 2. `<Context>` Is the Provider — No `.Provider`

```tsx
const ThemeContext = createContext<Theme>("light");

// BAD: .Provider is deprecated
<ThemeContext.Provider value={theme}>{children}</ThemeContext.Provider>

// GOOD: render the context itself
<ThemeContext value={theme}>{children}</ThemeContext>
```

### 3. `use()` Reads Context and Promises — Conditionally

Unlike `useContext`, `use()` works inside `if` blocks and loops, and unwraps promises with Suspense.

```tsx
import { use } from "react";

function Panel({ show }: { show: boolean }) {
  if (!show) return null;
  const theme = use(ThemeContext);     // legal inside a conditional
  return <hr className={theme} />;
}
```

### 4. Derive State During Render — Don't Sync It in an Effect

```tsx
// BAD: extra state + an Effect that lags one render behind
const [filtered, setFiltered] = useState(items);
useEffect(() => setFiltered(items.filter(i => i.active)), [items]);

// GOOD: compute during render — no state, no Effect
const filtered = items.filter(i => i.active);
```

If a value can be computed from props or other state, it is not state. See USE-EFFECT.md.

### 5. Forms Use Actions — `useActionState`, Not Manual Flags

`useActionState` tracks pending state and errors so you don't hand-roll `isSubmitting`.

```tsx
const [error, submitAction, isPending] = useActionState(
  async (_prev: string | null, formData: FormData) => {
    const result = await createPost({ title: formData.get("title") as string });
    return result.error ?? null;
  },
  null,
);

return (
  <form action={submitAction}>
    <input name="title" required />
    <button type="submit" disabled={isPending}>{isPending ? "Posting…" : "Create"}</button>
    {error && <p className="text-destructive">{error}</p>}
  </form>
);
```

### 6. `useFormStatus` Reads Form State Without Prop Drilling

A reusable submit button reads its parent `<form>`'s pending state directly.

```tsx
import { useFormStatus } from "react-dom";

// GOOD: no isPending prop threaded down
function SubmitButton({ children }: { children: React.ReactNode }) {
  const { pending } = useFormStatus();
  return <button type="submit" disabled={pending}>{pending ? "Saving…" : children}</button>;
}
```

`useFormStatus` must be called from a component rendered *inside* the `<form>`.

### 7. `useOptimistic` for In-Flight UI

```tsx
const [optimisticMessages, addOptimistic] = useOptimistic(
  messages,
  (state: Message[], text: string) => [...state, { id: crypto.randomUUID(), text, sending: true }],
);
// call addOptimistic(text) inside the action; React reverts automatically on settle
```

### 8. Manual `useMemo` / `useCallback` / `React.memo` Is an Anti-Pattern

React Compiler v1.0 is stable and auto-memoizes. Hand-written memo is now boilerplate.

```tsx
// BAD: noise the compiler already handles
const UserCard = React.memo(({ user }: { user: User }) => {
  const name = useMemo(() => formatName(user.name), [user.name]);
  const onClick = useCallback(() => selectUser(user.id), [user.id]);
  return <button onClick={onClick}>{name}</button>;
});

// GOOD: write it plainly — the compiler memoizes
function UserCard({ user }: { user: User }) {
  return <button onClick={() => selectUser(user.id)}>{formatName(user.name)}</button>;
}
```

Three narrow exceptions remain (third-party reference equality, measured-expensive computation, no-compiler codebases). See PERFORMANCE.md.

### 9. Stable Keys — Never Index Keys for Dynamic Lists

Index keys corrupt state when the list reorders, inserts, or deletes.

```tsx
// BAD: index key
{todos.map((todo, i) => <TodoItem key={i} todo={todo} />)}

// GOOD: stable identity
{todos.map(todo => <TodoItem key={todo.id} todo={todo} />)}

// GOOD: key to remount-and-reset a subtree on identity change
<ProfileForm key={userId} userId={userId} />
```

### 10. Don't Initialize State From Props Without Care

```tsx
// BAD: stale forever — prop changes never update the state
function Editor({ initialText }: { initialText: string }) {
  const [text, setText] = useState(initialText);
}
```

If the copy must reset when the prop changes, use a `key` (gotcha 9). If the parent owns the value, lift state up instead.

### 11. Rules of Hooks — Call Them at the Top Level

Hooks are tracked by call order. They must run at the top level of a component or custom hook — never inside conditions, loops, or after an early return.

```tsx
// BAD: hook after an early return — call order changes when `user` is null
function Profile({ user }: { user: User | null }) {
  if (!user) return null;
  const [tab, setTab] = useState("home"); // skipped on some renders
}

// GOOD: all hooks first, unconditionally; branch afterwards
function Profile({ user }: { user: User | null }) {
  const [tab, setTab] = useState("home");
  if (!user) return null;
}
```

`use()` is the *only* hook that may be called conditionally (gotcha 3). Every other hook — `useState`, `useEffect`, `useReducer`, custom hooks — is top-level only. See USE-EFFECT.md for the full Effect catalog.

## When to Use What

| Decision | Use |
|---|---|
| Single value, toggle, form field | `useState` |
| Multiple related values updated together | `useReducer` |
| Value computable from props/state | derive during render — not state |
| Read context | `use(Context)` — never `useContext` |
| Global, rarely-changing value (theme, auth, locale) | Context |
| Pass UI down 2-3 levels | `children` / slot props — not Context |
| Form submission | `<form action>` + `useActionState` |
| Submit button pending state | `useFormStatus` |
| Optimistic UI during an action | `useOptimistic` |
| Non-urgent state update | `startTransition` |
| Reset a subtree on identity change | `key` prop |
| Component, hook, or file too large | split — see COMPONENT-DESIGN.md |
| Data fetching | TanStack Query, or `use()` + Suspense — not a raw Effect |

## TypeScript Integration

```tsx
// Extend HTML element props
interface ButtonProps extends React.ComponentPropsWithoutRef<"button"> {
  variant?: "primary" | "secondary" | "destructive";
  isLoading?: boolean;
}

// Generic components
interface ListProps<T> {
  items: T[];
  renderItem: (item: T) => React.ReactNode;
  getKey: (item: T) => string;
}
function List<T>({ items, renderItem, getKey }: ListProps<T>) {
  return <ul>{items.map(item => <li key={getKey(item)}>{renderItem(item)}</li>)}</ul>;
}

// Event types
const handleChange = (e: React.ChangeEvent<HTMLInputElement>) => {};
const handleSubmit = (e: React.FormEvent<HTMLFormElement>) => {};

// Children: always React.ReactNode
interface CardProps { title: string; children: React.ReactNode; }

// Discriminated-union props — make impossible prop combinations unrepresentable
type AlertProps =
  | { variant: "inline"; onDismiss?: never }
  | { variant: "toast"; onDismiss: () => void };   // a toast REQUIRES onDismiss
```

For general type design — discriminated unions, generics, `satisfies`, type guards — see the `typescript-best-practices` skill. This section covers only React-specific typing; hook typing (`useState`/`useReducer`/`useRef`, custom-hook returns, nullable Context) is in COMPONENT-DESIGN.md.

## Error Boundaries

Granular, per-section — never one app-wide catch.

```tsx
import { ErrorBoundary } from "react-error-boundary";

function Dashboard() {
  return (
    <div>
      <ErrorBoundary FallbackComponent={ErrorFallback}><AnalyticsChart /></ErrorBoundary>
      <ErrorBoundary FallbackComponent={ErrorFallback}><RecentOrders /></ErrorBoundary>
    </div>
  );
}
```

## Project Structure

```
src/
  features/
    auth/
      components/
      hooks/
      types.ts
      index.ts          # Public API only
  shared/
    components/
    hooks/
  app/
    routes.tsx
    providers.tsx
```

Barrel exports at feature boundaries only. Colocate first; extract to `shared/` when 2+ features need it.

## Rules

1. **Always** use function components — no class components.
2. **Always** treat `ref` as a normal prop; never write `forwardRef` in new code.
3. **Always** render `<Context value={…}>` directly — never `<Context.Provider>`.
4. **Always** use `use()` to read context — never `useContext`.
5. **Always** derive state during render when a value is computable; don't sync it in an Effect.
6. **Always** use `<form action>` + `useActionState` for submissions; `useFormStatus` for nested submit buttons.
7. **Never** add `useMemo` / `useCallback` / `React.memo` in new code — the React Compiler handles memoization. See PERFORMANCE.md.
8. **Never** use an array index as a key for a dynamic list; use a stable id.
9. **Never** initialize state from a prop expecting it to update — use a `key` reset or lift state up.
10. **Never** call hooks conditionally, in loops, or after an early return — top level only. `use()` is the sole exception.
11. **Prefer** `children` / slot props over Context to avoid prop drilling.
12. **Prefer** granular per-section error boundaries; never rely on data-fetching Effects.
13. **Always** handle the loading / error / empty trio in data-driven components — see LOADING-STATES.md.

## Reference Files

For deeper guidance, load the file matching what you're working on:

- **COMPONENT-DESIGN.md** — read when splitting a component, extracting a custom hook, or a file is getting large. Covers the single-responsibility hard limits (≤200 lines/file, ≤30 lines/function, ≤50-line JSX return, ≤5-6 props, ≤3 nesting levels), split vs don't-split signals, one-concern-per-hook plus hook naming, composition vs Context vs prop drilling, early returns, file organization, the complexity smell test, and the server/client component boundary note.
- **USE-EFFECT.md** — read when writing or reviewing a `useEffect`. Covers the full "You Might Not Need an Effect" catalog (transforming data, resetting state via `key`, event handling, chained Effects, notifying parents, passing data to a parent, app init, fetching), the decision checklist, when Effects *are* correct plus cleanup and race-condition (`ignore` / `AbortController`) patterns, dependency-array discipline, and `useSyncExternalStore`.
- **PERFORMANCE.md** — read when chasing re-renders or memoization. Covers React Compiler v1.0 (delete manual memo; the three narrow exceptions; ESLint enforcement), keys and `startTransition`, `useDeferredValue` with its React 19 initial-value arg, `<Activity mode>` for pre-render and keep-alive, and resource preloading (`preload` / `preinit` / `prefetchDNS` / `preconnect`).
- **LOADING-STATES.md** — read when a component fetches data or shows async UI. Covers the loading / error / empty trio every data component must handle, skeleton screens vs spinners (and avoiding layout shift), building a reusable token-styled `Skeleton` primitive, `<Suspense>` + error-boundary pairing and boundary placement, empty-state design, and accessibility (`aria-busy`, `aria-live` / `role="status"`, focus management).
- **ZUSTAND.md** — read when client/UI state outgrows `useState` and Context. Covers typed curried store creation, atomic selectors and `useShallow` to prevent re-renders, exporting custom hooks over the raw store, event-driven actions, `persist` / `immer` / `devtools` middleware and composition order, the slices pattern, transient updates, and the rule that server state belongs in a query library, not a store.
- **TAILWIND-TOKENS.md** — read when styling — picking colors, spacing, radius, or typography. Covers Tailwind v4 CSS-first `@theme` config and namespaces, semantic color tokens (never raw `red-500`), `@theme inline`, the `--color-*: initial` namespace reset for hard palette lockdown, the semantic spacing scale, the ban on arbitrary values (`p-[13px]`, `text-[#3a3a3a]`) and the narrow exceptions, plus ESLint enforcement tooling.
