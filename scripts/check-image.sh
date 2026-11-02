#!/usr/bin/env bash
# Prueft das gebaute Connector-Image:
#   1. keine Adressen von UMH-Diensten im Binary (Dokumentationslinks auf
#      docs.umh.app sind erlaubt, sie werden nie aufgerufen)
#   2. die bewusst entfernten Plugins sind nicht registriert, die benoetigten schon
#
#   ./scripts/check-image.sh [image]      (Standard: opairs-connect-machine:dev)
set -euo pipefail
img="${1:-opairs-connect-machine:dev}"
tmp=$(mktemp -d)
cid=""
cleanup() { [ -n "$cid" ] && docker rm -f "$cid" >/dev/null 2>&1; rm -rf "$tmp"; }
trap cleanup EXIT

cid=$(docker create "$img")
docker cp -q "$cid:/benthos" "$tmp/benthos"

hits=$(grep -aoE 'https?://([a-z0-9-]+\.)*umh\.app[A-Za-z0-9/._-]*' "$tmp/benthos" \
  | grep -vE '^https?://docs\.umh\.app' | sort -u || true)
if [ -n "$hits" ]; then
  echo "Adressen von UMH-Diensten im Binary gefunden:"
  echo "$hits"
  exit 1
fi
echo "ok: keine Adressen von UMH-Diensten im Binary"

docker run --rm --entrypoint /benthos "$img" list --format json > "$tmp/list.json"
python3 - "$tmp/list.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
have = {(k.rstrip("s"), c) for k, v in d.items() if isinstance(v, list) for c in v}
names = {c for _, c in have}
removed = ["uns", "historian", "snowflake_put", "topic_browser", "classic_to_core", "stream_processor"]
needed = ["opcua", "sensorconnect", "s7comm", "modbus", "downsampler", "tag_processor", "sql_insert", "generate"]
bad = [n for n in removed if n in names]
missing = [n for n in needed if n not in names]
if bad or missing:
    print("noch registriert:", bad, "| fehlen:", missing)
    sys.exit(1)
print("ok: entfernte Plugins fehlen, benoetigte sind vorhanden")
for k in ("inputs", "outputs", "processors"):
    if isinstance(d.get(k), list):
        print(f"{k} ({len(d[k])}):", ", ".join(d[k]))
EOF
