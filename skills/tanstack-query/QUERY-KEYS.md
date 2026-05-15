# Query Keys & Factories

## Contents

- Why structured keys matter
- The naive approach (and why it breaks)
- @lukemorales/query-key-factory basics
- The merge pattern: per-domain factories, one root
- Invalidation strategies
- `_def` vs `_ctx`
- TypeScript inference
- Rules

## Why Structured Keys

Cache lookup, fuzzy invalidation, and optimistic updates all key off the
`queryKey` array. The hierarchy in that array is the only thing the cache
understands — `['todos']` is the prefix of `['todos', 'list', { status: 'active' }]`,
so invalidating the former invalidates the latter. If your keys are
inconsistent, fuzzy invalidation silently misses queries and your UI shows
stale data.

```ts
// BAD: ad-hoc strings, no hierarchy
useQuery({ queryKey: ['todos-active'], queryFn: ... });
useQuery({ queryKey: ['todos-detail-' + id], queryFn: ... });
queryClient.invalidateQueries({ queryKey: ['todos-active'] }); // misses detail

// GOOD: hierarchical arrays — one invalidate covers both
useQuery({ queryKey: ['todos', 'list', { status: 'active' }], queryFn: ... });
useQuery({ queryKey: ['todos', 'detail', id], queryFn: ... });
queryClient.invalidateQueries({ queryKey: ['todos'] }); // matches both
```

## The Naive Approach

Inline keys defined at the call site look fine in a small app and become a
maintenance disaster at scale: typos compile, autocomplete is useless, and a
schema rename requires grepping for stringly-typed needles.

```ts
// BAD: keys scattered across hooks, drift guaranteed
function useTodos() {
  return useQuery({ queryKey: ['todos', 'list'], queryFn: fetchTodos });
}
function useTodo(id: string) {
  return useQuery({ queryKey: ['todo', id], queryFn: () => fetchTodo(id) });
  //                            ^^^^^ singular vs plural — invalidation misses
}
function invalidate(qc: QueryClient) {
  qc.invalidateQueries({ queryKey: ['todos'] }); // does NOT touch ['todo', id]
}
```

The fix is a typed factory that owns every key in the app.

## @lukemorales/query-key-factory

```bash
npm install @tanstack/react-query @lukemorales/query-key-factory
```

`createQueryKeys(scope, definition)` builds a typed object whose leaves carry
`queryKey` (and optionally `queryFn`), plus a `_def` prefix used for fuzzy
invalidation.

```ts
import { createQueryKeys } from '@lukemorales/query-key-factory';
import { api } from '~/api';

export const todos = createQueryKeys('todos', {
  all: null,
  detail: (id: string) => ({
    queryKey: [id],
    queryFn: () => api.getTodo(id),
  }),
  list: (filters: { status: string }) => ({
    queryKey: [{ filters }],
    queryFn: () => api.getTodos(filters),
  }),
});

// Generated shapes:
todos._def;                        // ['todos']
todos.detail(id).queryKey;         // ['todos', 'detail', id]
todos.detail._def;                 // ['todos', 'detail']
todos.list({ status: 'a' }).queryKey; // ['todos', 'list', { filters: { status: 'a' } }]
```

Because each leaf returns both `queryKey` and `queryFn`, hooks become a
one-liner: `useQuery(todos.detail(id))`.

## The Merge Pattern

**Anti-pattern:** one 1000-line `createQueryKeys('app', { ... })` covering
every domain. It blocks parallel work, balloons diffs, and tanks IDE
performance.

**Pattern:** one factory per domain, each in its own file, composed with
`mergeQueryKeys`.

```ts
// src/queries/users.ts
import { createQueryKeys } from '@lukemorales/query-key-factory';
import { api } from '~/api';

export const usersKeys = createQueryKeys('users', {
  all: null,
  detail: (userId: string) => ({
    queryKey: [userId],
    queryFn: () => api.getUser(userId),
    contextQueries: {
      posts: {
        queryKey: null,
        queryFn: () => api.getUserPosts(userId),
      },
    },
  }),
});
```

```ts
// src/queries/todos.ts
import { createQueryKeys } from '@lukemorales/query-key-factory';
import { api } from '~/api';
import type { TodoFilters } from '~/types';

export const todosKeys = createQueryKeys('todos', {
  list: (filters: TodoFilters) => ({
    queryKey: [{ filters }],
    queryFn: () => api.getTodos(filters),
  }),
  detail: (id: string) => ({
    queryKey: [id],
    queryFn: () => api.getTodo(id),
  }),
});
```

```ts
// src/queries/products.ts
import { createQueryKeys } from '@lukemorales/query-key-factory';
import { api } from '~/api';

export const productsKeys = createQueryKeys('products', {
  all: { queryKey: null, queryFn: () => api.getProducts() },
  detail: (sku: string) => ({
    queryKey: [sku],
    queryFn: () => api.getProduct(sku),
  }),
});
```

```ts
// src/queries/index.ts
import { mergeQueryKeys } from '@lukemorales/query-key-factory';
import { usersKeys } from './users';
import { todosKeys } from './todos';
import { productsKeys } from './products';

export const queries = mergeQueryKeys(usersKeys, todosKeys, productsKeys);
```

Consumption is uniform across the app:

```ts
import { useQuery } from '@tanstack/react-query';
import { queries } from '~/queries';

useQuery(queries.users.detail(userId));
useQuery(queries.todos.list({ status: 'active' }));
useQuery(queries.products.all);
```

Each domain file stays small (target under 150 lines). Removing a feature is
one file deletion plus one line in `index.ts`. Autocomplete narrows per domain:
`queries.users.` shows only user leaves.

## Invalidation Strategies

The hierarchy enables surgical, broad, and predicate-based invalidation from
the same factory.

```ts
const qc = useQueryClient();

// Surgical — exactly one query
qc.invalidateQueries({
  queryKey: queries.todos.detail(id).queryKey,
  exact: true,
});

// Fuzzy by leaf — every list(filters) variation
qc.invalidateQueries({ queryKey: queries.todos.list._def });

// Whole domain — every todo query
qc.invalidateQueries({ queryKey: queries.todos._def });

// Direct cache write after a mutation returns the fresh value
qc.setQueryData(queries.todos.detail(todo.id).queryKey, todo);
```

Common post-mutation pattern: `setQueryData` for the detail you just touched,
plus `invalidateQueries` on the related list `_def`.

## `_def` vs `_ctx`

- `_def` is the **key prefix** for a leaf. Use it for fuzzy invalidation
  when you want every variant of a parameterized leaf.
- `_ctx` is the **nested sub-query namespace**. Leaves declared under
  `contextQueries` live there and inherit the parent's key.

```ts
// Definition (from users.ts above)
usersKeys.detail(id).queryKey;       // ['users', 'detail', id]
usersKeys.detail._def;                // ['users', 'detail']
usersKeys.detail(id)._ctx.posts.queryKey;
// ['users', 'detail', id, 'posts']

// Hook for the nested sub-query
function useUserPosts(id: string) {
  return useQuery(queries.users.detail(id)._ctx.posts);
}

// Invalidate every posts query across all users
qc.invalidateQueries({
  predicate: (q) => q.queryKey.includes('posts'),
});
```

Use `_ctx` for data that is logically owned by a parent entity (a user's
posts, a project's tasks). Use a sibling leaf when the relationship is flat.

## TypeScript Inference

The factory infers everything from your `queryFn` return types — no manual
generics on `useQuery`.

```ts
import type { inferQueryKeys } from '@lukemorales/query-key-factory';

export type UsersKeys = inferQueryKeys<typeof usersKeys>;

// data is typed as the queryFn return value automatically
function useUser(id: string) {
  const { data } = useQuery(queries.users.detail(id));
  return data; // inferred as User | undefined
}
```

If you need a key's literal type (for a `setQueryData` helper, say), pull it
from the leaf: `type DetailKey = ReturnType<typeof queries.todos.detail>['queryKey']`.

## Alternative — v5 `queryOptions`

v5 ships its own typed helper. No `_def`/`_ctx` fuzzy semantics, but types flow across `useQuery`, `prefetchQuery`, `setQueryData`, and `invalidateQueries`.

```ts
import { queryOptions } from '@tanstack/react-query';

export const todoDetail = (id: string) =>
  queryOptions({
    queryKey: ['todos', 'detail', id] as const,
    queryFn: () => api.todos.byId(id),
  });

useQuery(todoDetail(id));
queryClient.setQueryData(todoDetail(id).queryKey, updated);
```

Pick `@lukemorales/query-key-factory` for hierarchical fuzzy invalidation (`_def`) and nested sub-queries (`_ctx`); pick `queryOptions` when you don't need those and prefer zero third-party deps. **Don't mix both in one codebase.**

## Rules

1. **Prefer a typed key source** — either this factory or v5's built-in `queryOptions(...)` helper. Never inline ad-hoc `queryKey` arrays scattered across components.
2. **Split factories by domain, one file each.** Target under 150 lines per domain.
3. **Compose with `mergeQueryKeys`.** Never write a single god factory.
4. **Export one `queries` root** from `queries/index.ts` and import it everywhere.
5. **Use `_def` for fuzzy invalidation**, full `.queryKey` with `exact: true` for surgical.
6. **Co-locate `queryFn` with the key** inside the factory leaf — hooks become one-liners.
7. **Use `contextQueries` for parent-owned sub-data**, sibling leaves for flat relationships.
8. **Keep keys serializable** — primitives and plain objects only, no Dates, Maps, or class instances.
9. **Pass parameters through the leaf signature**, not via closure — keeps keys deterministic.
10. **After a mutation**, prefer `setQueryData` on the detail leaf plus `invalidateQueries` on the list `_def`.
