# Auth with Better Auth on Express

Better Auth owns sign-up, sign-in, sessions, and cookies. Your code owns who may
touch which row. Mixing those two jobs up is where auth bugs come from.

## Contents

- [The Instance](#the-instance)
- [Mount Order](#mount-order)
- [Schema Comes From the CLI](#schema-comes-from-the-cli)
- [requireAuth Middleware](#requireauth-middleware)
- [Ownership Lives in the Query](#ownership-lives-in-the-query)
- [tRPC Context](#trpc-context)
- [Cookies Across Origins](#cookies-across-origins)
- [Rate Limits](#rate-limits)
- [React Client](#react-client)
- [Testing](#testing)
- [Rules](#rules)

## The Instance

```ts
// src/shared/auth/auth.ts
import { betterAuth } from "better-auth";
import { drizzleAdapter } from "better-auth/adapters/drizzle";
import { db } from "../db";

export const auth = betterAuth({
  database: drizzleAdapter(db, { provider: "pg" }),
  emailAndPassword: { enabled: true, requireEmailVerification: true },
  trustedOrigins: [env.WEB_ORIGIN],
  session: { cookieCache: { enabled: true, maxAge: 5 * 60 } },
});

export type Session = typeof auth.$Infer.Session;
```

`BETTER_AUTH_SECRET` and `BETTER_AUTH_URL` come from the environment. Validate both
at boot with the rest of your env; a missing secret in production is a crash you
want before the first request, not after.

Add plugins (`organization`, `admin`, `twoFactor`) when a feature needs one. Every
plugin adds tables and endpoints, so each one means a fresh schema generate.

## Mount Order

```ts
// BAD — express.json() reads the body stream first; sign-in hangs, no error
app.use(express.json());
app.all("/api/auth/*splat", toNodeHandler(auth));

// BAD — Express 4 wildcard; Express 5 throws at startup
app.all("/api/auth/*", toNodeHandler(auth));

// GOOD
app.use(helmet());
app.use(cors({ origin: env.WEB_ORIGIN, credentials: true }));
app.all("/api/auth/*splat", toNodeHandler(auth));
app.use("/api", express.json({ limit: "100kb" }), apiRouter);
```

CORS goes before the auth handler, or the browser's preflight for sign-in fails.
The body parser goes after it, always.

## Schema Comes From the CLI

```bash
npx auth@latest generate --output src/shared/auth/schema.ts
npx drizzle-kit generate
```

```ts
// BAD — hand-added column; the next generate overwrites it
export const user = pgTable("user", { ...generated, plan: text("plan") });

// GOOD — declare it on the instance, then regenerate
betterAuth({
  user: { additionalFields: { plan: { type: "string", defaultValue: "free", input: false } } },
});
```

`input: false` stops a client from setting `plan` at sign-up. Leave it off only
for fields a user may really choose.

`@better-auth/cli` is the old CLI. Use `npx auth`.

## requireAuth Middleware

```ts
// src/shared/middleware/require-auth.ts
import { fromNodeHeaders } from "better-auth/node";
import type { RequestHandler } from "express";

declare global {
  namespace Express {
    interface Locals { session: Session }
  }
}

export const requireAuth: RequestHandler = async (req, res, next) => {
  const session = await auth.api.getSession({ headers: fromNodeHeaders(req.headers) });
  if (!session) throw new AppError("Not signed in", 401);
  res.locals.session = session;
  next();
};

export const requireRole = (role: string): RequestHandler => (_req, res, next) => {
  if (res.locals.session.user.role !== role) throw new AppError("Forbidden", 403);
  next();
};
```

```ts
// BAD — every route re-checks; the one you forget is public
router.get("/", async (req, res) => {
  const session = await auth.api.getSession({ headers: fromNodeHeaders(req.headers) });
  if (!session) return res.status(401).end();
  ...
});

// GOOD — guard the router once
router.use(requireAuth);
router.get("/", async (_req, res) => {
  res.json(await listExpenses(res.locals.session.user.id));
});
```

`user.role` exists only with the `admin` plugin. 401 means "who are you?"; 403 means
"I know you, and no". Read
`res.locals.session` only on a router that ran `requireAuth`.

## Ownership Lives in the Query

```ts
// BAD — signed in is not the same as allowed; any user reads any expense
export const getExpense = (id: string) =>
  db.query.expenses.findFirst({ where: eq(expenses.id, id) });

// GOOD — the user id is part of the lookup
export const getExpense = (id: string, userId: string) =>
  db.query.expenses.findFirst({
    where: and(eq(expenses.id, id), eq(expenses.userId, userId)),
  });
```

Return 404, not 403, when the row exists but belongs to someone else. A 403 tells
a stranger the id is real.

## tRPC Context

```ts
// GOOD — context carries the headers; the procedure resolves the session
export const createContext = ({ req }: trpcExpress.CreateExpressContextOptions) => ({
  headers: fromNodeHeaders(req.headers),
});

export const protectedProcedure = t.procedure.use(async ({ ctx, next }) => {
  const session = await auth.api.getSession({ headers: ctx.headers });
  if (!session) throw new TRPCError({ code: "UNAUTHORIZED" });
  return next({ ctx: { session } });
});
```

`cookieCache` keeps this cheap: the session comes from a signed cookie, and the
database is hit about once every `maxAge`.

## Cookies Across Origins

```ts
// BAD — cookie never comes back; every call is 401
cors({ origin: env.WEB_ORIGIN });
fetch(`${API}/api/expenses`);

// GOOD — both sides opt in
cors({ origin: env.WEB_ORIGIN, credentials: true });
createAuthClient({ baseURL: API });   // sends credentials for you
fetch(`${API}/api/expenses`, { credentials: "include" });
```

`origin: true` with `credentials: true` lets any site act as the signed-in user.
Always list the origin. If web and API live on sibling subdomains, set
`advanced.crossSubDomainCookies` instead of loosening `sameSite`.

## Rate Limits

Better Auth rate-limits its own endpoints, only in production by default. The
default store is memory, so each instance counts on its own.

```ts
betterAuth({
  rateLimit: {
    storage: "secondary-storage",
    customRules: { "/sign-in/email": { window: 60, max: 5 } },
  },
  secondaryStorage: redisStorage,
});
```

Calls through `auth.api` on the server skip the limiter. Never expose one of those
as a sign-in shortcut.

## React Client

```ts
// src/lib/auth-client.ts
import { createAuthClient } from "better-auth/react";
export const authClient = createAuthClient({ baseURL: import.meta.env.VITE_API_URL });
```

```ts
// GOOD — TanStack Router guard; the server still checks every request
beforeLoad: async () => {
  const { data } = await authClient.getSession();
  if (!data) throw redirect({ to: "/sign-in" });
},
```

A client guard is UX. It hides a page; it protects nothing.

## Testing

```ts
// BAD — the mock agrees with your bug; a broken mount order still passes
vi.spyOn(auth.api, "getSession").mockResolvedValue(fakeSession);

// GOOD — a real session through the real handler
const agent = request.agent(app).set("Origin", env.WEB_ORIGIN);
await agent.post("/api/auth/sign-up/email")
  .send({ email: "a@test.dev", password: "long-enough-pw", name: "A" });
await agent.get("/api/expenses").expect(200);
```

Turn off `requireEmailVerification` in the test config, or sign-up returns no
session. Test the 401 and the other user's 404 too, not only the happy path.

## Rules

- Always mount `toNodeHandler(auth)` on `/api/auth/*splat` **before** any body parser.
- Always put CORS before the auth handler, with an explicit origin and `credentials: true`.
- Always generate the auth schema with `npx auth generate`; never hand-edit auth tables.
- Always declare extra user fields in `additionalFields`, with `input: false` unless the user may set them.
- Always guard a router with `requireAuth` once; never check the session inside each route.
- Always scope a query by the owner's id; a session proves who, not what they may touch.
- Always return 404 for another user's row, 401 for no session, 403 for a wrong role.
- Always turn on `cookieCache` when every request resolves the session.
- Always move the rate-limit store to secondary storage when more than one instance runs.
- Never treat a client-side route guard as protection.
- Never mock `getSession` in an integration test; sign up through the real handler.
