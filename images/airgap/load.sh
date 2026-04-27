#!/usr/bin/env bash
# Load every .tar file in the input directory into the local Docker daemon.
# Run this on the air-gapped target host after the tars have been transferred.
#
# Usage:
#   bash images/airgap/load.sh ./tars

set -euo pipefail

IN_DIR="${1:-./tars}"

if [[ ! -d "$IN_DIR" ]]; then
  echo "input directory not found: $IN_DIR" >&2
  exit 1
fi

shopt -s nullglob
tars=( "$IN_DIR"/*.tar )

if [[ ${#tars[@]} -eq 0 ]]; then
  echo "no .tar files in $IN_DIR" >&2
  exit 1
fi

for tar in "${tars[@]}"; do
  echo "load  $tar"
  docker load -i "$tar"
done

echo
echo "Loaded images:"
docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}'
