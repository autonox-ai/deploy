# Warehouse initialization and upgrades

This workload runs the Warehouse CLI operations that initialize or upgrade the
AutoNox Warehouse database. It is separate from the source import workflow:
run these operations before the first import and after a Warehouse image
upgrade when migrations or access-layer changes are required.

It does **not** create PostgreSQL itself, roles, passwords, base schemas, or
workspace schemas. Those prerequisites are owned by
[`../../postgres/README.md`](../../postgres/README.md) and its bootstrap SQL.

## Quickstart (against `postgres/compose`)

Assumes you already ran `postgres/compose` end to end: container up, role
passwords set, and `ws_setup.sql.tmpl` applied with `WS_NAME=prod`. Reuses
`NOXOP_PASSWORD` from that setup.

Config and secrets live outside this repository, in `$AUTONOX_HOME` (default
`/etc/autonox`), as in [`../../postgres/compose/README.md`](../../postgres/compose/README.md).
On VM-backed Docker (Colima, Lima, Docker Desktop with restricted file
sharing) it must sit under a path the VM mounts — usually `$HOME`. A path the
VM cannot see mounts as an *empty* directory, and the CLI then fails with
`WIRING_INPUT_NOT_FOUND` rather than a mount error.

```bash
cd workloads/warehouse
export AUTONOX_HOME="${AUTONOX_HOME:-/etc/autonox}"
export NOXOP_PASSWORD='<the password you set in postgres/compose step 5>'

mkdir -p "$AUTONOX_HOME/warehouse-config"
cp examples/config/warehouse-wiring.yaml \
   examples/config/warehouse-canonical-wiring.yaml "$AUTONOX_HOME/warehouse-config/"

cat > "$AUTONOX_HOME/warehouse.env" <<EOF
CONTAINER_NETWORK=autonox-local
WAREHOUSE_PLATFORM=linux/amd64
# This walkthrough only: reuse the repo's manifest pin. A real customer
# environment sets its own reference — see Inputs below.
WAREHOUSE_IMAGE=$(awk '/^ghcr\.io\/autonox-ai\/autonox-warehouse:/ { print; exit }' ../../images/manifest.txt)
WAREHOUSE_CONFIG_DIR=$AUTONOX_HOME/warehouse-config
WAREHOUSE_POSTGRES_DSN="postgresql://noxop:${NOXOP_PASSWORD}@postgres:5432/autonox"
WAREHOUSE_CANONICAL_SHARED_SCHEMA=shared
WORKSPACE_ID=prod
EOF
chmod 600 "$AUTONOX_HOME/warehouse.env"

WAREHOUSE_ENV_FILE="$AUTONOX_HOME/warehouse.env" ./run.sh upgrade-workspace \
  | tee "$AUTONOX_HOME/evidence-upgrade-workspace.log"
```

Each of the four steps prints `{"status":"ok"}`; the last also lists the
access-layer objects it created. Verify the database actually changed:

```bash
docker exec nox-pg18 psql -U postgres -d autonox \
  -c '\dt warehouse.*' -c '\dt ws_prod.*' -c '\dv bi_views.*'
```

Different workspace name, PG mode, or wiring? See **Inputs** below.

## Lifecycle

For each workspace, the normal initialization/upgrade sequence is:

1. `warehouse migrate` applies the Warehouse runtime migrations, including
   Bronze, Silver, Gold, and shared canonical migrations described by the full
   Warehouse wiring.
2. `warehouse canonical migrate --shared` applies shared canonical migrations
   through canonical wiring.
3. `warehouse canonical migrate --workspace-id <workspace>` applies canonical
   workspace tables such as accounts and entitlements.
4. `warehouse canonical install-access-layer --workspace-id <workspace>`
   installs BI, analytics, and audit access-layer objects.

All commands are designed to be rerun for an upgrade. Preserve their JSON
output as deployment evidence and verify the recorded migration versions in
PostgreSQL according to the customer operating procedure.

## Inputs

Used the Quickstart above? It already sets everything below. This section is
for other PG modes, workspace names, or custom wiring.

Copy `.env.example` to `$AUTONOX_HOME/warehouse.env` and set
environment-specific values, then point the runner at it with
`WAREHOUSE_ENV_FILE`. Without that variable the runner reads `.env` beside
`run.sh`, which puts customer config inside this repository — avoid it. The
runner loads the file locally but passes only the declared Warehouse variables
into the container.

Set only what differs from the runner's defaults; `.env.example` documents
each default inline.

Place the existing full and canonical wiring documents in `WAREHOUSE_CONFIG_DIR`
(mounted read-only at `/config` by default), or override their in-container
paths with `WAREHOUSE_WIRING_PATH` and `WAREHOUSE_CANONICAL_WIRING_PATH`.
Wiring remains the source of truth; this workload does not duplicate it.

For the shape of both documents, see the minimal working pair (single-Postgres
control plane, file artifact store) at
[`examples/config/`](examples/config/), used by the Quickstart above. Copy
them as a starting point and adjust `workspace_id` and any customer-specific
wiring (secrets providers, non-file artifact stores, etc.).

`WAREHOUSE_IMAGE` is required — the exact `autonox-warehouse` reference pinned
for this customer environment. There is no repo-wide default: each environment
upgrades on its own cadence, so [`../../images/manifest.txt`](../../images/manifest.txt)
cannot be authoritative for what a given deployment is actually running.

Runtime tuning (podman, SELinux mounts, Apple Silicon emulation) is documented
inline in `.env.example`.

## Run

```bash
cd workloads/warehouse
export WAREHOUSE_ENV_FILE="$AUTONOX_HOME/warehouse.env"

# Full sequence for WORKSPACE_ID
./run.sh upgrade-workspace
```

Individual lifecycle commands are also available:

```bash
./run.sh migrate
./run.sh canonical-shared
./run.sh canonical-workspace
./run.sh install-access-layer --require-all
```

`raw` is an escape hatch for a supported Warehouse CLI command not yet given a
named wrapper. It passes its arguments directly to the image:

```bash
./run.sh raw canonical install-access-layer --help
```

For canonical access-layer semantics and its optional organization-projection
flags, see the Warehouse repository's `docs/canonical_access_layer.md` for the
image version in use.

## Failure handling

Do not begin an import if a required migration command fails. Keep its JSON
output and logs, correct the wiring/database prerequisite, and rerun the same
idempotent command. Do not use this runner to drop schemas, reset a database,
or roll back an image; those are explicit DBA/deployment operations.
