# autonox-ai/deploy

Single repository to deploy AutoNox into a customer environment. Each
top-level folder owns one concern; pick the subset that matches the
customer's situation.

## Principles

- **Reusable building blocks** (bases + generic overlays). Customers assemble
  deployments using their own environment overlays (namespace, storage,
  sizing, secrets).
- **Nothing here should require editing vendor files.** Override via
  Kustomize overlays/patches, env files, or Terraform variables.
- **Customer config lives outside this tree**, in `$AUTONOX_HOME` (default
  `/etc/autonox`) or in the customer's own Git repository for Kubernetes
  overlays. This repo is replaced wholesale on upgrade; anything written into
  it is lost. Generated output goes to `$AUTONOX_HOME/var/`.
- **No baked-in secrets.** Every credential is sourced from a
  customer-managed file or Kubernetes Secret.

## Folder map

```
deploy/
├── postgres/    # PostgreSQL — bootstrap SQL + compose + kustomize (3 modes)
├── metabase/    # OPTIONAL self-hosted BI — compose + kustomize + Terraform + air-gap runner
├── images/      # Workload (batch CLI) image transfer — JFrog or air-gap
├── workloads/   # Invocation scripts for the AutoNox batch CLI dockers
└── testkit/     # Harness for rehearsing a deployment end-to-end before doing it for real
```

## Start here

Start with PostgreSQL — AutoNox workloads need a reachable database before
anything else can run. Pick the customer's mode in
[`postgres/README.md`](postgres/README.md), then touch the matching folders:

| PG mode | Postgres folders | Always touch |
|---|---|---|
| 1 — DBA-managed, ready-to-use | none | `images/`, `workloads/`, `metabase/`* |
| 2 — DBA-managed, empty | `postgres/bootstrap/` | `images/`, `workloads/`, `metabase/`* |
| 3 — AutoNox-managed, Linux host | `postgres/compose/` + `bootstrap/` | `images/`, `workloads/`, `metabase/`* |
| 3 — AutoNox-managed, Kubernetes | `postgres/kustomize/` + `bootstrap/` | `images/`, `workloads/`, `metabase/`* |

\* only if the customer wants self-hosted BI

Then, for the always-touch folders: choose image distribution in
[`images/README.md`](images/README.md) (JFrog vs. air-gap), and run workloads
from [`workloads/README.md`](workloads/README.md) once PostgreSQL and the
images are ready.

## Per-component entry points

- [`postgres/README.md`](postgres/README.md) — three deployment modes,
  decision tree, and the bootstrap runbook.
- [`images/README.md`](images/README.md) — JFrog vs air-gap, plus the
  authoritative [`images/manifest.txt`](images/manifest.txt).
- [`metabase/README.md`](metabase/README.md) — end-to-end Metabase guide
  (DB bootstrap → service → declarative TF configuration).
- [`workloads/README.md`](workloads/README.md) — how the batch CLI dockers
  are invoked.
- [`testkit/README.md`](testkit/README.md) — rehearse a full deployment
  (provision → migrate → import → assert) against a scenario before running
  it against a real customer environment.

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
