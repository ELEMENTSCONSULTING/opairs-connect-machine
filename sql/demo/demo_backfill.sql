-- Demo-Daten: 7 Tage Historie fuer drei simulierte CNC-Maschinen
-- (demo-cnc-01 .. demo-cnc-03), ein Wert je Tag alle 10 Sekunden.
-- Gleiches Muster wie die Live-Pipeline pipelines/demo-anlage.yaml.
--
--   ./scripts/demo.sh backfill
--
-- Muster:
--   Schicht Mo-Fr 05:00-21:00 UTC (06:00-22:00 Winterzeit); sonst Stillstand
--   Stoerungen als 5-Minuten-Bloecke: cnc-01 ~8 %, cnc-02 ~15 %, cnc-03 ~4 % der Schicht
--   state              1 = laeuft, 0 = steht   (avg je Stunde = Verfuegbarkeit)
--   spindle_speed_rpm  Solldrehzahl +/- 5 %, im Stillstand 0
--   temperature_c      ~45-55 C im Betrieb (20-Minuten-Zyklus), ~27 C im Stillstand
--   power_kw           Last abhaengig von der Drehzahl, im Stillstand Grundlast
--   vibration_mm_s     ~1.5-2.5, gelegentliche Spitzen mit quality "Uncertain"
--
-- Wiederholbar: vorhandene Demo-Daten im Zeitraum werden vorher geloescht.
\set ON_ERROR_STOP on

-- Tagespartitionen fuer den Zeitraum anlegen, je Tag eine eigene kurze
-- Transaktion (die Elterntabelle wird dafuer kurz gesperrt).
SELECT opairs.create_day_partition(((now() AT TIME ZONE 'UTC')::date - 7));
SELECT opairs.create_day_partition(((now() AT TIME ZONE 'UTC')::date - 6));
SELECT opairs.create_day_partition(((now() AT TIME ZONE 'UTC')::date - 5));
SELECT opairs.create_day_partition(((now() AT TIME ZONE 'UTC')::date - 4));
SELECT opairs.create_day_partition(((now() AT TIME ZONE 'UTC')::date - 3));
SELECT opairs.create_day_partition(((now() AT TIME ZONE 'UTC')::date - 2));

BEGIN;

DELETE FROM opairs.machine_data
 WHERE machine LIKE 'demo-%'
   AND ts >= date_trunc('minute', now() - interval '7 days');

WITH t AS (
    SELECT ts
      FROM generate_series(date_trunc('minute', now() - interval '7 days'),
                           now() - interval '10 seconds',
                           interval '10 seconds') ts
), m(machine, seed, rpm, down_pct) AS (
    VALUES ('demo-cnc-01', 1, 8000, 8), ('demo-cnc-02', 2, 6500, 15), ('demo-cnc-03', 3, 9500, 4)
), s AS (
    SELECT t.ts, m.machine, m.seed, m.rpm,
           extract(epoch FROM t.ts)::bigint AS e,
           extract(isodow FROM t.ts AT TIME ZONE 'UTC') < 6
             AND extract(hour FROM t.ts AT TIME ZONE 'UTC') BETWEEN 5 AND 20
             AND ((extract(epoch FROM t.ts)::bigint / 300) * 7919 + m.seed * 104729) % 100 >= m.down_pct
             AS running
      FROM t CROSS JOIN m
)
INSERT INTO opairs.machine_data (ts, machine, tag, value, value_text, quality)
SELECT s.ts, s.machine, v.tag, v.value, NULL, v.quality
  FROM s
 CROSS JOIN LATERAL (
    SELECT random() < 0.02 AS spike,
           abs(2 * ((s.e % 1200) / 1200.0) - 1) AS tri
 ) x
 CROSS JOIN LATERAL (VALUES
    ('state',             CASE WHEN s.running THEN 1 ELSE 0 END::double precision, 'Good'),
    ('spindle_speed_rpm', CASE WHEN s.running THEN round((s.rpm * (0.95 + 0.1 * random()))::numeric, 0)::double precision ELSE 0 END, 'Good'),
    ('temperature_c',     round((CASE WHEN s.running THEN 45 + 10 * x.tri + 2 * random()
                                      ELSE 26 + 2 * random() END)::numeric, 2)::double precision, 'Good'),
    ('power_kw',          round((CASE WHEN s.running THEN 7.5 * s.rpm / 8000.0 + 3 * random()
                                      ELSE 0.6 + 0.3 * random() END)::numeric, 2)::double precision, 'Good'),
    ('vibration_mm_s',    round((CASE WHEN NOT s.running THEN 0.2 * random()
                                      WHEN x.spike THEN 6 + 3 * random()
                                      ELSE 1.5 + random() END)::numeric, 2)::double precision,
                          CASE WHEN s.running AND x.spike THEN 'Uncertain 0x40900000' ELSE 'Good' END)
 ) v(tag, value, quality);

COMMIT;

-- Zeilen der Default-Partition einsortieren, dann Minutenwerte fuer den
-- ganzen Zeitraum berechnen (normale Wartung rechnet nur die letzten 2 h).
SELECT opairs.maintain_partitions(raw_retention => NULL);
SELECT opairs.aggregate_1min(lookback => interval '8 days', max_catchup => interval '8 days');

SELECT machine, count(*) AS zeilen, min(ts) AS von, max(ts) AS bis
  FROM opairs.machine_data WHERE machine LIKE 'demo-%' GROUP BY 1 ORDER BY 1;
