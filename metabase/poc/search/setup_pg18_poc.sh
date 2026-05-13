#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

SOURCE_CONTAINER="${SOURCE_CONTAINER:-autonox-pg}"
TARGET_CONTAINER="${TARGET_CONTAINER:-postgres-18-poc}"
SOURCE_DB="${SOURCE_DB:-access_layer_verify}"
TARGET_DB="${TARGET_DB:-access_layer_verify}"
PG_TEXTSEARCH_VERSION="${PG_TEXTSEARCH_VERSION:-1.2.0}"
PG_TEXTSEARCH_DEB="pg-textsearch-postgresql-18_${PG_TEXTSEARCH_VERSION}-1_amd64.deb"
PG_TEXTSEARCH_ZIP="pg-textsearch-v${PG_TEXTSEARCH_VERSION}-pg18-amd64.zip"
WORK_DIR="${WORK_DIR:-/tmp/autonox-search-poc}"

need_container() {
  local name="$1"
  podman inspect "$name" >/dev/null
}

target_psql() {
  podman exec "$TARGET_CONTAINER" psql -U postgres -d "$TARGET_DB" "$@"
}

postgres_setting() {
  podman exec "$TARGET_CONTAINER" psql -U postgres -d postgres -X -A -t -c "$1"
}

install_pg_textsearch_if_needed() {
  local available
  available="$(postgres_setting "select coalesce((select default_version from pg_available_extensions where name = 'pg_textsearch'), '')")"
  if [[ -z "$available" ]]; then
    mkdir -p "$WORK_DIR"
    if [[ ! -f "$WORK_DIR/$PG_TEXTSEARCH_ZIP" ]]; then
      curl -fsSL \
        -o "$WORK_DIR/$PG_TEXTSEARCH_ZIP" \
        "https://github.com/timescale/pg_textsearch/releases/download/v${PG_TEXTSEARCH_VERSION}/${PG_TEXTSEARCH_ZIP}"
    fi
    unzip -o "$WORK_DIR/$PG_TEXTSEARCH_ZIP" -d "$WORK_DIR" >/dev/null
    podman cp "$WORK_DIR/$PG_TEXTSEARCH_DEB" "$TARGET_CONTAINER:/tmp/$PG_TEXTSEARCH_DEB"
    podman exec "$TARGET_CONTAINER" dpkg -i "/tmp/$PG_TEXTSEARCH_DEB"
  fi

  local preload
  preload="$(postgres_setting "select current_setting('shared_preload_libraries', true)")"
  if [[ "$preload" != *pg_textsearch* ]]; then
    local new_preload="pg_textsearch"
    if [[ -n "$preload" ]]; then
      new_preload="${preload},pg_textsearch"
    fi
    podman exec "$TARGET_CONTAINER" bash -lc \
      "printf '\nshared_preload_libraries = '\''${new_preload}'\''\n' >> \"\$PGDATA/postgresql.conf\""
    podman restart "$TARGET_CONTAINER" >/dev/null
  fi
}

clone_database() {
  podman exec "$SOURCE_CONTAINER" pg_dump -U postgres -d "$SOURCE_DB" -Fc -f "/tmp/$SOURCE_DB.dump"
  podman cp "$SOURCE_CONTAINER:/tmp/$SOURCE_DB.dump" "$WORK_DIR/$SOURCE_DB.dump"
  podman cp "$WORK_DIR/$SOURCE_DB.dump" "$TARGET_CONTAINER:/tmp/$SOURCE_DB.dump"
  podman exec "$TARGET_CONTAINER" dropdb -U postgres --if-exists "$TARGET_DB"
  podman exec "$TARGET_CONTAINER" createdb -U postgres "$TARGET_DB"
  podman exec "$TARGET_CONTAINER" pg_restore -U postgres -d "$TARGET_DB" --no-owner "/tmp/$SOURCE_DB.dump"
}

install_search_poc() {
  podman cp "$SCRIPT_DIR/sql/001_install_search_poc.sql" "$TARGET_CONTAINER:/tmp/001_install_search_poc.sql"
  podman cp "$SCRIPT_DIR/sql/002_refresh_search_poc.sql" "$TARGET_CONTAINER:/tmp/002_refresh_search_poc.sql"
  podman cp "$SCRIPT_DIR/sql/search_bm25_sample.sql" "$TARGET_CONTAINER:/tmp/search_bm25_sample.sql"
  target_psql -v ON_ERROR_STOP=1 -f /tmp/001_install_search_poc.sql
  target_psql -v ON_ERROR_STOP=1 -f /tmp/002_refresh_search_poc.sql
}

verify_search_poc() {
  target_psql -v ON_ERROR_STOP=1 -X -P pager=off -c "
    select current_setting('shared_preload_libraries', true) as shared_preload_libraries;
    select extname, extversion from pg_extension where extname in ('pg_textsearch', 'pg_trgm', 'unaccent') order by extname;
    select doc_type, count(*) from search_poc.current_documents group by doc_type order by doc_type;
    select count(*) filter (where is_fixture) as hebrew_fixture_docs, count(*) as total_docs from search_poc.current_documents;
  "
}

main() {
  mkdir -p "$WORK_DIR"
  need_container "$SOURCE_CONTAINER"
  need_container "$TARGET_CONTAINER"
  install_pg_textsearch_if_needed
  clone_database
  install_search_poc
  verify_search_poc
}

main "$@"
