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
        self.assertEqual(visible, ["Source", "Target", "Publisher", "Subscriber", "Slot"])
        self.assertEqual(next(item for item in variables if item["name"] == "subscription")["hide"], 2)

        panels = {panel["title"]: panel for panel in detail["panels"]}
        self.assertEqual(panels["Publication status"]["type"], "table")
        self.assertEqual(panels["Table status"]["type"], "table")
        self.assertIn("lag_bytes", panels["Lag (bytes)"]["targets"][0]["rawSql"])

    def test_cutover_and_alert_thresholds_match(self):
        overview_sql = dashboard("logical-replication-overview.json")["panels"][0]["targets"][0]["rawSql"]
        for status in ("READY", "WARNING", "NOT READY", "UNKNOWN"):
            self.assertIn(status, overview_sql)
        self.assertIn("e.new_errors > 5", overview_sql)

        alerts = (ROOT / "grafana" / "provisioning" / "alerting" / "logical-replication.yaml").read_text()
        self.assertIn("lr-logical-replication-errors", alerts)
        self.assertIn("new_errors > 5", alerts)
        self.assertNotIn("lr-apply-errors-increase", alerts)
        self.assertNotIn("lr-sync-errors-increase", alerts)

    def test_publication_metric_is_configured(self):
        metric = (ROOT / "config" / "metrics" / "source_publication.yaml").read_text()
        self.assertIn("pg_publication", metric)
        self.assertIn("table_count", metric)


if __name__ == "__main__":
    unittest.main()
