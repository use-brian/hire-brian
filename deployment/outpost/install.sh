#!/usr/bin/env bash
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run this installer with sudo." >&2; exit 1; }
. /etc/os-release
[ "${ID:-}" = debian ] || { echo "This installer supports Debian only." >&2; exit 1; }
case "${VERSION_ID:-}" in 12|13) ;; *) echo "Debian 12 or 13 is required." >&2; exit 1 ;; esac
case "$(dpkg --print-architecture)" in amd64|arm64) ;; *) echo "Outpost supports amd64 and arm64 only." >&2; exit 1 ;; esac
[ "$(</proc/1/comm)" = systemd ] || { echo "This installer requires systemd as PID 1." >&2; exit 1; }
[ ! -e /etc/use-brian-outpost/api.env ] || { echo "Outpost is already configured; use outpost-update." >&2; exit 1; }

HERE=$(cd "$(dirname "$0")" && pwd)
NONINTERACTIVE=${NONINTERACTIVE:-0}
. "$HERE/../common.sh"
install_complete=0
cleanup_partial() {
  if [ "$install_complete" != 1 ]; then
    rm -f /etc/use-brian-outpost/*.env /etc/use-brian-outpost/deploy.conf
  fi
}
trap cleanup_partial EXIT

ask OUTPOST_SOURCE_DIR "Absolute path to the supplied Outpost source tree"
OUTPOST_SOURCE_DIR=$(readlink -f "$OUTPOST_SOURCE_DIR")
for marker in package.json pnpm-lock.yaml pnpm-workspace.yaml turbo.json apps/api/package.json \
  apps/auth-web/package.json apps/app-web/package.json apps/doc-sync/package.json \
  apps/discord-connector/package.json apps/wa-connector/package.json \
  apps/browser-relay/package.json apps/wechat-connector/package.json \
  apps/browser-extension/package.json apps/feishu-connector/package.json packages/api/migrations; do
  [ -e "$OUTPOST_SOURCE_DIR/$marker" ] || { echo "Source tree is missing $marker." >&2; exit 1; }
done
detected_ssh_port=22
if [ -n "${SSH_CONNECTION:-}" ]; then detected_ssh_port=${SSH_CONNECTION##* }; fi
ask SSH_PORT "SSH server port to preserve in UFW" "$detected_ssh_port"
ask INSTALL_POSTGRES "Install PostgreSQL 18 and pgvector locally? (yes/no)" yes
ask INSTALL_LIBREOFFICE "Install headless LibreOffice for PDF exports? (yes/no)" yes
ask INSTALL_BROWSER "Install Chromium, Xfce, Xvfb, and local-only VNC? (yes/no)" no
ask APP_URL "Public HTTPS application origin"
ask API_URL "Public HTTPS API origin"
ask AUTH_PORTAL_URL "Public HTTPS authentication origin"
ask DOC_SYNC_PUBLIC_URL "Public WSS document-sync origin"
case "$APP_URL $API_URL $AUTH_PORTAL_URL $DOC_SYNC_PUBLIC_URL" in
  https://*\ https://*\ https://*\ wss://*) ;;
  *) echo "App, API and auth require HTTPS; doc-sync requires WSS." >&2; exit 1 ;;
esac
ask COOKIE_DOMAIN "Isolated cookie domain (for example .customer.example)"
case "$COOKIE_DOMAIN" in .?*.?*) ;; *) echo "COOKIE_DOMAIN must be a dot-prefixed isolated domain." >&2; exit 1 ;; esac
ask TRUST_PROXY_HEADERS "Trust sanitized proxy client-IP headers? (true/false)" false
case "$TRUST_PROXY_HEADERS" in true|false) ;; *) echo "TRUST_PROXY_HEADERS must be true or false." >&2; exit 1 ;; esac
configure_model_provider

ask OUTPOST_AUTH_METHOD "Authentication method (email/oidc)" email
ask OUTPOST_AUTH_BOOTSTRAP_EMAILS "Bootstrap administrator email"
case "$OUTPOST_AUTH_METHOD" in
  email)
    ask GMAIL_SMTP_USER "Gmail SMTP account"
    ask_secret GMAIL_SMTP_APP_PASSWORD "Gmail SMTP application password"
    ask EMAIL_FROM_ADDRESS "Email from address" "$GMAIL_SMTP_USER"
    OUTPOST_AUTH_EMAIL_ENABLED=true; OUTPOST_AUTH_OIDC_ENABLED=false
    ;;
  oidc)
    ask OUTPOST_OIDC_ISSUER_URL "OIDC discovery issuer URL"
    ask OUTPOST_OIDC_CLIENT_ID "OIDC client id"
    ask_secret OUTPOST_OIDC_CLIENT_SECRET "OIDC client secret"
    ask OUTPOST_OIDC_PROVIDER_NAME "OIDC provider display name"
    OUTPOST_AUTH_BRIDGE_SECRET=${OUTPOST_AUTH_BRIDGE_SECRET:-$(random_secret)}
    OUTPOST_AUTH_EMAIL_ENABLED=false; OUTPOST_AUTH_OIDC_ENABLED=true
    ;;
  *) echo "Authentication method must be email or oidc." >&2; exit 1 ;;
esac

echo ">> Installing native runtime and build dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg git openssl build-essential \
  python3 pkg-config rsync ufw util-linux ffmpeg fonts-liberation fonts-dejavu-core fonts-noto-cjk fonts-noto-color-emoji
if is_yes "$INSTALL_LIBREOFFICE"; then
  apt-get install -y --no-install-recommends libreoffice-writer-nogui libreoffice-calc-nogui libreoffice-impress-nogui
fi
if is_yes "$INSTALL_BROWSER"; then
  apt-get install -y --no-install-recommends chromium xfce4 xfce4-terminal xvfb x11vnc x11-utils dbus-x11
fi
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
printf 'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main\n' > /etc/apt/sources.list.d/nodesource.list
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor --yes -o /etc/apt/keyrings/postgresql.gpg
printf 'deb [signed-by=/etc/apt/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt %s-pgdg main\n' "$VERSION_CODENAME" > /etc/apt/sources.list.d/pgdg.list
apt-get update
apt-get install -y nodejs postgresql-client-18
corepack enable
corepack prepare pnpm@10.33.0 --activate

getent group brian-outpost >/dev/null || groupadd --system brian-outpost
id brian-outpost >/dev/null 2>&1 || useradd --system --gid brian-outpost --home-dir /var/lib/use-brian-outpost --shell /usr/sbin/nologin brian-outpost
install -d -o brian-outpost -g brian-outpost -m 0750 /var/lib/use-brian-outpost /var/lib/use-brian-outpost/files /var/lib/use-brian-outpost/releases
install -d -o root -g brian-outpost -m 0750 /etc/use-brian-outpost

if is_yes "$INSTALL_POSTGRES"; then
  apt-get install -y postgresql-18 postgresql-18-pgvector
  systemctl enable --now postgresql
  existing_objects=$(runuser -u postgres -- psql -Atc "SELECT
    (SELECT count(*) FROM pg_roles WHERE rolname IN ('brian_outpost', 'app_user')) +
    (SELECT count(*) FROM pg_database WHERE datname = 'brian')")
  [ "$existing_objects" -eq 0 ] || {
    echo "Local PostgreSQL already contains Outpost role/database names; refusing to alter them." >&2
    exit 1
  }
  owner_password=$(openssl rand -hex 24)
  app_password=$(openssl rand -hex 24)
  runuser -u postgres -- psql --set=ON_ERROR_STOP=1 --set=owner_pw="$owner_password" --set=app_pw="$app_password" <<'SQL'
SELECT format('CREATE ROLE brian_outpost LOGIN PASSWORD %L', :'owner_pw') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'brian_outpost') \gexec
SELECT format('CREATE ROLE app_user LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS', :'app_pw') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_user') \gexec
ALTER ROLE brian_outpost PASSWORD :'owner_pw';
ALTER ROLE app_user PASSWORD :'app_pw';
SELECT 'CREATE DATABASE brian OWNER brian_outpost' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'brian') \gexec
SQL
  runuser -u postgres -- psql --dbname=brian --set=ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
UPDATE pg_extension SET extowner = (SELECT oid FROM pg_roles WHERE rolname = 'brian_outpost') WHERE extname IN ('vector', 'pg_trgm');
SQL
  DATABASE_URL="postgresql://brian_outpost:${owner_password}@127.0.0.1:5432/brian"
  DATABASE_URL_APP="postgresql://app_user:${app_password}@127.0.0.1:5432/brian"
  LOCAL_POSTGRES=yes
else
  ask_secret DATABASE_URL "External PostgreSQL owner URL with TLS"
  ask_secret DATABASE_URL_APP "External PostgreSQL RLS-role URL with TLS"
  validate_external_postgres "$DATABASE_URL" "$DATABASE_URL_APP" true
  LOCAL_POSTGRES=no
fi

JWT_SECRET=${JWT_SECRET:-$(random_secret)}
DOC_SYNC_SECRET=${DOC_SYNC_SECRET:-$(random_secret)}
CHANNEL_CREDENTIAL_KEY=${CHANNEL_CREDENTIAL_KEY:-$(openssl rand -base64 32 | tr -d '\n')}
DISCORD_CONNECTOR_SECRET=${DISCORD_CONNECTOR_SECRET:-$(random_secret)}
WA_CONNECTOR_SECRET=${WA_CONNECTOR_SECRET:-$(random_secret)}
BROWSER_RELAY_SECRET=${BROWSER_RELAY_SECRET:-$(random_secret)}
WECHAT_CONNECTOR_SECRET=${WECHAT_CONNECTOR_SECRET:-$(random_secret)}
FEISHU_CONNECTOR_SECRET=${FEISHU_CONNECTOR_SECRET:-$(random_secret)}
BROWSER_VAULT_ENCRYPTION_KEY=${BROWSER_VAULT_ENCRYPTION_KEY:-$(openssl rand -base64 32 | tr -d '\n')}
BROWSER_CREDENTIAL_ENCRYPTION_KEY=${BROWSER_CREDENTIAL_ENCRYPTION_KEY:-$(openssl rand -base64 32 | tr -d '\n')}
LLM_PROVIDER_KEY_ENCRYPTION_KEY=${LLM_PROVIDER_KEY_ENCRYPTION_KEY:-$(openssl rand -base64 32 | tr -d '\n')}

{
  write_env NODE_ENV production; write_env USEBRIAN_EDITION outpost
  write_model_provider_env
  write_env DATABASE_URL "$DATABASE_URL"; write_env DATABASE_URL_APP "$DATABASE_URL_APP"
  write_env APP_URL "$APP_URL"; write_env AUTHED_APP_URL "$APP_URL"; write_env API_URL "$API_URL"; write_env WEBHOOK_BASE_URL "$API_URL"
  write_env AUTH_PORTAL_URL "$AUTH_PORTAL_URL"; write_env COOKIE_DOMAIN "$COOKIE_DOMAIN"; write_env TRUST_PROXY_HEADERS "$TRUST_PROXY_HEADERS"
  write_env DOC_SYNC_URL http://127.0.0.1:8080; write_env JWT_SECRET "$JWT_SECRET"; write_env DOC_SYNC_SECRET "$DOC_SYNC_SECRET"
  write_env CHANNEL_CREDENTIAL_KEY "$CHANNEL_CREDENTIAL_KEY"
  write_env DISCORD_CONNECTOR_URL http://127.0.0.1:8090; write_env DISCORD_CONNECTOR_SECRET "$DISCORD_CONNECTOR_SECRET"
  write_env WA_CONNECTOR_URL http://127.0.0.1:8091; write_env WA_CONNECTOR_SECRET "$WA_CONNECTOR_SECRET"
  write_env BROWSER_RELAY_URL http://127.0.0.1:8092; write_env BROWSER_RELAY_SECRET "$BROWSER_RELAY_SECRET"
  write_env WECHAT_CONNECTOR_URL http://127.0.0.1:8093; write_env WECHAT_CONNECTOR_SECRET "$WECHAT_CONNECTOR_SECRET"
  write_env FEISHU_CONNECTOR_URL http://127.0.0.1:8095; write_env FEISHU_CONNECTOR_SECRET "$FEISHU_CONNECTOR_SECRET"
  write_env BROWSER_VAULT_ENCRYPTION_KEY "$BROWSER_VAULT_ENCRYPTION_KEY"; write_env BROWSER_CREDENTIAL_ENCRYPTION_KEY "$BROWSER_CREDENTIAL_ENCRYPTION_KEY"
  write_env LLM_PROVIDER_KEY_ENCRYPTION_KEY "$LLM_PROVIDER_KEY_ENCRYPTION_KEY"; write_env LOCAL_FILES_DIR /var/lib/use-brian-outpost/files
  write_env OUTPOST_AUTH_EMAIL_ENABLED "$OUTPOST_AUTH_EMAIL_ENABLED"; write_env OUTPOST_AUTH_OIDC_ENABLED "$OUTPOST_AUTH_OIDC_ENABLED"
  write_env OUTPOST_AUTH_BOOTSTRAP_EMAILS "$OUTPOST_AUTH_BOOTSTRAP_EMAILS"
  if [ "$OUTPOST_AUTH_METHOD" = email ]; then
    write_env GMAIL_SMTP_USER "$GMAIL_SMTP_USER"; write_env GMAIL_SMTP_APP_PASSWORD "$GMAIL_SMTP_APP_PASSWORD"; write_env EMAIL_FROM_ADDRESS "$EMAIL_FROM_ADDRESS"
  else
    write_env OUTPOST_OIDC_ISSUER_URL "$OUTPOST_OIDC_ISSUER_URL"; write_env OUTPOST_OIDC_CLIENT_ID "$OUTPOST_OIDC_CLIENT_ID"
    write_env OUTPOST_OIDC_CLIENT_SECRET "$OUTPOST_OIDC_CLIENT_SECRET"; write_env OUTPOST_OIDC_PROVIDER_NAME "$OUTPOST_OIDC_PROVIDER_NAME"
    write_env OUTPOST_AUTH_BRIDGE_SECRET "$OUTPOST_AUTH_BRIDGE_SECRET"
  fi
} > /etc/use-brian-outpost/api.env
{
  write_env NODE_ENV production; write_env USEBRIAN_EDITION outpost; write_env APP_URL "$APP_URL"; write_env AUTHED_APP_URL "$APP_URL"
  write_env API_URL "$API_URL"; write_env AUTH_PORTAL_URL "$AUTH_PORTAL_URL"; write_env COOKIE_DOMAIN "$COOKIE_DOMAIN"; write_env TRUST_PROXY_HEADERS "$TRUST_PROXY_HEADERS"
  write_env OUTPOST_AUTH_EMAIL_ENABLED "$OUTPOST_AUTH_EMAIL_ENABLED"; write_env OUTPOST_AUTH_OIDC_ENABLED "$OUTPOST_AUTH_OIDC_ENABLED"
  write_env OUTPOST_AUTH_BOOTSTRAP_EMAILS "$OUTPOST_AUTH_BOOTSTRAP_EMAILS"
  if [ "$OUTPOST_AUTH_METHOD" = email ]; then write_env GMAIL_SMTP_USER "$GMAIL_SMTP_USER"; write_env GMAIL_SMTP_APP_PASSWORD "$GMAIL_SMTP_APP_PASSWORD"; write_env EMAIL_FROM_ADDRESS "$EMAIL_FROM_ADDRESS";
  else write_env OUTPOST_OIDC_ISSUER_URL "$OUTPOST_OIDC_ISSUER_URL"; write_env OUTPOST_OIDC_CLIENT_ID "$OUTPOST_OIDC_CLIENT_ID"; write_env OUTPOST_OIDC_CLIENT_SECRET "$OUTPOST_OIDC_CLIENT_SECRET"; write_env OUTPOST_OIDC_PROVIDER_NAME "$OUTPOST_OIDC_PROVIDER_NAME"; write_env OUTPOST_AUTH_BRIDGE_SECRET "$OUTPOST_AUTH_BRIDGE_SECRET"; fi
} > /etc/use-brian-outpost/auth.env
{
  write_env NODE_ENV production; write_env USEBRIAN_EDITION outpost; write_env NEXT_PUBLIC_USEBRIAN_EDITION outpost
  write_env APP_URL "$APP_URL"; write_env AUTHED_APP_URL "$APP_URL"; write_env API_URL "$API_URL"; write_env AUTH_PORTAL_URL "$AUTH_PORTAL_URL"
  write_env NEXT_PUBLIC_PRIMARY_AUTH_URL "$AUTH_PORTAL_URL"; write_env NEXT_PUBLIC_API_URL "$API_URL"; write_env NEXT_PUBLIC_DOC_SYNC_URL "$DOC_SYNC_PUBLIC_URL"; write_env COOKIE_DOMAIN "$COOKIE_DOMAIN"
} > /etc/use-brian-outpost/app.env
{ write_env NODE_ENV production; write_env DATABASE_URL "$DATABASE_URL"; write_env DATABASE_URL_APP "$DATABASE_URL_APP"; write_env JWT_SECRET "$JWT_SECRET"; write_env DOC_SYNC_SECRET "$DOC_SYNC_SECRET"; } > /etc/use-brian-outpost/doc-sync.env
{ write_env NODE_ENV production; write_env DISCORD_CONNECTOR_SECRET "$DISCORD_CONNECTOR_SECRET"; } > /etc/use-brian-outpost/discord.env
{ write_env NODE_ENV production; write_env DATABASE_URL "$DATABASE_URL"; write_env DATABASE_URL_APP "$DATABASE_URL_APP"; write_env WA_CONNECTOR_SECRET "$WA_CONNECTOR_SECRET"; } > /etc/use-brian-outpost/whatsapp.env
{ write_env NODE_ENV production; write_env JWT_SECRET "$JWT_SECRET"; write_env BROWSER_RELAY_SECRET "$BROWSER_RELAY_SECRET"; } > /etc/use-brian-outpost/browser-relay.env
{ write_env NODE_ENV production; write_env WECHAT_CONNECTOR_SECRET "$WECHAT_CONNECTOR_SECRET"; } > /etc/use-brian-outpost/wechat.env
{ write_env NODE_ENV production; write_env FEISHU_CONNECTOR_SECRET "$FEISHU_CONNECTOR_SECRET"; } > /etc/use-brian-outpost/feishu.env
{ write_env NODE_ENV production; write_env USEBRIAN_EDITION outpost; write_env DATABASE_URL "$DATABASE_URL"; } > /etc/use-brian-outpost/migrate.env
chown root:brian-outpost /etc/use-brian-outpost/*.env; chmod 0640 /etc/use-brian-outpost/*.env

{
  printf 'OUTPOST_SOURCE_DIR=%q\n' "$OUTPOST_SOURCE_DIR"
  printf 'APP_URL=%q\n' "$APP_URL"; printf 'API_URL=%q\n' "$API_URL"; printf 'AUTH_PORTAL_URL=%q\n' "$AUTH_PORTAL_URL"
  printf 'DOC_SYNC_PUBLIC_URL=%q\n' "$DOC_SYNC_PUBLIC_URL"; printf 'LOCAL_POSTGRES=%q\n' "$LOCAL_POSTGRES"
} > /etc/use-brian-outpost/deploy.conf
chmod 0600 /etc/use-brian-outpost/deploy.conf

install -d -m 0755 /usr/local/lib/use-brian-outpost
install -m 0755 "$HERE/bin/outpost-grant-role" /usr/local/lib/use-brian-outpost/grant-role
install -m 0755 "$HERE/bin/wait-for-api" /usr/local/lib/use-brian-outpost/wait-for-api
if is_yes "$INSTALL_BROWSER"; then
  install -m 0755 "$HERE/bin/start-browser-desktop" /usr/local/lib/use-brian-outpost/start-browser-desktop
  if [ -z "${VNC_PASSWORD:-}" ]; then
    if [ "$NONINTERACTIVE" = 1 ]; then VNC_PASSWORD=$(openssl rand -hex 4); else ask_secret VNC_PASSWORD "VNC password (maximum 8 characters)"; fi
  fi
  [ "${#VNC_PASSWORD}" -le 8 ] || { echo "VNC password must not exceed 8 characters." >&2; exit 1; }
  x11vnc -storepasswd "$VNC_PASSWORD" /etc/use-brian-outpost/vnc.pass >/dev/null
  chown root:brian-outpost /etc/use-brian-outpost/vnc.pass
  chmod 0640 /etc/use-brian-outpost/vnc.pass
  touch /etc/use-brian-outpost/browser-desktop
  chmod 0600 /etc/use-brian-outpost/browser-desktop
fi
install -m 0755 "$HERE/bin/outpost-doctor" /usr/local/bin/outpost-doctor
install -m 0755 "$HERE/bin/outpost-update" /usr/local/bin/outpost-update
install -m 0644 "$HERE/systemd/"use-brian-outpost-*.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable use-brian-outpost-{api,auth,app,doc-sync,discord,whatsapp,browser-relay,wechat,feishu}.service
if is_yes "$INSTALL_BROWSER"; then systemctl enable use-brian-outpost-browser-desktop.service; fi

ufw allow "$SSH_PORT/tcp"; ufw default deny incoming; ufw default allow outgoing; ufw --force enable
install_complete=1
outpost-update "$OUTPOST_SOURCE_DIR"
if is_yes "$INSTALL_BROWSER"; then systemctl start use-brian-outpost-browser-desktop.service; fi
echo "Native Outpost installation complete."
