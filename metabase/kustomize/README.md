# Metabase on Kubernetes — Kustomize bundle

Single-replica Metabase Deployment + Service, mirroring the
[`postgres/kustomize/`](../../postgres/kustomize/) pattern. Use this when the
customer wants Metabase managed alongside their AutoNox workloads on Kubernetes
or OpenShift.

## What you get

* `Service` `metabase` on port **3000** (ClusterIP)
* `Deployment` `metabase` (1 replica) — stateless; metadata lives in
  PostgreSQL (see required Secret below)
* HTTP readiness/liveness probes on `/api/health`

## What you must provide (required)

A Kubernetes `Secret` named **`metabase-db`** with the connection details
Metabase uses for its **own metadata store** (NOT the AutoNox warehouse):

* `MB_DB_HOST`
* `MB_DB_PORT`
* `MB_DB_DBNAME`
* `MB_DB_USER`
* `MB_DB_PASS`

That database and role must exist before Metabase starts. Provision them with
[`../bootstrap/setup.sql.tmpl`](../bootstrap/setup.sql.tmpl) — typically
against the same pgvector StatefulSet from
[`../../postgres/kustomize/`](../../postgres/kustomize/).

> Do **not** commit real secrets to Git. Use your organization's secret
> management solution (Vault, ExternalSecrets, SealedSecrets, etc.).

A template secret manifest is provided in
`examples/customer-overlay/secret.metabase-db.example.yaml`. It is a template,
not a manifest to apply: copy it out of this repository first, drop the
`.example`, and replace `change-me`.

## Image version pinning

The base Deployment leaves the image tag unpinned. Versions are centrally
pinned via the Kustomize component at
`metabase/kustomize/components/images`. Override in your overlay if needed.

## How to deploy (customer workflow)

Same vendor/customer split as the pgvector bundle: everything under
`examples/` is a template to copy out, never your overlay. Copy it into your
own Git repository:

```bash
cp -r metabase/kustomize/examples/customer-overlay ./acme-metabase
cd acme-metabase
```

If there is no customer Git repository, put it under `$AUTONOX_HOME` instead
(default `/etc/autonox`), alongside the rest of the customer configuration:

```bash
export AUTONOX_HOME="${AUTONOX_HOME:-/etc/autonox}"
mkdir -p "$AUTONOX_HOME/metabase-overlay"
cp -r metabase/kustomize/examples/customer-overlay/. "$AUTONOX_HOME/metabase-overlay/"
cd "$AUTONOX_HOME/metabase-overlay"
```

The copy does not build until you update `kustomization.yaml` to reference the
vendor explicitly (pinned Git ref or vendored copy) — see
[`../../postgres/kustomize/README.md`](../../postgres/kustomize/README.md)
for the same pattern with full instructions.

Set the namespace, create the `metabase-db` Secret using your secret
management process, then, from the copy rather than this repository:

```bash
oc apply -k .
oc get pods
oc logs deploy/metabase
```

## Next step

Once Metabase is reachable (for example via a Route/Ingress), apply the
declarative configuration from [`../tf/`](../tf/).

## Uninstall

```bash
oc delete -k .
```
