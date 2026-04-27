# PostgreSQL — deployment guide

AutoNox needs a PostgreSQL 18 instance with the `vector` extension. There are
**three customer modes**, each with a different split of responsibility:

| Mode | Customer provides | AutoNox provides |
|---|---|---|
| **1 — Fully managed** | Postgres instance **+** users, schemas, grants ready to use | Nothing here. AutoNox connects with the credentials the DBA delivers. |
| **2 — Partial** | Postgres instance with admin credentials | Roles, passwords, schemas, extensions, grants via [`bootstrap/`](bootstrap/) |
| **3 — Self-managed** | Linux host or Kubernetes cluster | The PG instance itself ([`compose/`](compose/) or [`kustomize/`](kustomize/)) **+** the bootstrap from mode 2 |

## Decision tree

1. **Has the customer's DBA delivered a database with users/schemas/grants?** → mode 1, skip everything below; hand the connection string to AutoNox apps.
2. **Has the customer given you an empty Postgres instance with admin access?** → mode 2, run [`bootstrap/setup.sql`](bootstrap/setup.sql), apply [`bootstrap/passwords.sql`](bootstrap/passwords.sql), then provision workspaces with [`bootstrap/ws_setup.sql.tmpl`](bootstrap/ws_setup.sql.tmpl).
3. **Are you bringing up Postgres yourselves?** → mode 3:
   - single Linux host → [`compose/`](compose/) (auto-applies bootstrap on first start)
   - Kubernetes / OpenShift → [`kustomize/`](kustomize/) (apply bootstrap manually after first pod is ready)

## Folder map

```
postgres/
├── bootstrap/      # SQL applied in modes 2 and 3
│   ├── setup.sql              # database, roles, schemas, extensions, grants
│   ├── passwords.sql          # role password updates using psql variables
│   └── ws_setup.sql.tmpl      # per-workspace schema provisioning (envsubst)
├── compose/        # mode 3 — single-host Docker Compose
└── kustomize/      # mode 3 — Kubernetes StatefulSet
```

## Mode 2 runbook (customer-managed instance)

Apply the bootstrap against the customer's PostgreSQL instance with admin
credentials.

`PG_ADMIN_URL` is a PostgreSQL connection string for an admin role, usually
pointing at the default `postgres` database because `setup.sql` creates the
`autonox` database itself.

Template:

```bash
export PG_ADMIN_URL='postgresql://<admin_user>:<admin_password>@<pg_host>:<pg_port>/postgres'
```

Example for a database exposed on the local host:

```bash
export PG_ADMIN_URL='postgresql://postgres:<admin-password>@localhost:5432/postgres'
```

If `psql` is installed on the deploy host, run:

```bash
psql "$PG_ADMIN_URL" -f postgres/bootstrap/setup.sql
```

If `psql` is only available inside the PostgreSQL container, stream the SQL
into the container instead:

```bash
docker exec -i <postgres-container> psql -U <admin_user> -d postgres < postgres/bootstrap/setup.sql
```

Example with the bundled Compose container name:

```bash
docker exec -i nox-pg18 psql -U postgres -d postgres < postgres/bootstrap/setup.sql
```

This creates:

- database `autonox`
- login roles `noxop`, `noxreader`, `bireader`
- schemas `warehouse`, `reconciliation`, `shared`, `bi_views`, `analytics`, `audit`
- extensions `uuid-ossp`, `pgcrypto`, `vector`

Set role passwords from customer-managed secret values. This step is required
before workloads can connect, and it can be rerun later to rotate passwords.

```bash
export NOXOP_PASSWORD='<noxop-password>'
export NOXREADER_PASSWORD='<noxreader-password>'
export BIREADER_PASSWORD='<bireader-password>'
```

With host-side `psql`:

```bash
psql "$PG_ADMIN_URL" \
  -v noxop_password="$NOXOP_PASSWORD" \
  -v noxreader_password="$NOXREADER_PASSWORD" \
  -v bireader_password="$BIREADER_PASSWORD" \
  -f postgres/bootstrap/passwords.sql
```

With container-side `psql`:

```bash
docker exec -i <postgres-container> psql -U <admin_user> -d postgres \
  -v noxop_password="$NOXOP_PASSWORD" \
  -v noxreader_password="$NOXREADER_PASSWORD" \
  -v bireader_password="$BIREADER_PASSWORD" \
  < postgres/bootstrap/passwords.sql
```

Example with the bundled Compose container name:

```bash
docker exec -i nox-pg18 psql -U postgres -d postgres \
  -v noxop_password="$NOXOP_PASSWORD" \
  -v noxreader_password="$NOXREADER_PASSWORD" \
  -v bireader_password="$BIREADER_PASSWORD" \
  < postgres/bootstrap/passwords.sql
```

Provision a workspace schema:

With host-side `psql`:

```bash
WS_NAME=prod envsubst < postgres/bootstrap/ws_setup.sql.tmpl | psql "$PG_ADMIN_URL" -d autonox
```

With container-side `psql`:

```bash
WS_NAME=prod envsubst < postgres/bootstrap/ws_setup.sql.tmpl \
  | docker exec -i <postgres-container> psql -U <admin_user> -d autonox
```

Example with the bundled Compose container name:

```bash
WS_NAME=prod envsubst < postgres/bootstrap/ws_setup.sql.tmpl \
  | docker exec -i nox-pg18 psql -U postgres -d autonox
```

## Mode 3 runbook (AutoNox-managed)

- Compose path: see [`compose/README.md`](compose/README.md). The compose spec
  mounts `bootstrap/setup.sql` into `docker-entrypoint-initdb.d`, so the
  bootstrap runs automatically on first start. Apply `bootstrap/passwords.sql`
  after first start to set application role passwords.
- Kubernetes path: see [`kustomize/README.md`](kustomize/README.md). After the
  StatefulSet is ready, run the workspace template against the in-cluster
  service.
