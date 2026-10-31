-- Demo-Daten: 7 Tage Historie, ein Wert je Tag alle 10 Sekunden.
-- Gleiches Muster wie die Live-Pipeline pipelines/demo-anlage.yaml.
--
--   ./scripts/demo.sh backfill
--
-- Anlagen (Details in README, Abschnitt "Demo-Daten"):
--   demo-cnc-01..03   CNC-Bearbeitung, 2 Schichten
--   demo-sgm-01..02   Spritzguss, Mo-Fr rund um die Uhr, Werkzeugdaten,
--                     sgm-02 mit taeglichem Werkzeugwechsel (Ruesten 05:00-05:45)
--   demo-mon-01       Montage: Schraubstation (Drehmoment, Drehwinkel)
--   demo-mon-02       Montage: Dichtheitspruefung (Pruefdruck, Leckrate)
--   demo-mon-03       Montage: Einpressstation (Kraft, Weg)
--   demo-mon-04       Montage: Endpruefung (Isolationswiderstand, Kamera)
--
-- Zeiten in UTC. Schicht Mo-Fr 05:00-21:00, Montage mit Pausen
-- 09:00-09:15 und 13:00-13:30. Stoerungen als 5-Minuten-Bloecke.
-- Pruefergebnis: value 1 = iO, 0 = NiO (Mittelwert = iO-Quote);
-- NiO-Grund als Text im Tag "nio_grund" (nur bei NiO).
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

-- Zeitraster mit den Kalendergroessen, die alle Anlagen brauchen
CREATE TEMP TABLE _demo_t ON COMMIT DROP AS
SELECT ts,
       extract(epoch FROM ts)::bigint                        AS e,
       extract(isodow FROM ts AT TIME ZONE 'UTC') < 6         AS weekday,
       (extract(hour FROM ts AT TIME ZONE 'UTC') * 60
        + extract(minute FROM ts AT TIME ZONE 'UTC'))::int   AS hm,
       extract(epoch FROM ts)::bigint / 300                  AS block,
       extract(epoch FROM ts)::bigint / 86400                AS day,
       abs(2 * ((extract(epoch FROM ts)::bigint % 1200) / 1200.0) - 1)   AS tri20,
       abs(2 * ((extract(epoch FROM ts)::bigint % 86400) / 86400.0) - 1) AS triday
  FROM generate_series(date_trunc('minute', now() - interval '7 days'),
                       now() - interval '10 seconds',
                       interval '10 seconds') ts;

------------------------------------------------------------------------
-- CNC-Bearbeitung
------------------------------------------------------------------------
WITH m(machine, seed, rpm, down_pct) AS (
    VALUES ('demo-cnc-01', 1, 8000, 8), ('demo-cnc-02', 2, 6500, 15), ('demo-cnc-03', 3, 9500, 4)
), s AS (
    SELECT t.*, m.machine, m.rpm,
           t.weekday AND t.hm BETWEEN 300 AND 1259
             AND (t.block * 7919 + m.seed * 104729) % 100 >= m.down_pct AS running
      FROM _demo_t t CROSS JOIN m
)
INSERT INTO opairs.machine_data (ts, machine, tag, value, value_text, quality)
SELECT s.ts, s.machine, v.tag, v.value, NULL, v.quality
  FROM s
 CROSS JOIN LATERAL (SELECT random() < 0.02 AS spike) x
 CROSS JOIN LATERAL (VALUES
    ('state',             CASE WHEN s.running THEN 1 ELSE 0 END::double precision, 'Good'),
    ('spindle_speed_rpm', CASE WHEN s.running THEN round((s.rpm * (0.95 + 0.1 * random()))::numeric, 0)::double precision ELSE 0 END, 'Good'),
    ('temperature_c',     round((CASE WHEN s.running THEN 45 + 10 * s.tri20 + 2 * random()
                                      ELSE 26 + 2 * random() END)::numeric, 2)::double precision, 'Good'),
    ('power_kw',          round((CASE WHEN s.running THEN 7.5 * s.rpm / 8000.0 + 3 * random()
                                      ELSE 0.6 + 0.3 * random() END)::numeric, 2)::double precision, 'Good'),
    ('vibration_mm_s',    round((CASE WHEN NOT s.running THEN 0.2 * random()
                                      WHEN x.spike THEN 6 + 3 * random()
                                      ELSE 1.5 + random() END)::numeric, 2)::double precision,
                          CASE WHEN s.running AND x.spike THEN 'Uncertain 0x40900000' ELSE 'Good' END)
 ) v(tag, value, quality);

------------------------------------------------------------------------
-- Spritzguss
------------------------------------------------------------------------
WITH m(machine, seed, down_pct) AS (
    VALUES ('demo-sgm-01', 4, 5), ('demo-sgm-02', 5, 10)
), s AS MATERIALIZED (
    SELECT t.*, m.machine,
           t.weekday AND m.machine = 'demo-sgm-02' AND t.hm BETWEEN 300 AND 344 AS ruesten,
           (t.block * 7919 + m.seed * 104729) % 100 < m.down_pct              AS stoerung,
           -- Werkzeug: sgm-01 fest, sgm-02 wechselt taeglich
           CASE WHEN m.machine = 'demo-sgm-01' THEN 'WZ-1001 Gehaeuse 4-fach'
                WHEN t.day % 2 = 0             THEN 'WZ-2002 Deckel 2-fach'
                ELSE                                'WZ-2003 Clip 8-fach' END AS werkzeug,
           CASE WHEN m.machine = 'demo-sgm-01' THEN 4  WHEN t.day % 2 = 0 THEN 2  ELSE 8  END AS kavitaeten,
           CASE WHEN m.machine = 'demo-sgm-01' THEN 28 WHEN t.day % 2 = 0 THEN 22 ELSE 16 END AS zyklus,
           2 * random() - 1 AS u1, 2 * random() - 1 AS u2, 2 * random() - 1 AS u3, 2 * random() - 1 AS u4,
           random() AS s1, random() AS s2
      FROM _demo_t t CROSS JOIN m
), c AS MATERIALIZED (
    SELECT s.*,
           s.weekday AND NOT s.ruesten AND NOT s.stoerung AS running,
           850 + 25 * s.u4 + CASE WHEN s.s1 < 0.02 THEN 120 ELSE 0 END AS druck
      FROM s
), d AS MATERIALIZED (
    SELECT c.*,
           CASE WHEN NOT c.running THEN NULL
                WHEN c.druck NOT BETWEEN 790 AND 910 THEN 'Einspritzdruck ausserhalb'
                WHEN c.s2 < 0.01 THEN 'Sichtpruefung: Grat'
           END AS nio_grund
      FROM c
), nio AS (
    INSERT INTO opairs.machine_data (ts, machine, tag, value, value_text, quality)
    SELECT ts, machine, 'nio_grund', NULL, nio_grund, 'Good' FROM d WHERE nio_grund IS NOT NULL
)
INSERT INTO opairs.machine_data (ts, machine, tag, value, value_text, quality)
SELECT d.ts, d.machine, v.tag, v.value, v.txt, 'Good'
  FROM d
 CROSS JOIN LATERAL (VALUES
    ('state',                CASE WHEN d.running THEN 1 ELSE 0 END::double precision, NULL),
    ('status',               NULL, CASE WHEN NOT d.weekday THEN 'Stillstand' WHEN d.ruesten THEN 'Ruesten'
                                        WHEN d.stoerung THEN 'Stoerung' ELSE 'Produktion' END),
    ('werkzeug',             NULL, d.werkzeug),
    ('kavitaeten',           d.kavitaeten::double precision, NULL),
    ('zykluszeit_s',         CASE WHEN d.running THEN round((d.zyklus * (1 + 0.01 * d.u1))::numeric, 2)::double precision END, NULL),
    ('massetemperatur_c',    round((CASE WHEN d.running THEN 230 + 3 * d.u2
                                         WHEN d.weekday THEN 220 + 2 * d.u2
                                         ELSE 40 + 2 * d.u2 END)::numeric, 1)::double precision, NULL),
    ('werkzeugtemperatur_c', round((CASE WHEN d.running THEN 60 + 1.5 * d.u3
                                              + CASE WHEN d.machine = 'demo-sgm-01' THEN 4 * d.triday ELSE 0 END
                                         WHEN d.weekday THEN 50 + d.u3
                                         ELSE 25 + d.u3 END)::numeric, 1)::double precision, NULL),
    ('einspritzdruck_bar',   CASE WHEN d.running THEN round(d.druck::numeric, 0)::double precision END, NULL),
    ('teil_io',              CASE WHEN d.running THEN CASE WHEN d.nio_grund IS NULL THEN 1 ELSE 0 END END::double precision, NULL)
 ) v(tag, value, txt);

------------------------------------------------------------------------
-- Montage
------------------------------------------------------------------------
WITH m(machine, seed, down_pct, takt, tag1, tag2) AS (
    VALUES ('demo-mon-01', 6, 6,  18, 'schraub_drehmoment_nm',     'schraub_drehwinkel_grad'),
           ('demo-mon-02', 7, 10, 25, 'pruefdruck_bar',            'leckrate_ccm_min'),
           ('demo-mon-03', 8, 4,  12, 'einpresskraft_kn',          'einpressweg_mm'),
           ('demo-mon-04', 9, 8,  30, 'isolationswiderstand_mohm', 'kamera_io')
), s AS MATERIALIZED (
    SELECT t.*, m.*,
           t.weekday AND t.hm BETWEEN 300 AND 1259                         AS schicht,
           (t.hm >= 540 AND t.hm < 555) OR (t.hm >= 780 AND t.hm < 810)    AS pause,
           (t.block * 7919 + m.seed * 104729) % 100 < m.down_pct           AS stoerung,
           2 * random() - 1 AS u1, 2 * random() - 1 AS u2, 2 * random() - 1 AS u3,
           random() AS s1, random() AS s2, random() AS s3
      FROM _demo_t t CROSS JOIN m
), c AS MATERIALIZED (
    SELECT s.*,
           s.schicht AND NOT s.pause AND NOT s.stoerung AS running,
           CASE s.machine
             -- Schrauber: Drehmoment steigt ueber die Schicht (Bit-Verschleiss, Wechsel zu
             -- Schichtbeginn), gegen Schichtende mehr NiO; selten fehlende Schraube
             WHEN 'demo-mon-01' THEN 4.45 + 0.08 * s.u1 + 0.3 * greatest(0, s.hm - 300) / 960.0
                                     + CASE WHEN s.s1 < 0.01 THEN -0.6 ELSE 0 END
             WHEN 'demo-mon-02' THEN 2.0 + 0.02 * s.u1
             WHEN 'demo-mon-03' THEN 8.0 + 0.3 * s.u1 + CASE WHEN s.s1 < 0.015 THEN 1.2 ELSE 0 END
             WHEN 'demo-mon-04' THEN CASE WHEN s.s1 < 0.01 THEN 40 + 30 * s.s3 ELSE 500 + 80 * s.u1 END
           END AS m1,
           CASE s.machine
             WHEN 'demo-mon-01' THEN 720 + 15 * s.u2 + CASE WHEN s.s2 < 0.005 THEN -200 ELSE 0 END
             WHEN 'demo-mon-02' THEN 0.6 + 0.3 * s.u2 + CASE WHEN s.s2 < 0.03 THEN 3 + 3 * s.s3 ELSE 0 END
             WHEN 'demo-mon-03' THEN 12.0 + 0.05 * s.u2 + CASE WHEN s.s2 < 0.01 THEN -0.3 ELSE 0 END
             WHEN 'demo-mon-04' THEN CASE WHEN s.s2 < 0.02 THEN 0 ELSE 1 END
           END AS m2
      FROM s
), d AS MATERIALIZED (
    SELECT c.*,
           CASE WHEN NOT c.running THEN NULL
                WHEN c.machine = 'demo-mon-01' AND c.m1 NOT BETWEEN 4.2 AND 4.8    THEN 'Drehmoment ausserhalb'
                WHEN c.machine = 'demo-mon-01' AND c.m2 NOT BETWEEN 680 AND 760    THEN 'Drehwinkel ausserhalb'
                WHEN c.machine = 'demo-mon-02' AND c.m2 > 2.0                      THEN 'Undicht'
                WHEN c.machine = 'demo-mon-03' AND c.m1 NOT BETWEEN 7.2 AND 8.8    THEN 'Einpresskraft ausserhalb'
                WHEN c.machine = 'demo-mon-03' AND c.m2 NOT BETWEEN 11.85 AND 12.15 THEN 'Einpressweg ausserhalb'
                WHEN c.machine = 'demo-mon-04' AND c.m1 < 100                      THEN 'Isolation zu gering'
                WHEN c.machine = 'demo-mon-04' AND c.m2 = 0                        THEN 'Kamera: Etikett fehlt'
           END AS nio_grund
      FROM c
), nio AS (
    INSERT INTO opairs.machine_data (ts, machine, tag, value, value_text, quality)
    SELECT ts, machine, 'nio_grund', NULL, nio_grund, 'Good' FROM d WHERE nio_grund IS NOT NULL
)
INSERT INTO opairs.machine_data (ts, machine, tag, value, value_text, quality)
SELECT d.ts, d.machine, v.tag, v.value, v.txt, 'Good'
  FROM d
 CROSS JOIN LATERAL (VALUES
    ('state',          CASE WHEN d.running THEN 1 ELSE 0 END::double precision, NULL),
    ('status',         NULL, CASE WHEN NOT d.schicht THEN 'Stillstand' WHEN d.pause THEN 'Pause'
                                  WHEN d.stoerung THEN 'Stoerung' ELSE 'Produktion' END),
    ('taktzeit_s',     CASE WHEN d.running THEN round((d.takt * (1 + 0.03 * d.u3))::numeric, 2)::double precision END, NULL),
    ('pruef_ergebnis', CASE WHEN d.running THEN CASE WHEN d.nio_grund IS NULL THEN 1 ELSE 0 END END::double precision, NULL),
    (d.tag1,           CASE WHEN d.running THEN round(d.m1::numeric, 3)::double precision END, NULL),
    (d.tag2,           CASE WHEN d.running THEN round(d.m2::numeric, 3)::double precision END, NULL)
 ) v(tag, value, txt);

COMMIT;

-- Zeilen der Default-Partition einsortieren, dann Minutenwerte fuer den
-- ganzen Zeitraum berechnen (normale Wartung rechnet nur die letzten 2 h).
SELECT opairs.maintain_partitions(raw_retention => NULL);
SELECT opairs.aggregate_1min(lookback => interval '8 days', max_catchup => interval '8 days');

SELECT machine, count(*) AS zeilen, min(ts) AS von, max(ts) AS bis
  FROM opairs.machine_data WHERE machine LIKE 'demo-%' GROUP BY 1 ORDER BY 1;
