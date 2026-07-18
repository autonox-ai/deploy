#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTKIT_ROOT="${TESTKIT_ROOT:-$ROOT/tmp/testkit}"
COMPOSE_FILE="${TESTKIT_POSTGRES_COMPOSE_FILE:-$ROOT/postgres/compose/compose.yaml}"
COMPOSE_PROJECT="${TESTKIT_COMPOSE_PROJECT:-autonox-testkit}"
WAREHOUSE_WORKLOAD="$ROOT/workloads/warehouse/run.sh"
IMPORT_WORKLOAD="$ROOT/workloads/import/import.sh"
SCENARIO_DIR="$ROOT/testkit/scenarios"
COMPOSE_CMD=()
PG_CONTAINER=""

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

# Resolve the running postgres container from Compose rather than assuming the
# name. compose.yaml pins container_name: nox-pg18, so that name does not follow
# TESTKIT_COMPOSE_PROJECT — asking Compose keeps the two from disagreeing, and
# keeps working if the pinned name is ever dropped.
pg_container() {
  if [[ -z "$PG_CONTAINER" ]]; then
    PG_CONTAINER="$(compose ps -q postgres 2>/dev/null | head -1)"
    [[ -n "$PG_CONTAINER" ]] || die "postgres container is not running; start it with: $0 up"
  fi
  printf '%s\n' "$PG_CONTAINER"
}

psql_super() {
  docker exec -i "$(pg_container)" psql -v ON_ERROR_STOP=1 -U postgres "$@"
}

wait_for_postgres() {
  local status cid
  for _ in {1..60}; do
    cid="$(compose ps -q postgres 2>/dev/null | head -1)"
    if [[ -n "$cid" ]]; then
      status="$(docker inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null || true)"
      [[ "$status" == healthy ]] && { PG_CONTAINER="$cid"; return 0; }
    fi
    sleep 1
  done
  [[ -n "${cid:-}" ]] && docker inspect "$cid" >&2 || true
  die "PostgreSQL did not become healthy"
}

usage() {
  cat <<'EOF'
Usage:
  testkit/run.sh e2e [scenario] [--workspace <name>]
  testkit/run.sh up
  testkit/run.sh down
  testkit/run.sh reset
  testkit/run.sh provision-workspace --workspace <name>
  testkit/run.sh set-passwords
  testkit/run.sh seed [scenario]
  testkit/run.sh migrate [--warehouse-env <file>]
  testkit/run.sh import --env <import-env-file>
  testkit/run.sh assert [scenario]
  testkit/run.sh status --receipt <receipt.json>
  testkit/run.sh scenario --warehouse-env <file> --import-env <file>

Commands:
  e2e       Whole run: reset, provision, passwords, seed, migrate, import,
            assert. Expects init.sh to have generated the env files first.
            Default scenario: mock-hr.
  up        Start the test PostgreSQL environment.
  down      Stop it while retaining the test volume.
  reset     Destroy and recreate the test PostgreSQL volume.
  provision-workspace  Apply the existing PostgreSQL workspace bootstrap template.
  set-passwords  Set local test-role passwords (fixtures, see NOXOP_PASSWORD).
  seed      Load a scenario's source data.
  migrate   Invoke workloads/warehouse/run.sh upgrade-workspace.
  import    Invoke workloads/import/import.sh start.
  assert    Run a scenario's expect.sql outcome checks.
  status    Invoke workloads/import/import.sh status.
  scenario  Run migrate followed by import.
EOF
}

run_e2e() {
  local scenario="$1" workspace="$2"
  local warehouse_env="$TESTKIT_ROOT/warehouse.env"
  local import_env="$TESTKIT_ROOT/import.env"

  for f in "$warehouse_env" "$import_env"; do
    [[ -f "$f" ]] || die "missing $f — generate it first with: testkit/init.sh $scenario"
  done

  printf '== reset ==\n';           compose down -v; compose up -d; wait_for_postgres
  printf '\n== provision (%s) ==\n' "$workspace"; provision_workspace "$workspace"
  printf '\n== passwords ==\n';     set_passwords
  printf '\n== seed (%s) ==\n' "$scenario"; seed_scenario "$scenario"
  printf '\n== migrate ==\n';       run_migrations "$warehouse_env"
  printf '\n== import ==\n';        run_import "$import_env"
  run_assertions "$scenario"
  printf '\ne2e passed (%s)\n' "$scenario"
}

provision_workspace() {
  local workspace="$1"
  [[ "$workspace" =~ ^[A-Za-z0-9_]+$ ]] || die "workspace must contain only letters, numbers, or underscores: $workspace"
  command -v envsubst >/dev/null 2>&1 || die "required command is unavailable: envsubst"
  WS_NAME="$workspace" envsubst < "$ROOT/postgres/bootstrap/ws_setup.sql.tmpl" \
    | psql_super -d postgres
  psql_super -d autonox -c 'GRANT USAGE, CREATE ON SCHEMA public TO noxop;'
}

# Local test-role passwords. These are fixtures, not credentials: the values are
# already baked into the env files init.sh generates, so the harness owning the
# step keeps the two in sync instead of relying on a copy-pasted docker exec.
set_passwords() {
  psql_super -d postgres \
    -v noxop_password="${NOXOP_PASSWORD:-local-noxop}" \
    -v noxreader_password="${NOXREADER_PASSWORD:-local-noxreader}" \
    -v bireader_password="${BIREADER_PASSWORD:-local-bireader}" \
    < "$ROOT/postgres/bootstrap/passwords.sql"
}

seed_scenario() {
  local scenario="$1"
  local dir="$SCENARIO_DIR/$scenario/source"
  [[ -d "$dir" ]] || die "scenario has no source directory: $dir"
  shopt -s nullglob
  local seeds=( "$dir"/*.sql )
  shopt -u nullglob
  [[ ${#seeds[@]} -gt 0 ]] || die "scenario has no .sql seed data in $dir"
  local seed
  for seed in "${seeds[@]}"; do
    printf 'seed  %s\n' "$(basename "$seed")"
    psql_super -d postgres < "$seed"
  done
}

# Outcome assertions: a scenario may ship expect.sql, which must exit non-zero
# on a failed expectation. Without this, a green run only proves import.sh's own
# gates passed, not that the images produced the right rows.
run_assertions() {
  local scenario="$1"
  local expect="$SCENARIO_DIR/$scenario/expect.sql"
  if [[ ! -f "$expect" ]]; then
    printf 'note: %s has no expect.sql — outcome not asserted\n' "$scenario" >&2
    return 0
  fi
  printf '\n== asserting expected state (%s) ==\n' "$scenario"
  psql_super -d autonox < "$expect"
  printf 'assertions passed\n'
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
    e2e)
      shift
      local scenario="mock-hr" workspace="hello"
      if [[ $# -gt 0 && "$1" != --* ]]; then scenario="$1"; shift; fi
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --workspace) workspace="${2:?missing value for --workspace}"; shift 2 ;;
          *) die "unexpected e2e argument: $1" ;;
        esac
      done
      run_e2e "$scenario" "$workspace"
      ;;
    set-passwords)
      shift; [[ $# -eq 0 ]] || die "set-passwords takes no arguments"
      set_passwords
      ;;
    seed)
      shift
      local scenario="${1:-mock-hr}"; [[ $# -eq 0 ]] || shift
      [[ $# -eq 0 ]] || die "unexpected seed arguments: $*"
      seed_scenario "$scenario"
      ;;
    assert)
      shift
      local scenario="${1:-mock-hr}"; [[ $# -eq 0 ]] || shift
      [[ $# -eq 0 ]] || die "unexpected assert arguments: $*"
      run_assertions "$scenario"
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
