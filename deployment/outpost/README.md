# Native Outpost Debian setup

This directory installs the multi-user Outpost edition directly on Debian 12 or 13. Node.js services and PostgreSQL run as native processes managed by systemd. Docker, containers, and container networks are not used.

## Source prerequisite

The operator supplies an updated standalone `use-brian` source tree on the host. The installer validates its Outpost-capable workspace manifests, builds a versioned release as the unprivileged `brian-outpost` user, runs its open migrations in Outpost mode, and atomically activates `/var/lib/use-brian-outpost/platform`.

Required source-tree markers include:

- `apps/api/package.json`
- `apps/auth-web/package.json`
- `apps/app-web/package.json`
- `apps/doc-sync/package.json`
- `packages/api/migrations/`
- Root `package.json`, `pnpm-lock.yaml`, and workspace configuration

## Install

```bash
sudo env OUTPOST_SOURCE_DIR=/srv/use-brian-outpost-source ./install.sh
```

The installer asks for:

- Local PostgreSQL 18 with pgvector, or external owner and RLS-role URLs.
- Public HTTPS app, API, and auth origins plus the WSS doc-sync origin.
- An isolated cookie domain.
- Whether the TLS ingress sanitizes and supplies trusted client-IP headers.
- Email or OIDC authentication.
- Primary model provider and its required API key or cloud project.
- Optional headless LibreOffice for PDF output.
- Optional Chromium/Xfce virtual desktop with Xvfb and localhost-only VNC.
- The SSH port UFW must preserve.

It installs Node.js 22, pnpm 10.33.0, build tools, ffmpeg, PostgreSQL client tools, fonts, and optional PostgreSQL/LibreOffice packages through apt.

Supported provider choices are `gemini` (API key), `dashscope` (API key plus optional base URL), `vertex` (project/location with ADC or an optional service-account JSON supplied through the environment), and `openai-codex` (interactive account sign-in after installation, no API key).

## Native services

| Unit | Port | Process |
| --- | ---: | --- |
| `use-brian-outpost-api` | 4000 | API and in-process workers |
| `use-brian-outpost-auth` | 3005 | Authentication portal |
| `use-brian-outpost-app` | 3003 | Product web app |
| `use-brian-outpost-doc-sync` | 8080 | Collaborative document sync |
| `use-brian-outpost-discord` | 8090 | Discord connector |
| `use-brian-outpost-whatsapp` | 8091 | WhatsApp connector |
| `use-brian-outpost-browser-relay` | 8092 | Browser relay |
| `use-brian-outpost-wechat` | 8093 | WeChat connector |
| `use-brian-outpost-feishu` | 8095 | Feishu connector |
| `use-brian-outpost-browser-desktop` | 5901 localhost | Optional Chromium virtual desktop |

Every unit runs under the unprivileged `brian-outpost` account with systemd filesystem protections, memory limits, automatic restart, per-service environment files, and journald logging.

When selected, the installer builds and loads the Use Brian Chromium extension, stores the browser profile under `/var/lib/use-brian-outpost/chromium`, and binds VNC only to localhost. Connect through SSH:

```bash
ssh -L 5901:127.0.0.1:5901 user@SERVER_IP
vncviewer 127.0.0.1:5901
```

## Database

Production uses two PostgreSQL roles:

- `DATABASE_URL`: owner role for migrations and system operations.
- `DATABASE_URL_APP`: distinct `NOSUPERUSER`, `NOBYPASSRLS` role for user-scoped queries.

Local setup installs PostgreSQL 18 and pgvector natively, creates both roles, and applies current/default privileges after migration. External URLs must enforce TLS and use PostgreSQL 18 with `vector` and `pg_trgm` installed.

This installer provisions a fresh Outpost database entirely from standalone `use-brian`.

## Updates

Update the supplied source tree, then run:

```bash
sudo outpost-update
sudo outpost-doctor
sudo journalctl -u use-brian-outpost-api -f
```

`outpost-update [source-directory]` stages a new release, performs a frozen install and filtered production build, stops writers, runs open and Outpost migrations, atomically switches the release symlink, starts the API through a readiness gate, starts dependent services, and runs health checks. Failed health checks restore the previous code release when available. Database migrations are forward-only and are not rolled back.

Back up PostgreSQL and `/var/lib/use-brian-outpost/files` before updates. Application listeners remain behind UFW; provide a TLS reverse proxy or outbound tunnel with WebSocket support.
