# Docker Compose OSS deployment

This target installs the public Use Brian OSS edition as containers. It is an
alternative to `deployment/oss/install.sh`, not an additional layer on top of
the native systemd installation. Do not run both against the same database.

API, app-web, doc sync, browser relay, and channel connectors use matching
versioned images from `ghcr.io/use-brian`. app-web reads its public domains from
the container environment and injects an allowlisted configuration into the
initial HTML, so the same image can run on different domains without rebuilding.
PostgreSQL 18, migrations, RLS grants, and Caddy HTTPS are part of the stack.

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
JWT, connector, and encryption secrets, pulls the selected image tag, and starts
the stack. It prints a generated owner password once; Caddy requires
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
# Database passwords must be URI-safe (hex is recommended).
# Generate OWNER_PASSWORD_HASH with:
# docker run --rm caddy:2-alpine caddy hash-password --plaintext 'choose-a-password'
# Keep the generated bcrypt hash inside single quotes in .env.
chmod 600 .env
docker compose pull
bash ./verify-images.sh
docker compose up -d
```

Open `https://$APP_DOMAIN` after `api` and `doc-sync` report healthy and the
`caddy` container is running. Enter the owner credential when the browser first
opens the session route.

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

To update, edit `BRIAN_IMAGE_TAG` in `.env`. Use a release or `sha-*` tag;
`update.sh` refuses mutable `latest`, `main`, and `develop` tags because updates
run forward-only migrations. Back up the volumes first, especially before a
PostgreSQL image update:

```bash
bash ./update.sh
```

The verifier compares the OCI source-revision label on every Use Brian image
and refuses a mixed application set under one tag.

`update.sh` pulls and verifies images before downtime, then stops Caddy and all
old application writers before migrations run. If migration or grant execution
fails, writers remain stopped. Inspect the migration logs and restore the
pre-update database backup when required; do not restart old code against a
partially advanced schema.

### Migrating from the source-built Compose target

Older Compose installations pinned core source with `BRIAN_REF` while
`BRIAN_IMAGE_TAG` selected only component images. The published-image target
ignores `BRIAN_REF`. Before the first update, map that source revision to a
published release or `sha-*` image tag and set `BRIAN_IMAGE_TAG` explicitly.

The `postgres-data`, `brian-data`, and `whatsapp-data` volumes are durable.
Back them up together with `.env`; losing `.env` makes encrypted connector and
browser credentials unrecoverable. Caddy certificate state lives in
`caddy-data` and can be regenerated from DNS.

Removing containers does not remove data. `docker compose down -v` permanently
deletes the database and application volumes and must only be used when the
installation is intentionally being destroyed.
