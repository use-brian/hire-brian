#!/usr/bin/env bash
# Shared mode, preflight and lifecycle logic. Never source a dotenv file.
set -euo pipefail
set +x

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$HERE"
MODE=${1:-oss}
case "$MODE" in oss|outpost) ;; *) echo "Mode must be oss or outpost." >&2; exit 1 ;; esac
command -v docker >/dev/null || { echo "Docker is required." >&2; exit 1; }
command -v python3 >/dev/null || { echo "Python 3 is required." >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "Docker Compose v2 is required." >&2; exit 1; }

# Explicit files/project/profile prevent ambient Compose settings changing the stack.
unset COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_NAME COMPOSE_ENV_FILES
export USEBRIAN_EDITION=$MODE
export BRIAN_ENV_FILE=${BRIAN_ENV_FILE:-.env}
COMPOSE=(docker compose --project-name use-brian --env-file "$BRIAN_ENV_FILE")
if [ "$MODE" = outpost ]; then
  [ -f outpost.env ] || { echo "Create outpost.env from outpost.env.example first." >&2; exit 1; }
  COMPOSE+=(--env-file outpost.env)
fi
COMPOSE+=(-f compose.yml)
if [ "$MODE" = outpost ]; then
  COMPOSE+=(-f compose.outpost.yml --profile outpost)
fi
WRITERS=(app-web api doc-sync browser-relay discord-connector wa-connector wechat-connector feishu-connector)
[ "$MODE" != outpost ] || WRITERS+=(auth-web)

preflight() {
  [ -f "$BRIAN_ENV_FILE" ] || { echo ".env is required; run install.sh first." >&2; return 1; }
  # Resolved config contains secrets: pipe it directly to validation, never log it.
  IMAGES=$("${COMPOSE[@]}" config --format json 2>/dev/null |
    python3 ./validate-config.py "$MODE" "${1:-check}") || return 1
  local legacy
  legacy=$(docker ps --filter label=com.docker.compose.project=use-brian \
    --filter label=com.docker.compose.service=caddy --format '{{.ID}}') || return 1
  [ -z "$legacy" ] || { echo "Stop the legacy use-brian Caddy container before proceeding; see README.md." >&2; return 1; }
  echo "Configuration preflight passed (credentials/connectivity not tested)."
}

verify_images() {
  local image revision expected_revision=
  while IFS= read -r image; do
    revision=$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$image") || return 1
    if [[ ! "$revision" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
      echo "An application image lacks a valid source revision label." >&2
      return 1
    fi
    if [ -n "$expected_revision" ] && [ "$revision" != "$expected_revision" ]; then
      echo "Application image revision mismatch; refusing mixed releases." >&2
      return 1
    fi
    expected_revision=$revision
  done <<< "$IMAGES"
  [ -n "$expected_revision" ] || return 1
  echo "All selected application images match revision $expected_revision."
}

deploy() {
  "${COMPOSE[@]}" pull
  verify_images
  # Include the optional auth writer even when switching back to OSS. Stop old
  # one-shot jobs too; no old writer may race the forward-only migrations.
  "${COMPOSE[@]}" --profile outpost stop app-web api doc-sync browser-relay \
    discord-connector wa-connector wechat-connector feishu-connector auth-web migrate grant-app-role
  "${COMPOSE[@]}" up -d --no-deps --wait postgres
  "${COMPOSE[@]}" run --rm --no-deps migrate
  "${COMPOSE[@]}" run --rm --no-deps grant-app-role
  # Jobs ran explicitly above; do not re-run dependencies or reuse completed jobs.
  "${COMPOSE[@]}" up -d --no-deps --force-recreate --wait "${WRITERS[@]}"
  "${COMPOSE[@]}" ps
}
