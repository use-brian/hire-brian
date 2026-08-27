# Native Outpost Debian setup

This directory installs the multi-user Outpost edition directly on Debian 12 or 13. Node.js services and PostgreSQL run as native processes managed by systemd. Docker, containers, and container networks are not used.

## Source prerequisite

By default, the installer clones the public `use-brian` repository at a configurable branch, tag, or commit. An existing source directory remains available for offline or prechecked installations. The installer validates Outpost-capable workspace manifests, builds a versioned release as the configured unprivileged service user, runs migrations, and atomically activates `/var/lib/use-brian-outpost/platform`.

Required source-tree markers include:

- `apps/api/package.json`
- `apps/auth-web/package.json`
- `apps/app-web/package.json`
- `apps/doc-sync/package.json`
- `packages/api/migrations/`
- Root `package.json`, `pnpm-lock.yaml`, and workspace configuration

## Install

```bash
sudo ./install.sh
```

The installer asks for:

- Dedicated service account name, defaulting to `brian`.
- Repository/ref or optional existing-directory source mode.
- Local PostgreSQL 18 with pgvector, or external owner and RLS-role URLs.
- Public HTTPS app, API, and auth origins plus the WSS doc-sync origin.
- An isolated cookie domain.
- Whether the TLS ingress sanitizes and supplies trusted client-IP headers.
- Email or OIDC authentication.
- Primary model provider and its required API key or cloud project.
- Optional headless LibreOffice for PDF output.
- Optional Chromium/Xfce virtual desktop with Xvfb and localhost-only VNC.
- Independent enable/disable choices for Discord, WhatsApp, WeChat, and Feishu connectors.
- The SSH port UFW must preserve.

It installs Node.js 22, pnpm 10.33.0, build tools, ffmpeg, PostgreSQL client tools, fonts, and optional PostgreSQL/LibreOffice packages through apt.

Supported provider choices are `gemini` (API key), `dashscope` (API key plus optional base URL), `vertex` (project/location with ADC or an optional service-account JSON supplied through the environment), and `openai-codex` (interactive account sign-in after installation, no API key).

At the end, choose `default` reverse proxy setup to install Caddy, configure app/API/auth/doc-sync routing, enable automatic TLS and WebSockets, and allow host ports 80/443. Choose `custom` to leave ingress unchanged. The cloud security group and DNS remain provider-level configuration and must allow/resolve ports 80/443 to this host.

## Native services

| Unit | Port | Process |
| --- | ---: | --- |
| `use-brian-outpost-api` | 4000 | API and in-process workers |
| `use-brian-outpost-auth` | 3005 | Authentication portal |
| `use-brian-outpost-app` | 3003 | Product web app |
| `use-brian-outpost-doc-sync` | 8080 | Collaborative document sync |
| `use-brian-outpost-discord` | 8090 | Optional Discord connector |
| `use-brian-outpost-whatsapp` | 8091 | Optional WhatsApp connector |
| `use-brian-outpost-browser-relay` | 8092 | Browser relay |
| `use-brian-outpost-wechat` | 8093 | Optional WeChat connector |
| `use-brian-outpost-feishu` | 8095 | Optional Feishu connector |
| `use-brian-outpost-browser-desktop` | 5901 localhost | Optional Chromium virtual desktop |

Every unit runs under the configured unprivileged service account with systemd filesystem protections, memory limits, automatic restart, per-service environment files, and journald logging. Releases, files, browser profiles, and build state are owned by that account.

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

For repository mode, update to the configured ref with:

```bash
sudo outpost-update
sudo outpost-doctor
sudo journalctl -u use-brian-outpost-api -f
```

`outpost-update [ref-or-source-directory]` clones the configured ref or stages the configured directory, performs a frozen install and filtered production build, stops writers, runs migrations, atomically switches the release symlink, starts enabled services, and runs health checks. Disabled connectors are excluded from service lifecycle and diagnostics.

Back up PostgreSQL and `/var/lib/use-brian-outpost/files` before updates. Application listeners remain behind UFW; provide a TLS reverse proxy or outbound tunnel with WebSocket support.
