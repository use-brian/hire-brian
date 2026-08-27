#!/usr/bin/env bash

# Shared installer primitives. Callers set NONINTERACTIVE before prompting.
ask() {
  local variable=$1 prompt=$2 default=${3:-} value
  value=${!variable:-}
  if [ -z "$value" ]; then
    if [ "${NONINTERACTIVE:-0}" = 1 ]; then
      [ -n "$default" ] || { echo "$variable is required in non-interactive mode." >&2; exit 1; }
      value=$default
    else
      read -r -p "$prompt${default:+ [$default]}: " value
      value=${value:-$default}
    fi
  fi
  printf -v "$variable" '%s' "$value"
}

ask_secret() {
  local variable=$1 prompt=$2 value
  value=${!variable:-}
  if [ -z "$value" ]; then
    if [ "${NONINTERACTIVE:-0}" = 1 ]; then
      echo "$variable is required in non-interactive mode." >&2
      exit 1
    fi
    read -r -s -p "$prompt: " value
    echo
  fi
  printf -v "$variable" '%s' "$value"
}

ask_optional() {
  local variable=$1 prompt=$2 value
  if [[ -v $variable ]]; then return 0; fi
  if [ "${NONINTERACTIVE:-0}" = 1 ]; then
    printf -v "$variable" '%s' ''
  else
    read -r -p "$prompt (leave blank for default): " value
    printf -v "$variable" '%s' "$value"
  fi
}

is_yes() {
  case "$1" in y|Y|yes|YES|true|1) return 0 ;; *) return 1 ;; esac
}

random_secret() {
  openssl rand -base64 36 | tr -d '\n'
}

write_env() {
  case "$2" in *$'\n'*|*$'\r'*) echo "Unsupported newline in $1." >&2; exit 1 ;; esac
  printf '%s=%s\n' "$1" "$2"
}

configure_service_user() {
  ask BRIAN_USER "Dedicated service user" brian
  [[ "$BRIAN_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || {
    echo "BRIAN_USER must be a valid lowercase Linux system username." >&2
    exit 1
  }
  BRIAN_GROUP=$BRIAN_USER
}

normalize_yes_no() {
  local variable=$1 value=${!1}
  case "$value" in
    y|Y|yes|YES|true|1) printf -v "$variable" '%s' yes ;;
    n|N|no|NO|false|0) printf -v "$variable" '%s' no ;;
    *) echo "$variable must be yes or no." >&2; exit 1 ;;
  esac
}

configure_connectors() {
  ask ENABLE_DISCORD "Enable Discord connector? (yes/no)" yes
  ask ENABLE_WHATSAPP "Enable WhatsApp connector? (yes/no)" yes
  ask ENABLE_WECHAT "Enable WeChat connector? (yes/no)" yes
  ask ENABLE_FEISHU "Enable Feishu connector? (yes/no)" yes
  normalize_yes_no ENABLE_DISCORD
  normalize_yes_no ENABLE_WHATSAPP
  normalize_yes_no ENABLE_WECHAT
  normalize_yes_no ENABLE_FEISHU
}

install_systemd_unit() {
  local source=$1 destination=$2 content
  content=$(<"$source")
  content=${content//@BRIAN_USER@/$BRIAN_USER}
  content=${content//@BRIAN_GROUP@/$BRIAN_GROUP}
  printf '%s\n' "$content" > "$destination"
  chmod 0644 "$destination"
}

configure_model_provider() {
  ask MODEL_PROVIDER "Primary model provider (gemini/vertex/dashscope/openai-codex)" gemini
  case "$MODEL_PROVIDER" in
    gemini)
      ask_secret GEMINI_API_KEY "Gemini API key"
      USEBRIAN_PREFERRED_PROVIDER=gemini
      ;;
    vertex)
      ask VERTEX_PROJECT_ID "Google Cloud project id"
      ask VERTEX_LOCATION "Vertex AI location" asia-east2
      USEBRIAN_PREFERRED_PROVIDER=gemini
      ;;
    dashscope)
      ask_secret DASHSCOPE_API_KEY "DashScope API key"
      ask_optional DASHSCOPE_BASE_URL "DashScope base URL"
      USEBRIAN_PREFERRED_PROVIDER=dashscope-intl
      ;;
    openai-codex)
      USEBRIAN_PREFERRED_PROVIDER=openai-codex
      ;;
    *)
      echo "MODEL_PROVIDER must be gemini, vertex, dashscope, or openai-codex." >&2
      exit 1
      ;;
  esac
}

write_model_provider_env() {
  write_env USEBRIAN_PREFERRED_PROVIDER "$USEBRIAN_PREFERRED_PROVIDER"
  case "$MODEL_PROVIDER" in
    gemini) write_env GEMINI_API_KEY "$GEMINI_API_KEY" ;;
    vertex)
      write_env VERTEX_PROJECT_ID "$VERTEX_PROJECT_ID"
      write_env VERTEX_LOCATION "$VERTEX_LOCATION"
      if [ -n "${VERTEX_SERVICE_ACCOUNT_JSON:-}" ]; then
        write_env VERTEX_SERVICE_ACCOUNT_JSON "$VERTEX_SERVICE_ACCOUNT_JSON"
      fi
      ;;
    dashscope)
      write_env DASHSCOPE_API_KEY "$DASHSCOPE_API_KEY"
      if [ -n "${DASHSCOPE_BASE_URL:-}" ]; then write_env DASHSCOPE_BASE_URL "$DASHSCOPE_BASE_URL"; fi
      ;;
    openai-codex) ;;
  esac
}

validate_external_postgres() {
  local database_url=$1 database_url_app=$2 require_tls=${3:-true}
  local query sslmode parameter version extension_count owner_role app_role flags
  local owner_database app_database dangerous_memberships
  local -a parameters

  if [ "$require_tls" = true ]; then
    for url in "$database_url" "$database_url_app"; do
      query=${url#*\?}
      [ "$query" != "$url" ] || { echo "External database URLs require sslmode." >&2; exit 1; }
      sslmode=
      IFS='&' read -r -a parameters <<< "$query"
      for parameter in "${parameters[@]}"; do
        if [ "${parameter%%=*}" = sslmode ]; then sslmode=${parameter#*=}; fi
      done
      case "$sslmode" in
        require|verify-ca|verify-full) ;;
        *) echo "External database sslmode must enforce TLS." >&2; exit 1 ;;
      esac
    done
  fi

  version=$(psql "$database_url" -Atc 'SHOW server_version_num')
  [ "$version" -ge 180000 ] && [ "$version" -lt 190000 ] || { echo "PostgreSQL 18 is required." >&2; exit 1; }
  extension_count=$(psql "$database_url" -Atc "SELECT count(*) FROM pg_extension WHERE extname IN ('vector', 'pg_trgm')")
  [ "$extension_count" -eq 2 ] || { echo "External database requires vector and pg_trgm." >&2; exit 1; }
  owner_role=$(psql "$database_url" -Atc 'SELECT current_user')
  app_role=$(psql "$database_url_app" -Atc 'SELECT current_user')
  [ "$owner_role" != "$app_role" ] || { echo "Database URLs must use different roles." >&2; exit 1; }
  owner_database=$(psql "$database_url" -Atc 'SELECT current_database()')
  app_database=$(psql "$database_url_app" -Atc 'SELECT current_database()')
  [ "$owner_database" = "$app_database" ] || { echo "Database URLs must target the same database." >&2; exit 1; }
  flags=$(psql "$database_url_app" -Atc 'SELECT rolsuper::int || chr(124) || rolbypassrls::int FROM pg_roles WHERE rolname=current_user')
  [ "$flags" = '0|0' ] || { echo "Application database role is privileged." >&2; exit 1; }
  dangerous_memberships=$(psql "$database_url_app" -Atc "SELECT count(*) FROM pg_roles WHERE (rolsuper OR rolbypassrls) AND pg_has_role(current_user, oid, 'member')")
  [ "$dangerous_memberships" -eq 0 ] || { echo "Application role inherits a privileged role." >&2; exit 1; }
}

public_host_from_url() {
  local url=$1 authority
  case "$url" in
    https://*) authority=${url#https://} ;;
    wss://*) authority=${url#wss://} ;;
    *) echo "Public URL must use https:// or wss://: $url" >&2; return 1 ;;
  esac
  authority=${authority%%/*}
  case "$authority" in *:*|*@*|*\?*|*\#*) echo "Public URL must be a hostname without credentials or a custom port: $url" >&2; return 1 ;; esac
  [[ "$authority" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || {
    echo "Invalid public hostname: $authority" >&2
    return 1
  }
  printf '%s' "$authority"
}

configure_reverse_proxy() {
  local host port
  local -A configured_hosts=()
  ask REVERSE_PROXY_SETUP "Reverse proxy setup (default/custom)" default
  case "$REVERSE_PROXY_SETUP" in
    custom)
      echo "Reverse proxy left to the operator. Keep application ports private and publish only HTTPS/WSS."
      return 0
      ;;
    default) ;;
    *) echo "REVERSE_PROXY_SETUP must be default or custom." >&2; exit 1 ;;
  esac

  [ $(( $# % 2 )) -eq 0 ] || { echo "Reverse proxy routes must be URL/port pairs." >&2; exit 1; }
  apt-get update
  apt-get install -y --no-install-recommends caddy
  install -d -m 0755 /etc/caddy
  if [ -s /etc/caddy/Caddyfile ]; then
    cp -a /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.pre-use-brian.$(date -u +%Y%m%dT%H%M%SZ)"
  fi
  : > /etc/caddy/Caddyfile
  while [ "$#" -gt 0 ]; do
    host=$(public_host_from_url "$1")
    port=$2
    [[ "$port" =~ ^[0-9]+$ ]] || { echo "Invalid reverse proxy port: $port" >&2; exit 1; }
    [ -z "${configured_hosts[$host]:-}" ] || {
      echo "Default reverse proxy setup requires distinct service hostnames; choose custom for same-origin routing." >&2
      exit 1
    }
    configured_hosts[$host]=1
    printf '%s {\n\treverse_proxy 127.0.0.1:%s\n}\n\n' "$host" "$port" >> /etc/caddy/Caddyfile
    shift 2
  done
  caddy fmt --overwrite /etc/caddy/Caddyfile
  caddy validate --config /etc/caddy/Caddyfile
  ufw allow 80/tcp
  ufw allow 443/tcp
  systemctl enable caddy
  if systemctl is-active --quiet caddy; then systemctl reload caddy; else systemctl start caddy; fi
  echo "Default Caddy reverse proxy configured with automatic TLS and WebSocket forwarding."
}
