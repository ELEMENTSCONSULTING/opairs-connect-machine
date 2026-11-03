#!/usr/bin/env python3
"""Baut den Superset-Export "OPAIRS Connect" (Datenbank, Datasets, Charts, Dashboard).

    python3 superset/build_dashboard.py
        -> superset/OPAIRS_Connect_Dashboard.zip mit eigener Verbindung "OPAIRS Connect"
    python3 superset/build_dashboard.py --database-uuid <uuid> --database-name <name> --out <zip>
        -> nutzt eine in Superset bereits angelegte Verbindung (kein Passwort beim Import)
    python3 superset/build_dashboard.py --check
        -> prueft, ob die eingecheckte ZIP zum Generator passt (CI)

Nur Standardbibliothek. Die Dateien sind JSON und damit gueltiges YAML, wie
Superset sie beim Import liest. Alle UUIDs sind fest (uuid5), unabhaengig von
der Verbindung: ein erneuter Import trifft dieselben Objekte.

Getestet mit dem Import in Apache Superset 6.1 (lokal und auf opairs-node-001).
"""
import argparse
import io
import json
import pathlib
import uuid
import zipfile

NS = uuid.UUID("6f1c0c1e-8d0a-4b7e-9a51-0a1b2c3d4e5f")


def uid(name):
    return str(uuid.uuid5(NS, name))


ROOT = "opairs_connect_dashboard"
DEFAULT_DB_NAME = "OPAIRS Connect"
DEFAULT_DB_UUID = uid("database")
DEFAULT_URI = "postgresql://opairs_reader:XXXXXXXXXX@opairs-connect-db:5432/opairs"
OUT = pathlib.Path(__file__).with_name("OPAIRS_Connect_Dashboard.zip")
TIME_DEFAULT = "Last week"

# ---------------------------------------------------------------- Datasets

def col(name, typ, dttm=False, verbose=None):
    return {
        "column_name": name, "verbose_name": verbose, "is_dttm": dttm, "is_active": True,
        "type": typ, "advanced_data_type": None, "groupby": True, "filterable": True,
        "expression": "", "description": None, "python_date_format": None,
        "datetime_format": None, "extra": {},
    }


TS = "TIMESTAMP WITH TIME ZONE"
DP = "DOUBLE PRECISION"
# Einordnung aus opairs.asset (in allen Datasets, damit die Filter Werk,
# Bereich, Linie und Anlage ueberall greifen)
HIER = [col("anlage", "TEXT", verbose="Anlage (Bezeichnung)"), col("art", "TEXT", verbose="Anlagenart"),
        col("unternehmen", "TEXT", verbose="Unternehmen"), col("werk", "TEXT", verbose="Werk"),
        col("bereich", "TEXT", verbose="Bereich (Halle)"), col("linie", "TEXT", verbose="Linie")]
VALS = [col("avg_value", DP, verbose="Mittelwert"), col("min_value", DP, verbose="Minimum"),
        col("max_value", DP, verbose="Maximum"), col("sample_count", "BIGINT", verbose="Anzahl Werte"),
        col("bad_count", "BIGINT", verbose="Werte mit Qualitätsproblem")]
SIG = [col("beschreibung", "TEXT", verbose="Signal"), col("einheit", "TEXT", verbose="Einheit")]
OEE_MIN = [("kalender_min", "Kalenderzeit (min)"), ("unbekannt_min", "Kein Signal (min)"),
           ("keine_schicht_min", "Keine Schicht (min)"), ("planbelegung_min", "Planbelegungszeit (min)"),
           ("geplanter_stillstand_min", "Geplanter Stillstand (min)"),
           ("geplante_betriebszeit_min", "Geplante Betriebszeit (min)"), ("ruesten_min", "Rüsten (min)"),
           ("stoerung_min", "Störung (min)"), ("nettobetriebszeit_min", "Nettobetriebszeit (min)"),
           ("leerlauf_min", "Leerlauf (min)"), ("produktion_min", "Produktion (min)"),
           ("auslastung_min", "Produktion + Rüsten (min)")]
DATASETS = {
    "agg": {
        "table_name": "opairs_connect_minutenwerte", "sql": "SELECT * FROM opairs.v_machine_data_1min_ctx",
        "main_dttm_col": "bucket",
        "columns": [col("bucket", TS, True, "Minute"), col("machine", "TEXT", verbose="Anlage"),
                    col("tag", "TEXT", verbose="Tag")] + VALS + HIER + SIG,
    },
    "latest": {
        "table_name": "opairs_connect_aktueller_stand", "sql": "SELECT * FROM opairs.v_latest_1min_ctx",
        "main_dttm_col": "bucket",
        "columns": [col("machine", "TEXT", verbose="Anlage"), col("tag", "TEXT", verbose="Tag"),
                    col("bucket", TS, True, "Minute")] + VALS + HIER + SIG,
    },
    "raw": {
        "table_name": "opairs_connect_rohdaten", "sql": "SELECT * FROM opairs.v_machine_data_ctx", "main_dttm_col": "ts",
        "columns": [col("ts", TS, True, "Zeitpunkt"), col("machine", "TEXT", verbose="Anlage"),
                    col("tag", "TEXT", verbose="Tag"), col("value", DP, verbose="Wert"),
                    col("value_text", "TEXT", verbose="Textwert"), col("quality", "TEXT", verbose="Qualität")] + HIER,
    },
    "oee": {
        "table_name": "opairs_connect_zeitmodell", "sql": "SELECT * FROM opairs.v_oee_1min", "main_dttm_col": "bucket",
        "columns": [col("bucket", TS, True, "Minute"), col("machine", "TEXT", verbose="Anlage")] + HIER
                   + [col("state_code", "INTEGER", verbose="Zustandscode"), col("zustand", "TEXT", verbose="Zustand"),
                      col("zeitstufe", "TEXT", verbose="Zeitstufe")]
                   + [col(n, "INTEGER", verbose=v) for n, v in OEE_MIN]
                   + [col("taktzeit_ist_s", DP, verbose="Taktzeit Ist (s)"),
                      col("taktzeit_soll_s", DP, verbose="Taktzeit Soll (s)"),
                      col("leistungsgrad", DP, verbose="Leistungsgrad"),
                      col("qualitaetsrate", DP, verbose="Qualitätsrate"),
                      col("nutzbar_min", DP, verbose="Nutzbare Zeit (min)"),
                      col("nettoproduktiv_min", DP, verbose="Nettoproduktivzeit (min)")],
    },
    "anlage": {
        "table_name": "opairs_connect_anlagen", "sql": "SELECT * FROM opairs.v_anlage", "main_dttm_col": None,
        "columns": [col("machine", "TEXT", verbose="Anlage")] + HIER
                   + [col("sap_werk", "TEXT", verbose="SAP-Werk"), col("sap_arbeitsplatz", "TEXT", verbose="SAP-Arbeitsplatz"),
                      col("sap_equipment", "TEXT", verbose="SAP-Equipment"), col("aktiv", "BOOLEAN", verbose="aktiv"),
                      col("in_stammdaten", "BOOLEAN", verbose="in Stammdaten")],
    },
}
for k, d in DATASETS.items():
    d["uuid"] = uid("dataset-" + k)


def dataset_yaml(d, db_uuid):
    return {
        "table_name": d["table_name"], "main_dttm_col": d["main_dttm_col"], "currency_code_column": None,
        "description": "OPAIRS Connect Dashboard", "default_endpoint": None, "offset": 0, "cache_timeout": None,
        "catalog": "opairs", "schema": "opairs", "sql": d["sql"], "params": None, "template_params": None,
        "filter_select_enabled": True, "fetch_values_predicate": None, "extra": None,
        "normalize_columns": False, "always_filter_main_dttm": False, "folders": None,
        "uuid": d["uuid"],
        "metrics": [{"metric_name": "count", "verbose_name": "COUNT(*)", "metric_type": "count",
                     "expression": "COUNT(*)", "description": None, "d3format": None, "currency": None,
                     "extra": {"warning_markdown": ""}, "warning_text": None}],
        "columns": d["columns"], "version": "1.0.0", "database_uuid": db_uuid,
    }

# ---------------------------------------------------------------- Bausteine

_n = 0


def _opt(prefix):
    global _n
    _n += 1
    return f"{prefix}_{_n:04d}"


def m_sql(label, expr):
    return {"aggregate": None, "column": None, "datasourceWarning": False, "expressionType": "SQL",
            "hasCustomLabel": True, "label": label, "optionName": _opt("metric"), "sqlExpression": expr}


def f_time(col, value=TIME_DEFAULT):
    return {"clause": "WHERE", "comparator": value, "expressionType": "SIMPLE", "operator": "TEMPORAL_RANGE",
            "subject": col, "filterOptionName": _opt("filter"), "isExtra": False, "isNew": False,
            "datasourceWarning": False, "sqlExpression": None}


def f_in(col, values):
    return {"clause": "WHERE", "comparator": values, "expressionType": "SIMPLE", "operator": "IN",
            "operatorId": "IN", "subject": col, "filterOptionName": _opt("filter"), "isExtra": False,
            "isNew": False, "datasourceWarning": False, "sqlExpression": None}


def f_sql(expr):
    return {"clause": "WHERE", "comparator": None, "expressionType": "SQL", "operator": None, "subject": None,
            "filterOptionName": _opt("filter"), "isExtra": False, "isNew": False,
            "datasourceWarning": False, "sqlExpression": expr}


def c_sql(label, expr):
    return {"label": label, "sqlExpression": expr, "expressionType": "SQL"}


WAVG = "SUM(avg_value * sample_count) / NULLIF(SUM(sample_count), 0)"

# Zeitmodell (Jodlbauer) aus opairs.v_oee_1min
K_OEE = "SUM(nettoproduktiv_min) / NULLIF(SUM(planbelegung_min), 0)"
K_OEE_GB = "SUM(nettoproduktiv_min) / NULLIF(SUM(geplante_betriebszeit_min), 0)"
K_TEEP = "SUM(nettoproduktiv_min) / NULLIF(SUM(kalender_min), 0)"
K_AUSL = "1.0 * SUM(auslastung_min) / NULLIF(SUM(geplante_betriebszeit_min), 0)"
K_VERF = "1.0 * SUM(nettobetriebszeit_min) / NULLIF(SUM(geplante_betriebszeit_min), 0)"
K_LEIST = "SUM(nutzbar_min) / NULLIF(SUM(nettobetriebszeit_min), 0)"
K_QUAL = "SUM(nettoproduktiv_min) / NULLIF(SUM(nutzbar_min), 0)"
K_ABD = "1 - 1.0 * SUM(unbekannt_min) / NULLIF(SUM(kalender_min), 0)"

CHARTS = []  # dicts: id, name, ds, viz, params, desc


def chart(name, ds, viz, params, desc=None):
    cid = len(CHARTS) + 1
    p = {"viz_type": viz, "extra_form_data": {}, "dashboards": [], **params}
    CHARTS.append({"id": cid, "name": name, "ds": ds, "viz": viz, "params": p, "desc": desc,
                   "uuid": uid(f"chart-{name}")})
    return cid


def big(name, ds, metric, filters, subtitle, fmt="SMART_NUMBER"):
    return chart(name, ds, "big_number_total", {
        "metric": metric, "adhoc_filters": filters, "subtitle": subtitle, "header_font_size": 0.4,
        "subtitle_font_size": 0.15, "show_metric_name": False, "y_axis_format": fmt,
        "time_format": "smart_date", "force_timestamp_formatting": False, "conditional_formatting": []})


def line(name, ds, metrics, filters, groupby=None, grain="PT15M", fmt="SMART_NUMBER", y_title="",
         xcol="bucket", desc=None):
    bounds = [0, 1] if fmt.endswith("%") else [None, None]
    return chart(name, ds, "echarts_timeseries_line", {
        "x_axis": xcol, "time_grain_sqla": grain, "x_axis_sort_asc": True, "x_axis_sort_series": "name",
        "x_axis_sort_series_ascending": True, "metrics": metrics,
        "groupby": groupby if groupby is not None else ["machine"], "adhoc_filters": filters,
        "order_desc": True, "row_limit": 10000, "truncate_metric": True, "show_empty_columns": True,
        "comparison_type": "values", "annotation_layers": [], "forecastPeriods": 10, "forecastInterval": 0.8,
        "x_axis_title_margin": 15, "y_axis_title": y_title, "y_axis_title_margin": 30,
        "y_axis_title_position": "Left", "sort_series_type": "sum", "color_scheme": "supersetColors",
        "seriesType": "line", "only_total": True, "opacity": 0.2, "markerSize": 6, "show_legend": True,
        "legendType": "scroll", "legendOrientation": "top", "x_axis_time_format": "smart_date",
        "rich_tooltip": True, "showTooltipTotal": False, "tooltipTimeFormat": "smart_date",
        "y_axis_format": fmt, "y_axis_bounds": bounds, "truncateYAxis": fmt.endswith("%"),
        "truncateXAxis": True, "zoomable": True,
        "markerEnabled": False}, desc)


def bar(name, ds, x, metrics, filters, groupby=None, fmt="SMART_NUMBER", stack=None, desc=None, y_title="",
        grain=None, show_value=True, rotate=None):
    extra = {"time_grain_sqla": grain} if grain else {}
    if rotate:
        extra["xAxisLabelRotation"] = rotate
    return chart(name, ds, "echarts_timeseries_bar", {
        **extra, "x_axis": x, "x_axis_sort_asc": True, "metrics": metrics, "groupby": groupby or [],
        "adhoc_filters": filters, "order_desc": True, "row_limit": 10000, "truncate_metric": True,
        "show_empty_columns": True, "comparison_type": "values", "annotation_layers": [],
        "forecastPeriods": 10, "forecastInterval": 0.8, "orientation": "vertical",
        "x_axis_title_margin": 15, "y_axis_title": y_title, "y_axis_title_margin": 30,
        "y_axis_title_position": "Left", "sort_series_type": "sum", "color_scheme": "supersetColors",
        "show_value": show_value, "only_total": True, "stack": stack, "show_legend": True, "legendType": "scroll",
        "legendOrientation": "top", "x_axis_time_format": "smart_date", "xAxisLabelInterval": "auto",
        "y_axis_format": fmt, "y_axis_bounds": [None, None], "truncateXAxis": True, "rich_tooltip": True,
        "showTooltipTotal": True, "tooltipSortByMetric": True, "tooltipTimeFormat": "smart_date"}, desc)


NUMFMT = {k: {"d3NumberFormat": ",.2f"} for k in ("avg_value", "min_value", "max_value", "value")}


def table_raw(name, ds, columns, filters, order, limit=1000, temporal=None):
    return chart(name, ds, "table", {"column_config": {k: v for k, v in NUMFMT.items() if k in columns},
        "query_mode": "raw", "groupby": [], "all_columns": columns, "percent_metrics": [],
        "temporal_columns_lookup": temporal or {}, "adhoc_filters": filters,
        "order_by_cols": [json.dumps(o) for o in order], "server_pagination": False, "row_limit": limit,
        "order_desc": True, "table_timestamp_format": "%d.%m.%Y %H:%M:%S", "show_cell_bars": False,
        "color_pn": True, "allow_render_html": False, "include_search": True, "conditional_formatting": []})


def table_agg(name, ds, groupby, metrics, filters, limit=1000, sort_metric=None, column_config=None):
    return chart(name, ds, "table", {"column_config": column_config or {},
        "query_mode": "aggregate", "groupby": groupby, "metrics": metrics, "all_columns": [],
        "percent_metrics": [], "adhoc_filters": filters, "order_by_cols": [], "server_pagination": False,
        "row_limit": limit, "order_desc": True, "timeseries_limit_metric": sort_metric,
        "table_timestamp_format": "%d.%m.%Y %H:%M", "show_cell_bars": True, "color_pn": True,
        "allow_render_html": False, "include_search": True, "conditional_formatting": []})

# ---------------------------------------------------------------- Charts

T = f_time
EXCL_TIME = []  # Charts ohne Zeitfilter des Dashboards

# Uebersicht
c_anlagen = big("[OPAIRS Connect] Anlagen mit Daten", "raw",
                m_sql("Anlagen mit Daten", "COUNT(DISTINCT machine)"),
                [f_sql("ts > now() - interval '5 minutes'")], "liefern in den letzten 5 Minuten")
EXCL_TIME.append(c_anlagen)
c_lauf = big("[OPAIRS Connect] Laufzeitanteil", "agg", m_sql("Laufzeitanteil", WAVG),
             [T("bucket"), f_in("tag", ["state"])], "alle Anlagen im Zeitraum", ".1%")
c_io_mon = big("[OPAIRS Connect] iO-Quote Montage", "agg", m_sql("iO-Quote Montage", WAVG),
               [T("bucket"), f_in("tag", ["pruef_ergebnis"])], "Montagelinien im Zeitraum", ".1%")
c_io_sgm = big("[OPAIRS Connect] iO-Quote Spritzguss", "agg", m_sql("iO-Quote Spritzguss", WAVG),
               [T("bucket"), f_in("tag", ["teil_io"])], "Spritzgussmaschinen im Zeitraum", ".1%")
c_bad = big("[OPAIRS Connect] Werte mit Qualitätsproblem", "agg",
            m_sql("Werte mit Qualitätsproblem", "SUM(bad_count)"), [T("bucket")],
            "Uncertain/Bad im Zeitraum")
c_lauf_anl = bar("[OPAIRS Connect] Laufzeitanteil je Anlage", "agg", "machine",
                 [m_sql("Laufzeitanteil", WAVG)], [T("bucket"), f_in("tag", ["state"])], fmt=".0%")
c_lauf_verl = line("[OPAIRS Connect] Laufzeitanteil im Verlauf", "agg", [m_sql("Laufzeitanteil", WAVG)],
                   [T("bucket"), f_in("tag", ["state"])], groupby=["art"], grain="PT1H", fmt=".0%")
c_stand = table_raw("[OPAIRS Connect] Aktueller Stand", "latest",
                    ["linie", "machine", "tag", "beschreibung", "avg_value", "einheit", "min_value", "max_value",
                     "bad_count", "bucket"],
                    [], [["machine", True], ["tag", True]], temporal={"bucket": True})

# Kennzahlen (OEE, TEEP, Auslastung) aus dem Zeitmodell
PCT = {"d3NumberFormat": ".1%"}
c_k = [
    big("[OPAIRS Connect] OEE", "oee", m_sql("OEE", K_OEE), [T("bucket")],
        "Nettoproduktivzeit / Planbelegungszeit", ".1%"),
    big("[OPAIRS Connect] OEE ohne geplante Stillstände", "oee", m_sql("OEE ohne geplante Stillstände", K_OEE_GB),
        [T("bucket")], "Nettoproduktivzeit / geplante Betriebszeit", ".1%"),
    big("[OPAIRS Connect] TEEP", "oee", m_sql("TEEP", K_TEEP), [T("bucket")],
        "Nettoproduktivzeit / Kalenderzeit", ".1%"),
    big("[OPAIRS Connect] Auslastung", "oee", m_sql("Auslastung", K_AUSL), [T("bucket")],
        "(Produktion + Rüsten) / geplante Betriebszeit", ".1%"),
    big("[OPAIRS Connect] Datenabdeckung", "oee", m_sql("Datenabdeckung", K_ABD), [T("bucket")],
        "Anteil der Zeit mit gültigem Zustand", ".1%"),
]
c_k_faktoren = bar("[OPAIRS Connect] OEE-Faktoren je Anlage", "oee", "anlage",
                   [m_sql("Verfügbarkeit", K_VERF), m_sql("Leistung", K_LEIST), m_sql("Qualität", K_QUAL),
                    m_sql("OEE", K_OEE)], [T("bucket")], fmt=".0%", show_value=False, rotate=45,
                   desc="Verfügbarkeit = Nettobetriebszeit / geplante Betriebszeit, Leistung = nutzbare Zeit / "
                        "Nettobetriebszeit, Qualität = Nettoproduktivzeit / nutzbare Zeit")
c_k_linie = bar("[OPAIRS Connect] OEE je Linie und Tag", "oee", "bucket", [m_sql("OEE", K_OEE)], [T("bucket")],
                groupby=["linie"], grain="P1D", fmt=".0%", show_value=False,
                desc="Tageswerte (UTC), Zeiten aller Anlagen der Linie summiert")
c_k_zeit = bar("[OPAIRS Connect] Zeitverteilung je Anlage", "oee", "anlage",
               [m_sql("Stunden", "SUM(kalender_min) / 60.0")], [T("bucket")], groupby=["zustand"],
               stack="Stack", show_value=False, y_title="Stunden", rotate=45)
c_k_verlauf = bar("[OPAIRS Connect] Zustände im Verlauf", "oee", "bucket",
                  [m_sql("Stunden", "SUM(kalender_min) / 60.0")], [T("bucket")], groupby=["zustand"],
                  stack="Stack", show_value=False, y_title="Stunden", grain="PT1H")
c_k_tab = table_agg("[OPAIRS Connect] Kennzahlen je Anlage", "oee", ["werk", "bereich", "linie", "anlage"],
                    [m_sql("OEE", K_OEE), m_sql("OEE o. gepl. Stillst.", K_OEE_GB), m_sql("TEEP", K_TEEP),
                     m_sql("Auslastung", K_AUSL), m_sql("Verfügbarkeit", K_VERF), m_sql("Leistung", K_LEIST),
                     m_sql("Qualität", K_QUAL),
                     m_sql("Störung (h)", "SUM(stoerung_min) / 60.0"), m_sql("Rüsten (h)", "SUM(ruesten_min) / 60.0"),
                     m_sql("Leerlauf (h)", "SUM(leerlauf_min) / 60.0"),
                     m_sql("Gepl. Stillstand (h)", "SUM(geplanter_stillstand_min) / 60.0"),
                     m_sql("Datenabdeckung", K_ABD)],
                    [T("bucket")],
                    column_config={k: PCT for k in ("OEE", "OEE o. gepl. Stillst.", "TEEP", "Auslastung",
                                                     "Verfügbarkeit", "Leistung", "Qualität", "Datenabdeckung")}
                    | {k: {"d3NumberFormat": ",.1f"} for k in ("Störung (h)", "Rüsten (h)", "Leerlauf (h)",
                                                                 "Gepl. Stillstand (h)")})
EXCL_TIME.append(c_stand)

# CNC
c_cnc = [
    line("[OPAIRS Connect] CNC Spindeldrehzahl", "agg", [m_sql("Drehzahl (1/min)", "AVG(avg_value)")],
         [T("bucket"), f_in("tag", ["spindle_speed_rpm"])], y_title="1/min"),
    line("[OPAIRS Connect] CNC Temperatur", "agg", [m_sql("Temperatur (°C)", "AVG(avg_value)")],
         [T("bucket"), f_in("tag", ["temperature_c"])], y_title="°C"),
    line("[OPAIRS Connect] CNC Leistung", "agg", [m_sql("Leistung (kW)", "AVG(avg_value)")],
         [T("bucket"), f_in("tag", ["power_kw"])], y_title="kW"),
    line("[OPAIRS Connect] CNC Vibration (Maximum)", "agg", [m_sql("Vibration max (mm/s)", "MAX(max_value)")],
         [T("bucket"), f_in("tag", ["vibration_mm_s"])], y_title="mm/s"),
]
c_cnc_bad = bar("[OPAIRS Connect] Qualitätsprobleme je Anlage", "agg", "machine",
                [m_sql("Werte mit Qualitätsproblem", "SUM(bad_count)")], [T("bucket")])

# Spritzguss
c_sgm = [
    line("[OPAIRS Connect] Spritzguss Werkzeugtemperatur", "agg", [m_sql("Werkzeugtemperatur (°C)", "AVG(avg_value)")],
         [T("bucket"), f_in("tag", ["werkzeugtemperatur_c"])], y_title="°C"),
    line("[OPAIRS Connect] Spritzguss Massetemperatur", "agg", [m_sql("Massetemperatur (°C)", "AVG(avg_value)")],
         [T("bucket"), f_in("tag", ["massetemperatur_c"])], y_title="°C"),
    line("[OPAIRS Connect] Spritzguss Zykluszeit", "agg", [m_sql("Zykluszeit (s)", "AVG(avg_value)")],
         [T("bucket"), f_in("tag", ["zykluszeit_s"])], y_title="s"),
    line("[OPAIRS Connect] Spritzguss Einspritzdruck", "agg", [m_sql("Einspritzdruck (bar)", "AVG(avg_value)")],
         [T("bucket"), f_in("tag", ["einspritzdruck_bar"])], y_title="bar"),
]
c_sgm_io = line("[OPAIRS Connect] Spritzguss iO-Quote", "agg", [m_sql("iO-Quote", WAVG)],
                [T("bucket"), f_in("tag", ["teil_io"])], grain="PT1H", fmt=".0%")
c_sgm_wz = table_agg("[OPAIRS Connect] Spritzguss Werkzeug je Tag", "raw",
                     [c_sql("Tag", "to_char(ts AT TIME ZONE 'UTC', 'YYYY-MM-DD')"), "machine",
                      c_sql("Werkzeug", "value_text")],
                     [m_sql("Erste Meldung (UTC)", "to_char(MIN(ts) AT TIME ZONE 'UTC', 'HH24:MI')"),
                      m_sql("Letzte Meldung (UTC)", "to_char(MAX(ts) AT TIME ZONE 'UTC', 'HH24:MI')")],
                     [T("ts"), f_in("tag", ["werkzeug"])],
                     sort_metric=m_sql("Sortierung", "MAX(ts)"))
c_sgm_nio = bar("[OPAIRS Connect] Spritzguss NiO-Gründe", "raw", c_sql("NiO-Grund", "value_text"),
                [m_sql("Anzahl", "COUNT(*)")],
                [T("ts"), f_in("tag", ["nio_grund"]), f_sql("machine LIKE '%sgm%'")],
                groupby=["machine"], stack="Stack")

# Montage
c_mon = [
    line("[OPAIRS Connect] Schraubstation Drehmoment", "agg",
         [m_sql("Drehmoment Mittel (Nm)", "AVG(avg_value)"), m_sql("Drehmoment max (Nm)", "MAX(max_value)")],
         [T("bucket"), f_in("tag", ["schraub_drehmoment_nm"])], groupby=[], y_title="Nm",
         desc="Steigt über die Schicht (Bit-Verschleiß)"),
    line("[OPAIRS Connect] Dichtheitsprüfung Leckrate (Maximum)", "agg",
         [m_sql("Leckrate max (ccm/min)", "MAX(max_value)")],
         [T("bucket"), f_in("tag", ["leckrate_ccm_min"])], groupby=[], y_title="ccm/min",
         desc="NiO ab 2,0 ccm/min"),
    line("[OPAIRS Connect] Einpressstation Kraft", "agg",
         [m_sql("Kraft min (kN)", "MIN(min_value)"), m_sql("Kraft Mittel (kN)", "AVG(avg_value)"),
          m_sql("Kraft max (kN)", "MAX(max_value)")],
         [T("bucket"), f_in("tag", ["einpresskraft_kn"])], groupby=[], y_title="kN",
         desc="iO 7,2 bis 8,8 kN"),
    line("[OPAIRS Connect] Endprüfung Isolationswiderstand (Minimum)", "agg",
         [m_sql("Isolationswiderstand min (MOhm)", "MIN(min_value)")],
         [T("bucket"), f_in("tag", ["isolationswiderstand_mohm"])], groupby=[], y_title="MOhm",
         desc="NiO unter 100 MOhm"),
]
c_mon_io = line("[OPAIRS Connect] Montage iO-Quote je Linie", "agg", [m_sql("iO-Quote", WAVG)],
                [T("bucket"), f_in("tag", ["pruef_ergebnis"])], grain="PT1H", fmt=".0%")
c_mon_takt = line("[OPAIRS Connect] Montage Taktzeit", "agg", [m_sql("Taktzeit (s)", "AVG(avg_value)")],
                  [T("bucket"), f_in("tag", ["taktzeit_s"])], grain="PT1H", y_title="s")
c_mon_nio = bar("[OPAIRS Connect] Montage NiO-Gründe", "raw", c_sql("NiO-Grund", "value_text"),
                [m_sql("Anzahl", "COUNT(*)")],
                [T("ts"), f_in("tag", ["nio_grund"]), f_sql("machine LIKE '%mon%'")],
                groupby=["machine"], stack="Stack")

# Rohdaten
c_raw = table_raw("[OPAIRS Connect] Rohdaten letzte 15 Minuten", "raw",
                  ["ts", "machine", "tag", "value", "value_text", "quality"],
                  [f_sql("ts > now() - interval '15 minutes'")], [["ts", False]], limit=10000,
                  temporal={"ts": True})
EXCL_TIME.append(c_raw)

# ---------------------------------------------------------------- Layout

POS = {"DASHBOARD_VERSION_KEY": "v2",
       "ROOT_ID": {"children": ["GRID_ID"], "id": "ROOT_ID", "type": "ROOT"},
       "HEADER_ID": {"id": "HEADER_ID", "meta": {"text": "OPAIRS Connect"}, "type": "HEADER"}}
GRID = {"children": [], "id": "GRID_ID", "parents": ["ROOT_ID"], "type": "GRID"}
POS["GRID_ID"] = GRID
TABS_ID = "TABS-opairs"
TABS = {"children": [], "id": TABS_ID, "meta": {}, "parents": ["ROOT_ID", "GRID_ID"], "type": "TABS"}
POS[TABS_ID] = TABS
GRID["children"].append(TABS_ID)
_row = 0
BY_ID = {c["id"]: c for c in CHARTS}
TAB_OF = {}


def tab(key, title):
    tid = f"TAB-{key}"
    POS[tid] = {"children": [], "id": tid, "meta": {"defaultText": "Tab title", "placeholder": "Tab title",
                                                     "text": title}, "parents": ["ROOT_ID", "GRID_ID", TABS_ID],
                "type": "TAB"}
    TABS["children"].append(tid)
    return tid


def row(tid, items, height=50):
    """items: Liste (chart_id oder ('md', text), breite)."""
    global _row
    _row += 1
    rid = f"ROW-{_row:03d}"
    parents = ["ROOT_ID", "GRID_ID", TABS_ID, tid]
    POS[rid] = {"children": [], "id": rid, "meta": {"background": "BACKGROUND_TRANSPARENT"},
                "parents": parents, "type": "ROW"}
    POS[tid]["children"].append(rid)
    assert sum(w for _, w in items) <= 12, items
    for i, (item, width) in enumerate(items):
        if isinstance(item, tuple):
            mid = f"MARKDOWN-{_row:03d}-{i}"
            POS[mid] = {"children": [], "id": mid, "meta": {"code": item[1], "height": height, "width": width},
                        "parents": parents + [rid], "type": "MARKDOWN"}
            POS[rid]["children"].append(mid)
            continue
        c = BY_ID[item]
        key = f"CHART-{item:03d}"
        POS[key] = {"children": [], "id": key, "meta": {"chartId": item, "height": height,
                                                          "sliceName": c["name"], "uuid": c["uuid"],
                                                          "sliceNameOverride": c["name"].replace("[OPAIRS Connect] ", ""),
                                                          "width": width},
                    "parents": parents + [rid], "type": "CHART"}
        POS[rid]["children"].append(key)
        TAB_OF[item] = tid


LEGENDE = """### Hinweise

- **Filter Werk, Bereich, Linie:** aus den Stammdaten `opairs.asset`. Anlagen ohne Eintrag erscheinen als *(nicht zugeordnet)*.
- **Laufzeitanteil:** Anteil der Zeit mit `state = 1` (Anlage produziert).
- **iO-Quote:** Anteil guter Teile aus `pruef_ergebnis` (Montage) bzw. `teil_io` (Spritzguss).
- **Qualitätsproblem:** Werte mit Qualität *Uncertain* oder *Bad*. Sie zählen nicht in Mittelwerte.
- Zeiten in **UTC**. Minutenwerte entstehen alle 5 Minuten, Rohdaten alle 10 s.
- Quelle: Schema `opairs` der OPAIRS-Connect-Datenbank."""

t1 = tab("uebersicht", "Übersicht")
row(t1, [(c_anlagen, 3), (c_lauf, 3), (c_io_mon, 2), (c_io_sgm, 2), (c_bad, 2)], height=25)
row(t1, [(c_lauf_anl, 6), (c_lauf_verl, 6)])
row(t1, [(c_stand, 8), (("md", LEGENDE), 4)], height=70)
ZEITMODELL = """### Zeitmodell

| Stufe | Abzug (Zustand) |
|---|---|
| Kalenderzeit | |
| Planbelegungszeit | − keine Schicht (8) |
| Geplante Betriebszeit | − Wartung, Reinigung, Pause (5, 6, 7) |
| Nettobetriebszeit | − Störung, Rüsten (3, 4) |
| Nutzbare Zeit | − Leerlauf (2), − Takt langsamer als Soll |
| Nettoproduktivzeit | × Qualitätsrate |

- **OEE** = Nettoproduktivzeit / Planbelegungszeit
- **TEEP** = Nettoproduktivzeit / Kalenderzeit
- **Auslastung** = (Produktion + Rüsten) / geplante Betriebszeit
- Zustand **0** (kein Signal) zählt nur zur Kalenderzeit, siehe *Datenabdeckung*.
- Zustände: Tabelle `opairs.state_def`, Signale je Anlage: `opairs.asset`."""

tk = tab("kennzahlen", "Kennzahlen")
row(tk, [(c_k[0], 3), (c_k[1], 3), (c_k[2], 2), (c_k[3], 2), (c_k[4], 2)], height=25)
row(tk, [(c_k_faktoren, 8), (("md", ZEITMODELL), 4)], height=60)
row(tk, [(c_k_zeit, 6), (c_k_linie, 6)], height=60)
row(tk, [(c_k_verlauf, 12)])
row(tk, [(c_k_tab, 12)], height=70)
t2 = tab("cnc", "CNC")
row(t2, [(c_cnc[0], 6), (c_cnc[1], 6)])
row(t2, [(c_cnc[2], 6), (c_cnc[3], 6)])
row(t2, [(c_cnc_bad, 12)])
t3 = tab("spritzguss", "Spritzguss")
row(t3, [(c_sgm[0], 6), (c_sgm[1], 6)])
row(t3, [(c_sgm[2], 6), (c_sgm[3], 6)])
row(t3, [(c_sgm_io, 6), (c_sgm_nio, 6)])
row(t3, [(c_sgm_wz, 12)])
t4 = tab("montage", "Montage")
row(t4, [(c_mon[0], 6), (c_mon[1], 6)])
row(t4, [(c_mon[2], 6), (c_mon[3], 6)])
row(t4, [(c_mon_io, 4), (c_mon_takt, 4), (c_mon_nio, 4)])
t5 = tab("rohdaten", "Rohdaten")
row(t5, [(c_raw, 12)], height=100)

assert set(TAB_OF) == set(BY_ID), "nicht alle Charts im Layout"

# ---------------------------------------------------------------- Filter

ALL = sorted(BY_ID)
TIME_SCOPE = [c for c in ALL if c not in EXCL_TIME]
TABS_ALL = TABS["children"]


def f_select(key, name, column, parent=None):
    return {"id": f"NATIVE_FILTER-opairs-{key}", "type": "NATIVE_FILTER", "name": name,
            "filterType": "filter_select", "description": "",
            "targets": [{"column": {"name": column}, "datasetUuid": DATASETS["anlage"]["uuid"]}],
            "controlValues": {"enableEmptyFilter": False, "defaultToFirstItem": False, "creatable": False,
                              "multiSelect": True, "searchAllOptions": False, "inverseSelection": False},
            "defaultDataMask": {"extraFormData": {}, "filterState": {}, "ownState": {}},
            "cascadeParentIds": [f"NATIVE_FILTER-opairs-{parent}"] if parent else [], "sortMetric": None,
            "scope": {"rootPath": ["ROOT_ID"], "excluded": []}, "chartsInScope": ALL, "tabsInScope": TABS_ALL}


FILTERS = [
    {"id": "NATIVE_FILTER-opairs-zeitraum", "type": "NATIVE_FILTER", "name": "Zeitraum",
     "filterType": "filter_time", "description": "", "targets": [{}],
     "controlValues": {"enableEmptyFilter": False},
     "defaultDataMask": {"extraFormData": {"time_range": TIME_DEFAULT},
                         "filterState": {"value": TIME_DEFAULT}, "ownState": {}},
     "cascadeParentIds": [], "scope": {"rootPath": ["ROOT_ID"], "excluded": EXCL_TIME},
     "chartsInScope": TIME_SCOPE, "tabsInScope": TABS_ALL},
    f_select("werk", "Werk", "werk"),
    f_select("bereich", "Bereich (Halle)", "bereich", "werk"),
    f_select("linie", "Linie", "linie", "bereich"),
    f_select("anlage", "Anlage", "machine", "linie"),
]

LABEL_COLORS = {"CNC": "#1F77B4", "Spritzguss": "#FF7F0E", "Montage": "#2CA02C",
                # Zustaende (Namen wie in opairs.state_def)
                "Produktion": "#2CA02C", "Leerlauf / wartet": "#F2C94C", "Technische Störung": "#D62728",
                "Rüsten / Produktwechsel": "#FF7F0E", "Wartung geplant": "#1F77B4",
                "Reinigung geplant": "#17BECF", "Pause / organisatorisch": "#9467BD",
                "Keine Schicht": "#C7C7C7", "Unbekannt / kein Signal": "#4D4D4D"}

dashboard = {
    "dashboard_title": "OPAIRS Connect", "description": None, "css": "", "slug": "opairs-connect",
    "certified_by": "", "certification_details": "", "published": True,
    "uuid": uid("dashboard"), "position": POS,
    "metadata": {
        "chart_configuration": {}, "global_chart_configuration": {
            "scope": {"rootPath": ["ROOT_ID"], "excluded": []}, "chartsInScope": ALL},
        "color_scheme": "", "refresh_frequency": 60, "expanded_slices": {}, "label_colors": LABEL_COLORS,
        "timed_refresh_immune_slices": [], "cross_filters_enabled": True, "default_filters": "{}",
        "chart_customization_config": [], "filter_bar_orientation": "HORIZONTAL",
        "show_chart_timestamps": False, "color_scheme_domain": [], "shared_label_colors": [],
        "map_label_colors": {}, "native_filter_configuration": FILTERS},
    "theme_uuid": None, "version": "1.0.0",
}

# ---------------------------------------------------------------- Schreiben


def safe(name):
    return "".join(ch if ch.isalnum() else "_" for ch in name).strip("_")


def members(data):
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        return {n: z.read(n) for n in z.namelist()}


def build(db_uuid, db_name, uri, out, check=False):
    database = {
        "database_name": db_name, "sqlalchemy_uri": uri,
        "cache_timeout": None, "expose_in_sqllab": True, "allow_run_async": False, "allow_ctas": False,
        "allow_cvas": False, "allow_dml": False, "allow_file_upload": False,
        "extra": {"metadata_params": {}, "engine_params": {}, "metadata_cache_timeout": {},
                  "schemas_allowed_for_file_upload": []},
        "impersonate_user": False, "configuration_method": "sqlalchemy_form", "uuid": db_uuid,
        "version": "1.0.0",
    }
    files = {
        # fester Zeitstempel: gleicher Generator ergibt dieselbe ZIP (CI-Pruefung)
        "metadata.yaml": {"version": "1.0.0", "type": "Dashboard", "timestamp": "2026-11-01T00:00:00+00:00"},
        f"databases/{safe(db_name)}.yaml": database,
        "dashboards/OPAIRS_Connect.yaml": dashboard,
    }
    for d in DATASETS.values():
        files[f"datasets/{safe(db_name)}/{d['table_name']}.yaml"] = dataset_yaml(d, db_uuid)
    for c in CHARTS:
        p = dict(c["params"])
        p["slice_id"] = c["id"]
        files[f"charts/{safe(c['name'])}_{c['id']}.yaml"] = {
            "slice_name": c["name"], "description": c["desc"], "certified_by": None,
            "certification_details": None, "viz_type": c["viz"], "params": p, "query_context": None,
            "cache_timeout": None, "uuid": c["uuid"], "version": "1.0.0",
            "dataset_uuid": DATASETS[c["ds"]]["uuid"]}
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for name, content in sorted(files.items()):
            info = zipfile.ZipInfo(f"{ROOT}/{name}", date_time=(2026, 11, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, json.dumps(content, ensure_ascii=False, indent=1) + "\n")
    if check:
        # Inhalt vergleichen, nicht Bytes: Deflate unterscheidet sich je zlib-Version
        old = pathlib.Path(out)
        if not old.exists() or members(old.read_bytes()) != members(buf.getvalue()):
            raise SystemExit(f"{out} ist veraltet: python3 superset/build_dashboard.py "
                             "ausfuehren und die ZIP einchecken")
        print(f"{out}: aktuell")
        return
    pathlib.Path(out).write_bytes(buf.getvalue())
    print(f"{out}: {len(CHARTS)} Charts, {len(DATASETS)} Datasets, Verbindung {db_name!r} ({db_uuid})")
    print("Nach dem Import: python3 superset/set_query_context.py --url <superset> --user <admin> "
          "ausfuehren (Query-Kontext fuer die API, Kennwort in SUPERSET_PASSWORD)")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--database-uuid", default=DEFAULT_DB_UUID,
                    help="UUID einer bestehenden Superset-Verbindung (Standard: eigene Verbindung)")
    ap.add_argument("--database-name", default=DEFAULT_DB_NAME,
                    help="Name der Verbindung (bei bestehender Verbindung deren Name)")
    ap.add_argument("--uri", default=DEFAULT_URI, help="SQLAlchemy-URI, nur fuer eine neue Verbindung")
    ap.add_argument("--out", default=str(OUT))
    ap.add_argument("--check", action="store_true",
                    help="nur pruefen, ob die vorhandene ZIP zum Generator passt")
    a = ap.parse_args()
    build(a.database_uuid, a.database_name, a.uri, a.out, a.check)
