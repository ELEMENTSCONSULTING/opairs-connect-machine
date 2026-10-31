-- Alle Demo-Daten entfernen (Rohdaten und Minutenwerte der Maschinen demo-*).
--   ./scripts/demo.sh remove
\set ON_ERROR_STOP on
BEGIN;
DELETE FROM opairs.machine_data      WHERE machine LIKE 'demo-%';
DELETE FROM opairs.machine_data_1min WHERE machine LIKE 'demo-%';
COMMIT;
