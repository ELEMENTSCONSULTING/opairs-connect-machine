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
