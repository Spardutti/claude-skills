# Indexing & Query Performance

## Contents

- Index types (B-tree, Hash, GIN, GiST)
- Covering indexes (INCLUDE)
- Partial indexes
- Expression indexes
- SARGability deep dive
- LIKE with leading wildcards
- OR conditions
- EXPLAIN — reading query plans
- Pagination (keyset vs OFFSET)
- COUNT(*) on large tables
- Over-indexing

## Index Types

**B-tree** (default): equality and range (`=`, `<`, `>`, `BETWEEN`, `IN`, `IS NULL`). Use for most columns.

**Hash**: equality only. Smaller and faster for pure lookups, no range or ORDER BY support. Rarely worth it over B-tree in practice — B-tree handles equality well and supports more.

**GIN**: arrays, JSONB, full-text. Fast reads, slow writes.

```sql
CREATE INDEX idx_events_meta ON events USING gin (metadata jsonb_path_ops);
SELECT * FROM events WHERE metadata @> '{"type": "click"}';
```

**`jsonb_path_ops` vs default `jsonb_ops`:**
- `jsonb_path_ops` — smaller, faster, but only supports `@>` (containment).
- Default `jsonb_ops` — larger, slower, supports `?`, `?|`, `?&`, `@>`.

Use `jsonb_path_ops` when you only need containment (most common). Use default when you also need key-existence operators.

**GiST**: geometric data, range types, nearest-neighbor.

```sql
CREATE INDEX idx_locations ON places USING gist (geom);
```

## Covering Indexes (Index-Only Scans)

Include all needed columns so the database never touches the heap.

```sql
-- BAD: must fetch name from heap
CREATE INDEX idx_users_email ON users (email);
SELECT email, name FROM users WHERE email = 'foo@bar.com';

-- GOOD: INCLUDE avoids heap lookup
CREATE INDEX idx_users_email ON users (email) INCLUDE (name);
-- Plan: Index Only Scan (Heap Fetches: 0)
```

INCLUDE columns are payload only — not part of the search key, cannot be used in WHERE.

## Partial Indexes

Index only the rows that matter.

```sql
-- BAD: full index on all rows
CREATE INDEX idx_orders_status ON orders (status);

-- GOOD: partial index for the hot path
CREATE INDEX idx_active_orders ON orders (created_at) WHERE status = 'active';
```

Great for `WHERE deleted_at IS NULL`, `WHERE active = true`, `WHERE status = 'pending'`.

## Expression Indexes

```sql
-- BAD: function on column prevents index usage
CREATE INDEX idx_email ON users (email);
SELECT * FROM users WHERE LOWER(email) = 'foo@bar.com';  -- Seq Scan

-- GOOD: index the expression
CREATE INDEX idx_lower_email ON users (LOWER(email));
```

## SARGability — Deep Dive

A predicate is SARGable when the database can use an index to resolve it. Wrapping columns in functions or arithmetic breaks this.

```sql
-- BAD: function on column (PG: EXTRACT; MySQL: YEAR — both kill the index)
SELECT * FROM orders WHERE EXTRACT(YEAR FROM created_at) = 2025;
-- GOOD: rewrite as range
SELECT * FROM orders WHERE created_at >= '2025-01-01' AND created_at < '2026-01-01';

-- BAD: arithmetic on column
SELECT * FROM products WHERE price / 100 > 50;
-- GOOD: move arithmetic to the constant
SELECT * FROM products WHERE price > 5000;
```

### Implicit Type Casting

Mismatched types force per-row conversion.

```sql
-- BAD: phone_number VARCHAR(20), compared with INTEGER
SELECT * FROM users WHERE phone_number = 5551234;  -- Seq Scan

-- GOOD: match types
SELECT * FROM users WHERE phone_number = '5551234';
```

## LIKE With Leading Wildcards

```sql
-- BAD: B-tree useless with leading wildcard
SELECT * FROM users WHERE name LIKE '%smith%';

-- GOOD option 1: trailing wildcard only
SELECT * FROM users WHERE name LIKE 'smith%';

-- GOOD option 2: trigram index (PostgreSQL)
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX idx_name_trgm ON users USING gin (name gin_trgm_ops);
SELECT * FROM users WHERE name LIKE '%smith%';  -- Bitmap Index Scan
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

## EXPLAIN — Reading Query Plans

```sql
-- Estimated plan (does not execute)
EXPLAIN SELECT * FROM orders WHERE customer_id = 42;

-- Actual execution with timing (EXECUTES the query).
-- BUFFERS is the single most useful flag — shows shared-hit vs disk-read I/O.
EXPLAIN (ANALYZE, BUFFERS, SETTINGS, WAL)
SELECT * FROM orders WHERE customer_id = 42;
```

`SETTINGS` (PG 12+) reveals non-default planner GUCs. `WAL` (PG 13+) shows write amplification on `INSERT`/`UPDATE`/`DELETE`.

**Warning:** EXPLAIN ANALYZE runs the query. Wrap destructive statements in a transaction and ROLLBACK.

### Scan Types

| Scan | When | Speed |
|---|---|---|
| Seq Scan | Small tables or >~10% of rows | Reads entire table |
| Index Scan | Small fraction of large table | Index lookup + heap fetch |
| Index Only Scan | All columns in the index | Never touches heap (fastest) |
| Bitmap Index Scan | Too many for Index Scan, too few for Seq Scan | Builds bitmap, sequential page reads |

### Join Algorithms

| Algorithm | Best For |
|---|---|
| Nested Loop | Small outer + indexed inner |
| Hash Join | Large unsorted datasets, equality joins |
| Merge Join | Both inputs already sorted on join key |

### Red Flags

- Seq Scan on large table → missing index or non-SARGable predicate
- Estimated vs actual rows differ wildly → run `ANALYZE tablename`
- Sort Method: external merge Disk → increase `work_mem`
- Nested Loop + Seq Scan on inner → missing index on join column

## Pagination — OFFSET Is a Trap

OFFSET reads and discards all skipped rows. Page 5000 reads 100,000 rows to return 20.

```sql
-- BAD: linear degradation with depth
SELECT * FROM products ORDER BY id LIMIT 20 OFFSET 100000;

-- GOOD: keyset pagination — constant performance
SELECT id, name, created_at FROM products
ORDER BY created_at DESC, id DESC LIMIT 20;

-- Next page (use last row's values as cursor):
SELECT id, name, created_at FROM products
WHERE (created_at, id) < ('2025-06-15 10:30:00', 9542)
ORDER BY created_at DESC, id DESC LIMIT 20;
```

Keyset needs a supporting index: `CREATE INDEX ON products (created_at DESC, id DESC)`.

Trade-off: keyset cannot jump to arbitrary pages. Use OFFSET only for small datasets or admin UIs.

## COUNT(*) on Large Tables

```sql
-- BAD: full table scan in PostgreSQL (MVCC = no cached count)
SELECT COUNT(*) FROM orders;
```

**Best:** maintain a counter (trigger or app-level) updated alongside writes. For dashboards, cache the value.

**Fallback (approximate):** `pg_stat_user_tables.n_live_tup` (updated by autovacuum) or `pg_class.reltuples`. Both can be wildly stale after bulk loads — run `ANALYZE` first.

```sql
SELECT n_live_tup FROM pg_stat_user_tables WHERE relname = 'orders';
-- or
SELECT reltuples::bigint FROM pg_class WHERE relname = 'orders';
```

## Over-Indexing

Every index slows INSERT, UPDATE, DELETE. Monitor unused indexes:

```sql
SELECT indexrelname, idx_scan
FROM pg_stat_user_indexes
WHERE idx_scan = 0
ORDER BY pg_relation_size(indexrelid) DESC;
```

## Rules

1. **Composite index order: equality → range → sort** — leftmost-prefix rule (B-tree specific).
2. **Never wrap indexed columns in functions** — rewrite as range or use expression indexes.
3. **Match types exactly** in WHERE clauses — implicit casts kill indexes.
4. **Use `INCLUDE` for covering indexes** on critical queries.
5. **Use partial indexes** when queries target a well-defined row subset.
6. **Always index foreign key columns** (PG/SQLite/MSSQL won't do it for you; MySQL does).
7. **Check `EXPLAIN (ANALYZE, BUFFERS)`** before and after index changes — measure, don't guess.
8. **Use keyset pagination** for user-facing paginated interfaces at scale.
9. **`SELECT` only needed columns** — enables index-only scans, reduces memory.
10. **Monitor unused indexes** — each adds write overhead for zero benefit.
11. **Run `ANALYZE` after bulk loads** — stale statistics cause bad query plans.
12. **`CREATE INDEX CONCURRENTLY`** in production — avoids blocking writes.
