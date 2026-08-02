# PostgreSQL via Docker Compose (mode 3)

Single-host pgvector-enabled PostgreSQL container for AutoNox.

This bundle covers **mode 3** (AutoNox-managed PostgreSQL end-to-end). For
modes 1 (customer DBA owns everything) and 2 (customer provides the instance,
AutoNox provisions roles/schemas), see [`../README.md`](../README.md).

The Compose spec bind-mounts the shared bootstrap SQL from
[`../bootstrap/setup.sql`](../bootstrap/setup.sql), so the `autonox` database
and core roles are created automatically on first startup. Role passwords are
set after startup with [`../bootstrap/passwords.sql`](../bootstrap/passwords.sql).

## What you get

- image: `pgvector/pgvector:0.8.5-pg18-trixie`
- container name: `nox-pg18`
- Docker network: `autonox-local`
- Docker volume: `autonox-pgdata`

## Start the bundled PostgreSQL server

Run every command below from the **repository root**. Nothing in this guide
writes into the repository — see step 2.

### 1. Pre-load the image

Connected environment:

```bash
docker pull --platform=linux/amd64 pgvector/pgvector:0.8.5-pg18-trixie
```

Air-gapped handoff: see [`../../images/airgap/README.md`](../../images/airgap/README.md).

### 2. Prepare the environment file

Configuration lives **outside this repository**, in a directory you own, so
that upgrading AutoNox is "replace the repo, keep your config". This guide
calls that directory `$AUTONOX_HOME` and defaults it to `/etc/autonox`.

```bash
export AUTONOX_HOME="${AUTONOX_HOME:-/etc/autonox}"
mkdir -p "$AUTONOX_HOME"
cp postgres/compose/postgres.env.example "$AUTONOX_HOME/postgres.env"
chmod 600 "$AUTONOX_HOME/postgres.env"
```

**Required:** set `POSTGRES_PASSWORD` in `$AUTONOX_HOME/postgres.env` to a
real, customer-managed secret. It ships empty on purpose — no baked-in
secrets — and `docker compose up` will refuse to start until it's set.

Never edit files inside this repository. `git status --porcelain` (or a
checksum of the tree) should stay empty after every step in this guide.

### 3. Start PostgreSQL

```bash
docker compose -f postgres/compose/compose.yaml \
  --env-file "$AUTONOX_HOME/postgres.env" up -d
```

To drop the flags from every later command, export the path once — Compose
reads it automatically (requires Compose v2.24+):

```bash
export COMPOSE_FILE="$PWD/postgres/compose/compose.yaml"
export COMPOSE_ENV_FILES="$AUTONOX_HOME/postgres.env"
docker compose up -d
```

The rest of this guide assumes those two exports are set; without them, add
`-f` and `--env-file` to each `docker compose` invocation. Bind-mount paths in
the spec resolve relative to `compose.yaml`, so it runs correctly from any
working directory.

On first startup, Compose mounts the shared AutoNox bootstrap SQL into
`/docker-entrypoint-initdb.d`, so the `autonox` database and core roles are
created automatically. The bootstrap creates application roles without
passwords; set them in the next step.

If the host still uses the legacy Compose v1 binary, replace `docker compose`
with `docker-compose`.

### 4. Verify

```bash
docker compose ps
docker logs nox-pg18
docker exec nox-pg18 pg_isready -U postgres -d postgres
```

### 5. Set application role passwords

```bash
export NOXOP_PASSWORD='<noxop-password>'
export NOXREADER_PASSWORD='<noxreader-password>'
export BIREADER_PASSWORD='<bireader-password>'

docker exec -i nox-pg18 psql -U postgres -d postgres \
  -v noxop_password="$NOXOP_PASSWORD" \
  -v noxreader_password="$NOXREADER_PASSWORD" \
  -v bireader_password="$BIREADER_PASSWORD" \
  < postgres/bootstrap/passwords.sql
```

These three values are also embedded in the consumers that outlive the database
— `WAREHOUSE_POSTGRES_DSN` in `workloads/warehouse`, `MB_DB_PASS` in
`metabase`, and the import env. A `down -v` drops the roles but not those
files, so re-running this step after one must use the same passwords, or every
consumer has to be updated to match.

### 6. Connect other containers

Attach future AutoNox containers to the `autonox-local` network.

Use one of these hostnames from peer containers:

- `postgres`
- `nox-pg18`

Port is always `5432`.

## Next step

PostgreSQL and application role passwords are done above. Continue, per
workspace and in order:

1. Workspace schema via [`../bootstrap/ws_setup.sql.tmpl`](../bootstrap/ws_setup.sql.tmpl)
   — admin-run, creates the `ws_<name>` schema and grants. A hard prerequisite
   for step 2: `workloads/warehouse` does not create workspace schemas itself.

   The template's own header shows the generic `psql "$PG_ADMIN_URL"` form for
   an externally-reachable instance (mode 2). For this Compose container,
   generate the file on the host, then apply it inside the container instead:

   ```bash
   mkdir -p "$AUTONOX_HOME/var/sql"
   WS_NAME=prod envsubst < postgres/bootstrap/ws_setup.sql.tmpl \
     > "$AUTONOX_HOME/var/sql/ws_prod_setup.sql"
   docker exec -i nox-pg18 psql -U postgres -d autonox \
     < "$AUTONOX_HOME/var/sql/ws_prod_setup.sql"
   ```

   Generated SQL goes to `$AUTONOX_HOME/var/`, not into this repo, for the
   same reason as the environment file. Everything under `var/` is output —
   rendered SQL, run logs, evidence — and is safe to delete; the files beside
   it are the configuration you own.
2. Warehouse migrations via [`../../workloads/warehouse/README.md`](../../workloads/warehouse/README.md)
   — runs as `noxop`, creates tables inside the schema from step 1.
3. Import via [`../../workloads/import/README.md`](../../workloads/import/README.md)

The authoritative flow is in [`../README.md`](../README.md).

## Stop or remove

These also interpolate the spec, so they need the same env file (or the
`COMPOSE_FILE` / `COMPOSE_ENV_FILES` exports from step 3).

Stop while keeping data:

```bash
docker compose down
```

Remove the database volume as well:

```bash
docker compose down -v
```

Neither removes `$AUTONOX_HOME` — your configuration survives teardown and
repo upgrades alike.
