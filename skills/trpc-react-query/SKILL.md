---
name: trpc-react-query
category: Frontend
description: "MUST USE when writing or editing: tRPC routers, procedures, tRPC React Query hooks, queryOptions, mutationOptions, tRPC middleware, or any tRPC client/server code. Enforces tRPC v11 with TanStack React Query patterns."
---

# tRPC with React Query

Use **tRPC v11** with the **TanStack React Query integration** (`@trpc/react-query`). Use `queryOptions` / `mutationOptions` factories — never the legacy `trpc.useQuery` wrapper hooks.

## Server Setup

### Initialize tRPC

```ts
// server/trpc.ts
import { initTRPC, TRPCError } from "@trpc/server"
import superjson from "superjson"
import { ZodError } from "zod"

export const t = initTRPC.context<Context>().create({
  transformer: superjson,
  errorFormatter({ shape, error }) {
    return {
      ...shape,
      data: {
        ...shape.data,
        zodError:
          error.code === "BAD_REQUEST" && error.cause instanceof ZodError
            ? error.cause.flatten()
            : null,
      },
    }
  },
})

export const publicProcedure = t.procedure
export const createTRPCRouter = t.router
```

### Context

```ts
// server/context.ts
export async function createContext(opts: FetchCreateContextFnOptions) {
  const session = await getSession(opts.req)
  return { user: session?.user ?? null, db }
}
export type Context = Awaited<ReturnType<typeof createContext>>
```

### Middleware — Auth Guard

```ts
// BAD: check auth inside every procedure
secret: publicProcedure.query(({ ctx }) => {
  if (!ctx.user) throw new TRPCError({ code: "UNAUTHORIZED" })
  return ctx.user
}),

// GOOD: reusable middleware narrows context type
const authedProcedure = publicProcedure.use(async (opts) => {
  if (!opts.ctx.user) throw new TRPCError({ code: "UNAUTHORIZED" })
  return opts.next({ ctx: { user: opts.ctx.user } })
})
```

### Router Organization

Split routers by feature, merge into a root router.

```ts
// server/routers/user.ts
export const userRouter = createTRPCRouter({
  me: authedProcedure.query(({ ctx }) => {
    return ctx.db.user.findUnique({ where: { id: ctx.user.id } })
  }),
  byId: publicProcedure
    .input(z.object({ id: z.string() }))
    .query(({ ctx, input }) => {
      return ctx.db.user.findUnique({ where: { id: input.id } })
    }),
  update: authedProcedure
    .input(z.object({ name: z.string().min(1) }))
    .mutation(({ ctx, input }) => {
      return ctx.db.user.update({ where: { id: ctx.user.id }, data: input })
    }),
})
```

```ts
// server/routers/_app.ts
export const appRouter = createTRPCRouter({
  user: userRouter,
  post: postRouter,
})
export type AppRouter = typeof appRouter
```

## Client Setup

```ts
// utils/trpc.ts
import { createTRPCContext } from "@trpc/tanstack-react-query"
import type { AppRouter } from "~/server/routers/_app"

export const { TRPCProvider, useTRPC, queryClient } = createTRPCContext<AppRouter>({
  transformer: superjson,
})

// Type helpers for use outside components
export type RouterInputs = inferRouterInputs<AppRouter>
export type RouterOutputs = inferRouterOutputs<AppRouter>
```

## Queries — queryOptions Pattern

Use `useTRPC()` to get the tRPC proxy, then pass `queryOptions()` to React Query hooks.

```tsx
// BAD: legacy wrapper hooks
const { data } = trpc.user.me.useQuery()

// GOOD: native React Query + queryOptions
import { useQuery } from "@tanstack/react-query"
import { useTRPC } from "~/utils/trpc"

function Profile() {
  const trpc = useTRPC()
  const { data: user, isLoading } = useQuery(trpc.user.me.queryOptions())
  if (isLoading) return <Skeleton />
  return <h1>{user?.name}</h1>
}
```

### With Input, Options, and Conditional Queries

```tsx
// Pass input as first arg, React Query options as second
const { data: user } = useQuery(
  trpc.user.byId.queryOptions({ id: userId }, { staleTime: 5 * 60 * 1000 }),
)

// BAD: ternary inside hook call
const { data } = useQuery(userId ? trpc.user.byId.queryOptions({ id: userId }) : {})

// GOOD: use enabled option
const { data: user } = useQuery({
  ...trpc.user.byId.queryOptions({ id: userId! }),
  enabled: !!userId,
})
```

## Mutations — mutationOptions Pattern

```tsx
function UpdateProfile() {
  const trpc = useTRPC()
  const queryClient = useQueryClient()

  const { mutate: updateUser, isPending } = useMutation(
    trpc.user.update.mutationOptions({
      onSuccess: () => {
        queryClient.invalidateQueries({ queryKey: trpc.user.me.queryKey() })
      },
    }),
  )

  return (
    <button onClick={() => updateUser({ name: "New Name" })} disabled={isPending}>
      {isPending ? "Saving..." : "Save"}
    </button>
  )
}
```

## Cache Invalidation

Use `queryKey()` for type-safe invalidation at any granularity.

```tsx
const trpc = useTRPC()
const queryClient = useQueryClient()

// Invalidate all user queries
queryClient.invalidateQueries({ queryKey: trpc.user.queryKey() })

// Invalidate a specific query
queryClient.invalidateQueries({ queryKey: trpc.user.byId.queryKey({ id: "123" }) })

// Cross-domain invalidation in a mutation
const { mutate: deleteUser } = useMutation(
  trpc.user.delete.mutationOptions({
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: trpc.user.queryKey() })
      queryClient.invalidateQueries({ queryKey: trpc.post.queryKey() })
    },
  }),
)
```

## Optimistic Updates

```tsx
const { mutate: toggleLike } = useMutation(
  trpc.post.toggleLike.mutationOptions({
    onMutate: async ({ postId }) => {
      const queryKey = trpc.post.byId.queryKey({ id: postId })
      await queryClient.cancelQueries({ queryKey })
      const previous = queryClient.getQueryData(queryKey)

      queryClient.setQueryData(queryKey, (old) =>
        old ? { ...old, liked: !old.liked } : old,
      )
      return { previous, queryKey }
    },
    onError: (_err, _vars, context) => {
      if (context) queryClient.setQueryData(context.queryKey, context.previous)
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: trpc.post.queryKey() })
    },
  }),
)
```

## Error Handling

```tsx
// BAD: generic error display
if (error) return <p>Something went wrong</p>

// GOOD: use tRPC error shape for validation errors
function CreatePost() {
  const trpc = useTRPC()
  const { mutate, error } = useMutation(trpc.post.create.mutationOptions())
  const zodError = error?.data?.zodError

  return (
    <form onSubmit={(e) => { /* ... */ }}>
      <input name="title" />
      {zodError?.fieldErrors?.title && (
        <span className="text-red-500">{zodError.fieldErrors.title[0]}</span>
      )}
    </form>
  )
}
```

## Destructuring Convention

```tsx
// BAD: generic names collide when using multiple hooks
const { data, isLoading } = useQuery(trpc.user.me.queryOptions())
const { data: posts } = useQuery(trpc.post.list.queryOptions())

// GOOD: namespaced aliases
const { data: user, isLoading: isLoadingUser } = useQuery(trpc.user.me.queryOptions())
const { data: posts, isLoading: isLoadingPosts } = useQuery(trpc.post.list.queryOptions())
const { mutate: createPost, isPending: isCreating } = useMutation(trpc.post.create.mutationOptions())
```

## Rules

1. **Always** use the TanStack integration (`queryOptions` / `mutationOptions`) — never legacy `trpc.useQuery` wrappers
2. **Always** use `useTRPC()` to access the tRPC proxy on the client
3. **Always** validate inputs with Zod on every procedure
4. **Always** use `superjson` as transformer for Date, Map, Set support
5. **Always** split routers by feature — one file per domain
6. **Always** use middleware for cross-cutting concerns (auth, logging) — never repeat checks in procedures
7. **Always** destructure with named aliases: `{ data: user, isLoading: isLoadingUser }`
8. **Always** invalidate via `queryKey()` — never hardcode string arrays
9. **Always** export `AppRouter` type from the root router for end-to-end type safety
10. **Never** import server code on the client — only import the `AppRouter` type
