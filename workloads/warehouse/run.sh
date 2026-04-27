#!/usr/bin/env bash
# Skeleton invocation for the warehouse workload.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/.env" ]] && set -a && . "${SCRIPT_DIR}/.env" && set +a

IMAGE="$(grep -E '^ghcr\.io/autonox-ai/warehouse:' "${SCRIPT_DIR}/../../images/manifest.txt" | head -n1 || true)"
: "${IMAGE:?could not resolve warehouse image from images/manifest.txt}"
IMAGE="${WAREHOUSE_IMAGE:-$IMAGE}"

docker run --rm \
  --network=autonox-local \
  --env-file "${SCRIPT_DIR}/.env" \
  "$IMAGE" \
  "$@"
