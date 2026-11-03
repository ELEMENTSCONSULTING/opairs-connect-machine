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

Wichtig: Wird nur der **Inhalt** einer Pipeline-Datei geaendert, bemerkt
Compose das nicht. Dann `docker compose restart connector` ausfuehren.
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
| `opairs.asset` | Stammdaten je Anlage: Werk, Bereich (Halle), Linie, SAP-Bezeichnungen, Signale fuer OEE |
| `opairs.tag_meta` | Signalbeschreibung, Einheit, Grenzwerte; `machine = '*'` gilt fuer alle Anlagen |
| `opairs.state_def` | einheitliche Maschinenzustaende 0-8 und ihre Zeitstufe |
| `opairs.state_1min` | Zustand, Taktzeit und Qualitaet je Anlage und Minute (aus `aggregate_1min()`) |
| `opairs.v_oee_1min`, `v_oee_taeglich` | Zeitmodell, OEE, TEEP und Auslastung (siehe unten) |
| `opairs.v_*_ctx`, `v_anlage`, `v_tag_meta` | Roh- und Minutenwerte mit Einordnung aus den Stammdaten |
| `opairs.maintain_partitions()`, `aggregate_1min()`, `purge_aggregates()` | Wartungsschritte (siehe unten) |
| `opairs.run_maintenance()` | alle Wartungsschritte in einem Aufruf |

Indizes: `(machine, tag, ts)` fuer Abfragen je Tag, BRIN auf `ts` fuer
Zeitbereiche, `bucket` auf den Minutenwerten.

Werte mit Zeitstempel in der Zukunft (falsche Uhr an der Quelle) werden
gespeichert, aber nicht aggregiert.

`quality` ist `Good`, `Uncertain 0x...` oder `Bad 0x...` (OPC UA) bzw. NULL
bei Quellen ohne Qualitaetsangabe. Nur `Good` und NULL fliessen in die
Minutenwerte ein (`opairs.is_good_quality()`).

### Stammdaten, Zustaende und OEE

Anlagen werden nach ISA-95 eingeordnet: Unternehmen > Werk > Bereich (Halle,
Kostenstelle) > Linie > Anlage > Signal. `opairs.asset.machine` ist der Name,
den der Connector schreibt. Anlagen ohne Eintrag funktionieren weiter und
erscheinen in den Sichten als *(nicht zugeordnet)*.

Fuer OEE liefert jede Anlage einen **Zustandscode** (Standard: Signal
`state_code`), Gruende im Detail als Text (z. B. `status`):

| Code | Zustand | Zeitstufe |
|---|---|---|
| 1 | Produktion | Produktion |
| 2 | Leerlauf / wartet | Leerlauf |
| 3 | Technische Stoerung | Verfuegbarkeitsverlust |
| 4 | Ruesten / Produktwechsel (inkl. Reinigung beim Wechsel) | Verfuegbarkeitsverlust, zaehlt zur Auslastung |
| 5 | Wartung geplant | geplanter Stillstand |
| 6 | Reinigung geplant | geplanter Stillstand |
| 7 | Pause / organisatorisch | geplanter Stillstand |
| 8 | Keine Schicht | keine Schicht |
| 0 | Unbekannt / kein Signal | nur Kalenderzeit (Datenabdeckung) |

Zeitmodell nach Jodlbauer, je Minute in `opairs.v_oee_1min`:
Kalenderzeit - keine Schicht = Planbelegungszeit - geplante Stillstaende =
geplante Betriebszeit - Stoerung und Ruesten = Nettobetriebszeit - Leerlauf
und Taktverlust (Soll/Ist-Taktzeit) = nutzbare Zeit x Qualitaetsrate =
Nettoproduktivzeit.

- OEE = Nettoproduktivzeit / Planbelegungszeit (zusaetzlich: OEE ohne geplante Stillstaende)
- TEEP = Nettoproduktivzeit / Kalenderzeit
- Auslastung = (Produktion + Ruesten) / geplante Betriebszeit

Der letzte Zustandswert gilt bis zu `asset.zustand_haltezeit` (Standard 15
Minuten), danach Zustand 0. Quellen, die nur bei Aenderung senden (OPC-UA-
Subscription), brauchen einen laengeren Wert. Qualitaet (`tag_qualitaet`, 1/0
je Teil) und Taktzeit (`tag_taktzeit`, Soll aus `tag_taktzeit_soll` oder
`soll_taktzeit_s`) sind optional, fehlen sie, zaehlt der Faktor 1.

Anlage eintragen (Beispiel):

```sql
INSERT INTO opairs.asset (machine, bezeichnung, art, werk, bereich, linie,
                          sap_arbeitsplatz, tag_qualitaet, tag_taktzeit, soll_taktzeit_s)
VALUES ('presse-01', 'Presse 1', 'Umformen', 'Werk 1000', 'Halle 3', 'Linie 2',
        'PRS01', 'teil_io', 'taktzeit_s', 12.5);
```

Die Zustaende einer neuen Anlage werden beim naechsten Wartungslauf ab dem
ersten Zustandswert (hoechstens 7 Tage) nachgerechnet. Nach Aenderungen an
den `tag_*`-Spalten die Vergangenheit neu rechnen:
`SELECT opairs.aggregate_state_1min(interval '30 days', interval '30 days');`
(nie weiter zurueck als die Rohdaten reichen).

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

## Datenbank-Speicherort

Standardmaessig liegen die Daten im Docker-Volume
`opairs-connect-machine_opairs-pgdata`. Sollen sie in einem festen Ordner auf
dem Host liegen (z. B. neben anderen Diensten unter `/srv/opairs`), in `.env`
`PGDATA_DIR` setzen. Bei einer leeren Datenbank genuegt:

```bash
sudo mkdir -p /srv/opairs/opairs-connect-db
echo "PGDATA_DIR=/srv/opairs/opairs-connect-db" >> .env
docker compose up -d
```

Bestehende Daten aus dem Volume mitnehmen (Dienste vorher stoppen):

```bash
docker compose down
sudo mkdir -p /srv/opairs/opairs-connect-db
docker run --rm -v opairs-connect-machine_opairs-pgdata:/von:ro \
  -v /srv/opairs/opairs-connect-db:/nach postgres:17 cp -a /von/. /nach/
echo "PGDATA_DIR=/srv/opairs/opairs-connect-db" >> .env
docker compose up -d
```

Das alte Volume bleibt als Sicherung bestehen. Erst wenn alles laeuft:
`docker volume rm opairs-connect-machine_opairs-pgdata`.

## Superset

Datenquelle vom Typ PostgreSQL, Benutzer `opairs_reader` (nur lesend), Schema
`opairs`. Fuer Dashboards `machine_data_1min` bzw. `v_latest_1min` verwenden,
nicht die Rohdaten.

**Superset auf einem anderen Host:** Port per `compose.override.yaml`
freigeben (Vorlage `compose.override.example.yaml`, nur an eine interne
Adresse, Firewall nur fuer den Superset-Host oeffnen):

```bash
cp compose.override.example.yaml compose.override.yaml
echo "DB_BIND_ADDRESS=<interne IP dieses Servers>" >> .env
echo "DB_PORT=55432" >> .env
docker compose up -d
```

SQLAlchemy-URI in Superset:
`postgresql://opairs_reader:<OPAIRS_READER_PASSWORD>@<IP>:55432/opairs`

**Superset auf demselben Host (Docker):** ohne Portfreigabe. Die Datenbank
kommt zusaetzlich in das Docker-Netz von Superset (`compose.superset.yaml`),
Superset bleibt unveraendert:

```bash
docker inspect superset --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}'
echo "SUPERSET_NETWORK=<Netz von Superset>" >> .env
echo "COMPOSE_FILE=compose.yaml:compose.superset.yaml" >> .env
docker compose up -d
```

Wird auch `compose.override.yaml` genutzt, diese in `COMPOSE_FILE` anhaengen
(`...:compose.superset.yaml:compose.override.yaml`).

SQLAlchemy-URI in Superset:
`postgresql://opairs_reader:<OPAIRS_READER_PASSWORD>@opairs-connect-db:5432/opairs`

Fertiges Dashboard zum Importieren: `superset/OPAIRS_Connect_Dashboard.zip`
(Anleitung in `superset/README.md`).

Der Datenbankdienst heisst bewusst `opairs-connect-db` und nicht `db`: In
gemeinsam genutzten Netzen gibt es oft schon andere Dienste namens `db`.

## Demo-Daten

Fuer Superset-Tests ohne Maschine: 9 simulierte Anlagen mit Schichtbetrieb,
Stoerungen, Qualitaetsspitzen und iO/NiO-Pruefungen.

```bash
./scripts/demo.sh backfill   # 7 Tage Historie und Stammdaten (ca. 4 Mio. Zeilen, etwa 1 Minute)
./scripts/demo.sh live       # Connector laeuft mit der Demo-Pipeline weiter (Takt 10 s)
./scripts/demo.sh remove     # alle Demo-Daten und Demo-Stammdaten loeschen
```

Stammdaten (`sql/demo/demo_stammdaten.sql`): Werk Demo, Halle 1
Teilefertigung (Linien CNC-Zelle, Spritzguss) und Halle 2 Montage
(Montagelinie A: mon-01, mon-02; Montagelinie B: mon-03, mon-04).

Zustaende (`state_code`, Grund in `status`):

| Anlage | Zustaende ausser Produktion, Stoerung, keine Schicht |
|---|---|
| `demo-cnc-01..03` | 2 wartet auf Material; cnc-02: 5 Wartung Mi 06:00-08:00; cnc-03: 4 Ruesten 13:00-13:20 |
| `demo-sgm-01` | 2 wartet auf Entnahme |
| `demo-sgm-02` | 4 Produktwechsel 05:00-05:45, 6 Reinigung Fr 19:00-20:00 |
| `demo-mon-01..04` | 7 Pause, 2 kein Material; mon-01: 4 Typwechsel 11:00-11:15; mon-02: 6 Reinigung 20:45-21:00; mon-04: 5 Wartung Di 05:00-06:00 |

Im Backfill liefert `demo-cnc-03` am letzten Werktag vor gestern von 10:00
bis 11:00 keine Daten (Zustand 0 ab 10:14, Datenabdeckung).

Zeiten UTC. Schicht Mo-Fr 05:00-21:00, Spritzguss Mo-Fr durchgehend,
Montage-Pausen 09:00-09:15 und 13:00-13:30, Stoerungen als 5-Minuten-Bloecke.

| Anlage | Art | Tags |
|---|---|---|
| `demo-cnc-01..03` | CNC-Bearbeitung | `state`, `state_code`, `status`, `spindle_speed_rpm`, `temperature_c`, `power_kw`, `vibration_mm_s` (Spitzen mit `Uncertain` -> `bad_count`) |
| `demo-sgm-01` | Spritzguss, Werkzeug `WZ-1001 Gehaeuse 4-fach` | `state`, `state_code`, `status`, `werkzeug`, `kavitaeten`, `zykluszeit_s`, `soll_zykluszeit_s`, `massetemperatur_c`, `werkzeugtemperatur_c` (Tagesdrift), `einspritzdruck_bar`, `teil_io`, `nio_grund` |
| `demo-sgm-02` | Spritzguss, taeglicher Werkzeugwechsel `WZ-2002 Deckel 2-fach` / `WZ-2003 Clip 8-fach`, Ruesten 05:00-05:45 | wie sgm-01 |
| `demo-mon-01` | Schraubstation | `schraub_drehmoment_nm` (steigt ueber die Schicht, Bit-Verschleiss), `schraub_drehwinkel_grad` |
| `demo-mon-02` | Dichtheitspruefung | `pruefdruck_bar`, `leckrate_ccm_min` (NiO > 2.0) |
| `demo-mon-03` | Einpressstation | `einpresskraft_kn` (iO 7.2-8.8), `einpressweg_mm` (iO 11.85-12.15) |
| `demo-mon-04` | Endpruefung | `isolationswiderstand_mohm` (NiO < 100), `kamera_io` |

Alle Montagelinien zusaetzlich: `state`, `state_code`, `status`, `taktzeit_s`, `pruef_ergebnis` (1 = iO, 0 = NiO; Mittelwert =
iO-Quote) und `nio_grund` (Text, nur bei NiO).

Textwerte (`status`, `werkzeug`, `nio_grund`) stehen in `value_text` der
Rohdaten und erscheinen nicht in den Minutenwerten.

## Rollen

- `opairs_writer`: Connector, darf nur in `opairs.machine_data` einfuegen
- `opairs_reader`: Superset, darf nur lesen
- Admin-Benutzer (`POSTGRES_USER`): Setup und Wartung

## Update

```bash
./scripts/update.sh
```

Holt den neuen Stand, baut die Images und startet `connector` und
`maintenance` neu. Der Neustart ist noetig, weil Pipelines und SQL als Ordner
eingebunden sind: `docker compose up -d` allein laesst die Container weiterlaufen,
und das Schema wird nur beim Start der Wartung eingespielt.

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
