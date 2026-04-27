# Metabase Terraform configuration

Declarative provisioning of the AutoNox Metabase content: 1 PostgreSQL data
source, 7 table references against the `bi_views` schema, 17 cards, and 3
dashboards (`Who Works Here`, `crossid_policy_coverage`, `Access
Investigations`).

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

All sensitive values are passed via `terraform.tfvars` (gitignored). Start
from the template:

```bash
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
```

Variables are documented in [`variables.tf`](variables.tf). The minimum set
to fill in:

- `metabase_host`, `metabase_username`, `metabase_password`
- `pg_host`, `pg_password` (defaults are sensible for the AutoNox bootstrap)

## Apply (connected environment)

```bash
terraform init
terraform plan
terraform apply
```

## Apply (air-gapped environment)

Two options:

1. **Direct** — copy [`.terraformrc.example`](.terraformrc.example) to
   `~/.terraformrc`, edit the absolute path inside, then run `terraform init`
   followed by `terraform apply`. Generate `provider-mirror/` first on a
   connected machine.
2. **Containerized** — use the prepackaged docker image, which bakes in both
   `terraform` and the provider mirror. See [`../tf-runner/`](../tf-runner/).

## Operational notes

[`suggestion.md`](suggestion.md) captures specific patterns we use with the
`audit.compare_access_between_dates()` function and how to wire change rows
to investigation drill-throughs. Read it before extending the cards.
