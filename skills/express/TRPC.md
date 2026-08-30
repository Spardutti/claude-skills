# tRPC v11 on Express

tRPC is not a replacement for the REST routes beside it — it is a second door into
the same service layer. Both mount on one Express app, and the rules in `SKILL.md`
about thin routes and validation at the boundary still hold; tRPC just gives you
the boundary for free.

## Contents

- [Mounting the Adapter](#mounting-the-adapter)
- [Context Is Per Request](#context-is-per-request)
- [Procedures, and Narrowing Auth](#procedures-and-narrowing-auth)
- [Errors: TRPCError or a Silent 500](#errors-trpcerror-or-a-silent-500)
- [Field-Level Validation Errors](#field-level-validation-errors)
- [Limits and Logging](#limits-and-logging)
- [Living Beside REST Routes](#living-beside-rest-routes)
- [Rules](#rules)

## Mounting the Adapter

```ts
import * as trpcExpress from "@trpc/server/adapters/express";

app.use(
  "/trpc",
  trpcExpress.createExpressMiddleware({ router: appRouter, createContext }),
);
```

Mount it **after** helmet, CORS, and the rate limiter, and **before** the 404 and
error handlers. tRPC answers everything under its path itself, so the Express
error middleware never sees a tRPC error — it has its own (below).

`express.json()` is not required for tRPC and can fight it on non-JSON payloads.
v11 accepts `FormData`, `Blob`, `File`, and `Uint8Array`; if you mount a JSON body
parser globally, scope it to your REST routes rather than the whole app.

## Context Is Per Request

```ts
// BAD — built once at startup; every request sees the first user
const ctx = { user: await getUser() };

// GOOD — a function, called per request, typed from the adapter's options
const createContext = ({ req, res }: trpcExpress.CreateExpressContextOptions) => ({
  token: req.headers.authorization?.split(" ")[1],
  res,
});
type Context = Awaited<ReturnType<typeof createContext>>;

const t = initTRPC.context<Context>().create();
```

Keep it cheap. It runs on every call including ones that fail auth, so a database
round-trip here is a round-trip you pay for on rejected traffic too. Put the token
in context; resolve the user in the middleware that needs it.

## Procedures, and Narrowing Auth

The point of the auth middleware is not the check — it is that `ctx.user` stops
being nullable afterwards.

```ts
export const publicProcedure = t.procedure;

export const protectedProcedure = t.procedure.use(async function isAuthed(opts) {
  if (!opts.ctx.user) throw new TRPCError({ code: "UNAUTHORIZED" });
  return opts.next({
    ctx: { user: opts.ctx.user },   // now non-nullable for everything downstream
  });
});
```

```ts
// BAD — the check is real but the type is not; every procedure re-narrows
publicProcedure.query(({ ctx }) => {
  if (!ctx.user) throw new TRPCError({ code: "UNAUTHORIZED" });
  return load(ctx.user!.id);       // the `!` is the tell
});

// GOOD
protectedProcedure.query(({ ctx }) => load(ctx.user.id));
```

Build one `protectedProcedure` and reuse it. A per-procedure check drifts, and the
one you forget is the one that leaks.

## Errors: TRPCError or a Silent 500

A plain `Error` thrown in a procedure is caught, wrapped as
`INTERNAL_SERVER_ERROR`, and its message hidden from the client. That is correct
for a bug and wrong for "not found".

```ts
// BAD — the client gets 500 and no explanation
throw new Error("User not found");

// GOOD — 404, with a message the client can show
throw new TRPCError({ code: "NOT_FOUND", message: "User not found" });
```

Codes map to HTTP: `BAD_REQUEST` 400, `UNAUTHORIZED` 401, `FORBIDDEN` 403,
`NOT_FOUND` 404, `CONFLICT` 409, `PAYLOAD_TOO_LARGE` 413,
`UNPROCESSABLE_CONTENT` 422, `TOO_MANY_REQUESTS` 429,
`INTERNAL_SERVER_ERROR` 500. Use `getHTTPStatusCodeFromError(err)` from
`@trpc/server/http` if you need the number yourself.

Wrap a lower-level failure rather than replacing it, so the cause survives to
your logs:

```ts
throw new TRPCError({ code: "CONFLICT", message: "Already claimed", cause: err });
```

## Field-Level Validation Errors

Without an `errorFormatter` a client gets `"Input validation failed"` and nothing
to put next to a form field.

```ts
const t = initTRPC.context<Context>().create({
  errorFormatter({ shape, error }) {
    return {
      ...shape,
      data: {
        ...shape.data,
        zodError:
          error.code === "BAD_REQUEST" && error.cause instanceof ZodError
            ? z.flattenError(error.cause)   // Zod 4
            : null,
      },
    };
  },
});
```

**Zod 3 uses `error.cause.flatten()`; Zod 4 uses `z.flattenError(error.cause)`.**
Zod 3 code type-checks against Zod 4 and quietly produces nothing useful, so
confirm the version in `package.json` before copying either. Zod 4 also collapsed
`message` / `invalid_type_error` / `required_error` / `errorMap` into one `error`
param.

## Limits and Logging

```ts
trpcExpress.createExpressMiddleware({
  router: appRouter,
  createContext,
  maxBodySize: 100_000,               // else PAYLOAD_TOO_LARGE, for every content type
  onError({ error, path, type }) {
    if (error.code === "INTERNAL_SERVER_ERROR") {
      logger.error({ err: error.cause ?? error, path, type }, "trpc");
    }
  },
});
```

`onError` is where server errors get logged — the Express error handler never sees
them. Log 5xx only; a 404 or a validation failure is normal traffic and logging
it buries the real ones.

## Living Beside REST Routes

```ts
app.use(helmet());
app.use(cors({ origin: ALLOWED_ORIGINS }));
app.use(rateLimit({ windowMs: 60_000, limit: 100 }));

app.use("/trpc", trpcExpress.createExpressMiddleware({ router: appRouter, createContext }));

app.use("/webhooks", express.raw({ type: "*/*" }), webhookRouter);  // signature needs the raw body
app.use("/api", express.json({ limit: "100kb" }), restRouter);

app.use(notFound);
app.use(errorHandler);   // four arguments, last
```

Both doors call the same service layer. A procedure that reimplements what a REST
route already does is the same duplication as two controllers sharing no model —
put the logic underneath and let both call it.

## Rules

- Always create context with a **function**, typed from `CreateExpressContextOptions` — a value built at startup is shared by every request.
- Always keep `createContext` cheap; it runs on requests that then fail auth.
- Always throw `TRPCError` with a code — a plain `Error` becomes a 500 with its message hidden.
- Always define one `protectedProcedure` that narrows `ctx.user`, and reuse it; a `!` on `ctx.user` means the check is in the wrong place.
- Always pass `cause` when wrapping a lower-level error, or the real failure never reaches your logs.
- Always add an `errorFormatter` if a client renders field errors — and match it to your Zod major, `flatten()` for 3 and `z.flattenError` for 4.
- Always set `maxBodySize` on the adapter; the Express body limit does not cover it.
- Always log from `onError`, and only for `INTERNAL_SERVER_ERROR` — the Express error handler never sees a tRPC error.
- Never mount a global JSON body parser in front of tRPC; v11 accepts FormData and binary, and the parser breaks it.
- Never put business logic in a procedure — it is a boundary, exactly like a route.
