---
name: sql
category: Database
description: "MUST USE when writing SQL, creating tables, defining columns, choosing data types, writing migrations, creating indexes, diagnosing slow queries, reading EXPLAIN output, writing JOINs, defining relationships, using subqueries, or writing code with any ORM (Prisma, Django, SQLAlchemy, ActiveRecord, TypeORM, Sequelize, Drizzle). Enforces correct types (TIMESTAMPTZ, NUMERIC for money), NOT NULL discipline, composite index order, SARGability, eager loading to prevent N+1, transaction safety, and safe migration patterns."
---

# SQL — Schema, Indexes, Joins, ORMs

Critical relational design and query patterns. The 80% case lives in this file; deep dives in the reference files.

## Quick Reference — When to Load What

| Working on… | Read |
|---|---|
| `CREATE TABLE`, `ALTER TABLE`, picking types, writing migrations | SCHEMA-DESIGN.md |
| `CREATE INDEX`, slow queries, `EXPLAIN` output, pagination | INDEXING.md |
| `JOIN`, subqueries, defining FKs, junction tables | JOINS.md |
| Any ORM code (Prisma/Django/SQLAlchemy/AR/TypeORM/Sequelize/Drizzle), transactions, locking | ORM-PATTERNS.md |

## Critical Gotchas (Always-Inline)

These are the bugs that ship to production silently. Memorize them.

### 1. LEFT JOIN Silently Becomes INNER JOIN

Filtering the right-side table in `WHERE` eliminates the NULL rows the LEFT JOIN was supposed to preserve.

```sql
-- BAD: WHERE on right table kills the LEFT JOIN
SELECT c.name, o.total FROM customers c
LEFT JOIN orders o ON c.id = o.customer_id
WHERE o.status = 'shipped';
-- Customers with no shipped orders DISAPPEAR

-- GOOD: filter in the ON clause
SELECT c.name, o.total FROM customers c
LEFT JOIN orders o ON c.id = o.customer_id AND o.status = 'shipped';
```

Rule: `ON` controls how tables relate; `WHERE` controls what rows survive. For OUTER JOINs the distinction is critical.

### 2. N+1 With ORMs (Lazy Loading Default)

Every ORM defaults to lazy loading. Fetching parents then accessing children in a loop fires N+1 queries.

```python
# BAD: 1 query for users + N queries for posts (every ORM)
users = User.find_all()
for user in users:
    print(user.posts)  # separate SELECT per user
```

The fix is ORM-specific — see ORM-PATTERNS.md for per-ORM eager loading APIs (`include`, `select_related`, `joinedload`, `includes`, `relations`, etc.).

**Trap:** SQLAlchemy `joinedload` + pagination silently broken — `LIMIT N` applies to joined rows, not parent rows, so you may get 2 users instead of 10. Use `selectinload` for paginated queries.

### 3. NOT IN With NULLs Returns Empty Set

If any value in the subquery is NULL, `NOT IN` returns no rows. Always use `NOT EXISTS`.

```sql
-- BAD: one NULL in closed_departments → empty result
SELECT name FROM employees
WHERE department_id NOT IN (SELECT department_id FROM closed_departments);

-- GOOD
SELECT name FROM employees e
WHERE NOT EXISTS (
  SELECT 1 FROM closed_departments cd WHERE cd.department_id = e.department_id
);
```

### 4. NUMERIC for Money, TIMESTAMPTZ for Time

```sql
-- BAD: FLOAT loses precision; TIMESTAMP loses timezone
CREATE TABLE invoices (amount REAL, created_at TIMESTAMP);

-- GOOD
CREATE TABLE invoices (
    amount NUMERIC(12,2) NOT NULL CHECK (amount >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

### 5. Missing FK Indexes

PostgreSQL does **not** auto-create indexes on foreign key columns. Without them, JOINs require sequential scans and parent DELETE/UPDATE locks the whole child table. (MySQL/InnoDB auto-indexes FKs; PG, SQLite, SQL Server do not.)

```sql
CREATE INDEX idx_orders_customer_id ON orders (customer_id);
```

### 6. Composite Index Column Order

Equality → range → ORDER BY. Leftmost-prefix rule: index `(A, B, C)` serves `A`, `A+B`, `A+B+C` — but not `B` alone.

```sql
-- BAD: leading column is the range predicate
CREATE INDEX idx_orders ON orders (created_at, customer_id);

-- GOOD: equality first, range second
CREATE INDEX idx_orders ON orders (customer_id, created_at);
```

### 7. SARGability — No Functions on Indexed Columns

```sql
-- BAD: function wraps the column → index ignored
SELECT * FROM orders WHERE EXTRACT(YEAR FROM created_at) = 2025;
-- (MySQL syntax: YEAR(created_at) — same problem.)

-- GOOD: rewrite as range
SELECT * FROM orders
WHERE created_at >= '2025-01-01' AND created_at < '2026-01-01';
```

Same applies to arithmetic (`price / 100 > 50` → `price > 5000`) and implicit type casts (`VARCHAR phone = 5551234` casts every row).

### 8. NOT NULL by Default

NULL breaks equality (`NULL != NULL`) and forces three-valued logic everywhere. Make every column NOT NULL unless it's genuinely optional.

### 9. Pre-Aggregate Before Joining Two "Many" Tables

Joining `orders` and `refunds` both via `customer_id` creates a Cartesian product per customer — aggregates inflate silently.

```sql
-- BAD: 3 orders × 2 refunds = 6 rows per customer, SUM(amount) is 2x wrong
SELECT c.id, SUM(o.amount), SUM(r.refund)
FROM customers c
JOIN orders o ON c.id = o.customer_id
JOIN refunds r ON c.id = r.customer_id
GROUP BY c.id;

-- GOOD: pre-aggregate
SELECT c.id, o.total, r.refunds FROM customers c
LEFT JOIN (SELECT customer_id, SUM(amount) AS total FROM orders GROUP BY customer_id) o
  ON c.id = o.customer_id
LEFT JOIN (SELECT customer_id, SUM(refund) AS refunds FROM refunds GROUP BY customer_id) r
  ON c.id = r.customer_id;
```

### 10. Safe Migrations — Three Things

Three patterns that prevent production outages. See SCHEMA-DESIGN.md for full migration playbook.

```sql
-- PG 11+: ADD COLUMN with constant NOT NULL DEFAULT is INSTANT — no table rewrite.
ALTER TABLE users ADD COLUMN bio TEXT NOT NULL DEFAULT 'No bio';

-- BUT volatile defaults (NOW(), gen_random_uuid()) or backfilling existing
-- rows from another value still need the three-step:
ALTER TABLE users ADD COLUMN bio TEXT;                          -- 1. nullable
UPDATE users SET bio = '...' WHERE id BETWEEN 1 AND 10000;     -- 2. batched backfill
ALTER TABLE users ALTER COLUMN bio SET NOT NULL;                -- 3. constrain

-- Indexes in production
CREATE INDEX CONCURRENTLY idx_users_email ON users (email);

-- Always set a lock timeout
SET lock_timeout = '5s';
```

## When to Use What

| Task | Approach |
|---|---|
| Money | `NUMERIC(12,2)` |
| Timestamps | `TIMESTAMPTZ` |
| Primary keys | `BIGSERIAL` (internal) or `UUIDv7` (public) — never `UUIDv4`; default to **BIGINT** not INT to avoid future exhaustion |
| UUIDv7 in PG | PG 18+ has built-in `uuidv7()`; earlier versions need an extension or app-side generation |
| Membership check | `EXISTS` (short-circuits) |
| Exclude-with-NULLs | `NOT EXISTS` (never `NOT IN`) |
| Pagination at scale | Keyset (cursor), not `OFFSET` |
| `COUNT(*)` on huge tables | Approximate via `pg_class.reltuples` |
| Index for OR conditions | `UNION` of two index scans |
| LIKE with leading wildcard | `pg_trgm` GIN index |
| Index foreign keys | Always |
| Soft delete | Avoid — prefer archive table + hard delete |
| EAV / multi-value columns | Never — use proper columns or JSONB+GIN |

## ORM SQL Logging — Enable in Development

Always inspect what your ORM generates. See ORM-PATTERNS.md for full details.

| ORM | Enable |
|-----|---|
| Prisma | `new PrismaClient({ log: ['query'] })` |
| Django | Django Debug Toolbar or `django.db.connection.queries` |
| SQLAlchemy | `echo=True` on engine |
| ActiveRecord | Rails dev log, `bullet` gem |
| TypeORM | `logging: true` |
| Sequelize | `logging: console.log` |
| Drizzle | `logger: true` |

## Rules

1. **Schema:** `TIMESTAMPTZ` always, `NUMERIC` for money, `NOT NULL` by default, FK on the "many" side, no EAV, no comma-separated IDs.
2. **Indexes:** Always index FK columns (PG/SQLite/MSSQL). Composite order = equality → range → sort. Never wrap indexed columns in functions. `SELECT` only needed columns to enable index-only scans. Use `CREATE INDEX CONCURRENTLY` in production.
3. **Joins:** Filter outer-join right side in `ON`, not `WHERE`. Use `NOT EXISTS`, never `NOT IN`. Pre-aggregate before joining "many" tables. `COUNT(column)` not `COUNT(*)` with OUTER JOINs.
4. **ORMs:** Never rely on lazy loading. Always specify the eager-loading strategy for your ORM. Enable SQL logging in dev.
5. **Transactions:** Keep them short. Use `SERIALIZABLE` for financial/inventory operations. Lock rows in consistent order. Set `statement_timeout` and `idle_in_transaction_session_timeout`.
6. **Migrations:** Constant-default columns are instant (PG 11+); use three-step (nullable → backfill → constrain) for volatile/computed defaults or row-derived backfills. `CREATE INDEX CONCURRENTLY`. `ADD CONSTRAINT NOT VALID` then `VALIDATE` separately. Always `SET lock_timeout`.
7. **Measure, don't guess:** Run `EXPLAIN ANALYZE` before and after index changes. Run `ANALYZE` after bulk loads.

## Reference Files

For deeper guidance, load the file matching what you're working on:

- **SCHEMA-DESIGN.md** — read when creating or altering tables, picking data types, writing migrations, or designing relationships. Covers: normalization (1NF/2NF/3NF), data type selection, constraints, god tables, polymorphic associations, soft delete pitfalls, three-step migrations, lock management.
- **INDEXING.md** — read when creating indexes, diagnosing slow queries, or reading EXPLAIN output. Covers: index types (B-tree/Hash/GIN/GiST), covering indexes, partial indexes, expression indexes, SARGability deep dive, LIKE with wildcards, OR conditions, EXPLAIN plan interpretation, keyset pagination, COUNT on large tables.
- **JOINS.md** — read when writing JOINs, defining FKs, or using subqueries. Covers: LEFT-to-INNER conversion variants, fan-out, EXISTS vs IN vs JOIN tradeoffs, correlated subqueries, junction tables, CASCADE pitfalls, FULL OUTER JOIN use cases.
- **ORM-PATTERNS.md** — read when writing ORM code or working with transactions/locking. Covers: per-ORM eager loading APIs (Prisma, Django, SQLAlchemy, ActiveRecord, TypeORM, Sequelize), transaction isolation levels, optimistic vs pessimistic locking, deadlock prevention, long-running transaction damage.
