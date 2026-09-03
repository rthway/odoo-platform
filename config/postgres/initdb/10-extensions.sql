-- =========================================================================
-- Run ONCE, by the postgres image, only on an empty data directory.
-- Never runs against an existing database, so it is safe on redeploy.
-- =========================================================================

-- pg_stat_statements: per-query execution statistics. Grafana's PostgreSQL
-- dashboard and the "which query is slow" runbook both depend on this.
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Odoo requires unaccent for accent-insensitive search, and pg_trgm for the
-- trigram indexes behind fuzzy name lookup.
CREATE EXTENSION IF NOT EXISTS unaccent;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- WAL archive destination referenced by archive_command in postgresql.conf.
-- Created here so archiving does not fail silently on a fresh cluster.
\! mkdir -p /var/lib/postgresql/wal_archive
