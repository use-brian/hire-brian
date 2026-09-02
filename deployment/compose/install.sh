#!/usr/bin/env bash
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$HERE"

command -v docker >/dev/null || { echo "Docker is required." >&2; exit 1; }
docker compose version >/dev/null || { echo "Docker Compose v2 is required." >&2; exit 1; }
command -v openssl >/dev/null || { echo "openssl is required." >&2; exit 1; }

if [ -e .env ]; then
  echo ".env already exists; refusing to replace its secrets." >&2
  echo "To resume the current install, run 'bash ./verify-images.sh' then 'docker compose up -d'." >&2
  echo "To change image versions, pin BRIAN_IMAGE_TAG and run 'bash ./update.sh'." >&2
  exit 1
fi

read_required() {
  local name=$1 label=$2 value=${!1:-}
  while [ -z "$value" ]; do
    if [ ! -t 0 ]; then
      echo "$name is required for noninteractive installation." >&2
      exit 1
    fi
    read -r -p "$label: " value
  done
  value=${value,,}
  if [[ ! "$value" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
    echo "$name must be a valid DNS hostname." >&2
    exit 1
  fi
  printf -v "$name" '%s' "$value"
}

read_required APP_DOMAIN "App hostname"
read_required API_DOMAIN "API hostname"
read_required DOC_SYNC_DOMAIN "Document sync hostname"
read_required RELAY_DOMAIN "Browser relay hostname"

declare -A seen_domains=()
for domain in "$APP_DOMAIN" "$API_DOMAIN" "$DOC_SYNC_DOMAIN" "$RELAY_DOMAIN"; do
  if [ -n "${seen_domains[$domain]:-}" ]; then
    echo "App, API, document sync, and relay hostnames must be distinct." >&2
    exit 1
  fi
  seen_domains[$domain]=1
done

COOKIE_DOMAIN=${COOKIE_DOMAIN:-}
while [ -z "$COOKIE_DOMAIN" ]; do
  if [ ! -t 0 ]; then
    echo "COOKIE_DOMAIN is required for noninteractive installation." >&2
    exit 1
  fi
  read -r -p "Shared cookie domain (for example .example.com): " COOKIE_DOMAIN
done
COOKIE_DOMAIN=${COOKIE_DOMAIN,,}
if [[ ! "$COOKIE_DOMAIN" =~ ^\.([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
  echo "COOKIE_DOMAIN must be a valid DNS suffix beginning with a dot." >&2
  exit 1
fi
for domain in "$APP_DOMAIN" "$API_DOMAIN" "$DOC_SYNC_DOMAIN" "$RELAY_DOMAIN"; do
  if [[ ".$domain" != *"$COOKIE_DOMAIN" ]]; then
    echo "$domain is outside COOKIE_DOMAIN $COOKIE_DOMAIN." >&2
    exit 1
  fi
done

BRIAN_IMAGE_TAG=${BRIAN_IMAGE_TAG:-latest}
if [[ ! "$BRIAN_IMAGE_TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
  echo "BRIAN_IMAGE_TAG is not a valid container image tag." >&2
  exit 1
fi
USEBRIAN_PREFERRED_PROVIDER=${USEBRIAN_PREFERRED_PROVIDER:-openai-codex}
OWNER_USERNAME=${OWNER_USERNAME:-brian}
if [[ ! "$OWNER_USERNAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "OWNER_USERNAME may contain only letters, numbers, dots, underscores, and hyphens." >&2
  exit 1
fi
OWNER_PASSWORD=${OWNER_PASSWORD:-$(openssl rand -hex 16)}
OWNER_PASSWORD_HASH=$(docker run --rm caddy:2-alpine caddy hash-password --plaintext "$OWNER_PASSWORD")

if [ -n "${GHCR_TOKEN:-}" ]; then
  [ -n "${GHCR_USERNAME:-}" ] || { echo "GHCR_USERNAME is required with GHCR_TOKEN." >&2; exit 1; }
  docker login ghcr.io --username "$GHCR_USERNAME" --password-stdin <<<"$GHCR_TOKEN"
fi

for image in api app-web doc-sync browser-relay discord-connector wa-connector wechat-connector feishu-connector; do
  if ! docker pull "ghcr.io/use-brian/$image:$BRIAN_IMAGE_TAG"; then
    echo "Unable to pull $image:$BRIAN_IMAGE_TAG from GHCR." >&2
    echo "Confirm the package is public or provide GHCR_USERNAME and GHCR_TOKEN." >&2
    exit 1
  fi
done

random_hex() { openssl rand -hex 32; }
random_b64() { openssl rand -base64 32 | tr -d '\n'; }

write_env() {
  local name=$1 value=$2
  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    echo "$name must not contain a newline." >&2
    exit 1
  fi
  value=${value//\\/\\\\}
  value=${value//\'/\\\'}
  printf "%s='%s'\n" "$name" "$value"
}

umask 077
{
  write_env BRIAN_IMAGE_TAG "$BRIAN_IMAGE_TAG"
  write_env APP_DOMAIN "$APP_DOMAIN"
  write_env API_DOMAIN "$API_DOMAIN"
  write_env DOC_SYNC_DOMAIN "$DOC_SYNC_DOMAIN"
  write_env RELAY_DOMAIN "$RELAY_DOMAIN"
  write_env COOKIE_DOMAIN "$COOKIE_DOMAIN"
  write_env OWNER_USERNAME "$OWNER_USERNAME"
  write_env OWNER_PASSWORD_HASH "$OWNER_PASSWORD_HASH"
  write_env USEBRIAN_PREFERRED_PROVIDER "$USEBRIAN_PREFERRED_PROVIDER"
  write_env GEMINI_API_KEY "${GEMINI_API_KEY:-}"
  write_env ANTHROPIC_API_KEY "${ANTHROPIC_API_KEY:-}"
  write_env DASHSCOPE_API_KEY "${DASHSCOPE_API_KEY:-}"
  write_env DASHSCOPE_BASE_URL "${DASHSCOPE_BASE_URL:-}"
  write_env APP_HOSTS "${APP_HOSTS:-}"
  write_env GOOGLE_CLIENT_ID "${GOOGLE_CLIENT_ID:-}"
  write_env GOOGLE_CLIENT_SECRET "${GOOGLE_CLIENT_SECRET:-}"
  write_env GOOGLE_API_KEY "${GOOGLE_API_KEY:-}"
  write_env GOOGLE_PROJECT_NUMBER "${GOOGLE_PROJECT_NUMBER:-}"
  write_env NOTION_CLIENT_ID "${NOTION_CLIENT_ID:-}"
  write_env NOTION_CLIENT_SECRET "${NOTION_CLIENT_SECRET:-}"
  write_env FATHOM_CLIENT_ID "${FATHOM_CLIENT_ID:-}"
  write_env FATHOM_CLIENT_SECRET "${FATHOM_CLIENT_SECRET:-}"
  write_env SHOPIFY_CLIENT_ID "${SHOPIFY_CLIENT_ID:-}"
  write_env SHOPIFY_CLIENT_SECRET "${SHOPIFY_CLIENT_SECRET:-}"
  write_env POSTGRES_PASSWORD "$(random_hex)"
  write_env APP_DATABASE_PASSWORD "$(random_hex)"
  write_env JWT_SECRET "$(random_hex)"
  write_env DOC_SYNC_SECRET "$(random_hex)"
  write_env CHANNEL_CREDENTIAL_KEY "$(random_b64)"
  write_env DISCORD_CONNECTOR_SECRET "$(random_hex)"
  write_env WA_CONNECTOR_SECRET "$(random_hex)"
  write_env BROWSER_RELAY_SECRET "$(random_hex)"
  write_env WECHAT_CONNECTOR_SECRET "$(random_hex)"
  write_env FEISHU_CONNECTOR_SECRET "$(random_hex)"
  write_env BROWSER_VAULT_ENCRYPTION_KEY "$(random_b64)"
  write_env BROWSER_CREDENTIAL_ENCRYPTION_KEY "$(random_b64)"
  write_env LLM_PROVIDER_KEY_ENCRYPTION_KEY "$(random_b64)"
} > .env

echo
echo "Owner login: $OWNER_USERNAME / $OWNER_PASSWORD"
echo "Store this password now; only its bcrypt hash is saved in .env."

bash ./verify-images.sh
docker compose up -d

echo
echo "Use Brian is starting at https://$APP_DOMAIN"
echo "Run 'docker compose ps' to check readiness and 'docker compose logs -f' for logs."
