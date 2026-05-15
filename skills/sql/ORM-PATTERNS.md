# ORM Patterns, Transactions & Locking

## Contents

- Prisma, Django, SQLAlchemy, ActiveRecord, TypeORM, Sequelize eager loading
- Transaction isolation levels (READ COMMITTED, SERIALIZABLE)
- Deadlock prevention
- Optimistic vs pessimistic locking
- Long-running transaction damage

## Prisma

**Prisma 6+ (mid-2024 GA): `relationLoadStrategy: "join"` is now the DEFAULT** for PG/MySQL on most relations — a single DB query with JOIN. The old multi-query plan is opt-in.

```typescript
// BAD: N+1 — works in any version
const users = await prisma.user.findMany();
for (const user of users) {
  const posts = await prisma.post.findMany({ where: { authorId: user.id } });
}

// GOOD (Prisma 6+ default): single JOIN
const users = await prisma.user.findMany({ include: { posts: true } });

// Force the legacy split-query plan (useful when JOIN is slow for huge relations):
const users = await prisma.user.findMany({
  relationLoadStrategy: "query",  // legacy: separate SELECTs joined in-memory
  include: { posts: true },
});
```

**Prisma <6:** the legacy split-query plan was default. If you're on an older version, pass `relationLoadStrategy: "join"` explicitly for the single-query plan.

## Django ORM

```python
# BAD: lazy loading — N+1
books = Book.objects.all()
for book in books:
    print(book.author.name)

# GOOD for ForeignKey/OneToOne: select_related (SQL JOIN)
books = Book.objects.select_related('author').all()

# GOOD for ManyToMany/reverse FK: prefetch_related (separate query with IN)
authors = Author.objects.prefetch_related('books').all()
```

**Trap:** `select_related` does not work on ManyToMany. `prefetch_related` works on ForeignKey but is less efficient than `select_related`.

## SQLAlchemy (2.0+ style)

SQLAlchemy 2.0 (released Jan 2023) is now standard. Examples use the modern `select()` API; the legacy `session.query()` still works but is discouraged.

```python
from sqlalchemy import select
from sqlalchemy.orm import joinedload, selectinload, subqueryload

# BAD: default lazy loading — N+1
users = session.execute(select(User)).scalars().all()
for user in users:
    print(user.posts)  # lazy load fires here

# joinedload: single query with LEFT OUTER JOIN
# Best for one-to-one, small result sets
users = session.execute(
    select(User).options(joinedload(User.posts))
).unique().scalars().all()

# selectinload: 2 queries (main + IN clause)
# Best for one-to-many, large collections — and the only safe choice with pagination
users = session.execute(
    select(User).options(selectinload(User.posts))
).scalars().all()

# subqueryload: 2 queries (main + subquery)
users = session.execute(
    select(User).options(subqueryload(User.posts))
).scalars().all()
```

**Trap:** `joinedload` with pagination — `LIMIT 10` applies to joined rows, not parent rows. You may get 2 users instead of 10. **Use `selectinload` for paginated queries.**

**Modern alternative to detect N+1: `raiseload` / `lazy="raise"`.** Make lazy loads throw an exception instead of silently firing, so accidental N+1 patterns fail loudly in development.

```python
class User(Base):
    posts = relationship("Post", lazy="raise")  # any lazy access raises

# Now you MUST eager-load explicitly:
users = session.execute(select(User).options(selectinload(User.posts))).scalars().all()
```

## ActiveRecord (Rails)

```ruby
# BAD: N+1
users = User.all
users.each { |u| puts u.posts.count }

# includes: Rails picks strategy (preload or eager_load)
users = User.includes(:posts).all

# preload: always separate queries (2 SELECTs)
users = User.preload(:posts).all

# eager_load: always LEFT OUTER JOIN (1 query)
users = User.eager_load(:posts).all
```

Use the `bullet` gem in development to auto-detect N+1.

## TypeORM

```typescript
// BAD: lazy loading
const users = await userRepository.find();
for (const user of users) {
  const posts = await user.posts;
}

// GOOD: eager load via relations
const users = await userRepository.find({ relations: ["posts"] });

// GOOD: query builder with explicit join
const users = await userRepository
  .createQueryBuilder("user")
  .leftJoinAndSelect("user.posts", "post")
  .getMany();
```

**Trap:** `eager: true` in entity decorators only works with `find*` methods. QueryBuilder **silently ignores** it — add `leftJoinAndSelect` manually.

## Sequelize

```javascript
// BAD: N+1
const users = await User.findAll();
for (const user of users) {
  const posts = await user.getPosts();
}

// GOOD: eager load with include
const users = await User.findAll({ include: [{ model: Post }] });
```

## SQL Logging Per ORM

See SKILL.md "ORM SQL Logging" table for the enable commands. Always enable in development.

## Transaction Isolation Levels

**READ COMMITTED** (default in PostgreSQL/MySQL): prevents dirty reads. Each statement sees data committed before it began. Other transactions can modify data between your statements.

**SERIALIZABLE**: transactions behave as if executed one after another. Prevents all anomalies but increases deadlocks. **Use for financial operations, inventory, seat booking.**

```sql
-- READ COMMITTED: non-repeatable reads possible
BEGIN;
SELECT balance FROM accounts WHERE id = 1;  -- 1000
-- another tx commits: balance = 500
SELECT balance FROM accounts WHERE id = 1;  -- 500 (changed!)
COMMIT;

-- SERIALIZABLE: full consistency
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT balance FROM accounts WHERE id = 1;
UPDATE accounts SET balance = balance - 100 WHERE id = 1;
COMMIT;  -- fails if another tx modified this row
```

## Deadlock Prevention

```
Tx A: locks row 1, then requests row 2
Tx B: locks row 2, then requests row 1
→ DEADLOCK — database kills one transaction
```

**Prevention:**
1. **Consistent lock ordering** — always lock rows in the same order (e.g., ascending ID)
2. **Short transactions** — minimize time locks are held
3. **Retry logic** — handle deadlock errors by retrying

## Optimistic vs Pessimistic Locking

### Optimistic (version column — low contention, read-heavy)

```sql
SELECT id, name, version FROM items WHERE id = 1;  -- version = 3

UPDATE items SET name = 'New', version = version + 1
WHERE id = 1 AND version = 3;
-- 0 rows affected = conflict → retry or error
```

### Pessimistic (SELECT FOR UPDATE — high contention)

```sql
BEGIN;
SELECT * FROM inventory WHERE product_id = 42 FOR UPDATE;
UPDATE inventory SET quantity = quantity - 1 WHERE product_id = 42;
COMMIT;
```

**When:** Pessimistic for high-contention (inventory, balances, reservations). Optimistic for low-contention (profile edits, document updates).

## Long-Running Transaction Damage

1. **VACUUM blocked** — dead rows pile up, table bloats unboundedly
2. **Lock escalation** — cascading waits across other transactions
3. **Connection pool exhaustion** — held connections unavailable
4. **Replication lag** — WAL application delayed on replicas

**Mitigations:**
- Set `idle_in_transaction_session_timeout` (PostgreSQL)
- Set `statement_timeout` as safety net
- Move analytics to read replicas
- Monitor `pg_stat_activity` for long-open transactions

## Rules

1. Never rely on lazy loading — always specify the eager-loading strategy.
2. Know your ORM's loading API: `include` / `select_related` / `joinedload` / `includes` / `relations`.
3. Enable SQL logging in development (see SKILL.md "ORM SQL Logging" table).
4. **SQLAlchemy:** never use `joinedload` with pagination — `LIMIT` breaks. Use `selectinload`.
5. **SQLAlchemy:** consider `lazy="raise"` / `raiseload()` to make N+1 fail loudly.
6. **Prisma 6+:** single-query JOIN is default; pass `relationLoadStrategy: "query"` only when JOIN is slow.
7. **TypeORM:** `eager: true` decorators don't work in QueryBuilder — add joins manually.
8. Use `SERIALIZABLE` isolation for financial, inventory, and seat-booking transactions.
9. Lock rows in consistent order to prevent deadlocks.
10. Optimistic locking (version column) for low-contention updates; pessimistic (`FOR UPDATE`) for high-contention resources.
11. Keep transactions short — long transactions block VACUUM and cause bloat.
12. Set `statement_timeout` and `idle_in_transaction_session_timeout` in production.
