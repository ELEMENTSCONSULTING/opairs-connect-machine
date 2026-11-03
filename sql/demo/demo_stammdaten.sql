-- Stammdaten der 9 Demo-Anlagen: Einordnung Werk > Bereich (Halle) > Linie,
-- SAP-Bezeichnungen, Signale fuer OEE und Signalbeschreibungen.
-- Wird von demo_backfill.sql und von "./scripts/demo.sh live" geladen.
-- Wiederholbar: vorhandene Demo-Eintraege werden aktualisiert.
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO opairs.asset (machine, bezeichnung, art, unternehmen, werk, bereich, linie,
                          sap_werk, sap_arbeitsplatz, sap_equipment, hersteller, baujahr,
                          tag_zustand, tag_qualitaet, tag_taktzeit, tag_taktzeit_soll, soll_taktzeit_s,
                          bemerkung) VALUES
    ('demo-cnc-01', 'CNC-Fräszentrum 1',        'CNC',        'OPAIRS Demo', 'Werk Demo', 'Halle 1 Teilefertigung', 'CNC-Zelle',
     '1000', 'CNC01', '10000101', 'Demo', 2019, 'state_code', NULL, NULL, NULL, NULL, 'Demo-Anlage'),
    ('demo-cnc-02', 'CNC-Fräszentrum 2',        'CNC',        'OPAIRS Demo', 'Werk Demo', 'Halle 1 Teilefertigung', 'CNC-Zelle',
     '1000', 'CNC02', '10000102', 'Demo', 2016, 'state_code', NULL, NULL, NULL, NULL, 'Demo-Anlage, Wartung Mi 06:00-08:00'),
    ('demo-cnc-03', 'CNC-Drehzentrum 3',        'CNC',        'OPAIRS Demo', 'Werk Demo', 'Halle 1 Teilefertigung', 'CNC-Zelle',
     '1000', 'CNC03', '10000103', 'Demo', 2022, 'state_code', NULL, NULL, NULL, NULL, 'Demo-Anlage, Ruesten 13:00-13:20'),
    ('demo-sgm-01', 'Spritzgussmaschine 1',     'Spritzguss', 'OPAIRS Demo', 'Werk Demo', 'Halle 1 Teilefertigung', 'Spritzguss',
     '1000', 'SGM01', '10000201', 'Demo', 2018, 'state_code', 'teil_io', 'zykluszeit_s', 'soll_zykluszeit_s', NULL, 'Demo-Anlage'),
    ('demo-sgm-02', 'Spritzgussmaschine 2',     'Spritzguss', 'OPAIRS Demo', 'Werk Demo', 'Halle 1 Teilefertigung', 'Spritzguss',
     '1000', 'SGM02', '10000202', 'Demo', 2021, 'state_code', 'teil_io', 'zykluszeit_s', 'soll_zykluszeit_s', NULL,
     'Demo-Anlage, Produktwechsel taeglich 05:00-05:45, Reinigung Fr 19:00-20:00'),
    ('demo-mon-01', 'Schraubstation',           'Montage',    'OPAIRS Demo', 'Werk Demo', 'Halle 2 Montage', 'Montagelinie A',
     '1000', 'MON01', '10000301', 'Demo', 2020, 'state_code', 'pruef_ergebnis', 'taktzeit_s', NULL, 17.5, 'Demo-Anlage, Typwechsel 11:00-11:15'),
    ('demo-mon-02', 'Dichtheitsprüfung',        'Montage',    'OPAIRS Demo', 'Werk Demo', 'Halle 2 Montage', 'Montagelinie A',
     '1000', 'MON02', '10000302', 'Demo', 2020, 'state_code', 'pruef_ergebnis', 'taktzeit_s', NULL, 24.0, 'Demo-Anlage, Reinigung 20:45-21:00'),
    ('demo-mon-03', 'Einpressstation',          'Montage',    'OPAIRS Demo', 'Werk Demo', 'Halle 2 Montage', 'Montagelinie B',
     '1000', 'MON03', '10000303', 'Demo', 2023, 'state_code', 'pruef_ergebnis', 'taktzeit_s', NULL, 11.5, 'Demo-Anlage'),
    ('demo-mon-04', 'Endprüfung',               'Montage',    'OPAIRS Demo', 'Werk Demo', 'Halle 2 Montage', 'Montagelinie B',
     '1000', 'MON04', '10000304', 'Demo', 2023, 'state_code', 'pruef_ergebnis', 'taktzeit_s', NULL, 29.0, 'Demo-Anlage, Wartung Di 05:00-06:00')
ON CONFLICT (machine) DO UPDATE SET
    bezeichnung = EXCLUDED.bezeichnung, art = EXCLUDED.art, unternehmen = EXCLUDED.unternehmen,
    werk = EXCLUDED.werk, bereich = EXCLUDED.bereich, linie = EXCLUDED.linie,
    sap_werk = EXCLUDED.sap_werk, sap_arbeitsplatz = EXCLUDED.sap_arbeitsplatz,
    sap_equipment = EXCLUDED.sap_equipment, hersteller = EXCLUDED.hersteller, baujahr = EXCLUDED.baujahr,
    tag_zustand = EXCLUDED.tag_zustand, tag_qualitaet = EXCLUDED.tag_qualitaet,
    tag_taktzeit = EXCLUDED.tag_taktzeit, tag_taktzeit_soll = EXCLUDED.tag_taktzeit_soll,
    soll_taktzeit_s = EXCLUDED.soll_taktzeit_s, bemerkung = EXCLUDED.bemerkung, aktiv = true;

-- Signalbeschreibungen: '*' gilt fuer alle Anlagen, dazu ein Beispiel fuer
-- eine anlagenspezifische Zeile (demo-cnc-02 hat eine andere Solldrehzahl).
INSERT INTO opairs.tag_meta (machine, tag, beschreibung, einheit, signalart, sollwert, grenze_min, grenze_max) VALUES
    ('*', 'state_code',                'Maschinenzustand (Code nach state_def)', NULL,      'zustand',       NULL, NULL,  NULL),
    ('*', 'state',                     'Anlage produziert (1/0)',             NULL,         'zustand',       NULL, NULL,  NULL),
    ('*', 'status',                    'Zustand im Klartext',                 NULL,         'text',          NULL, NULL,  NULL),
    ('*', 'spindle_speed_rpm',         'Spindeldrehzahl',                     '1/min',      'messwert',      8000, NULL,  NULL),
    ('*', 'temperature_c',             'Spindeltemperatur',                   '°C',         'messwert',      NULL, NULL,  60),
    ('*', 'power_kw',                  'Wirkleistung',                        'kW',         'messwert',      NULL, NULL,  NULL),
    ('*', 'vibration_mm_s',            'Schwinggeschwindigkeit',              'mm/s',       'messwert',      NULL, NULL,  4.5),
    ('*', 'werkzeug',                  'Werkzeug im Einsatz',                 NULL,         'text',          NULL, NULL,  NULL),
    ('*', 'kavitaeten',                'Kavitäten des Werkzeugs',             NULL,         'messwert',      NULL, NULL,  NULL),
    ('*', 'zykluszeit_s',              'Zykluszeit Ist',                      's',          'messwert',      NULL, NULL,  NULL),
    ('*', 'soll_zykluszeit_s',         'Zykluszeit Soll (je Werkzeug)',       's',          'sollwert',      NULL, NULL,  NULL),
    ('*', 'massetemperatur_c',         'Massetemperatur',                     '°C',         'messwert',      230,  220,   240),
    ('*', 'werkzeugtemperatur_c',      'Werkzeugtemperatur',                  '°C',         'messwert',      60,   55,    66),
    ('*', 'einspritzdruck_bar',        'Einspritzdruck',                      'bar',        'messwert',      850,  790,   910),
    ('*', 'teil_io',                   'Teil in Ordnung (1/0)',               NULL,         'pruefergebnis', NULL, NULL,  NULL),
    ('*', 'nio_grund',                 'Grund für NiO',                       NULL,         'text',          NULL, NULL,  NULL),
    ('*', 'taktzeit_s',                'Taktzeit Ist',                        's',          'messwert',      NULL, NULL,  NULL),
    ('*', 'pruef_ergebnis',            'Prüfergebnis iO (1/0)',               NULL,         'pruefergebnis', NULL, NULL,  NULL),
    ('*', 'schraub_drehmoment_nm',     'Schraube Drehmoment',                 'Nm',         'messwert',      4.5,  4.2,   4.8),
    ('*', 'schraub_drehwinkel_grad',   'Schraube Drehwinkel',                 '°',          'messwert',      720,  680,   760),
    ('*', 'pruefdruck_bar',            'Prüfdruck',                           'bar',        'messwert',      2.0,  NULL,  NULL),
    ('*', 'leckrate_ccm_min',          'Leckrate',                            'ccm/min',    'messwert',      NULL, NULL,  2.0),
    ('*', 'einpresskraft_kn',          'Einpresskraft',                       'kN',         'messwert',      8.0,  7.2,   8.8),
    ('*', 'einpressweg_mm',            'Einpressweg',                         'mm',         'messwert',      12.0, 11.85, 12.15),
    ('*', 'isolationswiderstand_mohm', 'Isolationswiderstand',                'MOhm',       'messwert',      NULL, 100,   NULL),
    ('*', 'kamera_io',                 'Kameraprüfung iO (1/0)',              NULL,         'pruefergebnis', NULL, NULL,  NULL),
    ('demo-cnc-02', 'spindle_speed_rpm', 'Spindeldrehzahl',                   '1/min',      'messwert',      6500, NULL,  NULL)
ON CONFLICT (machine, tag) DO UPDATE SET
    beschreibung = EXCLUDED.beschreibung, einheit = EXCLUDED.einheit, signalart = EXCLUDED.signalart,
    sollwert = EXCLUDED.sollwert, grenze_min = EXCLUDED.grenze_min, grenze_max = EXCLUDED.grenze_max;

COMMIT;
