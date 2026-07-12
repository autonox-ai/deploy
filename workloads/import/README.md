# Import workload

Runs the end-to-end source import flow: collection, Bronze registration and
commit, Silver intent emission, Reconciliation, and Silver finalization.

## Driver

`import.sh` is a receipt-driven, single-app orchestration driver. It runs each
CLI in an ephemeral Docker/Podman container and has no customer-specific paths,
images, credentials, or runtime mounts.

```bash
cd workloads/import
cp .env.example .env
# Fill in immutable image digests, existing configuration references, and paths.
set -a; source .env; set +a
./import.sh start
```

The script requires `jq`, a SHA-256 utility, and the configured container
runtime. Every image must be pinned by digest. It writes immutable receipt
versions below `RECEIPT_DIR/<orchestration_run_id>/`; use the latest receipt
there for safe inspection or recovery:

```bash
./import.sh status --receipt /srv/autonox/import-receipts/<id>/receipt.12.json
./import.sh resume --receipt /srv/autonox/import-receipts/<id>/receipt.12.json
```

Container customization is explicit and scoped per image. The newline-delimited
`COLLECTOR_CONTAINER_ENV_NAMES` and `COLLECTOR_CONTAINER_VOLUMES` variables
allow an Oracle collector, for example, to receive `TNS_ADMIN` and only the
wallet/client volumes it needs. Warehouse and Reconciliation receive none of
those values unless separately allow-listed. All task containers use `--rm`;
this removes the stopped container, not the image cache.

Receipts keep allow-listed variable names and container mount destinations, but
redact environment values, host-side mount sources, and runtime arguments.

The driver expects collector JSON to expose `run_id`, `report.uri`,
`report.status`, and `manifest.uri`. Artifact URIs must begin with
`ARTIFACT_URI_PREFIX`, which maps to `ARTIFACT_HOST_ROOT` for hashing and to a
separate per-tool container path prefix through the declared volumes.

See [Import orchestration](import-orchestration.md) for the lifecycle,
failure handling, recovery rules, and scheduler integration requirements.
