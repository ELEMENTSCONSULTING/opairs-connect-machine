#!/usr/bin/env bash
# SQL-Regressionstests gegen die laufende Compose-Datenbank.
# Die Tests laufen in einer Transaktion mit ROLLBACK, es bleiben keine Daten zurueck.
set -euo pipefail
cd "$(dirname "$0")/.."

docker compose exec -T db sh -c \
  'psql -q -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -f /docker-entrypoint-initdb.d/tests/maintenance_test.sql' \
  >/dev/null
echo "SQL-Tests: OK"
