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

- image: `pgvector/pgvector:0.8.2-pg18-trixie`
- container name: `nox-pg18`
- Docker network: `autonox-local`
- Docker volume: `autonox-pgdata`

## Start the bundled PostgreSQL server

### 1. Pre-load the image

Connected environment:

```bash
docker pull --platform=linux/amd64 pgvector/pgvector:0.8.2-pg18-trixie
```

Air-gapped handoff: see [`../../images/airgap/README.md`](../../images/airgap/README.md).

### 2. Prepare the environment file

```bash
cd postgres/compose
cp .env.example .env
```

Defaults are intentionally simple for POCs. Set `POSTGRES_PASSWORD` to a
customer-managed secret before starting the container.

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

Once PostgreSQL is running, continue with:

1. Application role passwords via [`../bootstrap/passwords.sql`](../bootstrap/passwords.sql)
2. Workspace provisioning via [`../bootstrap/ws_setup.sql.tmpl`](../bootstrap/ws_setup.sql.tmpl)

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
