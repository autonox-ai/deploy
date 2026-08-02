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

### 1b. A transient failure after `intents_emitted` cannot be resumed

`import-orchestration.md:156` is explicit: once Silver reaches `intents_emitted`
the workspace lock is intentionally retained, no second Silver run may start,
and recovery is to "resume validation/reconciliation from the frozen JSONL".
`import.sh` cannot do that — `run_pipeline` (`import.sh:365`) refuses any
receipt containing a failed task:

```
receipt records a failed or uncertain task (reconcile_validate);
inspect subsystem state with its supported read-only adapter before resuming
```

So a transient downstream failure — a missing grant, a restarted database, a
network blip — leaves the import unresumable, while the retained lock also
blocks starting a new one until it expires. Observed in a rehearsal:
`reconcile_validate` failed on a missing privilege, the privilege was granted
seconds later, and there was no supported way forward.

Three gaps behind it, all admitted in `import-orchestration.md:162`:

- **No way to clear the failed task and continue.** Recovering meant
  hand-editing a receipt to remove the failed entry — editing what is supposed
  to be immutable audit evidence. There should be a first-class
  "retry this task" path, gated on the operator having inspected state.
- **A rewound resume corrupts the receipt sequence.** Resuming from an older
  receipt restarts `receipt_sequence` there and overwrites the receipts above
  it, so `latest` can point at a *worse* state than a higher-numbered receipt
  still on disk. `workloads/import/README.md:22` tells operators to use "the
  latest receipt there for safe inspection or recovery", which is then wrong.
  Either refuse to rewind, or write forward without reusing sequence numbers.
- **No supported Silver lock inspection or release.** `warehouse silver` has
  only `run` and `finalize`. Lock state is visible solely by reading
  `warehouse.silver_workspace_locks` directly, and expiry (a liveness escape
  hatch, per `:160`) is the only way out.

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

### 3. Banding silently no-ops on an unmatched source name

`banding.py:441` looks up `banding_attributes.get(link.source)`, where
`link.source` is the value the **flow spec** stamps on canonical rows
(`source: {pipe: [{const: mock_hr}]}` in mock-hr's `flow.yaml`). When no key
matches, banding **skips attribute lookup and passes**: every link becomes its
own identity with an empty merged bag, so row-count assertions stay green while
every attribute is null. That is how mock-hr shipped.

The binding is therefore flow spec → banding spec, and nothing checks it. Two
documents, one written by whoever onboards a source, and a typo in either is
silent. The schema's `^[a-z][a-z0-9_]*$` on the banding key adds a trap: a
source named with a hyphen can be stamped by the flow spec but can never be
expressed as a banding key, so the pair cannot be made to agree at all.

`silver run` reads both documents and can compare them. It should fail when the
flow spec stamps a source the banding spec has no key for — or at minimum warn,
since an intentionally unbanded source is conceivable.

> Earlier revisions of this item claimed the key had to equal the collector's
> `system_instance_id`. It does not: `system_instance_id` is passed separately
> as `--system-instance-id` and never reaches this lookup. The two coincide in
> mock-hr, which is what made the wrong reading plausible.

### 3b. The runtime wiring requires `workspace_id`, which is not a wiring concern

Every other field in `spec` of `warehouse.runtime.config.spec.v1` describes
**topology** — `control_plane`, `artifact_store`, `bronze`, `silver`,
`canonical_store`, `secrets_providers_uri`: where things live and how to reach
them. `workspace_id` is the only one naming the **operand**: which workspace a
single invocation acts on. The two have different lifecycles — topology changes
when you re-platform, the operand changes per run — so they should not be
required to travel in the same document.

The product already models it the other way one command over:
`warehouse.canonical.config.spec.v1` has no `workspace_id` at all, and
`canonical migrate` / `canonical install-access-layer` take it only as
`--workspace-id`. One CLI, one concept, two answers.

Measured on `sha-ca9a4ad` with `warehouse wiring --wiring …`, which resolves and
validates without touching the database:

| wiring `spec.workspace_id` | `WAREHOUSE_WORKSPACE_ID` | `--workspace-id` | resolved |
| --- | --- | --- | --- |
| `local` | `fromenv` | — | `local` |
| absent | `fromenv` | — | `WIRING_VALIDATION_FAILED` |
| `local` | — | `fromcli` | `fromcli` |
| absent | — | — | `WIRING_VALIDATION_FAILED` |

Two consequences, both invisible from the outside:

- **The field cannot be omitted.** `spec.required` lists it and `spec` is
  `additionalProperties: false`, so every operator must write a workspace name
  into a document that will then be overridden by the flag.
- **`WAREHOUSE_WORKSPACE_ID` is dead for this field.** It enters as the
  `defaults` layer (`cli.py:284-292`, passed as `defaults=` at `cli.py:322-324`)
  and the merge is `defaults → wiring → CLI overrides`
  (`runtime/wiring/service.py:63-65`). Being a *fallback* rather than an
  override, it can only fill a field the wiring omits — and this field can never
  be omitted. It is documented as configurable and is unreachable.

**Ask:** drop `workspace_id` from `required` in
`autonox/warehouse/schema/warehouse.runtime.config.spec.v1.schema.json`. Keep it
permitted, so existing documents stay valid. Nothing else needs to move:
`cli.py:518` already raises `runtime.workspace_id.missing` when no layer supplies
it, and that becomes the real check — at the point where the value is actually
needed, rather than at document-validation time.

Follow-up in this repo once it ships: **6b**.

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

### 6b. The warehouse workload names the workspace twice — mitigated, not solved

**The bug, for the record.** `WORKSPACE_ID` in the env file and
`spec.workspace_id` in the warehouse wiring were not alternatives: they fed
different commands inside the same `upgrade-workspace` sequence, and nothing
compared them.

| `run.sh` step | Command | workspace_id came from |
| --- | --- | --- |
| 1 | `migrate` | **the wiring** — no `--workspace-id` was passed |
| 2 | `canonical migrate --shared` | shared, not workspace-scoped |
| 3 | `canonical migrate --workspace-id <id>` | the flag |
| 4 | `canonical install-access-layer --workspace-id <id>` | the flag |

Observed in a rehearsal: wiring `prod`, env `local`, every step reporting
`{"status":"ok"}`. It passed only because runtime `migrate` creates the
control-plane tables without writing workspace-scoped rows — those columns are
populated later, at import time, from a different (correct) wiring. The day a
runtime migration scopes anything by that value — a partitioned table, a
per-workspace index — the mismatch would write under the wrong workspace
silently.

**What was done.** `WORKSPACE_ID` is now the single source of truth:
`run.sh migrate` passes `--workspace-id` like the other three commands, so the
flag — the highest-precedence layer — decides for the whole sequence, and
`check_wiring_workspace` refuses to start when the wiring document disagrees.

**Why this is a mitigation and not the fix.** Cross-config validation is what
you write when a value lives in a document that should not own it. The wiring
document still has to carry a `workspace_id` that is now always overridden, so
the guard exists only to stop an operator being misled by a value that does
nothing. That is a documentation defect enforced by code. The field cannot
simply be deleted today — the schema requires it. See **3b** for the upstream
ask.

**Once 3b ships, in this repo:**

1. Delete `spec.workspace_id` from the four wiring documents that carry it:
   - `workloads/warehouse/examples/config/warehouse-wiring.yaml:6` (`prod`)
   - `testkit/templates/config/warehouse-wiring.yaml:6` (`hello`)
   - `testkit/scenarios/mock-hr/config/warehouse-wiring.yaml:6` (`${WORKSPACE_ID}`)
   - any deployed `$AUTONOX_HOME/warehouse-config/warehouse-wiring.yaml`
2. Delete `check_wiring_workspace` from `workloads/warehouse/run.sh` and its two
   call sites (`migrate`, `upgrade-workspace`). It already returns early when the
   field is absent, so removal is cleanup with no behaviour change — and leaving
   it in place is harmless if this step is missed.
3. Drop the render-time guard at `testkit/init.sh:103-105`, which exists for the
   same duplication. The `${`-placeholder check just above it stays; it covers
   the rest of the rendered config.
4. `workloads/warehouse/.env.example` — trim the `WORKSPACE_ID` comment back to
   "required by every command except `raw`"; the sentences about outranking the
   wiring document and about `run.sh` refusing to run become false.
5. `workloads/warehouse/README.md:102-103` — "Copy them as a starting point and
   adjust `workspace_id`" is then wrong; there is nothing to adjust.
6. `$AUTONOX_HOME/RUNBOOK.md` step 5 — drop the paragraph explaining which of the
   two names wins.

Keep this item open until all six are done: after 3b the mitigation is dead
weight that still reads as a live constraint.

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
| warehouse image | ~~warehouse `WAREHOUSE_IMAGE`, import `WAREHOUSE_IMG`~~ — **done**, both read `WAREHOUSE_IMAGE` from one `images.env` |
| noxop DSN | warehouse `WAREHOUSE_POSTGRES_DSN`, import (allow-listed via `*_CONTAINER_ENV_NAMES`) |
| docker network | warehouse `CONTAINER_NETWORK`, metabase `METABASE_DOCKER_NETWORK`, import (inside `*_CONTAINER_RUN_ARGS`) |

`postgres.env` overlaps with nothing — it configures the server, not a client.
Metabase's `MB_DB_*` is not duplication either: it connects as `bireader`.

What to fix is the **naming**, not the file count:

- ~~`WAREHOUSE_IMAGE` vs `WAREHOUSE_IMG`~~ **Done.** The import triplet is now
  `COLLECTOR_IMAGE` / `WAREHOUSE_IMAGE` / `RECONCILE_IMAGE`, matching the
  warehouse workload, and `images/resolve-digests.sh` writes all three — so the
  value that let a migrate and an import run different versions of the same
  image (item 6) now exists in one place.
- Three spellings of "the docker network" means an operator cannot grep their
  configuration for one concept. Still open.

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

### 9. Defaults that write inside this repo

The repo is meant to be immutable — replaceable wholesale on an upgrade — but
six paths default to writing into it. All are gitignored, so `git status` stays
clean and the breakage is invisible until someone replaces the tree.

| Path | Written by | Default that puts it here |
| --- | --- | --- |
| `tmp/testkit/receipts/` | `import.sh` via the testkit | `TESTKIT_ROOT=$ROOT/tmp/testkit` (`testkit/init.sh:6`, `run.sh:6`) |
| `tmp/testkit/artifacts/` | collector/warehouse/reconcile | same |
| `tmp/testkit/config/`, `*.env` | `testkit/init.sh` | same |
| `workloads/warehouse/.env` | operator | `ENV_FILE="${WAREHOUSE_ENV_FILE:-${SCRIPT_DIR}/.env}"` (`run.sh:9`) |
| `workloads/warehouse/config/` | operator | `WAREHOUSE_CONFIG_DIR="${…:-${SCRIPT_DIR}/config}"` (`run.sh:51`) |
| `metabase/compose/.env` | operator | Compose's own `.env` beside the spec |
| `tars/` | `images/airgap/pull-and-save.sh` | relative `./tars` (`load.sh:16`) |
| `metabase/tf/provider-mirror/` | `terraform providers mirror` | `tf/provider-mirror` |

Ranked by what actually hurts:

1. **Receipts.** `import-orchestration.md` calls them the durable record of an
   import and the only hand-off object between tasks — audit evidence. They
   must not live in a tree that gets deleted on upgrade. Even in the testkit
   they should default outside the repo.
2. **`workloads/warehouse` defaults.** Both the env file and the config dir
   default in-tree, so an operator who ignores the README puts customer config
   and a DSN inside the vendor tree. The README now says to use
   `WAREHOUSE_ENV_FILE`, but the default still leads the other way. Default to
   `$AUTONOX_HOME` and fail with a clear message when unset.
3. **`metabase/compose/.env`** — same as the postgres one already fixed; the
   Compose `--env-file` treatment applies unchanged.
4. **`tars/` and `provider-mirror/`** — large build outputs. Regenerable, so
   losing them is cheap, but they still make the tree non-replaceable in place.

Fix shape is the same one already applied to `postgres/compose` and
`workloads/warehouse`'s documentation: default to `$AUTONOX_HOME`, keep
generated output under `$AUTONOX_HOME/var/`, and never resolve a writable path
relative to the script.

Two stale leftovers exist right now from earlier runs and should be deleted:
`workloads/warehouse/.env` (no `WAREHOUSE_IMAGE`, wrong password) and
`metabase/compose/.env`.

### 10. mock-hr is a smoke test, not a fixture

One source, three identities, no accounts or entitlements. It cannot exercise
banding *across* sources — the case where several accounts collapse into one
identity — nor orphaned accounts, entitlements, or most of `bi_views`. A second
source with accounts correlated on `employee_id` would cover the parts that
matter, and the scenario contract makes that a new directory, not a harness
change.
