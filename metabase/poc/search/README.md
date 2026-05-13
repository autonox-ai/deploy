# Search POC

Proof of concept for global IAM search over the seeded `access_layer_verify`
access-layer database.

The POC uses:

- PostgreSQL 18 in the `postgres-18-poc` container.
- `pg_textsearch` for BM25 ranking.
- `pg_trgm` for typo-tolerant fallback and token suggestions.
- A dedicated `search_poc` schema so canonical and `bi_views` data are not
  modified.

The corpus keeps access-fact documents such as `identity_entitlement`,
`effective_entitlement`, and `identity_resource` so they can be evaluated later,
but the customer-facing sample and Metabase query show only noun-like entities
by default: identities, accounts, entitlements, resources, and applications.

## Run

The source database is the seeded PG 17 container:

```bash
./poc/search/setup_pg18_poc.sh
```

Defaults:

- source container: `autonox-pg`
- target container: `postgres-18-poc`
- database: `access_layer_verify`
- pg_textsearch version: `1.2.0`

The script installs the official PG 18 `pg_textsearch` package in the target
container if needed, clones the source database into the target, installs the
POC schema, and refreshes the search corpus.

## Validate

Run sample searches:

```bash
podman exec postgres-18-poc psql -U postgres -d access_layer_verify \
  -v q="'admin'" \
  -f /tmp/search_bm25_sample.sql
```

Or run ad hoc:

```sql
\set q 'מנהל מערכת'
\i poc/search/sql/search_bm25_sample.sql
```

## Metabase

Point Terraform at the POC database:

```hcl
pg_host     = "host.docker.internal"
pg_port     = 5431
pg_database = "access_layer_verify"
pg_user     = "postgres"
pg_password = "postgresspass"
pg_ssl      = false
```

Then apply the Metabase Terraform module. The search card is named
`Global Search POC` and is also placed on the `Search POC` dashboard.

## Hebrew

PostgreSQL does not ship a Hebrew text-search configuration in this image.
The BM25 index therefore uses `text_config = 'simple'`, which preserves Hebrew
tokens without stemming. The POC adds isolated Hebrew fixture documents directly
to `search_poc.current_documents`; no canonical seeded rows are changed.
