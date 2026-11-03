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
-- Maschinenzustand "state_code" nach opairs.state_def, Grund als Text in
-- "status". "state" bleibt 1 = Produktion, sonst 0.
--   CNC         8 ausserhalb der Schicht, 5 Wartung cnc-02 Mi 06:00-08:00,
--               4 Ruesten cnc-03 13:00-13:20, 3 Stoerung, 2 wartet auf Material
--   Spritzguss  8 am Wochenende, 4 Produktwechsel sgm-02 05:00-05:45,
--               6 Reinigung sgm-02 Fr 19:00-20:00, 3 Stoerung,
--               2 sgm-01 wartet auf Entnahme
--   Montage     8 ausserhalb der Schicht, 7 Pause, 6 Reinigung mon-02
--               20:45-21:00, 5 Wartung mon-04 Di 05:00-06:00, 4 Typwechsel
--               mon-01 11:00-11:15, 3 Stoerung, 2 kein Material
-- Am letzten Werktag vor gestern liefert demo-cnc-03 von 10:00 bis 11:00
-- keine Daten (Verbindung unterbrochen): ab 10:14 Zustand 0 "Unbekannt".
--
-- Wiederholbar: vorhandene Demo-Daten im Zeitraum werden vorher geloescht.
\set ON_ERROR_STOP on

\ir demo_stammdaten.sql

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
       extract(isodow FROM ts AT TIME ZONE 'UTC')::int        AS dow,
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
), s0 AS MATERIALIZED (
    -- MATERIALIZED: random() je Zeile genau einmal (Wert und Qualitaet passen zusammen)
    SELECT t.*, m.machine, m.rpm,
           CASE WHEN NOT (t.weekday AND t.hm BETWEEN 300 AND 1259)                    THEN 8
                WHEN m.machine = 'demo-cnc-02' AND t.dow = 3 AND t.hm >= 360 AND t.hm < 480 THEN 5
                WHEN m.machine = 'demo-cnc-03' AND t.hm >= 780 AND t.hm < 800          THEN 4
                WHEN (t.block * 7919 + m.seed * 104729) % 100 < m.down_pct            THEN 3
                WHEN (t.block * 7919 + m.seed * 104729) % 100 < m.down_pct + 5        THEN 2
                ELSE 1 END AS code,
           random() < 0.02 AS spike
      FROM _demo_t t CROSS JOIN m
), s AS (
    SELECT s0.*, s0.code = 1 AS running FROM s0
)
INSERT INTO opairs.machine_data (ts, machine, tag, value, value_text, quality)
SELECT s.ts, s.machine, v.tag, v.value, v.txt, v.quality
  FROM s
 CROSS JOIN LATERAL (VALUES
    ('state',             CASE WHEN s.running THEN 1 ELSE 0 END::double precision, 'Good', NULL),
    ('state_code',        s.code::double precision, 'Good', NULL),
    ('status',            NULL, 'Good', CASE s.code WHEN 8 THEN 'Keine Schicht' WHEN 5 THEN 'Wartung geplant'
                                              WHEN 4 THEN 'Ruesten Auftragswechsel' WHEN 3 THEN 'Stoerung'
                                              WHEN 2 THEN 'Wartet auf Material' ELSE 'Produktion' END),
    ('spindle_speed_rpm', CASE WHEN s.running THEN round((s.rpm * (0.95 + 0.1 * random()))::numeric, 0)::double precision ELSE 0 END, 'Good', NULL),
    ('temperature_c',     round((CASE WHEN s.running THEN 45 + 10 * s.tri20 + 2 * random()
                                      ELSE 26 + 2 * random() END)::numeric, 2)::double precision, 'Good', NULL),
    ('power_kw',          round((CASE WHEN s.running THEN 7.5 * s.rpm / 8000.0 + 3 * random()
                                      ELSE 0.6 + 0.3 * random() END)::numeric, 2)::double precision, 'Good', NULL),
    ('vibration_mm_s',    round((CASE WHEN NOT s.running THEN 0.2 * random()
                                      WHEN s.spike THEN 6 + 3 * random()
                                      ELSE 1.5 + random() END)::numeric, 2)::double precision,
                          CASE WHEN s.running AND s.spike THEN 'Uncertain 0x40900000' ELSE 'Good' END, NULL)
 ) v(tag, value, quality, txt);

------------------------------------------------------------------------
-- Spritzguss
------------------------------------------------------------------------
WITH m(machine, seed, down_pct) AS (
    VALUES ('demo-sgm-01', 4, 5), ('demo-sgm-02', 5, 10)
), s AS MATERIALIZED (
    SELECT t.*, m.machine,
           CASE WHEN NOT t.weekday                                                        THEN 8
                WHEN m.machine = 'demo-sgm-02' AND t.hm BETWEEN 300 AND 344                 THEN 4
                WHEN m.machine = 'demo-sgm-02' AND t.dow = 5 AND t.hm >= 1140 AND t.hm < 1200 THEN 6
                WHEN (t.block * 7919 + m.seed * 104729) % 100 < m.down_pct                 THEN 3
                WHEN m.machine = 'demo-sgm-01' AND (t.block * 7919 + m.seed * 104729) % 100 < m.down_pct + 3 THEN 2
                ELSE 1 END AS code,
           -- Werkzeug: sgm-01 fest, sgm-02 wechselt taeglich
           CASE WHEN m.machine = 'demo-sgm-01' THEN 'WZ-1001 Gehaeuse 4-fach'
                WHEN t.day % 2 = 0             THEN 'WZ-2002 Deckel 2-fach'
                ELSE                                'WZ-2003 Clip 8-fach' END AS werkzeug,
           CASE WHEN m.machine = 'demo-sgm-01' THEN 4  WHEN t.day % 2 = 0 THEN 2  ELSE 8  END AS kavitaeten,
           CASE WHEN m.machine = 'demo-sgm-01' THEN 28 WHEN t.day % 2 = 0 THEN 22 ELSE 16 END AS zyklus,
           CASE WHEN m.machine = 'demo-sgm-01' THEN 27 WHEN t.day % 2 = 0 THEN 21 ELSE 15.5 END AS soll_zyklus,
           2 * random() - 1 AS u1, 2 * random() - 1 AS u2, 2 * random() - 1 AS u3, 2 * random() - 1 AS u4,
           random() AS s1, random() AS s2
      FROM _demo_t t CROSS JOIN m
), c AS MATERIALIZED (
    SELECT s.*,
           s.code = 1 AS running,
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
    ('state_code',           d.code::double precision, NULL),
    ('status',               NULL, CASE d.code WHEN 8 THEN 'Keine Schicht' WHEN 4 THEN 'Werkzeugwechsel'
                                        WHEN 6 THEN 'Reinigung' WHEN 3 THEN 'Stoerung'
                                        WHEN 2 THEN 'Wartet auf Entnahme' ELSE 'Produktion' END),
    ('werkzeug',             NULL, d.werkzeug),
    ('kavitaeten',           d.kavitaeten::double precision, NULL),
    ('zykluszeit_s',         CASE WHEN d.running THEN round((d.zyklus * (1 + 0.01 * d.u1))::numeric, 2)::double precision END, NULL),
    ('soll_zykluszeit_s',    d.soll_zyklus::double precision, NULL),
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
           CASE WHEN NOT (t.weekday AND t.hm BETWEEN 300 AND 1259)                       THEN 8
                WHEN (t.hm >= 540 AND t.hm < 555) OR (t.hm >= 780 AND t.hm < 810)         THEN 7
                WHEN m.machine = 'demo-mon-02' AND t.hm >= 1245 AND t.hm < 1260            THEN 6
                WHEN m.machine = 'demo-mon-04' AND t.dow = 2 AND t.hm >= 300 AND t.hm < 360 THEN 5
                WHEN m.machine = 'demo-mon-01' AND t.hm >= 660 AND t.hm < 675              THEN 4
                WHEN (t.block * 7919 + m.seed * 104729) % 100 < m.down_pct               THEN 3
                WHEN (t.block * 7919 + m.seed * 104729) % 100 < m.down_pct + 5           THEN 2
                ELSE 1 END AS code,
           2 * random() - 1 AS u1, 2 * random() - 1 AS u2, 2 * random() - 1 AS u3,
           random() AS s1, random() AS s2, random() AS s3
      FROM _demo_t t CROSS JOIN m
), c AS MATERIALIZED (
    SELECT s.*,
           s.code = 1 AS running,
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
    ('state_code',     d.code::double precision, NULL),
    ('status',         NULL, CASE d.code WHEN 8 THEN 'Keine Schicht' WHEN 7 THEN 'Pause'
                                  WHEN 6 THEN 'Reinigung Pruefkammer' WHEN 5 THEN 'Wartung Kamera'
                                  WHEN 4 THEN 'Typwechsel' WHEN 3 THEN 'Stoerung'
                                  WHEN 2 THEN 'Kein Material' ELSE 'Produktion' END),
    ('taktzeit_s',     CASE WHEN d.running THEN round((d.takt * (1 + 0.03 * d.u3))::numeric, 2)::double precision END, NULL),
    ('pruef_ergebnis', CASE WHEN d.running THEN CASE WHEN d.nio_grund IS NULL THEN 1 ELSE 0 END END::double precision, NULL),
    (d.tag1,           CASE WHEN d.running THEN round(d.m1::numeric, 3)::double precision END, NULL),
    (d.tag2,           CASE WHEN d.running THEN round(d.m2::numeric, 3)::double precision END, NULL)
 ) v(tag, value, txt);

-- Verbindungsabbruch: demo-cnc-03 am letzten Werktag vor gestern
-- 10:00-11:00 ohne Daten
DELETE FROM opairs.machine_data
 WHERE machine = 'demo-cnc-03'
   AND ts >= (SELECT max(d) FROM generate_series((now() AT TIME ZONE 'UTC')::date - 6,
                                                 (now() AT TIME ZONE 'UTC')::date - 2, interval '1 day') d
               WHERE extract(isodow FROM d) < 6)::timestamp AT TIME ZONE 'UTC' + interval '10 hours'
   AND ts <  (SELECT max(d) FROM generate_series((now() AT TIME ZONE 'UTC')::date - 6,
                                                 (now() AT TIME ZONE 'UTC')::date - 2, interval '1 day') d
               WHERE extract(isodow FROM d) < 6)::timestamp AT TIME ZONE 'UTC' + interval '11 hours';

COMMIT;

-- Zeilen der Default-Partition einsortieren, dann Minutenwerte fuer den
-- ganzen Zeitraum berechnen (normale Wartung rechnet nur die letzten 2 h),
-- einschliesslich der Zustaende je Minute (opairs.state_1min).
SELECT opairs.maintain_partitions(raw_retention => NULL);
SELECT opairs.aggregate_1min(lookback => interval '8 days', max_catchup => interval '8 days');

SELECT machine, count(*) AS zeilen, min(ts) AS von, max(ts) AS bis
  FROM opairs.machine_data WHERE machine LIKE 'demo-%' GROUP BY 1 ORDER BY 1;
