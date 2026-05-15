---
name: typescript-best-practices
category: Foundations
description: "MUST USE when writing or editing TypeScript types, interfaces, generics, type guards, error handling patterns, or tsconfig configuration. Enforces TypeScript 6.x strict-mode best practices and type safety patterns."
---

# TypeScript Best Practices (TypeScript 6.x)

## Type Design

### Interface for objects, Type for everything else

```typescript
// interface: extendable object shapes
interface Animal { name: string; }
interface Dog extends Animal { breed: string; }

// type: unions, intersections, computed types
type Result = Success | Failure;
type Getters<T> = { [K in keyof T as `get${Capitalize<string & K>}`]: () => T[K] };
```

### Discriminated Unions over Optional Properties

```typescript
// BAD: ambiguous states
interface Shape { kind: string; radius?: number; width?: number; height?: number; }

// GOOD: impossible states are unrepresentable
interface Circle { kind: "circle"; radius: number; }
interface Rectangle { kind: "rectangle"; width: number; height: number; }
type Shape = Circle | Rectangle;
```

### Branded Types

```typescript
type Brand<T, B extends string> = T & { readonly __brand: B };
type UserId = Brand<string, "UserId">;
type ProductId = Brand<string, "ProductId">;

function getUser(id: UserId) {}
getUser(createProductId("prod_123")); // ERROR
```

### as const

```typescript
const ROLES = ["admin", "user", "guest"] as const;
type Role = (typeof ROLES)[number]; // "admin" | "user" | "guest"
```

### Utility Types

```typescript
type UserPreview = Pick<User, "id" | "name">;
type CreateUserInput = Omit<User, "id" | "createdAt">;
type UpdateUserInput = Partial<Omit<User, "id">>;
type RolePermissions = Record<User["role"], string[]>;
```

## Type Safety

### Avoid `any` — use `unknown`

```typescript
// BAD
function parseJSON(json: string): any { return JSON.parse(json); }

// GOOD
function parseJSON(json: string): unknown { return JSON.parse(json); }
const data = parseJSON('{}');
if (typeof data === "object" && data !== null && "name" in data) {
  console.log(data.name);
}
```

### Type Guards

```typescript
// BAD: type assertion
const user = value as User;

// GOOD: type predicate
function isUser(value: unknown): value is User {
  return typeof value === "object" && value !== null && "id" in value && "name" in value;
}
if (isUser(value)) console.log(value.name);

// GOOD: assertion function
function assertIsUser(value: unknown): asserts value is User {
  if (!isUser(value)) throw new Error("Expected User");
}
```

### Exhaustive Checks with `never`

```typescript
function assertNever(value: never): never {
  throw new Error(`Unexpected value: ${value}`);
}

function getLabel(status: Status): string {
  switch (status) {
    case "pending": return "Pending";
    case "active": return "Active";
    case "archived": return "Archived";
    default: return assertNever(status); // compile error if case missing
  }
}
```

### `satisfies` — validate + preserve inference

```typescript
// BAD: annotation widens, losing literal info
const colors: Record<string, string | [number, number, number]> = { red: [255, 0, 0], green: "#00ff00" };
colors.red.toUpperCase(); // ERROR

// GOOD
const colors = { red: [255, 0, 0], green: "#00ff00" } satisfies Record<string, string | [number, number, number]>;
colors.green.toUpperCase(); // OK
```

### `as const satisfies` — lock literals and validate

```typescript
// Freezes literal types AND checks the shape — the idiom for config objects
const config = {
  retries: 3,
  mode: "strict",
} as const satisfies AppConfig;
config.mode; // type is "strict", not string — and the shape was checked
```

### Validate External Data (Zod)

```typescript
const UserSchema = z.object({ id: z.number(), name: z.string(), email: z.string().email() });
type User = z.infer<typeof UserSchema>;

async function fetchUser(): Promise<User> {
  const data = await fetch("/api/user").then(r => r.json());
  return UserSchema.parse(data);
}
```

## Function Patterns

```typescript
// Overloads: only when return type depends on input
function parse(input: string): number;
function parse(input: string[]): number[];
function parse(input: string | string[]): number | number[] {
  return Array.isArray(input) ? input.map(Number) : Number(input);
}

// Generic constraints
function getProperty<T, K extends keyof T>(obj: T, key: K): T[K] { return obj[key]; }

// const type parameter: preserve literal inference without caller-side `as const`
function asTuple<const T extends readonly unknown[]>(t: T): T { return t; }
const pair = asTuple(["a", "b"]); // readonly ["a", "b"] — not string[]

// Parameter objects over long param lists
interface CreateUserParams { name: string; email: string; role: "admin" | "user"; }
function createUser(params: CreateUserParams) {}

// Infer return types internally, annotate on exports
export function fetchUsers(): Promise<User[]> { return api.get("/users"); }
```

## Type-Only Imports

With `verbatimModuleSyntax` (see tsconfig), imports used only as types must be marked `type` — they are erased from the JS output, preventing accidental runtime imports and breaking import cycles.

```typescript
// GOOD: type-only import — erased at compile time
import type { User } from "./types";

// GOOD: inline `type` for a mixed import
import { type Role, createUser } from "./users";
```

## Resource Management — `using`

`using` (and `await using`) auto-dispose a resource when the scope exits, even on throw. The resource implements `Symbol.dispose` / `Symbol.asyncDispose`.

```typescript
function openConn(url: string) {
  const conn = connect(url);
  return { conn, [Symbol.dispose]() { conn.close(); } };
}

function query() {
  using db = openConn(DATABASE_URL); // db.conn.close() runs automatically
  return db.conn.run("SELECT 1");     // ...even if this throws
}
```

## Common Pitfalls

### Object.keys returns `string[]`

```typescript
// GOOD: type-safe helper
function typedKeys<T extends object>(obj: T): (keyof T)[] {
  return Object.keys(obj) as (keyof T)[];
}
```

### Array.filter needs type predicates

```typescript
// BAD: doesn't narrow
const filtered = values.filter(v => v != null); // still (string | null)[]

// GOOD
function nonNullable<T>(value: T): value is NonNullable<T> { return value != null; }
const filtered = values.filter(nonNullable); // string[]
```

### Prefer unions over enums

```typescript
// BAD: numeric enums accept any number
enum Direction { Up, Down }
move(99); // NO ERROR

// GOOD: union types
type Direction = "up" | "down" | "left" | "right";

// GOOD: const object when you need runtime values
const Status = { Active: "active", Inactive: "inactive" } as const;
type Status = (typeof Status)[keyof typeof Status];
```

## Error Handling — Result Pattern

```typescript
type Result<T, E = Error> = { ok: true; value: T } | { ok: false; error: E };

function ok<T>(value: T): Result<T, never> { return { ok: true, value }; }
function err<E>(error: E): Result<never, E> { return { ok: false, error }; }

type AppError =
  | { type: "NOT_FOUND"; resource: string }
  | { type: "VALIDATION"; fields: string[] }
  | { type: "UNAUTHORIZED"; reason: string };

async function fetchUser(id: string): Promise<Result<User, AppError>> {
  const res = await fetch(`/api/users/${id}`);
  if (res.status === 404) return err({ type: "NOT_FOUND", resource: "User" });
  if (res.status === 401) return err({ type: "UNAUTHORIZED", reason: "Invalid token" });
  return ok(UserSchema.parse(await res.json()));
}
```

## Recommended tsconfig.json

```jsonc
{
  "compilerOptions": {
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "noFallthroughCasesInSwitch": true,
    "forceConsistentCasingInFileNames": true,
    "module": "ESNext",
    "moduleResolution": "bundler",
    "isolatedModules": true,
    "verbatimModuleSyntax": true,
    "target": "ES2022",
    "lib": ["ES2023", "DOM", "DOM.Iterable"],
    "skipLibCheck": true,
    "paths": { "@/*": ["./src/*"] }
  }
}
```

Under **TypeScript 6.0** (current stable), `strict`, `module: "esnext"`, and a modern `target` are defaults — the block above keeps them explicit for clarity and older toolchains. `moduleResolution` values `node` / `node10` / `classic` and `baseUrl` are deprecated in 6.0; `paths` works without `baseUrl`.

## Rules

1. **Always** enable `strict: true` and `noUncheckedIndexedAccess`
2. **Always** use `unknown` instead of `any` — narrow with type guards
3. **Always** use discriminated unions for multi-shape types
4. **Always** use exhaustive `never` checks in switch statements
5. **Always** validate external data at boundaries (Zod/valibot)
6. **Always** annotate return types on exported functions
7. **Never** use numeric enums — use union types or const objects
8. **Never** use type assertions (`as`) when a type guard is possible
9. **Prefer** `satisfies` over type annotations when you need both validation and inference
10. **Prefer** `as const` for literal arrays and config objects; `as const satisfies T` when you also need a shape check
11. **Prefer** `const` type parameters over caller-side `as const` for literal-preserving generics
12. **Use** `using` / `await using` for resources that need deterministic cleanup
13. **Mark type-only imports** with `import type` — required under `verbatimModuleSyntax`
