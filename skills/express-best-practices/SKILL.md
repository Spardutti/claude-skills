---
name: express-best-practices
category: Backend
description: "MUST USE when writing or editing: Express.js routes, middleware, controllers, services, error handlers, or any Express server code. Enforces feature-based structure, 3-layer architecture, and production patterns."
---

# Express.js Best Practices

Use **Express 5** (or 4.x with async wrappers). Organize code by **feature**, use a **3-layer architecture** (router → controller → service), and centralize error handling.

## Project Structure

Group everything related to a feature together. Never organize by technical role (all controllers in one folder, all models in another).

```
src/
├── features/
│   ├── users/
│   │   ├── user.router.ts
│   │   ├── user.controller.ts
│   │   ├── user.service.ts
│   │   ├── user.model.ts
│   │   ├── user.schema.ts        # Zod validation schemas
│   │   └── user.test.ts
│   ├── posts/
│   │   ├── post.router.ts
│   │   ├── post.controller.ts
│   │   ├── post.service.ts
│   │   ├── post.model.ts
│   │   ├── post.schema.ts
│   │   └── post.test.ts
│   └── auth/
│       ├── auth.router.ts
│       ├── auth.controller.ts
│       ├── auth.service.ts
│       ├── auth.schema.ts
│       └── auth.test.ts
├── middleware/
│   ├── error-handler.ts
│   ├── validate.ts
│   ├── authenticate.ts
│   └── rate-limit.ts
├── shared/
│   ├── app-error.ts
│   ├── db.ts
│   └── logger.ts
├── app.ts                         # Express app setup
└── server.ts                      # Entry point (listen)
```

## 3-Layer Architecture

**Router** → **Controller** → **Service**. Each layer has one job.

### Router — Only Wiring

```ts
// features/users/user.router.ts
import { Router } from "express"
import { userController } from "./user.controller"
import { validate } from "../../middleware/validate"
import { authenticate } from "../../middleware/authenticate"
import { createUserSchema, updateUserSchema } from "./user.schema"

const router = Router()

router.get("/", userController.list)
router.get("/:id", userController.getById)
router.post("/", validate(createUserSchema), userController.create)
router.patch("/:id", authenticate, validate(updateUserSchema), userController.update)
router.delete("/:id", authenticate, userController.remove)

export { router as userRouter }
```

### Controller — HTTP In/Out Only

Controllers parse the request, call a service, and send the response. No business logic.

```ts
// features/users/user.controller.ts
import { Request, Response } from "express"
import { userService } from "./user.service"

// BAD: business logic in controller
const create = async (req: Request, res: Response) => {
  const existing = await db.user.findByEmail(req.body.email)
  if (existing) return res.status(409).json({ error: "Email taken" })
  const hashed = await bcrypt.hash(req.body.password, 12)
  const user = await db.user.create({ ...req.body, password: hashed })
  res.status(201).json(user)
}

// GOOD: controller delegates to service
const create = async (req: Request, res: Response) => {
  const user = await userService.create(req.body)
  res.status(201).json(user)
}

const getById = async (req: Request, res: Response) => {
  const user = await userService.getById(req.params.id)
  res.json(user)
}

export const userController = { list, getById, create, update, remove }
```

### Service — Business Logic Only

Services contain all business rules. They throw `AppError` on failure — never send HTTP responses.

```ts
// features/users/user.service.ts
import { AppError } from "../../shared/app-error"
import { UserModel } from "./user.model"

// BAD: service sends HTTP response
const create = async (data, res) => {
  res.status(201).json(user)
}

// GOOD: service returns data or throws
const create = async (data: CreateUserInput) => {
  const existing = await UserModel.findOne({ email: data.email })
  if (existing) throw new AppError("Email already in use", 409)

  return UserModel.create(data)
}

const getById = async (id: string) => {
  const user = await UserModel.findById(id)
  if (!user) throw new AppError("User not found", 404)
  return user
}

export const userService = { create, getById, list, update, remove }
```

## Custom Error Class

```ts
// shared/app-error.ts
export class AppError extends Error {
  constructor(
    message: string,
    public statusCode: number = 500,
    public isOperational: boolean = true,
  ) {
    super(message)
    Error.captureStackTrace(this, this.constructor)
  }
}
```

## Centralized Error Handler

One error handler at the bottom of the middleware stack. Never handle errors in individual routes.

```ts
// middleware/error-handler.ts
import { ErrorRequestHandler } from "express"
import { AppError } from "../shared/app-error"

export const errorHandler: ErrorRequestHandler = (err, req, res, next) => {
  if (err instanceof AppError) {
    res.status(err.statusCode).json({ error: err.message })
    return
  }

  // Unexpected errors — log and hide details
  console.error("Unhandled error:", err)
  res.status(500).json({ error: "Internal server error" })
}
```

## Validation Middleware

Use **Zod** for request validation. One reusable middleware, schemas per feature.

```ts
// middleware/validate.ts
import { Request, Response, NextFunction } from "express"
import { AnyZodObject, ZodError } from "zod"
import { AppError } from "../shared/app-error"

export const validate = (schema: AnyZodObject) => {
  return (req: Request, res: Response, next: NextFunction) => {
    try {
      schema.parse({ body: req.body, query: req.query, params: req.params })
      next()
    } catch (err) {
      if (err instanceof ZodError) {
        res.status(400).json({ errors: err.flatten().fieldErrors })
        return
      }
      next(err)
    }
  }
}
```

```ts
// features/users/user.schema.ts
import { z } from "zod"

export const createUserSchema = z.object({
  body: z.object({
    name: z.string().min(1),
    email: z.string().email(),
    password: z.string().min(8),
  }),
})

export const updateUserSchema = z.object({
  params: z.object({ id: z.string() }),
  body: z.object({
    name: z.string().min(1).optional(),
    email: z.string().email().optional(),
  }),
})
```

## App Setup

```ts
// app.ts
import express from "express"
import helmet from "helmet"
import cors from "cors"
import { userRouter } from "./features/users/user.router"
import { postRouter } from "./features/posts/post.router"
import { authRouter } from "./features/auth/auth.router"
import { errorHandler } from "./middleware/error-handler"
import { rateLimiter } from "./middleware/rate-limit"

const app = express()

// 1. Security & parsing
app.use(helmet())
app.use(cors())
app.use(express.json({ limit: "10kb" }))
app.use(rateLimiter)

// 2. Feature routers
app.use("/api/auth", authRouter)
app.use("/api/users", userRouter)
app.use("/api/posts", postRouter)

// 3. 404 catch-all
app.use((req, res) => {
  res.status(404).json({ error: "Route not found" })
})

// 4. Error handler — always last
app.use(errorHandler)

export { app }
```

```ts
// server.ts
import { app } from "./app"

const PORT = process.env.PORT || 3000

app.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`)
})
```

## Authentication Middleware

```ts
// middleware/authenticate.ts
import { AppError } from "../shared/app-error"
import { verifyToken } from "../shared/jwt"

export const authenticate = (req: Request, res: Response, next: NextFunction) => {
  const header = req.headers.authorization
  if (!header?.startsWith("Bearer ")) throw new AppError("Unauthorized", 401)

  req.user = verifyToken(header.slice(7))
  next()
}
```

## Rules

1. **Always** organize by feature — one folder per domain with router, controller, service, schema, test
2. **Always** use 3 layers: router (wiring) → controller (HTTP) → service (logic)
3. **Never** put business logic in controllers or routers
4. **Never** send HTTP responses from services — throw `AppError` instead
5. **Always** validate requests with Zod schemas through the `validate` middleware
6. **Always** use a centralized error handler as the last middleware
7. **Always** use `helmet`, `cors`, and rate limiting in production
8. **Always** set `express.json({ limit: "10kb" })` to prevent payload abuse
9. **Never** expose stack traces or internal details in production error responses
10. **Always** colocate tests with their feature: `features/<name>/<name>.test.ts`
