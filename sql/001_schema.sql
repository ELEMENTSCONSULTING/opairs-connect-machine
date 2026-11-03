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

------------------------------------------------------------------------
-- Stammdaten (Anlagen und Signale) und Maschinenzustaende
------------------------------------------------------------------------

-- Anlagen mit Einordnung nach ISA-95 (Unternehmen > Werk > Bereich > Linie >
-- Anlage) und den SAP-Bezeichnungen. `machine` ist der Name, den der
-- Connector in machine_data.machine schreibt.
-- Die tag_*-Spalten sagen, aus welchen Signalen Zustand, Qualitaet und
-- Taktzeit fuer OEE/TEEP gelesen werden:
--   tag_zustand        Zustandscode nach opairs.state_def (Zahl je Wert)
--   zustand_haltezeit  so lange gilt der letzte Zustandswert; danach ist
--                      der Zustand 0 "Unbekannt". Quellen, die nur bei
--                      Aenderung senden (OPC-UA-Subscription), brauchen
--                      einen laengeren Wert, z. B. '12 hours'.
--   tag_qualitaet      Gutteil 1 / Schlechtteil 0 (Mittelwert = Gutanteil)
--   tag_taktzeit       Ist-Takt- bzw. Zykluszeit in Sekunden
--   tag_taktzeit_soll  Soll-Taktzeit als Signal (z. B. je Werkzeug), sonst
--   soll_taktzeit_s    feste Soll-Taktzeit in Sekunden
-- Fehlt Qualitaet oder Taktzeit, wird dieser Faktor mit 1 gerechnet.
CREATE TABLE IF NOT EXISTS opairs.asset (
    machine           text PRIMARY KEY,
    bezeichnung       text,
    art               text,
    unternehmen       text,
    werk              text,
    bereich           text,
    linie             text,
    sap_werk          text,
    sap_arbeitsplatz  text,
    sap_equipment     text,
    hersteller        text,
    baujahr           integer,
    seriennummer      text,
    tag_zustand       text     DEFAULT 'state_code',
    zustand_haltezeit interval NOT NULL DEFAULT interval '15 minutes'
                      CHECK (zustand_haltezeit >= interval '1 minute'),
    tag_qualitaet     text,
    tag_taktzeit      text,
    tag_taktzeit_soll text,
    soll_taktzeit_s   double precision CHECK (soll_taktzeit_s > 0),
    aktiv             boolean  NOT NULL DEFAULT true,
    gueltig_ab        timestamptz,
    bemerkung         text
);

-- Beschreibung der Signale. machine = '*' gilt fuer alle Anlagen, eine
-- Zeile mit dem Anlagennamen hat Vorrang (siehe v_tag_meta).
--   signalart  z. B. messwert, zaehler, zustand, sollwert, pruefergebnis, text
--   quelle     Adresse an der Maschine (OPC-UA-NodeId, S7-Adresse, ...)
CREATE TABLE IF NOT EXISTS opairs.tag_meta (
    machine      text NOT NULL DEFAULT '*',
    tag          text NOT NULL,
    beschreibung text,
    einheit      text,
    signalart    text,
    quelle       text,
    sollwert     double precision,
    grenze_min   double precision,
    grenze_max   double precision,
    PRIMARY KEY (machine, tag)
);

-- Einheitliche Maschinenzustaende und ihre Zeitstufe im Zeitmodell
-- (Jodlbauer). Codes 0-8 sind vorgegeben, eigene Codes ab 10 moeglich.
-- Gruende im Detail (welche Stoerung, welcher Wechsel) gehoeren in ein
-- Textsignal, z. B. "status".
CREATE TABLE IF NOT EXISTS opairs.state_def (
    state_code             integer PRIMARY KEY,
    bezeichnung            text    NOT NULL,
    zeitstufe              text    NOT NULL CHECK (zeitstufe IN (
                               'produktion', 'leerlauf', 'verfuegbarkeit',
                               'geplanter_stillstand', 'keine_schicht', 'unbekannt')),
    zaehlt_fuer_auslastung boolean NOT NULL DEFAULT false,
    beschreibung           text
);

-- Nur fehlende Codes ergaenzen: Aenderungen vor Ort bleiben erhalten.
INSERT INTO opairs.state_def (state_code, bezeichnung, zeitstufe, zaehlt_fuer_auslastung, beschreibung) VALUES
    (0, 'Unbekannt / kein Signal',     'unbekannt',            false, 'kein gueltiger Zustandswert innerhalb der Haltezeit'),
    (1, 'Produktion',                  'produktion',           true,  'Anlage fertigt'),
    (2, 'Leerlauf / wartet',           'leerlauf',             false, 'betriebsbereit, wartet auf Material, Bediener oder Folgeprozess'),
    (3, 'Technische Störung',          'verfuegbarkeit',       false, 'ungeplanter Stillstand durch Stoerung'),
    (4, 'Rüsten / Produktwechsel',     'verfuegbarkeit',       true,  'Ruesten, Werkzeug- und Produktwechsel, inkl. Reinigung als Teil des Wechsels'),
    (5, 'Wartung geplant',             'geplanter_stillstand', false, 'geplante Instandhaltung'),
    (6, 'Reinigung geplant',           'geplanter_stillstand', false, 'geplante Reinigung ohne Produktwechsel'),
    (7, 'Pause / organisatorisch',     'geplanter_stillstand', false, 'Pause, Besprechung, keine Auftraege eingeplant'),
    (8, 'Keine Schicht',               'keine_schicht',        false, 'ausserhalb der Schichtzeit')
ON CONFLICT (state_code) DO NOTHING;

-- Zustand je Anlage und Minute (letzter Zustandswert der Minute, gehalten
-- bis zur Haltezeit der Anlage), dazu die Minutenwerte von Taktzeit und
-- Qualitaet laut opairs.asset. Nur fuer Anlagen in opairs.asset.
CREATE TABLE IF NOT EXISTS opairs.state_1min (
    machine    text        NOT NULL,
    bucket     timestamptz NOT NULL,
    state_code integer     NOT NULL,
    PRIMARY KEY (machine, bucket)
);
ALTER TABLE opairs.state_1min
    ADD COLUMN IF NOT EXISTS taktzeit_ist_s  double precision,
    ADD COLUMN IF NOT EXISTS taktzeit_soll_s double precision,
    ADD COLUMN IF NOT EXISTS qualitaet       double precision;

CREATE INDEX IF NOT EXISTS state_1min_bucket_idx
    ON opairs.state_1min (bucket);

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

-- Zustand je Minute fuer alle aktiven Anlagen (idempotent). Rechnet die
-- letzten `lookback` Minuten neu und holt Luecken ab dem letzten Bucket
-- der Anlage auf, hoechstens `max_catchup` zurueck. Eine neu eingetragene
-- Anlage wird ab ihrem ersten Zustandswert (hoechstens `max_catchup`)
-- nachgerechnet; vor gueltig_ab entstehen keine Zeilen. Gerechnet wird
-- nie vor dem aeltesten Rohwert: aeltere Minuten bleiben unveraendert,
-- auch wenn lookback weiter zurueckreicht.
-- Wird am Ende von aggregate_1min() aufgerufen. Nach Aenderungen an den
-- tag_*-Spalten einer Anlage die Vergangenheit neu rechnen, z. B.
--   SELECT opairs.aggregate_state_1min(interval '30 days', interval '30 days');
CREATE OR REPLACE FUNCTION opairs.aggregate_state_1min(
    lookback    interval DEFAULT interval '2 hours',
    max_catchup interval DEFAULT interval '7 days'
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    n        bigint := 0;
    k        bigint;
    start_ts timestamptz := date_trunc('minute', now() - lookback);
    end_ts   timestamptz := date_trunc('minute', now()) + interval '1 minute';
    floor_ts timestamptz := date_trunc('minute', now() - max_catchup);
    von      timestamptz;
    erster   timestamptz;
    last_b   timestamptz;
    a        record;
BEGIN
    IF NOT pg_try_advisory_xact_lock(hashtext('opairs.aggregate_state')) THEN
        RAISE NOTICE 'opairs: Zustandsaggregation laeuft bereits, uebersprungen';
        RETURN 0;
    END IF;

    FOR a IN
        SELECT machine, tag_zustand, zustand_haltezeit, date_trunc('minute', gueltig_ab) AS ab,
               tag_qualitaet, tag_taktzeit, tag_taktzeit_soll, soll_taktzeit_s
          FROM opairs.asset
         WHERE aktiv AND tag_zustand IS NOT NULL
    LOOP
        IF a.ab IS NOT NULL THEN
            DELETE FROM opairs.state_1min WHERE machine = a.machine AND bucket < a.ab;
        END IF;

        -- aeltester vorhandener Zustandswert im Rechenzeitraum
        SELECT date_trunc('minute', min(ts)) INTO erster
          FROM opairs.machine_data
         WHERE machine = a.machine AND tag = a.tag_zustand
           AND ts >= floor_ts AND ts < end_ts;
        CONTINUE WHEN erster IS NULL;

        SELECT max(bucket) INTO last_b
          FROM opairs.state_1min
         WHERE machine = a.machine AND bucket < end_ts;

        von := CASE WHEN last_b IS NULL THEN erster ELSE least(start_ts, last_b) END;
        von := greatest(von, erster, floor_ts, coalesce(a.ab, '-infinity'));

        INSERT INTO opairs.state_1min (machine, bucket, state_code, taktzeit_ist_s, taktzeit_soll_s, qualitaet)
        SELECT a.machine, g.bucket, coalesce(l.code, 0),
               t.avg_value, coalesce(ts.avg_value, a.soll_taktzeit_s), q.avg_value
          FROM generate_series(von, end_ts - interval '1 minute', interval '1 minute') g(bucket)
          LEFT JOIN LATERAL (
                SELECT round(d.value)::integer AS code
                  FROM opairs.machine_data d
                 WHERE d.machine = a.machine
                   AND d.tag     = a.tag_zustand
                   AND d.ts <  g.bucket + interval '1 minute'
                   AND d.ts >= g.bucket + interval '1 minute' - a.zustand_haltezeit
                   AND d.value IS NOT NULL
                   AND opairs.is_good_quality(d.quality)
                 ORDER BY d.ts DESC
                 LIMIT 1) l ON true
          LEFT JOIN opairs.machine_data_1min t
                 ON t.machine = a.machine AND t.tag = a.tag_taktzeit AND t.bucket = g.bucket
          LEFT JOIN opairs.machine_data_1min ts
                 ON ts.machine = a.machine AND ts.tag = a.tag_taktzeit_soll AND ts.bucket = g.bucket
          LEFT JOIN opairs.machine_data_1min q
                 ON q.machine = a.machine AND q.tag = a.tag_qualitaet AND q.bucket = g.bucket
        ON CONFLICT (machine, bucket) DO UPDATE
           SET state_code      = EXCLUDED.state_code,
               taktzeit_ist_s  = EXCLUDED.taktzeit_ist_s,
               taktzeit_soll_s = EXCLUDED.taktzeit_soll_s,
               qualitaet       = EXCLUDED.qualitaet
         WHERE (opairs.state_1min.state_code, opairs.state_1min.taktzeit_ist_s,
                opairs.state_1min.taktzeit_soll_s, opairs.state_1min.qualitaet)
               IS DISTINCT FROM
               (EXCLUDED.state_code, EXCLUDED.taktzeit_ist_s, EXCLUDED.taktzeit_soll_s, EXCLUDED.qualitaet);
        GET DIAGNOSTICS k = ROW_COUNT;
        n := n + k;
    END LOOP;
    RETURN n;
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

    -- Zustaende je Minute im selben Lauf. Ein Fehler dort (z. B. falsch
    -- gepflegte Stammdaten) darf die Minutenwerte nicht verhindern.
    BEGIN
        PERFORM opairs.aggregate_state_1min(lookback, max_catchup);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'opairs: Zustandsaggregation fehlgeschlagen: %', SQLERRM;
    END;
    RETURN n;
END;
$$;

-- Alte Minutenwerte und Minutenzustaende loeschen.
CREATE OR REPLACE FUNCTION opairs.purge_aggregates(
    agg_retention interval DEFAULT interval '400 days'
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    n bigint;
    k bigint;
BEGIN
    DELETE FROM opairs.machine_data_1min WHERE bucket < now() - agg_retention;
    GET DIAGNOSTICS n = ROW_COUNT;
    DELETE FROM opairs.state_1min WHERE bucket < now() - agg_retention;
    GET DIAGNOSTICS k = ROW_COUNT;
    RETURN n + k;
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

------------------------------------------------------------------------
-- Sichten mit Stammdaten (Superset, Auswertungen)
-- Anlagen ohne Eintrag in opairs.asset erscheinen mit "(nicht zugeordnet)".
------------------------------------------------------------------------

-- Signalbeschreibung je Anlage: eigene Zeile vor der Vorgabe fuer '*'
CREATE OR REPLACE VIEW opairs.v_tag_meta AS
SELECT t.machine, t.tag, t.beschreibung, t.einheit, t.signalart, t.quelle,
       t.sollwert, t.grenze_min, t.grenze_max, false AS aus_vorgabe
  FROM opairs.tag_meta t
 WHERE t.machine <> '*'
UNION ALL
SELECT a.machine, t.tag, t.beschreibung, t.einheit, t.signalart, t.quelle,
       t.sollwert, t.grenze_min, t.grenze_max, true
  FROM opairs.asset a
  JOIN opairs.tag_meta t ON t.machine = '*'
 WHERE NOT EXISTS (SELECT 1 FROM opairs.tag_meta s WHERE s.machine = a.machine AND s.tag = t.tag);

-- Alle Anlagen fuer Filter: Stammdaten plus Anlagen ohne Stammdaten, die in
-- den letzten 24 Stunden Daten geliefert haben.
CREATE OR REPLACE VIEW opairs.v_anlage AS
SELECT a.machine, coalesce(a.bezeichnung, a.machine) AS anlage,
       coalesce(a.art, '(nicht zugeordnet)')         AS art,
       coalesce(a.unternehmen, '(nicht zugeordnet)') AS unternehmen,
       coalesce(a.werk, '(nicht zugeordnet)')        AS werk,
       coalesce(a.bereich, '(nicht zugeordnet)')     AS bereich,
       coalesce(a.linie, '(nicht zugeordnet)')       AS linie,
       a.sap_werk, a.sap_arbeitsplatz, a.sap_equipment, a.aktiv, true AS in_stammdaten
  FROM opairs.asset a
UNION ALL
SELECT DISTINCT m.machine, m.machine, '(nicht zugeordnet)', '(nicht zugeordnet)', '(nicht zugeordnet)',
       '(nicht zugeordnet)', '(nicht zugeordnet)', NULL, NULL, NULL, true, false
  FROM opairs.machine_data_1min m
 WHERE m.bucket > now() - interval '24 hours'
   AND NOT EXISTS (SELECT 1 FROM opairs.asset a WHERE a.machine = m.machine);

-- Minutenwerte mit Einordnung und Signalbeschreibung
CREATE OR REPLACE VIEW opairs.v_machine_data_1min_ctx AS
SELECT m.bucket, m.machine, m.tag, m.avg_value, m.min_value, m.max_value, m.sample_count, m.bad_count,
       coalesce(a.bezeichnung, m.machine)            AS anlage,
       coalesce(a.art, '(nicht zugeordnet)')         AS art,
       coalesce(a.unternehmen, '(nicht zugeordnet)') AS unternehmen,
       coalesce(a.werk, '(nicht zugeordnet)')        AS werk,
       coalesce(a.bereich, '(nicht zugeordnet)')     AS bereich,
       coalesce(a.linie, '(nicht zugeordnet)')       AS linie,
       coalesce(tm.beschreibung, tg.beschreibung)    AS beschreibung,
       coalesce(tm.einheit, tg.einheit)              AS einheit
  FROM opairs.machine_data_1min m
  LEFT JOIN opairs.asset a     ON a.machine = m.machine
  LEFT JOIN opairs.tag_meta tm ON tm.machine = m.machine AND tm.tag = m.tag
  LEFT JOIN opairs.tag_meta tg ON tg.machine = '*'       AND tg.tag = m.tag;

-- Letzter Minutenwert mit Einordnung
CREATE OR REPLACE VIEW opairs.v_latest_1min_ctx AS
SELECT l.*,
       coalesce(a.bezeichnung, l.machine)            AS anlage,
       coalesce(a.art, '(nicht zugeordnet)')         AS art,
       coalesce(a.unternehmen, '(nicht zugeordnet)') AS unternehmen,
       coalesce(a.werk, '(nicht zugeordnet)')        AS werk,
       coalesce(a.bereich, '(nicht zugeordnet)')     AS bereich,
       coalesce(a.linie, '(nicht zugeordnet)')       AS linie,
       coalesce(tm.beschreibung, tg.beschreibung)    AS beschreibung,
       coalesce(tm.einheit, tg.einheit)              AS einheit
  FROM opairs.v_latest_1min l
  LEFT JOIN opairs.asset a     ON a.machine = l.machine
  LEFT JOIN opairs.tag_meta tm ON tm.machine = l.machine AND tm.tag = l.tag
  LEFT JOIN opairs.tag_meta tg ON tg.machine = '*'       AND tg.tag = l.tag;

-- Rohdaten mit Einordnung
CREATE OR REPLACE VIEW opairs.v_machine_data_ctx AS
SELECT r.ts, r.machine, r.tag, r.value, r.value_text, r.quality,
       coalesce(a.bezeichnung, r.machine)            AS anlage,
       coalesce(a.art, '(nicht zugeordnet)')         AS art,
       coalesce(a.unternehmen, '(nicht zugeordnet)') AS unternehmen,
       coalesce(a.werk, '(nicht zugeordnet)')        AS werk,
       coalesce(a.bereich, '(nicht zugeordnet)')     AS bereich,
       coalesce(a.linie, '(nicht zugeordnet)')       AS linie
  FROM opairs.machine_data r
  LEFT JOIN opairs.asset a ON a.machine = r.machine;

-- Zeitmodell je Anlage und Minute (Jodlbauer). Jede Minute ist genau einer
-- Zeitstufe zugeordnet; die *_min-Spalten sind 0/1 bzw. Anteile einer Minute
-- und lassen sich ueber beliebige Zeitraeume, Anlagen, Linien und Werke
-- summieren:
--   Kalenderzeit                      kalender_min
--   - keine Schicht (8)             = planbelegung_min
--   - geplante Stillstaende (5,6,7) = geplante_betriebszeit_min
--   - Stoerung, Ruesten (3,4)       = nettobetriebszeit_min
--   - Leerlauf (2)                  = produktion_min
--   x Leistungsgrad (Soll/Ist-Takt) = nutzbar_min
--   x Qualitaetsrate                = nettoproduktiv_min
-- Minuten mit Zustand 0 (kein Signal) zaehlen nur zur Kalenderzeit und
-- werden als unbekannt_min ausgewiesen (Datenqualitaet).
--   OEE                    = nettoproduktiv / planbelegung
--   OEE ohne geplante Stillstaende = nettoproduktiv / geplante_betriebszeit
--   TEEP                   = nettoproduktiv / kalender
--   Auslastung             = auslastung_min (Produktion + Ruesten) / geplante_betriebszeit
CREATE OR REPLACE VIEW opairs.v_oee_1min AS
SELECT b.bucket, b.machine, b.anlage, b.art, b.unternehmen, b.werk, b.bereich, b.linie,
       b.state_code, b.zustand, b.zeitstufe,
       1                                                          AS kalender_min,
       (b.zeitstufe = 'unbekannt')::int                           AS unbekannt_min,
       (b.zeitstufe = 'keine_schicht')::int                       AS keine_schicht_min,
       (b.zeitstufe NOT IN ('keine_schicht', 'unbekannt'))::int   AS planbelegung_min,
       (b.zeitstufe = 'geplanter_stillstand')::int                AS geplanter_stillstand_min,
       (b.zeitstufe IN ('produktion', 'leerlauf', 'verfuegbarkeit'))::int AS geplante_betriebszeit_min,
       (b.zeitstufe = 'verfuegbarkeit' AND b.zaehlt_fuer_auslastung)::int     AS ruesten_min,
       (b.zeitstufe = 'verfuegbarkeit' AND NOT b.zaehlt_fuer_auslastung)::int AS stoerung_min,
       (b.zeitstufe IN ('produktion', 'leerlauf'))::int           AS nettobetriebszeit_min,
       (b.zeitstufe = 'leerlauf')::int                            AS leerlauf_min,
       (b.zeitstufe = 'produktion')::int                          AS produktion_min,
       (b.zaehlt_fuer_auslastung
        AND b.zeitstufe IN ('produktion', 'leerlauf', 'verfuegbarkeit'))::int AS auslastung_min,
       b.taktzeit_ist_s, b.taktzeit_soll_s, b.leistungsgrad, b.qualitaetsrate,
       CASE WHEN b.zeitstufe = 'produktion' THEN b.leistungsgrad ELSE 0 END                    AS nutzbar_min,
       CASE WHEN b.zeitstufe = 'produktion' THEN b.leistungsgrad * b.qualitaetsrate ELSE 0 END AS nettoproduktiv_min
  FROM (
    SELECT s.bucket, s.machine, s.state_code,
           coalesce(a.bezeichnung, s.machine)            AS anlage,
           coalesce(a.art, '(nicht zugeordnet)')         AS art,
           coalesce(a.unternehmen, '(nicht zugeordnet)') AS unternehmen,
           coalesce(a.werk, '(nicht zugeordnet)')        AS werk,
           coalesce(a.bereich, '(nicht zugeordnet)')     AS bereich,
           coalesce(a.linie, '(nicht zugeordnet)')       AS linie,
           coalesce(d.bezeichnung, 'Code ' || s.state_code || ' (nicht definiert)') AS zustand,
           coalesce(d.zeitstufe, 'unbekannt')            AS zeitstufe,
           coalesce(d.zaehlt_fuer_auslastung, false)     AS zaehlt_fuer_auslastung,
           s.taktzeit_ist_s, s.taktzeit_soll_s,
           CASE WHEN s.taktzeit_ist_s > 0 AND s.taktzeit_soll_s > 0
                THEN least(1.0, s.taktzeit_soll_s / s.taktzeit_ist_s)
                ELSE 1.0 END                             AS leistungsgrad,
           CASE WHEN s.qualitaet IS NULL THEN 1.0
                ELSE greatest(0.0, least(1.0, s.qualitaet)) END AS qualitaetsrate
      FROM opairs.state_1min s
      LEFT JOIN opairs.asset a     ON a.machine = s.machine
      LEFT JOIN opairs.state_def d ON d.state_code = s.state_code
  ) b;

-- Kennzahlen je Anlage und Tag (UTC)
CREATE OR REPLACE VIEW opairs.v_oee_taeglich AS
SELECT x.*,
       x.nettoproduktiv_min / nullif(x.planbelegung_min, 0)          AS oee,
       x.nettoproduktiv_min / nullif(x.geplante_betriebszeit_min, 0) AS oee_ohne_geplante_stillstaende,
       x.nettoproduktiv_min / nullif(x.kalender_min, 0)              AS teep,
       x.auslastung_min::double precision / nullif(x.geplante_betriebszeit_min, 0) AS auslastung,
       x.nettobetriebszeit_min::double precision / nullif(x.geplante_betriebszeit_min, 0) AS verfuegbarkeit,
       x.nutzbar_min / nullif(x.nettobetriebszeit_min, 0)            AS leistung,
       x.nettoproduktiv_min / nullif(x.nutzbar_min, 0)               AS qualitaet,
       1 - x.unbekannt_min::double precision / nullif(x.kalender_min, 0) AS datenabdeckung
  FROM (
    SELECT (bucket AT TIME ZONE 'UTC')::date AS datum, machine, anlage, art, unternehmen, werk, bereich, linie,
           sum(kalender_min)              AS kalender_min,
           sum(unbekannt_min)             AS unbekannt_min,
           sum(keine_schicht_min)         AS keine_schicht_min,
           sum(planbelegung_min)          AS planbelegung_min,
           sum(geplanter_stillstand_min)  AS geplanter_stillstand_min,
           sum(geplante_betriebszeit_min) AS geplante_betriebszeit_min,
           sum(ruesten_min)               AS ruesten_min,
           sum(stoerung_min)              AS stoerung_min,
           sum(nettobetriebszeit_min)     AS nettobetriebszeit_min,
           sum(leerlauf_min)              AS leerlauf_min,
           sum(produktion_min)            AS produktion_min,
           sum(auslastung_min)            AS auslastung_min,
           sum(nutzbar_min)               AS nutzbar_min,
           sum(nettoproduktiv_min)        AS nettoproduktiv_min
      FROM opairs.v_oee_1min
     GROUP BY 1, 2, 3, 4, 5, 6, 7, 8
  ) x;

-- Partitionen sofort anlegen, damit der Connector ab dem Start schreiben kann.
-- Bewusst OHNE Aufbewahrung: diese Datei laeuft bei jedem Start der Wartung,
-- geloescht wird nur im regulaeren Lauf mit der konfigurierten Frist.
SELECT opairs.maintain_partitions(raw_retention => NULL);
