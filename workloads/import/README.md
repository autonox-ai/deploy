# Import workload

Runs the end-to-end source import flow: collection, Bronze registration and
commit, Silver intent emission, Reconciliation, and Silver finalization.

## Driver

`import.sh` is a receipt-driven, single-app orchestration driver. It runs each
CLI in an ephemeral Docker/Podman container and has no customer-specific paths,
images, credentials, or runtime mounts.

Settings live outside this repository, in `$AUTONOX_HOME` (conventionally
`/etc/autonox`) — the same place `workloads/warehouse` reads from. This tree is
vendor-supplied and gets replaced wholesale on upgrade, so nothing an operator
writes belongs inside it, least of all a DSN.

`.env.example` is one file covering two halves: the deployment-wide settings and
the ones that differ per source system. Split it accordingly.

```bash
cd workloads/import
export AUTONOX_HOME="${AUTONOX_HOME:-/etc/autonox}"
mkdir -p "$AUTONOX_HOME/sources"

cp .env.example "$AUTONOX_HOME/import.env"        # keep the deployment-wide half
cp .env.example "$AUTONOX_HOME/sources/hr.env"    # keep the per-source half
chmod 600 "$AUTONOX_HOME/import.env" "$AUTONOX_HOME"/sources/*.env

./run-import.sh hr start
```

`run-import.sh` is the entry point; `import.sh` is what it drives. Invoking the
driver directly is supported and is what the testkit does, but then composing
the environment correctly — and not leaking one source's settings into the next
run — becomes the caller's problem. The next section is why that is harder than
it looks.

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

The script requires **bash ≥ 4.3**, `jq`, a SHA-256 utility, and the configured
container runtime. The bash floor is a nameref (`local -n` in `read_nul_array`),
so macOS stock bash 3.2 fails — use Homebrew's bash there. Every image must be
pinned by digest. It writes immutable receipt
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

`resume` handles interruptions, not failures: it refuses a receipt recording a
failed task, because the orchestrator cannot know whether the subsystem's state
matches what the receipt says. Once you have inspected that state, `retry-task`
is the way forward:

```bash
OPERATOR_ID=asaf ./import.sh retry-task \
  --receipt "$RECEIPT_DIR"/<id>/receipt.12.json \
  --task reconciliation_evidence \
  --acknowledge 'queried the execution group; all 240 intents applied'
```

It archives the failed attempt under `tasks.<name>.history` rather than erasing
it, records the acknowledgement in `operator_actions`, and then resumes. Tasks
the receipt already proves succeeded are skipped — a retry never recollects,
re-registers a manifest, reruns `stage-run`, or reapplies intents.

Two tasks are refused deliberately. `collect` cannot be retried in place,
because recollecting creates a new source and Bronze run and is therefore a new
import (`start`). `preflight` is likewise a new attempt. A failed `silver`
before `intents_emitted` re-runs `silver run` with the same preallocated run
ID; if the Warehouse CLI rejects reusing that ID, start a new import against the
already committed Bronze run.

Receipt sequence numbers are forward-only: retrying or resuming from an older
receipt writes above the highest number on disk instead of overwriting the
receipts between, so `latest` never points at a worse state than evidence still
in the directory. `resumed_from` records which receipt an attempt started from.

The Silver workspace lock is the one thing a retry cannot recover. `warehouse
silver` exposes only `run` and `finalize` — there is no supported way to inspect
or release a held lock, so a run that cannot be finalized waits out the 7200s
expiry.

See [Import orchestration](import-orchestration.md) for the lifecycle,
failure handling, recovery rules, and scheduler integration requirements.
