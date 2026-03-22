---
name: drizzle-orm
category: Backend
description: "MUST USE when writing or reviewing Drizzle ORM schemas, migrations, relational queries, or drizzle-kit configuration. Enforces identity columns over serial, proper relation definitions, migration safety, type inference, and query patterns."
---

# Drizzle ORM Best Practices

## Schema — Use Identity Columns, Not Serial

```typescript
// BAD: serial is legacy PostgreSQL
import { pgTable, serial, text } from "drizzle-orm/pg-core";
export const users = pgTable("users", {
  id: serial("id").primaryKey(),
  name: text("name"),
});

// GOOD: identity columns are the modern PostgreSQL standard
import { pgTable, integer, text } from "drizzle-orm/pg-core";
export const users = pgTable("users", {
  id: integer().primaryKey().generatedAlwaysAsIdentity(),
  name: text("name"),
});
```

## Schema — Column Naming

Map camelCase TypeScript to snake_case SQL explicitly.

```typescript
// BAD: implicit column name matches TS key — inconsistent SQL
export const users = pgTable("users", {
  firstName: varchar({ length: 256 }),
});

// GOOD: explicit snake_case SQL column name
export const users = pgTable("users", {
  firstName: varchar("first_name", { length: 256 }),
});
```

## Schema — Indexes and Constraints

Define indexes in the third argument array:

```typescript
export const posts = pgTable(
  "posts",
  {
    id: integer().primaryKey().generatedAlwaysAsIdentity(),
    slug: varchar({ length: 256 }),
    title: varchar({ length: 256 }),
    ownerId: integer("owner_id").references(() => users.id),
  },
  (table) => [
    uniqueIndex("posts_slug_idx").on(table.slug),
    index("posts_title_idx").on(table.title),
  ]
);
```

## Schema — Enums, Timestamps, Foreign Keys

```typescript
// Define enums OUTSIDE the table
export const roleEnum = pgEnum("role", ["guest", "user", "admin"]);

export const posts = pgTable("posts", {
  id: integer().primaryKey().generatedAlwaysAsIdentity(),
  title: text("title").notNull(),
  role: roleEnum().default("guest"),
  userId: integer("user_id")
    .notNull()
    .references(() => users.id, { onDelete: "cascade" }),
  createdAt: timestamp("created_at").notNull().defaultNow(),
  updatedAt: timestamp("updated_at")
    .notNull()
    .$onUpdate(() => new Date()),
});
```

## Schema — Type Inference

```typescript
// BAD: manually typing insert/select types
interface User { id: number; name: string; email: string; }

// GOOD: infer from schema — always in sync
export type InsertUser = typeof users.$inferInsert;
export type SelectUser = typeof users.$inferSelect;
```

## Relations — One-to-Many

```typescript
import { relations } from "drizzle-orm";

export const usersRelations = relations(users, ({ many }) => ({
  posts: many(posts),
}));

export const postsRelations = relations(posts, ({ one }) => ({
  author: one(users, {
    fields: [posts.userId],
    references: [users.id],
  }),
}));
```

## Relations — Many-to-Many

```typescript
export const usersToGroups = pgTable("users_to_groups", {
  userId: integer("user_id")
    .notNull()
    .references(() => users.id),
  groupId: integer("group_id")
    .notNull()
    .references(() => groups.id),
}, (t) => [
  primaryKey({ columns: [t.userId, t.groupId] }),
]);

export const usersRelations = relations(users, ({ many }) => ({
  groups: many(usersToGroups),
}));

export const groupsRelations = relations(groups, ({ many }) => ({
  members: many(usersToGroups),
}));
```

## Relational Queries — `with` and Filters

```typescript
import * as schema from "./schema";
const db = drizzle(pool, { schema }); // pass schema to enable relational queries

// BAD: manual joins for simple relation fetching
const result = await db
  .select()
  .from(users)
  .leftJoin(posts, eq(users.id, posts.userId));

// GOOD: relational query API — automatic joins, nested types
const result = await db.query.users.findMany({
  with: {
    posts: true,
  },
});

// Filter and limit nested relations
const result = await db.query.users.findMany({
  with: {
    posts: {
      where: (posts, { eq }) => eq(posts.published, true),
      limit: 5,
      orderBy: (posts, { desc }) => [desc(posts.createdAt)],
    },
  },
});
```

## Queries — Select Only What You Need

```typescript
// BAD: fetches all columns
const allUsers = await db.select().from(users);

// GOOD: partial select — less data over the wire
const names = await db
  .select({ id: users.id, name: users.name })
  .from(users);
```

## Queries — Insert, Update, Delete

```typescript
// Insert with returning
const [newUser] = await db
  .insert(users)
  .values({ name: "Alice", email: "alice@example.com" })
  .returning();

// Upsert (PostgreSQL)
await db
  .insert(users)
  .values({ email: "alice@example.com", name: "Alice" })
  .onConflictDoUpdate({
    target: users.email,
    set: { name: "Alice Updated" },
  });

// Update
await db.update(users).set({ name: "Bob" }).where(eq(users.id, 1));

// Delete
await db.delete(users).where(eq(users.id, 1));
```

## Transactions

```typescript
// BAD: separate queries — no atomicity
await db.insert(orders).values(order);
await db.update(inventory).set({ stock: sql`stock - 1` }).where(eq(inventory.id, itemId));

// GOOD: wrap in transaction
await db.transaction(async (tx) => {
  await tx.insert(orders).values(order);
  await tx
    .update(inventory)
    .set({ stock: sql`stock - 1` })
    .where(eq(inventory.id, itemId));
});
```

## Migrations — Config and Workflow

```typescript
// drizzle.config.ts
import { defineConfig } from "drizzle-kit";

export default defineConfig({
  dialect: "postgresql",
  schema: "./src/db/schema.ts",
  out: "./drizzle",
  strict: true, // prompts on ambiguous changes like renames
  dbCredentials: { url: process.env.DATABASE_URL! },
});
```

```bash
# 1. Generate migration from schema diff
drizzle-kit generate --name=add_posts_table

# 2. Review the generated SQL in ./drizzle/ before applying

# 3a. Apply migrations (production — uses migration journal)
drizzle-kit migrate

# 3b. Push directly (dev only — no migration files)
drizzle-kit push

# Pull schema from existing database
drizzle-kit pull

# Custom/seed migration (empty SQL file you write yourself)
drizzle-kit generate --name=seed_users --custom
```

## Migrations — Programmatic Apply
```typescript
import { migrate } from "drizzle-orm/node-postgres/migrator";
import { drizzle } from "drizzle-orm/node-postgres";
import { Pool } from "pg";

const pool = new Pool({ connectionString: process.env.DATABASE_URL });
const db = drizzle(pool);

await migrate(db, { migrationsFolder: "./drizzle" });
await pool.end();
```

## Migrations — Rename Columns Safely

Drizzle Kit may interpret renames as drop + add = **data loss**. With `strict: true` it will prompt you. Write a custom migration instead:

```sql
-- drizzle/XXXX_rename_name_to_full_name/migration.sql
ALTER TABLE "users" RENAME COLUMN "name" TO "full_name";
```

## Migrations — Add Non-Nullable Column Safely

Generate the column addition, then use `--custom` for backfill + constraint:

```sql
ALTER TABLE "users" ADD COLUMN "role" VARCHAR(20);             -- 1. nullable
UPDATE "users" SET "role" = 'member' WHERE "role" IS NULL;     -- 2. backfill
ALTER TABLE "users" ALTER COLUMN "role" SET NOT NULL;           -- 3. constrain
```

## Rules

1. **Use identity columns** (`generatedAlwaysAsIdentity()`) over `serial` for PostgreSQL
2. **Explicit snake_case column names** — always pass the SQL name string
3. **Infer types from schema** — use `$inferInsert` / `$inferSelect`, never manual interfaces
4. **Define relations separately** — `relations()` calls live alongside table definitions
5. **Use relational query API** (`db.query.X.findMany({ with })`) for nested data
6. **Select only needed columns** — avoid bare `select()` in production queries
7. **Wrap multi-table writes in transactions** — `db.transaction()`
8. **Always review generated SQL** before running `drizzle-kit migrate`
9. **Enable `strict: true`** in drizzle config — catches ambiguous renames
10. **Never use `push` in production** — always use migration files via `generate` + `migrate`
11. **Three-step non-nullable columns** — add nullable, backfill, set NOT NULL
12. **Commit migration files to version control** — they are your database changelog
13. **Run `drizzle-kit generate` in CI** to detect schema drift
