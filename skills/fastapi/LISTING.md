# List Endpoints — Pagination, Filtering, Search, Sorting

Design list endpoints **complete from day one**. The expensive mistake is
shipping `GET /users` that returns a bare array, then retrofitting pagination —
which turns `[...]` into `{items, total, ...}`, a breaking change for every
client. Ship the envelope, the filter params, and the sort contract up front.

## Contents

- The paginated response envelope
- Offset vs cursor — the decision
- Offset pagination
- Cursor pagination
- Filtering — typed params as a dependency
- Searching — ILIKE vs full-text
- Sorting — the allow-list
- Composing one list-query dependency
- Total-count cost
- Rules

## The Paginated Response Envelope

Never return a bare `list[T]`. Wrap every collection response in a generic
envelope — adding fields to it later is non-breaking; changing an array into
an object is not.

```python
from typing import Generic, TypeVar
from pydantic import BaseModel

T = TypeVar("T")

class Page(BaseModel, Generic[T]):
    items: list[T]
    total: int
    page: int
    size: int
    pages: int
    has_next: bool
    has_prev: bool
```

```python
# BAD: bare array — adding pagination later changes the response shape
@router.get("/users", response_model=list[UserRead])
async def list_users(db: DBSession):
    return await user_service.all(db)

# GOOD: envelope from the first commit — future fields are additive
@router.get("/users", response_model=Page[UserRead])
async def list_users(db: DBSession, q: Annotated[ListQuery, Depends(list_query)]):
    return await user_service.list(db, q)
```

`response_model=Page[UserRead]` gives a fully typed, documented OpenAPI schema.

## Offset vs Cursor — The Decision

| Use **offset** (`page`/`size`) | Use **cursor**/keyset |
|---|---|
| Small/medium datasets | Large tables (deep pages scan and discard huge row counts) |
| Users jump to arbitrary pages | Infinite scroll / feeds |
| Low write churn | Frequent inserts (offset pages shift → dupes/skips) |
| `total` count is affordable | No random access, no `total` needed |

Pick per endpoint — but **the envelope shape is fixed regardless**. The `sql`
skill covers keyset pagination at the database level (the supporting index and
the tuple-comparison `WHERE (created_at, id) < (...)`); this file adds the API
layer on top.

## Offset Pagination

```python
from fastapi import Query
from sqlalchemy import select, func

@router.get("/products", response_model=Page[ProductRead])
async def list_products(
    db: DBSession,
    page: int = Query(1, ge=1),
    size: int = Query(20, ge=1, le=100),   # le clamps abusive page sizes
):
    total = await db.scalar(select(func.count()).select_from(Product))
    rows = (await db.scalars(
        select(Product).order_by(Product.id).limit(size).offset((page - 1) * size)
    )).all()
    pages = (total + size - 1) // size
    return Page(
        items=rows, total=total, page=page, size=size, pages=pages,
        has_next=page < pages, has_prev=page > 1,
    )
```

`Query(..., ge=, le=)` validates and clamps in one place — never trust a raw
`limit` off the wire.

## Cursor Pagination

For large or high-churn tables. The cursor is an **opaque** token — encode the
last row's sort key, don't expose raw offsets or ids as a contract.

```python
import base64, json

class CursorPage(BaseModel, Generic[T]):
    items: list[T]
    next_cursor: str | None   # null = last page

def encode_cursor(created_at: datetime, id: int) -> str:
    return base64.urlsafe_b64encode(
        json.dumps([created_at.isoformat(), id]).encode()
    ).decode()

@router.get("/events", response_model=CursorPage[EventRead])
async def list_events(db: DBSession, cursor: str | None = None,
                      size: int = Query(20, ge=1, le=100)):
    stmt = select(Event).order_by(Event.created_at.desc(), Event.id.desc())
    if cursor:
        ts, last_id = json.loads(base64.urlsafe_b64decode(cursor))
        # keyset: tuple comparison, not OFFSET — see the sql skill for the index
        stmt = stmt.where(
            tuple_(Event.created_at, Event.id) < (datetime.fromisoformat(ts), last_id)
        )
    rows = (await db.scalars(stmt.limit(size + 1))).all()  # fetch one extra
    has_more = len(rows) > size
    rows = rows[:size]
    next_cursor = encode_cursor(rows[-1].created_at, rows[-1].id) if has_more else None
    return CursorPage(items=rows, next_cursor=next_cursor)
```

Fetching `size + 1` rows yields `has_next` with no `COUNT` query.

## Filtering — Typed Params as a Dependency

Bind a Pydantic model to query params. FastAPI flattens its fields into `?`
params, validates types, and rejects unknown params with `extra="forbid"`.

```python
class ProductFilter(BaseModel):
    model_config = {"extra": "forbid"}
    category: str | None = None
    min_price: float | None = Field(None, ge=0)
    max_price: float | None = Field(None, ge=0)
    status__in: list[str] | None = None   # repeated ?status__in=a&status__in=b

def apply_filters(stmt, f: ProductFilter):
    if f.category:   stmt = stmt.where(Product.category == f.category)
    if f.min_price:  stmt = stmt.where(Product.price >= f.min_price)
    if f.max_price:  stmt = stmt.where(Product.price <= f.max_price)
    if f.status__in: stmt = stmt.where(Product.status.in_(f.status__in))
    return stmt

@router.get("/products", response_model=Page[ProductRead])
async def list_products(f: Annotated[ProductFilter, Query()], db: DBSession): ...
```

Each filter maps to an **explicit, hand-written** `where`. The client never
names a column — field names are fixed in the model. Adding a filter field
later is purely additive: the contract stays stable.

## Searching — ILIKE vs Full-Text

```python
# Small tables / early stage: ILIKE — simple, no schema change
if search:
    stmt = stmt.where(Product.name.ilike(f"%{search}%"))
```

`ILIKE '%q%'` has no usable index on an interior wildcard, no stemming, no
ranking — fine under ~100k rows. Beyond that, or once search is a real
feature, switch to Postgres full-text: a stored `tsvector` column + GIN index.

```python
# Real search: full-text. websearch_to_tsquery safely parses a search box
# (quotes, OR, -exclusions) — never feed raw input to to_tsquery.
stmt = stmt.where(
    Product.search_vec.op("@@")(func.websearch_to_tsquery("english", search))
).order_by(func.ts_rank(Product.search_vec, func.websearch_to_tsquery("english", search)).desc())
```

Enforce `Query(None, min_length=2)` on the search param — single-character
searches scan everything.

## Sorting — The Allow-List

**Never** interpolate a client string into `order_by`. `getattr(Model, user_input)`
exposes arbitrary columns and relationships — an injection and data-exposure
hole. Map a fixed set of names to columns explicitly.

```python
SORT_FIELDS = {
    "price": Product.price,
    "name": Product.name,
    "created": Product.created_at,
}

def apply_sort(stmt, sort: str):
    descending = sort.startswith("-")
    column = SORT_FIELDS.get(sort.lstrip("-"))
    if column is None:
        raise HTTPException(422, detail=f"Cannot sort by '{sort}'")
    # trailing id = stable tiebreaker — required for deterministic paging
    return stmt.order_by(column.desc() if descending else column.asc(), Product.id)
```

```python
# BAD: arbitrary attribute access — client can name any column or relationship
stmt = stmt.order_by(getattr(Product, request.query_params["sort"]))
```

The trailing `Product.id` guarantees a total order — without it, rows with
equal sort values can shuffle between pages and corrupt cursor pagination.

## Composing One List-Query Dependency

Bundle pagination + filter + search + sort into a single dependency so every
list route stays thin and consistent.

```python
@dataclass
class ListQuery:
    filter: ProductFilter
    search: str | None
    sort: str
    page: int
    size: int

def list_query(
    f: Annotated[ProductFilter, Query()],
    search: str | None = Query(None, min_length=2),
    sort: str = Query("-created"),
    page: int = Query(1, ge=1),
    size: int = Query(20, ge=1, le=100),
) -> ListQuery:
    return ListQuery(filter=f, search=search, sort=sort, page=page, size=size)

# Route stays ~3 lines — HTTP only, logic in the service
@router.get("/products", response_model=Page[ProductRead])
async def list_products(q: Annotated[ListQuery, Depends(list_query)], db: DBSession):
    return await product_service.list(db, q)
```

The service applies them in order: base `select` → `apply_filters` →
search → `apply_sort` → paginate → build `Page`. One reusable pipeline.

## Total-Count Cost

`select(func.count())` is a full index scan — fine to a few hundred thousand
rows, expensive beyond. When `COUNT` shows up in slow-query logs:

1. **Omit `total`/`pages`** — fetch `size + 1` rows for `has_next` (see Cursor
   Pagination); the envelope keeps the field as `total: int | None`.
2. **Approximate** — Postgres `pg_class.reltuples` estimate (see the `sql` skill).
3. **Cursor pagination** — drops `total` entirely by design.

Default to an exact count; downgrade only when measured to be slow.

## Rules

1. **Never return a bare `list[T]`** — every collection response is a generic `Page[T]` / `CursorPage[T]` envelope, from the first commit.
2. **Design pagination, filtering, and sorting before shipping a list endpoint** — the response and query contract must be stable day one.
3. **Offset for random-access/small data; cursor for large or high-churn tables** — the envelope shape stays fixed either way.
4. **Validate and clamp page size** with `Query(20, ge=1, le=100)` — never trust a raw `limit`.
5. **Bind filters to a Pydantic model** with `extra="forbid"`; map each field to an explicit `where` — the client never names a column.
6. **Allow-list sortable fields** in a dict — never `getattr(Model, user_input)` or string-interpolate `order_by`.
7. **Always append a unique tiebreaker** (`id`) to the sort — required for deterministic and cursor paging.
8. **Make cursors opaque** (base64-encoded sort key) — don't expose raw offsets or ids as the contract.
9. **`ILIKE` for small tables, Postgres full-text for real search** — use `websearch_to_tsquery`, never raw `to_tsquery` on user input.
10. **Bundle list params into one `Depends` dependency** — keep the route thin, push the query pipeline into the service.
11. **Treat `total` count as a cost** — omit, approximate, or go cursor when `COUNT` is slow.
