# Deployment testkit

Reusable container-environment harness for testing deployment workloads. It
does not reimplement PostgreSQL or Warehouse setup:

1. PostgreSQL is started with `postgres/compose`.
2. Migrations are applied through `workloads/warehouse/run.sh`.
3. An import is executed through `workloads/import/import.sh`.
4. The resulting state is asserted with the scenario's `expect.sql`.

The harness is scenario-driven. Each scenario supplies its identity, source
data, the config `import.sh` consumes, and its expected outcome; the harness
supplies lifecycle, migration, and assertion commands.

Paths below are relative to the repo root. Run the scripts from there.

## Adding a scenario

A scenario is a directory under `scenarios/`. Both scripts discover it from
the filesystem, so adding one is never a harness edit:

```
scenarios/<name>/
├── scenario.env   # required — WORKSPACE_ID, SYSTEM_INSTANCE_ID, TENANT_ID,
│                  #   ENVIRONMENT, TARGET_REF, COMPLETION_POLICY
├── config/        # required — collector, connections, flow, banding,
│                  #   reconcile, warehouse-wiring, warehouse-canonical-wiring
├── source/*.sql   # seed data, loaded in filename order
└── expect.sql     # optional outcome assertions
```

`init.sh` validates all of the above before writing anything.

`config/` is a template pack, not the config the containers see. Files may use
`${WORKSPACE_ID}` and `${CONFIG_DIR}`; `init.sh` renders them into
`$TESTKIT_ROOT/config` and mounts that. So the workspace name is written once,
in `scenario.env`, and `file://` URIs resolve wherever the repo lives instead
of being absolute paths baked into a committed file.

That makes the workspace an override rather than a hardcode:

```bash
WORKSPACE_ID=local ./testkit/init.sh mock-hr
```

`expect.sql` is rendered the same way at assert time, so assertions follow the
override. Whatever workspace you name must be provisioned and migrated first.

Scenarios are self-contained — none reads another's config. `templates/` holds
reference wiring and annotated `*.env.example` files to copy from; it is not a
scenario and cannot be run.

Copy `scenarios/mock-hr/` as the starting point: it is a working end-to-end
scenario, and its config pack shows the shape the images actually accept.

Four constraints there are easy to get wrong, and three of them fail *silently*
— a green import that writes nothing:

- **Collect scalar columns, not JSON.** `json_build_object(...)` arrives as a
  string, the mapper has no JSON-decode transform, and the value is dropped.
  Cast non-JSON-safe types instead (`hire_date::text`).
- **`attributes` is a sibling of `columns`**, not one of them. Under
  `columns` it fails schema validation; as a sibling it fills the JSONB bag
  field by field. That bag is what banding and attribute merge read.
- **Banding merges under `partitions.columns`**, not `partitions.output`.
- **`banding_attributes` keys must equal the collector's `system_instance_id`**
  and match `^[a-z][a-z0-9_]*$`. A hyphenated instance id can never be banded:
  the key silently fails to match, banding skips attribute lookup, and every
  link becomes its own identity with an empty merged bag.

Because of that last one, assert *fields*, not row counts. Counting rows passes
while every merged attribute is null.

## Usage

Generate the env files, then run the whole thing:

```bash
./testkit/init.sh mock-hr
./testkit/run.sh e2e mock-hr
```

`e2e` runs reset → provision → passwords → seed → migrate → import → assert,
and stops at the first failure.

The individual steps remain available (`up`, `down`, `reset`,
`provision-workspace`, `set-passwords`, `seed`, `migrate`, `import`, `assert`,
`status`, `scenario`); run `./testkit/run.sh` with no arguments for the list.

### Against an existing PostgreSQL

Only `up`, `down`, `reset`, and `e2e` manage lifecycle. To run a scenario
against a database the harness does not own — an existing `postgres/compose`
instance, say — name its container and skip those:

```bash
export TESTKIT_PG_CONTAINER=nox-pg18
NOXOP_PASSWORD='<that instance's noxop password>' ./testkit/init.sh mock-hr
./testkit/run.sh provision-workspace --workspace hello
./testkit/run.sh seed mock-hr
./testkit/run.sh migrate --warehouse-env ./tmp/testkit/warehouse.env
./testkit/run.sh import --env ./tmp/testkit/import.env
./testkit/run.sh assert mock-hr
```

Assertions in `expect.sql` assume the scenario's own data, so run them against
a workspace nothing else is writing to.

### Credentials

The harness sets the local test-role passwords itself (`set-passwords`, folded
into `e2e`). These are fixtures, not credentials — the same values are already
written into the env files `init.sh` generates, so having the harness own the
step keeps the two from drifting. Override with `NOXOP_PASSWORD`,
`NOXREADER_PASSWORD`, `BIREADER_PASSWORD`.

The PostgreSQL superuser password is a fixture for the same reason: the test
database is destroyed on every `reset`. Override with `POSTGRES_PASSWORD`. A
real deployment instead passes `--env-file $AUTONOX_HOME/postgres.env`; the
compose spec starts with neither.

Real deployment configuration is still a customer input: the testkit does not
invent wiring documents or connection catalogs.

## Outcome assertions

A scenario may ship `scenarios/<name>/expect.sql`, run against the `autonox`
database with `ON_ERROR_STOP=1`. Raise an exception to fail the run:

```sql
IF n_accounts <> 1 THEN
  RAISE EXCEPTION 'expected 1 account, found %', n_accounts;
END IF;
```

Assert through `bi_views.*` where possible — that is the access layer a
customer's BI actually reads. Without `expect.sql` a scenario still runs, but a
pass only proves `import.sh`'s own gates were satisfied, not that the images
produced the right rows; the harness prints a note saying so.

## Air-gap rehearsal

`init.sh` resolves each image locally first and only pulls when it is absent, so
a host with images already loaded by `images/airgap/load.sh` needs no registry:

```bash
bash images/airgap/load.sh ./tars
TESTKIT_OFFLINE=1 ./testkit/init.sh mock-hr
```

`TESTKIT_OFFLINE=1` turns a missing image into an error instead of a pull, which
is what makes the rehearsal honest. Images restored from a `docker save` tar may
carry no registry digest — the digest does not survive the round trip — in which
case the manifest tag is used and a note is printed. The tag is still pinned by
`images/manifest.txt`, and `bundle.lock` is what verifies the bytes on that path.

## Configuration

| Variable | Purpose |
| --- | --- |
| `TESTKIT_ROOT` | Where env files, artifacts, and receipts are written. Default `./tmp/testkit`. |
| `TESTKIT_OFFLINE` | `1` fails instead of pulling a missing image. |
| `TESTKIT_POSTGRES_COMPOSE_FILE` | Use a different Compose file. |
| `TESTKIT_COMPOSE_PROJECT` | Use a different Compose project. |
| `TESTKIT_PG_CONTAINER` | Run the SQL steps against an existing PostgreSQL container instead of one the harness starts. |
| `TESTKIT_PG_HOST` | Hostname used in the generated DSNs. Default `postgres`. |
| `WAREHOUSE_ENV_FILE` | Warehouse env file for `migrate` when not passed explicitly. |

The postgres container is resolved through Compose rather than by name, so it
follows `TESTKIT_COMPOSE_PROJECT`. Note that `postgres/compose/compose.yaml`
pins `container_name: nox-pg18`, which is global to the Docker daemon — two
testkit projects cannot run side by side until that pin is removed.

For CI, point `TESTKIT_ROOT` somewhere outside the default:

```bash
export TESTKIT_ROOT="$PWD/.ci/testkit"
./testkit/init.sh mock-hr
```
