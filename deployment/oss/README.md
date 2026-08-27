# OSS Debian deployment

`install.sh` provisions a Debian 12 or 13 host and deploys the public Use Brian OSS edition as native systemd services. It clones the public `use-brian/use-brian` repository and sets `USEBRIAN_EDITION=oss` and `NEXT_PUBLIC_USEBRIAN_EDITION=oss`.

Supported architectures are amd64 and arm64. The installer verifies systemd, Node.js 22, Git, curl, ffmpeg/ffprobe, PostgreSQL client tools, and `runuser` before deployment.

## Services

| Unit | Listener | Purpose |
| --- | --- | --- |
| `brian-api` | `4000` | API and in-process workers |
| `brian-app-web` | `3003` | Next.js application |
| `brian-doc-sync` | `8080` | Collaborative document WebSocket service |
| `brian-discord-connector` | `8090` | Discord gateway connector |
| `brian-wa-connector` | `8091` | WhatsApp connector |
| `brian-browser-relay` | `8092` | Browser extension relay |
| `brian-wechat-connector` | `8093` | WeChat connector |
| `brian-feishu-connector` | `8095` | Feishu connector |
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
  MODEL_PROVIDER=gemini \
  GEMINI_API_KEY=replace \
  APP_URL=https://app.example.com \
  API_URL=https://api.example.com \
  DOC_SYNC_PUBLIC_URL=wss://docs.example.com \
  ./install.sh
```

When `INSTALL_POSTGRES=no`, also set `DATABASE_URL` and `DATABASE_URL_APP`. The external database administrator must create pgvector and `pg_trgm`, and the application URL's role must already have the required schema/table/sequence/function privileges while remaining `NOBYPASSRLS`. Optional values include `BRIAN_REPO`, `BRIAN_REF`, `COOKIE_DOMAIN`, and `VNC_PASSWORD`.

The installer asks for a primary model provider. Choose `gemini` to enter an API key, `dashscope` to enter an API key and optional base URL, `vertex` to enter a Google Cloud project/location, or `openai-codex` to complete interactive account sign-in after installation.

At the end, choose `default` reverse proxy setup to install Caddy, configure the app/API/doc-sync hostnames, enable automatic TLS and WebSockets, and allow host ports 80/443. Choose `custom` to leave ingress unchanged. Cloud security-group/firewall rules and DNS still need to point ports 80/443 and the configured hostnames to this server.

The external database preflight requires PostgreSQL 18 or newer, both extensions, and a `NOSUPERUSER`, `NOBYPASSRLS` application role. It checks connectivity before downloading and building Brian.

`INSTALL_LIBREOFFICE=yes` installs only the headless Writer, Calc, and Impress components. Brian invokes `soffice --headless` when exporting its documents, presentations, spreadsheets, or `renderPdf` output to PDF. It is not needed to start the services; select `no` if PDF generation is not required.

The public URLs must already be planned as `https://`/`wss://` origins because production authentication uses secure cookies. Leave `COOKIE_DOMAIN` empty for host-only cookies or set an isolated deployment domain such as `.client.example.com`; do not share a parent cookie domain between customers.

The first installer prompt selects the dedicated service account, defaulting to `brian`. Every service runs as that account, and release/data directories are owned by it. The installer writes `/etc/brian/brian.env` as `0640` with the configured service group. Add any additional provider or connector credentials there after installation, then run `sudo systemctl restart 'brian-*'`.

## Operations

```bash
sudo brian-doctor
sudo brian-update
sudo systemctl status 'brian-*'
sudo journalctl -u brian-api -f
```

`brian-update [git-ref]` clones and builds a versioned release, migrates, atomically switches `/var/lib/brian/platform`, and restarts the stack. Failed health checks restore the previous code release. Migrations are forward-only and are not rolled back, so take a database backup before updating.

## Browser desktop

The optional desktop runs Xvfb, Xfce, Chromium, the built Use Brian extension, and x11vnc on `127.0.0.1:5901`. Connect through SSH rather than opening VNC in the cloud firewall, then complete browser pairing in the Brian UI (custom self-host domains may require manual pairing):

```bash
ssh -L 5901:127.0.0.1:5901 debian@SERVER_IP
vncviewer 127.0.0.1:5901
```

## Public ingress

Application services are not opened by the Terraform firewall modules. The installer also enables UFW with inbound SSH only because several upstream processes bind all interfaces. Terminate HTTPS with a reverse proxy or tunnel on the host and route the configured app, API, and doc-sync hostnames to ports 3003, 4000, and 8080 over loopback. WebSocket upgrades must be enabled for doc-sync and browser relay. If a proxy must accept public traffic directly, add only its HTTP/HTTPS rules to UFW.

The cloud modules create a single encrypted boot disk but no backup policy. Before production use, configure provider snapshots or database backups for PostgreSQL and `/var/lib/brian`, and test restoration.

## Optional dependencies

- HTTPS ingress: provide Caddy, Nginx, cloudflared, or another TLS/WebSocket-capable proxy. It is intentionally not selected automatically.
- Local-folder opening: install `xdg-utils`, but this is disabled by default and requires the API to share a graphical session.
- Archived WeChat SILK audio: requires an independently installed `silk_v3_decoder` and `WECHAT_SILK_DECODER_BIN`; Debian does not provide this binary.
- E2B cloud browser and CLI MCP connectors use provider/operator-supplied credentials and binaries rather than host Debian packages.
