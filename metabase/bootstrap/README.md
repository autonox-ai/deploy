# Metabase bootstrap SQL

[`setup.sql.tmpl`](setup.sql.tmpl) is an `envsubst` template that creates the
Metabase application database and role on the AutoNox PostgreSQL instance.
Apply it **before** starting the Metabase service.

## Variables

- `METABASE_DB` — application database name (recommended: `metabase`)
- `METABASE_USER` — login role (recommended: `metabase_user`)
- `METABASE_PASSWORD` — password for that role

## Apply

Bundled PostgreSQL container:

```bash
export METABASE_DB=metabase
export METABASE_USER=metabase_user
export METABASE_PASSWORD=secret

envsubst < setup.sql.tmpl | docker exec -i nox-pg18 psql -U postgres -d postgres
```

Customer-managed PostgreSQL:

```bash
export METABASE_DB=metabase
export METABASE_USER=metabase_user
export METABASE_PASSWORD=secret
export PG_ADMIN_URL='postgresql://<admin_user>:<admin_password>@<pg_host>:<pg_port>/postgres'

envsubst < setup.sql.tmpl | psql "$PG_ADMIN_URL" -d postgres
```

The template is idempotent — the role is only created if missing, and the
database is only created if missing.
