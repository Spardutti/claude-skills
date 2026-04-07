---
name: sql-orm-patterns
category: Database
description: "MUST USE when writing code with any ORM (Prisma, Django, SQLAlchemy, ActiveRecord, TypeORM, Sequelize, Drizzle). Enforces eager loading to prevent N+1, correct loading strategies, SQL inspection, transaction safety, and locking patterns."
---

# SQL ORM Anti-Patterns & Transactions

## The N+1 Query Problem

Every ORM defaults to lazy loading. Fetching a list of parents then accessing children in a loop fires N+1 queries.

```python
# BAD: 1 query for users + N queries for posts (every ORM, every language)
users = User.find_all()
for user in users:
    print(user.posts)  # separate SELECT per user
# 101 queries for 100 users
```

The fix is ORM-specific — learn your ORM's eager loading API.

## Prisma — Does NOT Use JOINs by Default

Prisma issues separate queries and joins in-memory.

```typescript
// BAD: N+1 — separate query per user
const users = await prisma.user.findMany();
for (const user of users) {
  const posts = await prisma.post.findMany({ where: { authorId: user.id } });
}

// BETTER: include — 2 queries (SELECT users + SELECT posts WHERE id IN (...))
const users = await prisma.user.findMany({
  include: { posts: true },
});

// BEST: single database query with JOIN (Prisma 5.8+)
const users = await prisma.user.findMany({
  relationLoadStrategy: "join",
  include: { posts: true },
});
```

## Django ORM

```python
# BAD: lazy loading — N+1
books = Book.objects.all()
for book in books:
    print(book.author.name)  # separate query per book

# GOOD for ForeignKey/OneToOne: select_related (SQL JOIN)
books = Book.objects.select_related('author').all()

# GOOD for ManyToMany/reverse FK: prefetch_related (separate query with IN)
authors = Author.objects.prefetch_related('books').all()
```

**Trap:** `select_related` on ManyToMany does not work. `prefetch_related` on ForeignKey works but is less efficient than `select_related`.

## SQLAlchemy

```python
from sqlalchemy.orm import joinedload, selectinload, subqueryload

# BAD: default lazy loading — N+1
users = session.query(User).all()
for user in users:
    print(user.posts)

# joinedload: single query with LEFT OUTER JOIN
# Best for one-to-one, small result sets
users = session.query(User).options(joinedload(User.posts)).all()

# selectinload: 2 queries (main + IN clause)
# Best for one-to-many, large collections
users = session.query(User).options(selectinload(User.posts)).all()

# subqueryload: 2 queries (main + subquery)
# Best for filtered/paginated queries
users = session.query(User).options(subqueryload(User.posts)).all()
```

**Trap:** `joinedload` with pagination — `LIMIT 10` applies to joined rows, not parent rows. You may get 2 users instead of 10.

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

Use the `bullet` gem in development to auto-detect N+1 queries.

## TypeORM

```typescript
// BAD: lazy loading — separate query per access
const users = await userRepository.find();
for (const user of users) {
  const posts = await user.posts;  // lazy trigger
}

// GOOD: eager load via relations
const users = await userRepository.find({ relations: ["posts"] });

// GOOD: query builder with explicit join
const users = await userRepository
  .createQueryBuilder("user")
  .leftJoinAndSelect("user.posts", "post")
  .getMany();
```

**Trap:** `eager: true` in entity decorators only works with `find*` methods. QueryBuilder **silently ignores** it — you must add `leftJoinAndSelect` manually.

## Sequelize

```javascript
// BAD: N+1
const users = await User.findAll();
for (const user of users) {
  const posts = await user.getPosts();
}

// GOOD: eager load with include
const users = await User.findAll({
  include: [{ model: Post }],
});
```

## Inspecting ORM-Generated SQL

Always enable query logging during development:

| ORM | How to Enable |
|-----|---------------|
| **Prisma** | `new PrismaClient({ log: ['query'] })` |
| **Django** | `django.db.connection.queries` or Django Debug Toolbar |
| **SQLAlchemy** | `echo=True` on engine or `logging.getLogger('sqlalchemy.engine')` |
| **ActiveRecord** | Rails dev logs, `ActiveRecord::Base.logger`, Bullet gem |
| **TypeORM** | `logging: true` in connection options |
| **Sequelize** | `logging: console.log` in connection options |
| **Drizzle** | `logger: true` in drizzle config |

## Transaction Isolation Levels

**READ COMMITTED** (default in PostgreSQL/MySQL): prevents dirty reads. Each statement sees data committed before it began. Other transactions can modify data between your statements.

**SERIALIZABLE**: transactions behave as if executed one after another. Prevents all anomalies but increases deadlocks. **Use for financial operations, inventory, seat booking.**

```sql
-- READ COMMITTED: non-repeatable reads are possible
BEGIN;
SELECT balance FROM accounts WHERE id = 1;  -- 1000
-- another tx commits: balance = 500
SELECT balance FROM accounts WHERE id = 1;  -- 500 (changed!)
COMMIT;

-- SERIALIZABLE: full consistency
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT balance FROM accounts WHERE id = 1;  -- 1000
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
3. **Retry logic** — handle deadlock errors by retrying the transaction

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
-- Row exclusively locked until COMMIT
UPDATE inventory SET quantity = quantity - 1 WHERE product_id = 42;
COMMIT;
```

**When to use:** Pessimistic for high-contention (inventory, balances, reservations). Optimistic for low-contention (profile edits, document updates).

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

1. **Never rely on lazy loading** — always specify eager loading strategy
2. **Know your ORM's loading API**: `include`/`select_related`/`joinedload`/`includes`/`relations`
3. **Enable SQL logging in development** — inspect what your ORM actually generates
4. **Don't use joinedload with pagination** (SQLAlchemy) — LIMIT applies to joined rows
5. **Prisma: use `relationLoadStrategy: "join"`** for single-query loading
6. **TypeORM: eager decorators don't work in QueryBuilder** — add joins manually
7. **Use SERIALIZABLE isolation** for financial transactions and inventory
8. **Lock rows in consistent order** to prevent deadlocks
9. **Use optimistic locking** (version column) for low-contention updates
10. **Use pessimistic locking** (FOR UPDATE) for high-contention resources
11. **Keep transactions short** — long transactions block VACUUM and cause bloat
12. **Set statement_timeout and idle_in_transaction_session_timeout** in production
