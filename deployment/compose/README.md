# Docker Compose OSS deployment

This target installs the public Use Brian OSS edition as containers. It is an
alternative to `deployment/oss/install.sh`, not an additional layer on top of
the native systemd installation. Do not run both against the same database.

The core API and app-web image is built from `BRIAN_REPO` at `BRIAN_REF` so the
browser-facing URLs can be embedded during the Next.js build. Doc sync, browser
relay, and the channel connectors use versioned images from
`ghcr.io/use-brian`. PostgreSQL 18, migrations, RLS grants, and Caddy HTTPS are
part of the stack.

## Requirements

- An amd64 Linux host with at least 4 CPU, 8 GB RAM, and 30 GB free disk.
- Docker Engine 24 or newer with Docker Compose v2.
- Ports TCP 80/443 and UDP 443 open to the host.
- Four DNS names pointing to the host: app, API, document sync, and browser
  relay. They must be distinct and share one cookie-domain suffix. Caddy
  obtains and renews their TLS certificates.
- Anonymous pull access to the `ghcr.io/use-brian` component packages. After
  the first CI publish, an organization owner must make each package public.
  For private packages, pass `GHCR_USERNAME` and a read-packages `GHCR_TOKEN`
  to `install.sh`.

The published component images currently target amd64. Use the native OSS
installer for arm64 hosts.

## Install

From a clone of `hire-brian`:

```bash
cd deployment/compose
APP_DOMAIN=app.example.com \
API_DOMAIN=api.example.com \
DOC_SYNC_DOMAIN=docs.example.com \
RELAY_DOMAIN=relay.example.com \
COOKIE_DOMAIN=.example.com \
./install.sh
```

The installer creates a mode-`0600` `.env`, generates independent database,
JWT, connector, and encryption secrets, builds the selected Use Brian ref, and
starts the stack. It prints a generated owner password once; Caddy requires
that credential on the owner-session route and blocks direct public access to
the backend token endpoint. When run interactively, omitted hostnames and the
cookie domain are prompted for. The default model path is ChatGPT/Codex sign-in
from Settings; set
`USEBRIAN_PREFERRED_PROVIDER=gemini GEMINI_API_KEY=...` before running the
installer to start with Gemini instead.

For a manual install:

```bash
cp .env.example .env
# Set domains and replace every replace-* value.
# Generate OWNER_PASSWORD_HASH with:
# docker run --rm caddy:2-alpine caddy hash-password --plaintext 'choose-a-password'
chmod 600 .env
docker compose up -d --build
```

Open `https://$APP_DOMAIN` after `api` and `doc-sync` report healthy and the
`caddy` container is running. Enter the owner credential when the browser first
opens the session route. The first build clones and compiles the core
application and can take several minutes.

## Services

| Service | Exposure | Purpose |
|---|---|---|
| `postgres` | Compose network only | PostgreSQL 18 with pgvector |
| `migrate` | One-shot | Forward-only OSS schema migrations |
| `grant-app-role` | One-shot | Grants the non-owner RLS role after migrations |
| `api` | Caddy at `API_DOMAIN` | API and background workers |
| `app-web` | Caddy at `APP_DOMAIN` | Product web app |
| `doc-sync` | Caddy at `DOC_SYNC_DOMAIN` | Collaborative document WebSockets |
| `browser-relay` | Caddy at `RELAY_DOMAIN` | Browser extension WebSocket relay |
| `discord-connector` | Compose network only | Discord Gateway connector |
| `wa-connector` | Compose network only | WhatsApp connector |
| `wechat-connector` | Compose network only | WeChat connector |
| `feishu-connector` | Compose network only | Feishu/Lark connector |
| `caddy` | Host ports 80/443 | Automatic HTTPS and reverse proxy |

## Operations

```bash
docker compose ps
docker compose logs -f api
docker compose logs -f caddy
docker compose restart api
```

To update, edit `BRIAN_REF` and `BRIAN_IMAGE_TAG` in `.env`. Pin both to a
release tag for reproducibility. Rebuild the source image without the cached
Git fetch, pull all upstream images, and recreate the services. Back up the
volumes first, especially before a PostgreSQL image update:

```bash
docker compose build --pull --no-cache migrate
docker compose pull postgres caddy doc-sync browser-relay discord-connector wa-connector wechat-connector feishu-connector
docker compose up -d
```

The `postgres-data`, `brian-data`, and `whatsapp-data` volumes are durable.
Back them up together with `.env`; losing `.env` makes encrypted connector and
browser credentials unrecoverable. Caddy certificate state lives in
`caddy-data` and can be regenerated from DNS.

Removing containers does not remove data. `docker compose down -v` permanently
deletes the database and application volumes and must only be used when the
installation is intentionally being destroyed.
