# Superset-Dashboard "OPAIRS Connect"

`OPAIRS_Connect_Dashboard.zip` ist ein Superset-Export (Format wie
"Dashboards -> Export") mit:

- Datenbankverbindung **OPAIRS Connect** (`opairs_reader@opairs-connect-db:5432/opairs`)
- 4 Datasets: `machine_data_1min`, `v_latest_1min` sowie die virtuellen
  Datasets *OPAIRS Connect Anlagenstatus* und *OPAIRS Connect Textwerte*
- 33 Charts in 5 Tabs: Uebersicht, CNC, Spritzguss, Montage, Datenqualitaet
- Filter: Zeitraum (Standard: letzte 7 Tage), Anlagenart, Anlage

Getestet mit Apache Superset 6.0 und 6.1 gegen die Demo-Daten
(`scripts/demo.sh backfill`).

## Import

Voraussetzung: Superset erreicht die Datenbank unter `opairs-connect-db`
(siehe README, Abschnitt Superset, `compose.superset.yaml`).

1. Superset -> **Dashboards** -> Import-Symbol (Pfeil) -> ZIP auswaehlen
2. Superset fragt nach dem Passwort der Datenbank *OPAIRS Connect*: den Wert
   von `OPAIRS_READER_PASSWORD` aus `.env` eintragen
3. Importieren, Dashboard **OPAIRS Connect** oeffnen

Gibt es schon eine selbst angelegte Verbindung mit dem Namen
"OPAIRS Connect", diese vorher umbenennen oder loeschen. Superset lehnt den
Import sonst wegen des doppelten Namens ab.

## Update auf eine neue Fassung

Superset ueberschreibt beim Dashboard-Import nur das Dashboard selbst,
**nicht** Charts und Datasets. Fuer ein Update deshalb vorher loeschen:

1. Dashboards: *OPAIRS Connect* loeschen
2. Charts: alle Charts des Dashboards loeschen (Liste nach Dashboard filtern,
   "Bulk select")
3. Datasets: die vier Datasets oben loeschen
4. ZIP wie oben importieren. Die Datenbankverbindung bleibt bestehen, das
   Passwort wird nicht erneut abgefragt.

## Anpassen

Das Dashboard wird von `build_dashboard.py` erzeugt (nur Python-Standardbibliothek):

```bash
python3 superset/build_dashboard.py
```

Charts, Filter und Layout stehen dort als Python-Aufrufe. Die UUIDs sind fest,
ein Neuaufbau erzeugt dieselben Objekte. Die CI prueft mit `--check`, dass die
eingecheckte ZIP zum Generator passt. Nach einer Aenderung also die ZIP neu bauen und
mit einchecken.

Aenderungen, die nur in Superset gemacht werden (Edit dashboard), bleiben
erhalten, bis die ZIP erneut importiert wird.

## Kennzahlen

| Kennzahl | Berechnung |
|---|---|
| Mittelwert | `SUM(avg_value * sample_count) / SUM(sample_count)` (gewichtet mit der Anzahl guter Werte je Minute) |
| Verfuegbarkeit | Anteil der Werte mit `state = 1` |
| iO-Quote | Anteil `pruef_ergebnis = 1` (Montage) bzw. `teil_io = 1` (Spritzguss) |
| Uncertain/Bad | `SUM(bad_count)`: Werte, deren Quelle keine gute Qualitaet gemeldet hat. Sie stehen in den Rohdaten und fehlen in Mittel, Min und Max |
| online | letzter Wert juenger als 1 Minute |

Die Anlagenart ergibt sich aus dem Namen `<prefix>-<art>-<nr>`: `cnc` -> CNC,
`sgm` -> Spritzguss, `mon` -> Montage, sonst "Sonstige". Echte Anlagen
entsprechend benennen (`MACHINE_NAME`), oder `ART_SQL` in
`build_dashboard.py` anpassen.

Die Charts filtern nach Signalnamen (`tag`), nicht nach Anlagen. Echte
Anlagen mit denselben Signalnamen erscheinen deshalb automatisch.

Alle Zeiten sind UTC.
