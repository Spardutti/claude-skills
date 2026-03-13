---
name: fastify-best-practices
category: Backend
description: "MUST USE when writing or editing: Fastify routes, plugins, hooks, decorators, schemas, or any Fastify server code. Enforces plugin-based structure, encapsulation, TypeBox validation, and production patterns."
---

# Fastify Best Practices

Use **Fastify 5** with TypeScript. Organize code as **plugins**, use **@sinclair/typebox** for schema validation and serialization, and leverage **encapsulation** for isolation.

## Project Structure

Shared plugins (`src/plugins/`) use `fastify-plugin` to expose decorators. Resource plugins (`src/resources/`) are plain Fastify plugins — autoloaded and encapsulated.

```
src/
├── plugins/                   # Shared — wrapped with fastify-plugin
│   ├── database.plugin.ts     # DB decorator
│   ├── auth.plugin.ts         # fastify.authenticate decorator
│   ├── reply.plugin.ts        # reply.success() / reply.error()
│   └── errors.ts
├── resources/                 # Features — plain plugins, autoloaded
│   ├── users/
│   │   ├── users.plugin.ts
│   │   ├── users.service.ts
│   │   ├── users.schema.ts
│   │   └── users.test.ts
│   └── posts/
│       ├── posts.plugin.ts
│       ├── posts.service.ts
│       ├── posts.schema.ts
│       └── posts.test.ts
├── app.ts
└── server.ts
```

## Resource Plugins

Every feature is a plain plugin. Use `fastify.route()` full declaration style.

```ts
// resources/users/users.plugin.ts
import { FastifyPluginAsync } from "fastify"
import { Type } from "@sinclair/typebox"
import { createUserBody, CreateUserBody, userResponse, UserResponse } from "./users.schema"

const usersPlugin: FastifyPluginAsync = async (fastify) => {
  fastify.route<{ Body: CreateUserBody; Reply: UserResponse }>({
    method: "POST",
    url: "/",
    schema: { body: createUserBody, response: { 201: userResponse } },
    handler: async (request, reply) => {
      const user = await fastify.usersService.create(request.body)
      return reply.success(201, user)
    },
  })

  fastify.route<{ Params: { id: string }; Reply: UserResponse }>({
    method: "GET",
    url: "/:id",
    schema: { params: Type.Object({ id: Type.String() }), response: { 200: userResponse } },
    preHandler: [fastify.authenticate],
    handler: async (request, reply) => {
      const user = await fastify.usersService.getById(request.params.id)
      return reply.success(200, user)
    },
  })
}

// BAD: wrapping resource plugin in fastify-plugin (breaks encapsulation)
export default fp(usersPlugin)

// GOOD: plain export — stays encapsulated
export default usersPlugin
```

## Services as Decorators

Services are Fastify decorators accessed via the instance. Never import services directly.

```ts
// resources/users/users.service.ts
import fp from "fastify-plugin"
import { FastifyInstance, FastifyPluginAsync } from "fastify"
import { NotFoundError, ConflictError } from "../../plugins/errors"

declare module "fastify" {
  interface FastifyInstance {
    usersService: ReturnType<typeof buildUsersService>
  }
}

function buildUsersService(fastify: FastifyInstance) {
  return {
    async getById(id: string) {
      const user = await fastify.db.user.findById(id)
      if (!user) throw new NotFoundError("User")
      return user
    },
    async create(data: CreateUserInput) {
      const existing = await fastify.db.user.findByEmail(data.email)
      if (existing) throw new ConflictError("Email already in use")
      return fastify.db.user.create(data)
    },
  }
}

const usersServicePlugin: FastifyPluginAsync = async (fastify) => {
  fastify.decorate("usersService", buildUsersService(fastify))
}

export default fp(usersServicePlugin, { name: "usersService", dependencies: ["db"] })
```

```ts
// BAD: importing service directly
import { usersService } from "./users.service"

// GOOD: access via fastify instance
const user = await fastify.usersService.getById(id)
```

## Shared Plugins (`src/plugins/`)

Wrap with `fastify-plugin` so decorators are visible to all resource plugins.

```ts
// plugins/database.plugin.ts
import fp from "fastify-plugin"
import { FastifyPluginAsync } from "fastify"

declare module "fastify" {
  interface FastifyInstance { db: DatabaseClient }
}

const dbPlugin: FastifyPluginAsync = async (fastify) => {
  const client = await createDbClient(fastify.config.DATABASE_URL)
  fastify.decorate("db", client)
  fastify.addHook("onClose", async () => client.disconnect())
}

export default fp(dbPlugin, { name: "db" })
```

## TypeBox Schemas

Use `@sinclair/typebox` — single source of truth for validation, serialization, and TypeScript types.

```ts
// resources/users/users.schema.ts
import { Type, Static } from "@sinclair/typebox"

export const createUserBody = Type.Object({
  name: Type.String({ minLength: 1 }),
  email: Type.String({ format: "email" }),
})
export type CreateUserBody = Static<typeof createUserBody>

export const userResponse = Type.Object({
  id: Type.String(),
  name: Type.String(),
  email: Type.String(),
})
export type UserResponse = Static<typeof userResponse>
```

```ts
// BAD: no response schema — slow JSON.stringify, may leak fields
fastify.route({ method: "GET", url: "/users", handler: async () => db.user.findMany() })

// GOOD: response schema strips extra fields + fast serialization
fastify.route({
  method: "GET",
  url: "/users",
  schema: { response: { 200: Type.Array(userResponse) } },
  handler: async () => db.user.findMany(),
})
```

## Custom Reply Helpers

Never use `reply.send()` directly — use decorated helpers for a consistent envelope.

```ts
// plugins/reply.plugin.ts
import fp from "fastify-plugin"
import { FastifyPluginAsync } from "fastify"

declare module "fastify" {
  interface FastifyReply {
    success(statusCode: number, data: unknown): FastifyReply
    error(statusCode: number, message: string): FastifyReply
  }
}

const replyPlugin: FastifyPluginAsync = async (fastify) => {
  fastify.decorateReply("success", function (statusCode: number, data: unknown) {
    return this.code(statusCode).send({ success: true, data })
  })
  fastify.decorateReply("error", function (statusCode: number, message: string) {
    return this.code(statusCode).send({ success: false, error: message })
  })
}

export default fp(replyPlugin, { name: "reply-helpers" })
```

## Error Handling

Use `@fastify/error` for typed errors and `setErrorHandler` for centralized handling.

```ts
// plugins/errors.ts
import createError from "@fastify/error"

export const NotFoundError = createError("NOT_FOUND", "%s not found", 404)
export const ConflictError = createError("CONFLICT", "%s", 409)
```

```ts
// app.ts — global error handler
fastify.setErrorHandler((error, request, reply) => {
  request.log.error(error)
  if (error.validation) return reply.error(400, error.message)
  const statusCode = error.statusCode ?? 500
  return reply.error(statusCode, statusCode >= 500 ? "Internal Server Error" : error.message)
})
```

## Authentication

Registered as a decorator, used as a `preHandler` hook.

```ts
// plugins/auth.plugin.ts
import fp from "fastify-plugin"

declare module "fastify" {
  interface FastifyInstance {
    authenticate: (request: FastifyRequest, reply: FastifyReply) => Promise<void>
  }
}

const authPlugin: FastifyPluginAsync = async (fastify) => {
  fastify.decorate("authenticate", async (request: FastifyRequest, reply: FastifyReply) => {
    const token = request.headers.authorization?.replace("Bearer ", "")
    if (!token) return reply.error(401, "Unauthorized")
    request.user = await verifyToken(token)
  })
}

export default fp(authPlugin, { name: "authenticate" })
```

## Hooks

```ts
// BAD: mixing async and callback
fastify.addHook("preHandler", async (request, reply, done) => { done() })

// GOOD: async hooks — just return
fastify.addHook("preHandler", async (request, reply) => {
  // throw or return reply to short-circuit
})
```

## Decorators

```ts
// BAD: reference type shared across all requests
fastify.decorateRequest("session", {})

// GOOD: null initial + assign per-request
fastify.decorateRequest("session", null)
fastify.addHook("onRequest", async (request) => { request.session = {} })
```

## Rules

1. **Always** structure features as plain plugins in `src/resources/` — autoloaded and encapsulated
2. **Always** put shared plugins (db, auth, reply helpers) in `src/plugins/` wrapped with `fastify-plugin`
3. **Always** use `fastify.route()` full declaration style for all routes
4. **Always** use `@sinclair/typebox` for schemas — single source of truth for validation + TS types
5. **Always** define TypeBox schemas for body, params, querystring, **and response** on every route
6. **Always** register services as Fastify decorators — access via `fastify.serviceX`, never direct imports
7. **Never** decorate requests with reference types directly — use `null` + `onRequest` hook
8. **Never** mix async and callback styles in hooks or handlers
9. **Always** use `reply.success()` and `reply.error()` helpers — never `reply.send()` directly
10. **Always** use `fastify.log` / `request.log` — never `console.log`
11. **Always** use `fastify.authenticate` as a `preHandler` hook for protected routes
12. **Always** prefix resource routes with `/api/v1/{resource-name}`
13. **Always** use `@fastify/error` for custom error types with status codes
14. **Always** use `setErrorHandler` for centralized error handling — never catch in individual routes
15. **Never** use Express patterns — no `req.body` without schema, no middleware chains, no `app.use`
