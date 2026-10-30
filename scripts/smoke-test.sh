#!/usr/bin/env bash
# Smoke-Test: startet den Stack mit der Selbsttest-Pipeline und prueft,
# dass Daten in Postgres ankommen, Partitionen existieren und die
# Aggregation laeuft. Danach laufen die SQL-Regressionstests.
#
#   cp .env.example .env && ./scripts/smoke-test.sh
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || { echo "Bitte zuerst: cp .env.example .env"; exit 1; }

export PIPELINE=/etc/opairs/pipelines/selftest.yaml
docker compose up -d --build

q() { docker compose exec -T db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "$1"' _ "$1"; }

fail() {
    echo "FEHLER: $1"
    docker compose ps
    docker compose logs --no-color --tail=80 connector maintenance db
    exit 1
}

echo "Warte auf Testdaten (max. 120 s) ..."
rows=0
for _ in $(seq 1 60); do
    rows=$(q "SELECT count(*) FROM opairs.machine_data" 2>/dev/null || echo 0)
    [ "${rows:-0}" -gt 0 ] && break
    sleep 2
done
[ "${rows:-0}" -gt 0 ] || fail "keine Rohdaten angekommen"

parts=$(q "SELECT count(*) FROM pg_inherits i JOIN pg_class p ON p.oid=i.inhparent WHERE p.relname='machine_data'")
q "SELECT opairs.run_maintenance()" >/dev/null || fail "run_maintenance fehlgeschlagen"
agg=$(q "SELECT count(*) FROM opairs.machine_data_1min")
tags=$(q "SELECT count(DISTINCT tag) FROM opairs.machine_data WHERE machine='selftest'")

echo "Rohdaten-Zeilen: $rows | Partitionen: $parts | Minutenwerte: $agg | Tags: $tags"

[ "$parts" -ge 9 ] || fail "zu wenige Partitionen ($parts)"
[ "$agg"   -gt 0 ] || fail "keine Minutenwerte berechnet"
[ "$tags"  -ge 2 ] || fail "Selbsttest liefert nicht die erwarteten Tags ($tags)"

./scripts/test-sql.sh || fail "SQL-Regressionstests fehlgeschlagen"
echo "Smoke-Test: OK"
