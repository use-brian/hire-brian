#!/usr/bin/env bash
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$HERE"

[ -f .env ] || { echo ".env is required; run install.sh first." >&2; exit 1; }
command -v docker >/dev/null || { echo "Docker is required." >&2; exit 1; }
docker compose version >/dev/null || { echo "Docker Compose v2 is required." >&2; exit 1; }

if [ "${ALLOW_MUTABLE_IMAGE_TAG:-0}" != "1" ] &&
  docker compose config --images | grep -Eq '^ghcr\.io/use-brian/.+:(latest|main|develop)$'; then
  echo "Refusing a forward-only update from a mutable image tag." >&2
  echo "Set BRIAN_IMAGE_TAG in .env to a release or sha-* tag first." >&2
  exit 1
fi

docker compose pull
bash ./verify-images.sh

# Migrations run only after every old application writer and ingress is stopped.
docker compose stop \
  caddy app-web api doc-sync browser-relay \
  discord-connector wa-connector wechat-connector feishu-connector

if ! docker compose up -d; then
  echo "Update failed after application writers were stopped." >&2
  echo "Inspect 'docker compose logs migrate grant-app-role' before retrying or restoring." >&2
  exit 1
fi

docker compose ps
