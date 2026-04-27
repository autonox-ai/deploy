#!/usr/bin/env bash
# Skeleton invocation for the exporters workload.
# TODO: replace placeholders with the real CLI arguments once finalized.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/.env" ]] && set -a && . "${SCRIPT_DIR}/.env" && set +a

# Resolve the image reference from the manifest (first matching line).
IMAGE="$(grep -E '^ghcr\.io/autonox-ai/exporters:' "${SCRIPT_DIR}/../../images/manifest.txt" | head -n1 || true)"
: "${IMAGE:?could not resolve exporters image from images/manifest.txt}"

# Customer-overridable image (e.g. JFrog virtual repo rewrite).
IMAGE="${EXPORTERS_IMAGE:-$IMAGE}"

docker run --rm \
  --network=autonox-local \
  --env-file "${SCRIPT_DIR}/.env" \
  "$IMAGE" \
  "$@"
