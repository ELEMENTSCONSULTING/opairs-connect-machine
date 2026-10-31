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
                  ^         ^                 ^
       ./pipelines (YAML)   iodd-mirror   maintenance (alle 5 Min)
                            (./iodd)
```

## Schnellstart

```bash
cp .env.example .env        # Passwoerter anpassen (URL-sichere Zeichen)
docker compose up -d --build
```

Standardmaessig laeuft die **Selbsttest-Pipeline** (`pipelines/selftest.yaml`),
die Testwerte erzeugt. Damit laesst sich der Stack pruefen, bevor eine echte
Quelle angebunden wird.

Echte Quelle anbinden: in `.env` die Variable `PIPELINE` auf eine Datei aus
`pipelines/` setzen (z. B. `/etc/opairs/pipelines/opcua-to-postgres.yaml`), die
Knoten (`nodeIDs`) in der Datei anpassen und `docker compose up -d` ausfuehren.
Weitere Protokolle: siehe `docs/input/` (S7, Modbus, EtherNet/IP, ifm IO-Link,
Beckhoff ADS, Sparkplug B).

| Pipeline | Quelle |
|---|---|
| `selftest.yaml` | Testwerte, keine Maschine noetig |
| `opcua-to-postgres.yaml` | OPC-UA-Server |
| `ifm-to-postgres.yaml` | ifm IO-Link-Master (AL1350, AL1352, ...), IODDs vom lokalen Mirror |

## IO-Link: lokaler IODD-Mirror (offline)

Das sensorconnect-Plugin braucht fuer jeden IO-Link-Sensor die
Geraetebeschreibung (IODD) und laedt sie standardmaessig ueber einen
UMH-Server aus dem Internet. Der Dienst **`iodd-mirror`** (`iodd_mirror/`)
bildet genau die zwei Abfragen nach, die das Plugin stellt, und liefert die
IODDs aus dem Ordner `./iodd`. Der Connector braucht damit kein Internet, und
die automatische Erkennung der Sensoren bleibt erhalten.

- IODD-Dateien (ZIP oder XML) nach `./iodd` legen, Anleitung und
  Download-Befehl in [`iodd/README.md`](iodd/README.md).
- Sensoren ohne IODD liefern Rohdaten (Hex), der Connector laeuft weiter.
- Die Dateien muessen fuer andere lesbar sein (der Dienst laeuft nicht als
  root), z. B. `chmod -R a+rX iodd`.
- Der Mirror ist mit Go-Tests gegen den echten Plugin-Code abgesichert
  (`iodd_mirror/plugin_compat_test.go`, laeuft in der CI).

## Tests

| Befehl | Prueft |
|---|---|
| `./scripts/smoke-test.sh` | baut und startet den Stack, wartet auf Selbsttest-Daten, prueft Partitionen und Minutenwerte, ruft danach die SQL-Tests auf |
| `docker run --rm -v "$PWD/pipelines:/p:ro" opairs-connect-machine:dev test /p/...` | Unit-Tests der Pipeline-Mappings (`pipelines/*_benthos_test.yaml`) |
| `./scripts/test-sql.sh` | SQL-Regressionstests (`sql/tests/`) gegen die laufende Datenbank; laufen in einer Transaktion mit ROLLBACK, es bleiben keine Daten zurueck |
| CI (`.github/workflows/ci.yml`) | bei jedem Pull Request: Images bauen, IODD-Mirror-Tests (inkl. Plugin-Kompatibilitaet), `benthos lint`, Pipeline-Unit-Tests, Smoke-Test, SQL-Tests |

Die CI laeuft nur, wenn GitHub Actions fuer das Repository aktiviert ist
(Settings > Actions > General).

## Datenmodell (reines PostgreSQL, ohne Erweiterungen)

| Objekt | Zweck |
|---|---|
| `opairs.machine_data` | Rohdaten, schmal (`ts, machine, tag, value, value_text, quality`), **taeglich partitioniert** |
| `opairs.machine_data_default` | Sicherheitsnetz, falls eine Tagespartition fehlt (wird bei der Wartung aufgeloest) |
| `opairs.machine_data_1min` | Minutenwerte (avg/min/max/Anzahl) fuer Dashboards; nur Werte mit guter Qualitaet, `bad_count` zaehlt Uncertain/Bad |
| `opairs.v_latest_1min` | letzter Minutenwert je Maschine und Tag (letzte 24 h) |
| `opairs.maintain_partitions()`, `aggregate_1min()`, `purge_aggregates()` | Wartungsschritte (siehe unten) |
| `opairs.run_maintenance()` | alle Wartungsschritte in einem Aufruf |

Indizes: `(machine, tag, ts)` fuer Abfragen je Tag, BRIN auf `ts` fuer
Zeitbereiche, `bucket` auf den Minutenwerten.

Werte mit Zeitstempel in der Zukunft (falsche Uhr an der Quelle) werden
gespeichert, aber nicht aggregiert.

`quality` ist `Good`, `Uncertain 0x...` oder `Bad 0x...` (OPC UA) bzw. NULL
bei Quellen ohne Qualitaetsangabe. Nur `Good` und NULL fliessen in die
Minutenwerte ein (`opairs.is_good_quality()`).

Es gibt bewusst **keine Kompression und keine Continuous Aggregates**
(TimescaleDB-Community-Funktionen stehen unter der Timescale License). Rohdaten
kurz, Aggregate lang aufbewahren.

## Wartung und Updates

Der Container `maintenance`

1. wendet beim Start `sql/001_schema.sql` an (die Datei ist idempotent, so
   kommen Schema-Aenderungen nach einem Update automatisch in die Datenbank),
2. fuehrt danach alle 5 Minuten drei Schritte in getrennten Transaktionen aus:
   - `maintain_partitions`: Partitionen 7 Tage im Voraus anlegen, Rohdaten
     aelter als `RAW_RETENTION_DAYS` (Standard 30) loeschen
   - `aggregate_1min`: Minutenwerte berechnen
   - `purge_aggregates`: Minutenwerte aelter als `AGG_RETENTION_DAYS`
     (Standard 400) loeschen

Geloescht wird nur in diesem regulaeren Lauf. Das Anwenden des Schemas beim
Start legt nur Partitionen an und loescht nie Daten.

Faellt die Wartung aus, landen neue Zeilen in der Default-Partition. Der
naechste Lauf legt die fehlenden Tagespartitionen an und verschiebt die Zeilen
dorthin; dabei wird die Tabelle kurz exklusiv gesperrt (hoechstens 10 s
Wartezeit, sonst erneuter Versuch im naechsten Lauf). Die Aggregation holt
ebenfalls auf (hoechstens 7 Tage zurueck). Gleichzeitige Wartungslaeufe sind
per Sperre ausgeschlossen.

`SELECT opairs.run_maintenance();` fuehrt alle Schritte in einem Aufruf aus
(fuer manuelle Laeufe und Tests).

Die Rollen (`sql/002_roles.sh`) werden nur bei der Erstinitialisierung der
Datenbank angelegt.

## Superset

Datenquelle als PostgreSQL anlegen, Benutzer `opairs_reader` (nur lesend),
Schema `opairs`. Fuer Dashboards `machine_data_1min` bzw. `v_latest_1min`
verwenden, nicht die Rohdaten. Dazu in `compose.yaml` den Datenbank-Port
freigeben (auskommentierter Block), moeglichst nur im internen Netz und mit TLS.

## Rollen

- `opairs_writer`: Connector, darf nur in `opairs.machine_data` einfuegen
- `opairs_reader`: Superset, darf nur lesen
- Admin-Benutzer (`POSTGRES_USER`): Setup und Wartung

## Upstream-Updates

```bash
./scripts/sync-upstream.sh          # Aenderungen bis Upstream main
```

Legt einen Branch `chore/upstream-sync-<sha>` an, der per Pull Request
geprueft wird. Details in [`UPSTREAM.md`](UPSTREAM.md).

## Lizenzen

Siehe [`LICENSE`](LICENSE), [`NOTICE`](NOTICE) und
[`THIRD_PARTY.md`](THIRD_PARTY.md). Achtung: Die Sparkplug-Protobuf-Datei
steht unter EPL-2.0, nicht unter Apache-2.0.

## Stand / bekannte Grenzen

- SQL, Rollen und Wartung sind mit den Regressionstests gegen PostgreSQL 16
  geprueft. Docker-Build und Benthos-Pipelines sind **noch nicht ausgefuehrt**
  worden; das uebernimmt die CI bzw. `./scripts/smoke-test.sh`.
- Der Connector-Container hat keinen Healthcheck (`scratch`-Image ohne Shell).
  `restart: unless-stopped` startet ihn bei Absturz neu; der Status ist unter
  `:4195/ready` abrufbar.
- Das Image enthaelt alle Upstream-Plugins und das Redpanda-Free-Bundle; eine
  Reduktion auf die benoetigten Plugins ist offen.
- ERP-Anbindungen (SAP, Infor, proALPHA) sind nicht enthalten.
- Die ifm-Pipeline ist mit Unit-Tests und `lint` geprueft, aber noch nicht
  gegen einen echten IO-Link-Master gelaufen. `iodd-mirror fetch` ist gegen
  eine nachgebildete Quelle getestet, nicht gegen den echten IODDfinder.
