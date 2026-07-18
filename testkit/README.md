# Deployment testkit

Reusable container-environment harness for testing deployment workloads. It
does not reimplement PostgreSQL or Warehouse setup:

1. PostgreSQL is started with `deploy/postgres/compose`.
2. Migrations are applied through `deploy/workloads/warehouse/run.sh`.
3. An import is executed through `deploy/workloads/import/import.sh`.

The harness is scenario-driven. Each scenario supplies an environment file for
`import.sh`; the harness supplies lifecycle and migration commands.

## Usage

The testkit intentionally does not invent credentials, reset role passwords,
or generate deployment configuration. Those are customer/deployment inputs and
must be exercised explicitly.

For the verified mock-hr scenario, run:

```bash
./deploy/testkit/init.sh mock-hr --seed
./deploy/testkit/run.sh provision-workspace --workspace hello
export NOXOP_PASSWORD=local-noxop NOXREADER_PASSWORD=local-noxreader BIREADER_PASSWORD=local-bireader
docker exec -i nox-pg18 psql -U postgres -d postgres \
  -v noxop_password="$NOXOP_PASSWORD" \
  -v noxreader_password="$NOXREADER_PASSWORD" \
  -v bireader_password="$BIREADER_PASSWORD" \
  < deploy/postgres/bootstrap/passwords.sql
./deploy/testkit/run.sh migrate --warehouse-env ./tmp/testkit/warehouse.env
./deploy/testkit/run.sh import --env ./tmp/testkit/import.env
```

The helper writes the env files under `./tmp/testkit` by default:

```bash
./tmp/testkit/warehouse.env
./tmp/testkit/import.env
```

To start or reset PostgreSQL:

```bash
./deploy/testkit/run.sh up
./deploy/testkit/run.sh reset
./deploy/testkit/run.sh provision-workspace --workspace hello
```

The testkit uses the real customer-facing workload runners. `hello-world/run.sh`
remains the fast direct SQLite developer smoke test.

Set `TESTKIT_POSTGRES_COMPOSE_FILE` or `TESTKIT_COMPOSE_PROJECT` to use a
different Compose environment. Set `WAREHOUSE_ENV_FILE` when the migration
runner should load a specific Warehouse environment file.

For CI or any custom output location, set `TESTKIT_ROOT` before running
`init.sh`:

```bash
export TESTKIT_ROOT="$PWD/.ci/testkit"
./deploy/testkit/init.sh mock-hr --seed
```

The helper writes `warehouse.env`, `import.env`, artifacts, and receipts under
that root.
