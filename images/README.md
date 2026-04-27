# Image distribution

Two supported paths for getting AutoNox container images into the customer's
environment:

| Customer condition | Use |
|---|---|
| Has JFrog Artifactory and outbound HTTPS to `ghcr.io` is allowed *for JFrog only* | [`jfrog/`](jfrog/) — proxy model, scanned, signed, audited |
| No outbound from anywhere; images must arrive as files | [`airgap/`](airgap/) — `docker save` / `docker load` workflow |

The list of images required at a given AutoNox release lives in
[`manifest.txt`](manifest.txt). Both paths consume it.

## JFrog (recommended where allowed)

JFrog Artifactory becomes the **single supply-chain gateway**. Production
clusters never pull from external registries; they only pull from a customer
local/virtual repo that JFrog has populated, scanned, and approved.

Setup steps, repository configuration, vendor service-account credentials,
and security model are documented in
[`jfrog/integration-jfrog-artifactory.md`](jfrog/integration-jfrog-artifactory.md).

After the JFrog repos are configured, rewrite the image references in your
Kubernetes manifests / Compose files to point at your JFrog virtual repo
instead of `ghcr.io/autonox-ai/...`. Kustomize `images:` patches and
Compose `image:` overrides are the cleanest way to do this without touching
vendor files.

## Air-gap (where JFrog is not available)

The customer transfers `.tar` files containing the images by their approved
out-of-band method. AutoNox provides the tooling to produce and consume those
tars; the **transfer mechanism itself is the customer's responsibility**.

See [`airgap/README.md`](airgap/README.md) for the scripts and the recommended
flow.
