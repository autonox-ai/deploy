# Warehouse initialization and upgrades

This workload runs the Warehouse CLI operations that initialize or upgrade the
AutoNox Warehouse database. It is separate from the source import workflow:
run these operations before the first import and after a Warehouse image
upgrade when migrations or access-layer changes are required.

It does **not** create PostgreSQL itself, roles, passwords, base schemas, or
workspace schemas. Those prerequisites are owned by
[`../../postgres/README.md`](../../postgres/README.md) and its bootstrap SQL.

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

Copy `.env.example` to `.env` and set environment-specific values. The runner
loads it locally but passes only the declared Warehouse variables into the
container.

Place the existing full and canonical wiring documents in `WAREHOUSE_CONFIG_DIR`
(mounted read-only at `/config` by default), or override their in-container
paths with `WAREHOUSE_WIRING_PATH` and `WAREHOUSE_CANONICAL_WIRING_PATH`.
Wiring remains the source of truth; this workload does not duplicate it.

The runner resolves `autonox-warehouse` from
[`../../images/manifest.txt`](../../images/manifest.txt). Set `WAREHOUSE_IMAGE`
only for an approved registry rewrite or pinned override.

Use `CONTAINER_RUNTIME=docker` or `CONTAINER_RUNTIME=podman`. For a customer
network, set `CONTAINER_NETWORK`; for SELinux volume labeling, set
`CONTAINER_MOUNT_SUFFIX=:Z`. Neither is required by the workload contract.
When using the currently published AMD64-only images from Apple Silicon, set
`WAREHOUSE_PLATFORM=linux/amd64` and ensure Docker emulation is enabled.

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
