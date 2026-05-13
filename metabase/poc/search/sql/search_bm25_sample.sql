\set ON_ERROR_STOP on

WITH params AS (
  SELECT nullif(btrim(:q::text), '') AS q
),
visible_documents AS (
  SELECT *
  FROM search_poc.current_documents
  WHERE doc_type IN ('identity', 'account', 'entitlement', 'resource', 'application')
),
query_terms AS (
  SELECT token_position, token
  FROM params p
  CROSS JOIN LATERAL regexp_split_to_table(lower(p.q), '[^[:alnum:]א-ת]+') WITH ORDINALITY AS terms(token, token_position)
  WHERE p.q IS NOT NULL
    AND length(token) >= 2
),
corrected_query AS (
  SELECT
    nullif(string_agg(coalesce(best.term, qt.token), ' ' ORDER BY qt.token_position), '') AS q,
    string_agg(best.term, ', ' ORDER BY qt.token_position) FILTER (WHERE best.term IS NOT NULL) AS suggested_terms
  FROM query_terms qt
  LEFT JOIN LATERAL (
    SELECT l.term
    FROM search_poc.lexicon l
    WHERE l.term % qt.token
       OR similarity(l.term, qt.token) >= 0.2
    ORDER BY similarity(l.term, qt.token) DESC, l.document_count DESC, l.term
    LIMIT 1
  ) best ON true
),
bm25 AS (
  SELECT
    d.doc_id,
    d.doc_type,
    d.title,
    d.subtitle,
    d.payload,
    d.identity_id,
    d.account_id,
    d.entitlement_id,
    d.resource_id,
    d.app_id,
    d.search_text <@> to_bm25query(p.q, 'search_poc.search_poc_current_documents_bm25_simple_idx') AS raw_bm25_score,
    null::real AS trigram_score,
    'bm25'::text AS match_mode
  FROM visible_documents d
  CROSS JOIN params p
  WHERE p.q IS NOT NULL
  ORDER BY d.search_text <@> to_bm25query(p.q, 'search_poc.search_poc_current_documents_bm25_simple_idx')
  LIMIT 25
),
corrected_bm25 AS (
  SELECT
    d.doc_id,
    d.doc_type,
    d.title,
    d.subtitle,
    d.payload,
    d.identity_id,
    d.account_id,
    d.entitlement_id,
    d.resource_id,
    d.app_id,
    d.search_text <@> to_bm25query(cq.q, 'search_poc.search_poc_current_documents_bm25_simple_idx') AS raw_bm25_score,
    null::real AS trigram_score,
    'corrected_bm25'::text AS match_mode
  FROM visible_documents d
  CROSS JOIN params p
  CROSS JOIN corrected_query cq
  WHERE p.q IS NOT NULL
    AND cq.q IS NOT NULL
    AND cq.q <> lower(p.q)
  ORDER BY d.search_text <@> to_bm25query(cq.q, 'search_poc.search_poc_current_documents_bm25_simple_idx')
  LIMIT 25
),
trigram AS (
  SELECT
    d.doc_id,
    d.doc_type,
    d.title,
    d.subtitle,
    d.payload,
    d.identity_id,
    d.account_id,
    d.entitlement_id,
    d.resource_id,
    d.app_id,
    null::double precision AS raw_bm25_score,
    greatest(
      similarity(d.search_text, p.q),
      similarity(d.title, p.q),
      similarity(coalesce(d.subtitle, ''), p.q)
    ) AS trigram_score,
    'trigram'::text AS match_mode
  FROM visible_documents d
  CROSS JOIN params p
  WHERE p.q IS NOT NULL
    AND (
      d.search_text % p.q
      OR d.title % p.q
      OR coalesce(d.subtitle, '') % p.q
    )
  ORDER BY greatest(
    similarity(d.search_text, p.q),
    similarity(d.title, p.q),
    similarity(coalesce(d.subtitle, ''), p.q)
  ) DESC
  LIMIT 25
),
combined AS (
  SELECT * FROM bm25 WHERE raw_bm25_score < 0
  UNION ALL
  SELECT * FROM corrected_bm25 WHERE raw_bm25_score < 0
  UNION ALL
  SELECT * FROM trigram
),
deduped AS (
  SELECT DISTINCT ON (doc_id)
    doc_id,
    doc_type,
    title,
    subtitle,
    match_mode,
    raw_bm25_score,
    trigram_score,
    CASE
      WHEN raw_bm25_score IS NOT NULL THEN -raw_bm25_score
      ELSE trigram_score::double precision
    END AS relevance,
    identity_id,
    account_id,
    entitlement_id,
    resource_id,
    app_id,
    payload
  FROM combined
  ORDER BY doc_id, raw_bm25_score NULLS LAST, trigram_score DESC NULLS LAST
)
SELECT
  row_number() OVER (ORDER BY d.relevance DESC, d.title) AS rank,
  d.match_mode,
  round(d.relevance::numeric, 6) AS relevance,
  d.doc_type,
  d.title,
  d.subtitle,
  d.identity_id,
  d.account_id,
  d.entitlement_id,
  d.resource_id,
  d.app_id,
  (SELECT suggested_terms FROM corrected_query) AS suggested_terms,
  d.payload
FROM deduped d
ORDER BY d.relevance DESC, d.title
LIMIT 25;
