---
name: tanstack-router-best-practices
category: Frontend
description: "MUST USE when writing or editing TanStack Router routes, navigation, loaders, search params, beforeLoad guards, or route configuration. Enforces type-safe file-based routing patterns with TanStack Query integration."
---

# TanStack Router Best Practices

## Route Setup

### Root Route with Context

```tsx
// src/routes/__root.tsx
interface RouterContext {
  queryClient: QueryClient
  auth: { isAuthenticated: boolean; user: User | null }
}

export const Route = createRootRouteWithContext<RouterContext>()({
  component: () => (
    <>
      <Header />
      <main><Outlet /></main>
    </>
  ),
  notFoundComponent: () => <div>404 - Page Not Found</div>,
})
```

### Router Instantiation

```tsx
export const router = createRouter({
  routeTree,
  context: { queryClient, auth: { isAuthenticated: false, user: null } },
  defaultPreload: 'intent',
  defaultPendingMs: 1000,
  defaultPendingMinMs: 500,
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
│   └── _admin/             # Nested guard
│       └── route.tsx       # Role check
├── (marketing)/            # Route group (organizational only)
│   └── pricing.tsx         # "/pricing"
└── files/
    └── $.tsx               # Catch-all "/files/*"
```

## Type-Safe Navigation

```tsx
// Link with typed params and search
<Link to="/posts/$postId" params={{ postId: '123' }}>View Post</Link>
<Link to="/posts" search={{ page: 2, filter: 'recent' }}>Page 2</Link>
<Link from="/posts" search={(prev) => ({ ...prev, page: prev.page + 1 })}>Next</Link>

// Active styling
<Link to="/dashboard" activeProps={{ className: 'font-bold' }}>Dashboard</Link>

// Imperative navigation
const navigate = useNavigate()
navigate({ to: '/search', search: { q: values.query, page: 1 } })
navigate({ from: '/posts', search: (prev) => ({ ...prev, filter, page: 1 }) })
```

### Route Hooks — always use `from` for type safety

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
  queryOptions({
    queryKey: ['post', postId],
    queryFn: () => fetchPost(postId),
  })

// Route: ensureQueryData in loader
export const Route = createFileRoute('/posts/$postId')({
  loader: async ({ context: { queryClient }, params: { postId } }) => {
    await queryClient.ensureQueryData(postQueryOptions(postId))
  },
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
  loader: async ({ context: { queryClient }, deps: { page, filter } }) => {
    await queryClient.ensureQueryData(postsQueryOptions(page, filter))
  },
})
```

### Parallel and non-blocking queries

```tsx
// Parallel: await all critical data
loader: async ({ context: { queryClient }, params: { postId } }) => {
  await Promise.allSettled([
    queryClient.ensureQueryData(postQueryOptions(postId)),
    queryClient.ensureQueryData(commentsQueryOptions(postId)),
  ])
},

// Non-blocking: prefetch without awaiting
loader: async ({ context: { queryClient }, params: { postId } }) => {
  await queryClient.ensureQueryData(postQueryOptions(postId))
  queryClient.prefetchQuery(relatedPostsQueryOptions(postId))
},
```

### Deferred Data

```tsx
export const Route = createFileRoute('/dashboard')({
  loader: async () => ({
    criticalData: await fetchCriticalData(),
    slowDataPromise: defer(fetchSlowAnalytics()),
  }),
  component: () => {
    const { criticalData, slowDataPromise } = Route.useLoaderData()
    return (
      <div>
        <h1>{criticalData.title}</h1>
        <Suspense fallback={<Spinner />}>
          <Await promise={slowDataPromise}>{(data) => <Chart data={data} />}</Await>
        </Suspense>
      </div>
    )
  },
})
```

## Search Params

```tsx
// Validate with Zod .catch() for defaults
const searchSchema = z.object({
  page: z.number().catch(1),
  sort: z.enum(['price', 'name', 'date']).catch('date'),
  category: z.string().optional(),
})

export const Route = createFileRoute('/products')({
  validateSearch: searchSchema,
})

// Update search params
<Link from="/products" search={(prev) => ({ ...prev, page: prev.page + 1 })}>Next</Link>
navigate({ from: '/products', search: (prev) => ({ ...prev, category: 'electronics', page: 1 }) })
```

## Authentication

### beforeLoad Guard

```tsx
// src/routes/_authenticated/route.tsx
export const Route = createFileRoute('/_authenticated')({
  beforeLoad: ({ context, location }) => {
    if (!context.auth.isAuthenticated) {
      throw redirect({ to: '/login', search: { redirect: location.href } })
    }
  },
  component: () => <Outlet />,
})

// Role-based: nest another pathless layout
export const Route = createFileRoute('/_authenticated/_admin')({
  beforeLoad: ({ context }) => {
    if (context.user.role !== 'admin') throw redirect({ to: '/unauthorized' })
  },
})
```

### Route Context Augmentation

```tsx
// Parent adds user to context via beforeLoad
beforeLoad: async ({ context }) => {
  const user = await fetchCurrentUser(context.auth.token)
  return { user } // merged into context for all children
},
```

## Pending / Error / NotFound

```tsx
export const Route = createFileRoute('/posts/$postId')({
  loader: async ({ params }) => {
    const post = await fetchPost(params.postId)
    if (!post) throw notFound()
    return post
  },
  pendingComponent: () => <Spinner />,
  errorComponent: ({ error, reset }) => <ErrorFallback error={error} onRetry={reset} />,
  notFoundComponent: () => <div>Post not found</div>,
})
```

## Code Splitting

File-based routing auto-splits critical (loader, beforeLoad) from non-critical (component). For manual splitting use `.lazy.tsx`:

- **Main file:** `loader`, `beforeLoad`, `validateSearch`, `loaderDeps`
- **Lazy file:** `component`, `pendingComponent`, `errorComponent`

## Rules

1. **Always** use `createRootRouteWithContext` to inject `queryClient` and auth
2. **Always** register the router type via `declare module '@tanstack/react-router'`
3. **Always** use `Route.useParams()` / `Route.useSearch()` (not generic hooks without `from`)
4. **Always** use `ensureQueryData` in loaders, `useSuspenseQuery` in components
5. **Always** validate search params with Zod `.catch()` for defaults
6. **Always** use `loaderDeps` when a loader depends on search params
7. **Never** fetch data in components — use route loaders or query hooks
8. **Never** use `redirect()` without `throw`
9. **Prefer** `defaultPreload: 'intent'` for hover/focus preloading
10. **Prefer** pathless `_` layouts for auth guards and shared layouts
