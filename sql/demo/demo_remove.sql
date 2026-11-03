-- Alle Demo-Daten entfernen (Rohdaten, Minutenwerte, Minutenzustaende und
-- Stammdaten der Anlagen demo-*).
--   ./scripts/demo.sh remove
-- Die allgemeinen Signalbeschreibungen (tag_meta mit machine = '*') bleiben,
-- sie gelten auch fuer echte Anlagen mit denselben Signalnamen.
\set ON_ERROR_STOP on
BEGIN;
DELETE FROM opairs.machine_data      WHERE machine LIKE 'demo-%';
DELETE FROM opairs.machine_data_1min WHERE machine LIKE 'demo-%';
DELETE FROM opairs.state_1min        WHERE machine LIKE 'demo-%';
DELETE FROM opairs.tag_meta          WHERE machine LIKE 'demo-%';
DELETE FROM opairs.asset             WHERE machine LIKE 'demo-%';
COMMIT;
