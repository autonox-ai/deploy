-- ============================================
-- AutoNox PostgreSQL Bootstrap
-- Aligned to AutoNox — PostgreSQL Architecture & Setup
-- Run with:
--   docker exec -i nox-pg18 psql -U postgres -d postgres < postgres/bootstrap/setup.sql
--
-- This script creates login roles without hardcoded passwords. After applying
-- it, set role passwords with postgres/bootstrap/passwords.sql.
-- ============================================

-- ------------------------------------------------
-- DATABASE
-- ------------------------------------------------

SELECT 'CREATE DATABASE autonox'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'autonox')
\gexec

ALTER DATABASE autonox OWNER TO postgres;

-- ------------------------------------------------
-- ROLES
-- ------------------------------------------------

DO
$$
BEGIN
   IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'noxop') THEN
      CREATE ROLE noxop LOGIN;
   END IF;

   IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'noxreader') THEN
      CREATE ROLE noxreader LOGIN;
   END IF;

   IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'bireader') THEN
      CREATE ROLE bireader LOGIN;
   END IF;
END
$$;

\connect autonox

-- ------------------------------------------------
-- EXTENSIONS
-- ------------------------------------------------

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS vector;

-- ------------------------------------------------
-- CORE SCHEMAS
-- ------------------------------------------------

CREATE SCHEMA IF NOT EXISTS warehouse;
CREATE SCHEMA IF NOT EXISTS reconciliation;
CREATE SCHEMA IF NOT EXISTS shared;
CREATE SCHEMA IF NOT EXISTS bi_views;
CREATE SCHEMA IF NOT EXISTS analytics;
CREATE SCHEMA IF NOT EXISTS audit;

ALTER SCHEMA warehouse OWNER TO postgres;
ALTER SCHEMA reconciliation OWNER TO postgres;
ALTER SCHEMA shared OWNER TO postgres;
ALTER SCHEMA bi_views OWNER TO postgres;
ALTER SCHEMA analytics OWNER TO postgres;
ALTER SCHEMA audit OWNER TO postgres;

-- ------------------------------------------------
-- SCHEMA PRIVILEGES
-- ------------------------------------------------

-- noxop: full access to all pipeline schemas
GRANT USAGE, CREATE ON SCHEMA warehouse TO noxop;
GRANT USAGE, CREATE ON SCHEMA reconciliation TO noxop;
GRANT USAGE, CREATE ON SCHEMA shared TO noxop;
GRANT USAGE, CREATE ON SCHEMA bi_views TO noxop;
GRANT USAGE, CREATE ON SCHEMA analytics TO noxop;
GRANT USAGE, CREATE ON SCHEMA audit TO noxop;

-- noxreader: read access to all core schemas
GRANT USAGE ON SCHEMA warehouse, reconciliation, shared, bi_views, analytics, audit TO noxreader;

-- bireader: read-only on bi only
GRANT USAGE ON SCHEMA bi_views, analytics, audit TO bireader;

-- ------------------------------------------------
-- EXISTING OBJECT PRIVILEGES
-- ------------------------------------------------

GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA warehouse TO noxop;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA warehouse TO noxop;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA warehouse TO noxop;

GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA reconciliation TO noxop;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA reconciliation TO noxop;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA reconciliation TO noxop;

GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA shared TO noxop;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA shared TO noxop;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA shared TO noxop;

GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA bi_views TO noxop;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA bi_views TO noxop;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA bi_views TO noxop;

GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA analytics TO noxop;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA analytics TO noxop;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA analytics TO noxop;

GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA audit TO noxop;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA audit TO noxop;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA audit TO noxop;

GRANT SELECT ON ALL TABLES IN SCHEMA warehouse TO noxreader;
GRANT SELECT ON ALL TABLES IN SCHEMA reconciliation TO noxreader;
GRANT SELECT ON ALL TABLES IN SCHEMA shared TO noxreader;
GRANT SELECT ON ALL TABLES IN SCHEMA bi_views TO noxreader;
GRANT SELECT ON ALL TABLES IN SCHEMA analytics TO noxreader;
GRANT SELECT ON ALL TABLES IN SCHEMA audit TO noxreader;

GRANT SELECT ON ALL TABLES IN SCHEMA bi_views TO bireader;
GRANT SELECT ON ALL TABLES IN SCHEMA analytics TO bireader;
GRANT SELECT ON ALL TABLES IN SCHEMA audit TO bireader;

-- ------------------------------------------------
-- DEFAULT PRIVILEGES FOR FUTURE OBJECTS
-- NOTE: applies to objects created by noxop (the migration runner)
-- ------------------------------------------------

ALTER DEFAULT PRIVILEGES FOR ROLE noxop IN SCHEMA warehouse
   GRANT ALL ON TABLES TO noxop;
ALTER DEFAULT PRIVILEGES FOR ROLE noxop IN SCHEMA warehouse
   GRANT ALL ON SEQUENCES TO noxop;
ALTER DEFAULT PRIVILEGES FOR ROLE noxop IN SCHEMA warehouse
   GRANT ALL ON FUNCTIONS TO noxop;
ALTER DEFAULT PRIVILEGES FOR ROLE noxop IN SCHEMA warehouse
   GRANT SELECT ON TABLES TO noxreader;

ALTER DEFAULT PRIVILEGES FOR ROLE noxop IN SCHEMA reconciliation
   GRANT ALL ON TABLES TO noxop;
ALTER DEFAULT PRIVILEGES FOR ROLE noxop IN SCHEMA reconciliation
   GRANT ALL ON SEQUENCES TO noxop;
ALTER DEFAULT PRIVILEGES FOR ROLE noxop IN SCHEMA reconciliation
   GRANT ALL ON FUNCTIONS TO noxop;
ALTER DEFAULT PRIVILEGES FOR ROLE noxop IN SCHEMA reconciliation
   GRANT SELECT ON TABLES TO noxreader;

ALTER DEFAULT PRIVILEGES FOR ROLE noxop IN SCHEMA shared
   GRANT ALL ON TABLES TO noxop;
ALTER DEFAULT PRIVILEGES FOR ROLE noxop IN SCHEMA shared
   GRANT ALL ON SEQUENCES TO noxop;
ALTER DEFAULT PRIVILEGES FOR ROLE noxop IN SCHEMA shared
   GRANT ALL ON FUNCTIONS TO noxop;
ALTER DEFAULT PRIVILEGES FOR ROLE noxop IN SCHEMA shared
   GRANT SELECT ON TABLES TO noxreader;

ALTER DEFAULT PRIVILEGES FOR ROLE noxop IN SCHEMA bi_views
   GRANT ALL ON TABLES TO noxop;
ALTER DEFAULT PRIVILEGES FOR ROLE noxop IN SCHEMA bi_views
   GRANT ALL ON SEQUENCES TO noxop;
ALTER DEFAULT PRIVILEGES FOR ROLE noxop IN SCHEMA bi_views
   GRANT ALL ON FUNCTIONS TO noxop;
ALTER DEFAULT PRIVILEGES FOR ROLE noxop IN SCHEMA bi_views
   GRANT SELECT ON TABLES TO noxreader;
ALTER DEFAULT PRIVILEGES FOR ROLE noxop IN SCHEMA bi_views
   GRANT SELECT ON TABLES TO bireader;

ALTER DEFAULT PRIVILEGES FOR ROLE noxop IN SCHEMA analytics
   GRANT ALL ON TABLES TO noxop;
ALTER DEFAULT PRIVILEGES FOR ROLE noxop IN SCHEMA analytics
   GRANT ALL ON SEQUENCES TO noxop;
ALTER DEFAULT PRIVILEGES FOR ROLE noxop IN SCHEMA analytics
   GRANT ALL ON FUNCTIONS TO noxop;
ALTER DEFAULT PRIVILEGES FOR ROLE noxop IN SCHEMA analytics
   GRANT SELECT ON TABLES TO noxreader;
ALTER DEFAULT PRIVILEGES FOR ROLE noxop IN SCHEMA analytics
   GRANT SELECT ON TABLES TO bireader;

ALTER DEFAULT PRIVILEGES FOR ROLE noxop IN SCHEMA audit
   GRANT ALL ON TABLES TO noxop;
ALTER DEFAULT PRIVILEGES FOR ROLE noxop IN SCHEMA audit
   GRANT ALL ON SEQUENCES TO noxop;
ALTER DEFAULT PRIVILEGES FOR ROLE noxop IN SCHEMA audit
   GRANT ALL ON FUNCTIONS TO noxop;
ALTER DEFAULT PRIVILEGES FOR ROLE noxop IN SCHEMA audit
   GRANT SELECT ON TABLES TO noxreader;
ALTER DEFAULT PRIVILEGES FOR ROLE noxop IN SCHEMA audit
   GRANT SELECT ON TABLES TO bireader;

-- ------------------------------------------------
-- SEARCH PATH DEFAULTS
-- ------------------------------------------------

ALTER ROLE noxop IN DATABASE autonox SET search_path = public;

-- ------------------------------------------------
-- NOTES
-- ------------------------------------------------
-- 1. Workspace schemas (ws_prod, ws_dev, etc.) are NOT created here.
--    They are provisioned dynamically — see postgres/bootstrap/ws_setup.sql.tmpl
-- 2. Module tables are created by each module's migrate command,
--    run as noxop after this script completes.
-- 3. Role passwords are not set here. Apply postgres/bootstrap/passwords.sql
--    with customer-managed secret values.

\echo 'AutoNox bootstrap complete.'
