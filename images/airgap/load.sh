#!/usr/bin/env bash
# Load an air-gap bundle produced by pull-and-save.sh into the local Docker
# daemon. Run this on the air-gapped target host after the bundle has been
# transferred.
#
# The bundle's bundle.lock is the authority on what belongs: this script loads
# exactly the images it lists and verifies each against its recorded image ID,
# so a stale or truncated tar fails loudly instead of installing a build nobody
# asked for.
#
# Usage:
#   bash images/airgap/load.sh ./tars

set -euo pipefail

IN_DIR="${1:-./tars}"
LOCK="${IN_DIR}/bundle.lock"

if [[ ! -d "$IN_DIR" ]]; then
  echo "input directory not found: $IN_DIR" >&2
  exit 1
fi

shopt -s nullglob

if [[ ! -f "$LOCK" ]]; then
  # A bundle from before pull-and-save.sh wrote locks. Loadable, but nothing
  # here can tell whether these tars match the manifest they were built from.
  tars=( "$IN_DIR"/*.tar )
  if [[ ${#tars[@]} -eq 0 ]]; then
    echo "no .tar files in $IN_DIR" >&2
    exit 1
  fi
  echo "WARNING: no bundle.lock in $IN_DIR — loading every tar, unverified." >&2
  echo "         Regenerate with pull-and-save.sh to get verification." >&2
  echo
  for tar in "${tars[@]}"; do
    echo "load  $tar"
    docker load -i "$tar"
  done
  echo
  echo "Loaded (unverified). Check against images/manifest.txt before deploying."
  exit 0
fi

loaded=0
failed=()
expected=()

while IFS=$'\t' read -r image id _digest tar_name; do
  [[ -z "$image" || "$image" == \#* ]] && continue
  expected+=( "$tar_name" )

  tar="${IN_DIR}/${tar_name}"
  if [[ ! -f "$tar" ]]; then
    echo "MISS  $image (bundle.lock expects $tar_name, not in $IN_DIR)" >&2
    failed+=( "$image" )
    continue
  fi

  echo "load  $image"
  docker load -i "$tar" >/dev/null

  got="$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null || true)"
  if [[ -z "$got" ]]; then
    echo "FAIL  $image (tar loaded but the ref is absent — wrong tar for this entry?)" >&2
    failed+=( "$image" )
  elif [[ "$got" != "$id" ]]; then
    echo "FAIL  $image (expected $id, loaded $got)" >&2
    failed+=( "$image" )
  else
    echo "ok    $image"
    loaded=$(( loaded + 1 ))
  fi
done < "$LOCK"

# Extra tars are not an error — they are simply not part of this bundle.
for tar in "$IN_DIR"/*.tar; do
  name="$(basename "$tar")"
  keep=0
  for want in "${expected[@]}"; do
    [[ "$name" == "$want" ]] && { keep=1; break; }
  done
  (( keep )) || echo "note  $name is not in bundle.lock — not loaded"
done

echo
if [[ ${#failed[@]} -gt 0 ]]; then
  echo "${#failed[@]} image(s) failed to load or verify:" >&2
  printf '  %s\n' "${failed[@]}" >&2
  exit 1
fi

echo "Loaded and verified $loaded image(s) from $IN_DIR"
