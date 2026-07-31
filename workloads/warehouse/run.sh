#!/usr/bin/env bash
# Portable Warehouse initialization and upgrade runner.
# It runs the Warehouse CLI container; it does not provision PostgreSQL roles
# or schemas. Those belong to deploy/postgres/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Nothing writable or customer-specific resolves relative to this script: the
# repository is a vendor tree that gets replaced wholesale on upgrade. Config
# lives in $AUTONOX_HOME, or is named outright with WAREHOUSE_ENV_FILE.
if [[ -z "${WAREHOUSE_ENV_FILE:-}" && -z "${AUTONOX_HOME:-}" ]]; then
  echo "ERROR: set AUTONOX_HOME (config lives in \$AUTONOX_HOME/warehouse.env)" >&2
  echo "       or point WAREHOUSE_ENV_FILE at the env file directly" >&2
  exit 2
fi
ENV_FILE="${WAREHOUSE_ENV_FILE:-${AUTONOX_HOME}/warehouse.env}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: env file does not exist: ${ENV_FILE}" >&2
  echo "       copy workloads/warehouse/.env.example there and fill it in" >&2
  exit 2
fi

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

usage() {
  cat <<'EOF'
Usage:
  run.sh migrate
  run.sh canonical-shared
  run.sh canonical-workspace
  run.sh install-access-layer [--require-all] [--org-projection-detect <value>]
  run.sh upgrade-workspace [--require-all]
  run.sh raw <warehouse CLI arguments...>

Commands:
  migrate              Apply the Warehouse runtime migrations.
  canonical-shared     Apply shared canonical migrations.
  canonical-workspace  Apply canonical migrations for WORKSPACE_ID.
  install-access-layer Install BI, analytics, and audit access-layer objects.
  upgrade-workspace    Run the preceding four commands in order.
  raw                  Pass arguments directly to the Warehouse CLI image.
EOF
}

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "ERROR: required environment variable is missing: ${name}" >&2
    exit 2
  fi
}

: "${WAREHOUSE_IMAGE:?set WAREHOUSE_IMAGE to the autonox-warehouse image pinned for this customer environment}"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-docker}"
CONTAINER_NETWORK="${CONTAINER_NETWORK:-}"
CONTAINER_MOUNT_SUFFIX="${CONTAINER_MOUNT_SUFFIX:-}"
WAREHOUSE_PLATFORM="${WAREHOUSE_PLATFORM:-}"
WAREHOUSE_CONFIG_DIR="${WAREHOUSE_CONFIG_DIR:-${AUTONOX_HOME:-}/warehouse-config}"
WAREHOUSE_WIRING_PATH="${WAREHOUSE_WIRING_PATH:-/config/warehouse-wiring.yaml}"
WAREHOUSE_CANONICAL_WIRING_PATH="${WAREHOUSE_CANONICAL_WIRING_PATH:-/config/warehouse-canonical-wiring.yaml}"

if [[ "${WAREHOUSE_CONFIG_DIR}" != /* ]]; then
  echo "ERROR: WAREHOUSE_CONFIG_DIR must be an absolute path outside this repository: ${WAREHOUSE_CONFIG_DIR}" >&2
  exit 2
fi

require_var WAREHOUSE_POSTGRES_DSN

if [[ ! -d "${WAREHOUSE_CONFIG_DIR}" ]]; then
  echo "ERROR: WAREHOUSE_CONFIG_DIR is not a directory: ${WAREHOUSE_CONFIG_DIR}" >&2
  exit 2
fi
if ! command -v "${CONTAINER_RUNTIME}" >/dev/null 2>&1; then
  echo "ERROR: container runtime not found: ${CONTAINER_RUNTIME}" >&2
  exit 2
fi

run_warehouse() {
  local -a args=(run --rm)
  if [[ -n "${WAREHOUSE_PLATFORM}" ]]; then
    args+=(--platform "${WAREHOUSE_PLATFORM}")
  fi
  if [[ -n "${CONTAINER_NETWORK}" ]]; then
    args+=(--network "${CONTAINER_NETWORK}")
  fi
  args+=(-v "${WAREHOUSE_CONFIG_DIR}:/config:ro${CONTAINER_MOUNT_SUFFIX}")
  args+=(-e WAREHOUSE_POSTGRES_DSN)
  if [[ -n "${WAREHOUSE_CANONICAL_SHARED_SCHEMA:-}" ]]; then
    args+=(-e WAREHOUSE_CANONICAL_SHARED_SCHEMA)
  fi
  if [[ -n "${WAREHOUSE_EXTRA_ENV_VARS:-}" ]]; then
    local name
    for name in ${WAREHOUSE_EXTRA_ENV_VARS}; do
      if [[ -z "${!name:-}" ]]; then
        echo "ERROR: WAREHOUSE_EXTRA_ENV_VARS names an unset variable: ${name}" >&2
        exit 2
      fi
      args+=(-e "${name}")
    done
  fi
  "${CONTAINER_RUNTIME}" "${args[@]}" "${WAREHOUSE_IMAGE}" "$@"
}

wiring_args() {
  local wiring_path="$1"
  printf '%s\0%s\0' --wiring "${wiring_path}"
  if [[ -n "${WAREHOUSE_SECRETS_PROVIDERS_URI:-}" ]]; then
    printf '%s\0%s\0' --secrets-providers-uri "${WAREHOUSE_SECRETS_PROVIDERS_URI}"
  fi
}

run_with_wiring() {
  local wiring_path="$1"
  shift
  local -a args=()
  while IFS= read -r -d '' value; do
    args+=("${value}")
  done < <(wiring_args "${wiring_path}")
  run_warehouse "$@" "${args[@]}"
}

announce() {
  printf '[warehouse workload] %s\n' "$*" >&2
}

require_workspace() {
  require_var WORKSPACE_ID
}

command="${1:-}"
case "${command}" in
  migrate)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    announce 'migrate runtime schemas'
    run_with_wiring "${WAREHOUSE_WIRING_PATH}" migrate
    ;;
  canonical-shared)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    announce 'migrate canonical shared schema'
    run_with_wiring "${WAREHOUSE_CANONICAL_WIRING_PATH}" canonical migrate --shared
    ;;
  canonical-workspace)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    require_workspace
    announce "migrate canonical workspace schema: ${WORKSPACE_ID}"
    run_with_wiring "${WAREHOUSE_CANONICAL_WIRING_PATH}" canonical migrate --workspace-id "${WORKSPACE_ID}"
    ;;
  install-access-layer)
    shift || true
    require_workspace
    announce "install canonical access layer: ${WORKSPACE_ID}"
    run_with_wiring "${WAREHOUSE_CANONICAL_WIRING_PATH}" canonical install-access-layer --workspace-id "${WORKSPACE_ID}" "$@"
    ;;
  upgrade-workspace)
    shift || true
    require_workspace
    announce 'upgrade workspace: runtime migrations'
    run_with_wiring "${WAREHOUSE_WIRING_PATH}" migrate
    announce 'upgrade workspace: canonical shared migrations'
    run_with_wiring "${WAREHOUSE_CANONICAL_WIRING_PATH}" canonical migrate --shared
    announce "upgrade workspace: canonical workspace migrations: ${WORKSPACE_ID}"
    run_with_wiring "${WAREHOUSE_CANONICAL_WIRING_PATH}" canonical migrate --workspace-id "${WORKSPACE_ID}"
    announce "upgrade workspace: install access layer: ${WORKSPACE_ID}"
    run_with_wiring "${WAREHOUSE_CANONICAL_WIRING_PATH}" canonical install-access-layer --workspace-id "${WORKSPACE_ID}" "$@"
    ;;
  raw)
    shift || true
    [[ $# -gt 0 ]] || { usage >&2; exit 2; }
    run_warehouse "$@"
    ;;
  -h|--help|help|'')
    usage
    ;;
  *)
    echo "ERROR: unknown command: ${command}" >&2
    usage >&2
    exit 2
    ;;
esac
