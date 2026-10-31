#!/usr/bin/env bash
# Demo-Daten fuer Superset.
#
#   ./scripts/demo.sh backfill   7 Tage Historie fuer 9 Demo-Anlagen erzeugen
#   ./scripts/demo.sh live       Connector auf die Demo-Pipeline umstellen (laeuft weiter)
#   ./scripts/demo.sh remove     alle Demo-Daten loeschen
#
# "live" aendert PIPELINE in .env. Zurueck auf eine echte Quelle: PIPELINE in
# .env setzen und "docker compose up -d && docker compose restart connector".
set -euo pipefail
cd "$(dirname "$0")/.."

psql_file() {
    docker compose exec -T opairs-connect-db sh -c \
      'psql -q -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -P pager=off -f "$1"' _ "$1"
}

case "${1:-}" in
    backfill)
        echo "Erzeuge 7 Tage Demo-Daten (dauert etwa eine Minute) ..."
        psql_file /docker-entrypoint-initdb.d/demo/demo_backfill.sql
        ;;
    live)
        [ -f .env ] || { echo "Bitte zuerst: cp .env.example .env"; exit 1; }
        if grep -q '^PIPELINE=' .env; then
            sed -i 's#^PIPELINE=.*#PIPELINE=/etc/opairs/pipelines/demo-anlage.yaml#' .env
        else
            echo 'PIPELINE=/etc/opairs/pipelines/demo-anlage.yaml' >> .env
        fi
        docker compose up -d
        docker compose restart connector
        echo "Demo-Pipeline laeuft (9 Anlagen, Takt 10 s)."
        ;;
    remove)
        psql_file /docker-entrypoint-initdb.d/demo/demo_remove.sql
        echo "Demo-Daten entfernt."
        ;;
    *)
        sed -n '2,9p' "$0"; exit 2
        ;;
esac
