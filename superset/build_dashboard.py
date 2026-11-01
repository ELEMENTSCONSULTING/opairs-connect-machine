#!/usr/bin/env python3
"""Baut den Superset-Export "OPAIRS Connect" (Datenbank, Datasets, Charts, Dashboard).

    python3 superset/build_dashboard.py            -> superset/OPAIRS_Connect_Dashboard.zip
    python3 superset/build_dashboard.py --uri ...  -> andere Datenbank-URI (z. B. Tests)

Nur Standardbibliothek. Die Dateien sind JSON und damit gueltiges YAML, so wie
Superset sie beim Import erwartet. Alle UUIDs sind fest (uuid5): ein erneuter
Import mit "Overwrite" aktualisiert dieselben Objekte, statt Kopien anzulegen.

Getestet mit dem Import in Apache Superset 6.0 und 6.1 (Felder, die nur 6.1
kennt, sind bewusst weggelassen).
"""

import argparse
import io
import json
import pathlib
import uuid
import zipfile

NS = uuid.UUID("8f6c2b1e-4c1a-4d55-9a57-0b5c0de0a1f5")
VERSION = "1.0.0"
DB_NAME = "OPAIRS Connect"
DEFAULT_URI = "postgresql://opairs_reader:XXXXXXXXXX@opairs-connect-db:5432/opairs"
TIME_RANGE = 'DATEADD(DATETIME("now"), -7, day) : now'
OUT = pathlib.Path(__file__).with_name("OPAIRS_Connect_Dashboard.zip")


def uid(name):
    return str(uuid.uuid5(NS, name))


# Anlagenart aus dem Namensschema <prefix>-<art>-<nr> (Demo: demo-cnc-01 ...)
ART_SQL = (
    "CASE split_part({col}, '-', 2) WHEN 'cnc' THEN 'CNC' "
    "WHEN 'sgm' THEN 'Spritzguss' WHEN 'mon' THEN 'Montage' ELSE 'Sonstige' END"
)


# --------------------------------------------------------------------------
# Datasets
# --------------------------------------------------------------------------

def col(name, typ, dttm=False, expression="", verbose=None, description=None):
    return {
        "column_name": name, "verbose_name": verbose, "is_dttm": dttm,
        "is_active": True, "type": typ, "advanced_data_type": None,
        "groupby": True, "filterable": True, "expression": expression,
        "description": description, "python_date_format": None,
        "extra": {},
    }


def metric(name, expression, verbose, d3format=None, description=None):
    return {
        "metric_name": name, "verbose_name": verbose, "metric_type": None,
        "expression": expression, "description": description,
        "d3format": d3format, "currency": None,
        "extra": {"warning_markdown": ""}, "warning_text": None,
    }


COUNT = metric("count", "COUNT(*)", "Anzahl")
GEWICHTET = "SUM(avg_value * sample_count) / NULLIF(SUM(sample_count), 0)"
AGG_METRICS = [
    COUNT,
    metric("mittelwert", GEWICHTET, "Mittelwert",
           description="Mittelwert, gewichtet mit der Anzahl guter Werte je Minute"),
    metric("anteil", GEWICHTET, "Anteil", ".1%",
           "Für 1/0-Signale (state, teil_io, pruef_ergebnis): Anteil der Werte = 1"),
    metric("minimum", "MIN(min_value)", "Minimum"),
    metric("maximum", "MAX(max_value)", "Maximum"),
    metric("messwerte", "SUM(sample_count)", "Messwerte (gut)", ",d"),
    metric("schlechte_werte", "SUM(bad_count)", "Werte Uncertain/Bad", ",d"),
    metric("quote_schlecht",
           "SUM(bad_count)::float / NULLIF(SUM(bad_count + sample_count), 0)",
           "Anteil Uncertain/Bad", ".2%"),
]

AGG_COLUMNS = [
    col("bucket", "TIMESTAMP WITH TIME ZONE", dttm=True, verbose="Minute (UTC)"),
    col("machine", "TEXT", verbose="Anlage"),
    col("tag", "TEXT", verbose="Signal"),
    col("avg_value", "DOUBLE PRECISION", verbose="Mittel"),
    col("min_value", "DOUBLE PRECISION", verbose="Min"),
    col("max_value", "DOUBLE PRECISION", verbose="Max"),
    col("sample_count", "BIGINT", verbose="Werte (gut)"),
    col("bad_count", "BIGINT", verbose="Uncertain/Bad"),
    col("anlagenart", "TEXT", expression=ART_SQL.format(col="machine"),
        verbose="Anlagenart"),
]

STATUS_SQL = """WITH anlagen AS (
    SELECT machine, max(bucket) + interval '1 minute' AS letzter_wert
      FROM opairs.machine_data_1min
     WHERE bucket > now() - interval '30 days'
     GROUP BY machine
), frisch AS (
    SELECT machine, max(ts) AS letzter_wert,
           count(*) FILTER (WHERE ts > now() - interval '10 minutes') AS werte_10min
      FROM opairs.machine_data
     WHERE ts > now() - interval '1 hour'
     GROUP BY machine
), zustand AS (
    SELECT DISTINCT ON (machine, tag) machine, tag, value, value_text
      FROM opairs.machine_data
     WHERE tag IN ('status', 'state') AND ts > now() - interval '1 hour'
     ORDER BY machine, tag, ts DESC
)
, basis AS (
    SELECT machine,
           COALESCE(f.letzter_wert, a.letzter_wert) AS letzter_wert,
           COALESCE(f.werte_10min, 0) AS werte_10min
      FROM anlagen a
      FULL JOIN frisch f USING (machine)
)
SELECT b.machine,
       """ + ART_SQL.format(col="b.machine") + """ AS anlagenart,
       CASE WHEN b.letzter_wert > now() - interval '1 minute'
            THEN 'online' ELSE 'offline' END AS verbindung,
       COALESCE(st.value_text,
                CASE s.value WHEN 1 THEN 'Produktion' WHEN 0 THEN 'Stillstand' END,
                '-') AS status,
       b.letzter_wert,
       EXTRACT(EPOCH FROM now() - b.letzter_wert)::bigint AS alter_s,
       b.werte_10min
  FROM basis b
  LEFT JOIN zustand st ON st.machine = b.machine AND st.tag = 'status'
  LEFT JOIN zustand s  ON s.machine = b.machine AND s.tag = 'state'"""

EREIGNIS_SQL = """SELECT ts, machine,
       """ + ART_SQL.format(col="machine") + """ AS anlagenart,
       tag, value_text
  FROM opairs.machine_data
 WHERE value_text IS NOT NULL"""


def dataset(key, table, dttm, columns, metrics, sql="", description=None):
    return key, {
        "table_name": table, "main_dttm_col": dttm,
        "description": description,
        "default_endpoint": None, "offset": 0, "cache_timeout": None,
        "catalog": "opairs", "schema": "opairs", "sql": sql, "params": None,
        "template_params": None, "filter_select_enabled": True,
        "fetch_values_predicate": None, "extra": None,
        "normalize_columns": False, "always_filter_main_dttm": False,
        "folders": None, "uuid": uid("dataset:" + key), "metrics": metrics,
        "columns": columns, "version": VERSION, "database_uuid": uid("database"),
    }


DATASETS = dict([
    dataset("minuten", "machine_data_1min", "bucket", AGG_COLUMNS, AGG_METRICS,
            description="Minutenwerte je Anlage und Signal (nur Werte guter Qualität)"),
    dataset("aktuell", "v_latest_1min", "bucket",
            [c for c in AGG_COLUMNS], AGG_METRICS,
            description="Letzter Minutenwert je Anlage und Signal (24 h)"),
    dataset("status", "OPAIRS Connect Anlagenstatus", None, [
        col("machine", "TEXT", verbose="Anlage"),
        col("anlagenart", "TEXT", verbose="Anlagenart"),
        col("verbindung", "TEXT", verbose="Verbindung"),
        col("status", "TEXT", verbose="Status"),
        col("letzter_wert", "TIMESTAMP WITH TIME ZONE", verbose="Letzter Wert (UTC)"),
        col("alter_s", "BIGINT", verbose="Alter (s)"),
        col("werte_10min", "BIGINT", verbose="Werte 10 min"),
    ], [COUNT, metric("online", "SUM(CASE WHEN verbindung = 'online' THEN 1 ELSE 0 END)",
                      "Anlagen online", ",d")],
        sql=STATUS_SQL, description="Verbindung und Status je Anlage, live"),
    dataset("ereignisse", "OPAIRS Connect Textwerte", "ts", [
        col("ts", "TIMESTAMP WITH TIME ZONE", dttm=True, verbose="Zeit (UTC)"),
        col("machine", "TEXT", verbose="Anlage"),
        col("anlagenart", "TEXT", verbose="Anlagenart"),
        col("tag", "TEXT", verbose="Signal"),
        col("value_text", "TEXT", verbose="Wert"),
    ], [COUNT], sql=EREIGNIS_SQL,
        description="Textwerte aus den Rohdaten (Status, Werkzeug, NiO-Grund)"),
])
DS_OF = {}  # Chart -> Dataset-Schluessel


# --------------------------------------------------------------------------
# Charts
# --------------------------------------------------------------------------

_fid = 0


def flt(subject, value, op="=="):
    global _fid
    _fid += 1
    ops = {"==": "EQUALS", "IN": "IN", "LIKE": "LIKE"}
    return {
        "expressionType": "SIMPLE", "subject": subject, "operator": op,
        "operatorId": ops[op], "comparator": value, "clause": "WHERE",
        "sqlExpression": None, "isExtra": False, "isNew": False,
        "datasourceWarning": False, "filterOptionName": f"filter_opairs_{_fid}",
    }


def time_flt(column, default="No filter"):
    f = flt(column, default)
    f["operator"] = "TEMPORAL_RANGE"
    f.pop("operatorId")
    return f


def sql_metric(label, expression):
    return {
        "expressionType": "SQL", "sqlExpression": expression, "label": label,
        "hasCustomLabel": True, "optionName": "metric_" + uid(label)[:12],
        "aggregate": None, "column": None, "datasourceWarning": False,
    }


def sql_column(label, expression):
    return {"expressionType": "SQL", "sqlExpression": expression, "label": label}


CHARTS = {}  # key -> config
TIMECOL = {"minuten": "bucket", "aktuell": "bucket", "ereignisse": "ts"}


def chart(key, title, ds, viz, params, description=None):
    base = {"datasource": "1__table", "viz_type": viz, "extra_form_data": {}}
    base.update(params)
    filters = list(base.get("adhoc_filters", []))
    if ds in TIMECOL and not any(f.get("operator") == "TEMPORAL_RANGE" for f in filters):
        filters.insert(0, time_flt(TIMECOL[ds], "Last week" if ds == "ereignisse" else "No filter"))
    base["adhoc_filters"] = filters
    CHARTS[key] = {
        "slice_name": title, "description": description, "certified_by": None,
        "certification_details": None, "viz_type": viz, "params": base,
        "query_context": None, "cache_timeout": None,
        "uuid": uid("chart:" + key), "version": VERSION,
        "dataset_uuid": DATASETS[ds]["uuid"],
    }
    DS_OF[key] = ds


def kpi(key, title, ds, m, subtitle, fmt, filters=()):
    chart(key, title, ds, "big_number_total", {
        "metric": m, "adhoc_filters": list(filters), "header_font_size": 0.4,
        "subtitle": subtitle, "subtitle_font_size": 0.15, "show_metric_name": False,
        "y_axis_format": fmt, "time_format": "smart_date",
        "force_timestamp_formatting": False, "conditional_formatting": [],
    })


def ts_common(fmt):
    return {
        "x_axis_sort_asc": True, "order_desc": True, "row_limit": 10000,
        "truncate_metric": True, "show_empty_columns": True,
        "comparison_type": "values", "annotation_layers": [],
        "forecastPeriods": 10, "forecastInterval": 0.8,
        "x_axis_title_margin": 15, "y_axis_title_margin": 30,
        "y_axis_title_position": "Left", "sort_series_type": "sum",
        "color_scheme": "supersetColors", "only_total": True,
        "show_legend": True, "legendType": "scroll", "legendOrientation": "top",
        "x_axis_time_format": "smart_date", "xAxisLabelInterval": "auto",
        "rich_tooltip": True, "showTooltipTotal": False,
        "tooltipTimeFormat": "smart_date", "y_axis_format": fmt,
        "y_axis_bounds": [None, None], "truncateXAxis": True,
    }


def line(key, title, tag, metrics=("mittelwert",), groupby=("machine",), grain="PT15M",
         fmt="SMART_NUMBER", y_title="", ds="minuten", extra_filters=(), description=None):
    p = ts_common(fmt)
    p.update({
        "x_axis": TIMECOL[ds], "time_grain_sqla": grain, "metrics": list(metrics),
        "groupby": list(groupby),
        "adhoc_filters": [flt("tag", tag)] + list(extra_filters),
        # Luecken (Stillstand, Wochenende) als Luecke zeigen statt zu ueberbruecken
        "resample_rule": {"PT15M": "15min", "PT1H": "1h"}[grain], "resample_method": "asfreq",
        "seriesType": "line", "opacity": 0.2, "markerEnabled": False,
        "y_axis_bounds": [0, 1] if fmt.endswith("%") else [None, None],
        "markerSize": 6, "zoomable": True, "y_axis_title": y_title,
    })
    chart(key, title, ds, "echarts_timeseries_line", p, description)


def bar(key, title, ds, x, metrics, filters=(), groupby=(), grain=None, fmt="SMART_NUMBER",
        stack=False, horizontal=False, show_value=False, description=None):
    p = ts_common(fmt)
    p.update({
        "x_axis": x, "metrics": list(metrics), "groupby": list(groupby),
        "adhoc_filters": list(filters), "orientation": "horizontal" if horizontal else "vertical",
        "show_value": show_value, "stack": "Stack" if stack else None,
    })
    if x not in TIMECOL.values():
        p["xAxisLabelInterval"] = "0"  # jede Anlage beschriften
    if grain:
        p["time_grain_sqla"] = grain
    chart(key, title, ds, "echarts_timeseries_bar", p, description)


def table_raw(key, title, ds, columns, order, filters=(), page=20):
    chart(key, title, ds, "table", {
        "query_mode": "raw", "groupby": [], "metrics": [], "all_columns": columns,
        "percent_metrics": [], "adhoc_filters": list(filters),
        "order_by_cols": [json.dumps([c, asc]) for c, asc in order],
        "row_limit": 1000, "server_page_length": page, "order_desc": True,
        "table_timestamp_format": "%Y-%m-%d %H:%M:%S", "allow_render_html": False,
        "show_cell_bars": False, "color_pn": True, "include_search": False,
        "column_config": {c: {"d3NumberFormat": ",.2f"} for c in columns
                          if c in ("avg_value", "min_value", "max_value")},
    })


def table_agg(key, title, ds, groupby, metrics, filters=(), sort=None, page=20,
              percent=(), cell_bars=True):
    chart(key, title, ds, "table", {
        "query_mode": "aggregate", "groupby": list(groupby), "metrics": list(metrics),
        "all_columns": [], "percent_metrics": list(percent),
        "adhoc_filters": list(filters), "timeseries_limit_metric": sort,
        "order_desc": True, "row_limit": 1000, "server_page_length": page,
        "table_timestamp_format": "%Y-%m-%d %H:%M:%S", "allow_render_html": False,
        "show_cell_bars": cell_bars, "color_pn": True, "include_search": False,
    })


def pie(key, title, ds, groupby, m, filters=()):
    chart(key, title, ds, "pie", {
        "groupby": [groupby], "metric": m, "adhoc_filters": list(filters),
        "row_limit": 100, "sort_by_metric": True, "color_scheme": "supersetColors",
        "show_labels_threshold": 5, "show_legend": True, "legendType": "scroll",
        "legendOrientation": "top", "label_type": "key_percent",
        "number_format": "SMART_NUMBER", "date_format": "smart_date",
        "show_labels": True, "labels_outside": True, "outerRadius": 70,
        "donut": True, "innerRadius": 35,
    })


# --- Uebersicht -------------------------------------------------------------
kpi("k_online", "Anlagen online", "status", "online", "Daten in der letzten Minute", ",d")
kpi("k_verf", "Verfügbarkeit", "minuten", "anteil", "Anteil state = 1", ".1%",
    [flt("tag", "state")])
kpi("k_io_mon", "iO-Quote Montage", "minuten", "anteil", "pruef_ergebnis", ".1%",
    [flt("tag", "pruef_ergebnis")])
kpi("k_io_sgm", "iO-Quote Spritzguss", "minuten", "anteil", "teil_io", ".1%",
    [flt("tag", "teil_io")])
kpi("k_werte", "Messwerte", "minuten", "messwerte", "gespeichert, gute Qualität", "SMART_NUMBER")
kpi("k_bad", "Uncertain/Bad", "minuten", "schlechte_werte", "Werte schlechter Qualität",
    "SMART_NUMBER")
table_raw("t_status", "Anlagenstatus (live)", "status",
          ["machine", "anlagenart", "verbindung", "status", "letzter_wert", "alter_s",
           "werte_10min"], [("anlagenart", True), ("machine", True)])
bar("b_verf", "Verfügbarkeit je Anlage", "minuten", "machine", ["anteil"],
    [flt("tag", "state")], fmt=".0%", show_value=True, horizontal=True)
line("l_verf", "Verfügbarkeit je Anlagenart (stündlich)", "state", ["anteil"],
     ["anlagenart"], "PT1H", ".0%")
line("l_io", "iO-Quote je Linie (stündlich)", "pruef_ergebnis", ["anteil"], ["machine"],
     "PT1H", ".0%")

# --- CNC ---------------------------------------------------------------------
line("c_spindel", "Spindeldrehzahl", "spindle_speed_rpm", y_title="1/min")
line("c_temp", "Temperatur", "temperature_c", y_title="°C")
line("c_power", "Leistung", "power_kw", y_title="kW")
line("c_vib", "Vibration, Maximum je 15 min (nur gute Werte)", "vibration_mm_s", ["maximum"],
     y_title="mm/s")
bar("c_bad", "Vibration: Werte Uncertain/Bad je Stunde", "minuten", "bucket",
    ["schlechte_werte"], [flt("tag", "vibration_mm_s")], ["machine"], "PT1H", stack=True)

# --- Spritzguss -----------------------------------------------------------------
line("s_wzt", "Werkzeugtemperatur", "werkzeugtemperatur_c", y_title="°C")
line("s_mt", "Massetemperatur", "massetemperatur_c", y_title="°C")
line("s_druck", "Einspritzdruck", "einspritzdruck_bar", y_title="bar")
line("s_zyklus", "Zykluszeit", "zykluszeit_s", y_title="s")
line("s_io", "iO-Quote je Maschine (stündlich)", "teil_io", ["anteil"], ["machine"],
     "PT1H", ".0%")
table_agg("s_wz", "Werkzeugeinsatz je Tag", "ereignisse",
          [sql_column("Tag", "to_char(ts, 'YYYY-MM-DD')"), "machine",
           sql_column("Werkzeug", "value_text")],
          [sql_metric("von", "to_char(MIN(ts), 'HH24:MI')"),
           sql_metric("bis", "to_char(MAX(ts), 'HH24:MI')")],
          [flt("tag", "werkzeug")], cell_bars=False, page=14)
pie("s_nio", "NiO-Gründe Spritzguss", "ereignisse", "value_text", "count",
    [flt("tag", "nio_grund"), flt("anlagenart", "Spritzguss")])

# --- Montage ---------------------------------------------------------------------
line("m_dm", "Schraubdrehmoment (Mittel, Min, Max)", "schraub_drehmoment_nm",
     ["mittelwert", "minimum", "maximum"], (), y_title="Nm",
     description="Steigt über die Schicht (Bit-Verschleiß in den Demo-Daten)")
line("m_dw", "Schraubdrehwinkel", "schraub_drehwinkel_grad", y_title="°")
line("m_leck", "Leckrate, Maximum (NiO > 2,0)", "leckrate_ccm_min", ["maximum"], (),
     y_title="ccm/min")
line("m_kraft", "Einpresskraft (iO 7,2-8,8)", "einpresskraft_kn",
     ["mittelwert", "minimum", "maximum"], (), y_title="kN")
line("m_iso", "Isolationswiderstand, Minimum (NiO < 100)", "isolationswiderstand_mohm",
     ["minimum"], (), y_title="MOhm")
line("m_takt", "Taktzeit je Linie", "taktzeit_s", y_title="s")
bar("m_io", "iO-Quote je Linie", "minuten", "machine", ["anteil"],
    [flt("tag", "pruef_ergebnis")], fmt=".1%", show_value=True)
bar("m_nio", "NiO-Gründe je Linie", "ereignisse", "value_text", ["count"],
    [flt("tag", "nio_grund"), flt("anlagenart", "Montage")], ["machine"], stack=True,
    horizontal=True)

# --- Datenqualitaet --------------------------------------------------------------
bar("q_werte", "Gespeicherte Messwerte je Stunde", "minuten", "bucket", ["messwerte"],
    groupby=["machine"], grain="PT1H", stack=True)
table_agg("q_signale", "Signale mit Werten Uncertain/Bad", "minuten", ["machine", "tag"],
          ["schlechte_werte", "messwerte", "quote_schlecht"],
          [{
              "expressionType": "SQL", "sqlExpression": "SUM(bad_count) > 0", "clause": "HAVING",
              "subject": None, "operator": None, "comparator": None, "isExtra": False,
              "isNew": False, "datasourceWarning": False,
              "filterOptionName": "filter_opairs_bad"}],
          sort="schlechte_werte")
table_raw("q_aktuell", "Aktuelle Minutenwerte je Signal", "aktuell",
          ["machine", "tag", "avg_value", "sample_count", "bad_count", "bucket"],
          [("machine", True), ("tag", True)], page=25)


# --------------------------------------------------------------------------
# Dashboard
# --------------------------------------------------------------------------

MD_UEBERSICHT = """### OPAIRS Connect

Maschinendaten aus dem Connector-Stack (`opairs-connect-machine`), gespeichert in
PostgreSQL. Alle Zeiten **UTC**.

- **Verfügbarkeit**: Anteil der Messwerte mit `state = 1`
- **iO-Quote**: Anteil iO bei `pruef_ergebnis` (Montage) bzw. `teil_io` (Spritzguss)
- **Uncertain/Bad**: Werte, deren Quelle keine gute Qualität gemeldet hat. Sie zählen nicht in Mittelwerte
- **online**: letzter Wert jünger als 1 Minute

Die Anlagenart ergibt sich aus dem Namen: `…-cnc-…` CNC, `…-sgm-…` Spritzguss, `…-mon-…` Montage, sonst „Sonstige“."""

MD_QUALITAET = """### Datenqualität

- **Messwerte je Stunde**: Lücken zeigen Ausfälle von Connector oder Quelle
- **Uncertain/Bad**: Qualitätsstatus der Quelle (z. B. OPC UA). Diese Werte stehen in den Rohdaten
  (`opairs.machine_data`, Spalte `quality`), fließen aber nicht in die Minutenwerte ein
- Minutenwerte werden alle 5 Minuten berechnet, die letzten Minuten können fehlen"""

TABS = [
    ("uebersicht", "Übersicht", [
        [("k_online", 2, 26), ("k_verf", 2, 26), ("k_io_mon", 2, 26), ("k_io_sgm", 2, 26),
         ("k_werte", 2, 26), ("k_bad", 2, 26)],
        [("t_status", 7, 60), ("b_verf", 5, 60)],
        [("l_verf", 6, 50), ("l_io", 6, 50)],
        [("md:uebersicht", 12, 30)],
    ]),
    ("cnc", "CNC", [
        [("c_spindel", 6, 50), ("c_temp", 6, 50)],
        [("c_power", 6, 50), ("c_vib", 6, 50)],
        [("c_bad", 12, 40)],
    ]),
    ("sgm", "Spritzguss", [
        [("s_wzt", 6, 50), ("s_mt", 6, 50)],
        [("s_druck", 6, 50), ("s_zyklus", 6, 50)],
        [("s_io", 6, 50), ("s_nio", 6, 50)],
        [("s_wz", 12, 62)],
    ]),
    ("mon", "Montage", [
        [("m_io", 4, 50), ("m_dm", 8, 50)],
        [("m_dw", 6, 50), ("m_leck", 6, 50)],
        [("m_kraft", 6, 50), ("m_iso", 6, 50)],
        [("m_takt", 6, 50), ("m_nio", 6, 50)],
    ]),
    ("qualitaet", "Datenqualität", [
        [("q_werte", 8, 50), ("md:qualitaet", 4, 50)],
        [("q_signale", 5, 70), ("q_aktuell", 7, 70)],
    ]),
]
MARKDOWN = {"uebersicht": MD_UEBERSICHT, "qualitaet": MD_QUALITAET}


def build_dashboard():
    chart_ids = {key: i + 1 for i, key in enumerate(CHARTS)}
    pos = {
        "DASHBOARD_VERSION_KEY": "v2",
        "ROOT_ID": {"children": ["GRID_ID"], "id": "ROOT_ID", "type": "ROOT"},
        "GRID_ID": {"children": ["TABS-opairs"], "id": "GRID_ID",
                    "parents": ["ROOT_ID"], "type": "GRID"},
        "HEADER_ID": {"id": "HEADER_ID", "meta": {"text": "OPAIRS Connect"}, "type": "HEADER"},
        "TABS-opairs": {"children": [], "id": "TABS-opairs", "meta": {},
                        "parents": ["ROOT_ID", "GRID_ID"], "type": "TABS"},
    }
    for tab_key, tab_title, rows in TABS:
        tab_id = f"TAB-{tab_key}"
        tab_parents = ["ROOT_ID", "GRID_ID", "TABS-opairs"]
        pos["TABS-opairs"]["children"].append(tab_id)
        pos[tab_id] = {"children": [], "id": tab_id, "parents": tab_parents, "type": "TAB",
                       "meta": {"defaultText": "Tab title", "placeholder": "Tab title",
                                "text": tab_title}}
        for r, row in enumerate(rows):
            row_id = f"ROW-{tab_key}-{r}"
            row_parents = tab_parents + [tab_id]
            pos[tab_id]["children"].append(row_id)
            pos[row_id] = {"children": [], "id": row_id, "parents": row_parents, "type": "ROW",
                           "meta": {"background": "BACKGROUND_TRANSPARENT"}}
            for key, width, height in row:
                parents = row_parents + [row_id]
                if key.startswith("md:"):
                    cid = f"MARKDOWN-{key[3:]}"
                    pos[cid] = {"children": [], "id": cid, "parents": parents,
                                "type": "MARKDOWN",
                                "meta": {"code": MARKDOWN[key[3:]], "height": height,
                                         "width": width}}
                else:
                    cid = f"CHART-{key}"
                    c = CHARTS[key]
                    pos[cid] = {"children": [], "id": cid, "parents": parents, "type": "CHART",
                                "meta": {"chartId": chart_ids[key], "height": height,
                                         "sliceName": c["slice_name"], "uuid": c["uuid"],
                                         "width": width}}
                pos[row_id]["children"].append(cid)

    placed = {k for _, _, rows in TABS for row in rows for k, _, _ in row}
    missing = set(CHARTS) - placed
    assert not missing, f"Charts ohne Platz im Dashboard: {missing}"

    no_time = [chart_ids[k] for k in CHARTS if DS_OF[k] == "status"]
    minuten = DATASETS["minuten"]["uuid"]

    def select_filter(fid, name, column, parents=()):
        return {
            "id": fid, "type": "NATIVE_FILTER", "name": name, "filterType": "filter_select",
            "description": "", "targets": [{"column": {"name": column}, "datasetUuid": minuten}],
            "scope": {"rootPath": ["ROOT_ID"], "excluded": []},
            "controlValues": {"enableEmptyFilter": False, "defaultToFirstItem": False,
                              "creatable": False, "multiSelect": True,
                              "searchAllOptions": False, "inverseSelection": False},
            "defaultDataMask": {"extraFormData": {}, "filterState": {}, "ownState": {}},
            "cascadeParentIds": list(parents), "sortMetric": None,
        }

    native = [
        {
            "id": "NATIVE_FILTER-opairs-zeitraum", "type": "NATIVE_FILTER", "name": "Zeitraum",
            "filterType": "filter_time", "description": "", "targets": [{}],
            "scope": {"rootPath": ["ROOT_ID"], "excluded": no_time},
            "controlValues": {"enableEmptyFilter": False},
            "defaultDataMask": {"extraFormData": {"time_range": TIME_RANGE},
                                "filterState": {"value": TIME_RANGE}, "ownState": {}},
            "cascadeParentIds": [],
        },
        select_filter("NATIVE_FILTER-opairs-anlagenart", "Anlagenart", "anlagenart"),
        select_filter("NATIVE_FILTER-opairs-anlage", "Anlage", "machine",
                      ["NATIVE_FILTER-opairs-anlagenart"]),
    ]
    green, red, yellow, grey = "#2ECC71", "#E74C3C", "#F1C40F", "#95A5A6"
    return {
        "dashboard_title": "OPAIRS Connect",
        "description": "Maschinendaten aus opairs-connect-machine (Demo und echte Anlagen)",
        "css": "", "slug": "opairs-connect", "certified_by": "", "certification_details": "",
        "published": True, "uuid": uid("dashboard"), "position": pos,
        "metadata": {
            "chart_configuration": {},
            "global_chart_configuration": {"scope": {"rootPath": ["ROOT_ID"], "excluded": []},
                                           "chartsInScope": []},
            "color_scheme": "", "refresh_frequency": 300, "expanded_slices": {},
            "label_colors": {"online": green, "offline": red, "Produktion": green,
                             "Stoerung": red, "Pause": yellow, "Ruesten": yellow,
                             "Stillstand": grey},
            "timed_refresh_immune_slices": [], "cross_filters_enabled": True,
            "native_filter_configuration": native, "default_filters": "{}",
            "chart_customization_config": [], "filter_bar_orientation": "HORIZONTAL",
            "show_chart_timestamps": False, "color_scheme_domain": [],
            "shared_label_colors": [], "map_label_colors": {},
        },
        "theme_uuid": None, "version": VERSION,
    }


def build(uri, out):
    root = "dashboard_export_opairs_connect"
    database = {
        "database_name": DB_NAME, "sqlalchemy_uri": uri, "cache_timeout": None,
        "expose_in_sqllab": True, "allow_run_async": False, "allow_ctas": False,
        "allow_cvas": False, "allow_dml": False, "allow_file_upload": False,
        "extra": {"metadata_params": {}, "engine_params": {}, "metadata_cache_timeout": {},
                  "schemas_allowed_for_file_upload": []},
        "impersonate_user": False,
        "uuid": uid("database"), "version": VERSION,
    }
    files = {
        # fester Zeitstempel: gleicher Generator ergibt byte-gleiche ZIP (CI-Pruefung)
        "metadata.yaml": {"version": VERSION, "type": "Dashboard",
                          "timestamp": "2026-11-01T00:00:00+00:00"},
        "databases/OPAIRS_Connect.yaml": database,
        "dashboards/OPAIRS_Connect.yaml": build_dashboard(),
    }
    for key, ds in DATASETS.items():
        files[f"datasets/OPAIRS_Connect/{key}.yaml"] = ds
    for key, c in CHARTS.items():
        files[f"charts/{key}.yaml"] = c
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for name, content in sorted(files.items()):
            info = zipfile.ZipInfo(f"{root}/{name}", date_time=(2026, 11, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, json.dumps(content, ensure_ascii=False, indent=1) + "\n")
    pathlib.Path(out).write_bytes(buf.getvalue())
    print(f"{out}: {len(CHARTS)} Charts, {len(DATASETS)} Datasets")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--uri", default=DEFAULT_URI, help="SQLAlchemy-URI der Datenbank")
    ap.add_argument("--out", default=str(OUT))
    a = ap.parse_args()
    build(a.uri, a.out)
