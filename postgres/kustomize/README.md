# PostgreSQL (`pgvector`) on Kubernetes (mode 3 alt)

Simple pgvector-enabled Postgres deployment packaged as a Kubernetes
`StatefulSet`. **Not an operator.** Use this when the customer wants AutoNox
to manage Postgres on their cluster (mode 3) but on Kubernetes instead of
Docker Compose.

For mode 1 / mode 2 (customer-managed Postgres), apply
[`../bootstrap/setup.sql`](../bootstrap/setup.sql) against the customer's
instance instead.

After the bootstrap runs, apply
[`../bootstrap/passwords.sql`](../bootstrap/passwords.sql) with
customer-managed secret values to set the AutoNox application role passwords.

## What you get

* `Service` `pgvector` on port **5432**
* `StatefulSet` `pgvector` (1 replica) with a `PersistentVolumeClaim` for data
* initdb `ConfigMap` that enables `CREATE EXTENSION vector`
* a `Job` smoke test that verifies connectivity and pgvector availability

## What you must provide (required)

A Kubernetes `Secret` named **`pgvector-db`** with the following keys:

* `POSTGRES_DB`
* `POSTGRES_USER`
* `POSTGRES_PASSWORD`

> Do **not** commit real secrets to Git. Use your organization's secret
> management solution (Vault, ExternalSecrets, SealedSecrets, etc.).

An example secret manifest is provided in:

```
examples/customer-overlay/secret.pgvector-db.example.yaml
```

## Image version pinning

Container images are **not tagged in the base manifests**.

Image versions are centrally pinned via a Kustomize **Component** at
`postgres/kustomize/components/images`. The OpenShift overlay applies this
component automatically.

If you need to override the image version, do so in your own overlay by adding
an `images:` block or by supplying your own component.

## How to deploy (customer workflow)

Vendor/customer separation:

- **This repository** (`autonox-ai/deploy`) is read-only vendor content.
- **Your repository** contains environment-specific overlays and secrets.

Deploy pgvector by creating a customer-owned overlay.

### Step 1: Create a customer-owned overlay folder

In your own Git repository, create a folder for this deployment, e.g.
`acme-pgvector`, `prod-pgvector`. Start by copying the provided example:

```bash
cp -r postgres/kustomize/examples/customer-overlay ./acme-pgvector
cd acme-pgvector
```

Your overlay folder should contain:

```
acme-pgvector/
  kustomization.yaml
  secret.pgvector-db.example.yaml
```

### Step 2: Bind your overlay to the vendor repository

The example overlay uses **relative paths** that only work inside this repo.
After copying it into your own repo, update `kustomization.yaml` to reference
the vendor explicitly.

#### Replace this (example-relative path)

```yaml
resources:
  - ../../overlays/openshift
  - secret.pgvector-db.example.yaml
```

#### With one of:

##### Option A — Git reference (recommended)

```yaml
resources:
  - github.com/autonox-ai/deploy//postgres/kustomize/overlays/openshift?ref=v0.3.0
  - secret.pgvector-db.example.yaml
```

This binds your overlay to a specific vendor version.

##### Option B — Vendored copy (air-gapped environments)

Vendor the required files into your repository, e.g.:

```
vendor/
  autonox-deploy/
    postgres/kustomize/overlays/openshift
    postgres/kustomize/components/images
    postgres/kustomize/base
```

Then reference them locally:

```yaml
resources:
  - ../vendor/autonox-deploy/postgres/kustomize/overlays/openshift
  - secret.pgvector-db.example.yaml
```

### Step 3: Set the namespace

```yaml
namespace: autonox
```

Create it if needed:

```bash
oc new-project autonox
```

### Step 4: Configure storage (optional)

```yaml
patches:
  - target:
      kind: StatefulSet
      name: pgvector
    patch: |-
      - op: replace
        path: /spec/volumeClaimTemplates/0/spec/resources/requests/storage
        value: 50Gi
      - op: add
        path: /spec/volumeClaimTemplates/0/spec/storageClassName
        value: managed-csi
```

### Step 5: Create the database secret

```bash
oc apply -f secret.pgvector-db.example.yaml
```

### Step 6: Deploy

From your overlay directory:

```bash
oc apply -k .
```

### Step 7: Verify

```bash
oc get pods
oc get pvc
oc logs job/pgvector-smoke-test
```

The smoke test job must complete successfully.

## Uninstall

```bash
oc delete -k .
```

## Notes

* Intended for **development, POC, or controlled production** use cases.
* For advanced lifecycle management, HA, or backups, consider a managed
  Postgres service or a Postgres operator.
