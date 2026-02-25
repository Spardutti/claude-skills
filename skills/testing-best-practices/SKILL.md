---
name: testing-best-practices
description: "MUST USE when writing, reviewing, or modifying tests. Enforces Arrange-Act-Assert, factory-based test data, test isolation, mocking boundaries, and pyramid-balanced coverage."
---

# Testing Best Practices

Write tests that catch real bugs, run fast, and stay maintainable. Test behavior, not implementation.

## Testing Pyramid & What to Test

| Layer | Share | Speed | Scope | Examples |
|-------|-------|-------|-------|----------|
| Unit | ~70% | Fast (ms) | Single function/class | Pure logic, validators, transformers, utils |
| Integration | ~20% | Medium (s) | Multiple components | API endpoints, DB queries, service + repo |
| E2E | ~10% | Slow (10s+) | Full user flow | Login → checkout → confirmation |

### What to Test

- Business logic and domain rules
- Edge cases: empty input, boundary values, null/undefined
- Error paths and failure modes
- State transitions
- Public API contracts

### What NOT to Test

- Framework internals (Django ORM saves, React renders)
- Third-party library behavior
- Private methods directly — test through public API
- Trivial getters/setters with no logic

### Test Behavior, Not Implementation

```python
# BAD: testing implementation details
def test_user_creation():
    service = UserService()
    service.create_user("alice@example.com")
    # Brittle — breaks if internal method is renamed
    service._repo.insert.assert_called_once_with(
        {"email": "alice@example.com", "role": "member"}
    )

# GOOD: testing observable behavior
def test_create_user_stores_user_with_default_role():
    service = UserService()
    service.create_user("alice@example.com")
    user = service.get_user("alice@example.com")
    assert user.email == "alice@example.com"
    assert user.role == "member"
```

## Test Structure: Arrange-Act-Assert

Every test follows three phases. Maps to Given-When-Then in BDD. One behavior per test — if you need the word "and" in the test name, split it.

```python
# BAD: mixed phases, multiple behaviors
def test_order():
    user = User.objects.create(name="Alice")
    product = Product.objects.create(name="Widget", price=10, stock=5)
    order = OrderService.place_order(user, product, quantity=3)
    assert order.total == 30
    assert product.stock == 2  # testing two behaviors
    OrderService.cancel_order(order)
    assert order.status == "cancelled"  # separate action entirely

# GOOD: single behavior, clear phases
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
// BAD: no structure, multiple assertions on different behaviors
test("cart", () => {
  const cart = new Cart();
  cart.add({ id: 1, price: 10 });
  cart.add({ id: 2, price: 20 });
  expect(cart.items).toHaveLength(2);
  expect(cart.total).toBe(30);
  cart.clear();
  expect(cart.items).toHaveLength(0);
});

// GOOD: single behavior per test
test("adding items updates the cart total", () => {
  // Arrange
  const cart = new Cart();

  // Act
  cart.add({ id: 1, price: 10 });
  cart.add({ id: 2, price: 20 });

  // Assert
  expect(cart.total).toBe(30);
});
```

## Naming Conventions

Pattern: `test_[what]_[scenario]_[expected]`

| Element | Convention | Example |
|---------|-----------|---------|
| Test file | `test_<module>.py` / `<module>.test.ts` | `test_order_service.py` |
| Test function | `test_<what>_<scenario>_<expected>` | `test_place_order_with_zero_quantity_raises_error` |
| Fixture | Descriptive noun | `active_subscription`, `expired_token` |
| Factory | `<Model>Factory` | `UserFactory`, `OrderFactory` |
| Test class | `Test<Feature>` or `describe("<feature>")` | `TestOrderPlacement` |

```python
# BAD: vague names
def test_order():
    ...

def test_order2():
    ...

def test_it_works():
    ...

# GOOD: intent is clear from the name
def test_place_order_with_insufficient_stock_raises_out_of_stock():
    ...

def test_place_order_with_valid_items_creates_pending_order():
    ...

def test_cancel_order_after_shipment_raises_not_cancellable():
    ...
```

## Test File and Folder Structure

Separate tests by layer. Mirror the app structure within each layer. Centralize shared factories and fixtures.

### Python Project

```
tests/
├── conftest.py              # shared fixtures (db session, client)
├── factories/
│   ├── __init__.py
│   ├── user_factory.py
│   └── order_factory.py
├── unit/
│   ├── test_validators.py
│   ├── test_pricing.py
│   └── test_permissions.py
├── integration/
│   ├── test_order_api.py
│   ├── test_payment_service.py
│   └── test_user_repository.py
└── e2e/
    └── test_checkout_flow.py
```

### TypeScript Project

```
tests/
├── setup.ts                 # global setup (test DB, mocks)
├── factories/
│   ├── userFactory.ts
│   └── orderFactory.ts
├── unit/
│   ├── validators.test.ts
│   ├── pricing.test.ts
│   └── permissions.test.ts
├── integration/
│   ├── orderApi.test.ts
│   ├── paymentService.test.ts
│   └── userRepository.test.ts
└── e2e/
    └── checkoutFlow.test.ts
```

## Factory Pattern for Test Data

Factories produce valid objects with sensible defaults. Only override what matters for the specific test. Avoid kitchen-sink factories that set every field.

### Python (factory_boy)

```python
# BAD: every field specified, hard to see what matters
class UserFactory(factory.django.DjangoModelFactory):
    class Meta:
        model = User

    username = "testuser"
    email = "test@example.com"
    first_name = "Test"
    last_name = "User"
    is_active = True
    is_staff = False
    is_superuser = False
    date_joined = factory.LazyFunction(timezone.now)
    phone = "+1234567890"
    avatar = "default.png"
    bio = "Test bio"
    language = "en"
    timezone = "UTC"

# GOOD: minimal defaults, override what matters
class UserFactory(factory.django.DjangoModelFactory):
    class Meta:
        model = User

    username = factory.Sequence(lambda n: f"user-{n}")
    email = factory.LazyAttribute(lambda o: f"{o.username}@example.com")
    is_active = True

    class Params:
        admin = factory.Trait(is_staff=True, is_superuser=True)

# Usage — intent is immediately clear
user = UserFactory()                           # plain active user
admin = UserFactory(admin=True)                # admin user
inactive = UserFactory(is_active=False)        # inactive user
batch = UserFactory.create_batch(5)            # five users
```

### TypeScript (fishery)

```typescript
import { Factory } from "fishery";

// GOOD: minimal defaults with traits
const userFactory = Factory.define<User>(({ sequence, params }) => ({
  id: sequence,
  email: `user-${sequence}@example.com`,
  name: `User ${sequence}`,
  role: params.admin ? "admin" : "member",
  isActive: true,
}));

// Usage
const user = userFactory.build();
const admin = userFactory.build({ admin: true });
const users = userFactory.buildList(5);
```

### Key factory_boy Utilities

| Utility | Purpose | Example |
|---------|---------|---------|
| `Sequence` | Unique values per instance | `factory.Sequence(lambda n: f"user-{n}")` |
| `LazyAttribute` | Derive from other fields | `LazyAttribute(lambda o: f"{o.name}@test.com")` |
| `SubFactory` | Nested related objects | `author = factory.SubFactory(UserFactory)` |
| `Trait` | Named presets via `Params` | `admin = Trait(is_staff=True)` |
| `create_batch` | Generate N instances | `UserFactory.create_batch(10)` |

## Fixtures vs Factories

| Aspect | Fixtures | Factories |
|--------|----------|-----------|
| Best for | Environment setup (DB, client, config) | Test data (models, DTOs) |
| Scope | Session/module/function | Per-test |
| Examples | Database connection, API client, mock server | User, Order, Product instances |
| Reusability | Shared via `conftest.py` / `setup.ts` | Imported from `factories/` |
| Customization | Parameterized fixtures | Override fields per test |

**Recommended hybrid**: Use fixtures for infrastructure, factories for data.

```python
# Fixture: infrastructure
@pytest.fixture
def api_client(db_session):
    app = create_app(testing=True)
    with app.test_client() as client:
        yield client

# Factory: data
def test_list_active_users_returns_only_active(api_client):
    UserFactory.create_batch(3, is_active=True)
    UserFactory.create_batch(2, is_active=False)

    response = api_client.get("/users?active=true")

    assert response.status_code == 200
    assert len(response.json) == 3
```

## Test Isolation and Cleanup

Each test must be independent. No test should depend on another test's side effects. Tests must pass in any order.

```python
# BAD: shared mutable state between tests
cart = Cart()  # module-level — shared across tests!

def test_add_item():
    cart.add(Item(price=10))
    assert cart.total == 10

def test_cart_is_empty():
    assert cart.total == 0  # FAILS — polluted by previous test

# GOOD: fresh state per test via fixture
@pytest.fixture
def cart():
    return Cart()

def test_add_item(cart):
    cart.add(Item(price=10))
    assert cart.total == 10

def test_new_cart_is_empty(cart):
    assert cart.total == 0  # passes — fresh cart
```

```typescript
// BAD: shared mutable state
let db: Database;

beforeAll(async () => {
  db = await connectDatabase();
});

// Tests share the same data — ordering matters!

// GOOD: transaction rollback per test
beforeEach(async () => {
  await db.beginTransaction();
});

afterEach(async () => {
  await db.rollbackTransaction();
});
```

### Isolation Checklist

- Use transaction rollback or truncation between tests
- Use `yield` fixtures in pytest for setup + teardown
- Never rely on test execution order
- Reset singletons and caches in `beforeEach`/`setUp`
- Use unique values (Sequence/counter) to avoid collisions

## Mocking Guidelines

### When to Mock

- External HTTP APIs and third-party services
- File system and network I/O
- Time (`datetime.now`, `Date.now`)
- Non-deterministic values (UUIDs, random)
- Slow operations in unit tests (email sending, queue publishing)

### When NOT to Mock

- Your own database in integration tests
- Standard library functions
- The system under test itself
- Simple value objects or data classes

```python
# BAD: over-mocking — testing nothing real
@patch("app.services.order.OrderRepository")
@patch("app.services.order.PaymentGateway")
@patch("app.services.order.InventoryService")
@patch("app.services.order.NotificationService")
@patch("app.services.order.logger")
def test_place_order(mock_log, mock_notify, mock_inv, mock_pay, mock_repo):
    # Everything is mocked — what are we even testing?
    service = OrderService()
    service.place_order(user_id=1, items=[{"id": 1, "qty": 2}])
    mock_repo.return_value.save.assert_called_once()  # asserting on mocks

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
    assert order.payment_tx_id == "tx-123"
```

```typescript
// BAD: mocking the module under test
jest.mock("./cartService"); // why test it if you mock it?

// GOOD: mock external dependency only
test("checkout calls payment API with cart total", async () => {
  const mockPayment = jest.fn().mockResolvedValue({ success: true });
  const checkout = new CheckoutService({ processPayment: mockPayment });
  const cart = cartFactory.build({ total: 50 });

  await checkout.process(cart);

  expect(mockPayment).toHaveBeenCalledWith({ amount: 50 });
});
```

## Parameterized Tests

Use parameterized tests for the same logic with multiple inputs. Always include positive, negative, and edge cases. Use descriptive IDs.

```python
@pytest.mark.parametrize(
    "email, is_valid",
    [
        ("user@example.com", True),
        ("user+tag@example.com", True),
        ("user@sub.domain.com", True),
        ("", False),
        ("missing-at-sign", False),
        ("@no-local-part.com", False),
        ("user@", False),
        ("user @space.com", False),
    ],
    ids=[
        "standard email",
        "plus addressing",
        "subdomain",
        "empty string",
        "missing @",
        "no local part",
        "no domain",
        "contains space",
    ],
)
def test_validate_email(email, is_valid):
    assert validate_email(email) == is_valid
```

```typescript
test.each([
  { input: "hello world", expected: "hello-world", desc: "spaces to hyphens" },
  { input: "Hello World", expected: "hello-world", desc: "lowercase" },
  { input: "a--b", expected: "a-b", desc: "collapse hyphens" },
  { input: "", expected: "", desc: "empty string" },
  { input: "café", expected: "cafe", desc: "strip diacritics" },
])("slugify: $desc", ({ input, expected }) => {
  expect(slugify(input)).toBe(expected);
});
```

## Common Anti-Patterns

| Anti-Pattern | Problem | Fix |
|-------------|---------|-----|
| Ice cream cone | Mostly E2E, few unit tests — slow and fragile | Invert the pyramid: more unit, fewer E2E |
| The Mockery | Everything mocked — tests prove nothing | Mock only external boundaries |
| Implementation testing | Tests break on refactor with no behavior change | Assert on outputs and side effects, not internals |
| Complex setup | 50+ lines of arrange — test is unreadable | Use factories with minimal defaults |
| Flaky tests | Pass/fail randomly — erode trust | Fix root cause: shared state, timing, or ordering |
| No assertions | Test runs code but never asserts | Every test must have at least one meaningful assertion |
| Copy-paste tests | Dozens of identical tests with one value changed | Use parameterized tests |
| Testing private methods | Directly testing `_internal_method` | Test through the public API |
| God test file | 2000-line test file with no organization | Split by feature/layer, use folders |
| Assertion roulette | Multiple unrelated assertions with no message | One behavior per test, use descriptive messages |

## Rules Summary

1. **Test behavior, not implementation** — Assert on outputs and observable side effects, not internal method calls or data structures.
2. **One behavior per test** — If you need "and" in the test name, split the test.
3. **Arrange-Act-Assert** — Every test has three clear phases. No mixing.
4. **Name tests descriptively** — `test_[what]_[scenario]_[expected]` so failures are self-documenting.
5. **Use factories for test data** — Minimal defaults, override only what the test cares about.
6. **Mock at the boundary** — Mock external services and I/O. Never mock the system under test.
7. **Isolate every test** — No shared mutable state. Use transaction rollback, fresh fixtures, or cleanup.
8. **Follow the pyramid** — ~70% unit, ~20% integration, ~10% E2E. Invert only with strong reason.
9. **Parameterize repetitive cases** — Use `parametrize`/`test.each` with descriptive IDs instead of copy-pasting tests.
10. **Keep tests close to the code** — Mirror app structure in test folders. Group by feature, then by layer.
11. **Delete flaky tests or fix them** — A flaky test is worse than no test. Find the root cause.
12. **Review tests like production code** — Tests are documentation. They deserve the same care as the code they protect.
