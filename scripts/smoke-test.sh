#!/usr/bin/env bash
# Smoke-Test: startet den Stack mit der Selbsttest-Pipeline und prueft,
# dass Daten in Postgres ankommen, Partitionen existieren und die
# Aggregation laeuft.
#
#   cp .env.example .env && ./scripts/smoke-test.sh
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || { echo "Bitte zuerst: cp .env.example .env"; exit 1; }

export PIPELINE=/etc/opairs/pipelines/selftest.yaml
docker compose up -d --build

echo "Warte 20 s auf Testdaten ..."
sleep 20

q() { docker compose exec -T db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "$1"' _ "$1"; }

rows=$(q "SELECT count(*) FROM opairs.machine_data")
parts=$(q "SELECT count(*) FROM pg_inherits i JOIN pg_class p ON p.oid=i.inhparent WHERE p.relname='machine_data'")
q "SELECT opairs.run_maintenance()" >/dev/null
agg=$(q "SELECT count(*) FROM opairs.machine_data_1min")

echo "Rohdaten-Zeilen: $rows | Partitionen: $parts | Minutenwerte: $agg"

fail=0
[ "$rows"  -gt 0 ] || { echo "FEHLER: keine Rohdaten angekommen"; fail=1; }
[ "$parts" -ge 8 ] || { echo "FEHLER: zu wenige Partitionen"; fail=1; }
[ "$agg"   -gt 0 ] || { echo "FEHLER: keine Minutenwerte berechnet"; fail=1; }

[ "$fail" -eq 0 ] && echo "OK" || { docker compose logs --tail=50 connector; exit 1; }
