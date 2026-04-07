---
name: sql-indexing
category: Database
description: "MUST USE when creating indexes, diagnosing slow queries, or reading EXPLAIN output. Enforces correct composite index order, SARGable predicates, covering indexes, keyset pagination, and query plan interpretation."
---

# SQL Indexing & Query Performance

## Index Types — When to Use Each

**B-tree** (default): equality and range queries (`=`, `<`, `>`, `BETWEEN`, `IN`, `IS NULL`). Use for most columns.

**Hash**: equality only (`=`). Smaller and faster than B-tree for pure lookups, but cannot support range queries or ORDER BY.

**GIN** (Generalized Inverted Index): arrays, JSONB, full-text search. Fast reads, slow writes.

```sql
CREATE INDEX idx_events_meta ON events USING gin (metadata jsonb_path_ops);
SELECT * FROM events WHERE metadata @> '{"type": "click"}';
```

**GiST** (Generalized Search Tree): geometric data, range types, nearest-neighbor queries.

```sql
CREATE INDEX idx_locations ON places USING gist (geom);
SELECT * FROM places WHERE ST_DWithin(geom, ST_MakePoint(-73.9, 40.7)::geography, 1000);
```

## Composite Index Column Order

An index on `(A, B, C)` serves queries on `A`, `A+B`, or `A+B+C` — but **not** `B` alone or `C` alone (leftmost prefix rule).

```sql
-- BAD: leading column is the range predicate
CREATE INDEX idx_orders ON orders (created_at, customer_id);
-- WHERE customer_id = 42 cannot use this index

-- GOOD: equality first, range second, sort last
CREATE INDEX idx_orders ON orders (customer_id, created_at);
-- WHERE customer_id = 42 AND created_at > '2025-01-01' ORDER BY created_at
-- Jumps to customer_id=42, scans dates in order, no extra sort
```

**Rule of thumb:** equality predicates first → range predicates next → ORDER BY columns last.

## Covering Indexes (Index-Only Scans)

Include all columns needed by the query so the database never touches the table heap.

```sql
-- BAD: must fetch name from heap
CREATE INDEX idx_users_email ON users (email);
SELECT email, name FROM users WHERE email = 'foo@bar.com';
-- Plan: Index Scan + heap fetch

-- GOOD: INCLUDE avoids heap lookup
CREATE INDEX idx_users_email ON users (email) INCLUDE (name);
SELECT email, name FROM users WHERE email = 'foo@bar.com';
-- Plan: Index Only Scan (Heap Fetches: 0)
```

INCLUDE columns are payload only — not part of the search key, cannot be used in WHERE.

## Partial Indexes

Index only the rows that matter. Much smaller, much faster.

```sql
-- BAD: full index on all rows
CREATE INDEX idx_orders_status ON orders (status);

-- GOOD: partial index for the hot query path
CREATE INDEX idx_active_orders ON orders (created_at)
  WHERE status = 'active';

SELECT * FROM orders WHERE status = 'active' AND created_at > '2025-01-01';
-- Uses the small partial index
```

Great for: `WHERE deleted_at IS NULL`, `WHERE active = true`, `WHERE status = 'pending'`.

## Expression Indexes

```sql
-- BAD: function on column prevents index usage
CREATE INDEX idx_email ON users (email);
SELECT * FROM users WHERE LOWER(email) = 'foo@bar.com';
-- Seq Scan — index ignored

-- GOOD: index the expression
CREATE INDEX idx_lower_email ON users (LOWER(email));
SELECT * FROM users WHERE LOWER(email) = 'foo@bar.com';
-- Index Scan
```

## SARGability — Don't Kill Your Indexes

A predicate is SARGable (Search ARGument able) when the database can use an index to resolve it. Wrapping columns in functions or arithmetic breaks this.

```sql
-- BAD: function on column
SELECT * FROM orders WHERE YEAR(created_at) = 2025;

-- GOOD: rewrite as range
SELECT * FROM orders
WHERE created_at >= '2025-01-01' AND created_at < '2026-01-01';

-- BAD: arithmetic on column
SELECT * FROM products WHERE price / 100 > 50;

-- GOOD: move arithmetic to the constant
SELECT * FROM products WHERE price > 5000;
```

## Implicit Type Casting

Mismatched types force per-row conversion, turning index seeks into full scans.

```sql
-- BAD: column is VARCHAR, compared with INTEGER
-- phone_number VARCHAR(20), indexed
SELECT * FROM users WHERE phone_number = 5551234;
-- Casts phone_number to int for EVERY row → Seq Scan

-- GOOD: match types exactly
SELECT * FROM users WHERE phone_number = '5551234';
```

## LIKE With Leading Wildcards

```sql
-- BAD: leading wildcard — B-tree useless
SELECT * FROM users WHERE name LIKE '%smith%';

-- GOOD option 1: trailing wildcard only
SELECT * FROM users WHERE name LIKE 'smith%';

-- GOOD option 2: trigram index (PostgreSQL)
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX idx_name_trgm ON users USING gin (name gin_trgm_ops);
SELECT * FROM users WHERE name LIKE '%smith%';
-- Bitmap Index Scan — fast even with leading wildcard
```

## OR Conditions

```sql
-- BAD: OR across columns may prevent index usage
SELECT * FROM users WHERE email = 'foo@bar.com' OR phone = '555-1234';

-- GOOD: UNION lets each branch use its own index
SELECT * FROM users WHERE email = 'foo@bar.com'
UNION
SELECT * FROM users WHERE phone = '555-1234';
```

PostgreSQL can sometimes handle OR with BitmapOr — check EXPLAIN.

## Missing FK Indexes

PostgreSQL does **not** auto-create indexes on foreign key columns. Without them:
1. JOINs on the FK require sequential scans
2. Parent row DELETE/UPDATE takes a ShareLock on the entire child table

```sql
-- Always index foreign keys
CREATE INDEX idx_orders_customer_id ON orders (customer_id);
```

## EXPLAIN — Reading Query Plans

```sql
-- Estimated plan (does not execute)
EXPLAIN SELECT * FROM orders WHERE customer_id = 42;

-- Actual execution with timing (EXECUTES the query)
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT * FROM orders WHERE customer_id = 42;
```

**Warning:** EXPLAIN ANALYZE runs the query. Wrap destructive statements in a transaction and ROLLBACK.

### Scan Types

| Scan | When | Speed |
|------|------|-------|
| **Seq Scan** | Small tables or >~10% of rows returned | Reads entire table |
| **Index Scan** | Small fraction of large table | Index lookup + heap fetch |
| **Index Only Scan** | All columns in the index | Never touches heap (fastest) |
| **Bitmap Index Scan** | Too many for Index Scan, too few for Seq Scan | Builds bitmap, reads pages sequentially |

### Join Algorithms

| Algorithm | Best For |
|-----------|----------|
| **Nested Loop** | Small outer + indexed inner |
| **Hash Join** | Large unsorted datasets, equality joins |
| **Merge Join** | Both inputs already sorted on join key |

### Red Flags in EXPLAIN Output

- **Seq Scan on large table** → missing index or non-SARGable predicate
- **Estimated vs actual rows differ wildly** → run `ANALYZE tablename`
- **Sort Method: external merge Disk** → increase `work_mem`
- **Nested Loop + Seq Scan on inner** → missing index on join column

## Pagination — OFFSET Is a Trap

OFFSET reads and discards all skipped rows. Page 5000 reads 100,000 rows to return 20.

```sql
-- BAD: linear degradation with depth
SELECT * FROM products ORDER BY id LIMIT 20 OFFSET 100000;

-- GOOD: keyset pagination — constant performance
-- First page:
SELECT id, name, created_at FROM products
ORDER BY created_at DESC, id DESC
LIMIT 20;

-- Next page (use last row's values as cursor):
SELECT id, name, created_at FROM products
WHERE (created_at, id) < ('2025-06-15 10:30:00', 9542)
ORDER BY created_at DESC, id DESC
LIMIT 20;
```

Keyset needs a supporting index: `CREATE INDEX ON products (created_at DESC, id DESC)`.

Trade-off: keyset cannot jump to arbitrary pages. Use OFFSET only for small datasets or admin UIs.

## COUNT(*) on Large Tables

```sql
-- BAD: full table scan in PostgreSQL (MVCC means no cached count)
SELECT COUNT(*) FROM orders;

-- GOOD: approximate count from statistics
SELECT reltuples::bigint AS estimate
FROM pg_class WHERE relname = 'orders';
```

## Over-Indexing

Every index slows INSERT, UPDATE, and DELETE. Monitor unused indexes:

```sql
SELECT indexrelname, idx_scan
FROM pg_stat_user_indexes
WHERE idx_scan = 0
ORDER BY pg_relation_size(indexrelid) DESC;
```

## Rules

1. **Composite index order: equality → range → sort** — leftmost prefix rule
2. **Never wrap indexed columns in functions** — rewrite as range predicates or use expression indexes
3. **Match types exactly** in WHERE clauses — implicit casts kill indexes
4. **Use INCLUDE for covering indexes** on your most critical queries
5. **Use partial indexes** when queries target a well-defined row subset
6. **Always index foreign key columns** — PostgreSQL won't do it for you
7. **Check EXPLAIN ANALYZE** before and after index changes — measure, don't guess
8. **Use keyset pagination** for user-facing paginated interfaces at scale
9. **SELECT only needed columns** — enables index-only scans and reduces memory
10. **Monitor unused indexes** — each one adds write overhead for zero benefit
11. **Run ANALYZE after bulk loads** — stale statistics cause bad query plans
12. **Use CREATE INDEX CONCURRENTLY** in production — avoids blocking writes
