---
name: fastapi
category: Backend
description: "MUST USE when creating or editing FastAPI routes, async path operations, dependency injection, app lifespan/startup, middleware, or API configuration; or when working on Pydantic models and validators, SQLAlchemy/Alembic database migrations, or Celery background tasks and queues. Enforces async correctness, Annotated dependencies, yield-dependency cleanup, service layers, response models, and structured error handling."
---

# FastAPI — Endpoints, Dependencies, Async

Modern FastAPI application patterns: routing, async correctness, dependency injection, app lifecycle, and error handling. Baseline is FastAPI 0.136 + Pydantic 2.13 + Python 3.12 (3.10 is the floor). FastAPI is still 0.x — pin the exact version in production.

## Quick Reference — When to Load What

| Working on… | Read |
|---|---|
| Pydantic models, validators, settings, serialization, v1→v2 migration | PYDANTIC.md |
| Database migrations, Alembic autogenerate, async migrations | ALEMBIC.md |
| Background jobs, Celery tasks, queues, retries, beat schedules | CELERY.md |
| List endpoints — pagination, filtering, search, sorting, response envelope | LISTING.md |

## Project Structure

Organize by domain. Each domain owns its routes, schemas, models, and services.

```
src/
├── <domain>/      # one folder per domain (auth, posts, …)
│   router.py  schemas.py  models.py  service.py  dependencies.py  exceptions.py
├── config.py
├── database.py
└── main.py
```

Each domain exposes an `APIRouter(prefix="/posts", tags=["posts"])`; `main.py` mounts them with `app.include_router(posts_router)`.

## Package Management — uv

Use **uv** (Astral) — the 2026 standard for Python projects, replacing pip, pipenv, poetry, virtualenv, and pyenv.

```bash
uv add fastapi "uvicorn[standard]" sqlalchemy asyncpg pydantic-settings
uv add --dev pytest pytest-asyncio httpx ruff mypy
uv run uvicorn src.main:app --reload   # any command runs in the managed venv
```

Commit **both** `pyproject.toml` and `uv.lock` — the lock pins every transitive version, so every environment is identical. Reproduce one with `uv sync --frozen`; in Docker, `RUN uv sync --frozen --no-cache`.

## Critical Gotchas (Always-Inline)

### 1. `async def` + Blocking Call Freezes Every Request

```python
# BAD: blocks the whole event loop — all concurrent requests stall
@router.get("/report")
async def bad_report():
    time.sleep(5)            # blocking; also: requests.get(), sync DB driver
    return data

# GOOD: sync def — FastAPI runs it in the threadpool
@router.get("/report")
def good_report_sync():
    time.sleep(5)
    return data

# GOOD: async def only with await-able I/O
@router.get("/report")
async def good_report_async():
    await asyncio.sleep(5)   # async DB, httpx.AsyncClient, aiofiles
    return data
```

- `async def`: only with `await`-able I/O (async SQLAlchemy/asyncpg, `httpx.AsyncClient`, aiofiles).
- `def`: blocking I/O (sync DB, `requests`, file I/O, CPU-bound) — FastAPI offloads it.

### 2. Wrap Unavoidable Sync SDKs With `anyio.to_thread.run_sync`

```python
import anyio

# BAD: loop.run_in_executor — outdated; FastAPI itself is built on anyio
result = await asyncio.get_event_loop().run_in_executor(None, sync_sdk.call, arg)

# GOOD: anyio.to_thread.run_sync — the modern offload
@router.get("/charge")
async def charge(amount: int):
    return await anyio.to_thread.run_sync(stripe_sdk.charge, amount)
```

### 3. App Lifecycle Uses `lifespan` — Not `@app.on_event`

`@app.on_event("startup"/"shutdown")` is deprecated. Use an `@asynccontextmanager`. If `lifespan` is set, any `on_event` handler is ignored entirely.

```python
from contextlib import asynccontextmanager

# GOOD: process/worker-scoped resources — one set per uvicorn worker
@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.db_engine = create_async_engine(settings.database_url)
    app.state.redis = await aioredis.from_url(settings.redis_url)
    yield  # app serves requests here
    await app.state.redis.aclose()
    await app.state.db_engine.dispose()

app = FastAPI(lifespan=lifespan)
```

Long-lived clients (DB engine, Redis pool, shared `httpx` client) belong in `lifespan`. Per-request resources (DB *session*, current user, transaction) belong in `Depends` — not here.

### 4. `Annotated[T, Depends()]` — Define Reusable Aliases

```python
# GOOD: declare once, reuse across every route
CurrentUser = Annotated[User, Depends(get_current_active_user)]
DBSession = Annotated[AsyncSession, Depends(get_db)]

@router.get("/me", response_model=UserRead)
async def read_me(current_user: CurrentUser):
    return current_user
```

### 5. Yield Dependencies for Per-Request Cleanup

Code after `yield` runs even if the request raised — the session closes, the transaction rolls back.

```python
from collections.abc import AsyncIterator

# GOOD: session opened per request, closed automatically
async def get_db(request: Request) -> AsyncIterator[AsyncSession]:
    factory = async_sessionmaker(request.app.state.db_engine, expire_on_commit=False)
    async with factory() as session:
        yield session            # rollback + close happen on exit, even on error

DBSession = Annotated[AsyncSession, Depends(get_db)]
```

A dependency requested by multiple sub-dependencies is computed **once per request** (request-scoped cache). Pass `Depends(fn, use_cache=False)` only when you genuinely need a fresh instance.

### 6. Chain Dependencies for Validation and Authorization

```python
async def valid_post_id(post_id: int, db: DBSession) -> Post:
    post = await post_service.get_by_id(db, post_id)
    if not post:
        raise PostNotFound()
    return post

async def valid_owned_post(
    post: Annotated[Post, Depends(valid_post_id)],
    current_user: CurrentUser,
) -> Post:
    if post.author_id != current_user.id:
        raise HTTPException(status_code=403, detail="Not the post owner")
    return post

@router.put("/posts/{post_id}", response_model=PostRead)
async def update_post(
    post: Annotated[Post, Depends(valid_owned_post)],
    data: PostUpdate,
    db: DBSession,
):
    return await post_service.update(db, post, data)
```

Apply cross-cutting auth at the router: `APIRouter(prefix="/admin", dependencies=[Depends(require_admin)])`.

### 7. Always Set `response_model` — Never Leak ORM Fields

```python
# BAD: returns the ORM object directly — leaks hashed_password, internal columns
@router.get("/users/{user_id}")
async def get_user(user_id: int, db: DBSession):
    return await db.get(User, user_id)

# GOOD: response_model filters output to a Read schema
@router.get("/users/{user_id}", response_model=UserRead, status_code=status.HTTP_200_OK)
async def get_user(user_id: int, db: DBSession):
    return await user_service.get_by_id(db, user_id)
```

Set an explicit `status_code` (e.g. `status.HTTP_201_CREATED` on create). Trim output with `response_model_exclude_none` / `response_model_exclude_unset`. Schema design lives in PYDANTIC.md.

### 8. Service Layer — Keep Routes Thin

```python
# BAD: business logic in the route
@router.post("/orders", response_model=OrderRead)
async def create_order(data: OrderCreate, db: DBSession, user: CurrentUser):
    for item in data.items:
        product = await db.get(Product, item.product_id)
        if product.stock < item.quantity:
            raise HTTPException(status_code=400, detail="Out of stock")
        product.stock -= item.quantity
    db.add(Order(user_id=user.id, **data.model_dump()))
    await db.commit()

# GOOD: route handles HTTP only, delegates logic to the service
@router.post("/orders", response_model=OrderRead, status_code=status.HTTP_201_CREATED)
async def create_order(data: OrderCreate, db: DBSession, user: CurrentUser):
    return await order_service.create_order(db, user=user, data=data)
```

### 9. `HTTPException` for Expected Errors — Handlers Never Leak Internals

```python
# Custom exceptions per domain — raised from services, mapped to HTTP
class PostNotFound(HTTPException):
    def __init__(self) -> None:
        super().__init__(status_code=status.HTTP_404_NOT_FOUND, detail="Post not found")

# Catch-all: log the real error, return a generic 500 — never the traceback
@app.exception_handler(Exception)
async def generic_handler(request: Request, exc: Exception) -> JSONResponse:
    logger.exception("Unhandled error", exc_info=exc)
    return JSONResponse(status_code=500, content={"detail": "Internal server error"})
```

Register `@app.exception_handler(MyDomainError)` for domain types; override `RequestValidationError` for a custom 422 shape.

### 10. Settings via `pydantic-settings` — Never Hardcode Secrets

```python
from pydantic import SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict

class Settings(BaseSettings):
    database_url: str
    jwt_secret: SecretStr           # masked in repr / logs / model_dump
    jwt_algorithm: str = "HS256"
    debug: bool = False
    model_config = SettingsConfigDict(env_file=".env")

@lru_cache
def get_settings() -> Settings:
    return Settings()

AppSettings = Annotated[Settings, Depends(get_settings)]
```

`BaseSettings` lives in the separate `pydantic-settings` package — not in `pydantic`.

### 11. Explicit CORS Origins — Never `"*"` With Credentials

```python
# BAD: browsers reject wildcard + credentials anyway
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_credentials=True)

# GOOD: explicit origin list
app.add_middleware(
    CORSMiddleware,
    allow_origins=["https://app.example.com"],
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "DELETE"],
    allow_headers=["Authorization", "Content-Type"],
)
```

## Authentication

```python
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/auth/token")

async def get_current_user(
    token: Annotated[str, Depends(oauth2_scheme)], db: DBSession,
) -> User:
    creds_error = HTTPException(
        status_code=401, detail="Could not validate credentials",
        headers={"WWW-Authenticate": "Bearer"},
    )
    try:
        payload = jwt.decode(token, settings.jwt_secret.get_secret_value(),
                             algorithms=[settings.jwt_algorithm])
    except jwt.InvalidTokenError:
        raise creds_error
    user = await user_service.get_by_id(db, payload.get("sub"))
    if user is None:
        raise creds_error
    return user
```

Hash passwords with `pwdlib`/`argon2` (passlib+bcrypt is aging). `get_current_active_user` chains on `get_current_user` to also check `is_active`.

## Testing

FastAPI's DI system is built for testing — `app.dependency_overrides` swaps real dependencies (DB, auth) for test doubles. Override the *dependency function*, not the code inside it.

```python
import pytest
from httpx import AsyncClient, ASGITransport

@pytest.fixture
async def db_session(test_engine):  # transactional — rolls back after each test
    factory = async_sessionmaker(test_engine, expire_on_commit=False)
    async with factory() as session:
        yield session
        await session.rollback()

@pytest.fixture
async def client(db_session) -> AsyncIterator[AsyncClient]:
    app.dependency_overrides[get_db] = lambda: db_session
    app.dependency_overrides[get_current_user] = lambda: User(id=1, email="t@t.io")
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as c:
        yield c
    app.dependency_overrides.clear()  # never leak overrides between tests

async def test_get_user(client: AsyncClient):
    resp = await client.get("/users/1")
    assert resp.status_code == 200
```

Use `ASGITransport` + `AsyncClient` for `async def` routes (the sync `TestClient` spins its own loop and fights async fixtures). Always `clear()` overrides in fixture teardown. Test the service layer directly with plain unit tests — no HTTP needed.

## BackgroundTasks vs Celery

| Need | Use |
|---|---|
| Fast fire-and-forget after the response (email, audit log, cache bust) | `BackgroundTasks` |
| Heavy/long work, retries, status/result, scheduled jobs, fan-out | Celery — see CELERY.md |

`BackgroundTasks` (`background_tasks.add_task(fn, arg)`) has no retries, no result, and dies with the API process — and a blocking call in an `async def` task still stalls the loop. Anything beyond fire-and-forget needs Celery; the migration is mechanical (see CELERY.md).

## Rules

1. **Organize by domain** — each feature owns its router, schemas, models, service, exceptions. Manage dependencies with **uv**; commit `uv.lock`.
2. **Never block the event loop** — `def` for sync I/O, `async def` only with `await`-able calls.
3. **Wrap sync SDKs** with `anyio.to_thread.run_sync` — not `loop.run_in_executor`.
4. **Use `lifespan`** for process-scoped resources — never the deprecated `@app.on_event`.
5. **Use `Annotated[T, Depends()]`** with reusable type aliases — never bare `Depends()` defaults.
6. **Yield dependencies** for per-request cleanup (DB session, transaction) — never `lifespan`.
7. **Chain dependencies** for validation and authorization — keep routes thin.
8. **Set `response_model`** and an explicit `status_code` on every route — never return ORM objects.
9. **Service layer** for business logic — routes handle only HTTP concerns.
10. **Custom exceptions per domain**; a catch-all handler logs and returns a generic 500.
11. **`pydantic-settings` + `lru_cache`** for config; `SecretStr` for secrets — never hardcode.
12. **Explicit CORS origins** — never `"*"` with `allow_credentials=True`.
13. **Test with `app.dependency_overrides`** — swap DB/auth deps, `ASGITransport` for async routes, clear overrides in teardown.

## Reference Files

For deeper guidance, load the file matching what you're working on:

- **PYDANTIC.md** — read when defining or editing Pydantic models, validators, or settings. Covers `ConfigDict` (no inner `class Config`), `from_attributes` for ORM, `@field_validator` / `@model_validator` modes, `Annotated` reusable types, Create/Update/Read schema separation, `exclude_unset` for PATCH, discriminated unions, `computed_field`, `default_factory`, strict mode at trust boundaries, `TypeAdapter`, `SecretStr`, serialization/perf, and the full Pydantic v1→v2 migration gotcha checklist.
- **ALEMBIC.md** — read when creating or running database migrations. Covers `MetaData` naming conventions, timestamped file templates, autogenerate review and the rename = drop+add data-loss trap, the 3-step non-nullable column pattern, complete downgrades, no-app-models data migrations, batched backfills, `CREATE INDEX CONCURRENTLY`, async `env.py` (`async_engine_from_config` + `run_sync`), branch/merge of diverged heads, the stairway test, and deployment ordering.
- **CELERY.md** — read when writing background jobs, task queues, or scheduled work. Covers explicit task names, passing IDs not ORM objects, idempotency with `acks_late`, narrow `autoretry_for` + backoff + jitter, soft/hard time limits, no `.get()` inside a task, canvas (`chain`/`group`/`chord`), queue routing and priorities, result-backend hygiene, `beat` scheduling, observability signals, eager-mode testing, and the FastAPI integration pattern (`task.delay` from routes, polling `AsyncResult`).
- **LISTING.md** — read when building any endpoint that returns a collection. Covers the generic `Page[T]` response envelope (never ship a bare array), offset vs cursor pagination and when to use each, typed filter params as a Pydantic dependency, `ILIKE` vs Postgres full-text search, the sort allow-list (never `getattr` a client field), one composed list-query `Depends`, and total-count cost.
