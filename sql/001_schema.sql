-- OPAIRS Connect: Schema fuer Maschinendaten
-- Reines PostgreSQL (keine Erweiterungen, insbesondere kein TimescaleDB).
--
-- Wird ausgefuehrt
--   1) beim ersten Start der Datenbank (Postgres-Image: /docker-entrypoint-initdb.d)
--   2) bei jedem Start des Wartungs-Containers (Schema-Updates).
-- Die Datei muss deshalb idempotent bleiben (IF NOT EXISTS / OR REPLACE).
-- Achtung: Aendert sich die Parameterliste einer Funktion, vorher
-- DROP FUNCTION IF EXISTS ... mit der alten Signatur ergaenzen, sonst
-- entstehen zwei Varianten und Aufrufe werden mehrdeutig.

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

-- Abfragen je Maschine/Tag (Superset-Filter, Detailansichten)
CREATE INDEX IF NOT EXISTS machine_data_machine_tag_ts_idx
    ON opairs.machine_data (machine, tag, ts DESC);

-- Zeitbereichs-Abfragen ueber alle Tags (z. B. Aggregation). BRIN ist fuer
-- zeitlich aufsteigend geschriebene Daten sehr klein und billig.
CREATE INDEX IF NOT EXISTS machine_data_ts_brin_idx
    ON opairs.machine_data USING brin (ts);

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

-- Zeitfilter in Superset, Aufbewahrung und Ermittlung des letzten Buckets
CREATE INDEX IF NOT EXISTS machine_data_1min_bucket_idx
    ON opairs.machine_data_1min (bucket);

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
    -- Nur eine Wartung gleichzeitig (Sperre gilt bis Transaktionsende).
    IF NOT pg_try_advisory_xact_lock(hashtext('opairs.maintenance')) THEN
        RAISE NOTICE 'opairs: Wartung laeuft bereits, uebersprungen';
        RETURN;
    END IF;

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

-- Minutenwerte aus den Rohdaten (idempotent).
-- Berechnet mindestens die letzten `lookback` Minuten neu (spaet eintreffende
-- Werte). War die Wartung laenger ausgefallen, wird ab dem letzten
-- vorhandenen Bucket aufgeholt, hoechstens jedoch `max_catchup` zurueck.
-- Werte mit Zeitstempel in der Zukunft (falsche Uhr an der Quelle) werden
-- ignoriert. Voraussetzung: Rohdaten-Aufbewahrung > lookback.
CREATE OR REPLACE FUNCTION opairs.aggregate_1min(
    lookback    interval DEFAULT interval '2 hours',
    max_catchup interval DEFAULT interval '7 days'
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    n           bigint;
    start_ts    timestamptz := date_trunc('minute', now() - lookback);
    end_ts      timestamptz := date_trunc('minute', now()) + interval '1 minute';
    last_bucket timestamptz;
BEGIN
    SELECT max(bucket) INTO last_bucket
      FROM opairs.machine_data_1min
     WHERE bucket < end_ts;

    IF last_bucket IS NOT NULL AND last_bucket < start_ts THEN
        start_ts := last_bucket;
    END IF;
    start_ts := greatest(start_ts, date_trunc('minute', now() - max_catchup));

    INSERT INTO opairs.machine_data_1min
           (bucket, machine, tag, avg_value, min_value, max_value, sample_count)
    SELECT date_trunc('minute', ts), machine, tag,
           avg(value), min(value), max(value), count(*)
      FROM opairs.machine_data
     WHERE ts >= start_ts
       AND ts <  end_ts
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
    -- Nur eine Wartung gleichzeitig (gleiche Sperre wie in maintain_partitions).
    IF NOT pg_try_advisory_xact_lock(hashtext('opairs.maintenance')) THEN
        RAISE NOTICE 'opairs: Wartung laeuft bereits, uebersprungen';
        RETURN;
    END IF;

    IF raw_retention_days * 24 * 60 <= agg_lookback_minutes THEN
        RAISE EXCEPTION 'opairs: raw_retention_days (%) muss laenger sein als agg_lookback_minutes (%)',
            raw_retention_days, agg_lookback_minutes;
    END IF;

    PERFORM opairs.maintain_partitions(ahead_days, make_interval(days => raw_retention_days));
    PERFORM opairs.aggregate_1min(make_interval(mins => agg_lookback_minutes));
    DELETE FROM opairs.machine_data_1min
     WHERE bucket < now() - make_interval(days => agg_retention_days);
END;
$$;

-- Fuer Superset: letzter Minutenwert je Maschine und Tag (letzte 24 Stunden).
CREATE OR REPLACE VIEW opairs.v_latest_1min AS
SELECT DISTINCT ON (machine, tag)
       machine, tag, bucket, avg_value, min_value, max_value, sample_count
  FROM opairs.machine_data_1min
 WHERE bucket > now() - interval '24 hours'
 ORDER BY machine, tag, bucket DESC;

-- Erste Partitionen sofort anlegen, damit der Connector ab dem Start schreiben kann.
SELECT opairs.maintain_partitions();
