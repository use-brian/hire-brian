#!/usr/bin/env bash
set -euo pipefail

psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  --set=ON_ERROR_STOP=1 --set=app_password="$APP_DATABASE_PASSWORD" <<'SQL'
SELECT format(
  'CREATE ROLE app_user LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS',
  :'app_password'
) WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_user') \gexec
ALTER ROLE app_user PASSWORD :'app_password';
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
SQL
