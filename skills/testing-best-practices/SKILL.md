---
name: testing-best-practices
tracks: vitest@5, pytest@9 (pypi)
metadata:
  gate-paths: "**/*.test.ts, **/*.test.tsx, **/*.spec.ts, **/*.spec.tsx, **/test_*.py, **/*_test.py"
category: Foundations
description: "MUST USE when writing, reviewing, or modifying tests. Enforces Arrange-Act-Assert, assertions that fail when the code breaks (exact values, list ties, side effects, limits), factory-based test data, test isolation, mocking boundaries, and pyramid-balanced coverage; bundle covers mutation testing (Stryker, mutmut) for proving the tests would catch a break."
---

# Testing Best Practices

## Quick Reference — When to Load What

| Working on… | Read |
|---|---|
| Proving the tests would catch a break — Stryker, mutmut, surviving mutants, mutation score | MUTATION-TESTING.md |

## Testing Pyramid

| Layer | Share | Speed | Examples |
|-------|-------|-------|----------|
| Unit | ~70% | Fast (ms) | Pure logic, validators, utils |
| Integration | ~20% | Medium (s) | API endpoints, DB queries, service + repo |
| E2E | ~10% | Slow (10s+) | Login → checkout → confirmation |

**Test:** business logic, edge cases, error paths, public API contracts.
**Skip:** framework internals, third-party lib behavior, private methods, trivial getters.

## Test Behavior, Not Implementation

```python
# BAD: testing internals
def test_user_creation():
    service = UserService()
    service.create_user("alice@example.com")
    service._repo.insert.assert_called_once_with({"email": "alice@example.com", "role": "member"})

# GOOD: testing observable behavior
def test_create_user_stores_user_with_default_role():
    service = UserService()
    service.create_user("alice@example.com")
    user = service.get_user("alice@example.com")
    assert user.email == "alice@example.com"
    assert user.role == "member"
```

## Assert What Would Break

A test that still passes when the code is wrong proves nothing. Each case below is a gap mutation testing found in a suite that was green.

### Values, not shapes

```python
# BAD: every value could be wrong, and so could the message
assert set(body) == {"id", "slug", "name"}
assert response.status_code == 409

# GOOD
assert (body["slug"], body["name"]) == ("caribe", "Caribe")
assert response.json() == {"detail": "Another destino already uses that slug"}
```

### Lists: a tie, a short page, an empty result

Two distinct rows still pass with the tiebreak dropped, the `LIMIT` dropped, or `total or 1`.

```python
# GOOD: a tie that comes back out of order without the id tiebreak
older = await make_destino(db, slug="alaska", name="Alaska")
await make_destino(db, slug="caribe", name="Caribe")
older.name = "Caribe"  # an UPDATE rewrites the row after newer ones on disk
await db.flush()
assert await listed_slugs(client, "/destinos") == ["alaska", "caribe"]

# GOOD: more rows than the page holds
for slug in ("a", "b", "c"):
    await make_destino(db, slug=slug)
body = (await client.get("/destinos?size=2")).json()
assert (len(body["items"]), body["total"]) == (2, 3)

# GOOD: nothing to list
assert (await client.get("/destinos")).json()["total"] == 0
```

**A grouped query ignores that UPDATE.** Its rows come out of the aggregate, not off the disk. On Postgres 17, three tied groups still came back in id order with the tiebreak deleted; five came back `1,3,5,4,2`.

```python
# BAD: GROUP BY hands back a few groups in key order, so a dropped tiebreak passes
for slug in ("alaska", "caribe"):
    await make_published_menu(db, slug=slug, confirmed_at=NOON)

# GOOD: five tied groups, which hash aggregation returned scrambled
for slug in ("alaska", "baltico", "caribe", "egeo", "fiordos"):
    await make_published_menu(db, slug=slug, confirmed_at=NOON)
assert await suggested_slugs(client) == ["alaska", "baltico", "caribe", "egeo", "fiordos"]
```

Delete the tiebreak once and watch the test fail. If it still passes, run `EXPLAIN`: a `GroupAggregate` keyed on the tiebreak itself sorts the ties for free, so no data can catch it. Report that; never keep a test that cannot fail.

### The side effect, not just the response

```python
# BAD: passes with the audit row missing
assert (await client.delete(f"/navieras/{naviera.id}")).status_code == 204

# GOOD
await client.delete(f"/navieras/{naviera.id}")
entry = (await db.scalars(select(AuditLog))).one()
assert (entry.user_id, entry.data_before["slug"]) == (admin.id, "oceania")
```

### Both sides of a limit

```typescript
test("accepts a photo exactly at the size limit", () => {
  expect(refusal(fileOfSize(MAX_PHOTO_BYTES))).toBeNull();
});

test("refuses a photo one byte over the size limit", () => {
  expect(refusal(fileOfSize(MAX_PHOTO_BYTES + 1))).toBe("photo.jpg is over 10 MB");
});
```

### A mirrored domain gets parametrized tests, not copied ones

Copying `tests/navieras/` into `tests/destinos/` copies every gap, and each one then fails once per copy.

```python
@pytest.mark.parametrize("url, make", [
    ("/navieras", make_naviera),
    ("/destinos", make_destino),
], ids=["navieras", "destinos"])
async def test_a_page_holds_at_most_size_items(client, db, url, make):
    for slug in ("a", "b", "c"):
        await make(db, slug=slug)
    assert len((await client.get(f"{url}?size=2")).json()["items"]) == 2
```

## Arrange-Act-Assert

One behavior per test. If you need "and" in the test name, split it.

```python
# GOOD
def test_place_order_calculates_total_from_price_and_quantity():
    # Arrange
    user = UserFactory()
    product = ProductFactory(price=10)
    # Act
    order = OrderService.place_order(user, product, quantity=3)
    # Assert
    assert order.total == 30
```

```typescript
test("adding items updates the cart total", () => {
  const cart = new Cart();
  cart.add({ id: 1, price: 10 });
  cart.add({ id: 2, price: 20 });
  expect(cart.total).toBe(30);
});
```

## Naming: `test_[what]_[scenario]_[expected]`

```python
# BAD
def test_order(): ...
def test_it_works(): ...

# GOOD
def test_place_order_with_insufficient_stock_raises_out_of_stock(): ...
def test_cancel_order_after_shipment_raises_not_cancellable(): ...
```

## Factory Pattern for Test Data

Minimal defaults, override only what matters.

```python
# GOOD: factory_boy
class UserFactory(factory.django.DjangoModelFactory):
    class Meta:
        model = User
    username = factory.Sequence(lambda n: f"user-{n}")
    email = factory.LazyAttribute(lambda o: f"{o.username}@example.com")
    is_active = True
    class Params:
        admin = factory.Trait(is_staff=True, is_superuser=True)

user = UserFactory()
admin = UserFactory(admin=True)
inactive = UserFactory(is_active=False)
```

```typescript
// GOOD: fishery
const userFactory = Factory.define<User>(({ sequence, params }) => ({
  id: sequence,
  email: `user-${sequence}@example.com`,
  role: params.admin ? "admin" : "member",
  isActive: true,
}));

const user = userFactory.build();
const admin = userFactory.build({ admin: true });
```

Use **fixtures** for infrastructure (DB, client), **factories** for data (models, DTOs).

## Test Isolation

Each test must be independent. No shared mutable state.

```python
# BAD: module-level shared state
cart = Cart()
def test_add_item():
    cart.add(Item(price=10))
    assert cart.total == 10
def test_cart_is_empty():
    assert cart.total == 0  # FAILS — polluted

# GOOD: fresh state per test
@pytest.fixture
def cart():
    return Cart()

def test_add_item(cart):
    cart.add(Item(price=10))
    assert cart.total == 10
```

- Transaction rollback or truncation between tests
- Never rely on test execution order
- Reset singletons and caches in `beforeEach`/`setUp`

### Unique test data, or parallel tests queue

A rolled-back test holds every row it wrote or deleted until it ends. A fixed value in a unique column, or a `DELETE FROM` a whole table at test start, makes every parallel worker (mutmut, xdist) wait for the one before it. One API's mutation run went 2.1× faster from unique values alone; xdist can instead give each worker its own database.
```python
# BAD — every test inserts the same email; workers queue on the unique index
return await make_user(session, "test@example.com")
# GOOD — a value no other running test can hold
return await make_user(session, f"test-{uuid4()}@example.com")
```

### A wait that swallows its timeout is a sleep

```ts
// BAD — a page with no heading waits the full 3s, then carries on as if it loaded.
// One helper did this in every page test: 41 tests, 80% of the suite's time.
await screen.findByRole("heading", undefined, { timeout: 3000 }).catch(() => undefined);

// GOOD — wait for what means ready, and let a timeout fail the test.
// status starts "idle" before the first load, so resolvedLocation is checked too.
await waitFor(() => {
  expect(router.state.status).toBe("idle");
  expect(router.state.resolvedLocation).toBeDefined();
});
```

## Mocking — Only at the Boundary

**Mock:** external HTTP APIs, file/network I/O, time, non-deterministic values.
**Don't mock:** your own DB in integration tests, stdlib, the system under test.

```python
# BAD: over-mocking — testing nothing real
@patch("app.services.order.OrderRepository")
@patch("app.services.order.PaymentGateway")
@patch("app.services.order.InventoryService")
def test_place_order(mock_inv, mock_pay, mock_repo):
    service = OrderService()
    service.place_order(user_id=1, items=[{"id": 1, "qty": 2}])
    mock_repo.return_value.save.assert_called_once()

# GOOD: mock only the external boundary
def test_place_order_charges_payment_gateway(db_session):
    user = UserFactory()
    product = ProductFactory(price=25, stock=10)
    mock_gateway = Mock(spec=PaymentGateway)
    mock_gateway.charge.return_value = ChargeResult(success=True, tx_id="tx-123")
    service = OrderService(payment_gateway=mock_gateway)

    order = service.place_order(user, items=[{"product_id": product.id, "qty": 2}])

    mock_gateway.charge.assert_called_once_with(amount=50, user_id=user.id)
    assert order.status == "confirmed"
```

## Parameterized Tests

```python
@pytest.mark.parametrize("email, is_valid", [
    ("user@example.com", True),
    ("", False),
    ("missing-at-sign", False),
    ("@no-local.com", False),
], ids=["valid", "empty", "missing @", "no local part"])
def test_validate_email(email, is_valid):
    assert validate_email(email) == is_valid
```

```typescript
test.each([
  { input: "hello world", expected: "hello-world", desc: "spaces to hyphens" },
  { input: "", expected: "", desc: "empty string" },
])("slugify: $desc", ({ input, expected }) => {
  expect(slugify(input)).toBe(expected);
});
```

## Rules

1. **Test behavior, not implementation** — assert on outputs, not internal method calls
2. **One behavior per test** — if you need "and" in the name, split it
3. **Arrange-Act-Assert** — three clear phases, no mixing
4. **Descriptive names** — `test_[what]_[scenario]_[expected]`
5. **Factories for test data** — minimal defaults, override only what matters
6. **Mock at the boundary** — external services and I/O only
7. **Isolate every test** — no shared mutable state, transaction rollback, a fresh value in every unique column
8. **Follow the pyramid** — ~70% unit, ~20% integration, ~10% E2E
9. **Parameterize repetitive cases** — `parametrize`/`test.each` with descriptive IDs
10. **Fix or delete flaky tests** — a flaky test is worse than no test
11. **A green suite is not evidence** — tests written beside the code pass by construction; `/ship` proves them once with `ship-gate.sh`, before the PR. Never run the gate, Stryker or mutmut yourself mid-work; any later edit voids the run (MUTATION-TESTING.md)
12. **Assert values, not shapes** — the exact fields and error message, never only key names or a status code
13. **Give list tests a tie, more rows than the page, and an empty case** — two distinct rows cannot catch a dropped tiebreak or `LIMIT`, and a grouped query needs five tied groups
14. **Assert the side effect** — the audit row, the stored file, the sent message, not only the response
15. **Test both sides of every limit** — exactly at it, and one past it
16. **Parametrize a mirrored domain's tests** — never copy a test folder; its gaps come with it
17. **Never swallow a wait's timeout** — a caught timeout is a silent sleep that every test, and every mutant, pays

## Reference Files

- **MUTATION-TESTING.md** — read when setting up or reading mutation testing. Covers what it catches that review cannot (an assertion importing the constant it asserts on), Stryker setup with `coverageAnalysis: "perTest"` and diff-scoped `--mutate` ranges, the `.stryker-tmp` sandbox that silently doubles the test count, keeping page tests out of the Stryker run, mutmut 3's renamed config keys and mutant-name globs, why grepping for the word `survived` false-positives on Stryker's own summary header, the Ignore plugin for class-name noise, and working score thresholds.

## Anti-Rationalizations

| Excuse | Rebuttal |
|--------|----------|
| "I'll write tests after the implementation works" | "Later" never comes. Write the failing test first — it forces you to define done. |
| "This is too simple to need a test" | If it's simple, the test is one line. Write it. |
| "I tested it manually, it works" | Manual tests don't run in CI. The next refactor breaks it silently. |
| "Mocking the DB is fine here" | Mocked-DB tests pass while real migrations fail. Hit a real DB at the integration layer. |
| "The status code proves the endpoint works" | A 409 with the wrong message, or a 204 that skipped the audit row, returns the same code. |
| "100% coverage means it's well tested" | Coverage measures lines executed, not behavior verified. A test with no meaningful assertion is worthless. |
| "The test is flaky, just retry it in CI" | A flaky test is a broken test. Fix the race or delete it — retries hide real bugs. |
