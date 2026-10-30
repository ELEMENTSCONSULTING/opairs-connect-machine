# Drittanbieter-Lizenzen

Stand: 2026-10-30. Spalte "geprueft" gibt an, ob die Angabe am Quellcode bzw.
an der Originalquelle verifiziert wurde.

| Komponente | Lizenz | Quelle | geprueft |
|---|---|---|---|
| benthos-umh (dieses Repo ausser unten genannten Dateien) | Apache-2.0 | `LICENSE`, Datei-Header | ja |
| Teile von `snowflake_put_plugin/` (abgeleitet von warpstreamlabs/bento) | MIT | `NOTICE` | ja |
| Projektvorlage makenew/benthos-plugin | MIT | `NOTICE` | ja |
| `sparkplug_plugin/sparkplugb/sparkplug_b_official.pb.go` (Cirrus Link / Eclipse Tahu) | **EPL-2.0** | Datei-Header | ja |
| Redpanda Connect, Free-Bundle (`redpanda-data/connect/public/bundle/free`) | offen | `go.mod`, Upstream-Repo | **nein** |
| `RuneRoven/benthosAlarm`, `RuneRoven/benthosSMTP` | offen | `go.mod` | **nein** |
| Uebrige Go-Abhaengigkeiten (siehe `go.mod`, `go.sum`) | offen | | **nein** |
| PostgreSQL (Container-Image `postgres`) | PostgreSQL License | Docker Hub | nein |

## Offene Punkte

1. Lizenzen aller Go-Abhaengigkeiten pruefen (z. B. mit `go-licenses report ./...`
   oder einem SBOM-Scanner) und hier eintragen.
2. EPL-2.0-Datei: Datei unveraendert lassen und Lizenzhinweis beibehalten. Bei
   Weitergabe als Binaerdatei die EPL-Bedingungen fuer diese Datei beachten.
3. Lizenz der in diesem Repository neu hinzugefuegten Dateien (Pipelines, SQL,
   Compose, Skripte) festlegen. Bis dahin tragen sie keinen Lizenzkopf.
