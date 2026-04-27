# Metabase — deployment guide (optional)

Self-hosted Metabase plus declarative configuration of its data sources,
cards, and dashboards. Use only when the customer does not already have a BI
platform.

## Folder map

```
metabase/
├── bootstrap/      # SQL: create Metabase DB + role on the AutoNox PG instance
├── compose/        # Run Metabase as a Docker container (single host)
├── kustomize/      # Run Metabase on Kubernetes
├── tf/             # Terraform: data sources, cards, dashboards
└── tf-runner/      # Air-gapped Terraform docker image (provider pre-mirrored)
```

## End-to-end flow

1. **Provision the Metabase database** — run
   [`bootstrap/setup.sql.tmpl`](bootstrap/setup.sql.tmpl) against the AutoNox
   PostgreSQL instance to create the `metabase` database and role. (Keep
   separate from the AutoNox schemas.)

   ```bash
   export METABASE_DB=metabase
   export METABASE_USER=metabase_user
   export METABASE_PASSWORD='<metabase-password>'
   ```

   `PG_ADMIN_URL` is a PostgreSQL connection string for an admin role, usually
   pointing at the default `postgres` database because the template creates the
   Metabase database itself.

   ```bash
   export PG_ADMIN_URL='postgresql://<admin_user>:<admin_password>@<pg_host>:<pg_port>/postgres'
   ```

   Example for a database exposed on the local host:

   ```bash
   export PG_ADMIN_URL='postgresql://postgres:<admin-password>@localhost:5432/postgres'
   ```

   With host-side `psql`:

   ```bash
   envsubst < metabase/bootstrap/setup.sql.tmpl | psql "$PG_ADMIN_URL" -d postgres
   ```

   With container-side `psql`:

   ```bash
   envsubst < metabase/bootstrap/setup.sql.tmpl \
     | docker exec -i <postgres-container> psql -U <admin_user> -d postgres
   ```

   Example with the bundled PostgreSQL Compose container name:

   ```bash
   envsubst < metabase/bootstrap/setup.sql.tmpl \
     | docker exec -i nox-pg18 psql -U postgres -d postgres
   ```
2. **Run the Metabase service** — pick one:
   - [`compose/`](compose/) for single-host Docker
   - [`kustomize/`](kustomize/) for Kubernetes
3. **Complete first-time login** — open `http://<host>:3000` and create the
   admin account; capture the credentials for Terraform.
4. **Apply declarative configuration** — from [`tf/`](tf/) (or via the
   air-gapped [`tf-runner/`](tf-runner/) image), `terraform init && apply` to
   provision data sources, cards, and dashboards on top of the running
   Metabase.

## Connectivity assumption

The Terraform module connects to the AutoNox warehouse over PostgreSQL. The
host, database name, and credentials are passed as variables — see
[`tf/README.md`](tf/README.md) for the variable list.
