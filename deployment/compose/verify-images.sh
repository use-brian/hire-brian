#!/usr/bin/env bash
set -euo pipefail

expected_revision=
while IFS= read -r image; do
  [[ "$image" == ghcr.io/use-brian/* ]] || continue
  revision=$(docker image inspect \
    --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' \
    "$image")
  if [ -z "$revision" ] || [ "$revision" = "<no value>" ]; then
    echo "$image has no source revision label." >&2
    exit 1
  fi
  if [ -z "$expected_revision" ]; then
    expected_revision=$revision
  elif [ "$revision" != "$expected_revision" ]; then
    echo "Image revision mismatch: $image is $revision, expected $expected_revision." >&2
    exit 1
  fi
done < <(docker compose config --images | sort -u)

[ -n "$expected_revision" ] || {
  echo "No Use Brian application images found in Compose config." >&2
  exit 1
}
echo "All Use Brian images match revision $expected_revision."
