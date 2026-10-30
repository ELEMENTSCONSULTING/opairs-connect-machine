#!/bin/bash
# OPAIRS Connect: Rollen fuer den Connector (nur schreiben) und fuer Superset (nur lesen).
# Wird beim ersten Start der Datenbank vom Postgres-Image ausgefuehrt.
# Passwoerter kommen aus den Umgebungsvariablen OPAIRS_WRITER_PASSWORD und
# OPAIRS_READER_PASSWORD (siehe .env.example).
set -euo pipefail

: "${OPAIRS_WRITER_PASSWORD:?OPAIRS_WRITER_PASSWORD fehlt}"
: "${OPAIRS_READER_PASSWORD:?OPAIRS_READER_PASSWORD fehlt}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
     -v writer_pw="$OPAIRS_WRITER_PASSWORD" \
     -v reader_pw="$OPAIRS_READER_PASSWORD" <<'EOSQL'
SELECT format('CREATE ROLE opairs_writer LOGIN PASSWORD %L', :'writer_pw')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'opairs_writer') \gexec
SELECT format('CREATE ROLE opairs_reader LOGIN PASSWORD %L', :'reader_pw')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'opairs_reader') \gexec

GRANT USAGE ON SCHEMA opairs TO opairs_writer, opairs_reader;

-- Connector: darf nur in die Rohdaten-Tabelle schreiben (Partitionen erbt er darueber).
GRANT INSERT ON opairs.machine_data TO opairs_writer;

-- Superset: darf alles im Schema lesen, auch kuenftige Partitionen.
GRANT SELECT ON ALL TABLES IN SCHEMA opairs TO opairs_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA opairs GRANT SELECT ON TABLES TO opairs_reader;
EOSQL
