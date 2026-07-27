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

### 1. Pre-load the image

Connected environment:

```bash
docker pull --platform=linux/amd64 pgvector/pgvector:0.8.5-pg18-trixie
```

Air-gapped handoff: see [`../../images/airgap/README.md`](../../images/airgap/README.md).

### 2. Prepare the environment file

```bash
cd postgres/compose
cp .env.example .env
```

**Required:** set `POSTGRES_PASSWORD` in `.env` to a real, customer-managed
secret. It ships empty on purpose — no baked-in secrets — and `docker compose
up` will refuse to start until it's set.

### 3. Start PostgreSQL

```bash
docker compose up -d
```

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
  < ../bootstrap/passwords.sql
```

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
   WS_NAME=prod envsubst < ../bootstrap/ws_setup.sql.tmpl > ws_prod_setup.sql
   docker exec -i nox-pg18 psql -U postgres -d autonox < ws_prod_setup.sql
   ```
2. Warehouse migrations via [`../../workloads/warehouse/README.md`](../../workloads/warehouse/README.md)
   — runs as `noxop`, creates tables inside the schema from step 1.
3. Import via [`../../workloads/import/README.md`](../../workloads/import/README.md)

The authoritative flow is in [`../README.md`](../README.md).

## Stop or remove

Stop while keeping data:

```bash
docker compose down
```

Remove the database volume as well:

```bash
docker compose down -v
```
