# autonox-ai/deploy

Single repository to deploy AutoNox into a customer environment. Each
top-level folder owns one concern; pick the subset that matches the
customer's situation.

## Principles

- **Reusable building blocks** (bases + generic overlays). Customers assemble
  deployments using their own environment overlays (namespace, storage,
  sizing, secrets).
- **Nothing here should require editing vendor files.** Override via
  Kustomize overlays/patches, `.env` files, or Terraform variables.
- **No baked-in secrets.** Every credential is sourced from a
  customer-managed file or Kubernetes Secret.

## Folder map

```
deploy/
├── postgres/    # PostgreSQL — bootstrap SQL + compose + kustomize (3 modes)
├── metabase/    # OPTIONAL self-hosted BI — compose + kustomize + Terraform + air-gap runner
├── images/      # Workload (batch CLI) image transfer — JFrog or air-gap
└── workloads/   # Invocation scripts for the AutoNox batch CLI dockers
```

## Start here

Start with PostgreSQL. AutoNox workloads need a reachable PostgreSQL database
before anything else can run, and the customer's PostgreSQL ownership model
determines which deploy folders matter.

1. **Choose the PostgreSQL mode** in [`postgres/README.md`](postgres/README.md).
   - **Mode 1:** the customer DBA delivers a ready-to-use database with users,
     schemas, extensions, and grants already in place.
   - **Mode 2:** the customer DBA delivers an empty PostgreSQL instance with
     admin credentials, and AutoNox runs the bootstrap SQL.
   - **Mode 3:** AutoNox also deploys PostgreSQL, either with Docker Compose on
     one Linux host or with Kustomize on Kubernetes / OpenShift.
2. **Choose image distribution** in [`images/README.md`](images/README.md).
   Use JFrog when the customer has it and allows that gateway to reach
   `ghcr.io`; use the air-gap flow when images must be transferred as files.
3. **Deploy optional BI** from [`metabase/README.md`](metabase/README.md) only
   if the customer does not already have a BI platform.
4. **Run workloads** from [`workloads/README.md`](workloads/README.md) after
   PostgreSQL is reachable, bootstrapped, and the images are available.

## Scenario guide

Use the first scenario that matches the customer environment.

### PG mode 1: DBA-managed, ready-to-use database

The customer's DBA provides the database, users, schemas, extensions, and
grants. Skip `postgres/` deployment work and pass the delivered connection
details to the AutoNox workloads.

Touch:

- `images/` to make workload images available.
- `workloads/` to run the batch CLI containers.
- `metabase/` only if the customer wants self-hosted Metabase.

### PG mode 2: DBA-managed empty database

The customer's DBA provides an empty PostgreSQL instance and admin credentials.
Run the AutoNox bootstrap SQL against that instance.

Touch:

- `postgres/bootstrap/` for roles, schemas, extensions, grants, and workspace
  provisioning.
- `images/` to make workload images available.
- `workloads/` to run the batch CLI containers.
- `metabase/` only if the customer wants self-hosted Metabase.

### PG mode 3: AutoNox-managed PostgreSQL on one Linux host

AutoNox runs PostgreSQL with Docker Compose. The compose setup applies the
bootstrap on first start.

Touch:

- `postgres/compose/` for the PostgreSQL container.
- `postgres/bootstrap/` for the SQL mounted into the compose service.
- `images/` to make workload images available.
- `workloads/` to run the batch CLI containers.
- `metabase/` only if the customer wants self-hosted Metabase.

### PG mode 3: AutoNox-managed PostgreSQL on Kubernetes / OpenShift

AutoNox runs PostgreSQL as a Kustomize-managed StatefulSet. Apply workspace
bootstrap after the database pod is ready.

Touch:

- `postgres/kustomize/` for the PostgreSQL StatefulSet and customer overlay.
- `postgres/bootstrap/` for the SQL applied after the database is running.
- `images/` to make workload images available.
- `workloads/` to run the batch CLI containers.
- `metabase/` only if the customer wants self-hosted Metabase.

## Per-component entry points

- [`postgres/README.md`](postgres/README.md) — three deployment modes,
  decision tree, and the bootstrap runbook.
- [`images/README.md`](images/README.md) — JFrog vs air-gap, plus the
  authoritative [`images/manifest.txt`](images/manifest.txt).
- [`metabase/README.md`](metabase/README.md) — end-to-end Metabase guide
  (DB bootstrap → service → declarative TF configuration).
- [`workloads/README.md`](workloads/README.md) — how the batch CLI dockers
  are invoked.

## Air-gap considerations

If the customer is fully offline, every networked step has a documented
substitute:

| Concern | Connected | Air-gapped |
|---|---|---|
| Workload images | JFrog → ghcr.io | [`images/airgap/`](images/airgap/) tar transfer |
| pgvector / metabase images | docker pull | included in `images/manifest.txt` for the same airgap flow |
| Metabase Terraform provider | `terraform init` | generated during the [`metabase-tf-runner`](.github/workflows/metabase-tf-runner.yml) image build |
| Running Metabase Terraform | local terraform CLI | [`metabase/tf-runner/`](metabase/tf-runner/) — prebuilt docker image |
| This repository itself | git clone | hand the customer a tar of the repo |
