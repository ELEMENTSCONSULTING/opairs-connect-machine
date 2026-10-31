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
--   quality    Qualitaet der Quelle: "Good", "Uncertain 0x...", "Bad 0x..."
--              oder NULL (Quelle ohne Qualitaetsangabe, z. B. Modbus, S7)
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

-- Anzahl Werte je Minute, die nicht "Good" waren (Uncertain/Bad). Sie
-- fliessen nicht in avg/min/max/sample_count ein.
ALTER TABLE opairs.machine_data_1min
    ADD COLUMN IF NOT EXISTS bad_count bigint NOT NULL DEFAULT 0;

-- Ist ein Qualitaetswert "gut"? NULL (Quelle ohne Qualitaet) gilt als gut.
-- Erkennt auch den Langtext des OPC-UA-Plugins ("... StatusGood (0x0)"),
-- der vor der Vereinfachung in der Pipeline gespeichert wurde.
CREATE OR REPLACE FUNCTION opairs.is_good_quality(q text)
RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
    SELECT q IS NULL OR q ~* '^\s*good' OR q ~ 'StatusGood'
$$;

-- Zeitfilter in Superset, Aufbewahrung und Ermittlung des letzten Buckets
CREATE INDEX IF NOT EXISTS machine_data_1min_bucket_idx
    ON opairs.machine_data_1min (bucket);

-- Tagespartition (UTC) anlegen. Zeilen dieses Tages, die schon in der
-- Default-Partition liegen, werden verschoben. Dafuer wird die Elterntabelle
-- kurz exklusiv gesperrt, damit der Connector nicht zwischen Verschieben und
-- Anlegen neue Zeilen in die Default-Partition schreibt. Die Sperre gilt bis
-- Transaktionsende; maintain_partitions deshalb in einer eigenen Transaktion
-- aufrufen (so macht es der Wartungs-Container).
CREATE OR REPLACE FUNCTION opairs.create_day_partition(d date)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    part_name text        := 'machine_data_' || to_char(d, 'YYYYMMDD');
    lo        timestamptz := d::timestamp AT TIME ZONE 'UTC';
    hi        timestamptz := (d + 1)::timestamp AT TIME ZONE 'UTC';
BEGIN
    IF to_regclass(format('opairs.%I', part_name)) IS NOT NULL THEN
        RETURN false;
    END IF;

    -- Nicht endlos auf die Sperre warten (z. B. lange Superset-Abfrage):
    -- dann scheitert dieser Lauf, der naechste versucht es erneut.
    PERFORM set_config('lock_timeout', '10s', true);
    LOCK TABLE opairs.machine_data IN ACCESS EXCLUSIVE MODE;

    IF to_regclass('pg_temp._opairs_moved') IS NULL THEN
        CREATE TEMP TABLE _opairs_moved (LIKE opairs.machine_data) ON COMMIT DROP;
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
    RETURN true;
END;
$$;

-- Partitionen anlegen und (nur wenn raw_retention angegeben ist) alte
-- Rohdaten loeschen. raw_retention = NULL loescht nichts.
CREATE OR REPLACE FUNCTION opairs.maintain_partitions(
    ahead_days    integer  DEFAULT 7,
    raw_retention interval DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    today  date := (now() AT TIME ZONE 'UTC')::date;
    cutoff date;
    d      date;
    r      record;
BEGIN
    -- Nur eine Wartung gleichzeitig (Sperre gilt bis Transaktionsende).
    IF NOT pg_try_advisory_xact_lock(hashtext('opairs.maintenance')) THEN
        RAISE NOTICE 'opairs: Wartung laeuft bereits, uebersprungen';
        RETURN;
    END IF;

    -- Auch DROP TABLE braucht eine exklusive Sperre: nicht endlos warten
    -- (sonst stauen sich die Inserts des Connectors dahinter).
    PERFORM set_config('lock_timeout', '10s', true);

    IF raw_retention IS NOT NULL THEN
        IF raw_retention < interval '1 day' THEN
            RAISE EXCEPTION 'opairs: raw_retention muss mindestens 1 Tag sein (%)', raw_retention;
        END IF;
        cutoff := ((now() - raw_retention) AT TIME ZONE 'UTC')::date;
    END IF;

    -- 1) Partitionen fuer gestern bis heute + ahead_days.
    FOR i IN -1..ahead_days LOOP
        PERFORM opairs.create_day_partition(today + i);
    END LOOP;

    -- 2) Tage, fuer die Zeilen in der Default-Partition liegen (Quelle mit
    --    falscher Uhr, laengerer Wartungsausfall), bekommen ebenfalls eine
    --    Partition, sofern sie nicht unter die Aufbewahrung fallen und nicht
    --    mehr als ein Jahr in der Zukunft liegen.
    FOR d IN
        SELECT DISTINCT (ts AT TIME ZONE 'UTC')::date
          FROM opairs.machine_data_default
         ORDER BY 1
    LOOP
        IF (cutoff IS NULL OR d >= cutoff) AND d <= today + 366 THEN
            PERFORM opairs.create_day_partition(d);
        END IF;
    END LOOP;

    -- 3) Aufbewahrung: Partitionen komplett vor dem Stichtag loeschen,
    --    ebenso alte Zeilen in der Default-Partition.
    IF cutoff IS NOT NULL THEN
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

        DELETE FROM opairs.machine_data_default
         WHERE ts < cutoff::timestamp AT TIME ZONE 'UTC';
    END IF;
END;
$$;

-- Minutenwerte aus den Rohdaten (idempotent).
-- Berechnet mindestens die letzten `lookback` Minuten neu (spaet eintreffende
-- Werte). War die Wartung laenger ausgefallen, wird ab dem letzten
-- vorhandenen Bucket aufgeholt, hoechstens jedoch `max_catchup` zurueck.
-- Werte mit Zeitstempel in der Zukunft (falsche Uhr an der Quelle) werden
-- ignoriert. Nur Werte mit guter Qualitaet gehen in avg/min/max/sample_count
-- ein; die uebrigen zaehlt bad_count. Voraussetzung: Rohdaten-Aufbewahrung > lookback.
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
    -- Nur eine Aggregation gleichzeitig.
    IF NOT pg_try_advisory_xact_lock(hashtext('opairs.aggregate')) THEN
        RAISE NOTICE 'opairs: Aggregation laeuft bereits, uebersprungen';
        RETURN 0;
    END IF;

    SELECT max(bucket) INTO last_bucket
      FROM opairs.machine_data_1min
     WHERE bucket < end_ts;

    IF last_bucket IS NOT NULL AND last_bucket < start_ts THEN
        start_ts := last_bucket;
    END IF;
    start_ts := greatest(start_ts, date_trunc('minute', now() - max_catchup));

    INSERT INTO opairs.machine_data_1min
           (bucket, machine, tag, avg_value, min_value, max_value, sample_count, bad_count)
    SELECT date_trunc('minute', ts), machine, tag,
           avg(value)   FILTER (WHERE good),
           min(value)   FILTER (WHERE good),
           max(value)   FILTER (WHERE good),
           count(*)     FILTER (WHERE good),
           count(*)     FILTER (WHERE NOT good)
      FROM (SELECT ts, machine, tag, value, opairs.is_good_quality(quality) AS good
              FROM opairs.machine_data
             WHERE ts >= start_ts
               AND ts <  end_ts
               AND value IS NOT NULL) d
     GROUP BY 1, 2, 3
    ON CONFLICT (machine, tag, bucket) DO UPDATE
       SET avg_value    = EXCLUDED.avg_value,
           min_value    = EXCLUDED.min_value,
           max_value    = EXCLUDED.max_value,
           sample_count = EXCLUDED.sample_count,
           bad_count    = EXCLUDED.bad_count;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END;
$$;

-- Alte Minutenwerte loeschen.
CREATE OR REPLACE FUNCTION opairs.purge_aggregates(
    agg_retention interval DEFAULT interval '400 days'
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    n bigint;
BEGIN
    DELETE FROM opairs.machine_data_1min WHERE bucket < now() - agg_retention;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END;
$$;

-- Alles in einem Aufruf (fuer manuelle Laeufe und Tests). Der Wartungs-
-- Container ruft die drei Schritte stattdessen in getrennten Transaktionen
-- auf, damit die kurze Tabellensperre beim Anlegen einer Partition nicht bis
-- zum Ende der Aggregation gehalten wird.
CREATE OR REPLACE FUNCTION opairs.run_maintenance(
    raw_retention_days   integer DEFAULT 30,
    agg_retention_days   integer DEFAULT 400,
    ahead_days           integer DEFAULT 7,
    agg_lookback_minutes integer DEFAULT 120
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF raw_retention_days * 24 * 60 <= agg_lookback_minutes THEN
        RAISE EXCEPTION 'opairs: raw_retention_days (%) muss laenger sein als agg_lookback_minutes (%)',
            raw_retention_days, agg_lookback_minutes;
    END IF;

    PERFORM opairs.maintain_partitions(ahead_days, make_interval(days => raw_retention_days));
    PERFORM opairs.aggregate_1min(make_interval(mins => agg_lookback_minutes));
    PERFORM opairs.purge_aggregates(make_interval(days => agg_retention_days));
END;
$$;

-- Fuer Superset: letzter Minutenwert je Maschine und Tag (letzte 24 Stunden).
-- Neue Spalten nur hinten anhaengen (CREATE OR REPLACE VIEW erlaubt nichts anderes).
CREATE OR REPLACE VIEW opairs.v_latest_1min AS
SELECT DISTINCT ON (machine, tag)
       machine, tag, bucket, avg_value, min_value, max_value, sample_count, bad_count
  FROM opairs.machine_data_1min
 WHERE bucket > now() - interval '24 hours'
 ORDER BY machine, tag, bucket DESC;

-- Partitionen sofort anlegen, damit der Connector ab dem Start schreiben kann.
-- Bewusst OHNE Aufbewahrung: diese Datei laeuft bei jedem Start der Wartung,
-- geloescht wird nur im regulaeren Lauf mit der konfigurierten Frist.
SELECT opairs.maintain_partitions(raw_retention => NULL);
