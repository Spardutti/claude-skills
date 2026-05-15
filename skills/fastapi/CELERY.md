# Celery Best Practices

Celery 5.6 / Python 3.12+.

## Contents

- Task design (explicit names, IDs not objects, idempotency)
- `acks_late` + visibility timeout
- Retries (`autoretry_for`, backoff, jitter)
- Time limits
- Never block on another task; canvas (chain/group/chord)
- Broker and result-backend choices
- Queues and routing
- Priorities
- Beat (scheduled tasks)
- Config hygiene and observability
- FastAPI integration
- `BackgroundTasks` vs Celery decision
- Testing

## Task Definition

```python
# BAD: implicit name — renaming the module silently breaks in-flight messages
@app.task
def send_email(user_id): ...

# BAD: passing ORM objects — not JSON-serializable, and data goes stale in the queue
@app.task
def send_welcome(user: User): ...

# GOOD: explicit name, small serializable payload, bind for self access
@app.task(
    bind=True,
    name="emails.send_welcome",
    acks_late=True,
    autoretry_for=(ConnectionError, TimeoutError),
    retry_backoff=True,
    retry_backoff_max=600,
    retry_jitter=True,
    max_retries=5,
)
def send_welcome(self, user_id: int) -> None:
    user = User.objects.get(pk=user_id)
    mailer.send(user.email, template="welcome")
```

- **`bind=True`** — gives the task `self` for `self.retry(...)` and `self.request`.
- **`name=...`** — pins the wire name so renames don't orphan queued messages.
- Payload is an `int`, not the whole row — the worker fetches fresh data.

## Idempotency + acks_late

`acks_late=True` acks *after* the task returns. If the worker crashes mid-run,
the broker redelivers and the task runs again — so tasks must be idempotent.

```python
# BAD: not idempotent + acks_late — a crash mid-charge double-charges the card
@app.task(acks_late=True)
def charge(order_id: int) -> None:
    order = Order.objects.get(pk=order_id)
    stripe.Charge.create(amount=order.total, source=order.token)
    order.status = "paid"
    order.save()

# GOOD: dedupe with an idempotency key + short-circuit on replay
@app.task(bind=True, acks_late=True, name="billing.charge")
def charge(self, order_id: int) -> None:
    with transaction.atomic():
        order = Order.objects.select_for_update().get(pk=order_id)
        if order.status == "paid":
            return  # replay — already done
        stripe.Charge.create(
            amount=order.total,
            source=order.token,
            idempotency_key=f"order-{order_id}",
        )
        order.status = "paid"
        order.save()
```

Global config to pair with this:

```python
app.conf.update(
    task_acks_late=True,
    task_reject_on_worker_lost=True,   # requeue on OOM / SIGKILL
    worker_prefetch_multiplier=1,      # fairness; no hoarding
    broker_transport_options={"visibility_timeout": 3600},  # > longest task
)
```

## Retries

```python
# BAD: bare except + manual retry with no cap — infinite loop on persistent failure
@app.task(bind=True)
def sync(self, id):
    try:
        do_work(id)
    except Exception as exc:
        self.retry(exc=exc)  # no countdown, no max_retries

# BAD: retrying on non-transient errors (ValidationError) — wastes workers
@app.task(bind=True, autoretry_for=(Exception,))
def sync(self, id): ...

# GOOD: retry only on transient errors, exclude the rest
@app.task(
    bind=True,
    autoretry_for=(ConnectionError, TimeoutError, RedisError),
    dont_autoretry_for=(ValidationError, PermissionDenied),
    retry_backoff=2,
    retry_backoff_max=300,
    retry_jitter=True,
    max_retries=5,
)
def sync(self, id): ...
```

`retry_jitter=True` prevents a thundering herd when many tasks retry at once.

## Time Limits

```python
# GOOD: soft limit lets the task clean up; hard limit kills runaway tasks
@app.task(soft_time_limit=25, time_limit=30)
def export(user_id: int) -> None:
    try:
        build_report(user_id)
    except SoftTimeLimitExceeded:
        cleanup_partial_files()
        raise
```

Keep `visibility_timeout > time_limit`, or a still-running task gets redelivered.

## Never Block on Another Task Inside a Task

```python
# BAD: deadlocks — worker waits for a result it may be responsible for producing
@app.task
def parent():
    result = child.delay().get(timeout=30)  # DON'T
    return process(result)

# GOOD: compose with a chain
from celery import chain

@app.task
def parent_entry():
    return chain(child.s(), process.s())()
```

## Canvas: chain / group / chord

```python
# BAD: launching tasks imperatively and collecting with .get() in a loop
results = [my_task.delay(i).get() for i in ids]

# GOOD: group runs in parallel, chord collects results into a callback
from celery import group, chord, chain

# pipeline: a -> b -> c
chain(fetch.s(url), parse.s(), store.s()).apply_async()

# fan-out / fan-in
chord((process.s(i) for i in ids), summarize.s()).apply_async()
```

Compose with **signatures** (`.s()`, `.si()`). `.si()` is the *immutable*
signature — it ignores the previous step's result.

## Broker and Result Backend

- **Redis** — simple, fast, common default. No native priorities beyond a basic
  scheme; visibility-timeout based redelivery.
- **RabbitMQ** — true priorities, robust routing, durable; heavier to operate.

```python
# GOOD: opt in to results only when you read them; never store large payloads
app.conf.update(
    task_ignore_result=True,   # default for all tasks
    result_expires=3600,       # auto-expire stored results
)

@app.task(ignore_result=False)   # opt in per task
def compute(x: int) -> int:
    return x * 2
```

Don't store DataFrames or file contents in the result backend — write to S3/DB
and return the key. The AMQP backend is especially bad here (one message per
result).

## Queues and Routing

```python
# GOOD: separate queues so slow jobs don't starve fast ones
from kombu import Queue

app.conf.task_routes = {
    "emails.*":  {"queue": "io"},
    "billing.*": {"queue": "critical"},
    "reports.*": {"queue": "slow"},
}
app.conf.task_queues = (
    Queue("critical", routing_key="critical"),
    Queue("io",       routing_key="io"),
    Queue("slow",     routing_key="slow"),
)
app.conf.task_default_queue = "default"
```

```bash
# run workers per queue so they scale independently
celery -A proj worker -Q critical -n critical@%h --concurrency=8
celery -A proj worker -Q slow     -n slow@%h     --concurrency=2
```

## Priorities

Priorities work on RabbitMQ and Redis, but the scales are **inverted**.

- **RabbitMQ**: `0` = lowest, `9` = highest.
- **Redis**: `0` = highest, `9` = lowest.

```python
send_welcome.apply_async(args=[user_id], priority=0)  # Redis: top priority
```

Lower `worker_prefetch_multiplier` (ideally `1`) for priorities to matter —
otherwise workers hoard low-priority tasks before high-priority ones arrive.

## Beat (Scheduled Tasks)

```python
from celery.schedules import crontab

# BAD: schedule without routing — lands on default queue, mixed with ad-hoc work
app.conf.beat_schedule = {
    "nightly-report": {"task": "reports.nightly", "schedule": crontab(hour=2)},
}

# GOOD: pin queue + expires so a stalled beat doesn't flood after recovery
app.conf.beat_schedule = {
    "nightly-report": {
        "task": "reports.nightly",
        "schedule": crontab(hour=2, minute=0),
        "options": {"queue": "slow", "expires": 60 * 60},
    },
}
```

Run **exactly one beat process** — two beats produce duplicate schedules. Use
`django-celery-beat` for HA or DB-backed schedules.

## Config Hygiene

```python
app.conf.update(
    broker_url=settings.broker_url,
    result_backend=settings.result_backend,
    task_serializer="json",            # never pickle in an untrusted env
    accept_content=["json"],
    result_serializer="json",
    timezone="UTC",
    enable_utc=True,
    broker_connection_retry_on_startup=True,
    task_track_started=True,           # exposes STARTED state
)
```

## Observability

```python
from celery.signals import task_failure, task_retry

@task_failure.connect
def on_failure(sender, task_id, exception, args, kwargs, **_) -> None:
    logger.exception("task.failed", extra={"task": sender.name, "id": task_id})
    sentry_sdk.capture_exception(exception)

@task_retry.connect
def on_retry(sender, reason, **_) -> None:
    logger.warning("task.retry %s: %s", sender.name, reason)
```

Run **Flower** (`celery -A proj flower`) for live worker, queue, and task
inspection.

## FastAPI Integration

Define the Celery `app` separately from the FastAPI `app`. Workers run as their
own processes — they survive API restarts and vice versa.

```python
# worker.py — the Celery app, imported by both workers and the API
from celery import Celery

celery_app = Celery("myproj", broker=settings.broker_url,
                     backend=settings.result_backend)
celery_app.autodiscover_tasks(["myapp.tasks"])

# routes.py — enqueue from a path operation, return a handle
from fastapi import APIRouter
from celery.result import AsyncResult

router = APIRouter()

@router.post("/reports", status_code=202)
async def create_report(user_id: int) -> dict[str, str]:
    result = generate_report.delay(user_id)  # returns immediately
    return {"task_id": result.id}

@router.get("/reports/{task_id}")
async def report_status(task_id: str) -> dict[str, str | None]:
    res = AsyncResult(task_id, app=celery_app)
    return {"state": res.state, "result": res.result if res.ready() else None}
```

Never call `.get()` on an `AsyncResult` inside a path operation — it blocks the
event loop. Return the id and let the client poll.

## BackgroundTasks vs Celery — Decision

`BackgroundTasks` (FastAPI built-in) runs work *in the same process* after the
response is sent. Celery runs work in *separate, durable* worker processes.

```python
# GOOD: BackgroundTasks — lightweight, fire-and-forget, no infra
from fastapi import BackgroundTasks

@router.post("/signup")
async def signup(data: SignupIn, background_tasks: BackgroundTasks):
    user = await create_user(data)
    background_tasks.add_task(send_welcome_email, user.email)  # fast, post-response
    return {"id": user.id}

# GOOD: Celery — heavy, retryable, status-tracked, survives API restarts
@router.post("/videos")
async def upload_video(file: UploadFile):
    key = await store(file)
    transcode_video.delay(key)  # minutes-long, needs retries + a broker
    return {"key": key}
```

Choose **`BackgroundTasks`** for lightweight, fast, fire-and-forget work —
notification emails, audit logs, cache invalidation. No retries, no result, no
status; it dies if the API process dies. Zero infrastructure.

Choose **Celery** for heavy or long work (video/image processing, reports, ML
inference), anything needing retries, status/result tracking, scheduled (beat)
jobs, fan-out, or guaranteed execution across API restarts. Requires a broker.

Recommended path: start with `BackgroundTasks`; migrate a hot path to Celery
once you need retries, durability, or it competes with request handling. The
migration is mechanical — move the body into a `@celery_app.task` and swap
`background_tasks.add_task(fn, x)` for `fn.delay(x)`.

Note: a `def` background task runs in the threadpool; an `async def` background
task runs on the event loop — a blocking call there stalls requests.

## Testing

```python
# GOOD: run tasks eagerly in unit tests — no broker needed
@pytest.fixture(autouse=True)
def celery_eager(settings) -> None:
    settings.CELERY_TASK_ALWAYS_EAGER = True
    settings.CELERY_TASK_EAGER_PROPAGATES = True

def test_charge_is_idempotent(order) -> None:
    charge.delay(order.id)
    charge.delay(order.id)  # replay
    assert Charge.objects.filter(order=order).count() == 1
```

For integration tests against a real broker, use `pytest-celery`.

## Rules

1. Explicit `name="domain.action"` on every task — never rely on auto-naming.
2. Pass IDs, not objects — payloads must be small, JSON-serializable, fetched fresh.
3. Tasks must be idempotent — pair with `acks_late=True` + `task_reject_on_worker_lost=True`.
4. Use `autoretry_for` with a narrow tuple — never `Exception`; always cap `max_retries`.
5. `retry_backoff=True` + `retry_jitter=True` — prevents thundering-herd retries.
6. Set `soft_time_limit` and `time_limit`; keep `visibility_timeout > time_limit`.
7. Never call `.get()` inside a task or a path operation — compose with canvas.
8. Separate queues by workload (critical / io / slow) with dedicated workers.
9. `worker_prefetch_multiplier=1` for priority queues and long tasks.
10. Ignore results by default; never store large payloads in the backend.
11. `task_serializer="json"`, `accept_content=["json"]` — never pickle untrusted input.
12. One beat process only; pin `queue` and `expires` on every scheduled task.
13. Use `BackgroundTasks` for light fire-and-forget work; Celery for heavy, retryable, or durable work.
