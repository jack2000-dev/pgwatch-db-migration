import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def dashboard(name):
    return json.loads((ROOT / "grafana" / "dashboards" / name).read_text())


class MonitoringConfigTest(unittest.TestCase):
    def test_detail_dashboard_has_requested_controls_and_tables(self):
        detail = dashboard("logical-replication-migration.json")
        variables = detail["templating"]["list"]
        visible = [item["label"] for item in variables if not item.get("hide")]
        self.assertEqual(visible, ["Source", "Target", "Slot"])
        self.assertEqual(next(item for item in variables if item["name"] == "subscription")["hide"], 2)
        self.assertEqual({item["name"] for item in variables}, {"source", "target", "slot", "subscription"})
        self.assertIn("tag_data->>'database'", variables[0]["query"])
        self.assertIn("tag_data->>'database'", variables[1]["query"])
        self.assertIn("server_address", variables[0]["query"])
        self.assertIn("server_address", variables[1]["query"])

        panels = {panel["title"]: panel for panel in detail["panels"]}
        self.assertEqual(panels["Source"]["gridPos"]["x"], 0)
        self.assertEqual(panels["Target"]["gridPos"]["x"], 12)
        self.assertEqual(panels["Source"]["gridPos"]["y"], panels["Target"]["gridPos"]["y"])
        self.assertIn("pg_version", panels["Source"]["targets"][0]["rawSql"])
        self.assertIn("pg_version", panels["Target"]["targets"][0]["rawSql"])
        self.assertIn("server_endpoint", panels["Source"]["targets"][0]["rawSql"])
        self.assertIn("server_endpoint", panels["Target"]["targets"][0]["rawSql"])
        self.assertTrue(all(0 <= panel["gridPos"]["x"] and panel["gridPos"]["x"] + panel["gridPos"]["w"] <= 24 for panel in detail["panels"]))
        self.assertEqual(panels["Publication status"]["type"], "table")
        self.assertEqual(panels["Table status"]["type"], "table")
        self.assertEqual(panels["Table readiness"]["type"], "table")
        self.assertNotIn("Ready tables", panels)
        self.assertNotIn("Non-ready tables", panels)
        self.assertNotIn("Total tables", panels)
        health_sql = panels["Replication health"]["targets"][0]["rawSql"]
        self.assertIn("errors_last_5m", health_sql)
        self.assertIn("new_errors", health_sql)
        cutover_sql = panels["Cutover status"]["targets"][0]["rawSql"]
        self.assertIn("cutover_validation", cutover_sql)
        self.assertIn("DATA CHECK REQUIRED", json.dumps(panels["Cutover status"]))
        self.assertIn("lag_bytes", panels["Lag (bytes)"]["targets"][0]["rawSql"])
        self.assertIn("database_size_bytes", panels["Source database size"]["targets"][0]["rawSql"])
        self.assertIn("database_size_bytes", panels["Target database size"]["targets"][0]["rawSql"])
        self.assertIn("dbname = '$source'", panels["Source database size"]["targets"][0]["rawSql"])
        self.assertIn("dbname = '$target'", panels["Target database size"]["targets"][0]["rawSql"])
        snapshot_panels = ("Source", "Target", "Replication health", "Cutover status", "Subscription status", "Slot active", "Apply worker count", "Table sync worker count", "Table readiness", "Publication status", "Logical replication slots", "Subscription workers", "Table status", "Replication origins", "Source database size", "Target database size")
        self.assertTrue(all("time > now() - interval '5 minutes'" in panels[title]["targets"][0]["rawSql"] for title in snapshot_panels))

    def test_data_flow_and_panel_descriptions(self):
        detail = dashboard("logical-replication-migration.json")
        overview = dashboard("logical-replication-overview.json")
        for item in (detail, overview):
            self.assertTrue(all(panel.get("description", "").strip() for panel in item["panels"]))
        panels = {panel["title"]: panel for panel in detail["panels"]}
        slot = panels["Slot active"]["gridPos"]
        flow = panels["Data flow"]
        self.assertEqual((slot["x"], slot["w"]), (0, 6))
        self.assertEqual((flow["gridPos"]["x"], flow["gridPos"]["w"], flow["gridPos"]["y"]), (6, 6, slot["y"]))
        self.assertEqual(
            {value["text"] for value in flow["fieldConfig"]["defaults"]["mappings"][0]["options"].values()},
            {"FLOWING", "IDLE", "DISCONNECTED", "UNKNOWN"},
        )
        flow_sql = flow["targets"][0]["rawSql"]
        self.assertIn("confirmed_flush_lsn", flow_sql)
        self.assertIn("interval '60 seconds'", flow_sql)
        self.assertIn("interval '90 seconds'", flow_sql)
        table_sql = panels["Table status"]["targets"][0]["rawSql"]
        self.assertIn("AS table_name", table_sql)
        self.assertNotIn("AS table,", table_sql)

    def test_cutover_and_alert_thresholds_match(self):
        overview = dashboard("logical-replication-overview.json")
        overview_sql = overview["panels"][0]["targets"][0]["rawSql"]
        for status in ("READY", "WARNING", "NOT READY", "UNKNOWN"):
            self.assertIn(status, overview_sql)
        self.assertIn("e.new_errors > 5", overview_sql)
        self.assertIn("cutover_validation", overview_sql)
        self.assertIn("v.status IS NULL", overview_sql)
        self.assertIn("DATA CHECK REQUIRED", overview_sql)
        link = overview["panels"][0]["fieldConfig"]["overrides"][0]["properties"][0]["value"][0]["url"]
        self.assertIn('var-source=${__data.fields["publisher"]}', link)
        self.assertIn('var-target=${__data.fields["subscriber"]}', link)
        self.assertNotIn("var-publisher", link)

        alerts = (ROOT / "grafana" / "provisioning" / "alerting" / "logical-replication.yaml").read_text()
        self.assertIn("lr-logical-replication-errors", alerts)
        self.assertIn("new_errors > 5", alerts)
        self.assertNotIn("lr-apply-errors-increase", alerts)
        self.assertNotIn("lr-sync-errors-increase", alerts)

    def test_exact_validation_status_is_persisted(self):
        start = (ROOT / "scripts" / "start.sh").read_text()
        wrapper = (ROOT / "scripts" / "validate-data.sh").read_text()
        self.assertIn("CREATE TABLE IF NOT EXISTS cutover_validation", start)
        self.assertIn("INSERT INTO cutover_validation", wrapper)
        self.assertIn("VALIDATION_MIGRATION_PAIR", wrapper)

    def test_publication_metric_is_configured(self):
        metric = (ROOT / "config" / "metrics" / "source_publication.yaml").read_text()
        self.assertIn("pg_publication", metric)
        self.assertIn("table_count", metric)

        general = (ROOT / "config" / "metrics" / "general.yaml").read_text()
        self.assertEqual(general.count("tag_pg_version"), 2)
        self.assertEqual(general.count("tag_server_address"), 2)
        self.assertEqual(general.count("database_size_bytes"), 2)


if __name__ == "__main__":
    unittest.main()
