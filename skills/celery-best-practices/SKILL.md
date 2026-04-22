---
name: celery-best-practices
category: Backend
description: "MUST USE when writing or editing Celery tasks, workers, beat schedules, canvas workflows, or broker/backend config. Enforces idempotency, acks_late, autoretry with backoff, small payloads, routing, time limits, and correct canvas usage."
---

# Celery Best Practices

## Task Definition

```python
# BAD: implicit name — renaming the module silently breaks in-flight messages
@app.task
def send_email(user_id): ...

# BAD: passing ORM objects — not serializable, and data goes stale in the queue
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

- **`bind=True`** — gives the task `self` so it can call `self.retry(...)`, inspect `self.request`.
- **`name=...`** — pin the wire name so renames don't orphan queued messages.
- Payload is an `int`, not the whole row.

## Idempotency + acks_late

`acks_late=True` means "ack after the task returns." If the worker crashes mid-run, the broker redelivers, and the task runs again.

```python
# BAD: not idempotent + acks_late — a crash mid-charge double-charges the card
@app.task(acks_late=True)
def charge(order_id: int):
    order = Order.objects.get(pk=order_id)
    stripe.Charge.create(amount=order.total, source=order.token)
    order.status = "paid"
    order.save()

# GOOD: dedupe with an idempotency key + short-circuit on replay
@app.task(bind=True, acks_late=True, name="billing.charge")
def charge(self, order_id: int):
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

`retry_jitter=True` prevents thundering-herd when many tasks retry simultaneously.

## Time Limits

```python
# GOOD: soft limit lets the task clean up; hard limit kills runaway tasks
@app.task(soft_time_limit=25, time_limit=30)
def export(user_id: int):
    try:
        build_report(user_id)
    except SoftTimeLimitExceeded:
        cleanup_partial_files()
        raise
```

Set `visibility_timeout > time_limit`, or tasks get redelivered while still running.

## Never Block on Another Task Inside a Task

```python
# BAD: deadlocks — worker waits for a result it may be responsible for producing
@app.task
def parent():
    result = child.delay().get(timeout=30)  # DON'T
    return process(result)

# GOOD: use a chain or chord
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

Always use **signatures** (`.s()`, `.si()`) to compose. `.si()` is the *immutable* signature — ignores the previous step's result.

## Queues and Routing

```python
# GOOD: separate queues so slow jobs don't starve fast ones
app.conf.task_routes = {
    "emails.*":   {"queue": "io"},
    "billing.*":  {"queue": "critical"},
    "reports.*":  {"queue": "slow"},
}

app.conf.task_queues = (
    Queue("critical", routing_key="critical"),
    Queue("io",       routing_key="io"),
    Queue("slow",     routing_key="slow"),
)
app.conf.task_default_queue = "default"
```

Run workers per queue so they scale independently:

```bash
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

Lower `worker_prefetch_multiplier` (ideally `1`) for priorities to actually matter — otherwise workers hoard low-priority tasks first.

## Result Backend

```python
# BAD: storing every result forever fills the backend
# (AMQP backend is especially bad — one message per result)

# GOOD: opt in to results only when you read them
app.conf.update(
    task_ignore_result=True,        # default for all tasks
    result_expires=3600,            # auto-expire if a backend is used
)

@app.task(ignore_result=False)      # opt in per task
def compute(x): return x * 2
```

Don't store large payloads (DataFrames, file contents) in the result backend — write to S3/DB and return the key.

## Beat (Scheduled Tasks)

```python
# BAD: schedule without routing — lands on default queue, mixed with ad-hoc work
app.conf.beat_schedule = {
    "nightly-report": {"task": "reports.nightly", "schedule": crontab(hour=2)},
}

# GOOD: pin queue + name + expires so a stalled beat doesn't flood after recovery
app.conf.beat_schedule = {
    "nightly-report": {
        "task": "reports.nightly",
        "schedule": crontab(hour=2, minute=0),
        "options": {"queue": "slow", "expires": 60 * 60},
    },
}
```

Run **exactly one beat process.** Two beats = duplicate schedules. Use `django-celery-beat` if you need HA or DB-backed schedules.

## Config Hygiene

```python
app.conf.update(
    broker_url=settings.BROKER_URL,
    result_backend=settings.RESULT_BACKEND,
    task_serializer="json",            # never pickle in untrusted env
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
def on_failure(sender, task_id, exception, args, kwargs, **_):
    logger.exception("task.failed", extra={"task": sender.name, "id": task_id})
    sentry_sdk.capture_exception(exception)

@task_retry.connect
def on_retry(sender, reason, **_):
    logger.warning("task.retry %s: %s", sender.name, reason)
```

## Testing

```python
# GOOD: run tasks eagerly in unit tests — no broker needed
@pytest.fixture(autouse=True)
def celery_eager(settings):
    settings.CELERY_TASK_ALWAYS_EAGER = True
    settings.CELERY_TASK_EAGER_PROPAGATES = True

def test_charge_is_idempotent(order):
    charge.delay(order.id)
    charge.delay(order.id)  # replay
    assert Charge.objects.filter(order=order).count() == 1
```

For integration tests against a real broker, use `pytest-celery`.

## Rules

1. **Explicit `name="domain.action"`** on every task — never rely on auto-naming
2. **Pass IDs, not objects** — payloads must be small, JSON-serializable, and fetch-fresh
3. **Tasks must be idempotent** — pair with `acks_late=True` + `task_reject_on_worker_lost=True`
4. **Use `autoretry_for` with a narrow tuple** — never `Exception`, always cap `max_retries`
5. **`retry_backoff=True` + `retry_jitter=True`** — prevents thundering-herd retries
6. **Set `soft_time_limit` and `time_limit`** — and keep `visibility_timeout > time_limit`
7. **Never call `.get()` inside a task** — compose with `chain` / `group` / `chord` / signatures
8. **Separate queues by workload** — critical / io / slow — with dedicated workers
9. **`worker_prefetch_multiplier=1`** for priority queues and long tasks
10. **Ignore results by default** — opt in per task; never store large payloads in the backend
11. **`task_serializer="json"`, `accept_content=["json"]`** — never pickle untrusted input
12. **One beat process only** — pin `queue` and `expires` on every scheduled task
