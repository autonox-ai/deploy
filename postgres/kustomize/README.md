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
customer-managed secret values to set the AutoNox application role passwords,
then [`../bootstrap/ws_setup.sql.tmpl`](../bootstrap/ws_setup.sql.tmpl) per
workspace — a hard prerequisite for `workloads/warehouse`, which does not
create workspace schemas itself.

Both scripts' own headers show the generic `psql "$PG_ADMIN_URL"` form for an
externally-reachable instance. On this StatefulSet, Postgres is only reachable
from inside the cluster, so apply them against the running pod instead
(`$PG_ADMIN_USER` is whatever `POSTGRES_USER` you set in the `pgvector-db`
secret):

```bash
export AUTONOX_HOME="${AUTONOX_HOME:-/etc/autonox}"

oc exec -i pgvector-0 -- psql -U "$PG_ADMIN_USER" -d autonox \
  -v noxop_password="$NOXOP_PASSWORD" \
  -v noxreader_password="$NOXREADER_PASSWORD" \
  -v bireader_password="$BIREADER_PASSWORD" \
  < postgres/bootstrap/passwords.sql

mkdir -p "$AUTONOX_HOME/var/sql"
WS_NAME=prod envsubst < postgres/bootstrap/ws_setup.sql.tmpl \
  > "$AUTONOX_HOME/var/sql/ws_prod_setup.sql"
oc exec -i pgvector-0 -- psql -U "$PG_ADMIN_USER" -d autonox \
  < "$AUTONOX_HOME/var/sql/ws_prod_setup.sql"
```

Run these from the repository root. Rendered SQL goes to `$AUTONOX_HOME/var/`
(default `/etc/autonox/var/`), never into this repository — same reason as the
overlay below: the tree is vendor content, replaced wholesale on upgrade.
Everything under `var/` is output and safe to delete.

Replace `oc` with `kubectl` on plain Kubernetes.

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

A template secret manifest is provided in:

```
examples/customer-overlay/secret.pgvector-db.example.yaml
```

It is a template, not a manifest to apply: copy it out of this repository
first, drop the `.example`, and replace `change-me`.

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

Deploy pgvector by creating a customer-owned overlay. Everything under
`examples/` is a template to copy out — never your overlay. Editing it in place
and running `oc apply -k` from inside this repository puts your namespace,
storage sizing and secret into vendor content that the next upgrade replaces
wholesale.

### Step 1: Create a customer-owned overlay folder

Put the overlay in your own Git repository — a folder for this deployment, e.g.
`acme-pgvector`, `prod-pgvector`:

```bash
cp -r postgres/kustomize/examples/customer-overlay ./acme-pgvector
cd acme-pgvector
```

If there is no customer Git repository, put it under `$AUTONOX_HOME` instead —
the same directory the Compose bundle and the workloads read their
configuration from (default `/etc/autonox`), so it survives a repo upgrade:

```bash
export AUTONOX_HOME="${AUTONOX_HOME:-/etc/autonox}"
mkdir -p "$AUTONOX_HOME/pgvector-overlay"
cp -r postgres/kustomize/examples/customer-overlay/. "$AUTONOX_HOME/pgvector-overlay/"
cd "$AUTONOX_HOME/pgvector-overlay"
```

Either way your overlay folder starts as:

```
acme-pgvector/
  kustomization.yaml
  secret.pgvector-db.example.yaml
```

### Step 2: Bind your overlay to the vendor repository

The template uses **relative paths** that only resolve inside this repo, so the
copy does not build until you point it at the vendor explicitly. That is
deliberate: an overlay that keeps working in place is one nobody copies out.

#### Replace this (template-relative path)

```yaml
resources:
  - ../../overlays/openshift
  - secret.pgvector-db.example.yaml
```

#### With one of:

##### Option A — Git reference (recommended)

```yaml
resources:
  - github.com/autonox-ai/deploy//postgres/kustomize/overlays/openshift?ref=<vendor-version>
  - secret.pgvector-db.yaml
```

This binds your overlay to a specific vendor version. Use the release ref the
customer was delivered.

##### Option B — Vendored copy (air-gapped environments)

Vendor the required files next to your overlay — inside your repository, or
under `$AUTONOX_HOME` if that is where the overlay lives:

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
  - secret.pgvector-db.yaml
```

Either way, rename the secret template as you fill it in:

```bash
mv secret.pgvector-db.example.yaml secret.pgvector-db.yaml
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

Set a real `POSTGRES_PASSWORD` in `secret.pgvector-db.yaml` first — the
template ships `change-me`. Better still, delete the file and have your secret
manager create `pgvector-db` (Vault, ExternalSecrets, SealedSecrets), then drop
it from `resources:`.

```bash
oc apply -f secret.pgvector-db.yaml
```

### Step 6: Deploy

From your overlay directory — the copy, not this repository:

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
