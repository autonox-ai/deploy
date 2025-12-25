# pgvector (Postgres) — Kustomize bundle (third-party)

This is a **simple pgvector-enabled Postgres** deployment packaged as a Kubernetes
`StatefulSet`.

It is **not an operator**.

This bundle is intended as an **optional third-party dependency** for Autonox
when a managed Postgres service is not available.

---

## What you get

* `Service` `pgvector` on port **5432**
* `StatefulSet` `pgvector` (1 replica) with a `PersistentVolumeClaim` for data
* initdb `ConfigMap` that enables `CREATE EXTENSION vector`
* a `Job` smoke test that verifies connectivity and pgvector availability

---

## What you must provide (required)

A Kubernetes `Secret` named **`pgvector-db`** with the following keys:

* `POSTGRES_DB`
* `POSTGRES_USER`
* `POSTGRES_PASSWORD`

> ⚠️ Do **not** commit real secrets to Git.
> Use your organization’s secret management solution
> (Vault, ExternalSecrets, SealedSecrets, etc.).

An example secret manifest is provided in:

```
examples/customer-overlay/secret.pgvector-db.example.yaml
```

---

## Image version pinning

Container images are **not tagged in the base manifests**.

Image versions are centrally pinned via a Kustomize **Component**:

````

dist/kustomize/shared/components/images

````

If you need to override the image version, do so in your own overlay by adding an
`images:` block or by supplying your own component.

---

## How to deploy (customer workflow)

This deployment follows a **GitOps-friendly vendor/customer separation**.

- **This repository** (`autonox-ai/deploy`) is read-only vendor content
- **Your repository** contains environment-specific overlays and secrets

You deploy pgvector by creating a **customer-owned overlay**.

---

### Step 1: Create a customer-owned overlay folder

In **your own Git repository**, create a folder for this deployment.
Name it according to your organization or environment, for example:

- `acme-pgvector`
- `prod-pgvector`
- `autonox-pgvector-dev`

You may start by copying the provided example:

```bash
cp -r dist/kustomize/third-party/pgvector/examples/customer-overlay ./acme-pgvector
cd acme-pgvector
```

> The folder name is arbitrary and fully customer-owned.

Your overlay folder should look like:

```
acme-pgvector/
  kustomization.yaml
  secret.pgvector-db.example.yaml
```

---

### Step 2: Bind your overlay to the vendor repository (IMPORTANT)

The example overlay uses **relative paths** that only work inside this repository.

After copying the example into your own repository, you **must update**
`kustomization.yaml` to reference the vendor repository explicitly.

#### Replace this (example-relative path)

```yaml
resources:
  - ../../overlays/openshift
  - secret.pgvector-db.example.yaml
```

#### With one of the following options:

##### Option A — Git reference (recommended)

```yaml
resources:
  - github.com/autonox-ai/deploy//dist/kustomize/third-party/pgvector/overlays/openshift?ref=v0.3.0
  - secret.pgvector-db.example.yaml
```

This binds your overlay to a **specific vendor version**.

##### Option B — Vendored copy (air-gapped environments)

Vendor the required files into your repository, for example:

```
vendor/
  autonox-deploy/
    dist/kustomize/third-party/pgvector/overlays/openshift
```

Then reference them locally:

```yaml
resources:
  - ../vendor/autonox-deploy/dist/kustomize/third-party/pgvector/overlays/openshift
  - secret.pgvector-db.example.yaml
```

---

### Step 3: Set the namespace

Set the target namespace in your overlay:

```yaml
namespace: autonox
```

Create it if needed:

```bash
oc new-project autonox
```

---

### Step 4: Configure storage (optional)

Override PVC size and StorageClass in your overlay if required.
If omitted, the cluster default StorageClass is used.

Example:

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

---

### Step 5: Create the database secret

Create a `Secret` named `pgvector-db` in the target namespace
(using your organization’s secret management process).

Example:

```bash
oc apply -f secret.pgvector-db.example.yaml
```

---

### Step 6: Deploy

From your overlay directory:

```bash
oc apply -k .
```

---

### Step 7: Verify

```bash
oc get pods
oc get pvc
oc logs job/pgvector-smoke-test
```

The smoke test job must complete successfully.

---

## Uninstall

To remove the deployment:

```bash
oc delete -k .
```

---

## Notes

* This deployment is intended for **development, POC, or controlled production**
  use cases.
* For advanced lifecycle management, HA, or backups, consider a managed Postgres
  service or a Postgres operator.
