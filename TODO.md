# TODO

Findings from a full deployment rehearsal (PostgreSQL → migrations → import →
assert) against the mock-hr scenario. Grouped by who has to fix them.

## Product — needs a change in the images, not here

### 1. Reconciliation creates `public.schema_migrations`

Its migrations runner ignores `control_plane_store.schema` and writes to
`public`, so `noxop` needs permanent `CREATE` on `public` or every import dies:

```
psycopg.errors.InsufficientPrivilege: permission denied for schema public
LINE 2: CREATE TABLE IF NOT EXISTS "public".schema_migrations...
  autonox/reconciliation/migrations/runner.py:191 _ensure_migrations_table_pg
```

Worked around by `testkit/run.sh:161-165` and step 3 of the rehearsal runbook.

- **Minimum fix:** honour `control_plane_store.schema` (already set to
  `reconciliation` in every wiring; the schema exists and sits empty). The
  extra grant then disappears — `ws_setup.sql.tmpl` grants already cover it.
- **Proper fix:** a `reconcile migrate` command mirroring `warehouse migrate`,
  run once at deploy time by an admin role, with the runtime role holding DML
  only and failing loudly when migrations are missing — the way Warehouse
  reports "Silver schema missing; run `warehouse migrate`". `workloads/` then
  gains a third workload and the deploy sequence is symmetric.
- **Why it matters:** `public` is shared with every extension; PG15 revoked
  `CREATE` there from `PUBLIC` precisely to stop this. Granting it back for the
  life of the deployment undoes that, and many customers forbid DDL rights on a
  routine scheduled job.

### 2. Postgres collector emits JSON columns as strings

`integrations/postgres/collector.py:34` does `payload = dict(row)`; the driver
returns `json`/`jsonb` as text, so `json_build_object(...)` arrives as a string.
The mapper has no JSON-decode transform (only `join`, `map`, `substring`) and
cannot build a keyed object (`collect` yields arrays), so such a value can never
reach `attributes`.

Consequence: `banding.py:460` drops the non-Mapping to `{}` and banding fails
with `ERR_BANDING_ATTRIBUTE_MISSING`. Workaround is to select scalar columns and
map them one by one — see `testkit/scenarios/mock-hr/config/`. Either parse JSON
columns in the collector, or add a decode transform to the mapper.

### 3. Banding silently no-ops on a hyphenated `system_instance_id`

`banding_attributes` keys must equal the collector's `system_instance_id`, but
the schema requires `^[a-z][a-z0-9_]*$`. With `system_instance_id: mock-hr` the
key can never match, so banding **skips attribute lookup and passes** — every
link becomes its own identity with an empty merged bag, and row-count assertions
stay green while every attribute is null. That is how mock-hr shipped.

Either validate that the two agree, or allow the same character set in both.

## This repo

### 4. Customer config still written in-tree

The `$AUTONOX_HOME` convention is done for `postgres/compose` and
`workloads/warehouse`. Still telling customers to write into the repo:

- `workloads/README.md:44`
- `workloads/import/README.md:14`
- `metabase/compose/README.md:60`
- `postgres/kustomize/examples/customer-overlay/` — overlays live in-tree

### 5. Role passwords are not persisted

`postgres.env` carries `POSTGRES_PASSWORD` but not `NOXOP_PASSWORD` /
`NOXREADER_PASSWORD` / `BIREADER_PASSWORD`, so after `down -v` they must be
remembered. Add them to `postgres.env.example` (empty) and have step 5 of
`postgres/compose/README.md` source that file instead of ad-hoc exports.

### 6. Nothing checks the warehouse image pin against the manifest

`workloads/warehouse` takes `WAREHOUSE_IMAGE` from its env file while
`import.sh` takes images from `images/manifest.txt`. A stale pin migrates with
an older image and surfaces three steps later as
`ERR_SILVER_SCHEMA_CONTRACT_MISMATCH` — "Silver schema missing" — which reads as
a missing migration rather than a version skew. Worth a note in
`workloads/warehouse/README.md`, or a check in the runner.

### 6b. The warehouse workload names the workspace twice, and both are live

`WORKSPACE_ID` in the env file and `spec.workspace_id` in the warehouse wiring
must agree, and nothing checks it. They are not alternatives — they feed
different commands inside the same `upgrade-workspace` sequence.

The image resolves workspace_id in three layers, later overriding earlier
(`autonox/warehouse/cli.py`):

```
wiring spec.workspace_id                     base
  ← WAREHOUSE_WORKSPACE_ID                   _parse_env_stage:289
    ← --workspace-id                         _shared_overrides:299
```

It is required — `cli.py:518` raises `runtime.workspace_id.missing` when no
layer supplies it. Which layer wins depends on the command:

| `run.sh` step | Command | workspace_id from |
| --- | --- | --- |
| 1 | `migrate` | **the wiring** — no `--workspace-id` is passed |
| 2 | `canonical migrate --shared` | shared, not workspace-scoped |
| 3 | `canonical migrate --workspace-id <id>` | the flag |
| 4 | `canonical install-access-layer --workspace-id <id>` | the flag |

So step 1 runs with whatever the wiring says, and steps 3–4 with whatever the
env file says. Observed in a rehearsal: wiring `prod`, env `local`. It passed
only because runtime `migrate` creates the control-plane tables without writing
workspace-scoped rows — the `workspace_id` columns are populated later, at
import time, from a different (correct) wiring. The day a runtime migration
scopes anything by that value — a partitioned table, a per-workspace index —
the mismatch writes under the wrong workspace silently.

`workloads/warehouse/README.md` still says to copy `examples/config/` and
"adjust `workspace_id`", which is exactly the duplication the testkit removed
by rendering `${WORKSPACE_ID}` (`testkit/init.sh`). Either template the wiring
the same way, or have `run.sh` refuse to run when the two disagree.

### 6c. One concept, several names across the env files

Each workload should keep its own env file — different lifecycles (install vs
image upgrade vs per-run), different blast radius (`postgres.env` holds the
superuser credential; the thing running hourly imports must not read it), and
different consumers (Compose interpolates a spec, `run.sh` sources a file,
`import.sh` passes only allow-listed variable *names* into containers so values
never reach a receipt). Merging them into one file defeats that last property.

The duplication is the price, and it is small — four values, not four files:

| Value | Duplicated across |
| --- | --- |
| `WORKSPACE_ID` | warehouse, import |
| warehouse image | warehouse `WAREHOUSE_IMAGE`, import `WAREHOUSE_IMG` |
| noxop DSN | warehouse `WAREHOUSE_POSTGRES_DSN`, import (allow-listed via `*_CONTAINER_ENV_NAMES`) |
| docker network | warehouse `CONTAINER_NETWORK`, metabase `METABASE_DOCKER_NETWORK`, import (inside `*_CONTAINER_RUN_ARGS`) |

`postgres.env` overlaps with nothing — it configures the server, not a client.
Metabase's `MB_DB_*` is not duplication either: it connects as `bireader`.

What to fix is the **naming**, not the file count:

- `WAREHOUSE_IMAGE` vs `WAREHOUSE_IMG` for the same image is what allowed a
  migrate and an import to run different versions of it (see item 6). Pick one.
- Three spellings of "the docker network" means an operator cannot grep their
  configuration for one concept.

Accept one breaking rename now. Operators who want shared values can layer
files themselves — `set -a; source common.env; source warehouse.env; set +a`
works today and needs no support from this repo.

### 7. `container_name: nox-pg18` is daemon-global

`postgres/compose/compose.yaml:5` pins it, so `TESTKIT_COMPOSE_PROJECT` cannot
give two stacks side by side and the testkit collides with a running instance.
Drop the pin and resolve the container through Compose (`run.sh` already does).

### 8. Smaller

- `testkit/init.sh:155-157` — `--user 0` for all three containers, unexplained.
  Find out why root is needed, comment it, or drop it.
- `testkit/init.sh:153` — `warehouse_volumes` mounts the config dir twice now
  that import and warehouse config resolved to the same directory.
- `images/manifest.txt:30` — `metabase/metabase:v0.58.x` is a floating tag,
  contradicting the file's own "Tags are immutable; never use `:latest`".
- `images/manifest.txt` — `autonox-warehouse` is pinned to latest `main`; that
  package has no release channel, only branch tags, unlike `collectors` and
  `reconciliation` which carry `enterprise`. Confirm that is intended.

### 9. mock-hr is a smoke test, not a fixture

One source, three identities, no accounts or entitlements. It cannot exercise
banding *across* sources — the case where several accounts collapse into one
identity — nor orphaned accounts, entitlements, or most of `bi_views`. A second
source with accounts correlated on `employee_id` would cover the parts that
matter, and the scenario contract makes that a new directory, not a harness
change.
