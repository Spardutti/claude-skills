---
name: docker-best-practices
category: Backend
description: "MUST USE when writing or editing Dockerfiles, docker-compose.yml, .dockerignore, or container configuration. Enforces multi-stage builds, layer caching, security hardening, Compose Watch for local dev, and health checks."
---

# Docker Best Practices

## Multi-Stage Builds

Separate build dependencies from runtime. Ship only what you need.

```dockerfile
# BAD: build tools, devDependencies, and source all ship to production
FROM node:20
WORKDIR /app
COPY . .
RUN npm ci && npm run build
CMD ["node", "dist/index.js"]

# GOOD: multi-stage — clean production image
FROM node:20-slim AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM node:20-slim
WORKDIR /app
COPY --from=build /app/dist ./dist
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/package.json ./
USER node
CMD ["node", "dist/index.js"]
```

```dockerfile
# GOOD: Go with distroless — ~2 MiB final image
FROM golang:1.22 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /app ./cmd/server

FROM gcr.io/distroless/static-debian12
COPY --from=build /app /app
USER nonroot:nonroot
ENTRYPOINT ["/app"]
```

## Layer Caching

Order instructions from **least-frequently changed to most-frequently changed**.

```dockerfile
# BAD: every code change reinstalls dependencies
COPY . .
RUN pip install -r requirements.txt

# GOOD: deps cached unless requirements.txt changes
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
```

```dockerfile
# BAD: separate RUN commands — extra layers, stale apt cache
RUN apt-get update
RUN apt-get install -y curl git

# GOOD: single layer, sorted packages, cache cleaned
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*
```

## Security — Non-Root User

```dockerfile
# BAD: runs as root
FROM node:20-slim
WORKDIR /app
COPY . .
CMD ["node", "server.js"]

# GOOD: non-root user
FROM node:20-slim
WORKDIR /app
COPY --chown=node:node package*.json ./
RUN npm ci --omit=dev
COPY --chown=node:node . .
USER node
CMD ["node", "server.js"]
```

## COPY --chown, Not RUN chown

Docker's copy-on-write stores files in **two layers** if you chown after COPY.

```dockerfile
# BAD: files duplicated across two layers — doubles size
COPY . /app
RUN chown -R app:app /app

# GOOD: ownership set during copy — single layer
COPY --chown=app:app . /app
```

```dockerfile
# BAD                              # GOOD
COPY entrypoint.sh /entrypoint.sh  COPY --chmod=755 entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
```

## Build Secrets

`ARG` and `ENV` persist in image layers. Use `--mount=type=secret`.

```dockerfile
# BAD: secret baked into image (visible via docker history)
ARG NPM_TOKEN
RUN echo "//registry.npmjs.org/:_authToken=${NPM_TOKEN}" > .npmrc && \
    npm ci && rm .npmrc  # too late — it's in a previous layer

# GOOD: secret mounted temporarily, never persisted
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc npm ci
# Build: docker build --secret id=npmrc,src=$HOME/.npmrc .
```

## CMD — Exec Form

```dockerfile
# BAD: shell form — PID 1 is /bin/sh, app doesn't receive SIGTERM
CMD npm start

# GOOD: exec form — app is PID 1, receives signals properly
CMD ["node", "server.js"]
```

## Base Images — Pin Versions

```dockerfile
# BAD: non-reproducible
FROM node:latest

# GOOD: pinned slim image
FROM node:20.11-slim
```

Use `<lang>-slim` for most apps. Use `distroless/static` or `scratch` for static binaries (Go, Rust).

## .dockerignore

Always create one. Without it, `.git`, `node_modules`, `.env` enter the build context.

```
.git
node_modules
dist
*.md
.env*
.vscode
__pycache__
*.pyc
docker-compose*.yml
Dockerfile*
```

## Health Checks

```yaml
# In Compose — use with depends_on for startup ordering
services:
  db:
    image: postgres:16
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5

  api:
    build: .
    depends_on:
      db:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
```

## Compose Watch — Local Dev

Replaces bind mount hacks. One-way sync from host to container: **sync** (hot reload), **sync+restart** (config changes), **rebuild** (dependency changes).

```yaml
# BAD: bidirectional bind mount — can clobber node_modules
services:
  web:
    build: .
    volumes:
      - .:/app
      - /app/node_modules  # anonymous volume hack

# GOOD: Compose Watch with granular rules
services:
  web:
    build: .
    command: npm run dev
    develop:
      watch:
        - action: sync
          path: ./src
          target: /app/src
          ignore:
            - node_modules/
        - action: sync+restart
          path: ./config
          target: /app/config
        - action: rebuild
          path: package.json
```

Start with: `docker compose watch`

### Full Local Dev Stack

```yaml
services:
  api:
    build: .
    ports:
      - "8000:8000"
    env_file: .env
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    develop:
      watch:
        - action: sync
          path: ./src
          target: /app/src
        - action: rebuild
          path: requirements.txt

  db:
    image: postgres:16
    volumes:
      - pgdata:/var/lib/postgresql/data
    environment:
      POSTGRES_DB: app
      POSTGRES_USER: app
      POSTGRES_PASSWORD: localdev
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U app"]
      interval: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      retries: 5

volumes:
  pgdata:
```

## Rules

1. **Always use multi-stage builds** — separate build from runtime
2. **Copy dependency files before source code** — maximize layer caching
3. **Never run as root** — add `USER` directive in every Dockerfile
4. **Use `COPY --chown`** — never `COPY` then `RUN chown`
5. **Never bake secrets into layers** — use `--mount=type=secret`
6. **Use exec form** for CMD and ENTRYPOINT — `["binary", "arg"]`
7. **Pin base image versions** — never use `latest`
8. **Always create `.dockerignore`** — exclude .git, node_modules, .env
9. **Add health checks** — use with `depends_on: condition: service_healthy`
10. **Use Compose Watch for local dev** — not bind mount volume hacks
