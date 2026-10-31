# IODD-Ordner

Hier liegen die Geraetebeschreibungen (IODDs) der IO-Link-Sensoren. Der
Dienst `iodd-mirror` stellt sie dem Connector ueber dieselbe Schnittstelle
bereit wie der IODDfinder; der Connector braucht damit **kein Internet**.

Dateien in diesem Ordner (ausser dieser Anleitung) werden nicht ins
Repository eingecheckt.

## Dateien ablegen

- IODD-Pakete als **ZIP** (so wie sie der IODDfinder oder der Hersteller
  liefert) oder einzelne **IODD-XML**-Dateien, beliebig in Unterordnern.
- Sprachdateien und Bilder in den ZIPs werden automatisch ignoriert.
- Liegen mehrere Versionen desselben Geraets vor, nimmt der Connector die mit
  dem neuesten `releaseDate`.
- Dateien muessen fuer andere lesbar sein (`chmod -R a+rX iodd`), der Dienst
  laeuft nicht als root. Mit `fetch` geladene Dateien sind es automatisch.
- IODDs in ISO-8859-1 / Windows-1252 werden automatisch nach UTF-8 umgewandelt.
- Nicht lesbare XML-Dateien stehen als Warnung im Log
  (`docker compose logs iodd-mirror`).
- Neue Dateien werden nach spaetestens 60 Sekunden erkannt, kein Neustart
  noetig. Uebersicht: `http://<host>:8080/` (falls der Port freigegeben ist)
  oder `docker compose logs iodd-mirror`.

## IODDs herunterladen (auf einem Rechner mit Internet)

```bash
docker compose build iodd-mirror
docker compose run --rm --no-deps --user "$(id -u):$(id -g)" -v "$PWD/iodd:/fetch" \
  iodd-mirror fetch -out /fetch 310:967 42:278531
# oder mit Liste:
docker compose run --rm --no-deps --user "$(id -u):$(id -g)" -v "$PWD/iodd:/fetch" \
  iodd-mirror fetch -out /fetch -list /fetch/geraete.example.txt
```

`VENDOR:DEVICE` sind die IO-Link-IDs (Vendor ID und Device ID). Der Connector
schreibt sie ins Log, wenn er einen Sensor findet. Quelle ist standardmaessig
der IODDfinder der IO-Link Community (`-api` aendert sie).

Danach den Ordner zum Kunden kopieren.

Hinweis: Die IODDs stammen von den Geraeteherstellern. Vor dem Mitliefern
eines IODD-Satzes als Teil eines Produkts die Nutzungsbedingungen des
IODDfinders und der Hersteller pruefen.
