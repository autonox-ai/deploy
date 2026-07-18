# Deployment testkit

Reusable container-environment harness for testing deployment workloads. It
does not reimplement PostgreSQL or Warehouse setup:

1. PostgreSQL is started with `postgres/compose`.
2. Migrations are applied through `workloads/warehouse/run.sh`.
3. An import is executed through `workloads/import/import.sh`.
4. The resulting state is asserted with the scenario's `expect.sql`.

The harness is scenario-driven. Each scenario supplies source data, the config
`import.sh` consumes, and its expected outcome; the harness supplies lifecycle,
migration, and assertion commands.

Paths below are relative to the repo root. Run the scripts from there.

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

### Credentials

The harness sets the local test-role passwords itself (`set-passwords`, folded
into `e2e`). These are fixtures, not credentials — the same values are already
written into the env files `init.sh` generates, so having the harness own the
step keeps the two from drifting. Override with `NOXOP_PASSWORD`,
`NOXREADER_PASSWORD`, `BIREADER_PASSWORD`.

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
