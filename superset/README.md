# Superset-Dashboard "OPAIRS Connect"

`OPAIRS_Connect_Dashboard.zip` ist ein Superset-Export (Format wie
"Dashboards -> Export") mit:

- Datenbankverbindung **OPAIRS Connect** (`opairs_reader@opairs-connect-db:5432/opairs`)
- 5 virtuelle Datasets mit eigenen Namen, damit sie nicht mit selbst
  angelegten Datasets auf dieselben Tabellen kollidieren:
  - `opairs_connect_minutenwerte` (`SELECT * FROM opairs.v_machine_data_1min_ctx`)
  - `opairs_connect_aktueller_stand` (`SELECT * FROM opairs.v_latest_1min_ctx`)
  - `opairs_connect_rohdaten` (`SELECT * FROM opairs.v_machine_data_ctx`)
  - `opairs_connect_zeitmodell` (`SELECT * FROM opairs.v_oee_1min`)
  - `opairs_connect_anlagen` (`SELECT * FROM opairs.v_anlage`, Quelle der Filter)
- 38 Charts in 6 Tabs: Uebersicht, Kennzahlen, CNC, Spritzguss, Montage, Rohdaten
- Filter: Zeitraum (Standard: letzte Woche), Werk -> Bereich (Halle) -> Linie
  -> Anlage (jeweils nur Werte des darueber gewaehlten). Aktualisierung jede Minute.

Voraussetzung: Datenbankschema mit Stammdaten und Zustaenden (`sql/001_schema.sql`
ab dieser Fassung; die Wartung spielt es beim Start ein).

Getestet mit Apache Superset 6.1, lokal gegen die Demo-Daten und auf
opairs-node-001 im Betrieb.

## Import

Voraussetzung: Superset erreicht die Datenbank unter `opairs-connect-db`
(siehe README, Abschnitt Superset, `compose.superset.yaml`).

**Mit eigener Verbindung (ZIP aus dem Repo):**

1. Superset -> **Dashboards** -> Import-Symbol (Pfeil) -> ZIP auswaehlen
2. Superset fragt nach dem Passwort der Datenbank *OPAIRS Connect*: den Wert
   von `OPAIRS_READER_PASSWORD` aus `.env` eintragen
3. Dashboard **OPAIRS Connect** oeffnen

Gibt es schon eine Verbindung mit dem Namen "OPAIRS Connect", die nicht aus
diesem Export stammt, diese vorher umbenennen. Superset lehnt den Import sonst
wegen des doppelten Namens ab.

**Mit einer bereits angelegten Verbindung:** Superset ordnet Verbindungen beim
Import ueber ihre UUID zu, nicht ueber den Namen. UUID und Name anzeigen
(im Browser, angemeldet in Superset):

```
http://<superset>/api/v1/database/?q=(columns:!(database_name,uuid))
```

Dann die ZIP fuer diese Verbindung bauen und importieren. Es wird kein
Passwort abgefragt, die Verbindung bleibt unveraendert:

```bash
python3 superset/build_dashboard.py \
  --database-uuid <uuid> --database-name "<name>" --out /tmp/OPAIRS_Connect_Dashboard.zip
```

## Update auf eine neue Fassung

Superset ueberschreibt beim Dashboard-Import nur das Dashboard selbst,
**nicht** Charts und Datasets. Fuer ein Update deshalb vorher loeschen:

1. Dashboards: *OPAIRS Connect* loeschen
2. Charts: alle Charts mit `[OPAIRS Connect]` im Namen loeschen ("Bulk select")
3. Datasets: alle `opairs_connect_*`-Datasets loeschen
4. ZIP wie oben importieren. Die Datenbankverbindung bleibt bestehen.

## Anpassen

Das Dashboard wird von `build_dashboard.py` erzeugt (nur Python-Standardbibliothek):

```bash
python3 superset/build_dashboard.py
```

Charts, Filter und Layout stehen dort als Python-Aufrufe. Die UUIDs sind fest
und haengen nicht von der Verbindung ab, ein Neuaufbau erzeugt dieselben
Objekte. Die CI prueft mit `--check`, dass die eingecheckte ZIP zum Generator
passt. Nach einer Aenderung also die ZIP neu bauen und mit einchecken.

Aenderungen, die nur in Superset gemacht werden (Edit dashboard), bleiben
erhalten, bis die ZIP erneut importiert wird.

## Kennzahlen

| Kennzahl | Berechnung |
|---|---|
| Laufzeitanteil | `SUM(avg_value * sample_count) / SUM(sample_count)` fuer `tag = state` (Anteil der Zeit mit `state = 1`) |
| iO-Quote | wie oben fuer `pruef_ergebnis` (Montage) bzw. `teil_io` (Spritzguss) |
| Werte mit Qualitaetsproblem | `SUM(bad_count)`: Werte mit Qualitaet Uncertain oder Bad. Sie stehen in den Rohdaten und fehlen in Mittel, Min und Max |
| Anlagen mit Daten | Anlagen mit mindestens einem Rohwert in den letzten 5 Minuten |
| Verlaeufe | `AVG(avg_value)`, bei Grenzwert-Signalen `MAX(max_value)` bzw. `MIN(min_value)` |
| OEE | `SUM(nettoproduktiv_min) / SUM(planbelegung_min)` |
| OEE ohne geplante Stillstaende | `SUM(nettoproduktiv_min) / SUM(geplante_betriebszeit_min)` |
| TEEP | `SUM(nettoproduktiv_min) / SUM(kalender_min)` |
| Auslastung | `SUM(auslastung_min) / SUM(geplante_betriebszeit_min)` (Produktion + Ruesten) |
| Verfuegbarkeit, Leistung, Qualitaet | Nettobetriebszeit / geplante Betriebszeit, nutzbare Zeit / Nettobetriebszeit, Nettoproduktivzeit / nutzbare Zeit |
| Datenabdeckung | Anteil der Minuten mit gueltigem Zustand (nicht 0) |

Kennzahlen je Linie, Bereich oder Werk summieren die Minuten aller Anlagen
(zeitgewichtet), sie bilden keinen Engpass einer verketteten Linie ab.

Die Anlagenart im Chart "Laufzeitanteil im Verlauf" kommt aus `opairs.asset.art`. Die Charts filtern nach
Signalnamen (`tag`), nicht nach Anlagen. Echte Anlagen mit denselben
Signalnamen erscheinen deshalb automatisch.

Alle Zeiten sind UTC.
