#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Writable state never lands in the repository — it is a vendor tree that gets
# replaced wholesale on upgrade, and receipts are durable audit evidence.
# Unlike the customer-facing workloads this harness still defaults, so a fresh
# clone runs without ceremony.
TESTKIT_ROOT="${TESTKIT_ROOT:-${AUTONOX_HOME:-$HOME/.autonox}/var/testkit}"
SEED=0

usage() {
  cat <<'EOF'
Usage:
  testkit/init.sh [scenario] [--seed]

Generates local warehouse/import env files under
$AUTONOX_HOME/var/testkit (default $HOME/.autonox/var/testkit).
The default scenario is mock-hr.

A scenario is a directory under testkit/scenarios/ containing scenario.env
(identity and run shape), config/ (the documents import.sh consumes),
source/*.sql (seed data), and optionally expect.sql (outcome assertions).
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"; }

SCENARIO=""
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --seed)    SEED=1 ;;
    -*)        die "unexpected argument: $arg" ;;
    *)
      [[ -z "$SCENARIO" ]] || die "unexpected argument: $arg"
      SCENARIO="$arg"
      ;;
  esac
done
SCENARIO="${SCENARIO:-mock-hr}"

need docker
need awk
need mkdir
need cat

# A scenario is a directory, not a case branch: adding one must not require
# editing the harness. run.sh discovers seeds and assertions the same way.
SCENARIO_DIR="$ROOT/testkit/scenarios/$SCENARIO"
[[ -d "$SCENARIO_DIR" ]] || die "unknown scenario: $SCENARIO (expected $SCENARIO_DIR)"

SCENARIO_ENV="$SCENARIO_DIR/scenario.env"
[[ -f "$SCENARIO_ENV" ]] || die "scenario is missing scenario.env: $SCENARIO_ENV"
set -a
# shellcheck disable=SC1090
source "$SCENARIO_ENV"
set +a

for var in WORKSPACE_ID SYSTEM_INSTANCE_ID TENANT_ID ENVIRONMENT TARGET_REF COMPLETION_POLICY; do
  [[ -n "${!var:-}" ]] || die "$SCENARIO_ENV does not set $var"
done

# Same fixture default as run.sh set-passwords; override to point the
# generated env files at an existing database whose noxop password differs.
NOXOP_PASSWORD="${NOXOP_PASSWORD:-local-noxop}"
PG_HOST="${TESTKIT_PG_HOST:-postgres}"
NOXOP_DSN="postgresql://noxop:${NOXOP_PASSWORD}@${PG_HOST}:5432/autonox"

SOURCE_CONFIG_DIR="$SCENARIO_DIR/config"
[[ -d "$SOURCE_CONFIG_DIR" ]] || die "scenario is missing config/: $SOURCE_CONFIG_DIR"

for f in collector.yaml connections.yaml flow.yaml banding.yaml reconcile.yaml \
         warehouse-wiring.yaml warehouse-canonical-wiring.yaml; do
  [[ -f "$SOURCE_CONFIG_DIR/$f" ]] || die "scenario config is missing $f: $SOURCE_CONFIG_DIR/$f"
done

# Render the config pack rather than mounting the repo copy. Scenario config
# carries ${WORKSPACE_ID} and ${CONFIG_DIR} placeholders, so the workspace name
# is written once in scenario.env and the file:// URIs resolve wherever the
# repo happens to live. Rendering is also what keeps the tree read-only.
need envsubst
CONFIG_DIR="$TESTKIT_ROOT/config"
rm -rf "$CONFIG_DIR"
mkdir -p "$CONFIG_DIR"
for f in "$SOURCE_CONFIG_DIR"/*; do
  WORKSPACE_ID="$WORKSPACE_ID" CONFIG_DIR="$CONFIG_DIR" \
    envsubst '${WORKSPACE_ID} ${CONFIG_DIR}' < "$f" > "$CONFIG_DIR/$(basename "$f")"
done

# Every scenario is self-contained — no borrowing config from a sibling.
IMPORT_CONFIG_DIR="$CONFIG_DIR"
WAREHOUSE_CONFIG_DIR="$CONFIG_DIR"

# Cheap post-render check: an unrendered placeholder, or a scenario that wrote
# the workspace name literally somewhere, would otherwise surface much later as
# a reconcile binding error.
if grep -rlq '\${' "$CONFIG_DIR"; then
  die "unrendered placeholder left in $CONFIG_DIR: $(grep -rl '\${' "$CONFIG_DIR" | tr '\n' ' ')"
fi
rendered_workspace="$(awk '/^[[:space:]]*workspace_id:/ { print $2; exit }' "$CONFIG_DIR/warehouse-wiring.yaml")"
[[ "$rendered_workspace" == "$WORKSPACE_ID" ]] || die \
  "workspace mismatch after render: WORKSPACE_ID=$WORKSPACE_ID but warehouse-wiring.yaml workspace_id=${rendered_workspace:-<unset>}"
grep -q "warehouse/ws_${WORKSPACE_ID}:" "$CONFIG_DIR/reconcile.yaml" || die \
  "reconcile.yaml has no target_mapping for warehouse/ws_${WORKSPACE_ID}"

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
WAREHOUSE_POSTGRES_DSN=$NOXOP_DSN
WORKSPACE_ID=$WORKSPACE_ID
EOF

cat > "$TESTKIT_ROOT/import.env" <<EOF
TENANT_ID=$TENANT_ID
ENVIRONMENT=$ENVIRONMENT
WORKSPACE_ID=$WORKSPACE_ID
SYSTEM_INSTANCE_ID=$SYSTEM_INSTANCE_ID
TARGET_REF=$TARGET_REF
CONTAINER_RUNTIME=docker
COMPLETION_POLICY=$COMPLETION_POLICY
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
POSTGRES_DSN=$NOXOP_DSN
WAREHOUSE_POSTGRES_DSN=$NOXOP_DSN
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
  # run.sh owns container resolution and lifecycle; do not duplicate it here.
  # It also validates that the scenario actually ships seed data.
  printf '\nSeeding %s\n' "$SCENARIO"
  "$ROOT/testkit/run.sh" seed "$SCENARIO"
fi
