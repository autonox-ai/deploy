# Workloads

The AutoNox runtime is a set of **batch CLI dockers** (not long-running
services). Each workload is a separate image; an operator (or a scheduler
like cron / Kubernetes `CronJob`) invokes them on a schedule.

This folder holds the **invocation scripts** customers use to run those
workloads. Each subfolder is one workload.

## Image source

Workload images come from the references in
[`../images/manifest.txt`](../images/manifest.txt). Whichever delivery path
the customer used (JFrog or air-gap — see [`../images/`](../images/)), the
images must be available to the local Docker daemon before any of these
scripts will succeed.

## Folder map

```
workloads/
├── import/       # End-to-end collection-to-warehouse import orchestration
└── warehouse/    # Migrations + materializations on the autonox database
```

> Each `run.sh` here is a **skeleton**. It demonstrates the invocation shape
> (image ref, env vars, network, mounts) but the real argument lists land in
> follow-up commits as each workload is wired in.

## Common preconditions

Every workload assumes:

1. PostgreSQL is reachable and bootstrapped — see
   [`../postgres/README.md`](../postgres/README.md).
2. The container can reach Postgres on the `autonox-local` network (Compose
   path) or via the `pgvector` service (Kubernetes path).
3. Credentials are passed via environment variables, never baked into images.

## Running a standalone workload (example shape)

Settings live in `$AUTONOX_HOME` (conventionally `/etc/autonox`), never in this
repository — it is a vendor tree replaced wholesale on upgrade, so anything an
operator writes into it is lost on the next one, silently.

```bash
export AUTONOX_HOME=/etc/autonox

cp workloads/warehouse/.env.example "$AUTONOX_HOME/warehouse.env"
chmod 600 "$AUTONOX_HOME/warehouse.env"           # it holds a DSN
bash workloads/warehouse/run.sh upgrade-workspace

cp workloads/import/.env.example "$AUTONOX_HOME/import.env"
bash workloads/import/run-import.sh hr start
```

Each workload's README covers its own settings; import splits its env file into
a deployment-wide half and one file per source system.

For Kubernetes, equivalent invocations are typically packaged as `CronJob`s
in the customer overlay; the same env vars apply.

## Import orchestration

[`import/import-orchestration.md`](import/import-orchestration.md) defines the
end-to-end collection-to-warehouse lifecycle, durable hand-offs, recovery, and
ETL/scheduler integration requirements.
