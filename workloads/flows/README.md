# flows workload

Reconciliation and policy flows that run on top of the AutoNox warehouse.

## Image

`ghcr.io/autonox-ai/flows:<version>` per
[`../../images/manifest.txt`](../../images/manifest.txt).

## Configure & run

```bash
cp .env.example .env
$EDITOR .env
bash run.sh <flow-name>
```

> `run.sh` is currently a skeleton.
