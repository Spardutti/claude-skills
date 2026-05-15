---
name: tanstack-query
category: Frontend
description: "MUST USE when writing any @tanstack/react-query code (TanStack Query, formerly React Query), including useQuery, useMutation, useInfiniteQuery, useSuspenseQuery, useQueries, QueryClient setup, designing query keys or key factories, invalidating or prefetching cache, doing optimistic or pessimistic mutations, configuring select/error handling/retry/refetchType, or migrating from v4 to v5. Enforces v5 single-object signatures, the pending/isLoading rename, gcTime over cacheTime, serializable query keys, queryFn throwing on error, pessimistic-first mutation strategy, the cancelQueries → snapshot → setQueryData → rollback → invalidate template, refetchType: 'none' for broad invalidation, and the @lukemorales/query-key-factory merge pattern."
---

# TanStack Query — Cache, Queries, Mutations

Server-state caching for React. v5 syntax throughout. The 80% case lives in this file; deep dives in the reference files.

## Quick Reference — When to Load What

| Working on… | Read |
|---|---|
| Designing query keys, factories, fuzzy invalidation prefixes | QUERY-KEYS.md |
| Mutations, pessimistic vs optimistic, `refetchType`, post-write invalidation | MUTATIONS.md |
| `select`, error handling, `useInfiniteQuery`, `useSuspenseQuery`, devtools, stale closures | QUERIES.md |

## Critical Gotchas (Always-Inline)

These are the bugs that ship to production silently. v5 changed a lot — most of these bite people coming from React Query v4.

### 1. v5 Single-Object Signatures

Every hook takes one options object. Positional args are gone.

```ts
// BAD: v4 positional — TypeScript error in v5
useQuery(['todos'], fetchTodos, { staleTime: 60_000 });
useMutation(updateTodo, { onSuccess });

// GOOD: v5
useQuery({ queryKey: ['todos'], queryFn: fetchTodos, staleTime: 60_000 });
useMutation({ mutationFn: updateTodo, onSuccess });
```

### 2. `pending` Replaced `loading`; `isLoading` Changed Meaning

```ts
// BAD: v4 status value
if (query.status === 'loading') return <Spinner />;

// GOOD: v5
if (query.status === 'pending') return <Spinner />;
// or
if (query.isPending) return <Spinner />;
```

`isPending` = old `isLoading` (no data yet). New `isLoading` = `isPending && isFetching` — true only when the *first* fetch is in flight. Use `isPending` for the initial-render spinner.

### 3. `cacheTime` Renamed to `gcTime`

```ts
// BAD
new QueryClient({ defaultOptions: { queries: { cacheTime: 600_000 } } });

// GOOD
new QueryClient({ defaultOptions: { queries: { gcTime: 600_000 } } });
```

`gcTime` is how long *unused* data lingers before garbage collection (default 5min). It does **not** control freshness — `staleTime` does.

### 4. `staleTime: 0` Default Causes Refetch Thrash

Every mount and window focus refetches. Most apps want 30s–5min.

```ts
// GOOD: set once on the client, override per-query when needed
new QueryClient({
  defaultOptions: { queries: { staleTime: 60_000 } },
});
```

### 5. `onSuccess` / `onError` Removed From `useQuery`

```ts
// BAD: silently ignored in v5
useQuery({ queryKey: ['user'], queryFn: getUser, onSuccess: (u) => track(u) });

// GOOD: side effects belong in mutations or effects
const { data } = useQuery({ queryKey: ['user'], queryFn: getUser });
useEffect(() => { if (data) track(data); }, [data]);
```

Callbacks are still valid on `useMutation`.

### 6. `useInfiniteQuery` Requires `initialPageParam`

```ts
// BAD: v5 throws at runtime
useInfiniteQuery({
  queryKey: ['feed'],
  queryFn: ({ pageParam }) => fetchFeed(pageParam),
  getNextPageParam: (last) => last.nextCursor,
});

// GOOD
useInfiniteQuery({
  queryKey: ['feed'],
  queryFn: ({ pageParam }) => fetchFeed(pageParam),
  initialPageParam: 0,
  getNextPageParam: (last) => last.nextCursor ?? undefined,
});
```

### 7. Query Keys Must Be Serializable

Arrays of primitives + plain objects only. No `Date`, `Map`, `Set`, class instances, or functions. Object key order does not matter — deep-equal compared.

```ts
// BAD: Date is not serializable for the cache key
useQuery({ queryKey: ['report', new Date()], queryFn: getReport });

// GOOD
useQuery({ queryKey: ['report', date.toISOString()], queryFn: getReport });
```

### 8. `queryFn` Must Throw on Error

The cache treats a resolved promise as success — returning an error object hides failures.

```ts
// BAD: query stays in 'success' with bogus data
queryFn: async () => {
  const res = await fetch('/api/todos');
  return res.json();   // 4xx/5xx still resolves
};

// GOOD
queryFn: async ({ signal }) => {
  const res = await fetch('/api/todos', { signal });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
};
```

Always thread `signal` to `fetch` so the cache can cancel in-flight requests.

### 9. `enabled: false` Is NOT "Idle"

A disabled query sits in `status: 'pending'` forever with no data. Don't gate spinners on `isPending` alone.

```ts
// BAD: spinner shown forever when userId is undefined
const q = useQuery({ queryKey: ['user', userId], queryFn: () => getUser(userId!), enabled: !!userId });
if (q.isPending) return <Spinner />;

// GOOD: check the gate explicitly, or use fetchStatus
if (!userId) return <SignInPrompt />;
if (q.isPending) return <Spinner />;
```

`fetchStatus === 'idle'` + `isPending` distinguishes disabled from in-flight.

### 10. `placeholderData: keepPreviousData` Replaced `keepPreviousData: true`

```ts
import { keepPreviousData } from '@tanstack/react-query';

// BAD: v4 syntax — ignored in v5
useQuery({ queryKey: ['todos', page], queryFn, keepPreviousData: true });

// GOOD
useQuery({ queryKey: ['todos', page], queryFn, placeholderData: keepPreviousData });
```

### 11. Fuzzy Invalidation Matches Prefixes

`invalidateQueries({ queryKey: ['todos'] })` busts every key starting with `['todos', ...]`. Usually what you want — pair with `exact: true` when you don't.

```ts
qc.invalidateQueries({ queryKey: ['todos'] });               // all todo queries
qc.invalidateQueries({ queryKey: ['todos', id], exact: true }); // only this one
```

## When to Use What

| Decision | Use |
|---|---|
| Read data in a component | `useQuery` |
| Read data and integrate with `<Suspense>` | `useSuspenseQuery` (no `enabled`, no `isPending`) |
| Parallel reads, variable count | `useQueries({ queries: [...] })` |
| Paginated/cursor lists | `useInfiniteQuery` with `initialPageParam` |
| Write data | `useMutation` |
| Refresh after a write — server is source of truth | `queryClient.invalidateQueries` |
| Refresh after a write — mutation returns fresh entity | `queryClient.setQueryData` (skip the refetch) |
| Common pattern after a write | `setQueryData(detail)` + `invalidateQueries(list._def)` |
| Evict on logout | `queryClient.removeQueries` (or `queryClient.clear()`) |
| Disable until args ready | `enabled: false` on `useQuery` (never on `useSuspenseQuery`) |
| Stable spinner across page changes | `placeholderData: keepPreviousData` |
| SSR | `prefetchQuery` + `dehydrate` + `<HydrationBoundary>`, new `QueryClient` per request |
| Devtools | `@tanstack/react-query-devtools`, import behind a dev check |

## Rules

1. **v5 only:** single-object signatures, `pending` not `loading`, `gcTime` not `cacheTime`, `isPending` for the first-fetch spinner, `placeholderData: keepPreviousData` over the old flag.
2. **Set `staleTime` on the client.** The default of 0 thrashes; pick a project-wide floor (30s–5min) and override per-hook only when needed.
3. **Query keys are serializable arrays, broad to narrow:** `['todos', 'list', { filters }]`, `['todos', 'detail', id]`. Stringify dates; never put functions, `Map`/`Set`, or class instances in a key.
4. **`queryFn` throws on non-OK responses.** Resolved promise = success in the cache. Always thread `signal` for cancellation.
5. **No side effects in `useQuery`.** `onSuccess`/`onError` are gone — put effects in `useEffect` or in the relevant `useMutation`.
6. **Default to pessimistic mutations.** Wait for the server, then `setQueryData` or `invalidateQueries`. Reach for optimistic only when latency hurts UX — and then all five steps: `cancelQueries` → snapshot → `setQueryData` → `onError` rollback → `onSettled` invalidate. See MUTATIONS.md.
7. **One factory per domain, then `mergeQueryKeys`.** Do not build a single 1000-line monolith. See QUERY-KEYS.md.
8. **`enabled: false` is not idle.** Gate UI on the precondition itself, not on `isPending`. Never combine `enabled` with `useSuspenseQuery`.
9. **SSR:** create a fresh `QueryClient` per request on the server, and on the client create it inside `useState(() => new QueryClient())` — never at module scope.
10. **Devtools:** import `@tanstack/react-query-devtools` only in development (dynamic import or `NODE_ENV` guard) to keep the prod bundle clean.

## Reference Files

For deeper guidance, load the file matching what you're working on:

- **QUERY-KEYS.md** — read when designing query keys, building a `@lukemorales/query-key-factory` factory, or invalidating cache by prefix. Covers the merge pattern (one `createQueryKeys` file per domain, composed via `mergeQueryKeys`), the `_def` / `_ctx` / `contextQueries` shapes, fuzzy vs exact invalidation targets, and `inferQueryKeys` for type extraction.
- **MUTATIONS.md** — read when writing `useMutation`, doing optimistic updates, or invalidating after a write. Covers the `mutate` vs `mutateAsync` choice, the `onMutate → mutationFn → onSuccess/onError → onSettled` lifecycle, **pessimistic vs optimistic — pick the default**, the canonical `cancelQueries → snapshot → setQueryData → rollback → invalidate` template, the full `refetchType` table (including `'none'` for broad invalidations), call-site vs hook-level callbacks, and concurrent-mutation `scope`.
- **QUERIES.md** — read when reading data, tuning options, handling errors, or integrating devtools. Covers `select` for derived state and re-render stability, error handling (`throwOnError`, retry, retryDelay, error boundaries), full `useInfiniteQuery` example + key-change reset gotcha, `useSuspenseQuery` and `useQueries` examples, stale closures in `queryFn`, network/focus options (`networkMode`, dev-mode `refetchOnWindowFocus`, `gcTime: 0`), and Devtools setup.
