#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh" "${1:-oss}"
preflight
verify_images
