#!/usr/bin/env bash
# Skeleton invocation for the flows workload.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/.env" ]] && set -a && . "${SCRIPT_DIR}/.env" && set +a

IMAGE="$(grep -E '^ghcr\.io/autonox-ai/flows:' "${SCRIPT_DIR}/../../images/manifest.txt" | head -n1 || true)"
: "${IMAGE:?could not resolve flows image from images/manifest.txt}"
IMAGE="${FLOWS_IMAGE:-$IMAGE}"

docker run --rm \
  --network=autonox-local \
  --env-file "${SCRIPT_DIR}/.env" \
  "$IMAGE" \
  "$@"
