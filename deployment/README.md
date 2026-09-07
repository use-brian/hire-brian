# Deployment targets

- `compose/`: published-image Docker Compose deployment with PostgreSQL 18, loopback-only OSS defaults, and optional Outpost auth behind your external HTTPS reverse proxy. Both modes share one project and durable volumes; no bundled public proxy or Basic Auth gate.
- `oss/`: native Debian 12/13 installation of the public Use Brian OSS edition.
- `outpost/`: native Debian 12/13 Outpost installation using `OUTPOST_SOURCE_MODE=repository` with `BRIAN_REPO`/`BRIAN_REF`, or `OUTPOST_SOURCE_MODE=directory` with `OUTPOST_SOURCE_DIR`.

The targets are independent. Do not run multiple installers on the same host or point them at the same database. Start with the README inside the selected target.

`common.sh` contains installer behavior shared by both native targets: prompting, secret input, environment serialization, model-provider configuration, and external PostgreSQL validation.

Both native installers prompt for `BRIAN_USER`, PostgreSQL mode, browser/LibreOffice options, connector toggles, model provider, and `REVERSE_PROXY_SETUP`. Provider choices are Gemini, Vertex, DashScope (including optional `DASHSCOPE_BASE_URL`), and OpenAI Codex.
