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
