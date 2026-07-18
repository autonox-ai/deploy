#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_FILE="${TESTKIT_POSTGRES_COMPOSE_FILE:-$ROOT/deploy/postgres/compose/compose.yaml}"
COMPOSE_PROJECT="${TESTKIT_COMPOSE_PROJECT:-autonox-testkit}"
WAREHOUSE_WORKLOAD="$ROOT/deploy/workloads/warehouse/run.sh"
IMPORT_WORKLOAD="$ROOT/deploy/workloads/import/import.sh"
COMPOSE_CMD=()

die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"; }

compose() {
  "${COMPOSE_CMD[@]}" -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" "$@"
}

select_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
  else
    die "Docker Compose is unavailable; install the Compose plugin or docker-compose"
  fi
}

wait_for_postgres() {
  local status
  for _ in {1..60}; do
    status="$(docker inspect -f '{{.State.Health.Status}}' nox-pg18 2>/dev/null || true)"
    [[ "$status" == healthy ]] && return 0
    sleep 1
  done
  docker inspect nox-pg18 >&2 || true
  die "PostgreSQL did not become healthy"
}

usage() {
  cat <<'EOF'
Usage:
  deploy/testkit/run.sh up
  deploy/testkit/run.sh down
  deploy/testkit/run.sh reset
  deploy/testkit/run.sh provision-workspace --workspace <name>
  deploy/testkit/run.sh migrate [--warehouse-env <file>]
  deploy/testkit/run.sh import --env <import-env-file>
  deploy/testkit/run.sh status --receipt <receipt.json>
  deploy/testkit/run.sh scenario --warehouse-env <file> --import-env <file>

Commands:
  up        Start the test PostgreSQL environment.
  down      Stop it while retaining the test volume.
  reset     Destroy and recreate the test PostgreSQL volume.
  provision-workspace  Apply the existing PostgreSQL workspace bootstrap template.
  migrate   Invoke workloads/warehouse/run.sh upgrade-workspace.
  import    Invoke workloads/import/import.sh start.
  status    Invoke workloads/import/import.sh status.
  scenario  Run migrate followed by import.
EOF
}

provision_workspace() {
  local workspace="$1"
  [[ "$workspace" =~ ^[A-Za-z0-9_]+$ ]] || die "workspace must contain only letters, numbers, or underscores: $workspace"
  command -v envsubst >/dev/null 2>&1 || die "required command is unavailable: envsubst"
  WS_NAME="$workspace" envsubst < "$ROOT/deploy/postgres/bootstrap/ws_setup.sql.tmpl" \
    | docker exec -i nox-pg18 psql -U postgres -d postgres
  docker exec -i nox-pg18 psql -U postgres -d autonox -c 'GRANT USAGE, CREATE ON SCHEMA public TO noxop;'
}

warehouse_env_file() {
  [[ -n "${WAREHOUSE_ENV_FILE:-}" ]] || die "set WAREHOUSE_ENV_FILE or pass --warehouse-env <file>"
  printf '%s\n' "$WAREHOUSE_ENV_FILE"
}

run_migrations() {
  local env_file="${1:-$(warehouse_env_file)}"
  [[ -f "$env_file" ]] || die "Warehouse env file does not exist: $env_file"
  WAREHOUSE_ENV_FILE="$env_file" "$WAREHOUSE_WORKLOAD" upgrade-workspace
}

run_import() {
  local env_file="$1"
  [[ -f "$env_file" ]] || die "Import env file does not exist: $env_file"
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
  "$IMPORT_WORKLOAD" start
}

main() {
  need docker
  select_compose
  local command="${1:-}"
  case "$command" in
    up)
      shift; [[ $# -eq 0 ]] || die "up takes no arguments"
      compose up -d
      wait_for_postgres
      ;;
    down)
      shift; [[ $# -eq 0 ]] || die "down takes no arguments"
      compose down
      ;;
    reset)
      shift; [[ $# -eq 0 ]] || die "reset takes no arguments"
      compose down -v
      compose up -d
      wait_for_postgres
      ;;
    provision-workspace)
      shift
      [[ "${1:-}" == --workspace && -n "${2:-}" ]] || die "provision-workspace requires --workspace <name>"
      local workspace="$2"; shift 2
      [[ $# -eq 0 ]] || die "unexpected provision-workspace arguments: $*"
      provision_workspace "$workspace"
      ;;
    migrate)
      shift
      local env_file=""
      if [[ "${1:-}" == --warehouse-env ]]; then
        [[ -n "${2:-}" ]] || die "--warehouse-env requires a file"
        env_file="$2"; shift 2
      fi
      [[ $# -eq 0 ]] || die "unexpected migrate arguments: $*"
      [[ -n "$env_file" ]] || env_file="$(warehouse_env_file)"
      run_migrations "$env_file"
      ;;
    import)
      shift
      [[ "${1:-}" == --env && -n "${2:-}" ]] || die "import requires --env <file>"
      local import_env="$2"; shift 2
      [[ $# -eq 0 ]] || die "unexpected import arguments: $*"
      run_import "$import_env"
      ;;
    status)
      shift
      [[ "${1:-}" == --receipt && -n "${2:-}" ]] || die "status requires --receipt <file>"
      local receipt="$2"; shift 2
      [[ $# -eq 0 ]] || die "unexpected status arguments: $*"
      "$IMPORT_WORKLOAD" status --receipt "$receipt"
      ;;
    scenario)
      shift
      local warehouse_env="" import_env=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --warehouse-env) warehouse_env="${2:?missing value for --warehouse-env}"; shift 2 ;;
          --import-env) import_env="${2:?missing value for --import-env}"; shift 2 ;;
          *) die "unexpected scenario argument: $1" ;;
        esac
      done
      [[ -n "$warehouse_env" ]] || warehouse_env="$(warehouse_env_file)"
      [[ -n "$import_env" ]] || die "scenario requires --import-env <file>"
      run_migrations "$warehouse_env"
      run_import "$import_env"
      ;;
    -h|--help|help|'') usage ;;
    *) die "unknown command: $command" ;;
  esac
}

main "$@"
