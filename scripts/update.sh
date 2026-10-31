#!/usr/bin/env bash
# Update: neuen Stand holen, Images bauen, Dienste neu starten.
#
#   ./scripts/update.sh
#
# Pipelines (./pipelines) und SQL (./sql) sind als Ordner eingebunden.
# Compose erkennt deren Aenderungen nicht und wuerde die Container einfach
# weiterlaufen lassen. Deshalb werden connector und maintenance immer neu
# gestartet; maintenance spielt dabei das Schema ein.
set -euo pipefail
cd "$(dirname "$0")/.."

git pull --ff-only
docker compose up -d --build --remove-orphans
docker compose restart connector maintenance
docker compose ps
