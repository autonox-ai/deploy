#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTKIT_ROOT="${TESTKIT_ROOT:-$ROOT/tmp/testkit}"
SCENARIO="${1:-mock-hr}"
SEED=0

usage() {
  cat <<'EOF'
Usage:
  testkit/init.sh [scenario] [--seed]

Generates local warehouse/import env files under ./tmp/testkit by default.
The default scenario is mock-hr.
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"; }

[[ "${1:-}" != "-h" && "${1:-}" != "--help" ]] || { usage; exit 0; }

if [[ "${2:-}" == "--seed" ]]; then
  SEED=1
elif [[ -n "${2:-}" ]]; then
  die "unexpected argument: $2"
fi
[[ -n "$SCENARIO" ]] || die "scenario is required"

need docker
need awk
need mkdir
need cat

case "$SCENARIO" in
  mock-hr)
    IMPORT_CONFIG_DIR="$ROOT/testkit/scenarios/mock-hr/config"
    WAREHOUSE_CONFIG_DIR="$ROOT/testkit/scenarios/example/config"
    ;;
  example)
    IMPORT_CONFIG_DIR="$ROOT/testkit/scenarios/example/config"
    WAREHOUSE_CONFIG_DIR="$ROOT/testkit/scenarios/example/config"
    ;;
  *)
    die "unknown scenario: $SCENARIO"
    ;;
esac

mkdir -p "$TESTKIT_ROOT/artifacts" "$TESTKIT_ROOT/receipts"
mkdir -p "$TESTKIT_ROOT/container-tmp"
chmod -R a+rwX "$TESTKIT_ROOT/artifacts" || true

image_tag() {
  awk -v prefix="$1" '$0 ~ "^" prefix { print; exit }' "$ROOT/images/manifest.txt"
}

# Resolve an image to the most pinned reference available locally, pulling only
# if it is absent. Air-gapped hosts have images pre-loaded by images/airgap and
# no registry to reach, so a pull must never be the first move.
#
# Images restored from a `docker save` tar carry no RepoDigests — the registry
# digest does not survive the round trip — so fall back to the manifest tag.
# That is still pinned by images/manifest.txt, and bundle.lock is what verifies
# the bytes on the air-gap path.
image_digest() {
  local image="$1" digest=""

  if ! docker image inspect "$image" >/dev/null 2>&1; then
    if [[ "${TESTKIT_OFFLINE:-0}" == "1" ]]; then
      die "image not present locally and TESTKIT_OFFLINE=1: $image (load it with images/airgap/load.sh)"
    fi
    printf 'pull  %s\n' "$image" >&2
    docker pull --platform linux/amd64 "$image" >/dev/null
  fi

  digest="$(docker image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "$image" 2>/dev/null || true)"
  if [[ -n "$digest" ]]; then
    printf '%s\n' "$digest"
  else
    printf 'note: %s has no registry digest (loaded from a tar?) — using the manifest tag\n' "$image" >&2
    printf '%s\n' "$image"
  fi
}

WAREHOUSE_IMAGE_TAG="$(image_tag 'ghcr\.io/autonox-ai/autonox-warehouse:')"
COLLECTOR_IMAGE_TAG="$(image_tag 'ghcr\.io/autonox-ai/collectors:')"
RECONCILE_IMAGE_TAG="$(image_tag 'ghcr\.io/autonox-ai/reconciliation:')"

[[ -n "$WAREHOUSE_IMAGE_TAG" ]] || die "warehouse image tag not found in images/manifest.txt"
[[ -n "$COLLECTOR_IMAGE_TAG" ]] || die "collectors image tag not found in images/manifest.txt"
[[ -n "$RECONCILE_IMAGE_TAG" ]] || die "reconciliation image tag not found in images/manifest.txt"

WAREHOUSE_IMAGE="$(image_digest "$WAREHOUSE_IMAGE_TAG")"
COLLECTOR_IMAGE="$(image_digest "$COLLECTOR_IMAGE_TAG")"
RECONCILE_IMAGE="$(image_digest "$RECONCILE_IMAGE_TAG")"

collector_volumes="$TESTKIT_ROOT/artifacts:/output"$'\n'"$IMPORT_CONFIG_DIR:$IMPORT_CONFIG_DIR:ro"
warehouse_volumes="$TESTKIT_ROOT/artifacts:/output"$'\n'"$TESTKIT_ROOT/container-tmp:/tmp"$'\n'"$WAREHOUSE_CONFIG_DIR:$WAREHOUSE_CONFIG_DIR:ro"$'\n'"$IMPORT_CONFIG_DIR:$IMPORT_CONFIG_DIR:ro"
reconcile_volumes="$TESTKIT_ROOT/artifacts:/output"$'\n'"$TESTKIT_ROOT/container-tmp:/tmp"$'\n'"$IMPORT_CONFIG_DIR:$IMPORT_CONFIG_DIR:ro"
collector_run_args=$'--platform\nlinux/amd64\n--user\n0\n--network\nautonox-local'
warehouse_run_args=$'--platform\nlinux/amd64\n--user\n0\n--network\nautonox-local'
reconcile_run_args=$'--platform\nlinux/amd64\n--user\n0\n--network\nautonox-local'
reconcile_env_names=$'RECONCILE_POSTGRES_DSN\nRECONCILE_WAREHOUSE_DSN'

cat > "$TESTKIT_ROOT/warehouse.env" <<EOF
CONTAINER_RUNTIME=docker
CONTAINER_NETWORK=autonox-local
WAREHOUSE_PLATFORM=linux/amd64
WAREHOUSE_IMAGE=$WAREHOUSE_IMAGE
WAREHOUSE_CONFIG_DIR=$WAREHOUSE_CONFIG_DIR
WAREHOUSE_WIRING_PATH=/config/warehouse-wiring.yaml
WAREHOUSE_CANONICAL_WIRING_PATH=/config/warehouse-canonical-wiring.yaml
WAREHOUSE_POSTGRES_DSN=postgresql://noxop:local-noxop@postgres:5432/autonox
WORKSPACE_ID=hello
EOF

cat > "$TESTKIT_ROOT/import.env" <<EOF
TENANT_ID=local
ENVIRONMENT=test
WORKSPACE_ID=hello
SYSTEM_INSTANCE_ID=mock-hr
TARGET_REF=warehouse/ws_hello
CONTAINER_RUNTIME=docker
COMPLETION_POLICY=none
COLLECTOR_IMG=$COLLECTOR_IMAGE
WAREHOUSE_IMG=$WAREHOUSE_IMAGE
RECONCILE_IMG=$RECONCILE_IMAGE
RECEIPT_DIR=$TESTKIT_ROOT/receipts
ARTIFACT_URI_PREFIX=shared://local/imports
ARTIFACT_HOST_ROOT=$TESTKIT_ROOT/artifacts
COLLECTOR_ARTIFACT_PATH_PREFIX=/output
WAREHOUSE_ARTIFACT_PATH_PREFIX=/output
RECONCILE_ARTIFACT_PATH_PREFIX=/output
COLLECTOR_SPEC=$IMPORT_CONFIG_DIR/collector.yaml
CONNECTION_CATALOG=$IMPORT_CONFIG_DIR/connections.yaml
COLLECTOR_ROOT_URI=/output
WAREHOUSE_WIRING=$WAREHOUSE_CONFIG_DIR/warehouse-wiring.yaml
FLOW_SPEC=$IMPORT_CONFIG_DIR/flow.yaml
BANDING_SPEC=$IMPORT_CONFIG_DIR/banding.yaml
RECONCILE_WIRING=$IMPORT_CONFIG_DIR/reconcile.yaml
POSTGRES_DSN=postgresql://noxop:local-noxop@postgres:5432/autonox
WAREHOUSE_POSTGRES_DSN=postgresql://noxop:local-noxop@postgres:5432/autonox
RECONCILE_POSTGRES_DSN=\$WAREHOUSE_POSTGRES_DSN
RECONCILE_WAREHOUSE_DSN=\$WAREHOUSE_POSTGRES_DSN
COLLECTOR_CONTAINER_ENV_NAMES=POSTGRES_DSN
WAREHOUSE_CONTAINER_ENV_NAMES=WAREHOUSE_POSTGRES_DSN
RECONCILE_CONTAINER_ENV_NAMES=$(printf '%q' "$reconcile_env_names")
COLLECTOR_CONTAINER_VOLUMES=$(printf '%q' "$collector_volumes")
WAREHOUSE_CONTAINER_VOLUMES=$(printf '%q' "$warehouse_volumes")
RECONCILE_CONTAINER_VOLUMES=$(printf '%q' "$reconcile_volumes")
COLLECTOR_CONTAINER_RUN_ARGS=$(printf '%q' "$collector_run_args")
WAREHOUSE_CONTAINER_RUN_ARGS=$(printf '%q' "$warehouse_run_args")
RECONCILE_CONTAINER_RUN_ARGS=$(printf '%q' "$reconcile_run_args")
EOF

printf 'Wrote:\n  %s\n  %s\n' "$TESTKIT_ROOT/warehouse.env" "$TESTKIT_ROOT/import.env"
printf '\nNext:\n  ./testkit/run.sh e2e %s\n' "$SCENARIO"

if (( SEED )); then
  [[ "$SCENARIO" == mock-hr ]] || die "--seed is only supported for mock-hr"
  # run.sh owns container resolution and lifecycle; do not duplicate it here.
  printf '\nSeeding %s\n' "$SCENARIO"
  "$ROOT/testkit/run.sh" seed "$SCENARIO"
fi
