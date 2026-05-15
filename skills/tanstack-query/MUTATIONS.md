# Mutations, Optimistic Updates & Invalidation

## Contents

- `useMutation` basics (v5 single-object signature)
- `mutate` vs `mutateAsync`
- Lifecycle: `onMutate` → `onError` / `onSuccess` → `onSettled`
- Pessimistic vs optimistic — pick the default
- The optimistic update template
- Invalidation strategies & `refetchType`
- `setQueryData` vs `invalidateQueries`
- Call-site callbacks vs hook-level callbacks
- Mutation keys and concurrent mutations
- Server action / RSC interop
- Rules

## `useMutation` Basics

v5 uses a single-object signature for every hook. Positional args from v4 are gone.

```ts
// BAD: v4 positional signature — does not type-check in v5
const m = useMutation(
  (todo: Todo) => api.updateTodo(todo),
  { onSuccess: () => {} },
);

// GOOD: v5 single object
const m = useMutation({
  mutationFn: (todo: Todo) => api.updateTodo(todo),
  onSuccess: () => {},
});

m.mutate(todo);            // fire-and-forget; errors land in onError
await m.mutateAsync(todo); // throws on error — use inside try/catch
```

Status fields: `isPending`, `isSuccess`, `isError`, `data`, `error`, `variables`, `reset()`. Note `isLoading` was renamed to `isPending` in v5 (consistent with `useQuery`).

## `mutate` vs `mutateAsync`

```ts
// `mutate` — fire-and-forget. Errors land in `onError`. Returns void.
updateTodo.mutate(todo);

// `mutateAsync` — returns a promise that REJECTS on error.
// Useful inside async flows (forms, server-action transitions) but MUST be wrapped.
```

```ts
// BAD: unhandled rejection — crashes in strict mode, ugly errors in prod
async function handleSubmit() {
  await updateTodo.mutateAsync(todo);
  toast('saved');  // never reached on error; rejection bubbles up
}

// GOOD: catch the rejection
async function handleSubmit() {
  try {
    await updateTodo.mutateAsync(todo);
    toast('saved');
  } catch (e) {
    toast.error(e.message);
  }
}

// ALSO GOOD: stick with `mutate` + onSuccess/onError on the hook
const updateTodo = useMutation({
  mutationFn: api.updateTodo,
  onSuccess: () => toast('saved'),
  onError: (e) => toast.error(e.message),
});
updateTodo.mutate(todo);
```

Default to `mutate`. Use `mutateAsync` only when you genuinely need a promise to chain with — and always wrap it.

## Lifecycle

Order of callbacks for a single `mutate()` call:

1. `onMutate(variables)` runs **before** the network call. Return value is delivered as `context` to later callbacks.
2. `mutationFn(variables)` runs.
3. On success: `onSuccess(data, variables, context)` → `onSettled(data, null, variables, context)`.
4. On error: `onError(error, variables, context)` → `onSettled(undefined, error, variables, context)`.

What each callback is for:

- **`onMutate`** — optimistic write + snapshot for rollback. Return the snapshot as context.
- **`onError`** — roll back using `context`. Don't refetch here; `onSettled` will.
- **`onSuccess`** — react to confirmed success (toast, navigate, write fresh server data into cache).
- **`onSettled`** — runs on both branches. **Invalidate here**, so the cache resyncs whether the mutation succeeded or failed.

## Pessimistic vs Optimistic — Pick the Default

**Default to pessimistic.** Wait for the server, then sync the cache. Optimistic is only worth its complexity (rollback bookkeeping, race conditions) when perceived latency actually hurts UX — toggles, likes, list reordering, anything that should feel instant.

```ts
// PESSIMISTIC, flavor (a): use the server response to write the cache directly.
// No refetch needed for the entity you just mutated.
useMutation({
  mutationFn: api.updateTodo,
  onSuccess: (updated) => {
    queryClient.setQueryData(['todos', 'detail', updated.id], updated);
    queryClient.invalidateQueries({ queryKey: ['todos', 'list'] });
  },
});

// PESSIMISTIC, flavor (b): invalidate and let queries refetch.
// Use when you don't trust the response shape, or the mutation affects many entities.
useMutation({
  mutationFn: api.updateTodo,
  onSettled: () => queryClient.invalidateQueries({ queryKey: ['todos'] }),
});
```

Most mutations should look like one of the two above. Reach for the optimistic template below only when the wait would feel wrong to the user.

## The Optimistic Update Template

Canonical recipe. Copy-paste, then change the keys and shape.

```ts
const queryClient = useQueryClient();

const updateTodo = useMutation({
  mutationFn: (todo: Todo) => api.updateTodo(todo),

  onMutate: async (newTodo) => {
    // 1. Cancel in-flight refetches so they can't overwrite our optimistic write
    await queryClient.cancelQueries({ queryKey: ['todos'] });

    // 2. Snapshot current value for rollback
    const previousTodos = queryClient.getQueryData<Todo[]>(['todos']);

    // 3. Optimistically update cache
    queryClient.setQueryData<Todo[]>(['todos'], (old) =>
      old?.map((t) => (t.id === newTodo.id ? newTodo : t)),
    );

    // 4. Return context for rollback
    return { previousTodos };
  },

  onError: (_err, _newTodo, context) => {
    if (context?.previousTodos) {
      queryClient.setQueryData(['todos'], context.previousTodos);
    }
  },

  onSettled: () => {
    // Re-sync with server regardless of outcome
    queryClient.invalidateQueries({ queryKey: ['todos'] });
  },
});
```

Why each step matters:

- **`cancelQueries`** — an in-flight refetch will land *after* your optimistic write and clobber it. This is the only way to prevent the race.
- **`getQueryData` snapshot** — without it, `onError` has nothing to roll back to.
- **`setQueryData` updater fn `(old) => ...`** — never a static value; the cache may have moved since render.
- **`invalidateQueries` in `onSettled`** — both branches resync: server may add derived fields on success; on error the optimistic write must be discarded.

## Invalidation Strategies & `refetchType`

`invalidateQueries` marks queries stale **and** triggers a refetch — but only for *active* (mounted) observers by default. The full option set:

| `refetchType` | Marks stale | Refetches |
|---|---|---|
| `'active'` (default) | all matched | mounted observers only |
| `'inactive'` | all matched | unmounted queries only |
| `'all'` | all matched | every matching query |
| `'none'` | all matched | nothing — lazy refetch next time observed |

```ts
// Broad (fuzzy): invalidate everything under the prefix
queryClient.invalidateQueries({ queryKey: ['todos'] });
// → matches ['todos'], ['todos', 'list', ...], ['todos', 'detail', 1], etc.

// Surgical (exact key, exact match):
queryClient.invalidateQueries({
  queryKey: ['todos', { status: 'active' }],
  exact: true,
});

// Predicate — arbitrary logic
queryClient.invalidateQueries({
  predicate: (q) =>
    q.queryKey[0] === 'todos' && q.state.dataUpdatedAt < Date.now() - 60_000,
});
```

**Use `refetchType: 'none'` to avoid post-mutation refetch storms.** A broad invalidation without it can fire dozens of network requests if many queries share the prefix — even for screens the user can't see.

```ts
// GOOD: mark stale broadly, refetch lazily as queries are re-observed
queryClient.invalidateQueries({ queryKey: ['todos'], refetchType: 'none' });
```

Trap: `invalidateQueries({ queryKey: ['todos'] })` is fuzzy by default. If you mean only the literal `['todos']` key, pass `exact: true`.

## `setQueryData` vs `invalidateQueries`

```ts
// BAD: invalidate after mutation when the response already has fresh data —
// causes an unnecessary network round-trip
onSuccess: () => {
  queryClient.invalidateQueries({ queryKey: ['todos', 'detail', id] });
},

// GOOD: write the server response directly, skip the refetch
onSuccess: (updatedTodo) => {
  queryClient.setQueryData(['todos', 'detail', updatedTodo.id], updatedTodo);
  // …and still invalidate the *list* queries since their shape may differ
  queryClient.invalidateQueries({ queryKey: ['todos', 'list'] });
},
```

Rule of thumb: `setQueryData` for the exact entity you mutated (you have the response). `invalidateQueries` for everything related you don't have fresh data for (lists, counts, search results).

## Call-site Callbacks vs Hook-level Callbacks

`onSuccess` / `onError` / `onSettled` can be passed two places — and the choice matters.

```ts
// Hook-level: ALWAYS runs, even if the component unmounts before the mutation settles
const updateTodo = useMutation({
  mutationFn: api.updateTodo,
  onSuccess: () => queryClient.invalidateQueries({ queryKey: ['todos'] }),
});

// Call-site: tied to the calling component's lifecycle — DROPPED if it unmounts
updateTodo.mutate(todo, {
  onSuccess: () => navigate('/done'),  // skipped if user navigated away
});
```

Rule of thumb:

- **Cache work** (invalidation, `setQueryData`) → hook level. It must always run.
- **UI work** (navigation, toasts that only make sense in this component) → call site. You usually don't want it to fire if the user has moved on.

Both fire when both are defined; hook-level runs first.

## Mutation Keys & Concurrent Mutations

`mutationKey` lets other components observe a mutation's state via `useMutationState`:

```ts
useMutation({ mutationKey: ['updateTodo'], mutationFn: api.updateTodo });

// Elsewhere in the tree:
const pendingUpdates = useMutationState({
  filters: { mutationKey: ['updateTodo'], status: 'pending' },
});
```

By default, calling `mutate()` twice in rapid succession runs both `mutationFn` calls in **parallel**. For the same logical resource that's a race:

```ts
// BAD: two rapid toggles race — second response may arrive before the first,
// leaving the server in a stale state
const toggle = useMutation({
  mutationFn: (id: string) => api.toggleTodo(id),
});
toggle.mutate('todo-1');
toggle.mutate('todo-1'); // fires immediately, in parallel

// GOOD: scope serializes mutations on the same id — they run one after the other
const toggle = useMutation({
  mutationFn: (id: string) => api.toggleTodo(id),
  scope: { id: 'toggle-todo' },
});
```

Mutations sharing a `scope.id` queue and run sequentially. Use one scope per logical resource (e.g. `` `todo-${id}` ``) when out-of-order completion would corrupt state.

## Server Actions / RSC Interop

`mutationFn` can wrap a Next.js server action directly: `useMutation({ mutationFn: updateTodoAction, onSettled: () => qc.invalidateQueries({ queryKey: ['todos'] }) })`. Use TanStack mutations when you want optimistic UI, retry, or shared pending state; use server actions directly for single-shot form submits with no client-side cache to update.

## Rules

1. **Default to pessimistic.** Reach for the optimistic template only when waiting feels wrong to the user.
2. Always `await cancelQueries` at the start of `onMutate` — otherwise an in-flight refetch will clobber your optimistic write.
3. Always snapshot in `onMutate` and roll back in `onError`. Optimistic updates without rollback leave the cache permanently wrong.
4. Invalidate in `onSettled`, not `onSuccess` — `onSettled` runs on both branches so the cache resyncs after errors too.
5. Use `setQueryData` for the entity you just mutated (you have fresh server data); `invalidateQueries` for related lists/counts.
6. Pass `setQueryData` an updater function `(old) => ...`, not a static value — the cache may have moved since render.
7. `invalidateQueries` is fuzzy by default. Pass `exact: true` when you want only the literal key.
8. **Use `refetchType: 'none'`** for broad post-mutation invalidations — avoids network storms for queries the user can't currently see.
9. Use `mutateAsync` only inside `try/catch` — unhandled rejections will crash. Prefer `mutate` with `onError` for fire-and-forget.
10. **Cache work goes hook-level; UI work goes call-site.** Hook-level callbacks survive unmount; call-site ones don't.
11. Type the context returned from `onMutate` so `onError`'s `context` arg is typed — TS won't infer it across the callback boundary without help.
12. Use `scope: { id }` to serialize concurrent mutations on the same resource — parallel mutations on one entity race.
13. Never derive component state from mutation callbacks alone; read from the cache (or `mutation.data`) so React re-renders correctly.
14. Don't call `invalidateQueries` inside the `mutationFn` — invalidation belongs in lifecycle callbacks where the cache snapshot is consistent.
