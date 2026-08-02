# `metabase/tf-runner` — air-gapped Terraform image

Container image that bakes in Terraform, the AutoNox Metabase project
(`../tf/`), and the offline provider mirror. Use this on a host that cannot
reach `registry.terraform.io`.

## Build

The build context must be `metabase/` (one level up from this directory) so
that the `tf/` source tree is visible to the Dockerfile.

GitHub Actions generates `tf/provider-mirror/registry.terraform.io/` before
building the image. For a local connected build, generate it first:

```bash
cd metabase
terraform -chdir=tf providers mirror -platform=linux_amd64 provider-mirror
docker build -t ghcr.io/autonox-ai/metabase-terraform -f tf-runner/Dockerfile .
```

CI currently mirrors `linux_amd64`. Add other runtime architectures by
extending the mirror command, for example:

```bash
terraform -chdir=tf providers mirror \
  -platform=linux_amd64 \
  -platform=linux_arm64 \
  provider-mirror
```

The build runs `terraform init` inside the image, so the resulting image is
ready to `apply` without further network access.

## Hand off to an air-gapped host

```bash
docker save -o autonox-metabase-terraform.tar ghcr.io/autonox-ai/metabase-terraform
# transfer the .tar by your customer's approved method, then on the target:
docker load -i autonox-metabase-terraform.tar
```

(See [`../../images/airgap/`](../../images/airgap/) for the same workflow used
for the AutoNox workload images.)

## Run

Mount your variables file from `$AUTONOX_HOME` — the same
`$AUTONOX_HOME/metabase.tfvars` the host-side flow uses (see
[`../tf/README.md`](../tf/README.md); shape in
[`../tf/terraform.tfvars.example`](../tf/terraform.tfvars.example)) — and pick a
Terraform subcommand. Mounting it at `/work/tf/terraform.tfvars` is what makes
Terraform auto-load it, so no `-var-file` is needed:

```bash
export AUTONOX_HOME="${AUTONOX_HOME:-/etc/autonox}"
```

Plan:

```bash
docker run --rm --network=host \
  -v "$AUTONOX_HOME/metabase.tfvars:/work/tf/terraform.tfvars:ro" \
  ghcr.io/autonox-ai/metabase-terraform plan
```

Apply (the default `CMD`):

```bash
docker run --rm --network=host \
  -v "$AUTONOX_HOME/metabase.tfvars:/work/tf/terraform.tfvars:ro" \
  ghcr.io/autonox-ai/metabase-terraform
```

Destroy — be careful:

```bash
docker run --rm --network=host \
  -v "$AUTONOX_HOME/metabase.tfvars:/work/tf/terraform.tfvars:ro" \
  ghcr.io/autonox-ai/metabase-terraform destroy -auto-approve
```

`--network=host` is the simplest way to let the container reach a Metabase
running on the same host. On Kubernetes, run as a `Job` in the same namespace
as Metabase and target the in-cluster `metabase` service via `metabase_host`.

## Persisting state

The image does not persist `terraform.tfstate`. Mount a host directory for it
if you need state across runs — `$AUTONOX_HOME/var/tf/metabase` is where the
host-side flow keeps it, so the two agree:

```bash
mkdir -p "$AUTONOX_HOME/var/tf/metabase"
docker run --rm --network=host \
  -v "$AUTONOX_HOME/var/tf/metabase:/work/tf/state" \
  -v "$AUTONOX_HOME/metabase.tfvars:/work/tf/terraform.tfvars:ro" \
  ghcr.io/autonox-ai/metabase-terraform apply -state=/work/tf/state/terraform.tfstate -auto-approve
```

State holds the Metabase admin and `bireader` passwords in cleartext — keep it
out of this repository and back it up as a secret.

For real deployments, replace the `backend "local" {}` block in `tf/main.tf`
with the customer's remote backend.
