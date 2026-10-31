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
