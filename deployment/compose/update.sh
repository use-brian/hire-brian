#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh" "${1:-oss}"
preflight update
trap 'echo "Deployment failed. If writers were stopped, leave them stopped and inspect migration/grant logs before recovery." >&2' ERR
set -E
deploy
