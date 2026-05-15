# Alembic Migration Best Practices

Alembic 1.18 / SQLAlchemy 2.0 / Python 3.12+.

## Contents

- Naming conventions on `MetaData`
- Timestamped file templates
- `alembic.ini` / `env.py` setup
- Async `env.py` (`async_engine_from_config` + `run_sync`)
- Autogenerate — what it detects and misses, fixing renames
- Complete downgrades
- Data migrations — never import app models, batch backfills
- Safe migration patterns (3-step non-nullable, batch ops, online DDL, lock timeout)
- Branching and merging revisions
- Testing (stairway, `alembic check`) and deployment ordering

## Naming Conventions — Define Once

```python
# BAD: no naming convention — anonymous constraints break downgrades
class Base(DeclarativeBase):
    pass

# GOOD: explicit naming convention so every constraint has a deterministic name
from sqlalchemy import MetaData
from sqlalchemy.orm import DeclarativeBase

convention = {
    "ix": "ix_%(table_name)s_%(column_0_label)s",
    "uq": "uq_%(table_name)s_%(column_0_name)s",
    "ck": "ck_%(table_name)s_%(constraint_name)s",
    "fk": "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s",
    "pk": "pk_%(table_name)s",
}

class Base(DeclarativeBase):
    metadata = MetaData(naming_convention=convention)
```

## File Naming — Use Timestamps

```ini
# alembic.ini
file_template = %%(epoch)d_%%(rev)s_%%(slug)s
```

```bash
# BAD
alembic revision --autogenerate -m "changes"
# GOOD — descriptive message becomes the file slug
alembic revision --autogenerate -m "add_phone_column_to_users"
```

## env.py Setup

```python
# env.py — point target_metadata at the app's Base, enable thorough comparison
from myapp.db import Base

target_metadata = Base.metadata

def do_run_migrations(connection: Connection) -> None:
    context.configure(
        connection=connection,
        target_metadata=target_metadata,
        compare_type=True,            # detect column type changes
        compare_server_default=True,  # detect server-default changes
        render_as_batch=True,         # required for SQLite ALTER support
    )
    with context.begin_transaction():
        context.run_migrations()
```

## Async env.py

`alembic init -t async` scaffolds this. The default sync `engine_from_config`
cannot drive `asyncpg`/`aiosqlite` — async migrations need `async_engine_from_config`
plus `connection.run_sync(...)` to bridge into Alembic's sync migration API.

```python
# GOOD: async env.py — async engine, NullPool, run_sync bridge
import asyncio
from alembic import context
from sqlalchemy import pool, Connection
from sqlalchemy.ext.asyncio import async_engine_from_config


def do_run_migrations(connection: Connection) -> None:
    context.configure(
        connection=connection,
        target_metadata=target_metadata,
        compare_type=True,
        compare_server_default=True,
    )
    with context.begin_transaction():
        context.run_migrations()


async def run_async_migrations() -> None:
    connectable = async_engine_from_config(
        context.config.get_section(context.config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,  # fresh connection, closed immediately
    )
    async with connectable.connect() as connection:
        await connection.run_sync(do_run_migrations)
    await connectable.dispose()


def run_migrations_online() -> None:
    asyncio.run(run_async_migrations())
```

Use `NullPool` for migrations: a migration run wants one connection opened and
closed, not a long-lived pool competing with the app.

## Autogenerate — Always Review

**Detects:** table/column add/remove, nullable changes, indexes, foreign keys,
and (with the flags above) type and server-default changes.

**Cannot detect:** renames (rendered as drop + create = **data loss**), enum
value changes, standalone CHECK/EXCLUDE constraints, trigger/function changes.

### Fix Renames Manually

```python
# BAD: autogenerate output — DATA LOSS
def upgrade() -> None:
    op.drop_column("users", "name")
    op.add_column("users", sa.Column("full_name", sa.String(100)))

# GOOD: rename, with a matching downgrade
def upgrade() -> None:
    op.alter_column("users", "name", new_column_name="full_name")

def downgrade() -> None:
    op.alter_column("users", "full_name", new_column_name="name")
```

## Complete Downgrades — Always

Reverse operations in **opposite order** of upgrade.

```python
# BAD
def downgrade() -> None:
    pass

# GOOD
def upgrade() -> None:
    op.add_column("users", sa.Column("phone", sa.String(20), nullable=True))
    op.create_index("ix_users_phone", "users", ["phone"])

def downgrade() -> None:
    op.drop_index("ix_users_phone", table_name="users")
    op.drop_column("users", "phone")
```

## Data Migrations — Never Import App Models

Models change over time; a migration must reflect the schema *at its revision*.
Use inline `table()`/`column()` definitions or raw SQL.

```python
# BAD: breaks when the User model changes later
from myapp.models import User

def upgrade() -> None:
    users = User.query.all()

# GOOD: inline table definition, decoupled from the app model
from sqlalchemy import table, column, String, func

def upgrade() -> None:
    user_table = table("users", column("id"), column("email", String))
    conn = op.get_bind()
    conn.execute(user_table.update().values(email=func.lower(user_table.c.email)))

# GOOD: raw SQL
def upgrade() -> None:
    op.execute("UPDATE users SET email = LOWER(email) WHERE email IS NOT NULL")
```

### Batch Large Backfills

```python
# BAD: single UPDATE on millions of rows — long table lock
op.execute("UPDATE orders SET status = 'active' WHERE status IS NULL")

# GOOD: bounded batches release locks between iterations
def upgrade() -> None:
    conn = op.get_bind()
    while True:
        result = conn.execute(sa.text(
            "UPDATE orders SET status = 'active' "
            "WHERE id IN (SELECT id FROM orders WHERE status IS NULL LIMIT 1000)"
        ))
        if result.rowcount == 0:
            break
```

## Separate Schema and Data Migrations

Never mix DDL and DML in the same revision — a failed backfill should not strand
half-applied schema changes.

```bash
alembic revision --autogenerate -m "add_status_column_to_orders"
alembic revision -m "backfill_status_column_on_orders"
```

## Add Non-Nullable Column — Three Steps

```python
# GOOD: add nullable -> backfill -> constrain
def upgrade() -> None:
    op.add_column("users", sa.Column("role", sa.String(20), nullable=True))
    op.execute("UPDATE users SET role = 'member' WHERE role IS NULL")
    op.alter_column("users", "role", nullable=False)

def downgrade() -> None:
    op.drop_column("users", "role")
```

## Online DDL and Lock Safety

```python
# GOOD: concurrent index — does not block writes (PostgreSQL)
def upgrade() -> None:
    op.execute("CREATE INDEX CONCURRENTLY ix_orders_user_id ON orders (user_id)")
```

`CREATE INDEX CONCURRENTLY` cannot run inside a transaction — disable the
per-migration transaction:

```python
# at module scope in the revision file
def upgrade() -> None: ...

# tell Alembic not to wrap this revision in a transaction
disable_transaction = True  # alembic 1.18: transactional=False on the revision
```

Set a lock timeout so a blocked migration aborts instead of stalling the app:

```python
def upgrade() -> None:
    op.execute("SET lock_timeout = '5s'")
    op.add_column("users", sa.Column("nickname", sa.String(50), nullable=True))
```

Add foreign keys in two steps to avoid a full-table validation under an
exclusive lock:

```python
# GOOD: NOT VALID first, then validate without blocking writes
def upgrade() -> None:
    op.create_foreign_key(
        "fk_orders_customer_id_customers", "orders", "customers",
        ["customer_id"], ["id"], postgresql_not_valid=True,
    )
    op.execute("ALTER TABLE orders VALIDATE CONSTRAINT fk_orders_customer_id_customers")
```

## Batch Operations for SQLite

SQLite cannot `ALTER` most columns. `batch_alter_table` rebuilds the table:

```python
# GOOD: works on SQLite and Postgres alike
def upgrade() -> None:
    with op.batch_alter_table("users") as batch:
        batch.alter_column("email", nullable=False)
```

## Branching and Merging Revisions

Two developers branching from the same head produces diverged heads.

```bash
# inspect
alembic heads
alembic branches

# merge into a single head — the merge revision has two down_revisions
alembic merge -m "merge_heads" head1 head2

# adopt Alembic on an existing DB without running migrations
alembic stamp head
```

## Testing

```python
# GOOD: stairway test — every revision upgrades, downgrades, and upgrades again
from alembic import command
from alembic.script import ScriptDirectory

def test_stairway(alembic_config) -> None:
    script = ScriptDirectory.from_config(alembic_config)
    revisions = list(script.walk_revisions("base", "heads"))
    revisions.reverse()
    for revision in revisions:
        command.upgrade(alembic_config, revision.revision)
        command.downgrade(alembic_config, revision.down_revision or "base")
        command.upgrade(alembic_config, revision.revision)
```

```bash
# CI: fail the build if models drifted from migrations
alembic check
```

## Deployment

```yaml
# Docker Compose: run migrations as a separate step before the app starts
app_migrations:
  command: ["alembic", "upgrade", "head"]
  depends_on:
    db: { condition: service_healthy }
app:
  depends_on:
    app_migrations: { condition: service_completed_successfully }
```

Never run `alembic upgrade head` from inside the app's startup hook — concurrent
workers would race on the same migration.

## Rules

1. Define naming conventions on `MetaData` — predictable, downgrade-safe names.
2. Use a timestamp `file_template` and always pass a descriptive `-m` message.
3. Review every autogenerated migration — it misses renames, enums, CHECKs.
4. Enable `compare_type` and `compare_server_default` in `env.py`.
5. Fix renames manually — autogenerate renders them as drop + create (data loss).
6. Use an async `env.py` (`async_engine_from_config` + `run_sync`) for async engines; `NullPool` for migrations.
7. Write complete downgrades — reverse every operation in opposite order.
8. Never import app models in migrations — use `table()`/`column()` or raw SQL.
9. Separate schema and data migrations — never mix DDL and DML.
10. Three-step non-nullable columns; batch large backfills to avoid long locks.
11. `CREATE INDEX CONCURRENTLY` and `ADD CONSTRAINT NOT VALID` for online DDL; set `lock_timeout`.
12. Run stairway tests and `alembic check` in CI; apply migrations as a deploy step, not at app startup.
