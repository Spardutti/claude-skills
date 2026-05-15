# Queries — Options, Hooks, Error Handling

## Contents

- `select` for derived state and referential stability
- Error handling (`throwOnError`, retry, retryDelay, error boundaries)
- `useInfiniteQuery` — end-to-end + reset-on-key-change gotcha
- `useSuspenseQuery` — when to use, what to avoid
- `useQueries` — parallel reads
- Stale closures in `queryFn`
- Network & focus options (`networkMode`, dev focus noise, `gcTime: 0`)
- Devtools setup
- Rules

## `select` — Derived State + Referential Stability

`select` runs *after* the cache resolves. Two superpowers:

1. Components see only the slice they need.
2. The returned reference stays stable across re-renders as long as the slice deep-equals — so consumers don't re-render when unrelated cache fields change.

```ts
// BAD: every render rebuilds the array; consumers re-render even when the
// underlying data is identical. Also exposes the full payload to the component.
const { data: todos } = useQuery({ queryKey: ['todos'], queryFn: getTodos });
const completed = todos?.filter((t) => t.done);

// GOOD: `select` is memoized on the cached value
const { data: completed } = useQuery({
  queryKey: ['todos'],
  queryFn: getTodos,
  select: (todos) => todos.filter((t) => t.done),
});
```

For derived primitives (counts, booleans), `select` is essentially free re-render protection — the consumer only updates when the *primitive* changes.

```ts
const { data: count } = useQuery({
  queryKey: ['todos'],
  queryFn: getTodos,
  select: (todos) => todos.length,  // re-renders only when length changes
});
```

Keep `select` functions stable (defined outside the component or wrapped in `useCallback`) — recreating it on every render defeats the memoization.

## Error Handling

### `queryFn` throws → query enters `error` state

```ts
const { data, error, isError } = useQuery({
  queryKey: ['user', id],
  queryFn: async ({ signal }) => {
    const res = await fetch(`/api/users/${id}`, { signal });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return res.json();
  },
});
if (isError) return <ErrorBanner message={error.message} />;
```

### `throwOnError` — route errors to an Error Boundary

```ts
// All matching queries throw, letting a React Error Boundary catch them
useQuery({
  queryKey: ['user', id],
  queryFn: getUser,
  throwOnError: true,  // boolean — or a function for selective rethrow
});

// Selective: only throw on 5xx, handle 4xx in-component
useQuery({
  queryKey: ['user', id],
  queryFn: getUser,
  throwOnError: (err) => err.status >= 500,
});
```

Set globally on the `QueryClient` for an app-wide error-boundary strategy.

### `retry` and `retryDelay`

Defaults: 3 retries with exponential backoff (`min(1000 * 2 ** attempt, 30_000)`).

```ts
new QueryClient({
  defaultOptions: {
    queries: {
      retry: (failureCount, err) =>
        err.status >= 500 && failureCount < 3,  // don't retry 4xx
      retryDelay: (attempt) => Math.min(1000 * 2 ** attempt, 30_000),
    },
  },
});
```

Don't retry 4xx — the response won't change. Don't set `retry: 0` blindly; intermittent network errors deserve at least one retry.

## `useInfiniteQuery`

End-to-end pattern: cursor pagination, `pages` accumulation, flattening for the UI.

```ts
const {
  data,
  fetchNextPage,
  hasNextPage,
  isFetchingNextPage,
  status,
} = useInfiniteQuery({
  queryKey: ['feed', { filter }],
  queryFn: ({ pageParam, signal }) => api.feed({ cursor: pageParam, signal }),
  initialPageParam: null as string | null,
  getNextPageParam: (last) => last.nextCursor ?? undefined,
  // Optional: bidirectional pagination
  // getPreviousPageParam: (first) => first.prevCursor ?? undefined,
});

const items = data?.pages.flatMap((p) => p.items) ?? [];
```

**Reset gotcha:** changing the query key does **not** reset accumulated `pages`. The new key gets its own cache entry, but the old one stays — and switching back to it shows the old paginated data. Explicit reset:

```ts
// When the filter changes and you want a fresh start:
queryClient.removeQueries({ queryKey: ['feed', { filter: oldFilter }] });
```

## `useSuspenseQuery`

Same options as `useQuery`, but throws a promise → suspends until data lands. Cleaner code path when paired with `<Suspense>` and an error boundary.

```ts
function UserProfile({ id }: { id: string }) {
  const { data: user } = useSuspenseQuery({
    queryKey: ['user', id],
    queryFn: () => api.user(id),
  });
  return <h1>{user.name}</h1>;  // data is guaranteed; no isPending branch
}

// Parent wires Suspense + error boundary:
<ErrorBoundary fallback={<Err />}>
  <Suspense fallback={<Spinner />}>
    <UserProfile id={id} />
  </Suspense>
</ErrorBoundary>
```

**Trade-offs:**

- No `enabled` — the hook always runs. Don't use for conditional fetches.
- No `isPending` / `status` branching — Suspense handles it.
- Naive sibling `useSuspenseQuery` calls **waterfall** (each suspends sequentially). Use `useSuspenseQueries` for parallel.

## `useQueries` — Parallel Reads

For a variable number of queries (e.g. one per item in a list):

```ts
const userQueries = useQueries({
  queries: userIds.map((id) => ({
    queryKey: ['user', id],
    queryFn: () => api.user(id),
    staleTime: 60_000,
  })),
});

const isLoading = userQueries.some((q) => q.isPending);
const users = userQueries.map((q) => q.data).filter(Boolean);
```

v5's `combine` option reduces the result array into a single memoized value: `useQueries({ queries: [...], combine: (results) => ({ data: results.map((r) => r.data), pending: results.some((r) => r.isPending) }) })`.

## Stale Closures in `queryFn`

Capturing props inside `queryFn` looks fine but freezes the value at first render — the cache uses the *key*, not the closure, to dedupe. If the prop changes but the key doesn't, you get stale data forever.

```ts
// BAD: `filter` captured in closure; if it changes without the key changing,
// the cached query still uses the old value
function TodoList({ filter }: { filter: string }) {
  const { data } = useQuery({
    queryKey: ['todos'],                    // key doesn't include filter!
    queryFn: () => api.todos({ filter }),   // stale capture
  });
}

// GOOD: pass the param through the key — and through the queryFn arg
function TodoList({ filter }: { filter: string }) {
  const { data } = useQuery({
    queryKey: ['todos', { filter }],
    queryFn: ({ queryKey: [, params] }) => api.todos(params as { filter: string }),
  });
}
```

Rule: **every value the `queryFn` depends on must be in the `queryKey`.**

## Network & Focus Options

### `networkMode`

Default `'online'` — queries pause when the browser reports offline. Useful for native-feel apps; less so when your "online" check is unreliable (corporate networks, VPNs).

```ts
new QueryClient({
  defaultOptions: { queries: { networkMode: 'always' } },  // ignore offline state
});
```

### `refetchOnWindowFocus` in dev

Default `true`. Triggers a refetch every time DevTools regain focus → looks like network spam during debugging. Either accept it or disable in dev:

```ts
new QueryClient({
  defaultOptions: {
    queries: {
      refetchOnWindowFocus: process.env.NODE_ENV === 'production',
    },
  },
});
```

### `gcTime: 0` is an anti-pattern

`gcTime` controls how long *unused* data stays cached. `0` evicts immediately on the last observer unmount — every navigation back to a screen refetches from scratch. People often set this thinking it controls *freshness*; that's `staleTime`. Leave `gcTime` at default (5min) unless you have a memory pressure reason.

## Devtools Setup

```bash
npm i -D @tanstack/react-query-devtools
```

```tsx
import { QueryClientProvider, QueryClient } from '@tanstack/react-query';
import { ReactQueryDevtools } from '@tanstack/react-query-devtools';

export function Providers({ children }: { children: React.ReactNode }) {
  const [qc] = useState(() => new QueryClient());
  return (
    <QueryClientProvider client={qc}>
      {children}
      {process.env.NODE_ENV !== 'production' && <ReactQueryDevtools initialIsOpen={false} />}
    </QueryClientProvider>
  );
}
```

For zero prod-bundle impact use `React.lazy(() => import('@tanstack/react-query-devtools')...)` gated on `NODE_ENV`.

## Rules

1. **Use `select`** for derived state and re-render stability. Define the function outside the component or memoize it.
2. **Set `throwOnError` globally** if you want an error-boundary strategy; per-query if you only want some errors to bubble.
3. **Don't retry 4xx.** Make `retry` a function that inspects the error.
4. **Always put every `queryFn` dependency in the `queryKey`.** Closure captures go stale silently.
5. **`useInfiniteQuery`: explicit `initialPageParam`**, `getNextPageParam` returns `undefined` to signal end, flatten via `data.pages.flatMap`.
6. **Reset infinite queries by removing them** — changing the key creates a new entry, not a reset.
7. **`useSuspenseQuery` for cleaner code paths,** but never with `enabled`. Use `useSuspenseQueries` to avoid waterfalls.
8. **`useQueries({ queries, combine })`** for parallel reads of dynamic-length lists.
9. **Leave `gcTime` alone** unless you have a memory reason. It is *not* freshness control — that's `staleTime`.
10. **Gate `ReactQueryDevtools` to dev** with `NODE_ENV` or a dynamic import.
11. **`signal` from `queryFn` context** threads cancellation into `fetch` — wire it up so unmount and key-change cancel in-flight requests.
