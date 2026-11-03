#!/usr/bin/env python3
"""Query-Kontext für alle Charts eines Superset-Dashboards setzen (OPAIRS Connect).

Importierte Charts haben keinen gespeicherten query_context. Ohne ihn liefert
/api/v1/chart/<id>/data keine Daten (OPAIRS Connect Assistent, Alerts & Reports).
Das Skript baut ihn aus den gespeicherten Chart-Parametern, prüft ihn mit
/api/v1/chart/data und speichert ihn nur, wenn diese Abfrage fehlerfrei läuft.
Nur Python-Standardbibliothek.

  python3 superset/set_query_context.py --url http://localhost:8088 --user admin \\
      --password-env SUPERSET_PASSWORD --dashboard "OPAIRS Connect" [--dry-run] [--force]
"""
import argparse
import http.cookiejar
import json
import os
import sys
import urllib.error
import urllib.request


class Superset:
    def __init__(self, url: str, user: str, password: str):
        self.url = url.rstrip("/")
        self.op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        self.h: dict = {}
        tok = self.req(
            "POST", "/api/v1/security/login",
            {"username": user, "password": password, "provider": "db", "refresh": True}, auth=False,
        )["access_token"]
        self.h = {"Authorization": f"Bearer {tok}", "Referer": self.url + "/"}
        try:
            self.h["X-CSRFToken"] = self.req("GET", "/api/v1/security/csrf_token/")["result"]
        except RuntimeError:
            pass  # CSRF für die API nicht aktiv

    def req(self, method: str, path: str, body=None, auth: bool = True) -> dict:
        data = json.dumps(body).encode() if body is not None else None
        r = urllib.request.Request(self.url + path, data=data, method=method)
        if data is not None:  # GET ohne Body: kein JSON-Header, sonst antworten manche Endpunkte mit 400
            r.add_header("Content-Type", "application/json")
        if auth:
            for k, v in self.h.items():
                r.add_header(k, v)
        try:
            with self.op.open(r, timeout=120) as resp:
                return json.loads(resp.read() or b"{}")
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"{method} {path}: HTTP {e.code}: {e.read()[:400].decode(errors='replace')}")


def _filters(params: dict):
    """adhoc_filters -> Filter der Abfrage, SQL-Filter -> extras.where/having, Zeitraum -> TEMPORAL_RANGE."""
    flt, where, having = [], [], []
    for f in params.get("adhoc_filters") or []:
        if f.get("expressionType") == "SQL":
            (having if f.get("clause") == "HAVING" else where).append(f"({f.get('sqlExpression')})")
        elif f.get("operator") == "TEMPORAL_RANGE":
            flt.append({"col": f.get("subject"), "op": "TEMPORAL_RANGE",
                        "val": f.get("comparator") or params.get("time_range") or "No filter"})
        else:
            x = {"col": f.get("subject"), "op": f.get("operator")}
            if f.get("comparator") is not None:
                x["val"] = f["comparator"]
            flt.append(x)
    if not any(x["op"] == "TEMPORAL_RANGE" for x in flt):
        tcol = params.get("granularity_sqla") or (params.get("x_axis") if isinstance(params.get("x_axis"), str) else None)
        if tcol and params.get("time_range"):
            flt.append({"col": tcol, "op": "TEMPORAL_RANGE", "val": params["time_range"]})
    extras = {}
    if where:
        extras["where"] = " AND ".join(where)
    if having:
        extras["having"] = " AND ".join(having)
    if params.get("time_grain_sqla"):
        extras["time_grain_sqla"] = params["time_grain_sqla"]
    return flt, extras


def _base_axis(params: dict):
    x = params.get("x_axis") or params.get("granularity_sqla")
    if not x:
        return None
    if isinstance(x, dict):  # adhoc-Spalte
        return {**x, "columnType": "BASE_AXIS", "timeGrain": params.get("time_grain_sqla")}
    return {"columnType": "BASE_AXIS", "expressionType": "SQL", "label": x, "sqlExpression": x,
            "timeGrain": params.get("time_grain_sqla")}


def build_query(params: dict) -> dict:
    viz = params.get("viz_type", "")
    flt, extras = _filters(params)
    metrics = params.get("metrics") or ([params["metric"]] if params.get("metric") else [])
    groupby = list(params.get("groupby") or [])
    q = {"filters": flt, "extras": extras, "metrics": metrics, "columns": [], "orderby": [],
         "row_limit": int(params.get("row_limit") or 10000)}
    if viz == "big_number_total":
        pass  # nur Metrik
    elif viz == "table":
        if params.get("query_mode") == "raw":
            # metrics = None heisst Einzelzeilen (mit [] gruppiert Superset ueber alle Spalten)
            q["columns"], q["metrics"] = list(params.get("all_columns") or []), None
            # Sortierung der Rohtabelle (z. B. neueste Werte zuerst), sonst liefert das Limit beliebige Zeilen
            q["orderby"] = [json.loads(o) if isinstance(o, str) else o for o in params.get("order_by_cols") or []]
        else:
            q["columns"] = groupby
            sort = params.get("timeseries_limit_metric")
            if sort:
                q["orderby"] = [[sort, not params.get("order_desc", True)]]
            elif metrics:
                q["orderby"] = [[metrics[0], False]]
    elif viz.startswith("echarts_timeseries") or viz in ("echarts_area", "big_number"):
        ax = _base_axis(params)
        q["columns"] = ([ax] if ax else []) + groupby
        q["series_columns"] = groupby
        if metrics:
            q["orderby"] = [[metrics[0], False]]
    else:  # pie, bar u. a.: Gruppierung + Metriken
        q["columns"] = groupby
    return q


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", default="http://localhost:8088")
    ap.add_argument("--user", default="admin")
    ap.add_argument("--password-env", default="SUPERSET_PASSWORD", help="Umgebungsvariable mit dem Kennwort")
    ap.add_argument("--dashboard", default="OPAIRS Connect", help="Titel, Slug oder ID")
    ap.add_argument("--dry-run", action="store_true", help="nur prüfen, nichts speichern")
    ap.add_argument("--force", action="store_true", help="auch Charts mit vorhandenem Query-Kontext neu setzen")
    a = ap.parse_args()
    pw = os.environ.get(a.password_env)
    if not pw:
        print(f"Kennwort fehlt: Umgebungsvariable {a.password_env} setzen.", file=sys.stderr)
        return 2
    s = Superset(a.url, a.user, pw)

    if a.dashboard.isdigit():
        did = int(a.dashboard)
    else:
        dashes = s.req("GET", "/api/v1/dashboard/?q=(page_size:100)")["result"]
        hit = [d for d in dashes if d.get("dashboard_title") == a.dashboard or d.get("slug") == a.dashboard]
        if len(hit) != 1:
            print(f"Dashboard '{a.dashboard}' nicht eindeutig gefunden ({len(hit)} Treffer).", file=sys.stderr)
            return 2
        did = hit[0]["id"]

    ok = skipped = failed = 0
    for c in s.req("GET", f"/api/v1/dashboard/{did}/charts")["result"]:
        cid, name = c["id"], c.get("slice_name")
        info = s.req("GET", f"/api/v1/chart/{cid}")["result"]
        if info.get("query_context") and not a.force:
            skipped += 1
            print(f"  = {cid:>5}  {name}: Query-Kontext vorhanden")
            continue
        params = json.loads(info.get("params") or "{}")
        ds = params.get("datasource") or (c.get("form_data") or {}).get("datasource") or ""
        try:
            ds_id, ds_type = ds.split("__")
            qc = {
                "datasource": {"id": int(ds_id), "type": ds_type},
                "force": False,
                "queries": [build_query(params)],
                "form_data": {**params, "slice_id": cid, "datasource": ds},
                "result_format": "json",
                "result_type": "full",
            }
            res = s.req("POST", "/api/v1/chart/data", qc)
            rows = sum(len(r.get("data") or []) for r in res.get("result", []))
            if not a.dry_run:
                s.req("PUT", f"/api/v1/chart/{cid}", {"query_context": json.dumps(qc), "query_context_generation": True})
            ok += 1
            print(f"  ✓ {cid:>5}  {name}: {rows} Zeilen{' (nur geprüft)' if a.dry_run else ', gespeichert'}")
        except (RuntimeError, ValueError, KeyError) as e:
            failed += 1
            print(f"  ✗ {cid:>5}  {name}: {str(e)[:300]}")
    print(f"\n{ok} gesetzt{' (dry-run)' if a.dry_run else ''}, {skipped} übersprungen, {failed} fehlgeschlagen.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
