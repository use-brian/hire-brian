#!/usr/bin/env bash

# Source this file, select a profile, then build a release directory.
# build_filters contains Turbo CLI selectors (not dependency-closure selectors).
native_build_filters() {
  build_filters=()
  case "${1:-}" in
    oss|outpost) ;;
    *) echo 'native_build_filters: expected oss or outpost' >&2; return 2 ;;
  esac

  build_filters=(
    --filter=@use-brian/api-open
    --filter=app-web
    --filter=@use-brian/doc-sync
    --filter=@use-brian/browser-relay
  )
  if [ "$1" = outpost ]; then build_filters+=(--filter=@use-brian/auth-web); fi
  # The optional local Chromium desktop loads this unpacked extension.
  # Its default build is Chromium-only; never invoke build:firefox.
  if [ "${INSTALL_BROWSER:-no}" = yes ]; then build_filters+=(--filter=@use-brian/browser-extension); fi
  if [ "${ENABLE_DISCORD:-}" = yes ]; then build_filters+=(--filter=@use-brian/discord-connector); fi
  if [ "${ENABLE_WHATSAPP:-}" = yes ]; then build_filters+=(--filter=@use-brian/wa-connector); fi
  if [ "${ENABLE_WECHAT:-}" = yes ]; then build_filters+=(--filter=@use-brian/wechat-connector); fi
  if [ "${ENABLE_FEISHU:-}" = yes ]; then build_filters+=(--filter=@use-brian/feishu-connector); fi
  return 0
}

# A subshell preserves the caller's working directory and environment. Explicit
# failure checks also work when invoked in an if/|| context (errexit disabled).
build_native_release() (
  if [ "$#" -ne 1 ] || [ -z "${1:-}" ]; then
    echo 'build_native_release: expected a release directory' >&2
    return 2
  fi
  if [ -z "${build_filters[*]:-}" ]; then
    echo 'build_native_release: select build_filters first' >&2
    return 2
  fi
  local filter
  local -a install_filters=()
  for filter in "${build_filters[@]}"; do
    install_filters+=("${filter}...")
  done
  # Needed by migrations, but not an additional top-level Turbo build target.
  install_filters+=(--filter=@use-brian/api...)

  cd -- "$1" || return $?
  PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
    PUPPETEER_SKIP_DOWNLOAD=true \
    ELECTRON_SKIP_BINARY_DOWNLOAD=1 \
    corepack pnpm "${install_filters[@]}" install --frozen-lockfile --prod=false || return $?
  # A clean @use-brian/api TypeScript compile exceeds Node's default heap
  # (~2 GiB below 16 GB RAM, regardless of swap); the hosted Docker build
  # stage uses the same 4096 MiB cap. Build-only: never set for services.
  NODE_ENV=production NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--max-old-space-size=4096" \
    corepack pnpm turbo run build --concurrency=1 "${build_filters[@]}" || return $?
)
