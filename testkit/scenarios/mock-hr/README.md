# Mock HR import scenario

This scenario runs one mocked HR source, represented by PostgreSQL tables,
through the real Collector, Warehouse, and Reconciliation containers via
`import.sh`.

The scenario is wired for the verified testkit path:

- `TARGET_REF=warehouse/ws_hello`
- `COMPLETION_POLICY=none`
- `shared_schema=shared`

Seed the mocked HR source into the test PostgreSQL database:

```bash
SCENARIO="$PWD/deploy/testkit/scenarios/mock-hr"
docker exec -i nox-pg18 psql -U postgres -d postgres \
  < "$SCENARIO/source/mock_hr.sql"
```

Use this directory as `CONFIG_DIR` when generating the import environment:

```bash
CONFIG_DIR="$PWD/deploy/testkit/scenarios/mock-hr/config"
SOURCE_DIR="$PWD/deploy/testkit/scenarios/mock-hr/source"
TESTKIT_ROOT="$PWD/tmp/testkit"
ARTIFACT_DIR="$TESTKIT_ROOT/artifacts"
RECEIPT_DIR="$TESTKIT_ROOT/receipts"
```

The source is already inside PostgreSQL; no source volume mount is required.

The generated import environment passes the PostgreSQL DSN into the Warehouse
and Reconciliation containers, and points the reconciliation target at the
warehouse binding that the runtime expects:

```bash
WAREHOUSE_POSTGRES_DSN=postgresql://noxop:local-noxop@postgres:5432/autonox
RECONCILE_POSTGRES_DSN="$WAREHOUSE_POSTGRES_DSN"
RECONCILE_WAREHOUSE_DSN="$WAREHOUSE_POSTGRES_DSN"
TARGET_REF=warehouse/ws_hello
COMPLETION_POLICY=none
WAREHOUSE_WIRING="$PWD/deploy/testkit/scenarios/example/config/warehouse-wiring.yaml"
WAREHOUSE_CONTAINER_ENV_NAMES=WAREHOUSE_POSTGRES_DSN
RECONCILE_CONTAINER_ENV_NAMES=$'RECONCILE_POSTGRES_DSN\nRECONCILE_WAREHOUSE_DSN'
COLLECTOR_CONTAINER_ENV_NAMES=POSTGRES_DSN
```

`./deploy/testkit/init.sh mock-hr --seed` writes the exact env files used by
the verified flow under `./tmp/testkit`.
