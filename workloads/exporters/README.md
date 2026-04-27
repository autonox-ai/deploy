# exporters workload

Pulls data from upstream source systems into the AutoNox warehouse.

## Image

Resolved from [`../../images/manifest.txt`](../../images/manifest.txt):
`ghcr.io/autonox-ai/exporters:<version>` (or the customer's JFrog rewrite of
the same).

## Configure

```bash
cp .env.example .env
$EDITOR .env
```

## Run

```bash
bash run.sh
```

> `run.sh` is currently a skeleton. Real argument lists land in a follow-up
> commit once the exporters CLI surface is finalized.
