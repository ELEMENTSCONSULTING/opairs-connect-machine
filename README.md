# opairs-connect-machine

Connector-Stack fuer Maschinendaten: liest OT-Quellen (OPC UA, Siemens S7,
Modbus, EtherNet/IP, ...) und schreibt sie in eine PostgreSQL-Datenbank, aus
der Superset liest.

Basis ist **benthos-umh** (Apache-2.0, UMH Systems GmbH), siehe
[`UPSTREAM.md`](UPSTREAM.md). Das urspruengliche README steht in
[`README.upstream.md`](README.upstream.md), die Doku der Plugins unter
[`docs/`](docs/).

```
Maschinen --> connector (benthos-umh) --> Postgres --> Superset
                  ^                           ^
            ./pipelines (YAML)          maintenance (alle 5 Min)
```

## Schnellstart

```bash
cp .env.example .env        # Passwoerter anpassen (URL-sichere Zeichen)
docker compose up -d --build
```

Standardmaessig laeuft die **Selbsttest-Pipeline** (`pipelines/selftest.yaml`),
die Testwerte erzeugt. Damit laesst sich der Stack pruefen, bevor eine echte
Quelle angebunden wird:

```bash
./scripts/smoke-test.sh
```

Echte Quelle anbinden: in `.env` die Variable `PIPELINE` auf eine Datei aus
`pipelines/` setzen (z. B. `/etc/opairs/pipelines/opcua-to-postgres.yaml`) und
die Knoten (`nodeIDs`) in der Datei anpassen. Weitere Protokolle: siehe
`docs/input/` (S7, Modbus, EtherNet/IP, ifm IO-Link, Beckhoff ADS, Sparkplug B).

## Datenmodell (reines PostgreSQL, ohne Erweiterungen)

| Objekt | Zweck |
|---|---|
| `opairs.machine_data` | Rohdaten, schmal (`ts, machine, tag, value, value_text, quality`), **taeglich partitioniert** |
| `opairs.machine_data_default` | Sicherheitsnetz, falls eine Tagespartition fehlt |
| `opairs.machine_data_1min` | Minutenwerte (avg/min/max/Anzahl) fuer Dashboards |
| `opairs.run_maintenance()` | legt Partitionen an, loescht alte Rohdaten, berechnet Minutenwerte |

Der Container `maintenance` ruft `run_maintenance()` alle 5 Minuten auf.
Aufbewahrung ueber `RAW_RETENTION_DAYS` (Standard 30) und `AGG_RETENTION_DAYS`
(Standard 400). Die Rohdaten-Aufbewahrung muss laenger sein als das
Aggregations-Fenster (2 Stunden).

Es gibt bewusst **keine Kompression und keine Continuous Aggregates**
(TimescaleDB-Community-Funktionen stehen unter der Timescale License). Rohdaten
kurz, Aggregate lang aufbewahren.

## Superset

Datenquelle als PostgreSQL anlegen, Benutzer `opairs_reader` (nur lesend),
Schema `opairs`. Fuer Dashboards die Tabelle `machine_data_1min` verwenden,
nicht die Rohdaten. Dazu in `compose.yaml` den Datenbank-Port freigeben
(auskommentierter Block), moeglichst nur im internen Netz und mit TLS.

## Rollen

- `opairs_writer`: Connector, darf nur in `opairs.machine_data` einfuegen
- `opairs_reader`: Superset, darf nur lesen
- Admin-Benutzer (`POSTGRES_USER`): Setup und Wartung

## Lizenzen

Siehe [`LICENSE`](LICENSE), [`NOTICE`](NOTICE) und
[`THIRD_PARTY.md`](THIRD_PARTY.md). Achtung: Die Sparkplug-Protobuf-Datei
steht unter EPL-2.0, nicht unter Apache-2.0.

## Stand / bekannte Grenzen

- Die Benthos-Pipelines (`pipelines/*.yaml`) und das Dockerfile wurden
  **noch nicht gebaut oder ausgefuehrt**. Das SQL und die Rollen sind gegen
  PostgreSQL 16 getestet. Zuerst `./scripts/smoke-test.sh` ausfuehren.
- Der Connector-Container hat keinen Healthcheck (`scratch`-Image ohne Shell).
  `restart: unless-stopped` startet ihn bei Absturz neu; der Status ist unter
  `:4195/ready` abrufbar.
- ERP-Anbindungen (SAP, Infor, proALPHA) sind nicht enthalten.
