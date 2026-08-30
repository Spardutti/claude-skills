---
name: express
category: Backend
description: "MUST USE when writing or reviewing Express routes, middleware, or error handling. Express 5 — automatic async error forwarding, the four-argument error handler, named wildcards, validation at the boundary, thin routes, and the security baseline every production app needs. Bundle covers tRPC v11 on Express."
tracks: express@5.2, @trpc/server@11.18
---

# Express

Express 5 (5.2.x current; 5.1 is fine, Node 18+ required). If a file still uses
`express@4`, the async and wildcard rules below do **not** apply to it — check
`package.json` before assuming.

## Quick Reference — When to Load What

| Working on… | Read |
|---|---|
| tRPC routers, procedures, context, TRPCError, errorFormatter | TRPC.md |

## 1. Async Errors Forward Themselves — Stop Wrapping

Express 5 catches a rejected promise from a handler and sends it to the error
middleware. The try/catch-and-`next(err)` dance is Express 4 muscle memory.

```js
// BAD — Express 4 habit; the wrapper does nothing in 5
app.get("/users/:id", async (req, res, next) => {
  try {
    const user = await findUser(req.params.id);
    res.json(user);
  } catch (err) {
    next(err);
  }
});

// GOOD — throw and let it land in the error handler
app.get("/users/:id", async (req, res) => {
  const user = await findUser(req.params.id);
  if (!user) throw new AppError("User not found", 404);
  res.json(user);
});
```

Catch only when you are going to **do** something — enrich the error, fall back,
release a resource. Catching to re-throw is noise.

## 2. The Error Handler Takes Four Arguments and Goes Last

Express identifies the error handler by **arity**. Three parameters and it is a
normal middleware that never sees an error.

```js
// BAD — silently never runs; Express sees a normal middleware
app.use((err, req, res) => { res.status(500).json({ error: err.message }); });

// GOOD — four parameters, registered after every route
app.use((err, req, res, next) => {
  const status = err.status ?? 500;
  if (status >= 500) req.log.error({ err }, "unhandled");
  res.status(status).json({
    error: status >= 500 ? "Internal Server Error" : err.message,
  });
});
```

Never send `err.message` for a 5xx — it leaks stack details and internal names.
Client errors carry a message you wrote; server errors get a generic one.

Order is load-bearing: routes → 404 handler → error handler. A `app.use` after
the error handler is unreachable.

## 3. One Error Type, Carrying Its Status

```js
// GOOD
export class AppError extends Error {
  constructor(message, status = 400, cause) {
    super(message, { cause });
    this.status = status;
  }
}
```

Anything thrown without a `status` is a bug, not a client error, and defaults to
500. That is the correct default — an unexpected error is not a 400.

## 4. Validate at the Boundary, Once

Parse the request into a typed value at the edge; below that, nothing revalidates.

```js
// BAD — validation scattered through the handler
app.post("/expenses", async (req, res) => {
  if (!req.body.amount) throw new AppError("amount required");
  if (typeof req.body.amount !== "number") throw new AppError("amount must be a number");
  // …six more lines before anything happens
});

// GOOD — one schema, one parse, a typed value after it
const CreateExpense = z.object({
  amount: z.number().positive(),
  note: z.string().max(200).optional(),
});

app.post("/expenses", async (req, res) => {
  const input = CreateExpense.parse(req.body);   // throws ZodError → 400
  res.status(201).json(await expenses.create(input));
});
```

Map `ZodError` to a 400 in the error handler, in one place:

```js
if (err instanceof z.ZodError) {
  // Zod 4: z.flattenError(err). Zod 3: err.flatten().
  return res.status(400).json({ error: "Invalid request", details: z.flattenError(err) });
}
```

**Check which Zod you are on.** Zod 4 replaced `message` / `invalid_type_error` /
`required_error` / `errorMap` with a single `error` param, and moved formatting to
`z.flattenError` / `z.treeifyError` / `z.prettifyError`. Zod 3 code compiles
against Zod 4 and then formats nothing.

## 5. `req.query` Is a Getter — You Cannot Assign It

Express 5 defines `req.query` with a getter and no setter. Assigning is silently
useless in loose mode and throws in strict mode.

```js
// BAD — no longer takes effect
req.query = { ...req.query, page: 1 };

// GOOD — parse into your own value
const query = ListQuery.parse(req.query);
```

Same for `req.params` shape changes. Treat both as read-only input.

## 6. Wildcards Must Be Named

`path-to-regexp` changed. A bare `*` throws at registration.

```js
// BAD — throws on startup in Express 5
app.get("/files/*", handler);

// GOOD — named, and req.params.path is an ARRAY of segments
app.get("/files/*path", (req, res) => {
  const relative = req.params.path.join("/");
});

// GOOD — to also match zero segments, brace the wildcard
app.get("/files{/*path}", handler);
```

Optional `:param?` is gone too — use `{/:param}`.

## 7. `res.status()` Validates Now

```js
res.status("404");   // TypeError — must be an integer
res.status(99);      // RangeError — must be 100–999
res.status(err.status ?? 500);   // GOOD — never pass through an unchecked value
```

A status computed from user input or an upstream response can crash the handler.
Default it before it reaches `res.status`.

## 8. Routes Stay Thin

A route reads input, calls one thing, and shapes the response. Business logic
lives in a module that has never heard of HTTP — that is what makes it testable
without a server and reusable from a job or a CLI.

```js
// BAD — the route IS the feature
app.post("/expenses", async (req, res) => {
  const input = CreateExpense.parse(req.body);
  const account = await db.account.findUnique({ where: { id: input.accountId } });
  if (!account) throw new AppError("No such account", 404);
  if (account.balance < input.amount) throw new AppError("Insufficient funds", 409);
  // …30 more lines
});

// GOOD — HTTP at the edge, the decision underneath
app.post("/expenses", async (req, res) => {
  const expense = await expenses.create(CreateExpense.parse(req.body));
  res.status(201).json(expense);
});
```

## 9. The Security Baseline

Not optional, and not alternatives to each other — they solve different problems.

```js
app.use(helmet());                                    // security headers
app.use(cors({ origin: ALLOWED_ORIGINS }));           // never `origin: true` in prod
app.use(rateLimit({ windowMs: 60_000, limit: 100 })); // brute force, abuse
app.use(express.json({ limit: "100kb" }));            // an unbounded body is a DoS
```

Also: `app.set("trust proxy", 1)` behind a load balancer, or the rate limiter
sees one IP for everyone and `req.ip` is wrong.

## 10. Shut Down Cleanly

```js
// GOOD
const server = app.listen(PORT);
for (const signal of ["SIGTERM", "SIGINT"]) {
  process.on(signal, () => {
    server.close(async () => {
      await db.end();
      process.exit(0);
    });
  });
}
```

Without this a deploy kills in-flight requests mid-write.

## Rules

1. **Never wrap an async handler in try/catch to re-throw** — Express 5 forwards rejections itself.
2. **Always give the error handler four parameters and register it last** — arity is how Express finds it.
3. **Never return `err.message` on a 5xx** — a generic message for server errors, your own text for client errors.
4. **Always validate once at the boundary** and pass a typed value down; nothing below revalidates.
5. **Always name a wildcard** (`*path`) and brace it (`{/*path}`) to match zero segments.
6. **Never assign to `req.query`** — it is a getter in Express 5.
7. **Always default a status before `res.status()`** — it throws on a non-integer or out-of-range code.
8. **Always keep business logic out of the route** — a route reads input, calls one thing, shapes a response.
9. **Always run helmet, CORS with an explicit origin, a rate limiter, and a body limit** in production.
10. **Always close the server and drain connections on SIGTERM.**

## Reference Files

- **TRPC.md** — read when working on tRPC routers, procedures, or the Express adapter. Covers `createExpressMiddleware` and typed context, `protectedProcedure` middleware that narrows the context type, why a plain `Error` becomes a 500 and `TRPCError` does not, the error-code-to-HTTP mapping, `errorFormatter` for field-level Zod errors (and the Zod 3 → 4 difference), `maxBodySize`, and where tRPC and REST routes coexist in one app.
