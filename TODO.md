# TODO

Findings from a full deployment rehearsal (PostgreSQL → migrations → import →
assert) against the mock-hr scenario, plus the structural review of the repo.
Grouped by who has to fix them. Strike through and annotate when done rather
than deleting — the reasoning is worth more than the checkbox.

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

### 1b. No supported Silver lock inspection or release

`warehouse silver` has only `run` and `finalize`. Lock state is visible solely
by reading `warehouse.silver_workspace_locks` directly, and expiry (a liveness
escape hatch, per `import-orchestration.md:160`) is the only way out. A run that
cannot be finalized therefore blocks its workspace for the full 7200s even after
the operator knows exactly what happened and has fixed it.

The two repo-side gaps that used to sit here are done. `import.sh retry-task
--receipt <r> --task <name> --acknowledge <reason>` gives a failed task a
first-class, operator-acknowledged retry path: it archives the failed attempt
under `tasks.<name>.history` and records the acknowledgement in
`operator_actions` instead of requiring a hand-edited receipt, and the Bronze
and reconciliation stages now gate per task so a retry never recollects,
re-registers, reruns `stage-run`, or reapplies intents. `publish_receipt` takes
`max(sequence, highest_sequence_on_disk + 1)`, so numbers are never reused and
`latest` cannot regress below evidence still on disk. Both are covered by
`workloads/import/tests/import_test.sh`.

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

### 3c. CLI JSON output is unversioned, so the orchestrator hedges

`import.sh` carries 22 `//` fallbacks across its task assertions
(`import.sh:310-410`) — `.state // .status`,
`.manifest_sha256 // .manifest_hash`, `.workspace_id // .workspace`,
`.staging_ref // .staging_evidence`. Each one is the orchestrator not knowing
which CLI version it is talking to and accepting both shapes.

That is a silent wrong-data risk, not cosmetics: bump `manifest.txt`, the output
shape changes, and a hedge picks the wrong branch or an assertion passes when it
should not. The assertions are the only thing standing between a half-committed
Bronze run and a receipt that says everything succeeded.

**Ask:** version the JSON output contracts in collectors, warehouse and
reconciliation. Then `import.sh` asserts the contract version it requires once,
at startup, fails loudly on a mismatch, and the 22 hedges delete themselves.
Item **6** is the same skew seen from the warehouse side.

> **Rejected: moving the orchestrator into an image.** An earlier framing of
> this called for `import.sh` to become `autonox import` or ship as its own
> entry in `manifest.txt`, on the grounds that 438 lines of correctness-critical
> state machine should not ship as a repo file while the CLIs it drives ship as
> digests.
>
> Relocation does not fix the skew, it moves it — four mutually compatible
> images instead of three plus a script. A subcommand would put the driver
> inside one of the images it spawns. Its own image needs Docker-in-Docker or a
> mounted container socket, which many customers forbid, and adds another tar to
> the air-gap bundle. Both also cost the property worth keeping: the
> orchestrator is the one component a customer can read, audit and patch without
> a rebuild, which for software that writes access decisions is a feature.
>
> Once the contracts are versioned, where the orchestrator lives is a
> preference, not a correctness question.

### 3d. Nothing pins the `postgres/bootstrap` ↔ Warehouse schema contract

`postgres/bootstrap/setup.sql:56-61` and `ws_setup.sql.tmpl` create the schema
set and grants that `workloads/warehouse`'s `migrate`, `canonical migrate` and
`install-access-layer` assume already exist. A Warehouse release needing a new
schema requires `setup.sql` to be updated in lockstep, and no version check
enforces it — the failure surfaces as a permission or missing-relation error
during migration rather than as a version mismatch.

Item **1** is one instance of exactly this: reconciliation needs a schema the
bootstrap does not grant, and the fix was a manual `GRANT` bolted onto the
runbook.

**Ask:** a schema-version assertion the image checks at migrate time, or at
minimum a compatibility statement stating which bootstrap revision a given
image release requires.

## This repo

### 4. Customer config still written in-tree

The `$AUTONOX_HOME` convention is done for `postgres/compose`,
`workloads/warehouse` and now `workloads/import`. Still telling customers to
write into the repo:

- ~~`workloads/README.md:44`~~ **Done.** The example shape now writes both env
  files to `$AUTONOX_HOME` and invokes `run-import.sh` rather than a bare
  `run.sh`.
- ~~`workloads/import/README.md:14`~~ **Done.** The Quickstart was the last
  documented path that wrote a DSN into the vendor tree, and it contradicted
  `run-import.sh` — which already requires `AUTONOX_HOME` — thirteen lines
  further down the same file. It now splits `.env.example` into
  `$AUTONOX_HOME/import.env` plus `$AUTONOX_HOME/sources/<source>.env`, which
  is what `.env.example`'s own header always described.
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

**Watch, not yet actionable — the size of the env surface.** Import requires 21
variables (`import.sh:516`) plus nine `*_CONTAINER_ENV_NAMES` / `*_VOLUMES` /
`*_RUN_ARGS` entries and a tail of optional ones, and each new component adds
another triplet. Collapsing this into an
import profile was decided against deliberately
(`import-orchestration.md:84,189`), and `run-import.sh` addressed the real pain
— composition and leakage between sources — without it. Nothing to do now. If
it does bite, the seam is schema validation over the composed environment, not
a return to the profile.

### 7. `container_name: nox-pg18` is daemon-global

`postgres/compose/compose.yaml:5` pins it, so `TESTKIT_COMPOSE_PROJECT` cannot
give two stacks side by side and the testkit collides with a running instance.
Drop the pin and resolve the container through Compose (`run.sh` already does).

### 8. Smaller

- `testkit/init.sh:155-157` — `--user 0` for all three containers, unexplained.
  Find out why root is needed, comment it, or drop it.
- `testkit/init.sh:153` — `warehouse_volumes` mounts the config dir twice now
  that import and warehouse config resolved to the same directory.
- ~~`images/manifest.txt:30` — `metabase/metabase:v0.58.x` is a floating tag~~
  **Done.** Pinned to `v0.58.22`, and `hashicorp/terraform:1.9` to `1.9.8`, in
  the manifest and in the five other places that named them.
- `images/manifest.txt` — `autonox-warehouse` is pinned to latest `main`; that
  package has no release channel, only branch tags, unlike `collectors` and
  `reconciliation` which carry `enterprise`. Confirm that is intended.
- `workloads/import/import.sh:153` — the `find`-based manifest fallback
  contradicts `import-orchestration.md`'s "never search a filesystem for a
  manifest". Prefer fixing the collector contract to always emit `manifest.uri`
  so the fallback can go.
- ~~`workloads/import/README.md` — document the bash ≥ 4.3 requirement.~~
  **Done.** Stated alongside the `jq` / SHA-256 / container-runtime
  prerequisites, naming the nameref in `read_nul_array` as the reason and
  Homebrew bash as the way out on macOS.
- **Dedupe the example wiring YAML.** `workloads/warehouse/examples/config/`
  (`workspace_id: prod`) and `testkit/templates/config/` (`hello`) differ in two
  lines. Pick one canonical copy and point the other at it. Sequence this after
  **6b**, which deletes a field from both and from a third copy.

### 9. Defaults that write inside this repo

The repo is meant to be immutable — replaceable wholesale on an upgrade — but
several paths defaulted to writing into it. All were gitignored, so `git status`
stayed clean and the breakage stayed invisible until someone replaced the tree.

Mostly closed. Still open:

| Path | Written by | Default that puts it here |
| --- | --- | --- |
| `metabase/compose/.env` | operator | Compose's own `.env` beside the spec (`metabase/compose/README.md:60`) |
| `metabase/tf/provider-mirror/` | `terraform providers mirror` | relative `provider-mirror/` (`metabase/tf/README.md:50`) |

Both take the shape already applied elsewhere: default to `$AUTONOX_HOME`, keep
generated output under `$AUTONOX_HOME/var/`, and never resolve a writable path
relative to the script. The Compose one is the same `--env-file` treatment
`postgres/compose` already got. `provider-mirror/` is a regenerable build
output, so losing it is cheap — it just makes the tree non-replaceable in place.

One stale leftover exists right now and should be deleted: `metabase/compose/.env`.

**Fixed since this was written**, all verified in the current tree:

- **Receipts, artifacts and testkit config** — the entry that mattered most,
  because `import-orchestration.md` calls receipts durable audit evidence and
  they must not sit in a tree that gets deleted on upgrade. `TESTKIT_ROOT` now
  defaults to `${AUTONOX_HOME:-$HOME/.autonox}/var/testkit` in both
  `testkit/init.sh` and `testkit/run.sh`, each carrying a comment saying why.
  `import.sh` never had an in-repo default: `RECEIPT_DIR` is required
  (`import.sh:117`, `:516`) and `.env.example:95` points at
  `/srv/autonox/import-receipts`.
- **`workloads/warehouse` env file and config dir** — `run.sh` refuses to start
  unless `AUTONOX_HOME` or `WAREHOUSE_ENV_FILE` is set (`run.sh:13-18`), and
  `WAREHOUSE_CONFIG_DIR` resolves under `$AUTONOX_HOME` (`run.sh:66`). The
  `workloads/warehouse/.env` leftover named here is gone.
- **`tars/`** — `images/airgap/pull-and-save.sh` and `images/airgap/load.sh`
  both require the bundle directory as an argument and exit 2 without one,
  telling the caller to keep bundles outside the repository.

### 10. mock-hr is a smoke test, not a fixture

One source, three identities, no accounts or entitlements. It cannot exercise
banding *across* sources — the case where several accounts collapse into one
identity — nor orphaned accounts, entitlements, or most of `bi_views`. A second
source with accounts correlated on `employee_id` would cover the parts that
matter, and the scenario contract makes that a new directory, not a harness
change.
