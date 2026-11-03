-- Regressionstests fuer Schema, Wartung und Rollen.
-- Laeuft komplett in einer Transaktion und wird am Ende zurueckgerollt:
-- es bleiben keine Testdaten zurueck.
--
--   ./scripts/test-sql.sh            (gegen den laufenden Compose-Stack)

\set ON_ERROR_STOP on
BEGIN;

-- 1) Partitionen fuer gestern .. heute+7 existieren
DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n
      FROM pg_inherits i JOIN pg_class p ON p.oid = i.inhparent
     WHERE p.relname = 'machine_data' AND p.relnamespace = 'opairs'::regnamespace;
    IF n < 9 THEN RAISE EXCEPTION 'TEST 1: zu wenige Partitionen (%)', n; END IF;
END $$;

-- 2) Zeilen aus der Default-Partition werden beim Anlegen verschoben
DO $$
DECLARE d date := (now() AT TIME ZONE 'UTC')::date + 12;
BEGIN
    IF to_regclass('opairs.machine_data_' || to_char(d, 'YYYYMMDD')) IS NOT NULL THEN
        RAISE NOTICE 'TEST 2 uebersprungen: Partition existiert schon';
        RETURN;
    END IF;
    INSERT INTO opairs.machine_data (ts, machine, tag, value)
    VALUES (d::timestamp AT TIME ZONE 'UTC' + interval '1 hour', '__test__', 'default', 1);
    IF NOT EXISTS (SELECT 1 FROM opairs.machine_data_default WHERE machine = '__test__') THEN
        RAISE EXCEPTION 'TEST 2: Zeile ist nicht in der Default-Partition gelandet';
    END IF;
    PERFORM opairs.maintain_partitions(ahead_days => 13);
    IF EXISTS (SELECT 1 FROM opairs.machine_data_default WHERE machine = '__test__') THEN
        RAISE EXCEPTION 'TEST 2: Zeile wurde nicht verschoben';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM opairs.machine_data WHERE machine = '__test__' AND tag = 'default') THEN
        RAISE EXCEPTION 'TEST 2: Zeile ging beim Verschieben verloren';
    END IF;
END $$;

-- 2b) Ohne Aufbewahrungsfrist wird nichts geloescht (Schema-Start darf keine
--     Daten loeschen, auch wenn RAW_RETENTION_DAYS > 30 konfiguriert ist)
SELECT opairs.create_day_partition((now() AT TIME ZONE 'UTC')::date - 40);
SELECT opairs.maintain_partitions();
SELECT opairs.maintain_partitions(raw_retention => NULL);
DO $$
BEGIN
    IF to_regclass('opairs.machine_data_' || to_char((now() AT TIME ZONE 'UTC')::date - 40, 'YYYYMMDD')) IS NULL THEN
        RAISE EXCEPTION 'TEST 2b: Partition ohne Aufbewahrungsfrist geloescht';
    END IF;
END $$;

-- 2c) Default-Partition: Zeilen vergangener Tage bekommen eine Partition,
--     Zeilen vor dem Stichtag werden geloescht
DO $$
DECLARE
    d5  date := (now() AT TIME ZONE 'UTC')::date - 5;
    d60 date := (now() AT TIME ZONE 'UTC')::date - 60;
BEGIN
    IF to_regclass('opairs.machine_data_' || to_char(d5, 'YYYYMMDD')) IS NOT NULL
       OR to_regclass('opairs.machine_data_' || to_char(d60, 'YYYYMMDD')) IS NOT NULL THEN
        RAISE NOTICE 'TEST 2c uebersprungen: Partitionen existieren schon';
        RETURN;
    END IF;
    INSERT INTO opairs.machine_data (ts, machine, tag, value) VALUES
        (d5::timestamp  AT TIME ZONE 'UTC' + interval '12 hours', '__test__', 'late', 1),
        (d60::timestamp AT TIME ZONE 'UTC' + interval '12 hours', '__test__', 'ancient', 1);
    PERFORM opairs.maintain_partitions(raw_retention => interval '30 days');
    IF to_regclass('opairs.machine_data_' || to_char(d5, 'YYYYMMDD')) IS NULL THEN
        RAISE EXCEPTION 'TEST 2c: keine Partition fuer verspaeteten Tag angelegt';
    END IF;
    IF EXISTS (SELECT 1 FROM opairs.machine_data_default WHERE machine = '__test__') THEN
        RAISE EXCEPTION 'TEST 2c: Zeilen in der Default-Partition uebrig';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM opairs.machine_data WHERE machine = '__test__' AND tag = 'late') THEN
        RAISE EXCEPTION 'TEST 2c: verspaetete Zeile verloren';
    END IF;
    IF EXISTS (SELECT 1 FROM opairs.machine_data WHERE machine = '__test__' AND tag = 'ancient') THEN
        RAISE EXCEPTION 'TEST 2c: Zeile vor dem Stichtag nicht geloescht';
    END IF;
END $$;

-- 3) Alte Partitionen werden geloescht
CREATE TABLE opairs.machine_data_20200101 PARTITION OF opairs.machine_data
    FOR VALUES FROM ('2020-01-01 00:00+00') TO ('2020-01-02 00:00+00');
INSERT INTO opairs.machine_data (ts, machine, tag, value)
VALUES ('2020-01-01 12:00+00', '__test__', 'old', 1);
SELECT opairs.maintain_partitions(raw_retention => interval '30 days');
DO $$
BEGIN
    IF to_regclass('opairs.machine_data_20200101') IS NOT NULL THEN
        RAISE EXCEPTION 'TEST 3: alte Partition wurde nicht geloescht';
    END IF;
    IF to_regclass('opairs.machine_data_' || to_char((now() AT TIME ZONE 'UTC')::date - 40, 'YYYYMMDD')) IS NOT NULL THEN
        RAISE EXCEPTION 'TEST 3: 40 Tage alte Partition wurde nicht geloescht';
    END IF;
END $$;

-- 4) Aggregation ist wiederholbar (kein Doppelzaehlen), Zukunftswerte ignoriert
INSERT INTO opairs.machine_data (ts, machine, tag, value) VALUES
    (date_trunc('minute', now()) - interval '1 minute' + interval '10 seconds', '__test__', 'agg', 10),
    (date_trunc('minute', now()) - interval '1 minute' + interval '20 seconds', '__test__', 'agg', 20),
    (now() + interval '2 days', '__test__', 'future', 999);
SELECT opairs.aggregate_1min();
SELECT opairs.aggregate_1min();
DO $$
DECLARE c bigint; a double precision;
BEGIN
    SELECT sample_count, avg_value INTO c, a
      FROM opairs.machine_data_1min
     WHERE machine = '__test__' AND tag = 'agg';
    IF c IS DISTINCT FROM 2 OR a IS DISTINCT FROM 15 THEN
        RAISE EXCEPTION 'TEST 4: erwartet count=2 avg=15, erhalten count=% avg=%', c, a;
    END IF;
    IF EXISTS (SELECT 1 FROM opairs.machine_data_1min WHERE machine = '__test__' AND tag = 'future') THEN
        RAISE EXCEPTION 'TEST 4: Zukunftswert wurde aggregiert';
    END IF;
END $$;

-- 4b) Qualitaet: nur gute Werte in avg/min/max/sample_count, Rest in bad_count.
--     Kurzform aus der Pipeline und Langtext des Plugins werden erkannt.
INSERT INTO opairs.machine_data (ts, machine, tag, value, quality) VALUES
    (date_trunc('minute', now()) - interval '1 minute' + interval '1 second', '__test__', 'q', 10, 'Good'),
    (date_trunc('minute', now()) - interval '1 minute' + interval '2 seconds', '__test__', 'q', 20, 'The operation succeeded. StatusGood (0x0)'),
    (date_trunc('minute', now()) - interval '1 minute' + interval '3 seconds', '__test__', 'q', 30, NULL),
    (date_trunc('minute', now()) - interval '1 minute' + interval '4 seconds', '__test__', 'q', 999, 'Uncertain 0x40900000'),
    (date_trunc('minute', now()) - interval '1 minute' + interval '5 seconds', '__test__', 'q', 999, 'Whatever was updating this value has stopped doing so. StatusUncertainLastUsableValue (0x40900000)'),
    (date_trunc('minute', now()) - interval '1 minute' + interval '6 seconds', '__test__', 'q', 999, 'Bad 0x80340000'),
    (date_trunc('minute', now()) - interval '1 minute' + interval '7 seconds', '__test__', 'onlybad', 5, 'Bad 0x80340000');
SELECT opairs.aggregate_1min();
DO $$
DECLARE r record;
BEGIN
    SELECT * INTO r FROM opairs.machine_data_1min WHERE machine = '__test__' AND tag = 'q';
    IF r.sample_count IS DISTINCT FROM 3 OR r.bad_count IS DISTINCT FROM 3
       OR r.avg_value IS DISTINCT FROM 20 OR r.max_value IS DISTINCT FROM 30 THEN
        RAISE EXCEPTION 'TEST 4b: erwartet good=3 bad=3 avg=20 max=30, erhalten good=% bad=% avg=% max=%',
            r.sample_count, r.bad_count, r.avg_value, r.max_value;
    END IF;
    SELECT * INTO r FROM opairs.machine_data_1min WHERE machine = '__test__' AND tag = 'onlybad';
    IF r.sample_count IS DISTINCT FROM 0 OR r.bad_count IS DISTINCT FROM 1 OR r.avg_value IS NOT NULL THEN
        RAISE EXCEPTION 'TEST 4b: Minute nur mit schlechten Werten falsch: %', r;
    END IF;
END $$;

-- 4c) Zustaende je Minute und Zeitmodell (OEE)
--     Zustand alle 5 Minuten, Haltezeit 5 Minuten: 1, 3, 7, danach kein
--     Signal (0). Ein Zustand mit schlechter Qualitaet zaehlt nicht.
INSERT INTO opairs.asset (machine, werk, bereich, linie, tag_zustand, zustand_haltezeit,
                          tag_qualitaet, tag_taktzeit, soll_taktzeit_s)
VALUES ('__test_oee__', 'W', 'B', 'L', 'zs', interval '5 minutes', 'qi', 'tk', 9);
INSERT INTO opairs.machine_data (ts, machine, tag, value, quality)
SELECT date_trunc('minute', now()) - interval '30 minutes' + o, '__test_oee__', t, v, q
  FROM (VALUES (interval '10 seconds',             'zs', 1,  'Good'),
               (interval '3 minutes 30 seconds',   'zs', 3,  'Bad 0x80340000'),
               (interval '5 minutes 10 seconds',   'zs', 3,  'Good'),
               (interval '10 minutes 10 seconds',  'zs', 7,  'Good'),
               (interval '1 minute 5 seconds',     'tk', 10, 'Good'),
               (interval '2 minutes 5 seconds',    'qi', 1,  'Good'),
               (interval '2 minutes 6 seconds',    'qi', 0,  'Good'),
               (interval '2 days',                 'zs', 3,  'Good')) x(o, t, v, q);
SELECT opairs.aggregate_1min();
DO $$
DECLARE r record; n bigint;
BEGIN
    SELECT count(*) FILTER (WHERE state_code = 1) AS c1, count(*) FILTER (WHERE state_code = 3) AS c3,
           count(*) FILTER (WHERE state_code = 7) AS c7, count(*) FILTER (WHERE state_code = 0) AS c0,
           min(bucket) AS von
      INTO r FROM opairs.state_1min WHERE machine = '__test_oee__';
    IF (r.c1, r.c3, r.c7, r.c0) IS DISTINCT FROM (5::bigint, 5::bigint, 5::bigint, 16::bigint)
       OR r.von IS DISTINCT FROM date_trunc('minute', now()) - interval '30 minutes' THEN
        RAISE EXCEPTION 'TEST 4c: Zustaende falsch: %', r;
    END IF;

    SELECT sum(planbelegung_min) AS pb, sum(geplante_betriebszeit_min) AS gb,
           sum(nettobetriebszeit_min) AS nb, sum(produktion_min) AS pr,
           round(sum(nutzbar_min)::numeric, 6) AS nu, round(sum(nettoproduktiv_min)::numeric, 6) AS np,
           sum(unbekannt_min) AS unb, min(werk) AS werk
      INTO r FROM opairs.v_oee_1min WHERE machine = '__test_oee__';
    IF (r.pb, r.gb, r.nb, r.pr, r.nu, r.np, r.unb, r.werk)
       IS DISTINCT FROM (15::bigint, 10::bigint, 5::bigint, 5::bigint, 4.9, 4.4, 16::bigint, 'W') THEN
        RAISE EXCEPTION 'TEST 4c: Zeitmodell falsch: %', r;
    END IF;

    SELECT * INTO r FROM opairs.v_oee_taeglich WHERE machine = '__test_oee__' ORDER BY datum DESC LIMIT 1;
    IF r IS NULL OR r.oee IS NULL OR r.oee > 1 OR r.auslastung IS NULL THEN
        RAISE EXCEPTION 'TEST 4c: v_oee_taeglich ohne Kennzahlen: %', r;
    END IF;

    -- wiederholbar: zweiter Lauf aendert nichts
    n := opairs.aggregate_state_1min();
    IF n <> 0 THEN
        RAISE EXCEPTION 'TEST 4c: zweiter Lauf aendert % Zeilen', n;
    END IF;

    -- gueltig_ab: davor keine Zeilen mehr
    UPDATE opairs.asset SET gueltig_ab = date_trunc('minute', now()) - interval '10 minutes'
     WHERE machine = '__test_oee__';
    PERFORM opairs.aggregate_state_1min();
    SELECT count(*) INTO n FROM opairs.state_1min WHERE machine = '__test_oee__';
    IF n <> 11 THEN
        RAISE EXCEPTION 'TEST 4c: nach gueltig_ab erwartet 11 Minuten, erhalten %', n;
    END IF;

    -- Aufbewahrung gilt auch fuer Minutenzustaende
    INSERT INTO opairs.state_1min (machine, bucket, state_code) VALUES ('__test_oee__', '2020-01-01 00:00+00', 1);
    PERFORM opairs.purge_aggregates(interval '400 days');
    IF EXISTS (SELECT 1 FROM opairs.state_1min WHERE machine = '__test_oee__' AND bucket < '2021-01-01') THEN
        RAISE EXCEPTION 'TEST 4c: alter Minutenzustand nicht geloescht';
    END IF;
END $$;

-- 4d) Vorgegebene Zustandscodes vorhanden, Signalbeschreibung mit Vorrang
DO $$
DECLARE e text;
BEGIN
    IF (SELECT count(*) FROM opairs.state_def WHERE state_code BETWEEN 0 AND 8) <> 9 THEN
        RAISE EXCEPTION 'TEST 4d: Zustandscodes 0-8 fehlen';
    END IF;
    INSERT INTO opairs.tag_meta (machine, tag, einheit) VALUES ('*', '__t__', 'a'), ('__test_oee__', '__t__', 'b');
    SELECT einheit INTO e FROM opairs.v_tag_meta WHERE machine = '__test_oee__' AND tag = '__t__';
    IF e IS DISTINCT FROM 'b' THEN
        RAISE EXCEPTION 'TEST 4d: anlagenspezifische Signalbeschreibung ohne Vorrang (%)', e;
    END IF;
END $$;

-- 5) Rollen: Writer darf nur einfuegen, Reader nur lesen
SET ROLE opairs_writer;
INSERT INTO opairs.machine_data (ts, machine, tag, value) VALUES (now(), '__test__', 'writer', 1);
DO $$
BEGIN
    PERFORM count(*) FROM opairs.machine_data;
    RAISE EXCEPTION 'TEST 5: Writer darf lesen';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;
RESET ROLE;

SET ROLE opairs_reader;
SELECT count(*) FROM opairs.machine_data;
SELECT count(*) FROM opairs.machine_data_1min;
SELECT count(*) FROM opairs.v_latest_1min;
SELECT count(*) FROM opairs.v_latest_1min_ctx;
SELECT count(*) FROM opairs.v_machine_data_1min_ctx WHERE bucket > now() - interval '1 hour';
SELECT count(*) FROM opairs.v_machine_data_ctx WHERE ts > now() - interval '1 hour';
SELECT count(*) FROM opairs.v_anlage;
SELECT count(*) FROM opairs.v_tag_meta;
SELECT count(*) FROM opairs.v_oee_1min WHERE bucket > now() - interval '1 day';
SELECT count(*) FROM opairs.v_oee_taeglich WHERE datum > current_date - 2;
DO $$
BEGIN
    INSERT INTO opairs.machine_data (ts, machine, tag, value) VALUES (now(), '__test__', 'reader', 1);
    RAISE EXCEPTION 'TEST 5: Reader darf schreiben';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;
RESET ROLE;

-- 6) Komplettlauf
SELECT opairs.run_maintenance();

ROLLBACK;
\echo 'SQL-Tests: OK'
