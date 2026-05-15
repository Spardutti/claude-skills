# Pydantic v2 — Models, Validation, Settings

Pydantic 2.13, Python 3.12+. All examples are fully type-hinted.

## Contents

- Model configuration (`ConfigDict`)
- Field constraints (`Field`)
- Field validators (modes)
- Model validators (cross-field, wrap mode)
- Annotated types for reuse
- Separate schemas per operation
- Partial updates with `exclude_unset`
- Discriminated unions
- Computed fields
- Mutable defaults
- Strict mode at the boundary
- Serialization control
- `TypeAdapter` for non-BaseModel types
- Settings with `pydantic-settings`
- v1 → v2 migration checklist
- Performance notes
- Rules

## Model Configuration

```python
# BAD: Pydantic v1 style — silently ignored in v2
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
        from_attributes=True,    # build from ORM objects (replaces orm_mode)
        populate_by_name=True,   # accept field name or alias on input
    )
```

## Field Constraints

Declare constraints on `Field` instead of hand-writing validators for ranges
and lengths.

```python
from pydantic import Field

class Product(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    price: float = Field(gt=0, le=1_000_000)
    sku: str = Field(pattern=r"^[A-Z]{3}-\d{4}$")
    tags: list[str] = Field(default_factory=list, max_length=10)
    # alias drives input/output JSON key
    created_by: int = Field(alias="createdBy")
```

`gt`/`ge`/`lt`/`le` for numbers, `min_length`/`max_length` for strings and
collections, `pattern` for regex, `multiple_of` for steps.

## Field Validators

```python
# BAD: v1-style @validator — deprecated; raw method without decorator does nothing
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
- `mode="wrap"` — full control, can short-circuit; avoid in hot paths

Inside a validator, raise `ValueError` or `AssertionError` — a `TypeError` no
longer becomes a `ValidationError` in v2. Use `ValidationInfo` for context (the
v1 `field`/`config` args are gone):

```python
@field_validator("end_date", mode="after")
@classmethod
def after_start(cls, v: date, info: ValidationInfo) -> date:
    start = info.data.get("start_date")
    if start and v < start:
        raise ValueError("end_date must be after start_date")
    return v
```

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
from typing import Self

class SignUp(BaseModel):
    password: str
    password_confirm: str

    @model_validator(mode="after")
    def passwords_match(self) -> Self:
        if self.password != self.password_confirm:
            raise ValueError("passwords do not match")
        return self
```

`mode="before"` model validators receive the raw input (a dict) and run before
field parsing — use to normalize payload shape. `mode="wrap"` wraps the handler
for full control. `mode="after"` is an instance method; `before`/`wrap` are
classmethods.

## Annotated Types for Reuse

Define a validation rule once as an `Annotated` type instead of copying the
same validator across models.

```python
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
    quantity: Positive       # reused, no duplicated validator
    owner: Username
```

## Separate Schemas per Operation

```python
# BAD: one model leaks internals and lets clients set id/created_at
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
    model_config = ConfigDict(from_attributes=True)
    id: int
    email: EmailStr
    created_at: datetime
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
# BAD: plain union — Pydantic tries every member, slow with noisy errors
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

A plain `@property` is not serialized and not in the JSON schema.
`@computed_field` makes a derived value appear in `model_dump()` and the schema.

```python
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

Pydantic deep-copies mutable defaults per instance, but `default_factory` is
clearer and matches stdlib `dataclasses`.

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

## Serialization Control

```python
from pydantic import SecretStr, field_serializer

class User(BaseModel):
    email: EmailStr
    api_key: SecretStr                     # masked in repr/model_dump by default
    created_by: int = Field(alias="createdBy")

    @field_serializer("email")
    def _lower(self, v: str) -> str:
        return v.lower()

user.model_dump()                    # python dict
user.model_dump_json()               # JSON string, one Rust pass — faster
user.model_dump(by_alias=True)       # {"createdBy": ...} instead of created_by
user.model_dump(exclude={"api_key"})
user.model_dump(exclude_none=True)   # drop fields whose value is None
```

`model_dump_json()` is a single pass through the Rust core — faster than
`json.dumps(model_dump())` and handles `datetime`/`UUID`/`Decimal` natively.
`@model_serializer` customizes the whole object's output shape.

## TypeAdapter for Non-BaseModel Types

```python
# BAD: wrapping a single value in a throwaway model
class _Wrap(BaseModel):
    items: list[int]
_Wrap.model_validate({"items": raw})

# GOOD: TypeAdapter validates any type — primitives, lists, TypedDict, dataclasses
from pydantic import TypeAdapter

IntList = TypeAdapter(list[int])     # construct ONCE at module scope
items = IntList.validate_python(raw)
json_bytes = IntList.dump_json(items)
```

Cache the adapter at module scope — construction is the expensive part.

## Settings with pydantic-settings

`BaseSettings` lives in the separate `pydantic-settings` package, not `pydantic`.

```python
from functools import lru_cache
from pydantic import SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict

class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_prefix="APP_", extra="ignore")
    database_url: str
    jwt_secret: SecretStr          # never logged or dumped in plaintext
    debug: bool = False

@lru_cache
def get_settings() -> Settings:
    return Settings()
```

`@lru_cache` makes settings a singleton — env parsing happens once.

## v1 → v2 Migration Checklist

Common gotchas when adopting v2 in legacy code:

- Methods: `.dict()` → `.model_dump()`, `.json()` → `.model_dump_json()`,
  `.parse_obj()` → `.model_validate()`, `.construct()` → `.model_construct()`,
  `.copy()` → `.model_copy()`.
- Config: `class Config` → `model_config = ConfigDict(...)`; `orm_mode` →
  `from_attributes`; `allow_population_by_field_name` → `populate_by_name`.
- Validators: `@validator` → `@field_validator`, `@root_validator` →
  `@model_validator`; the `field`/`config` args are gone — use `ValidationInfo`.
- A `TypeError` raised inside a validator no longer becomes a `ValidationError`
  — raise `ValueError` or `AssertionError`.
- `GenericModel` is removed — use `Generic[T]` directly on `BaseModel`.
- `ConstrainedInt`/`ConstrainedStr` are removed — use `Annotated[int, Field(...)]`.
- `BaseSettings` moved to the `pydantic-settings` package.
- Removed config keys: `allow_mutation`, `error_msg_templates`, `getter_dict`.

## Performance Notes

- Prefer `model_dump_json()` over `json.dumps(model_dump())` — one Rust pass.
- Cache `TypeAdapter` instances at module scope.
- Use discriminated unions instead of plain unions for polymorphic payloads.
- Avoid `mode="wrap"` validators in hot paths.
- Use `TypedDict` over nested `BaseModel` when you only need validation.

## Rules

1. **Use `model_config = ConfigDict(...)`** — never `class Config` (v1 style).
2. **Use `@field_validator` / `@model_validator`** — never the v1 `@validator` / `@root_validator`.
3. **Cross-field logic belongs in `@model_validator(mode="after")`** — not `@field_validator`.
4. **Declare constraints on `Field`** — don't hand-write validators for ranges and lengths.
5. **Extract reusable rules into `Annotated` types** — don't copy validators across models.
6. **Separate `Create` / `Update` / `Read` schemas** — never reuse one model for input and output.
7. **Use `model_dump(exclude_unset=True)`** for PATCH — don't overwrite fields with `None`.
8. **Tag unions with `Field(discriminator=...)`** — cheaper, clearer errors than plain unions.
9. **Use `@computed_field`** — not `@property` — for derived fields that must serialize.
10. **Use `default_factory`** for mutable or dynamic defaults.
11. **Turn on `strict=True`** at trust boundaries — external inputs should not be silently coerced.
12. **Use `TypeAdapter`** for non-BaseModel types — cache it at module scope.
13. **Use `SecretStr`** for secrets — keeps them out of logs and tracebacks.
14. **Import `BaseSettings` from `pydantic-settings`** — it is not in `pydantic`.
