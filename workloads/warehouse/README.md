# warehouse workload

Runs migrations and materializations against the AutoNox `autonox` database
(schemas: `warehouse`, `reconciliation`, `shared`, `bi_views`).

## Image

`ghcr.io/autonox-ai/warehouse:<version>` per
[`../../images/manifest.txt`](../../images/manifest.txt).

## Configure & run

```bash
cp .env.example .env
$EDITOR .env
bash run.sh migrate     # or another supported subcommand
```

> `run.sh` is currently a skeleton.
