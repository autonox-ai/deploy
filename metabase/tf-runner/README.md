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

Mount your `terraform.tfvars` (gitignored — see
[`../tf/terraform.tfvars.example`](../tf/terraform.tfvars.example) for the
shape) and pick a Terraform subcommand:

```bash
# Plan
docker run --rm --network=host \
  -v $(pwd)/terraform.tfvars:/work/tf/terraform.tfvars:ro \
  ghcr.io/autonox-ai/metabase-terraform plan

# Apply (default CMD)
docker run --rm --network=host \
  -v $(pwd)/terraform.tfvars:/work/tf/terraform.tfvars:ro \
  ghcr.io/autonox-ai/metabase-terraform

# Destroy (be careful)
docker run --rm --network=host \
  -v $(pwd)/terraform.tfvars:/work/tf/terraform.tfvars:ro \
  ghcr.io/autonox-ai/metabase-terraform destroy -auto-approve
```

`--network=host` is the simplest way to let the container reach a Metabase
running on the same host. On Kubernetes, run as a `Job` in the same namespace
as Metabase and target the in-cluster `metabase` service via `metabase_host`.

## Persisting state

The image does not persist `terraform.tfstate`. Mount a host directory at
`/work/tf` (alongside `terraform.tfvars`) if you need state across runs:

```bash
docker run --rm --network=host \
  -v $(pwd)/state:/work/tf/state \
  -v $(pwd)/terraform.tfvars:/work/tf/terraform.tfvars:ro \
  ghcr.io/autonox-ai/metabase-terraform apply -state=/work/tf/state/terraform.tfstate -auto-approve
```

For real deployments, configure a remote backend in `tf/main.tf` instead.
