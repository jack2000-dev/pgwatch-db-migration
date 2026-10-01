#!/usr/bin/env python3
"""Embed the shared, read-only relationship query into the provisioned dashboards."""

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SQL = (ROOT / "grafana/sql/relationship-status.sql").read_text().strip()
DASHBOARDS = ROOT / "grafana/dashboards"
DETAIL_URL = "/d/logical-replication-migration/postgresql-logical-replication-migration"


def field(name):
    return '${__data.fields["' + name + '"]:percentencode}'


def link(fields):
    return DETAIL_URL + "?" + "&".join("var-" + name + "=" + field(column) for name, column in fields)


def status_override(name, colors):
    return {"matcher": {"id": "byName", "options": name}, "properties": [
        {"id": "mappings", "value": [{"type": "value", "options": {
            status: {"text": status, "color": color} for status, color in colors.items()
        }}]},
        {"id": "custom.cellOptions", "value": {"type": "color-text"}},
    ]}


HEALTH_COLORS = {"HEALTHY": "green", "WARNING": "orange", "CRITICAL": "red", "UNKNOWN": "gray"}
CUTOVER_COLORS = {"READY": "green", "WARNING": "orange", "NOT READY": "red",
                  "DATA CHECK REQUIRED": "blue", "UNKNOWN": "gray"}


def write(name, dashboard):
    (DASHBOARDS / name).write_text(json.dumps(dashboard, indent=2, ensure_ascii=False) + "\n")


def context_variable(name):
    return {
        "current": {"selected": False, "text": "", "value": ""},
        "hide": 2,
        "label": name,
        "name": name,
        "options": [],
        "query": "",
        "type": "textbox",
    }


fleet_path = DASHBOARDS / "logical-replication-overview.json"
fleet = json.loads(fleet_path.read_text())
fleet_panel = fleet["panels"][0]
fleet_panel["title"] = "Instance-pair fleet status"
fleet_panel["description"] = (
    "One row per source → target PostgreSQL instance pair. Health summarizes live replication; "
    "cutover is READY only when every database/slot relationship is READY. "
    "The count columns expose mixed states; missing or stale profiles remain UNKNOWN. "
    "Open an instance pair to inspect its databases."
)
fleet_sql = f"""WITH relationships AS ({SQL}), fleet AS (
  SELECT source_provider, source_instance, target_provider, target_instance,
    count(*) AS migrations,
    count(*) FILTER (WHERE health_status = 'HEALTHY') AS healthy_count,
    count(*) FILTER (WHERE health_status = 'WARNING') AS health_warning_count,
    count(*) FILTER (WHERE health_status = 'CRITICAL') AS critical_count,
    count(*) FILTER (WHERE health_status = 'UNKNOWN') AS health_unknown_count,
    count(*) FILTER (WHERE cutover_status = 'READY') AS ready_count,
    count(*) FILTER (WHERE cutover_status = 'WARNING') AS cutover_warning_count,
    count(*) FILTER (WHERE cutover_status = 'NOT READY') AS not_ready_count,
    count(*) FILTER (WHERE cutover_status = 'DATA CHECK REQUIRED') AS data_check_required_count,
    count(*) FILTER (WHERE cutover_status = 'UNKNOWN') AS cutover_unknown_count,
    max(lag_bytes) AS max_lag_bytes,
    sum(errors) AS new_errors,
    CASE WHEN bool_or(health_status = 'CRITICAL') THEN 'CRITICAL'
         WHEN bool_or(health_status = 'UNKNOWN') THEN 'UNKNOWN'
         WHEN bool_or(health_status = 'WARNING') THEN 'WARNING'
         ELSE 'HEALTHY' END AS health_status,
    CASE WHEN bool_or(cutover_status = 'NOT READY') THEN 'NOT READY'
         WHEN bool_or(cutover_status = 'UNKNOWN') THEN 'UNKNOWN'
         WHEN bool_or(cutover_status = 'WARNING') THEN 'WARNING'
         WHEN bool_or(cutover_status = 'DATA CHECK REQUIRED') THEN 'DATA CHECK REQUIRED'
         ELSE 'READY' END AS cutover_status
  FROM relationships
  GROUP BY source_provider, source_instance, target_provider, target_instance
)
SELECT * FROM fleet
ORDER BY CASE cutover_status WHEN 'NOT READY' THEN 0 WHEN 'UNKNOWN' THEN 1
  WHEN 'WARNING' THEN 2 WHEN 'DATA CHECK REQUIRED' THEN 3 ELSE 4 END,
  source_provider, source_instance, target_provider, target_instance"""
fleet_panel["targets"][0]["rawSql"] = fleet_sql
fleet_panel["fieldConfig"]["overrides"] = [
    {"matcher": {"id": "byName", "options": "source_instance"}, "properties": [
        {"id": "links", "value": [{"title": "Open instance migrations", "url": link([
            ("source_provider", "source_provider"), ("source_instance", "source_instance"),
            ("target_provider", "target_provider"), ("target_instance", "target_instance")
        ])}]}
    ]},
    {"matcher": {"id": "byName", "options": "max_lag_bytes"},
     "properties": [{"id": "unit", "value": "bytes"}]},
    status_override("health_status", HEALTH_COLORS),
    status_override("cutover_status", CUTOVER_COLORS),
]
write("logical-replication-overview.json", fleet)

detail_path = DASHBOARDS / "logical-replication-migration.json"
detail = json.loads(detail_path.read_text())
detail["panels"] = [panel for panel in detail["panels"] if panel["id"] != 26]
if detail["panels"][0]["gridPos"]["y"] == 0:
    for panel in detail["panels"]:
        panel["gridPos"]["y"] += 12

detail_sql = f"""SELECT source_provider, source_instance, target_provider, target_instance,
  source_database, target_database, slot, subscription,
  health_status, cutover_status, lag_bytes, errors, tables_ready,
  data_validation, validated_at, publisher, subscriber
FROM ({SQL}) AS relationships
WHERE (${{source_provider:sqlstring}} = '' OR source_provider = ${{source_provider:sqlstring}})
  AND (${{source_instance:sqlstring}} = '' OR source_instance = ${{source_instance:sqlstring}})
  AND (${{target_provider:sqlstring}} = '' OR target_provider = ${{target_provider:sqlstring}})
  AND (${{target_instance:sqlstring}} = '' OR target_instance = ${{target_instance:sqlstring}})
ORDER BY CASE cutover_status WHEN 'NOT READY' THEN 0 WHEN 'UNKNOWN' THEN 1
  WHEN 'WARNING' THEN 2 WHEN 'DATA CHECK REQUIRED' THEN 3 ELSE 4 END,
  source_database, target_database, slot"""
detail["panels"].insert(0, {
    "id": 26,
    "type": "table",
    "title": "Database migrations in this instance pair",
    "description": "Each row is a database/slot relationship. Registered profiles without fresh metrics remain UNKNOWN. Select a database to load its detailed replication panels below.",
    "gridPos": {"h": 12, "w": 24, "x": 0, "y": 0},
    "datasource": {"type": "postgres", "uid": "pgwatch-metrics"},
    "targets": [{"refId": "A", "format": "table", "rawSql": detail_sql}],
    "fieldConfig": {"defaults": {}, "overrides": [
        {"matcher": {"id": "byName", "options": "source_database"}, "properties": [
            {"id": "links", "value": [{"title": "Inspect database migration", "url": link([
                ("source_provider", "source_provider"), ("source_instance", "source_instance"),
                ("target_provider", "target_provider"), ("target_instance", "target_instance"),
                ("source", "publisher"), ("target", "subscriber"), ("slot", "slot")
            ])}]}
        ]},
        {"matcher": {"id": "byName", "options": "lag_bytes"},
         "properties": [{"id": "unit", "value": "bytes"}]},
        status_override("health_status", HEALTH_COLORS),
        status_override("cutover_status", CUTOVER_COLORS),
    ]},
    "options": {"showHeader": True},
})

context = [context_variable(name) for name in (
    "source_provider", "source_instance", "target_provider", "target_instance"
)]
source_where = " AND ".join([
    "i.retired_at IS NULL", "i.role = 'publisher'",
    "(${source_provider:sqlstring} = '' OR i.provider = ${source_provider:sqlstring})",
    "(${source_instance:sqlstring} = '' OR i.instance = ${source_instance:sqlstring})",
])
target_where = " AND ".join([
    "i.retired_at IS NULL", "i.role = 'subscriber'",
    "i.migration_pair = (SELECT migration_pair FROM monitoring_profile_inventory WHERE profile_name = ${source:sqlstring})",
    "(${target_provider:sqlstring} = '' OR i.provider = ${target_provider:sqlstring})",
    "(${target_instance:sqlstring} = '' OR i.instance = ${target_instance:sqlstring})",
])
def profile_query(where):
    return ("SELECT COALESCE(d.database, i.profile_name) || ' — ' || i.profile_name AS __text, "
            "i.profile_name AS __value FROM monitoring_profile_inventory i "
            "LEFT JOIN LATERAL (SELECT COALESCE(NULLIF(tag_data->>'database', ''), dbname) AS database "
            "FROM general_database WHERE dbname = i.profile_name AND time > now() - interval '5 minutes' "
            "ORDER BY time DESC LIMIT 1) d ON true WHERE " + where + " ORDER BY __text")

variables = [v for v in detail["templating"]["list"] if v["name"] not in {
    "source_provider", "source_instance", "target_provider", "target_instance"
}]
variables[0]["query"] = profile_query(source_where)
variables[1]["query"] = profile_query(target_where)
variables[2]["query"] = (
    "SELECT DISTINCT tag_data->>'slot_name' AS __text, tag_data->>'slot_name' AS __value "
    "FROM target_subscription WHERE dbname = ${target:sqlstring} "
    "AND time > now() - interval '5 minutes' ORDER BY 1"
)
variables[3]["query"] = (
    "SELECT DISTINCT tag_data->>'subscription' AS __text, "
    "tag_data->>'subscription' AS __value FROM target_subscription "
    "WHERE dbname = ${target:sqlstring} AND tag_data->>'slot_name' = ${slot:sqlstring} "
    "AND time > now() - interval '5 minutes' ORDER BY 1"
)
detail["templating"]["list"] = context + variables
write("logical-replication-migration.json", detail)
