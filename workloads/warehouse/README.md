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

```bash
cd workloads/warehouse

export NOXOP_PASSWORD='<the password you set in postgres/compose step 5>'

# For this local walkthrough only: reuse the repo's current manifest pin. A
# real customer environment must set WAREHOUSE_IMAGE explicitly instead — see
# Inputs below.
export WAREHOUSE_IMAGE="$(awk '/^ghcr\.io\/autonox-ai\/autonox-warehouse:/ { print; exit }' ../../images/manifest.txt)"

mkdir -p config
cp examples/config/warehouse-wiring.yaml examples/config/warehouse-canonical-wiring.yaml config/

cat <<EOF > .env
CONTAINER_RUNTIME=docker
CONTAINER_NETWORK=autonox-local
WAREHOUSE_PLATFORM=linux/amd64
WAREHOUSE_IMAGE=${WAREHOUSE_IMAGE}
WAREHOUSE_CONFIG_DIR=./config
WAREHOUSE_WIRING_PATH=/config/warehouse-wiring.yaml
WAREHOUSE_CANONICAL_WIRING_PATH=/config/warehouse-canonical-wiring.yaml
WAREHOUSE_POSTGRES_DSN="postgresql://noxop:${NOXOP_PASSWORD}@postgres:5432/autonox"
WAREHOUSE_CANONICAL_SHARED_SCHEMA=shared
WORKSPACE_ID=prod
EOF

./run.sh upgrade-workspace
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

Copy `.env.example` to `.env` and set environment-specific values. The runner
loads it locally but passes only the declared Warehouse variables into the
container.

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
cp .env.example .env
$EDITOR .env

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
