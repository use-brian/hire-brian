#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh" "${1:-oss}"
case "${2:-check}" in
  check) preflight ;;
  up)
    # Resume/install or change modes with the same safe ordering as an update.
    preflight update
    deploy
    ;;
  ps|logs) "${COMPOSE[@]}" "${2}" ;;
  *) echo "Usage: bash stack.sh [oss|outpost] [check|up|ps|logs]" >&2; exit 1 ;;
esac
