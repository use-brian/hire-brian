#!/usr/bin/env bash
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run this installer with sudo." >&2; exit 1; }
[ -r /etc/os-release ] || { echo "Cannot identify this operating system." >&2; exit 1; }
. /etc/os-release
[ "${ID:-}" = debian ] || { echo "This installer supports Debian only." >&2; exit 1; }
case "${VERSION_ID:-}" in 12|13) ;; *) echo "Debian 12 or 13 is required." >&2; exit 1 ;; esac
case "$(dpkg --print-architecture)" in
  amd64|arm64) ;;
  *) echo "Use Brian supports Debian amd64 and arm64 hosts only." >&2; exit 1 ;;
esac
[ "$(</proc/1/comm)" = systemd ] || { echo "This installer requires systemd as PID 1." >&2; exit 1; }

HERE=$(cd "$(dirname "$0")" && pwd)
NONINTERACTIVE=${NONINTERACTIVE:-0}
. "$HERE/../common.sh"

if [ -e /etc/brian/brian.env ]; then
  echo "Brian is already configured. Use 'sudo brian-update' to deploy updates." >&2
  exit 1
fi
install_complete=0
cleanup_partial_install() {
  if [ "$install_complete" != 1 ]; then
    rm -f /etc/brian/brian.env /etc/brian/deploy.conf
  fi
}
trap cleanup_partial_install EXIT

configure_service_user
ask INSTALL_POSTGRES "Install PostgreSQL 18 and pgvector locally? (yes/no)" yes
ask INSTALL_BROWSER "Install Chromium, Xfce, Xvfb, and local-only VNC? (yes/no)" no
ask INSTALL_LIBREOFFICE "Install headless LibreOffice for PDF exports? (yes/no)" yes
ask BRIAN_REPO "Use Brian repository" "https://github.com/use-brian/use-brian.git"
ask BRIAN_REF "Git branch, tag, or commit" main
ask APP_URL "Public HTTPS application URL"
ask API_URL "Public HTTPS API URL"
ask DOC_SYNC_PUBLIC_URL "Public secure doc-sync WebSocket URL (wss://...)"
case "$APP_URL $API_URL $DOC_SYNC_PUBLIC_URL" in
  https://*\ https://*\ wss://*) ;;
  *) echo "Production URLs must use https:// for app/API and wss:// for doc-sync." >&2; exit 1 ;;
esac
if [ -z "${COOKIE_DOMAIN+x}" ]; then
  if [ "$NONINTERACTIVE" = 1 ]; then COOKIE_DOMAIN=""; else read -r -p "Cookie domain (leave blank for host-only cookies): " COOKIE_DOMAIN; fi
fi
configure_model_provider

echo ">> Installing operating-system dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg git openssl build-essential ufw util-linux \
  python3 pkg-config ffmpeg fonts-liberation fonts-noto-cjk fonts-noto-color-emoji
if is_yes "$INSTALL_LIBREOFFICE"; then
  apt-get install -y --no-install-recommends libreoffice-writer-nogui \
    libreoffice-calc-nogui libreoffice-impress-nogui
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
for required_command in node corepack git curl ffmpeg ffprobe psql runuser; do
  command -v "$required_command" >/dev/null || {
    echo "Required command was not installed: $required_command" >&2
    exit 1
  }
done
if is_yes "$INSTALL_LIBREOFFICE"; then
  command -v soffice >/dev/null || {
    echo "LibreOffice was selected but soffice was not installed." >&2
    exit 1
  }
fi
[ "$(node --print 'process.versions.node.split(`.`)[0]')" -eq 22 ] || {
  echo "Node.js 22 is required." >&2
  exit 1
}

# Most Brian processes do not support a bind-address option. Keep their listeners
# private even on cloud networks that allow traffic from the whole VPC.
ufw allow 22/tcp
ufw default deny incoming
ufw default allow outgoing
ufw --force enable

getent group "$BRIAN_GROUP" >/dev/null || groupadd --system "$BRIAN_GROUP"
id "$BRIAN_USER" >/dev/null 2>&1 || useradd --system --gid "$BRIAN_GROUP" --home-dir /var/lib/brian --shell /usr/sbin/nologin "$BRIAN_USER"
install -d -o "$BRIAN_USER" -g "$BRIAN_GROUP" -m 0750 /var/lib/brian /var/lib/brian/files /var/lib/brian/wa-creds
install -d -o root -g "$BRIAN_GROUP" -m 0750 /etc/brian

if is_yes "$INSTALL_POSTGRES"; then
  echo ">> Installing local PostgreSQL"
  apt-get install -y postgresql-18 postgresql-18-pgvector
  systemctl enable --now postgresql
  owner_password=$(openssl rand -hex 24)
  app_password=$(openssl rand -hex 24)
  runuser -u postgres -- psql --set=ON_ERROR_STOP=1 --set=owner_pw="$owner_password" --set=app_pw="$app_password" <<'SQL'
SELECT format('CREATE ROLE brian LOGIN PASSWORD %L', :'owner_pw') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'brian') \gexec
SELECT format('CREATE ROLE app_user LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS', :'app_pw') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_user') \gexec
ALTER ROLE brian PASSWORD :'owner_pw';
ALTER ROLE app_user PASSWORD :'app_pw';
SELECT 'CREATE DATABASE brian OWNER brian' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'brian') \gexec
SQL
  runuser -u postgres -- psql --dbname=brian --set=ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
UPDATE pg_extension SET extowner = (SELECT oid FROM pg_roles WHERE rolname = 'brian') WHERE extname IN ('vector', 'pg_trgm');
SQL
  DATABASE_URL="postgresql://brian:${owner_password}@127.0.0.1:5432/brian"
  DATABASE_URL_APP="postgresql://app_user:${app_password}@127.0.0.1:5432/brian"
else
  ask_secret DATABASE_URL "PostgreSQL owner URL (DATABASE_URL)"
  ask_secret DATABASE_URL_APP "PostgreSQL non-owner RLS role URL (DATABASE_URL_APP)"
  validate_external_postgres "$DATABASE_URL" "$DATABASE_URL_APP" true
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
  write_env NODE_ENV production
  write_env USEBRIAN_EDITION oss
  write_model_provider_env
  write_env DATABASE_URL "$DATABASE_URL"
  write_env DATABASE_URL_APP "$DATABASE_URL_APP"
  write_env APP_URL "$APP_URL"
  write_env AUTHED_APP_URL "$APP_URL"
  write_env API_URL "$API_URL"
  write_env WEBHOOK_BASE_URL "$API_URL"
  write_env INTERNAL_API_URL http://127.0.0.1:4000
  write_env NEXT_PUBLIC_API_URL "$API_URL"
  write_env NEXT_PUBLIC_DOC_SYNC_URL "$DOC_SYNC_PUBLIC_URL"
  write_env NEXT_PUBLIC_USEBRIAN_EDITION oss
  if [ -n "$COOKIE_DOMAIN" ]; then write_env COOKIE_DOMAIN "$COOKIE_DOMAIN"; fi
  write_env DOC_SYNC_URL http://127.0.0.1:8080
  write_env JWT_SECRET "$JWT_SECRET"
  write_env DOC_SYNC_SECRET "$DOC_SYNC_SECRET"
  write_env CHANNEL_CREDENTIAL_KEY "$CHANNEL_CREDENTIAL_KEY"
  write_env DISCORD_CONNECTOR_URL http://127.0.0.1:8090
  write_env DISCORD_CONNECTOR_SECRET "$DISCORD_CONNECTOR_SECRET"
  write_env WA_CONNECTOR_URL http://127.0.0.1:8091
  write_env WA_CONNECTOR_SECRET "$WA_CONNECTOR_SECRET"
  write_env BROWSER_RELAY_URL http://127.0.0.1:8092
  write_env BROWSER_RELAY_SECRET "$BROWSER_RELAY_SECRET"
  write_env WECHAT_CONNECTOR_URL http://127.0.0.1:8093
  write_env WECHAT_CONNECTOR_SECRET "$WECHAT_CONNECTOR_SECRET"
  write_env FEISHU_CONNECTOR_URL http://127.0.0.1:8095
  write_env FEISHU_CONNECTOR_SECRET "$FEISHU_CONNECTOR_SECRET"
  write_env BROWSER_VAULT_ENCRYPTION_KEY "$BROWSER_VAULT_ENCRYPTION_KEY"
  write_env BROWSER_CREDENTIAL_ENCRYPTION_KEY "$BROWSER_CREDENTIAL_ENCRYPTION_KEY"
  write_env LLM_PROVIDER_KEY_ENCRYPTION_KEY "$LLM_PROVIDER_KEY_ENCRYPTION_KEY"
  write_env LOCAL_FILES_DIR /var/lib/brian/files
} > /etc/brian/brian.env
chown "root:$BRIAN_GROUP" /etc/brian/brian.env
chmod 0640 /etc/brian/brian.env

{
  printf 'BRIAN_REPO=%q\n' "$BRIAN_REPO"
  printf 'BRIAN_REF=%q\n' "$BRIAN_REF"
  printf 'NEXT_PUBLIC_API_URL=%q\n' "$API_URL"
  printf 'NEXT_PUBLIC_DOC_SYNC_URL=%q\n' "$DOC_SYNC_PUBLIC_URL"
  printf 'LOCAL_POSTGRES=%q\n' "$(is_yes "$INSTALL_POSTGRES" && printf yes || printf no)"
  printf 'BRIAN_USER=%q\n' "$BRIAN_USER"
  printf 'BRIAN_GROUP=%q\n' "$BRIAN_GROUP"
} > /etc/brian/deploy.conf
chmod 0600 /etc/brian/deploy.conf

echo ">> Installing service definitions and operations commands"
install -m 0755 "$HERE/bin/brian-update" /usr/local/bin/brian-update
install -m 0755 "$HERE/bin/brian-doctor" /usr/local/bin/brian-doctor
install -d -m 0755 /usr/local/lib/brian
install -m 0755 "$HERE/bin/grant-app-role" /usr/local/lib/brian/grant-app-role
install -m 0755 "$HERE/bin/wait-for-api" /usr/local/lib/brian/wait-for-api
for unit in brian-{api,app-web,doc-sync,discord-connector,wa-connector,browser-relay,wechat-connector,feishu-connector}.service; do
  install_systemd_unit "$HERE/systemd/$unit" "/etc/systemd/system/$unit"
done

if is_yes "$INSTALL_BROWSER"; then
  echo ">> Installing local-only browser desktop"
  apt-get install -y --no-install-recommends chromium xfce4 xfce4-terminal xvfb x11vnc x11-utils dbus-x11
  install -m 0755 "$HERE/bin/start-browser-desktop" /usr/local/lib/brian/start-browser-desktop
  install_systemd_unit "$HERE/systemd/brian-browser-desktop.service" /etc/systemd/system/brian-browser-desktop.service
  if [ -z "${VNC_PASSWORD:-}" ]; then
    if [ "$NONINTERACTIVE" = 1 ]; then VNC_PASSWORD=$(openssl rand -hex 4); else ask_secret VNC_PASSWORD "VNC password (maximum 8 characters)"; fi
  fi
  if [ "${#VNC_PASSWORD}" -gt 8 ]; then echo "VNC_PASSWORD must not exceed 8 characters." >&2; exit 1; fi
  x11vnc -storepasswd "$VNC_PASSWORD" /etc/brian/vnc.pass >/dev/null
  chown "root:$BRIAN_GROUP" /etc/brian/vnc.pass
  chmod 0640 /etc/brian/vnc.pass
fi

systemctl daemon-reload
systemctl enable brian-api brian-app-web brian-doc-sync brian-discord-connector brian-wa-connector brian-browser-relay brian-wechat-connector brian-feishu-connector
if is_yes "$INSTALL_BROWSER"; then systemctl enable brian-browser-desktop.service; fi

echo ">> Building, migrating, and starting Brian (this can take several minutes)"
/usr/local/bin/brian-update "$BRIAN_REF"

if is_yes "$INSTALL_BROWSER"; then systemctl start brian-browser-desktop.service; fi
install_complete=1

echo
echo "Brian installation complete."
echo "Edit /etc/brian/brian.env to add model-provider and connector credentials."
echo "Run: sudo brian-doctor"
if is_yes "$INSTALL_BROWSER"; then echo "VNC is available only through an SSH tunnel to 127.0.0.1:5901."; fi
