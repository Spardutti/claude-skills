---
name: fastapi-best-practices
description: "MUST USE when creating or editing FastAPI routes, dependencies, Pydantic schemas, middleware, or API configuration. Enforces async correctness, dependency injection, service layer, Pydantic validation, and structured error handling."
---

# FastAPI Best Practices

Use async correctly, validate everything with Pydantic, keep routes thin with dependency injection, and push business logic into services.

## Project Structure

Organize by domain, not by file type. Each domain package owns its routes, schemas, models, and services.

```
src/
├── auth/
│   ├── router.py
│   ├── schemas.py
│   ├── models.py
│   ├── service.py
│   ├── dependencies.py
│   └── exceptions.py
├── posts/
│   ├── router.py
│   ├── schemas.py
│   ├── models.py
│   ├── service.py
│   ├── dependencies.py
│   └── exceptions.py
├── config.py
├── exceptions.py
├── database.py
└── main.py
```

### Use Explicit Imports Across Domains

```python
# BAD: ambiguous — which "service"?
from src.auth.service import create_user
from src.posts.service import create_post

# GOOD: namespace is clear
from src.auth import service as auth_service
from src.posts import service as post_service

auth_service.create_user(data)
post_service.create_post(data)
```

## Async Correctness

### Never Block the Event Loop

`async def` routes run on the main event loop. Blocking calls freeze the entire server.

```python
import asyncio
import time

# BAD: blocks the event loop — all other requests stall
@router.get("/sleep")
async def bad_sleep():
    time.sleep(10)
    return {"msg": "done"}

# GOOD (option 1): sync def — FastAPI offloads to threadpool automatically
@router.get("/sleep")
def good_sleep_sync():
    time.sleep(10)
    return {"msg": "done"}

# GOOD (option 2): async with non-blocking I/O
@router.get("/sleep")
async def good_sleep_async():
    await asyncio.sleep(10)
    return {"msg": "done"}
```

### When to Use `async def` vs `def`

| Use `async def` | Use `def` |
|------------------|-----------|
| `await`-able I/O (async DB drivers, httpx, aiofiles) | Blocking I/O (sync DB drivers, `requests`, file I/O) |
| Non-blocking operations | CPU-bound work (offloaded to threadpool) |

### Wrap Sync SDKs in `run_in_executor`

```python
import asyncio
from functools import partial

# BAD: blocking call in async route
@router.get("/external")
async def bad_external():
    result = sync_sdk.call()  # blocks event loop
    return result

# GOOD: offload to threadpool
@router.get("/external")
async def good_external():
    loop = asyncio.get_event_loop()
    result = await loop.run_in_executor(None, partial(sync_sdk.call))
    return result
```

## Pydantic Schemas

### Separate Schemas for Input, Output, and Internal Use

```python
# BAD: one model for everything
class User(BaseModel):
    id: int
    email: str
    hashed_password: str  # leaked to API response!

# GOOD: separate schemas per operation
class UserCreate(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8, max_length=128)

class UserRead(BaseModel):
    id: int
    email: EmailStr
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)

class UserInDB(BaseModel):
    id: int
    email: str
    hashed_password: str
```

### Leverage Built-In Validators

```python
from pydantic import BaseModel, EmailStr, Field, AnyHttpUrl

class CreateAccount(BaseModel):
    email: EmailStr
    username: str = Field(min_length=3, max_length=64, pattern=r"^[a-zA-Z0-9_-]+$")
    age: int = Field(ge=18, le=120)
    website: AnyHttpUrl | None = None
```

### Use `response_model` to Control Output

```python
# BAD: returns whatever the function returns — may leak fields
@router.get("/users/{user_id}")
async def get_user(user_id: int):
    return await user_service.get_by_id(user_id)

# GOOD: response_model strips extra fields
@router.get("/users/{user_id}", response_model=UserRead)
async def get_user(user_id: int):
    return await user_service.get_by_id(user_id)
```

## Dependency Injection

### Use `Annotated` + `Depends` for All Dependencies

```python
from typing import Annotated
from fastapi import Depends

# Define reusable type aliases
CurrentUser = Annotated[User, Depends(get_current_active_user)]
DBSession = Annotated[AsyncSession, Depends(get_db)]

@router.get("/me", response_model=UserRead)
async def read_me(current_user: CurrentUser):
    return current_user

@router.get("/posts", response_model=list[PostRead])
async def list_posts(db: DBSession, current_user: CurrentUser):
    return await post_service.get_user_posts(db, current_user.id)
```

### Chain Dependencies for Validation

```python
# Dependency validates resource exists
async def valid_post_id(post_id: int, db: DBSession) -> Post:
    post = await post_service.get_by_id(db, post_id)
    if not post:
        raise PostNotFound()
    return post

# Dependency chains: validates ownership
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

Dependencies are cached per-request by default — the same dependency used multiple times in a chain executes only once.

## Service Layer

### Keep Routes Thin — Business Logic in Services

```python
# BAD: business logic in route
@router.post("/orders", response_model=OrderRead)
async def create_order(data: OrderCreate, db: DBSession, user: CurrentUser):
    for item in data.items:
        product = await db.get(Product, item.product_id)
        if product.stock < item.quantity:
            raise HTTPException(status_code=400, detail="Out of stock")
        product.stock -= item.quantity
    order = Order(user_id=user.id, **data.model_dump())
    db.add(order)
    await db.commit()
    await send_confirmation_email(order)
    return order

# GOOD: route delegates to service
@router.post("/orders", response_model=OrderRead, status_code=201)
async def create_order(data: OrderCreate, db: DBSession, user: CurrentUser):
    return await order_service.create_order(db, user=user, data=data)
```

```python
# services/order_service.py
class OrderService:
    async def create_order(self, db: AsyncSession, user: User, data: OrderCreate) -> Order:
        async with db.begin():
            for item in data.items:
                product = await db.get(Product, item.product_id, with_for_update=True)
                if product.stock < item.quantity:
                    raise InsufficientStockError(product.name)
                product.stock -= item.quantity
            order = Order(user_id=user.id, **data.model_dump())
            db.add(order)
        await send_confirmation_email(order)
        return order

order_service = OrderService()
```

## Error Handling

### Custom Exceptions Per Domain

```python
# src/posts/exceptions.py
from fastapi import HTTPException, status

class PostNotFound(HTTPException):
    def __init__(self):
        super().__init__(status_code=status.HTTP_404_NOT_FOUND, detail="Post not found")

class PostPermissionDenied(HTTPException):
    def __init__(self):
        super().__init__(status_code=status.HTTP_403_FORBIDDEN, detail="Not the post owner")
```

### Never Leak Internal Details

```python
# BAD: leaks stack trace / internal info
@app.exception_handler(Exception)
async def generic_handler(request, exc):
    return JSONResponse(status_code=500, content={"detail": str(exc)})

# GOOD: generic message, log the real error
@app.exception_handler(Exception)
async def generic_handler(request, exc):
    logger.exception("Unhandled error", exc_info=exc)
    return JSONResponse(status_code=500, content={"detail": "Internal server error"})
```

## Configuration

### Use Pydantic `BaseSettings` with Dependency Injection

```python
# src/config.py
from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    database_url: str
    jwt_secret: str
    jwt_algorithm: str = "HS256"
    jwt_expire_minutes: int = 30
    debug: bool = False

    model_config = SettingsConfigDict(env_file=".env")
```

```python
# src/main.py
from functools import lru_cache
from typing import Annotated
from fastapi import Depends

@lru_cache
def get_settings():
    return Settings()

AppSettings = Annotated[Settings, Depends(get_settings)]
```

Never hardcode secrets. Always load from environment variables via `BaseSettings`.

## CORS and Middleware

### Explicit Origins — Never Use `"*"` with Credentials

```python
from fastapi.middleware.cors import CORSMiddleware

# BAD: wildcard with credentials — browsers reject this
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
)

# GOOD: explicit allowed origins
app.add_middleware(
    CORSMiddleware,
    allow_origins=["https://app.example.com", "https://admin.example.com"],
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "DELETE"],
    allow_headers=["Authorization", "Content-Type"],
)
```

## Authentication

### OAuth2 + JWT with Dependency Chain

```python
from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/auth/token")

async def get_current_user(
    token: Annotated[str, Depends(oauth2_scheme)],
    db: DBSession,
) -> User:
    try:
        payload = jwt.decode(token, settings.jwt_secret, algorithms=[settings.jwt_algorithm])
        user_id: int = payload.get("sub")
        if user_id is None:
            raise HTTPException(status_code=401, detail="Invalid token")
    except jwt.InvalidTokenError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Could not validate credentials",
            headers={"WWW-Authenticate": "Bearer"},
        )
    user = await user_service.get_by_id(db, user_id)
    if user is None:
        raise HTTPException(status_code=401, detail="User not found")
    return user

async def get_current_active_user(
    current_user: Annotated[User, Depends(get_current_user)],
) -> User:
    if current_user.disabled:
        raise HTTPException(status_code=400, detail="Inactive user")
    return current_user
```

## Testing

### Use `TestClient` and Override Dependencies

```python
from fastapi.testclient import TestClient

def get_settings_override():
    return Settings(database_url="sqlite:///test.db", jwt_secret="test-secret")

app.dependency_overrides[get_settings] = get_settings_override

client = TestClient(app)

def test_create_post():
    response = client.post("/posts", json={"title": "Test", "body": "Content"}, headers={"Authorization": "Bearer test-token"})
    assert response.status_code == 201
    assert response.json()["title"] == "Test"
```

Use `dependency_overrides` to swap real services for fakes/mocks in tests.

## API Versioning

### Prefix Routes with API Version

```python
from fastapi import APIRouter

v1_router = APIRouter(prefix="/api/v1")
v1_router.include_router(auth_router, prefix="/auth", tags=["auth"])
v1_router.include_router(posts_router, prefix="/posts", tags=["posts"])

app.include_router(v1_router)
```

## Rules Summary

1. **Organize by domain** — each feature owns its routes, schemas, models, services, and exceptions
2. **Never block the event loop** — use `def` for sync I/O, `async def` only with `await`-able calls
3. **Separate schemas** for create, read, and internal use — never expose `hashed_password` or internal fields
4. **Use `response_model`** on every route — control exactly what the API returns
5. **Use `Annotated[T, Depends()]`** for all dependencies — create reusable type aliases
6. **Chain dependencies** for resource validation and authorization — keep routes thin
7. **Service layer** for business logic — routes only handle HTTP concerns
8. **Custom exceptions per domain** — never leak internal error details
9. **`BaseSettings` + `lru_cache`** for configuration — never hardcode secrets
10. **Explicit CORS origins** — never use `"*"` with `allow_credentials=True`
11. **Leverage Pydantic validators** — `EmailStr`, `Field(min_length=...)`, `pattern` instead of manual checks
12. **Override dependencies in tests** — use `dependency_overrides` to swap services for fakes
