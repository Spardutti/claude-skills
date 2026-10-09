# Production Compose

A local stack and a production stack want opposite things. Locally, a stopped
container stays stopped. On a server, it comes back by itself. Keep them in two
files so neither setting leaks into the other.

## Contents

- [Two Files](#two-files)
- [The Production Stack](#the-production-stack)
- [Restart, Init, Limits, Logs](#restart-init-limits-logs)
- [Runtime Secrets](#runtime-secrets)
- [Migrations Run Once, Before the App](#migrations-run-once-before-the-app)
- [The App Gets Its Own Database User](#the-app-gets-its-own-database-user)
- [Backups](#backups)
- [Rules](#rules)

## Two Files

```
compose.yaml        local: watch, published db port, no restart policy
compose.prod.yaml   server: restart, limits, logs, secrets, proxy
```

```bash
docker compose up                          # local
docker compose -f compose.prod.yaml up -d  # server
```

```yaml
# BAD — restart in the shared file; the laptop restarts the stack on every boot
services:
  db:
    image: postgres:18
    restart: unless-stopped
```

## The Production Stack

```yaml
x-defaults: &defaults
  restart: unless-stopped
  init: true
  logging:
    driver: json-file
    options: { max-size: "10m", max-file: "3" }

services:
  proxy:
    <<: *defaults
    image: caddy:2-alpine
    ports: ["80:80", "443:443"]
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
    depends_on: [app]

  migrate:
    image: ghcr.io/acme/app:1.4.2
    command: ["node", "dist/migrate.js"]
    restart: "no"
    secrets: [db_owner_password]
    depends_on:
      db: { condition: service_healthy }

  app:
    <<: *defaults
    image: ghcr.io/acme/app:1.4.2
    secrets: [app_db_password]
    deploy:
      resources:
        limits: { memory: 256M }
    depends_on:
      migrate: { condition: service_completed_successfully }

  db:
    <<: *defaults
    image: postgres:18-alpine
    volumes:
      - pgdata:/var/lib/postgresql
      - ./db/init:/docker-entrypoint-initdb.d:ro
    environment:
      POSTGRES_DB: app
      POSTGRES_PASSWORD_FILE: /run/secrets/db_owner_password
    secrets: [db_owner_password, app_db_password]
    deploy:
      resources:
        limits: { memory: 512M }
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d app"]
      interval: 5s
      retries: 5

secrets:
  db_owner_password: { file: ./secrets/db_owner_password }
  app_db_password: { file: ./secrets/app_db_password }

volumes:
  pgdata:
  caddy_data:
```

Only the proxy publishes ports. The app and the database are reachable on the
Compose network and nowhere else. Run an image built and tagged in CI, not
`build:` on the server.

## Restart, Init, Limits, Logs

```yaml
# BAD — each one is a separate outage waiting to happen
app:
  image: ghcr.io/acme/app:latest   # which version is running? nobody knows
  # no restart:   a crash at 3am stays down until someone notices
  # no init:      zombie processes pile up; SIGTERM may never reach node
  # no limit:     one leak takes the database down with it
  # no log cap:   json-file grows until the disk is full
```

- `restart: unless-stopped` comes back after a crash or a reboot, but not after
  you ran `docker compose stop`.
- `init: true` puts a tiny init as PID 1 to reap zombies and forward signals.
- A memory limit makes a leak kill one container, not the whole server.
- `max-size` × `max-file` is the most disk one service's logs can ever use.

## Runtime Secrets

```yaml
# BAD — visible in `docker inspect`, in the process env, and in every crash dump
environment:
  DATABASE_URL: postgres://app:hunter2@db/app
```

```yaml
# GOOD — mounted as a file at /run/secrets/<name>
secrets: [app_db_password]
```

```ts
const password = readFileSync("/run/secrets/app_db_password", "utf8").trim();
```

Official images read `*_FILE` variables (`POSTGRES_PASSWORD_FILE`). Keep
`secrets/` out of git and out of the build context.

## Migrations Run Once, Before the App

```yaml
# BAD — every replica races to migrate on boot; a failed migration still starts the app
app:
  command: sh -c "node dist/migrate.js && node dist/index.js"
```

The `migrate` service above runs once and exits. The app waits for
`service_completed_successfully`, so a failed migration means the old version
keeps running and the new one never starts. Migrations run as the database owner;
the app does not.

## The App Gets Its Own Database User

The `postgres` user is a superuser. Superusers skip row-level security without
an error or a warning. So do table owners, unless the table has
`FORCE ROW LEVEL SECURITY`.

```sh
# db/init/01-app-role.sh — runs only when the volume is empty
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<SQL
CREATE ROLE app LOGIN NOSUPERUSER NOBYPASSRLS
  PASSWORD '$(cat /run/secrets/app_db_password)';
GRANT USAGE ON SCHEMA public TO app;
ALTER DEFAULT PRIVILEGES FOR ROLE $POSTGRES_USER IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app;
SQL
```

The app connects as `app`. Migrations connect as the owner. Init scripts never
run again on an existing volume, so a role added later goes in a migration.

## Backups

A volume is not a backup. A backup is a dump on another machine that you have
restored at least once.

```bash
# host crontab, hourly — the % must be escaped in cron
0 * * * * docker compose -f /srv/app/compose.prod.yaml exec -T db \
  pg_dump -U postgres -Fc app > /srv/backups/app-$(date +\%F-\%H).dump
```

Then copy `/srv/backups` off the server (restic, rclone, or the provider's object
storage), and prune old dumps on both sides.

Once a month, restore the newest dump into a throwaway container and run a query
against it:

```bash
docker run -d --name restore-test -e POSTGRES_PASSWORD=x postgres:18-alpine
docker exec -i restore-test pg_restore -U postgres -d postgres --create < latest.dump
```

A dump nobody has restored is a guess.

## Rules

- Always keep production settings in `compose.prod.yaml`; never put `restart:` in the local `compose.yaml`.
- Always set `restart: unless-stopped`, `init: true`, a memory limit, and capped logs on every long-running production service.
- Always pin the production image to a version tag, never `latest`.
- Always publish ports only on the reverse proxy.
- Always pass secrets as files under `/run/secrets`, never as plain `environment:` values.
- Always run migrations as a one-shot service that the app waits on with `service_completed_successfully`.
- Never let the app connect as a superuser or a table owner; give it a role with `NOSUPERUSER NOBYPASSRLS`.
- Always copy backups off the server and test a restore every month.
