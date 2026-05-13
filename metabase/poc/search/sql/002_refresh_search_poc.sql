\set ON_ERROR_STOP on

SELECT search_poc.refresh_current_documents() AS refreshed_documents;

SELECT doc_type, count(*) AS documents
FROM search_poc.current_documents
GROUP BY doc_type
ORDER BY doc_type;

SELECT count(*) AS hebrew_fixture_documents
FROM search_poc.current_documents
WHERE is_fixture;
