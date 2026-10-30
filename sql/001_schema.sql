-- OPAIRS Connect: Schema fuer Maschinendaten
-- Reines PostgreSQL (keine Erweiterungen, insbesondere kein TimescaleDB).
-- Wird beim ersten Start der Datenbank automatisch ausgefuehrt
-- (Postgres-Image: /docker-entrypoint-initdb.d).

CREATE SCHEMA IF NOT EXISTS opairs;

-- Rohdaten: schmale Tabelle, partitioniert nach Zeit (taeglich).
--   value      numerische Werte (Bool wird als 1/0 gespeichert)
--   value_text Werte, die keine Zahl sind (Text, JSON)
--   quality    Qualitaetsangabe der Quelle (z. B. OPC-UA-Statuscode)
CREATE TABLE IF NOT EXISTS opairs.machine_data (
    ts         timestamptz      NOT NULL,
    machine    text             NOT NULL,
    tag        text             NOT NULL,
    value      double precision,
    value_text text,
    quality    text
) PARTITION BY RANGE (ts);

-- Sicherheitsnetz: faengt Zeilen auf, falls fuer einen Tag noch keine
-- Partition existiert (z. B. weil der Wartungsjob ausgefallen ist).
CREATE TABLE IF NOT EXISTS opairs.machine_data_default
    PARTITION OF opairs.machine_data DEFAULT;

CREATE INDEX IF NOT EXISTS machine_data_machine_tag_ts_idx
    ON opairs.machine_data (machine, tag, ts DESC);

-- Aggregat fuer Dashboards (Minutenwerte), laenger aufbewahrt als Rohdaten.
CREATE TABLE IF NOT EXISTS opairs.machine_data_1min (
    bucket       timestamptz      NOT NULL,
    machine      text             NOT NULL,
    tag          text             NOT NULL,
    avg_value    double precision,
    min_value    double precision,
    max_value    double precision,
    sample_count bigint           NOT NULL,
    PRIMARY KEY (machine, tag, bucket)
);

-- Partitionen im Voraus anlegen und alte Rohdaten-Partitionen loeschen.
CREATE OR REPLACE FUNCTION opairs.maintain_partitions(
    ahead_days    integer  DEFAULT 7,
    raw_retention interval DEFAULT interval '30 days'
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    today     date := (now() AT TIME ZONE 'UTC')::date;
    cutoff    date := ((now() - raw_retention) AT TIME ZONE 'UTC')::date;
    d         date;
    part_name text;
    lo        timestamptz;
    hi        timestamptz;
    r         record;
BEGIN
    -- 1) Partitionen fuer gestern bis heute + ahead_days anlegen.
    FOR i IN -1..ahead_days LOOP
        d := today + i;
        part_name := 'machine_data_' || to_char(d, 'YYYYMMDD');

        IF to_regclass(format('opairs.%I', part_name)) IS NULL THEN
            lo := d::timestamp AT TIME ZONE 'UTC';
            hi := (d + 1)::timestamp AT TIME ZONE 'UTC';

            -- Zeilen, die schon in der Default-Partition liegen, muessen
            -- vor dem Anlegen verschoben werden (sonst lehnt Postgres ab).
            IF to_regclass('pg_temp._opairs_moved') IS NULL THEN
                CREATE TEMP TABLE _opairs_moved
                    (LIKE opairs.machine_data) ON COMMIT DROP;
            ELSE
                TRUNCATE _opairs_moved;
            END IF;

            WITH m AS (
                DELETE FROM opairs.machine_data_default
                 WHERE ts >= lo AND ts < hi
                RETURNING *
            )
            INSERT INTO _opairs_moved SELECT * FROM m;

            EXECUTE format(
                'CREATE TABLE opairs.%I PARTITION OF opairs.machine_data '
                'FOR VALUES FROM (%L) TO (%L)', part_name, lo, hi);

            INSERT INTO opairs.machine_data SELECT * FROM _opairs_moved;
            TRUNCATE _opairs_moved;
        END IF;
    END LOOP;

    -- 2) Rohdaten-Partitionen loeschen, die komplett vor dem Stichtag liegen.
    FOR r IN
        SELECT c.relname
          FROM pg_inherits i
          JOIN pg_class c     ON c.oid = i.inhrelid
          JOIN pg_class p     ON p.oid = i.inhparent
          JOIN pg_namespace n ON n.oid = p.relnamespace
         WHERE n.nspname = 'opairs'
           AND p.relname = 'machine_data'
           AND c.relname ~ '^machine_data_[0-9]{8}$'
    LOOP
        IF to_date(substr(r.relname, 14), 'YYYYMMDD') < cutoff THEN
            EXECUTE format('DROP TABLE opairs.%I', r.relname);
        END IF;
    END LOOP;
END;
$$;

-- Minutenwerte aus den Rohdaten (idempotent, ueberschreibt die letzten
-- lookback Minuten). Voraussetzung: Rohdaten-Aufbewahrung > lookback.
CREATE OR REPLACE FUNCTION opairs.aggregate_1min(
    lookback interval DEFAULT interval '2 hours'
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    n bigint;
BEGIN
    INSERT INTO opairs.machine_data_1min
           (bucket, machine, tag, avg_value, min_value, max_value, sample_count)
    SELECT date_trunc('minute', ts), machine, tag,
           avg(value), min(value), max(value), count(*)
      FROM opairs.machine_data
     WHERE ts >= date_trunc('minute', now() - lookback)
       AND value IS NOT NULL
     GROUP BY 1, 2, 3
    ON CONFLICT (machine, tag, bucket) DO UPDATE
       SET avg_value    = EXCLUDED.avg_value,
           min_value    = EXCLUDED.min_value,
           max_value    = EXCLUDED.max_value,
           sample_count = EXCLUDED.sample_count;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END;
$$;

-- Alles in einem Aufruf (wird vom Wartungs-Container alle 5 Minuten ausgefuehrt).
CREATE OR REPLACE FUNCTION opairs.run_maintenance(
    raw_retention_days  integer DEFAULT 30,
    agg_retention_days  integer DEFAULT 400,
    ahead_days          integer DEFAULT 7,
    agg_lookback_minutes integer DEFAULT 120
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM opairs.maintain_partitions(ahead_days, make_interval(days => raw_retention_days));
    PERFORM opairs.aggregate_1min(make_interval(mins => agg_lookback_minutes));
    DELETE FROM opairs.machine_data_1min
     WHERE bucket < now() - make_interval(days => agg_retention_days);
END;
$$;

-- Erste Partitionen sofort anlegen, damit der Connector ab dem Start schreiben kann.
SELECT opairs.maintain_partitions();
