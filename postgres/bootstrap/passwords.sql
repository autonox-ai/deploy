-- ============================================
-- AutoNox PostgreSQL Role Passwords
--
-- Supply passwords as psql variables:
--   psql "$PG_ADMIN_URL" \
--     -v noxop_password="$NOXOP_PASSWORD" \
--     -v noxreader_password="$NOXREADER_PASSWORD" \
--     -v bireader_password="$BIREADER_PASSWORD" \
--     -f postgres/bootstrap/passwords.sql
--
-- psql's :'var' syntax quotes the values as SQL string literals, so ordinary
-- punctuation in generated passwords is handled safely.
-- ============================================

\set ON_ERROR_STOP on

\if :{?noxop_password}
\else
  \echo 'missing required psql variable: noxop_password'
  \quit 1
\endif

\if :{?noxreader_password}
\else
  \echo 'missing required psql variable: noxreader_password'
  \quit 1
\endif

\if :{?bireader_password}
\else
  \echo 'missing required psql variable: bireader_password'
  \quit 1
\endif

ALTER ROLE noxop PASSWORD :'noxop_password';
ALTER ROLE noxreader PASSWORD :'noxreader_password';
ALTER ROLE bireader PASSWORD :'bireader_password';

\echo 'AutoNox role passwords updated.'
