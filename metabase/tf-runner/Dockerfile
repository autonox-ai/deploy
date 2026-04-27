# Air-gapped Terraform runner for the AutoNox Metabase configuration.
#
# Bakes in:
#   - Terraform CLI
#   - The full metabase/tf/ project (main.tf, variables.tf, lock file)
#   - The flovouin/metabase provider mirror (offline-installable)
#   - A .terraformrc that points Terraform at the bundled mirror
#
# Build context MUST be the deploy/metabase/ directory so that ./tf/ is in scope.
# Build:
#   docker build -t ghcr.io/autonox-ai/metabase-terraform -f tf-runner/Dockerfile .
#
# Run (apply):
#   docker run --rm --network=host \
#     -v $(pwd)/terraform.tfvars:/work/tf/terraform.tfvars:ro \
#     ghcr.io/autonox-ai/metabase-terraform apply -auto-approve
#
# Run (init only — usually not needed because the image is pre-initialized):
#   docker run --rm ghcr.io/autonox-ai/metabase-terraform init -backend=false

FROM hashicorp/terraform:1.9

WORKDIR /work/tf

# Provider mirror first so that init can resolve flovouin/metabase offline.
COPY tf/provider-mirror /work/tf/provider-mirror
COPY tf-runner/terraformrc /root/.terraformrc

# Project files.
COPY tf/main.tf            /work/tf/main.tf
COPY tf/variables.tf       /work/tf/variables.tf
COPY tf/.terraform.lock.hcl /work/tf/.terraform.lock.hcl

# Pre-initialize so `apply` works without a network.
RUN terraform init -input=false

ENTRYPOINT ["terraform"]
CMD ["apply", "-auto-approve"]
