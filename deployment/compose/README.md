# Docker Compose

Published-image deployment of Use Brian with PostgreSQL 18/pgvector. The default
OSS mode is a **local, loopback-only installation**, with no reverse proxy,
public 80/443 listeners, tunnel, or Basic Auth gate. Optional Outpost mode adds
`auth-web` and uses HTTPS supplied by **your external reverse proxy**.

Do not run this target and a native installer against the same database.
Both Compose modes use project `use-brian` and the same durable `postgres-data`,
`brian-data`, and `whatsapp-data` volumes. Switching modes does not migrate the
OSS owner's identity or transfer their data to an Outpost user/workspace.

## Release Requirements

This deployment consumes the official images published to GitHub Container
Registry (GHCR). Once a release is published, select its tag with
`BRIAN_IMAGE_TAG`; no application source checkout or local image build is needed.

- Docker Engine with Compose v2 supporting multiple `--env-file` flags and `up --wait`, plus Bash and Python 3 on the host.
- Access to matching `ghcr.io/use-brian/{api,app-web,doc-sync,browser-relay,discord-connector,wa-connector,wechat-connector,feishu-connector}` images. Prefer a release or `sha-*` tag in `BRIAN_IMAGE_TAG`.
- Outpost additionally uses `ghcr.io/use-brian/auth-web` at the same tag and source revision. The publishing workflow includes this image, and the deployment scripts pull and verify it along with the other selected services before stopping applications.
- The selected release must support runtime `PUBLIC_APP_URL`, `PUBLIC_API_URL`, `PUBLIC_DISPLAY_API_URL`, `PUBLIC_DOC_SYNC_URL`, and `PUBLIC_PRIMARY_AUTH_URL`. These are direct URLs, including scheme and local ports, not build-time hostname substitutions.
- Localhost deployment requires the app-web empty-cookie-domain fix `ff0ec379` in the selected release so the default empty `COOKIE_DOMAIN` works correctly.
- Outpost requires the primary auth redirect fix `ac41f62b` in the selected release so app-web redirects to the configured `PUBLIC_PRIMARY_AUTH_URL`.
- The selected Outpost release must include the auth portal cookie-domain fix accepting a portal such as `auth.example.com` with `COOKIE_DOMAIN=.example.com`. Configuration cannot fix an older release that rejects that combination. No second-level subdomains are needed.

The verifier checks every selected application image's OCI source-revision
label, including auth-web in Outpost mode. Matching labels do not prove runtime
feature support, image authenticity, working SMTP/OIDC credentials, or DNS/TLS.
Authenticate to GHCR separately with `docker login ghcr.io` if packages require
it; no registry credentials belong in the Compose examples.

## Local OSS Install

From this directory:

```bash
# Replace with an available matching published release/SHA tag.
BRIAN_IMAGE_TAG=sha-YOUR_RELEASE_REVISION bash ./install.sh oss
bash ./stack.sh oss ps
```

Open `http://localhost:3003`. The installer generates independent database,
JWT, connector and encryption secrets in a mode-`0600` `.env`. It refuses to
replace an existing `.env` or generate new keys over existing `use-brian`
volumes. It stages configuration for secret-safe validation before publishing
`.env`, then pulls and verifies images before touching running services.
If pulling fails, `.env` remains for retry; do not delete it or rotate its keys.

For manual configuration, copy `.env.example` to `.env`, replace every
`replace-*` value, pin the image tag, and `chmod 600 .env`. Database passwords
must be URI-safe (hex recommended); encryption keys must be base64-encoded
32-byte values. Single-quote values containing `$` to avoid interpolation.
Run `bash ./stack.sh oss check`, then `bash ./stack.sh oss up`.

| Service | Host Loopback Address |
| --- | --- |
| app-web | `127.0.0.1:3003` |
| API | `127.0.0.1:4000` |
| Doc sync | `127.0.0.1:8080` |
| Browser relay | `127.0.0.1:8094` |
| auth-web (Outpost only) | `127.0.0.1:3005` |

PostgreSQL and connectors have no host ports. Raw host ports stay loopback-only
in **both** modes. The default model path is ChatGPT/Codex sign-in from Settings;
optional model and app OAuth credentials can be configured in `.env`.

### Localhost My Browser Limitation

**My Browser does not work with the default `PUBLIC_RELAY_URL=http://localhost:8094`.**
Compose passes this value to the API as `BROWSER_RELAY_URL`. The current API uses
that same setting for its HTTP relay transport and the advertised browser
WebSocket URL; it has no separate internal/public relay settings. Inside the
API container, `localhost:8094` points to the API container itself, not the
host-published relay port. Changing it to `http://browser-relay:8080` would fix
API reachability but advertise a Compose-only hostname the user's browser
cannot reach.

Standard local OSS installation remains supported; preflight intentionally
allows this default and does not prove My Browser connectivity. To use My
Browser, set `PUBLIC_RELAY_URL` to a relay HTTPS origin, such as
`https://relay.example.com`, reachable by **both the API container and the
user's browser**. Your external proxy must route HTTP and WebSocket traffic to
the relay. The domain-based Outpost configuration below supports this path
when DNS, TLS and routing work from both clients. This target does not use host
networking or invent an unsupported internal/public URL split.

### OSS Owner Security

**Never publicly expose the OSS owner-session mint endpoints without external
protection.** app-web's `/api/auth/local-session` and the API's
`/auth/local-session` can mint the local owner's session. This target installs
no gate for either endpoint. Anyone with access to them may become the owner.
Loopback limits network access, not access by other local users/processes.

If exposing OSS via your own HTTPS proxy, protect the app-web owner-session
route and prevent unprotected direct access to the API mint route, including
equivalent route variants. Protect all alternate ingress paths. Set direct
`PUBLIC_*` HTTPS/WSS URLs and the shared cookie domain in `.env`; review your
own proxy/auth policy before enabling public access. The scripts validate URL
shape, not external protection. Local HTTP remains suitable only for localhost.

## Outpost And External HTTPS

Create `outpost.env` from `outpost.env.example`, `chmod 600 outpost.env`, and set
real values. This overlay contains public URLs and provider settings, not a
second copy of database or encryption keys. Example routing for your proxy:

| Public Origin | Upstream On This Host |
| --- | --- |
| `https://app.example.com` | `http://127.0.0.1:3003` |
| `https://api.example.com` | `http://127.0.0.1:4000` |
| `wss://docs.example.com` | `http://127.0.0.1:8080` (WebSocket upgrade) |
| `https://relay.example.com` | `http://127.0.0.1:8094` (support WebSockets) |
| `https://auth.example.com` | `http://127.0.0.1:3005` |

Use five distinct single-level sibling hosts and `COOKIE_DOMAIN=.example.com`.
Provide certificates and DNS, preserve the public host, and forward WebSocket
upgrades. The proxy must be able to reach host loopback; another container's
`127.0.0.1` is not this host. A remote proxy needs a separately secured transport,
not a change to wildcard public bindings. `TRUST_PROXY_HEADERS=false` is
intentional; auth-web uses its explicit canonical `AUTH_PORTAL_URL`.

Email login requires real bootstrap administrator mailbox addresses, SMTP
host/port, user/password, and an approved sender. OIDC requires registration
with a real issuer, client ID/secret, provider name and a persistent bridge
secret of at least 32 characters. Register
`https://auth.example.com/api/auth/oidc/callback` as the redirect URI. Enable at
least one provider; email can be disabled for OIDC-only setups. Invite-only
enrollment needs bootstrap emails; mapped enrollment must reference existing
workspace IDs and requires review of the provider's claims/mapping policy.
The empty example credentials deliberately fail preflight.

For a new Outpost installation:

```bash
BRIAN_IMAGE_TAG=sha-YOUR_RELEASE_REVISION bash ./install.sh outpost
```

For an existing Compose installation, retain `.env`, pin its image tag, back up
data, configure the external proxy/providers, then:

```bash
bash ./stack.sh outpost check
bash ./update.sh outpost
```

Outpost auth disables the local-session flow. Do not copy OSS testing proxy
rules or add a test Basic Auth gate. This is **not an automatic owner/data
migration**. Treat identity/workspace migration as a separate, explicitly
planned operation. Switching back with `bash ./update.sh oss` stops auth-web
and restores OSS local-owner behavior; remove/protect public OSS ingress first.

## Operations And Updates

Always pass the same mode to these scripts. OSS selects `.env` + `compose.yml`;
Outpost selects `.env`, then `outpost.env`, plus `compose.yml`,
`compose.outpost.yml`, and profile `outpost`. The edition is selected by the
wrapper, not a persisted dotenv mode. Both force project `use-brian` and ignore
ambient Compose file/profile/project selections. Ordinary exported application
variables still take precedence over dotenv values per Compose rules; avoid
stale shell overrides. Do not use bare `docker compose up` for updates or mode
switches: it bypasses validation, image verification and writer-stop ordering.

```bash
bash ./stack.sh oss check       # Validate only, no pull or stack changes
bash ./verify-images.sh oss     # Validate + inspect already-pulled images
bash ./stack.sh oss ps
bash ./stack.sh oss logs
# Back up, then edit BRIAN_IMAGE_TAG in .env to the desired release/SHA tag.
bash ./update.sh oss
# Substitute outpost consistently for Outpost deployments.
```

`stack.sh MODE up` resumes a configured installation with the same safe sequence
as `update.sh MODE`. Updates/resumes reject mutable `latest`, `main`, and
`develop` tags. The example permits `latest` for a first install only; pin a
release/SHA before retrying or updating. Tags other than these can also be
retagged by publishers; use a trusted immutable release policy.

The sequence is: validate configuration, pull selected images, verify matching
source revisions, stop **all** application writers (including optional auth-web
and old migration/grant jobs), wait for PostgreSQL, run migrations explicitly,
run grants explicitly, then recreate and wait for the selected applications.
`init-db.sh` creates the restricted app role on a new database;
`grant-app-role.sql` applies grants after every migration. Completed old Compose
jobs are not reused. Stop any writers outside this project yourself first.

If migration or grants fail, applications remain stopped. Keep command output
for diagnosis: migration/grant commands are one-shot `run --rm` containers, so
their logs are not retained after removal. Do not restart old code against a
partially advanced schema; investigate or restore the pre-update backup.
Application readiness failure after successful migrations needs separate
diagnosis and is not an automatic schema rollback.

Back up all three volumes together with `.env` and `outpost.env` securely before
updates. Losing encryption keys makes stored credentials unrecoverable. No
script deletes volumes, resets the database, performs owner migration, or
automatically rolls back forward-only migrations. PostgreSQL major upgrades
require a separate planned database migration.

### Older Compose Targets

For a prior source-built target, map `BRIAN_REF` to a matching published release
or SHA tag and set `BRIAN_IMAGE_TAG`; `BRIAN_REF` is no longer used. Preserve
the original database/encryption secrets and volume names. Translate the old
`*_DOMAIN` settings into direct `PUBLIC_*` URLs using these examples.

The old Caddy service is no longer part of this manifest. Preflight refuses an
active legacy `use-brian` Caddy container so it cannot silently remain as public
orphan ingress. Identify it with
`docker ps --filter label=com.docker.compose.project=use-brian --filter label=com.docker.compose.service=caddy`
and deliberately stop that container after planning replacement ingress.
No script deletes its old certificate volumes. Old owner Basic Auth settings
are unused and are not a substitute for external OSS protection.

## Offline Tests

```bash
bash -n common.sh install.sh stack.sh update.sh verify-images.sh init-db.sh
uv run --no-project --with pyyaml python test-config.py
```

Tests use synthetic configuration and mocked Docker, never real secret files
or a daemon. They check loopback defaults, shared mode/env/profile selection,
auth/provider wiring, image selection, fail-closed preflight, staged install
behavior, and update/migration/grant ordering. Live image availability,
runtime-public-config support, portal cookie behavior, DNS/TLS, provider
credentials, readiness and end-to-end login must be verified for your release.
