-- Expected canonical state after a mock-hr import.
--
-- Run by `testkit/run.sh assert mock-hr` (and by `e2e`) against the autonox
-- database with ON_ERROR_STOP=1, so a RAISE EXCEPTION here fails the run.
--
-- These assert what the images actually produce, not what import.sh's own gates
-- report. A green import with an empty warehouse must fail here.
--
-- Source fixture is scenarios/mock-hr/source/mock_hr.sql: exactly one row,
-- user_id hr-u001 / username ada / employee_id E001. flow.yaml maps it to one
-- canonical `account` and one `identity_source_link`.

\set ON_ERROR_STOP on

DO $$
DECLARE
  n_accounts   bigint;
  n_identities bigint;
  rec          record;
BEGIN
  -- The access layer is what a customer's BI actually reads, so assert through
  -- it rather than the underlying canonical tables.
  SELECT count(*) INTO n_accounts FROM bi_views.accounts;
  IF n_accounts <> 1 THEN
    RAISE EXCEPTION 'expected 1 account, found %', n_accounts;
  END IF;

  SELECT count(*) INTO n_identities FROM bi_views.identity_accounts;
  IF n_identities <> 1 THEN
    RAISE EXCEPTION 'expected 1 identity_account link, found %', n_identities;
  END IF;

  -- Field-level check: catches a mapper regression that still produces the
  -- right row count but drops or mangles the payload.
  SELECT source, source_key, username INTO rec FROM bi_views.accounts;
  IF rec.source_key <> 'hr-u001' THEN
    RAISE EXCEPTION 'expected source_key hr-u001, found %', rec.source_key;
  END IF;
  IF rec.username <> 'ada' THEN
    RAISE EXCEPTION 'expected username ada, found %', rec.username;
  END IF;
  IF rec.source <> 'mock-hr' THEN
    RAISE EXCEPTION 'expected source mock-hr, found %', rec.source;
  END IF;

  RAISE NOTICE 'mock-hr: 1 account (%/%), 1 identity link — as expected',
    rec.source, rec.source_key;
END $$;
