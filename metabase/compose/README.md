# Metabase via Docker Compose

Optional self-hosted Metabase deployment for AutoNox. Use only when the
customer does not already have a BI platform such as BusinessObjects or
Power BI.

## Scope

This document covers running the Metabase container. The Metabase application
database is provisioned separately via [`../bootstrap/setup.sql.tmpl`](../bootstrap/setup.sql.tmpl).

This is **not** the AutoNox PostgreSQL bootstrap — see
[`../../postgres/README.md`](../../postgres/README.md) for that.

## What you get

- container name: `nox-metabase`
- port: `3000`
- shared network: `autonox-local`
- PostgreSQL-backed Metabase metadata store (provisioned via `../bootstrap/`)

## Run Metabase

Run every command below from the **repository root**. Nothing in this guide
writes into the repository — see step 2.

### Step 1: provision the Metabase application database

Metabase needs its own database and role, separate from the AutoNox schemas.

```bash
export METABASE_DB=metabase
export METABASE_USER=metabase_user
export METABASE_PASSWORD='<metabase-password>'
```

These values must match the Metabase environment file written in step 2:

- `METABASE_DB` → `MB_DB_DBNAME`
- `METABASE_USER` → `MB_DB_USER`
- `METABASE_PASSWORD` → `MB_DB_PASS`

Bundled PostgreSQL example:

```bash
envsubst < metabase/bootstrap/setup.sql.tmpl | docker exec -i nox-pg18 psql -U postgres -d postgres
```

Customer-managed PostgreSQL example:

```bash
envsubst < metabase/bootstrap/setup.sql.tmpl | psql "$PG_ADMIN_URL" -d postgres
```

This creates:

- role `metabase_user`
- database `metabase` owned by `metabase_user`
- `CREATE` access on schema `public`

### Step 2: configure the Metabase environment

Configuration lives **outside this repository**, in a directory you own, so
that upgrading AutoNox is "replace the repo, keep your config". This guide
calls that directory `$AUTONOX_HOME` and defaults it to `/etc/autonox` — the
same directory [`../../postgres/compose/README.md`](../../postgres/compose/README.md)
and the workloads use.

```bash
export AUTONOX_HOME="${AUTONOX_HOME:-/etc/autonox}"
mkdir -p "$AUTONOX_HOME"
cp metabase/compose/metabase.env.example "$AUTONOX_HOME/metabase.env"
chmod 600 "$AUTONOX_HOME/metabase.env"
```

Keep these values in `$AUTONOX_HOME/metabase.env` aligned with the database and
role created in step 1:

```bash
MB_DB_DBNAME=metabase
MB_DB_USER=metabase_user
MB_DB_PASS=<metabase-password>
```

**Required:** `MB_DB_PASS` ships empty on purpose — no baked-in secrets — and
`docker compose up` refuses to start until it's set.

Recommended defaults when using the bundled PostgreSQL container:

- `MB_DB_HOST=postgres`
- `MB_DB_PORT=5432`

If the customer uses a managed PostgreSQL service instead, set `MB_DB_HOST`,
`MB_DB_PORT`, `MB_DB_DBNAME`, `MB_DB_USER`, and `MB_DB_PASS` accordingly.

This is better than using `host.docker.internal` on Linux because Metabase can
connect directly over the shared container network.

Update `METABASE_IMAGE` to the exact approved image tag for the customer
environment if needed.

Never edit files inside this repository. `git status --porcelain` (or a
checksum of the tree) should stay empty after every step in this guide.

### Step 3: start Metabase

```bash
docker compose -f metabase/compose/compose.yaml \
  --env-file "$AUTONOX_HOME/metabase.env" up -d
```

To drop the flags from every later command, export the path once — Compose
reads it automatically (requires Compose v2.24+):

```bash
export COMPOSE_FILE="$PWD/metabase/compose/compose.yaml"
export COMPOSE_ENV_FILES="$AUTONOX_HOME/metabase.env"
docker compose up -d
```

The rest of this guide assumes those two exports are set; without them, add
`-f` and `--env-file` to each `docker compose` invocation. If PostgreSQL was
started the same way, its exports name a different spec and env file — set
these in a separate shell, or keep passing the flags explicitly.

If the host still uses the legacy Compose v1 binary, replace `docker compose`
with `docker-compose`.

This Compose file expects the `autonox-local` network to already exist. If
PostgreSQL was started from
[`../../postgres/compose/compose.yaml`](../../postgres/compose/compose.yaml),
that network is already created.

If PostgreSQL is customer-managed and that network does not exist yet, either:

- create it once with `docker network create autonox-local`
- or set `METABASE_DOCKER_NETWORK` in `$AUTONOX_HOME/metabase.env` to an
  existing network name

### Step 4: verify

```bash
docker compose ps
docker logs nox-metabase
```

Then open:

- [http://localhost:3000](http://localhost:3000)

### Step 5 (optional): apply Terraform configuration

After Metabase is reachable, configure data sources, cards, and dashboards
declaratively from [`../tf/`](../tf/). See [`../tf/README.md`](../tf/README.md).

## Stop or remove

These also interpolate the spec, so they need the same env file (or the
`COMPOSE_FILE` / `COMPOSE_ENV_FILES` exports from step 3):

```bash
docker compose down
```

That does not remove `$AUTONOX_HOME/metabase.env` — your configuration survives
teardown and repo upgrades alike. Metabase itself is stateless here; its
metadata lives in the PostgreSQL database from step 1.

## Notes

- Metabase is optional and should not be treated as part of the AutoNox core
  bootstrap.
- Keep Metabase metadata in its own database instead of reusing the `autonox`
  database.
