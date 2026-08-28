# Native Outpost Debian setup

This directory installs the multi-user Outpost edition directly on Debian 12 or 13. Node.js services and PostgreSQL run as native processes managed by systemd. Docker, containers, and container networks are not used.

## Source prerequisite

`OUTPOST_SOURCE_MODE` defaults to `repository`. It clones `BRIAN_REPO` (default `https://github.com/use-brian/use-brian.git`) and checks out `BRIAN_REF` (default `main`) as a detached branch, tag, or commit. Directory mode stages absolute `OUTPOST_SOURCE_DIR` with `rsync`.

Required source-tree markers include:

- `apps/api/package.json`
- `apps/auth-web/package.json`
- `apps/app-web/package.json`
- `apps/doc-sync/package.json`
- `apps/discord-connector/package.json`
- `apps/wa-connector/package.json`
- `apps/browser-relay/package.json`
- `apps/browser-extension/package.json`
- `apps/wechat-connector/package.json`
- `apps/feishu-connector/package.json`
- `packages/api/migrations/`
- Root `package.json`, `pnpm-lock.yaml`, `pnpm-workspace.yaml`, and `turbo.json`

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
- For email authentication, the SMTP host, port, TLS mode, account, password,
  and visible From address. Use `SMTP_SECURE=false` for STARTTLS (normally port
  587) or `SMTP_SECURE=true` for implicit TLS (normally port 465).
- Primary model provider and its required API key or cloud project.
- Optional headless LibreOffice for PDF output.
- Optional Chromium/Xfce virtual desktop with Xvfb and localhost-only VNC.
- Independent enable/disable choices for Discord, WhatsApp, WeChat, and Feishu connectors.
- The SSH port UFW must preserve.

It installs Node.js 22, pnpm 10.33.0, build tools, ffmpeg, PostgreSQL client tools, fonts, and optional PostgreSQL/LibreOffice packages through apt. Release builds run serially to limit peak memory use; provision at least 8 GB RAM as documented by the Terraform configurations, and add swap before installation on memory-constrained hosts.

Important defaults are `BRIAN_USER=brian`, `OUTPOST_SOURCE_MODE=repository`, `INSTALL_POSTGRES=yes`, `INSTALL_LIBREOFFICE=yes`, `INSTALL_BROWSER=no`, all four `ENABLE_*` connector values `yes`, and `REVERSE_PROXY_SETUP=default`. For noninteractive installation set `NONINTERACTIVE=1` and pass variables from `outpost.env.example` through `sudo env`; the installer does not read that file automatically.

Email authentication defaults to `SMTP_HOST=smtp.gmail.com`, `SMTP_PORT=587`,
and `SMTP_SECURE=false`, but accepts any authenticated SMTP submission server.
Existing noninteractive installs may still supply `GMAIL_SMTP_USER` and
`GMAIL_SMTP_APP_PASSWORD`; the installer maps them to the generic credential
names when `SMTP_USER` and `SMTP_PASSWORD` are absent.

`MODEL_PROVIDER` defaults to `gemini`. Gemini uses `GEMINI_API_KEY`; DashScope uses `DASHSCOPE_API_KEY` plus optional `DASHSCOPE_BASE_URL`; Vertex uses `VERTEX_PROJECT_ID`, `VERTEX_LOCATION` (default `asia-east2`), and optional compact `VERTEX_SERVICE_ACCOUNT_JSON`; OpenAI Codex stores the preference without a key and is authorized through the deployed Brian provider flow.

`REVERSE_PROXY_SETUP=default` installs Caddy, requires distinct app/API/auth/doc-sync hostnames, enables automatic TLS/WebSockets, and opens UFW 80/443. `custom` leaves Caddy and HTTP/HTTPS UFW rules unchanged. DNS and cloud firewall rules remain operator responsibilities.

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

`INSTALL_BROWSER` defaults to `no`. When enabled, `VNC_PASSWORD` is generated if omitted and must be at most eight characters. The profile is stored under `/var/lib/use-brian-outpost/chromium`; connect through SSH:

```bash
ssh -L 5901:127.0.0.1:5901 user@SERVER_IP
vncviewer 127.0.0.1:5901
```

## Database

Production uses two PostgreSQL roles:

- `DATABASE_URL`: owner role for migrations and system operations.
- `DATABASE_URL_APP`: distinct `NOSUPERUSER`, `NOBYPASSRLS` role for user-scoped queries.

Local setup installs PostgreSQL 18 and pgvector, creates both roles, and grants current/default privileges. External URLs should enforce TLS with `sslmode=require`, `verify-ca`, or `verify-full`, target the same PostgreSQL 18.x database with distinct roles, and have `vector`/`pg_trgm`. If either URL does not enforce TLS, the installer requires explicit approval; noninteractive installs must set `ALLOW_INSECURE_EXTERNAL_POSTGRES=yes`. The application role must be unprivileged and inherit no privileged role; the owner must be able to grant object privileges.

This installer provisions a fresh Outpost database entirely from standalone `use-brian`.

## Updates

For repository mode, update to the configured ref with:

```bash
sudo outpost-update
sudo outpost-update BRANCH_OR_TAG_OR_COMMIT       # repository mode
sudo outpost-update /absolute/source/directory    # directory mode
sudo outpost-doctor
sudo outpost-connectors status
sudo outpost-connectors enable discord
sudo outpost-connectors disable whatsapp
# Connector names: discord, whatsapp, wechat, feishu
sudo systemctl status 'use-brian-outpost-*'
sudo journalctl -u use-brian-outpost-api -f
```

`outpost-update [argument]` interprets its argument by persisted source mode: branch/tag/commit for repository mode or an absolute directory for directory mode. With no argument it uses persisted `BRIAN_REF` or `OUTPOST_SOURCE_DIR`. Overrides apply to one run and do not modify `deploy.conf`.

Use `outpost-connectors status`, `outpost-connectors enable <connector>`, or `outpost-connectors disable <connector>`. Supported connector names are `discord`, `whatsapp`, `wechat`, and `feishu`.

Back up PostgreSQL and `/var/lib/use-brian-outpost/files` before updates. Default proxy mode publishes only Caddy on 80/443; application listeners remain protected by UFW. Custom mode requires operator-managed TLS/WebSocket ingress.
