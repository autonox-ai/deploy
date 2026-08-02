# Metabase Terraform configuration

Declarative provisioning of the AutoNox Metabase content: 1 PostgreSQL data
source, 7 table references against the `bi_views` schema, 35 cards, and 7
dashboards — `Who Works Here`, `Access Explorer`, `Access Investigations`,
`Access Changes Between Dates`, `Entitlements Catalog`, `Entitlement
Comparison`, `Crossid Policy Coverage`. 50 resources in all; counts measured
from `terraform state list`, not from the source.

Provider: [`flovouin/metabase`](https://registry.terraform.io/providers/flovouin/metabase/latest)
pinned to `~> 0.1` via [`.terraform.lock.hcl`](.terraform.lock.hcl).

## Prerequisites

1. A running Metabase instance reachable from where you'll run `terraform`.
   See [`../compose/`](../compose/) or [`../kustomize/`](../kustomize/).
2. The Metabase admin account is created (run through the first-login wizard
   in the browser).
3. The AutoNox PostgreSQL instance is bootstrapped with the `bi_views` schema
   populated. See [`../../postgres/README.md`](../../postgres/README.md).

## Variables

All sensitive values are passed in a `.tfvars` file that lives **outside this
repository**, in `$AUTONOX_HOME` (default `/etc/autonox`) like the rest of the
customer configuration — the repo is replaced wholesale on upgrade. Start from
the template, from the repository root:

```bash
export AUTONOX_HOME="${AUTONOX_HOME:-/etc/autonox}"
cp metabase/tf/terraform.tfvars.example "$AUTONOX_HOME/metabase.tfvars"
chmod 600 "$AUTONOX_HOME/metabase.tfvars"
$EDITOR "$AUTONOX_HOME/metabase.tfvars"
```

Variables are documented in [`variables.tf`](variables.tf). The minimum set
to fill in:

- `metabase_host`, `metabase_username`, `metabase_password`
- `pg_host`, `pg_password` (defaults are sensible for the AutoNox bootstrap)

## Apply (connected environment)

Terraform's working directory and state also go to `$AUTONOX_HOME`. State
records the Metabase admin and `bireader` passwords in cleartext, so it is
customer data, not build output — treat it as a secret and back it up.

```bash
export AUTONOX_HOME="${AUTONOX_HOME:-/etc/autonox}"
export TF_DATA_DIR="$AUTONOX_HOME/var/tf/metabase/.terraform"
mkdir -p "$AUTONOX_HOME/var/tf/metabase"

terraform -chdir=metabase/tf init \
  -backend-config="path=$AUTONOX_HOME/var/tf/metabase/terraform.tfstate"
terraform -chdir=metabase/tf plan  -var-file="$AUTONOX_HOME/metabase.tfvars"
terraform -chdir=metabase/tf apply -var-file="$AUTONOX_HOME/metabase.tfvars"
```

`TF_DATA_DIR` must stay set for every command after `init` — it is where the
provider plugins and the resolved backend configuration live. If the customer
has a remote backend (S3, Terraform Cloud), replace `backend "local" {}` in
[`main.tf`](main.tf) with theirs — the one vendor-file edit this guide
sanctions, and one to carry forward on every repo upgrade.

[`apply.sh`](apply.sh) wraps the same sequence — it applies the database
resource, waits for the `bi_views` schema sync, then applies the rest — and
reads the same two locations, so it needs only `AUTONOX_HOME`:

```bash
AUTONOX_HOME=/etc/autonox ./metabase/tf/apply.sh
```

**Upgrading from an earlier revision** that kept state in `metabase/tf/`: the
first `init` with `-backend-config` sees a changed backend and asks to copy the
existing state across. Run it once interactively and answer `yes` (or add
`-migrate-state`), then delete the leftover `metabase/tf/terraform.tfstate*`
and `metabase/tf/.terraform/`. `apply.sh` passes `-input=false`, so it errors
instead of prompting until that migration is done.

Nothing above writes into the repository. `terraform init` can rewrite
[`.terraform.lock.hcl`](.terraform.lock.hcl) when it sees a platform the lock
does not cover; if `git status` reports it, that is a vendor file to report
upstream, not a local edit to keep.

## Apply (air-gapped environment)

Two options:

1. **Direct** — copy [`.terraformrc.example`](.terraformrc.example) to
   `$AUTONOX_HOME/terraformrc`, edit the absolute path inside to point at this
   repo's `metabase/tf/provider-mirror`, then run the same `init`/`apply` pair
   as above with `TF_CLI_CONFIG_FILE="$AUTONOX_HOME/terraformrc"` set (or copy
   it to `~/.terraformrc`, which Terraform reads by default). Generate
   `provider-mirror/` first on a connected machine.
2. **Containerized** — use the prepackaged docker image, which bakes in both
   `terraform` and the provider mirror. See [`../tf-runner/`](../tf-runner/).

## Operational notes

[`suggestion.md`](suggestion.md) captures specific patterns we use with the
`audit.compare_access_between_dates()` function and how to wire change rows
to investigation drill-throughs. Read it before extending the cards.
