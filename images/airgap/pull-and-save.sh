#!/usr/bin/env bash
# Pull every image listed in images/manifest.txt and save each to a .tar file
# in the output directory. Run this on a host with internet access; ship the
# resulting directory to the air-gapped target by your customer's approved
# transfer method (SFTP, USB, approved share, etc.).
#
# Usage:
#   bash images/airgap/pull-and-save.sh ./tars [linux/amd64]
#
# Auth:
#   For private ghcr.io/autonox-ai images, either run `gh auth login` first or
#   set GHCR_USER and GHCR_TOKEN. Set GHCR_LOGIN=0 to skip this login step.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/../manifest.txt"
OUT_DIR="${1:-./tars}"
PLATFORM="${2:-linux/amd64}"

if [[ ! -f "$MANIFEST" ]]; then
  echo "manifest not found: $MANIFEST" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

if [[ "${GHCR_LOGIN:-1}" != "0" ]] && grep -Eq '^[[:space:]]*ghcr\.io/autonox-ai/' "$MANIFEST"; then
  echo "Logging into GHCR"
  if [[ -n "${GHCR_USER:-}" && -n "${GHCR_TOKEN:-}" ]]; then
    printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin >/dev/null
  elif command -v gh >/dev/null 2>&1; then
    gh auth token | docker login ghcr.io -u "$(gh api user --jq .login)" --password-stdin >/dev/null
  else
    echo "GHCR auth needed for private AutoNox images." >&2
    echo "Run 'gh auth login', set GHCR_USER/GHCR_TOKEN, or set GHCR_LOGIN=0 if Docker is already logged in." >&2
    exit 1
  fi
fi

while IFS= read -r line; do
  # Strip comments and surrounding whitespace.
  image="${line%%#*}"
  image="${image#"${image%%[![:space:]]*}"}"
  image="${image%"${image##*[![:space:]]}"}"
  [[ -z "$image" ]] && continue

  # Slug: replace / and : with _ for a filesystem-safe name.
  slug="${image//\//_}"
  slug="${slug//:/_}"
  out="${OUT_DIR}/${slug}.tar"
  tmp="${out}.tmp"

  if [[ -f "$out" ]]; then
    echo "skip  $image (exists: $out)"
    continue
  fi

  echo "pull  $image  ($PLATFORM)"
  docker pull --platform="$PLATFORM" "$image"

  echo "save  $image -> $out"
  docker save --platform="$PLATFORM" -o "$tmp" "$image"
  mv "$tmp" "$out"
done < "$MANIFEST"

echo
echo "Done. Tars are in: $OUT_DIR"
ls -lh "$OUT_DIR"
