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

## One source per run

An import run imports **one** source system. A deployment collecting from HR,
Active Directory and Entra runs the driver three times, and roughly a third of
the settings differ each time — `SYSTEM_INSTANCE_ID`, `COLLECTOR_SPEC`,
`FLOW_SPEC`, `COMPLETION_POLICY`, and the collector's own credentials and
mounts. The rest is deployment-wide.

`run-import.sh` owns that split so `import.sh` does not have to. It takes a
source name, composes `$AUTONOX_HOME/images.env`, `import.env` and
`sources/<source>.env` in an erased environment, and execs the driver:

```bash
AUTONOX_HOME=/etc/autonox ./run-import.sh entra start
AUTONOX_HOME=/etc/autonox ./run-import.sh hr status --receipt .../latest
```

The erased environment matters more than it looks: `set -a; source a.env;
source b.env` accumulates, so any variable the first source sets and the second
does not is still live. Running two sources from one shell can otherwise import
one system with another's settings, and nothing downstream would object.

Naming the source as an argument rather than selecting it through the
environment also keeps it visible where operators actually look — `ps`, the
journal, cron mail — and lets one systemd template unit serve every source. See
[`systemd/`](systemd/) for that reference deployment.

**Schedule imports into the same workspace so they cannot overlap.** Silver
takes one lock per workspace, not per source (`silver_workspace_locks` keys on
`workspace_id`), so a second concurrent import fails to acquire it. A run that
fails after emitting intents keeps the lock until it expires — 7200s by default
— so leave real headroom between sources.

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

The driver expects collector JSON to expose `run_id` and a successful report
status. If the collector also prints `report.uri` and `manifest.uri`, those are
used directly; otherwise the driver resolves `run.report.json` and
`run.manifest.json` from `ARTIFACT_HOST_ROOT` using `run_id`. Artifact URIs
must begin with `ARTIFACT_URI_PREFIX`, which maps to `ARTIFACT_HOST_ROOT` for
hashing and to a separate per-tool container path prefix through the declared
volumes.

The driver prints one line per task to stderr as it goes — `→ <task>` on start,
`✓ <task> (<seconds>) — <message>` on success — using the same messages it
records in the receipt. stdout stays empty, so callers parsing it are
unaffected, and schedulers capture the progress in their logs. Pass
`-q`/`--quiet` to suppress it; the receipt is written either way.

## When a step fails

The driver reports only which task failed — for example `silver failed; see
<RECEIPT_DIR>/<orchestration_run_id>/latest`. The tool's actual error is not in
that receipt; it is in the attempt log:

```bash
cat "$RECEIPT_DIR"/<orchestration_run_id>/attempts/<task>/*/stderr.log
```

That file holds the JSON error the CLI emitted — schema validation failures name
the offending path, and runtime errors carry a code such as
`ERR_BANDING_ATTRIBUTE_MISSING` with the source and key involved. Start there
before re-reading configuration.

The receipt itself is still the record of what ran: `tasks.<name>.status` shows
how far the orchestration got, and the run is resumable from it.

See [Import orchestration](import-orchestration.md) for the lifecycle,
failure handling, recovery rules, and scheduler integration requirements.
