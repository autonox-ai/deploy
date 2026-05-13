\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pg_textsearch;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS unaccent;

CREATE SCHEMA IF NOT EXISTS search_poc;

CREATE OR REPLACE FUNCTION search_poc.compact_text(VARIADIC parts text[])
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT btrim(regexp_replace(coalesce(array_to_string(parts, ' '), ''), '\s+', ' ', 'g'));
$$;

CREATE TABLE IF NOT EXISTS search_poc.current_documents (
  doc_id text PRIMARY KEY,
  doc_type text NOT NULL,
  title text NOT NULL,
  subtitle text,
  search_text text NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  identity_id text,
  account_id text,
  entitlement_id text,
  resource_id text,
  app_id text,
  source_view text NOT NULL,
  is_fixture boolean NOT NULL DEFAULT false,
  refreshed_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS search_poc.lexicon (
  term text PRIMARY KEY,
  document_count integer NOT NULL,
  refreshed_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION search_poc.refresh_current_documents()
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  document_count bigint;
BEGIN
  TRUNCATE search_poc.current_documents;
  TRUNCATE search_poc.lexicon;

  INSERT INTO search_poc.current_documents (
    doc_id, doc_type, title, subtitle, search_text, payload,
    identity_id, source_view
  )
  SELECT
    'identity:' || identity_id,
    'identity',
    coalesce(display_name, email, identity_id),
    search_poc.compact_text(email, identity_kind, status, department, job_title, org_unit_name),
    search_poc.compact_text(
      display_name, email, identity_kind, status, department, job_title,
      employment_type, org_unit_id, org_unit_name, org_unit_path, org_unit_type,
      manager_name, attributes::text
    ),
    jsonb_build_object(
      'identity_id', identity_id,
      'email', email,
      'identity_kind', identity_kind,
      'department', department,
      'org_unit_name', org_unit_name
    ),
    identity_id,
    'bi_views.active_identities'
  FROM bi_views.active_identities;

  INSERT INTO search_poc.current_documents (
    doc_id, doc_type, title, subtitle, search_text, payload,
    identity_id, account_id, source_view
  )
  SELECT
    'account:' || account_id,
    'account',
    coalesce(username, account_id),
    search_poc.compact_text(source, status, source_key),
    search_poc.compact_text(username, account_id, source, source_key, status, attributes::text),
    jsonb_build_object(
      'account_id', account_id,
      'identity_id', identity_id,
      'username', username,
      'source', source,
      'status', status
    ),
    identity_id,
    account_id,
    'bi_views.accounts'
  FROM bi_views.accounts;

  INSERT INTO search_poc.current_documents (
    doc_id, doc_type, title, subtitle, search_text, payload,
    entitlement_id, source_view
  )
  SELECT
    'entitlement:' || entitlement_id,
    'entitlement',
    coalesce(display_name, name, entitlement_id),
    search_poc.compact_text(source, kind, source_key),
    search_poc.compact_text(name, display_name, description, kind, source, source_key, attributes::text),
    jsonb_build_object(
      'entitlement_id', entitlement_id,
      'name', name,
      'display_name', display_name,
      'source', source,
      'kind', kind
    ),
    entitlement_id,
    'bi_views.entitlements'
  FROM bi_views.entitlements;

  INSERT INTO search_poc.current_documents (
    doc_id, doc_type, title, subtitle, search_text, payload,
    resource_id, source_view
  )
  SELECT
    'resource:' || resource_id,
    'resource',
    coalesce(name, resource_id),
    search_poc.compact_text(source, resource_type, source_key),
    search_poc.compact_text(name, description, resource_type, source, source_key, attributes::text),
    jsonb_build_object(
      'resource_id', resource_id,
      'name', name,
      'source', source,
      'resource_type', resource_type
    ),
    resource_id,
    'bi_views.resources'
  FROM bi_views.resources;

  INSERT INTO search_poc.current_documents (
    doc_id, doc_type, title, subtitle, search_text, payload,
    app_id, source_view
  )
  SELECT
    'application:' || app_id,
    'application',
    coalesce(display_name, app_name, app_id),
    search_poc.compact_text(discovery_method, entitlement_count::text, assigned_user_count::text),
    search_poc.compact_text(app_name, display_name, discovery_method, entitlement_count::text, assigned_user_count::text),
    jsonb_build_object(
      'app_id', app_id,
      'app_name', app_name,
      'display_name', display_name,
      'discovery_method', discovery_method,
      'entitlement_count', entitlement_count,
      'assigned_user_count', assigned_user_count
    ),
    app_id,
    'bi_views.applications'
  FROM bi_views.applications;

  INSERT INTO search_poc.current_documents (
    doc_id, doc_type, title, subtitle, search_text, payload,
    identity_id, account_id, entitlement_id, source_view
  )
  SELECT
    'identity_entitlement:' || md5(search_poc.compact_text(identity_id, entitlement_id, assigned_via_account, assigned_via_source)),
    'identity_entitlement',
    search_poc.compact_text(display_name, entitlement_name),
    search_poc.compact_text(email, app_name, entitlement_source, assigned_via_account),
    search_poc.compact_text(
      display_name, email, entitlement_name, entitlement_type, entitlement_source,
      app_name, app_display_name, assigned_via_account, assigned_via_source,
      entitlement_attributes::text, membership_attributes::text
    ),
    jsonb_build_object(
      'identity_id', identity_id,
      'email', email,
      'entitlement_id', entitlement_id,
      'entitlement_name', entitlement_name,
      'app_name', app_name,
      'assigned_via_account', assigned_via_account,
      'assigned_via_source', assigned_via_source
    ),
    identity_id,
    assigned_via_account,
    entitlement_id,
    'bi_views.identity_entitlements'
  FROM bi_views.identity_entitlements;

  INSERT INTO search_poc.current_documents (
    doc_id, doc_type, title, subtitle, search_text, payload,
    identity_id, account_id, entitlement_id, source_view
  )
  SELECT
    'effective_entitlement:' || md5(search_poc.compact_text(identity_id, entitlement_id, assigned_via_account, assigned_via_source, depth::text, assignment_type)),
    'effective_entitlement',
    search_poc.compact_text(display_name, entitlement_name),
    search_poc.compact_text(email, assignment_type, entitlement_source, assigned_via_account),
    search_poc.compact_text(
      display_name, email, entitlement_name, entitlement_type, entitlement_source,
      assignment_type, depth::text, assigned_via_account, assigned_via_source
    ),
    jsonb_build_object(
      'identity_id', identity_id,
      'email', email,
      'entitlement_id', entitlement_id,
      'entitlement_name', entitlement_name,
      'assignment_type', assignment_type,
      'depth', depth,
      'assigned_via_account', assigned_via_account,
      'assigned_via_source', assigned_via_source
    ),
    identity_id,
    assigned_via_account,
    entitlement_id,
    'bi_views.identity_effective_entitlements'
  FROM bi_views.identity_effective_entitlements;

  INSERT INTO search_poc.current_documents (
    doc_id, doc_type, title, subtitle, search_text, payload,
    identity_id, account_id, entitlement_id, resource_id, source_view
  )
  SELECT
    'identity_resource:' || md5(search_poc.compact_text(identity_id, resource_id, entitlement_id, assigned_via_account, assigned_via_source)),
    'identity_resource',
    search_poc.compact_text(display_name, resource_name),
    search_poc.compact_text(email, app_name, resource_source, granted_via_entitlement),
    search_poc.compact_text(
      display_name, email, resource_name, resource_type, resource_source,
      granted_via_entitlement, entitlement_type, app_name, app_display_name,
      assigned_via_account, assigned_via_source, resource_attributes::text,
      membership_attributes::text
    ),
    jsonb_build_object(
      'identity_id', identity_id,
      'email', email,
      'resource_id', resource_id,
      'resource_name', resource_name,
      'entitlement_id', entitlement_id,
      'granted_via_entitlement', granted_via_entitlement,
      'app_name', app_name,
      'assigned_via_account', assigned_via_account,
      'assigned_via_source', assigned_via_source
    ),
    identity_id,
    assigned_via_account,
    entitlement_id,
    resource_id,
    'bi_views.identity_resource_membership'
  FROM bi_views.identity_resource_membership;

  INSERT INTO search_poc.current_documents (
    doc_id, doc_type, title, subtitle, search_text, payload,
    identity_id, entitlement_id, resource_id, source_view, is_fixture
  )
  VALUES
    (
      'fixture:hebrew:identity:yael-levi',
      'identity',
      'יעל לוי',
      'מנהלת מערכת | yael.levi@example.co.il',
      search_poc.compact_text('יעל לוי', 'מנהלת מערכת', 'צוות אבטחה', 'admin security operations', 'yael.levi@example.co.il'),
      '{"fixture":"hebrew_poc","language":"he","note":"Synthetic Hebrew identity fixture"}',
      'fixture-hebrew-identity-yael-levi',
      null,
      null,
      'search_poc.hebrew_fixture',
      true
    ),
    (
      'fixture:hebrew:entitlement:system-admins',
      'entitlement',
      'קבוצת מנהלי מערכת',
      'הרשאת production admin',
      search_poc.compact_text('קבוצת מנהלי מערכת', 'הרשאת ייצור', 'production admin group', 'privileged entitlement'),
      '{"fixture":"hebrew_poc","language":"he","note":"Synthetic Hebrew entitlement fixture"}',
      null,
      'fixture-hebrew-entitlement-system-admins',
      null,
      'search_poc.hebrew_fixture',
      true
    ),
    (
      'fixture:hebrew:resource:customer-db',
      'resource',
      'מאגר לקוחות',
      'בסיס נתוני לקוחות | customer database',
      search_poc.compact_text('מאגר לקוחות', 'בסיס נתוני לקוחות', 'customer database', 'sensitive resource'),
      '{"fixture":"hebrew_poc","language":"he","note":"Synthetic Hebrew resource fixture"}',
      null,
      null,
      'fixture-hebrew-resource-customer-db',
      'search_poc.hebrew_fixture',
      true
    );

  INSERT INTO search_poc.lexicon (term, document_count)
  SELECT term, count(DISTINCT doc_id)::integer
  FROM search_poc.current_documents d
  CROSS JOIN LATERAL regexp_split_to_table(lower(d.search_text), '[^[:alnum:]א-ת]+') AS term
  WHERE length(term) >= 2
  GROUP BY term;

  SELECT count(*) INTO document_count FROM search_poc.current_documents;
  RETURN document_count;
END;
$$;

CREATE INDEX IF NOT EXISTS search_poc_current_documents_bm25_simple_idx
ON search_poc.current_documents
USING bm25 (search_text)
WITH (text_config = 'simple');

CREATE INDEX IF NOT EXISTS search_poc_current_documents_trgm_idx
ON search_poc.current_documents
USING gin (search_text gin_trgm_ops);

CREATE INDEX IF NOT EXISTS search_poc_current_documents_title_trgm_idx
ON search_poc.current_documents
USING gin (title gin_trgm_ops);

CREATE INDEX IF NOT EXISTS search_poc_lexicon_term_trgm_idx
ON search_poc.lexicon
USING gin (term gin_trgm_ops);
