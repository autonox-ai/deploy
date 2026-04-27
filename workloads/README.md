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
├── exporters/    # Pull data from upstream sources into the warehouse
├── warehouse/    # Migrations + materializations on the autonox database
└── flows/        # Reconciliation / policy flows on top of the warehouse
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

## Running a workload (example shape)

```bash
cd workloads/exporters
cp .env.example .env       # fill in connection + source-system credentials
bash run.sh
```

For Kubernetes, equivalent invocations are typically packaged as `CronJob`s
in the customer overlay; the same env vars apply.
