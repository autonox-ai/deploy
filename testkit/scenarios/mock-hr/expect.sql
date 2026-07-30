-- Expected canonical state after a mock-hr import.
--
-- Run by `testkit/run.sh assert mock-hr` (and by `e2e`) against the autonox
-- database with ON_ERROR_STOP=1, so a RAISE EXCEPTION here fails the run.
--
-- These assert what the images actually produce, not what import.sh's own gates
-- report. A green import with an empty warehouse must fail here.
--
-- Source fixture is scenarios/mock-hr/source/mock_hr.sql: three people,
-- hr-u001/E001 Ada Lovelace, hr-u002/E002 Grace Hopper, hr-u003/E003 Alan
-- Turing. HR is an authoritative identity source and emits no accounts, so
-- each row becomes one identity_source_link and one banded identity.

\set ON_ERROR_STOP on

DO $$
DECLARE
  n_accounts   bigint;
  n_links      bigint;
  n_identities bigint;
  rec          record;
BEGIN
  -- HR grants no access. An account here means the source is being modelled as
  -- a target system, which would corrupt orphaned-account reporting.
  SELECT count(*) INTO n_accounts FROM bi_views.accounts;
  IF n_accounts <> 0 THEN
    RAISE EXCEPTION 'expected 0 accounts from an identity source, found %', n_accounts;
  END IF;

  SELECT count(*) INTO n_links FROM ws_${WORKSPACE_ID}.identity_source_links;
  IF n_links <> 3 THEN
    RAISE EXCEPTION 'expected 3 identity_source_links, found %', n_links;
  END IF;

  SELECT count(*) INTO n_identities FROM shared.identities WHERE is_current;
  IF n_identities <> 3 THEN
    RAISE EXCEPTION 'expected 3 identities, found %', n_identities;
  END IF;

  -- Field-level check: catches a mapper or attribute-merge regression that
  -- still produces the right row count but drops or mangles the payload.
  SELECT display_name, first_name, last_name, email, primary_hr_key, identity_kind
    INTO rec
    FROM shared.identities
   WHERE is_current AND primary_hr_key = 'E002';
  IF rec IS NULL THEN
    RAISE EXCEPTION 'no identity with primary_hr_key E002';
  END IF;
  IF rec.first_name <> 'Grace' OR rec.last_name <> 'Hopper' THEN
    RAISE EXCEPTION 'expected Grace Hopper for E002, found % %', rec.first_name, rec.last_name;
  END IF;
  IF rec.email <> 'grace@example.test' THEN
    RAISE EXCEPTION 'expected grace@example.test for E002, found %', rec.email;
  END IF;
  IF rec.identity_kind <> 'human' THEN
    RAISE EXCEPTION 'expected identity_kind human for E002, found %', rec.identity_kind;
  END IF;
  -- Merged from two source fields, so it also proves the attribute bag is a
  -- real object rather than an unparsed string.
  IF rec.display_name <> 'Grace Hopper' THEN
    RAISE EXCEPTION 'expected display_name Grace Hopper for E002, found %', rec.display_name;
  END IF;

  RAISE NOTICE 'mock-hr: 3 identities, 3 source links, 0 accounts — as expected';
END $$;
