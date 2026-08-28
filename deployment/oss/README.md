# OSS Debian deployment

`install.sh` provisions a Debian 12 or 13 host and deploys the public Use Brian OSS edition as native systemd services. It clones the public `use-brian/use-brian` repository and sets `USEBRIAN_EDITION=oss` and `NEXT_PUBLIC_USEBRIAN_EDITION=oss`.

Supported architectures are amd64 and arm64. The installer verifies systemd, Node.js 22, Git, curl, ffmpeg/ffprobe, PostgreSQL client tools, and `runuser` before deployment.

## Services

| Unit | Listener | Purpose |
| --- | --- | --- |
| `brian-api` | `4000` | API and in-process workers |
| `brian-app-web` | `3003` | Next.js application |
| `brian-doc-sync` | `8080` | Collaborative document WebSocket service |
| `brian-discord-connector` | `8090` | Optional Discord gateway connector |
| `brian-wa-connector` | `8091` | Optional WhatsApp connector |
| `brian-browser-relay` | `8092` | Browser extension relay |
| `brian-wechat-connector` | `8093` | Optional WeChat connector |
| `brian-feishu-connector` | `8095` | Optional Feishu connector |
| `brian-browser-desktop` | `5901` localhost | Optional Chromium/Xfce virtual desktop |

PostgreSQL may be installed locally or supplied externally. Production requires two connections: an owner URL for migrations and system operations (`DATABASE_URL`) and a non-owner, non-`BYPASSRLS` application-role URL (`DATABASE_URL_APP`).

## Install

```bash
sudo ./install.sh
```

For unattended installation, set all required values:

```bash
sudo env \
  NONINTERACTIVE=1 \
  BRIAN_USER=brian \
  INSTALL_POSTGRES=yes \
  INSTALL_BROWSER=no \
  INSTALL_LIBREOFFICE=yes \
  ENABLE_DISCORD=no \
  ENABLE_WHATSAPP=no \
  ENABLE_WECHAT=no \
  ENABLE_FEISHU=no \
  MODEL_PROVIDER=gemini \
  GEMINI_API_KEY=replace \
  APP_URL=https://app.example.com \
  API_URL=https://api.example.com \
  DOC_SYNC_PUBLIC_URL=wss://docs.example.com \
  REVERSE_PROXY_SETUP=default \
  ./install.sh
```

Change individual `ENABLE_*` values as required; each defaults to `yes`. `INSTALL_BROWSER` defaults to `no`; local PostgreSQL and LibreOffice default to `yes`.

When `INSTALL_POSTGRES=no`, set TLS-enforcing `DATABASE_URL` and `DATABASE_URL_APP` values for the same PostgreSQL 18 database. The owner must have `vector` and `pg_trgm` installed. The application role must be distinct, `NOSUPERUSER`, `NOBYPASSRLS`, inherit no privileged role, and have required object privileges.

`MODEL_PROVIDER` defaults to `gemini`. Gemini uses `GEMINI_API_KEY`; DashScope uses `DASHSCOPE_API_KEY` and optional `DASHSCOPE_BASE_URL`; Vertex uses `VERTEX_PROJECT_ID`, `VERTEX_LOCATION` (default `asia-east2`), and optional compact `VERTEX_SERVICE_ACCOUNT_JSON`; OpenAI Codex stores the preference without an API key and is authorized through the deployed Brian provider flow.

Discord, WhatsApp, WeChat, and Feishu are independently optional. A disabled connector is not configured in the API, enabled in systemd, restarted during updates, or checked by `brian-doctor`.

`REVERSE_PROXY_SETUP` defaults to `default`: it installs Caddy, requires distinct app/API/doc-sync hostnames, enables automatic TLS/WebSockets, and opens host UFW ports 80/443. `custom` leaves ingress unchanged. DNS and cloud firewall rules remain operator responsibilities.

External preflight expects TLS `sslmode=require`, `verify-ca`, or `verify-full`; PostgreSQL 18.x; `vector` and `pg_trgm`; the same database with distinct roles; and an application role that is `NOSUPERUSER`, `NOBYPASSRLS`, and inherits no privileged role. If either URL does not enforce TLS, the installer requires explicit approval; noninteractive installs must set `ALLOW_INSECURE_EXTERNAL_POSTGRES=yes`.

`INSTALL_LIBREOFFICE=yes` installs only the headless Writer, Calc, and Impress components. Brian invokes `soffice --headless` when exporting its documents, presentations, spreadsheets, or `renderPdf` output to PDF. It is not needed to start the services; select `no` if PDF generation is not required.

The public URLs must already be planned as `https://`/`wss://` origins because production authentication uses secure cookies. Leave `COOKIE_DOMAIN` empty for host-only cookies or set an isolated deployment domain such as `.client.example.com`; do not share a parent cookie domain between customers.

The first prompt selects the service account, defaulting to `brian`. `/etc/brian/brian.env` is `0640` with that service group. After editing it, restart only affected enabled services, for example `sudo systemctl restart brian-api brian-app-web`, then run `sudo brian-doctor`.

## Operations

```bash
sudo brian-doctor
sudo brian-update
sudo brian-update BRANCH_OR_TAG_OR_COMMIT
sudo brian-connectors status
sudo brian-connectors enable discord
sudo brian-connectors disable whatsapp
# Connector names: discord, whatsapp, wechat, feishu
sudo systemctl status 'brian-*'
sudo journalctl -u brian-api -f
```

`brian-update [git-ref]` uses persisted `BRIAN_REF` when omitted. A branch, tag, or commit argument overrides it for that run only. It does not rewrite `/etc/brian/deploy.conf`.

Use `brian-connectors status`, `brian-connectors enable <connector>`, or `brian-connectors disable <connector>`.

## Browser desktop

`INSTALL_BROWSER` defaults to `no`. When enabled, `VNC_PASSWORD` is generated if omitted and must be at most eight characters. Connect through SSH:

```bash
ssh -L 5901:127.0.0.1:5901 SSH_USER@SERVER_IP
vncviewer 127.0.0.1:5901
```

## Public ingress

The installer first permits SSH in UFW. Default proxy setup also opens 80/443 and routes app/API/doc-sync to loopback ports 3003/4000/8080. Custom mode leaves HTTP/HTTPS ingress to the operator. Port 8092 is not published by default Caddy.

The cloud modules create one boot disk and no backup policy. AWS explicitly encrypts its root volume; verify provider policy/defaults elsewhere. Configure and test backups for PostgreSQL and `/var/lib/brian`.

## Optional dependencies

- HTTPS ingress: default setup installs Caddy. Select `custom` for Nginx, cloudflared, a cloud load balancer, or another TLS/WebSocket proxy.
- Local-folder opening: install `xdg-utils`, but this is disabled by default and requires the API to share a graphical session.
- Archived WeChat SILK audio: requires an independently installed `silk_v3_decoder` and `WECHAT_SILK_DECODER_BIN`; Debian does not provide this binary.
- E2B cloud browser and CLI MCP connectors use provider/operator-supplied credentials and binaries rather than host Debian packages.
