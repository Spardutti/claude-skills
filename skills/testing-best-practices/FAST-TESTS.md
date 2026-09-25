# Tests That Stay Fast

A slow suite is rarely slow tests. It is setup every test inherits: fixtures that **queue on each other's locks** once workers run side by side — mutmut's children, xdist's `-n`, Vitest threads — or that **pay a production cost on every test**, like a full-strength password hash or a cloud client waiting on the network. Mutation testing multiplies whatever each test pays by every mutant.

## Contents

- [A Rolled-Back Test Still Holds Its Locks](#a-rolled-back-test-still-holds-its-locks)
- [Unique Values In Unique Columns](#unique-values-in-unique-columns)
- [Never Delete Or Truncate A Whole Table At Test Start](#never-delete-or-truncate-a-whole-table-at-test-start)
- [Hash Test Passwords With The Cheapest Settings](#hash-test-passwords-with-the-cheapest-settings)
- [Stop Cloud Clients Probing The Network](#stop-cloud-clients-probing-the-network)
- [Measure Before Fixing](#measure-before-fixing)
- [Rules](#rules)

## A Rolled-Back Test Still Holds Its Locks

Rollback makes a test's writes vanish afterwards. Until then, every row it inserted, updated or deleted stays locked, and another worker that touches the same row — or the same value in a unique index — waits for the whole test to end. With 8 workers, one shared value turns 8 lanes into 1.

## Unique Values In Unique Columns

```python
# BAD — every test inserts the same email; workers queue on the unique index
@pytest.fixture
async def user_id(session):
    return await make_user(session, "test@example.com")

# GOOD — a value no other running test can hold
@pytest.fixture
async def user_id(session):
    return await make_user(session, f"test-{uuid4()}@example.com")
```

The same goes for slugs, usernames, codes and any column behind a `UNIQUE` constraint. A test that asserts on the value reads it back from the fixture rather than repeating the literal.

## Never Delete Or Truncate A Whole Table At Test Start

A fixture that "starts clean" with `DELETE FROM users` locks every row already in the table — on a development database, that is real data — so every other worker's `DELETE` waits.

```python
# BAD — each test locks every existing row until it rolls back
await connection.execute(text("DELETE FROM audit_log"))

# BAD — cheaper per test, and worse: TRUNCATE takes a lock on the whole table
await connection.execute(text("TRUNCATE audit_log"))
```

Give the tests a database with nothing in it instead. Either works; neither changes a test:

```bash
# GOOD — one empty, migrated <db>_test the suite points at before it starts
export DATABASE_URL="${DATABASE_URL}_test"
python -m tests.prepare_database   # create if missing, run migrations, stop if it fails
```

```python
# GOOD — one database per xdist worker, created and migrated at session start
def _test_db_name() -> str:
    return f"app_test_{os.environ.get('PYTEST_XDIST_WORKER', 'master')}"
```

The per-worker form only helps xdist: mutmut's children set no worker id, so under mutation testing they share one database and need the empty one.

## Hash Test Passwords With The Cheapest Settings

Argon2 and bcrypt are slow on purpose. A fixture that hashes the test password at production strength charges that cost on **every login in every test** — on one API it was 15 of 54 seconds, and mutation testing multiplies it by every mutant.

Verification reads the cost from the stored hash, so a cheap hash still runs the real algorithm through the real code path. Production keeps its settings; only the fixture changes.

```python
# BAD — every login in every test pays the production cost
PASSWORD_HASH = PasswordHash.recommended().hash(TEST_PASSWORD)

# GOOD — the same Argon2 check, with the lowest cost it accepts
PASSWORD_HASH = PasswordHash(
    (Argon2Hasher(time_cost=1, memory_cost=8, parallelism=1),)
).hash(TEST_PASSWORD)
```

```python
# GOOD — bcrypt at its minimum of 4 rounds, for every hash made during tests
_gensalt = bcrypt.gensalt
bcrypt.gensalt = lambda rounds=4, prefix=b"2b": _gensalt(rounds=4, prefix=prefix)

# GOOD — Django: a fast hasher in the test settings only
PASSWORD_HASHERS = ["django.contrib.auth.hashers.MD5PasswordHasher"]
```

```ts
// GOOD — bcrypt's minimum in the test fixture
const passwordHash = await bcrypt.hash(TEST_PASSWORD, 4);
```

Prefer the form that covers every hash the tests make (the bcrypt patch, Django's setting) over one that covers only the fixture: a test that registers a user through the API hashes too.

Set it where every test runner reads it, not inside one runner:

```python
# BAD — only `manage.py test` runs this; pytest and mutmut keep the slow hasher
class ProjectTestRunner(DiscoverRunner):
    def setup_test_environment(self, **kwargs):
        settings.PASSWORD_HASHERS = ["django.contrib.auth.hashers.MD5PasswordHasher"]

# GOOD — api/conftest.py, loaded by pytest and by mutmut through pytest
def pytest_configure():
    settings.PASSWORD_HASHERS = ["django.contrib.auth.hashers.MD5PasswordHasher"]
```

On one API this took a mutation run from 870s to 186s. Keep the runner line too if `manage.py test` is still used.

## Stop Cloud Clients Probing The Network

A cloud SDK with no credentials goes looking for them. boto3 asks the EC2 metadata server at `169.254.169.254`, which only answers on AWS, so on a laptop or a CI runner it waits out two 1-second timeouts. An app that builds its client at import pays that every time a process loads it — once per test run, and once more for every process mutation testing starts.

```python
# BAD — a region but no credentials: boto3 probes the metadata server at import
os.environ.setdefault("AWS_REGION", "us-east-1")

# GOOD — the probe is off; fake keys cover what the client needs to build
os.environ.setdefault("AWS_REGION", "us-east-1")
os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
```

Set these in `conftest.py` before the app is imported. On one API it took importing the app from 2.28s to 0.55s and the suite from 2.87s to 0.83s.

## Measure Before Fixing

A queue and a hot CPU look alike from outside — the suite is just slow. Look before changing anything:

```sql
-- what each connection is waiting on, during a parallel run
SELECT wait_event, left(query, 60), count(*)
FROM pg_stat_activity WHERE state <> 'idle' GROUP BY 1, 2 ORDER BY 3 DESC;
```

```bash
docker stats --no-stream                                   # CPU per container
python -m cProfile -s tottime -m pytest -q | head -30      # where one run's time goes
```

Fix the limit the numbers show. Removing a lock does nothing while the CPUs are full; once a cheaper hash frees them, the same lock becomes the limit. One API: the empty test database alone gained nothing, the cheap hash took 943s to 557s, and the empty database on top took it to 439s.

## Rules

- Always insert a fresh value into every unique column in a fixture.
- Never `DELETE FROM` or `TRUNCATE` a whole table to reset a test; give the suite an empty database.
- Always hash test passwords with the algorithm's cheapest settings, in test setup only.
- Always switch off cloud SDK credential probes in test setup.
- Always measure — wait events, CPU, a profile — before changing a test fixture for speed.
- Never make tests faster by running fewer of them or asserting less.
