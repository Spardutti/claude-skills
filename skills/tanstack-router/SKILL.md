---
name: tanstack-router
category: Frontend
description: "MUST USE when writing or editing TanStack Router routes, file-based routing, navigation, loaders, search params, beforeLoad auth guards, pendingComponent / loading UI, or route configuration. Enforces type-safe file-based routing, pending UI that prevents 'frozen on slow internet' navigation, auth checked once per subtree (not per page), loader caching with staleTime, and TanStack Query integration."
---

# TanStack Router Best Practices

## Setup

### Vite Plugin & Route Tree

File-based routing requires the bundler plugin — it generates `routeTree.gen.ts` from `src/routes/` on dev and build.

```ts
// vite.config.ts
import { tanstackRouter } from '@tanstack/router-plugin/vite'

export default defineConfig({
  plugins: [tanstackRouter({ target: 'react' }), react()],
})
```

Never hand-edit `routeTree.gen.ts` — it is regenerated. Commit it or gitignore it, but do so consistently across the team.

### Root Route with Context

```tsx
// src/routes/__root.tsx
interface RouterContext {
  queryClient: QueryClient
  auth: { isAuthenticated: boolean; user: User | null }
}

export const Route = createRootRouteWithContext<RouterContext>()({
  loader: () => null, // makes pending UI work for ALL descendants — see Pending UI
  component: () => (
    <>
      <Header />
      <main><Outlet /></main>
    </>
  ),
})
```

### Router Instantiation

```tsx
export const router = createRouter({
  routeTree,
  context: { queryClient, auth: { isAuthenticated: false, user: null } },
  defaultPreload: 'intent',
  defaultPendingComponent: () => <RouteSkeleton />,
  defaultPendingMs: 1000,
  defaultPendingMinMs: 500,
  defaultErrorComponent: ({ error, reset }) => <ErrorFallback error={error} onRetry={reset} />,
  defaultNotFoundComponent: () => <NotFound />,
})

declare module '@tanstack/react-router' {
  interface Register { router: typeof router }
}
```

### File-Based Route Structure

```
src/routes/
├── __root.tsx              # Root layout
├── index.tsx               # "/"
├── posts/
│   ├── index.tsx           # "/posts"
│   └── $postId.tsx         # "/posts/:postId"
├── _authenticated/         # Pathless layout (no URL segment)
│   ├── route.tsx           # Guard + layout
│   ├── dashboard.tsx       # "/dashboard"
│   └── _admin/route.tsx    # Nested role check
├── (marketing)/            # Route group (organizational only)
│   └── pricing.tsx         # "/pricing"
└── files/
    └── $.tsx               # Catch-all "/files/*"
```

Flat and nested forms are equivalent: `posts.$postId.tsx` === `posts/$postId.tsx`. Mix freely — flatten deep trees, nest where a layout route is shared.

## Type-Safe Navigation

```tsx
<Link to="/posts/$postId" params={{ postId: '123' }}>View Post</Link>
<Link to="/posts" search={{ page: 2, filter: 'recent' }}>Page 2</Link>
<Link to="/dashboard" activeProps={{ className: 'font-bold' }}>Dashboard</Link>

// Imperative
const navigate = useNavigate()
navigate({ to: '/search', search: { q: values.query, page: 1 } })
navigate({ from: '/posts', search: (prev) => ({ ...prev, filter, page: 1 }) })
```

### Route Hooks — always use `Route.*` for type safety

```tsx
function PostDetail() {
  const { postId } = Route.useParams()
  const search = Route.useSearch()
  const data = Route.useLoaderData()
}
```

## Data Loading

### TanStack Query Integration (ensureQueryData)

```tsx
// src/queries/posts.ts — reusable query options
export const postQueryOptions = (postId: string) =>
  queryOptions({ queryKey: ['post', postId], queryFn: () => fetchPost(postId) })

// Route: ensureQueryData in loader
export const Route = createFileRoute('/posts/$postId')({
  loader: ({ context: { queryClient }, params: { postId } }) =>
    queryClient.ensureQueryData(postQueryOptions(postId)),
  component: PostComponent,
})

// Component: useSuspenseQuery reads from cache
function PostComponent() {
  const { postId } = Route.useParams()
  const { data: post } = useSuspenseQuery(postQueryOptions(postId))
  return <div>{post.title}</div>
}
```

### loaderDeps — re-run loader when search params change

```tsx
export const Route = createFileRoute('/posts')({
  validateSearch: z.object({ page: z.number().catch(1), filter: z.string().catch('') }),
  loaderDeps: ({ search: { page, filter } }) => ({ page, filter }),
  loader: ({ context: { queryClient }, deps: { page, filter } }) =>
    queryClient.ensureQueryData(postsQueryOptions(page, filter)),
})
```

### Loader Caching — Don't Refetch on Every Navigation

Loader data defaults to `staleTime: 0` — stale immediately, re-fetched on every re-entry. Tune it so unchanged data isn't needlessly refetched.

```tsx
export const Route = createFileRoute('/posts')({
  loader: ({ context }) => context.queryClient.ensureQueryData(postsQueryOptions()),
  staleTime: 30_000,     // data fresh for 30s — no refetch on quick re-entry
  // gcTime: 5 * 60_000  // keep cached data this long after the route unmounts
})
```

After a mutation, force a reload with `router.invalidate()`. When TanStack Query owns caching (`ensureQueryData` + `useSuspenseQuery`), Query's own `staleTime` governs refetching — set it there and the router `staleTime` matters less.

### Parallel and Deferred Data

```tsx
// Parallel: await all critical data at once
loader: ({ context: { queryClient }, params }) =>
  Promise.all([
    queryClient.ensureQueryData(postQueryOptions(params.postId)),
    queryClient.ensureQueryData(commentsQueryOptions(params.postId)),
  ]),

// Deferred: critical data blocks; slow data streams in behind <Suspense>
loader: async () => ({
  criticalData: await fetchCriticalData(),
  slowDataPromise: defer(fetchSlowAnalytics()),
})
// in the component:
// <Suspense fallback={<ChartSkeleton />}>
//   <Await promise={slowDataPromise}>{(data) => <Chart data={data} />}</Await>
// </Suspense>
```

## Search Params

```tsx
const searchSchema = z.object({
  page: z.number().catch(1),
  sort: z.enum(['price', 'name', 'date']).catch('date'),
  category: z.string().optional(),
})

export const Route = createFileRoute('/products')({ validateSearch: searchSchema })

// Update — functional form preserves the rest of the params
navigate({ from: '/products', search: (prev) => ({ ...prev, category: 'electronics', page: 1 }) })
```

`.catch()` supplies a default for invalid/missing values so the route never crashes on a malformed URL.

## Authentication

### Guard Once Per Subtree — Not Per Page

`beforeLoad` on a parent runs before every child's `beforeLoad` and `loader`. Put the auth check on ONE pathless `_authenticated` layout — it guards the whole subtree.

```tsx
// GOOD: one guard for every route under _authenticated
export const Route = createFileRoute('/_authenticated')({
  beforeLoad: ({ context, location }) => {
    if (!context.auth.isAuthenticated) {
      throw redirect({ to: '/login', search: { redirect: location.href } })
    }
  },
  // component defaults to <Outlet /> — don't declare it
})

// BAD: an auth check (or auth fetch) in every route's loader —
// re-runs on every single navigation
export const Route = createFileRoute('/dashboard')({
  loader: async () => {
    const user = await fetchCurrentUser() // network call on EVERY nav
    if (!user) throw redirect({ to: '/login' })
  },
})
```

`beforeLoad` reads `context.auth` synchronously — zero network cost per navigation. Keep auth state in router context (typed via `createRootRouteWithContext`), synced from a hook wrapping `RouterProvider`.

### Role Checks & Context Augmentation

```tsx
// Nest another pathless layout for a role check
export const Route = createFileRoute('/_authenticated/_admin')({
  beforeLoad: ({ context }) => {
    if (context.auth.user?.role !== 'admin') throw redirect({ to: '/unauthorized' })
  },
})

// A beforeLoad that returns an object MERGES it into context for all children —
// fetch the user once here, children read context.user with no extra fetch
beforeLoad: async ({ context }) => {
  const user = await fetchCurrentUser(context.auth.token)
  return { user }
},
```

If `beforeLoad` itself fetches, wrap in try/catch and re-throw redirects via `isRedirect(error)` — otherwise a thrown `redirect()` is swallowed as an error.

## Pending, Error & NotFound UI

Without pending UI, clicking a link on a slow connection leaves the **old page frozen** until the loader resolves — the app feels broken. `pendingComponent` fixes this: the user sees a skeleton immediately.

Set the defaults at the router (see Router Instantiation) so **no route ever ships without pending/error UI**.

### The pendingMs / pendingMinMs Mechanism

- **`pendingMs` (default 1000ms)** — a route must stay pending this long *before* the pending UI renders. Fast navigations resolve under the threshold, so the pending UI never flashes.
- **`pendingMinMs` (default 500ms)** — once the pending UI *is* shown, it stays at least this long even if data arrives sooner. Prevents a sub-100ms flicker.

Together: instant navigations feel instant; slow ones immediately show a skeleton instead of a dead-looking page. The pending component renders in place of the route's `<Outlet />` — the parent layout and header stay put. It also covers the lazy component-chunk download, not just the loader.

### Gotcha — Pending UI Needs a loader or beforeLoad

`pendingComponent` only triggers for routes that have a `loader` or `beforeLoad`. A route with neither shows **nothing** while its lazy chunk downloads on a slow connection. The no-op `loader: () => null` on the root route (see Root Route) gives every descendant pending state.

### Per-Route Override

```tsx
export const Route = createFileRoute('/dashboard')({
  loader: ({ context }) => context.queryClient.ensureQueryData(statsQueryOptions()),
  // BAD: a centered spinner that swaps to a full table → jarring layout shift
  // GOOD: a skeleton matching the real content's dimensions
  pendingComponent: () => <DashboardSkeleton />,
  errorComponent: ({ error, reset }) => <ErrorFallback error={error} onRetry={reset} />,
})

// notFoundComponent renders when a loader throws notFound()
export const Route = createFileRoute('/posts/$postId')({
  loader: async ({ params }) => {
    const post = await fetchPost(params.postId)
    if (!post) throw notFound()
    return post
  },
  notFoundComponent: () => <div>Post not found</div>,
})
```

`errorComponent` receives `reset` to retry the boundary; `router.invalidate()` reloads and resets together.

## Code Splitting

File-based routing auto-splits critical (`loader`, `beforeLoad`) from non-critical (`component`). For manual splitting use `.lazy.tsx`:

- **Main file:** `loader`, `beforeLoad`, `validateSearch`, `loaderDeps`
- **Lazy file:** `component`, `pendingComponent`, `errorComponent`

## Rules

1. **Always** install the `@tanstack/router-plugin` bundler plugin; never hand-edit `routeTree.gen.ts`.
2. **Always** use `createRootRouteWithContext` to inject `queryClient` and auth, and register the router type via `declare module`.
3. **Always** give the root route a no-op `loader: () => null` so pending UI works for every descendant.
4. **Always** set `defaultPendingComponent` / `defaultErrorComponent` at the router — no route should ship without pending and error UI.
5. **Always** use `Route.useParams()` / `Route.useSearch()` / `Route.useLoaderData()` — never generic hooks without `from`.
6. **Always** use `ensureQueryData` in loaders, `useSuspenseQuery` in components.
7. **Always** validate search params with Zod `.catch()` for defaults, and use `loaderDeps` when a loader depends on them.
8. **Guard auth once** on a pathless `_authenticated` layout via `beforeLoad` — never re-check auth in every route's loader.
9. **Tune loader `staleTime`** so unchanged data is not refetched on every navigation; `router.invalidate()` after mutations.
10. **Use skeletons, not spinners**, for `pendingComponent` — match the real content's dimensions to avoid layout shift.
11. **Never** fetch data in components — use route loaders or query hooks.
12. **Never** use `redirect()` without `throw`; re-throw redirects with `isRedirect` if a `beforeLoad` try/catches.
13. **Prefer** `defaultPreload: 'intent'` for hover/focus preloading.
