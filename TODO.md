# TODO

Findings from a full deployment rehearsal (PostgreSQL → migrations → import →
assert) against the mock-hr scenario, plus the structural review of the repo.
Grouped by who has to fix them.

This is a list of open work, not a ledger. Keep a completed item only while its
reasoning still constrains something open — a rejected alternative, a mitigation
waiting on an upstream fix, a correction that would otherwise be re-derived
wrong. Once nothing depends on it, delete it; git history holds the rest.

## Index

Priority is against **shipping this repo to a real customer**, not against
engineering taste. `P0` = do it before go-live. `P1` = soon after, or before the
second customer. `P2` = maintainability; nothing breaks if it waits.

| # | Item | Owner | Pri | Why that priority |
| --- | --- | --- | --- | --- |
| [1](#1-reconciliation-creates-publicschema_migrations--closed-here) | Reconciliation creates `public.schema_migrations` | ~~here~~ / upstream [rec#14](https://github.com/autonox-ai/reconciliation/issues/14) | **done** | Fixed by setting `migrations_schema` in the reconcile wiring; the `public` grant is gone from `testkit/run.sh` and was never needed. #14 remains open for the structural half (DDL in the runtime path) but blocks nothing. |
| [1b](#1b-no-supported-silver-lock-inspection-or-release) | No Silver lock inspection or release | upstream [wh#37](https://github.com/autonox-ai/warehouse/issues/37) | P2 | A stuck lock costs 7200s of failed imports, but `import.sh retry-task` covers the operator path. |
| [2](#2-postgres-collector-emits-json-columns-as-strings) | Collector emits JSON columns as strings | upstream | P2 | Workaround (scalar columns, mapped one by one) is documented and proven in mock-hr. |
| [3](#3-banding-silently-no-ops-on-an-unmatched-source-name) | Banding silently no-ops on unmatched source | upstream | **P0** | Silent wrong data: row counts stay green while every attribute is null. Compounds with **10** — the smoke test cannot catch it. Go-live must assert a non-null attribute on the customer's real specs. |
| [3b](#3b-the-runtime-wiring-requires-workspace_id-which-is-not-a-wiring-concern) | Wiring requires `workspace_id` | upstream | P2 | Mitigated by **6b**; the guard holds. |
| [3c](#3c-cli-json-output-is-unversioned-so-the-orchestrator-hedges) | CLI JSON output is unversioned | upstream | P1 | Latent while digests are pinned. Becomes a live wrong-data risk the moment `manifest.txt` is bumped — until then, the constraint is: never bump without re-running the testkit. |
| [3d](#3d-nothing-pins-the-postgresbootstrap--warehouse-schema-contract) | Bootstrap ↔ Warehouse schema contract unpinned | upstream | P2 | Same class as **1**; surfaces as a loud migration failure, not silent corruption. |
| [6b](#6b-the-warehouse-workload-names-the-workspace-twice--mitigated-not-solved) | Workspace named twice — mitigated | here, blocked on 3b | P2 | Guard is in place and correct. The six cleanup steps are dead-weight removal. |
| [6c](#6c-one-concept-several-names-across-the-env-files) | One concept, several names across env files | here | P2 | Operator ergonomics. Costs one breaking rename, so do it between customers, not before one. |
| [7](#7-container_name-nox-pg18-is-daemon-global) | `container_name: nox-pg18` is daemon-global | here | P1 | Observed blocking a run, not theoretical: `run.sh e2e` under project `autonox-testkit` failed with `Conflict. The container name "/nox-pg18" is already in use`, and its `reset` could not drop `autonox-pgdata` because the other project held it. Testing a change against a live instance requires tearing that instance down first. |
| [8](#8-smaller) | Smaller | here | P2 — **except** the `manifest.txt` channel question, which is **P0** | `autonox-warehouse` is pinned to a `main` build with no release channel while `collectors` and `reconciliation` carry `enterprise`. Ship that knowingly or not at all. |
| [9](#9-defaults-that-write-inside-this-repo) | `provider-mirror/` written inside the repo | here | P1 | Tracked *and* gitignored, arm64 zip missing. Regeneration drifts silently — matters as soon as the air-gap bundle ships. |
| [10](#10-mock-hr-is-a-smoke-test-not-a-fixture) | mock-hr is a smoke test, not a fixture | here | P1 | A green testkit run proves less than it appears to. See **3** for the specific thing it fails to catch. |
| [11](#11-warehouse-config-vs-config--inconsistent-host-directory-convention) | `warehouse-config/` vs `config/` — inconsistent host directory convention | here | P2 | Operator ergonomics, same class as **6c**. Surfaced onboarding a real customer: nothing breaks, but the split is unexplained without reading both workloads' source. |

## Product — needs a change in the images, not here

### 1. Reconciliation creates `public.schema_migrations` — closed here

**Resolved in this repo without waiting for upstream.** `migrations_schema` is
already a supported wiring field (`wiring.spec.v1.schema.json:149`, validated at
`config.py:161-184`); only its *default* is wrong — absent, it resolves to
`"public"` (`runtime_context.py:334-337`), independently of
`control_plane_store.schema`. Setting it explicitly in
`testkit/scenarios/mock-hr/config/reconcile.yaml` puts the ledger in
`reconciliation`, which `setup.sql:76` already grants to `noxop` and
`setup.sql:141-148` already covers with default privileges for `noxreader`.

The `GRANT USAGE, CREATE ON SCHEMA public TO noxop` workaround is deleted from
`testkit/run.sh`. Verified on a clean `e2e mock-hr` bootstrap: import green
end to end, `has_schema_privilege('noxop','public','CREATE')` = `false`, zero
tables in `public`, and `schema_migrations` present only in `reconciliation`
and `warehouse`.

Keep this note until
[reconciliation#14](https://github.com/autonox-ai/reconciliation/issues/14)
ships — it explains why every reconcile wiring must carry `migrations_schema`,
which is otherwise an unexplained line that looks redundant beside `schema`.

**Still upstream, not blocking:** DDL runs inside
`PostgresReconciliationStore.__init__`, so every process migrates — including
read-only `reconcile get`/`list`/`validate` — and `noxop` holds `CREATE` on
`reconciliation` at runtime rather than DML only. That is what `reconcile
migrate` fixes, and it is when `workloads/` gains a third workload.

### 1b. No supported Silver lock inspection or release

Filed upstream as
[autonox-ai/warehouse#37](https://github.com/autonox-ai/warehouse/issues/37),
asking for `silver lock status` and a guarded `silver lock release`. `silver`
has only `run` and `finalize` today, so lock state is visible solely by reading
`warehouse.silver_workspace_locks` directly, and expiry (a liveness escape
hatch, per `import-orchestration.md:160`) is the only way out. A run that cannot
be finalized therefore blocks its workspace for the full 7200s even after the
operator knows exactly what happened and has fixed it.

`import.sh retry-task` covers the repo side of this — an operator who has fixed
the underlying problem gets a supported retry — but it cannot release a lock it
does not own.

**When #37 ships, in this repo:** have `retry-task` call `silver lock status`
before retrying, so a blocked workspace reports who holds it instead of failing
with `ERR_LOCK_UNAVAILABLE`.

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

Note this is a *different* skew from the image-pin one: both workloads now
resolve their digests from one `images.env`, so they run the same builds. What
is still unpinned is the shape of what those builds print.

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

The duplication is the price, and it is small — three values, not four files:

| Value | Duplicated across |
| --- | --- |
| `WORKSPACE_ID` | warehouse, import |
| noxop DSN | warehouse `WAREHOUSE_POSTGRES_DSN`, import (allow-listed via `*_CONTAINER_ENV_NAMES`) |
| docker network | warehouse `CONTAINER_NETWORK`, metabase `METABASE_DOCKER_NETWORK`, import (inside `*_CONTAINER_RUN_ARGS`) |

`postgres.env` overlaps with nothing — it configures the server, not a client.
Metabase's `MB_DB_*` is not duplication either: it connects as `bireader`.

What to fix is the **naming**, not the file count: three spellings of "the
docker network" means an operator cannot grep their configuration for one
concept.

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

Observed while verifying item 1: `run.sh e2e` under project `autonox-testkit`
died on `Conflict. The container name "/nox-pg18" is already in use`, after its
`reset` had already failed to remove `autonox-pgdata` ("Resource is still in
use") because the `autonox-postgres` project still held it. The only way
forward was `compose down -v` on the other stack — so verifying any change
costs the running instance. The `nox-pg18` network alias
(`compose.yaml:29-31`) already gives peers a stable hostname, so dropping the
pin does not change how containers reach the database; it only changes the
`docker exec nox-pg18` lines in the READMEs.

### 8. Smaller

- `testkit/init.sh:155-157` — `--user 0` for all three containers, unexplained.
  Find out why root is needed, comment it, or drop it.
- `testkit/init.sh:153` — `warehouse_volumes` mounts the config dir twice now
  that import and warehouse config resolved to the same directory.
- `images/manifest.txt` — `autonox-warehouse` is pinned to latest `main`; that
  package has no release channel, only branch tags, unlike `collectors` and
  `reconciliation` which carry `enterprise`. Confirm that is intended.
- `workloads/import/import.sh:153` — the `find`-based manifest fallback
  contradicts `import-orchestration.md`'s "never search a filesystem for a
  manifest". Prefer fixing the collector contract to always emit `manifest.uri`
  so the fallback can go.
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
| `metabase/tf/provider-mirror/` | `terraform providers mirror` | relative `provider-mirror/` (`metabase/tf/README.md:50`) |

The fix takes the shape already applied elsewhere: default to `$AUTONOX_HOME`,
keep generated output under `$AUTONOX_HOME/var/`, and never resolve a writable
path relative to the script. `provider-mirror/` is a regenerable build output,
so losing it is cheap — it just makes the tree non-replaceable in place.

Note the mirror is *committed* today — the index JSONs and the linux/amd64 zip
are tracked, the arm64 zip beside them is not — while the path is also
gitignored, so a regeneration silently adds nothing and drifts. Decide first
whether the mirror ships as vendor content (then drop the ignore rule and track
both platforms) or is generated per-install (then move the write target to
`$AUTONOX_HOME/var/` and untrack it). Redirecting the output without settling
that leaves the tracked copy stale.

### 10. mock-hr is a smoke test, not a fixture

One source, three identities, no accounts or entitlements. It cannot exercise
banding *across* sources — the case where several accounts collapse into one
identity — nor orphaned accounts, entitlements, or most of `bi_views`. A second
source with accounts correlated on `employee_id` would cover the parts that
matter, and the scenario contract makes that a new directory, not a harness
change.

### 11. `warehouse-config/` vs `config/` — inconsistent host directory convention

`workloads/warehouse/run.sh` mounts `WAREHOUSE_CONFIG_DIR` wholesale into the
container at a fixed path, `/config` (`run.sh:108`), and the CLI inside
defaults to `/config/warehouse-wiring.yaml` and
`/config/warehouse-canonical-wiring.yaml` (`run.sh:81-82`). That host
directory therefore has to be dedicated — nothing else can live in it, because
the whole thing gets mounted as `/config`. Hence `warehouse-config/`.

`workloads/import` has no equivalent mechanism. `RECONCILE_WIRING`,
`COLLECTOR_SPEC`, `FLOW_SPEC`, `BANDING_SPEC` and `CONNECTION_CATALOG` are
just host file paths named individually in `*_CONTAINER_VOLUMES` — `import.sh`
doesn't care what directory they live in. `.env.example` picks
`/etc/autonox/config/` as a shared home for all of them and mounts it at the
*same* path inside the container (not `/config`), but that is a documentation
convention, not something the code enforces.

Result: two directories with overlapping-sounding names (`warehouse-config`,
`config`) where one is a hard mount contract and the other is an arbitrary
example choice — indistinguishable to an operator without reading both
workloads' source, as happened onboarding a real customer. Doesn't block
anything; costs an explanation every time someone new sets up a deployment.

**Ask:** either document the distinction prominently (top-level README's
folder map, or each workload's README) or rename `config/` to something that
doesn't rhyme with `warehouse-config/` — e.g. `import-config/` — so the two
read as unrelated rather than as an inconsistent pair.
