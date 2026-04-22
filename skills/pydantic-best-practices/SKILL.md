---
name: pydantic-best-practices
category: Backend
description: "MUST USE when writing or editing Pydantic v2 models, validators, settings, or serialization logic. Enforces model_config, field/model validators, Annotated types, discriminated unions, computed_field, strict mode, and TypeAdapter usage."
---

# Pydantic v2 Best Practices

## Model Configuration

```python
# BAD: Pydantic v1 style — deprecated in v2
class User(BaseModel):
    class Config:
        str_strip_whitespace = True
        frozen = True

# GOOD: v2 uses model_config as a class attribute
from pydantic import BaseModel, ConfigDict

class User(BaseModel):
    model_config = ConfigDict(
        str_strip_whitespace=True,
        frozen=True,
        extra="forbid",          # reject unknown fields
        from_attributes=True,    # for ORM objects (replaces orm_mode)
    )
```

## Field Validators

```python
# BAD: raw method without decorator — silently does nothing
class User(BaseModel):
    email: str
    def validate_email(self, v):
        return v.lower()

# BAD: v1-style @validator — deprecated
class User(BaseModel):
    email: str
    @validator("email")
    def lower_email(cls, v):
        return v.lower()

# GOOD: v2 @field_validator with explicit mode
from pydantic import field_validator

class User(BaseModel):
    email: str

    @field_validator("email", mode="after")
    @classmethod
    def lower_email(cls, v: str) -> str:
        return v.lower()
```

- `mode="before"` — runs before type coercion (raw input)
- `mode="after"` — runs after coercion (the default, preferred)
- `mode="wrap"` — avoid; hurts performance

## Model Validators (Cross-Field)

```python
# BAD: cross-field logic in a @field_validator — other fields may not exist yet
@field_validator("password_confirm")
@classmethod
def match(cls, v, info):
    if v != info.data.get("password"):  # fragile: depends on field order
        raise ValueError("mismatch")

# GOOD: @model_validator(mode="after") — all fields are set
from pydantic import model_validator

class SignUp(BaseModel):
    password: str
    password_confirm: str

    @model_validator(mode="after")
    def passwords_match(self) -> "SignUp":
        if self.password != self.password_confirm:
            raise ValueError("passwords do not match")
        return self
```

## Annotated Types for Reuse

```python
# BAD: repeat the same validator across models
class Order(BaseModel):
    quantity: int
    @field_validator("quantity")
    @classmethod
    def positive(cls, v): ...

class LineItem(BaseModel):
    quantity: int
    @field_validator("quantity")
    @classmethod
    def positive(cls, v): ...

# GOOD: define once, reuse everywhere
from typing import Annotated
from pydantic import AfterValidator, Field

def _positive(v: int) -> int:
    if v <= 0:
        raise ValueError("must be positive")
    return v

Positive = Annotated[int, AfterValidator(_positive)]
Username = Annotated[str, Field(min_length=3, max_length=32, pattern=r"^[a-z0-9_]+$")]

class Order(BaseModel):
    quantity: Positive

class LineItem(BaseModel):
    quantity: Positive
    owner: Username
```

## Separate Schemas per Operation

```python
# BAD: one model leaks internals and allows clients to set id/created_at
class User(BaseModel):
    id: int
    email: str
    hashed_password: str
    created_at: datetime

# GOOD: narrow input and output schemas
class UserCreate(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8, max_length=128)

class UserUpdate(BaseModel):
    email: EmailStr | None = None
    password: str | None = Field(default=None, min_length=8)

class UserRead(BaseModel):
    id: int
    email: EmailStr
    created_at: datetime
    model_config = ConfigDict(from_attributes=True)
```

## Partial Updates with exclude_unset

```python
# BAD: None-valued fields overwrite real data on PATCH
def update_user(user, payload: UserUpdate):
    for k, v in payload.model_dump().items():
        setattr(user, k, v)  # sets email=None if not sent

# GOOD: only touch fields the client actually sent
def update_user(user, payload: UserUpdate):
    for k, v in payload.model_dump(exclude_unset=True).items():
        setattr(user, k, v)
```

## Discriminated Unions

```python
# BAD: plain union — Pydantic tries every member, slow and error messages are noisy
Event = Union[UserCreated, UserDeleted, OrderPlaced]

# GOOD: tagged/discriminated union — O(1) dispatch on `type`
from typing import Annotated, Literal
from pydantic import Field

class UserCreated(BaseModel):
    type: Literal["user.created"]
    user_id: int

class OrderPlaced(BaseModel):
    type: Literal["order.placed"]
    order_id: int

Event = Annotated[UserCreated | OrderPlaced, Field(discriminator="type")]

class Envelope(BaseModel):
    event: Event
```

## Computed Fields

```python
# BAD: property not serialized, not in schema, not in model_dump()
class User(BaseModel):
    first: str
    last: str

    @property
    def full_name(self) -> str:
        return f"{self.first} {self.last}"

# GOOD: @computed_field serializes and appears in JSON schema
from pydantic import computed_field

class User(BaseModel):
    first: str
    last: str

    @computed_field
    @property
    def full_name(self) -> str:
        return f"{self.first} {self.last}"
```

## Mutable Defaults

Pydantic deep-copies mutable defaults per instance, but `default_factory` is clearer and matches stdlib `dataclasses`.

```python
# OK but unclear intent
class Cart(BaseModel):
    items: list[str] = []

# GOOD: explicit factory
class Cart(BaseModel):
    items: list[str] = Field(default_factory=list)
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
```

## Strict Mode at the Boundary

```python
# BAD: lax coercion silently turns "123" into 123 — hides upstream bugs
class Request(BaseModel):
    user_id: int

Request.model_validate({"user_id": "123"})  # works, but should it?

# GOOD: strict at trust boundaries (external APIs, queue messages)
class Request(BaseModel):
    model_config = ConfigDict(strict=True)
    user_id: int

# Or per-call
Request.model_validate(payload, strict=True)
```

## TypeAdapter for Non-BaseModel Types

```python
# BAD: wrapping a single value in a throwaway model
class _Wrap(BaseModel):
    items: list[int]
_Wrap.model_validate({"items": raw})

# GOOD: TypeAdapter validates any type — primitives, lists, TypedDict, dataclasses
from pydantic import TypeAdapter

IntList = TypeAdapter(list[int])
items = IntList.validate_python(raw)
json_bytes = IntList.dump_json(items)
```

Cache the adapter at module scope — construction is the expensive part.

## Settings with pydantic-settings

```python
from pydantic_settings import BaseSettings, SettingsConfigDict
from functools import lru_cache

class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_prefix="APP_", extra="ignore")
    database_url: str
    jwt_secret: str
    debug: bool = False

@lru_cache
def get_settings() -> Settings:
    return Settings()
```

## Serialization Control

```python
from pydantic import SecretStr, field_serializer

class User(BaseModel):
    email: EmailStr
    api_key: SecretStr                     # masked in repr/model_dump by default

    @field_serializer("email")
    def _lower(self, v: str) -> str:
        return v.lower()

user.model_dump()            # python dict
user.model_dump_json()       # JSON string, faster than json.dumps(model_dump())
user.model_dump(exclude={"api_key"})
```

## Performance Notes

- Prefer `model_dump_json()` over `json.dumps(model_dump())` — one pass through the Rust core.
- Cache `TypeAdapter` instances at module scope.
- Use discriminated unions instead of plain unions for polymorphic payloads.
- Avoid `mode="wrap"` validators in hot paths.
- Use `TypedDict` over nested `BaseModel` when you only need validation, not methods.

## Rules

1. **Use `model_config = ConfigDict(...)`** — never `class Config` (v1 style)
2. **Use `@field_validator` / `@model_validator`** — never the v1 `@validator` / `@root_validator`
3. **Cross-field logic belongs in `@model_validator(mode="after")`** — not `@field_validator`
4. **Extract reusable rules into `Annotated` types** — don't copy validators across models
5. **Separate `Create` / `Update` / `Read` schemas** — never reuse one model for input and output
6. **Use `model_dump(exclude_unset=True)`** for PATCH — don't overwrite fields with `None`
7. **Tag unions with `Field(discriminator=...)`** — cheaper and clearer errors than plain unions
8. **Use `@computed_field`** — not `@property` — for derived fields that must serialize
9. **Use `default_factory`** for mutable or dynamic defaults — makes intent explicit
10. **Turn on `strict=True`** at trust boundaries — external inputs should not be silently coerced
11. **Use `TypeAdapter`** for non-BaseModel types — cache it at module scope
12. **Use `SecretStr`** for secrets — keeps them out of logs and tracebacks
