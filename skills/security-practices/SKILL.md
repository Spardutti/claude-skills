---
name: security-practices
description: "MUST USE when writing or reviewing code that handles user input, authentication, authorization, API endpoints, database queries, secrets, or any security-sensitive functionality. Enforces OWASP Top 10 prevention, secure defaults, and defense-in-depth patterns."
---

# Security Best Practices

Validate all input, parameterize all queries, authenticate and authorize every request, never leak internals, and treat all external data as hostile.

## Input Validation and Sanitization

### Validate on the Server — Never Trust the Client

```python
# BAD: trusting client-side validation
@app.post("/users")
async def create_user(data: dict):
    email = data["email"]  # no validation at all
    db.execute(f"INSERT INTO users (email) VALUES ('{email}')")

# GOOD: strict schema validation with Pydantic
from pydantic import BaseModel, EmailStr, Field

class UserCreate(BaseModel):
    email: EmailStr
    username: str = Field(min_length=3, max_length=64, pattern=r"^[a-zA-Z0-9_-]+$")
    age: int = Field(ge=13, le=150)

@app.post("/users")
async def create_user(data: UserCreate):
    await user_service.create(data)
```

```typescript
// BAD: no validation
app.post("/users", (req, res) => {
  db.query("INSERT INTO users (email) VALUES ($1)", [req.body.email]);
});

// GOOD: validate with zod
import { z } from "zod";

const UserCreate = z.object({
  email: z.string().email(),
  username: z.string().min(3).max(64).regex(/^[a-zA-Z0-9_-]+$/),
  age: z.number().int().min(13).max(150),
});

app.post("/users", (req, res) => {
  const data = UserCreate.parse(req.body);
  db.query("INSERT INTO users (email) VALUES ($1)", [data.email]);
});
```

### Allowlist Over Denylist

```python
# BAD: trying to block known-bad input
def sanitize(value: str) -> str:
    for bad in ["<script>", "DROP TABLE", "' OR 1=1"]:
        value = value.replace(bad, "")
    return value

# GOOD: only allow known-good patterns
from pydantic import Field

class SortParams(BaseModel):
    sort_by: Literal["created_at", "updated_at", "name", "price"]
    order: Literal["asc", "desc"] = "asc"
```

## SQL Injection Prevention

### Always Use Parameterized Queries

```python
# BAD: string interpolation — SQL injection
username = request.args.get("username")
query = f"SELECT * FROM users WHERE username = '{username}'"
# Attacker input: ' OR '1'='1' --
# Results in: SELECT * FROM users WHERE username = '' OR '1'='1' --'

# GOOD: parameterized query
cursor.execute("SELECT * FROM users WHERE username = %s", (username,))
```

```python
# GOOD: SQLAlchemy ORM — automatically parameterized
user = await db.execute(select(User).where(User.username == username))

# GOOD: SQLAlchemy text with bound params
from sqlalchemy import text
result = await db.execute(text("SELECT * FROM users WHERE username = :name"), {"name": username})
```

```typescript
// BAD: string concatenation
const query = `SELECT * FROM users WHERE id = ${userId}`;
await db.query(query);

// GOOD: parameterized query
await db.query("SELECT * FROM users WHERE id = $1", [userId]);

// GOOD: ORM (Prisma) — automatically parameterized
const user = await prisma.user.findUnique({ where: { id: userId } });
```

### Never Interpolate Column or Table Names from User Input

```python
# BAD: user controls column name
sort_col = request.args.get("sort")
query = f"SELECT * FROM products ORDER BY {sort_col}"

# GOOD: validate against allowlist
ALLOWED_SORT = {"name", "price", "created_at"}
sort_col = request.args.get("sort", "created_at")
if sort_col not in ALLOWED_SORT:
    raise HTTPException(status_code=400, detail="Invalid sort column")
query = f"SELECT * FROM products ORDER BY {sort_col}"  # safe — validated against allowlist
```

## Cross-Site Scripting (XSS) Prevention

### Escape Output — Never Render Raw User Input

```typescript
// BAD: renders raw HTML from user input
app.get("/profile", (req, res) => {
  res.send(`<h1>Welcome, ${user.name}</h1>`);  // if name contains <script>...
});

// GOOD: use a template engine with auto-escaping (e.g., Nunjucks, Jinja2)
// Nunjucks auto-escapes by default
res.render("profile.html", { name: user.name });
```

```python
# BAD: raw HTML in response
@app.get("/greet")
async def greet(name: str):
    return HTMLResponse(f"<h1>Hello {name}</h1>")

# GOOD: use Jinja2 templates with autoescape (default)
from fastapi.templating import Jinja2Templates
templates = Jinja2Templates(directory="templates")

@app.get("/greet")
async def greet(request: Request, name: str):
    return templates.TemplateResponse("greet.html", {"request": request, "name": name})
```

### Set Content-Type and Security Headers

```python
from starlette.middleware import Middleware
from starlette.middleware.trustedhost import TrustedHostMiddleware

# Secure headers middleware
@app.middleware("http")
async def security_headers(request, call_next):
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["X-XSS-Protection"] = "0"  # modern browsers — rely on CSP instead
    response.headers["Content-Security-Policy"] = "default-src 'self'"
    response.headers["Strict-Transport-Security"] = "max-age=63072000; includeSubDomains"
    response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
    return response
```

```typescript
// Express: use helmet for secure defaults
import helmet from "helmet";
app.use(helmet());
```

## CSRF Protection

### Use Anti-CSRF Tokens for State-Changing Operations

```python
# For cookie-based auth, require CSRF tokens on all POST/PUT/DELETE
from starlette.middleware import Middleware
from starlette_csrf import CSRFMiddleware

app = FastAPI(middleware=[Middleware(CSRFMiddleware, secret="your-csrf-secret")])
```

```typescript
// Express: use csurf or csrf-csrf
import { doubleCsrf } from "csrf-csrf";

const { doubleCsrfProtection } = doubleCsrf({
  getSecret: () => process.env.CSRF_SECRET,
  cookieName: "__csrf",
});
app.use(doubleCsrfProtection);
```

For token-based auth (Bearer JWT), CSRF is mitigated by default since browsers don't auto-attach `Authorization` headers.

## Authentication

### Hash Passwords with Strong Algorithms

```python
# BAD: plain text or weak hashing
hashed = hashlib.md5(password.encode()).hexdigest()
hashed = hashlib.sha256(password.encode()).hexdigest()

# GOOD: bcrypt with auto-salting
from passlib.context import CryptContext

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

hashed = pwd_context.hash(password)
is_valid = pwd_context.verify(plain_password, hashed)
```

```typescript
// BAD: weak hashing
const hash = crypto.createHash("sha256").update(password).digest("hex");

// GOOD: bcrypt
import bcrypt from "bcrypt";
const hash = await bcrypt.hash(password, 12);
const isValid = await bcrypt.compare(password, hash);
```

### JWT Best Practices

```python
# BAD: no expiry, weak secret, no algorithm pinning
token = jwt.encode({"user_id": 1}, "secret")
data = jwt.decode(token, "secret", algorithms=["HS256", "none"])  # allows "none" alg!

# GOOD: short expiry, strong secret, pinned algorithm
from datetime import datetime, timedelta, timezone

token = jwt.encode(
    {"sub": str(user.id), "exp": datetime.now(timezone.utc) + timedelta(minutes=15)},
    settings.jwt_secret,  # loaded from env, 256+ bits
    algorithm="HS256",
)

# Decode — pin to ONE algorithm
payload = jwt.decode(token, settings.jwt_secret, algorithms=["HS256"])
```

### Return Generic Auth Error Messages

```python
# BAD: reveals which field is wrong
if not user:
    raise HTTPException(400, "User not found")
if not verify_password(password, user.hashed_password):
    raise HTTPException(400, "Incorrect password")

# GOOD: generic message prevents user enumeration
if not user or not verify_password(password, user.hashed_password):
    raise HTTPException(401, "Incorrect username or password")
```

## Authorization

### Scope Queries to the Authenticated User

```python
# BAD: IDOR — any authenticated user can access any order
@router.get("/orders/{order_id}")
async def get_order(order_id: int, db: DBSession):
    return await db.get(Order, order_id)

# GOOD: scope to user
@router.get("/orders/{order_id}")
async def get_order(order_id: int, db: DBSession, user: CurrentUser):
    order = await db.execute(
        select(Order).where(Order.id == order_id, Order.user_id == user.id)
    )
    order = order.scalar_one_or_none()
    if not order:
        raise HTTPException(status_code=404, detail="Order not found")
    return order
```

### Enforce Least Privilege with Role/Permission Checks

```python
# Dependency that checks roles
def require_role(*roles: str):
    async def check(current_user: CurrentUser):
        if current_user.role not in roles:
            raise HTTPException(status_code=403, detail="Forbidden")
        return current_user
    return check

AdminUser = Annotated[User, Depends(require_role("admin"))]

@router.delete("/users/{user_id}")
async def delete_user(user_id: int, admin: AdminUser, db: DBSession):
    await user_service.delete(db, user_id)
```

## Secret Management

### Never Hardcode Secrets

```python
# BAD: secrets in source code
JWT_SECRET = "super-secret-key-123"
DATABASE_URL = "postgresql://admin:password@db:5432/prod"

# GOOD: load from environment with validation
from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    jwt_secret: str  # required — fails if not set
    database_url: str
    model_config = SettingsConfigDict(env_file=".env")

# .env is in .gitignore — NEVER committed
```

### Gitignore Sensitive Files

```gitignore
# MUST be in .gitignore
.env
.env.*
*.pem
*.key
credentials.json
service-account.json
```

## Error Handling — Never Leak Internals

```python
# BAD: exposes stack trace, DB schema, internal paths
@app.exception_handler(Exception)
async def handler(request, exc):
    return JSONResponse(status_code=500, content={"detail": str(exc)})
    # Could leak: "relation 'users' does not exist" or file paths

# GOOD: log internally, return generic message
import logging
logger = logging.getLogger(__name__)

@app.exception_handler(Exception)
async def handler(request, exc):
    logger.exception("Unhandled error", exc_info=exc)
    return JSONResponse(status_code=500, content={"detail": "Internal server error"})
```

```python
# BAD: debug mode in production
app = FastAPI(debug=True)  # exposes tracebacks to clients

# GOOD: debug only in development
app = FastAPI(debug=settings.debug)  # settings.debug = False in production
```

## CORS Configuration

```python
# BAD: wide open — allows any origin with credentials
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_credentials=True)

# GOOD: explicit origins, scoped methods and headers
app.add_middleware(
    CORSMiddleware,
    allow_origins=["https://app.example.com"],
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "DELETE"],
    allow_headers=["Authorization", "Content-Type"],
)
```

## Rate Limiting

```python
# FastAPI with slowapi
from slowapi import Limiter
from slowapi.util import get_remote_address

limiter = Limiter(key_func=get_remote_address)
app.state.limiter = limiter

@app.post("/auth/login")
@limiter.limit("5/minute")
async def login(request: Request, data: LoginRequest):
    ...
```

```typescript
// Express with express-rate-limit
import rateLimit from "express-rate-limit";

const authLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 5,
  message: "Too many login attempts, try again later",
});
app.use("/auth/login", authLimiter);
```

## Dependency Security

### Keep Dependencies Updated and Audited

```bash
# Python — audit for known vulnerabilities
pip-audit

# Node — audit for known vulnerabilities
npm audit

# Pin exact versions in production
# requirements.txt: package==1.2.3 (not package>=1.2.3)
# package.json: "package": "1.2.3" (not "^1.2.3")
```

### Use Lock Files and Verify Integrity

Always commit `package-lock.json`, `poetry.lock`, or `requirements.txt` with pinned hashes. Use `pip install --require-hashes` or `npm ci` in CI/CD.

## HTTPS and Transport Security

```python
# Enforce HTTPS redirect in production
from starlette.middleware.httpsredirect import HTTPSRedirectMiddleware

if not settings.debug:
    app.add_middleware(HTTPSRedirectMiddleware)

# Set HSTS header (via security headers middleware above)
# "Strict-Transport-Security": "max-age=63072000; includeSubDomains"
```

Set secure cookie flags:

```python
response.set_cookie(
    key="session",
    value=token,
    httponly=True,    # not accessible via JavaScript
    secure=True,      # HTTPS only
    samesite="lax",   # CSRF mitigation
    max_age=3600,
)
```

## Rules Summary

1. **Validate all input server-side** — use Pydantic, Zod, or equivalent; never trust the client
2. **Allowlist over denylist** — validate against known-good values, not known-bad patterns
3. **Parameterize all queries** — never interpolate user input into SQL, use ORM or bound params
4. **Escape all output** — use auto-escaping templates, set `Content-Security-Policy` header
5. **Hash passwords with bcrypt/argon2** — never MD5, SHA, or plain text
6. **Pin JWT algorithm, set short expiry** — never allow `"none"` algorithm
7. **Return generic auth errors** — never reveal whether username or password was wrong
8. **Scope queries to authenticated user** — prevent IDOR by filtering on `user_id`
9. **Enforce least privilege** — role/permission checks via dependencies, not inline logic
10. **Never hardcode secrets** — use environment variables, keep `.env` in `.gitignore`
11. **Never leak internal errors** — log details server-side, return generic messages to clients
12. **Explicit CORS origins** — never `"*"` with credentials
13. **Rate limit auth endpoints** — prevent brute force attacks
14. **Audit dependencies** — use `pip-audit` / `npm audit`, pin versions, use lock files
15. **Enforce HTTPS** — redirect HTTP, set HSTS, use `secure` and `httponly` cookie flags
