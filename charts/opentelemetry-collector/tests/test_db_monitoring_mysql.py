"""Verify the MySQL DB monitoring preset with Helm and the Collector."""
import os
import unittest

from test_db_monitoring import collect_logs, render, target, values


PREFIX = "db_monitoring_mysql_"


def mysql_values(*targets):
    settings = values()
    settings["presets"]["dbMonitoring"]["mysql"] = targets
    settings["presets"]["coralogixExporter"] = {"enabled": True, "domain": "example.com"}
    return settings


class MySQLMonitoringTests(unittest.TestCase):
    def test_mysql_uses_reference_schedules_and_routes_by_engine(self):
        settings = mysql_values(target(querySamples={"enabled": True}, topQueries={"enabled": True},
                                       catalog={"enabled": True}))
        settings["presets"]["dbMonitoring"]["postgresql"] = [target(topQueries={"enabled": True}, catalog={"enabled": True})]
        config = render(settings)
        prefix = PREFIX + "orders"
        receivers = config["receivers"]
        expected = {
            f"mysql/{prefix}_metrics": "60s",
            f"mysql/{prefix}_queries": "60s",
            f"sql_query/{prefix}_health": "60s",
            f"sql_query/{prefix}_tables": "5m",
            f"sql_query/{prefix}_details": "5m",
            f"sql_query/{prefix}_schema": "5m",
        }
        self.assertEqual({name: receivers[name]["collection_interval"] for name in expected}, expected)
        self.assertEqual(receivers[f"mysql/{prefix}_metrics"]["endpoint"], "orders.example.com:3306")
        self.assertEqual(receivers[f"sql_query/{prefix}_schema"]["password"], "${env:ORDERS_PASSWORD}")
        self.assertEqual(receivers[f"sql_query/{prefix}_schema"]["additional_params"]["tls"], "true")
        queries = receivers[f"mysql/{prefix}_queries"]
        self.assertTrue(queries["events"]["db.server.top_query"]["enabled"])
        self.assertTrue(queries["events"]["db.server.query_sample"]["enabled"])
        self.assertFalse(queries["events"]["db.server.query_plan"]["enabled"])
        self.assertEqual(queries["query_sample_collection"]["max_rows_per_query"], 20)
        for field, value in {"top_query_count": 50, "lookback_time": 360,
                             "max_query_sample_count": 1000}.items():
            self.assertEqual(queries["top_query_collection"][field], value)
        pipelines = config["service"]["pipelines"]
        for pipeline, subsystem in [
            (f"metrics/{prefix}", "mysql"),
            (f"logs/{prefix}_queries", "mysql-slow-queries"),
            ("logs/db_monitoring_postgresql_orders_queries", "postgresql-slow-queries"),
        ]:
            exporters = [e for e in pipelines[pipeline]["exporters"] if e.startswith("coralogix/")]
            self.assertEqual([config["exporters"][e]["subsystem_name"] for e in exporters], [subsystem])
        catalog = next(e for e in pipelines[f"logs/{prefix}_catalog"]["exporters"] if e.startswith("coralogix/"))
        self.assertEqual(config["exporters"][catalog]["logs"]["headers"]["x-coralogix-ingress"],
                         "metadata-as-otlp-logs/v1")
        self.assertIn("transform/db_monitoring_mysql_catalog", pipelines[f"logs/{prefix}_catalog"]["processors"])
        self.assertIn("transform/db_monitoring_catalog", pipelines["logs/db_monitoring_postgresql_orders_catalog"]["processors"])

    def test_mysql_iam_only_reaches_native_receivers(self):
        item = target(auth={"aws_iam": {"region": "eu-west-1"}}, collectionInterval="45s",
                      querySamples={"enabled": True}, topQueries={"enabled": True, "planEvents": True},
                      receivers={"topQueries": {"collectionInterval": "2m", "timeout": "10s"}})
        with self.assertRaisesRegex(ValueError, "sqlAuth is required"):
            render(mysql_values(item))

        item["sqlAuth"] = {"username": "catalog_reader", "password": "${env:CATALOG_PASSWORD}"}
        config = render(mysql_values(item))
        prefix = PREFIX + "orders"
        for kind in ["metrics", "queries", "samples"]:
            receiver = config["receivers"][f"mysql/{prefix}_{kind}"]
            self.assertEqual(receiver["db_auth"], "aws_iam_db_auth/eu-west-1")
            self.assertNotIn("password", receiver)
        for kind in ["health", "tables"]:
            receiver = config["receivers"][f"sql_query/{prefix}_{kind}"]
            self.assertEqual(receiver["username"], "catalog_reader")
            self.assertEqual(receiver["password"], "${env:CATALOG_PASSWORD}")
            self.assertNotIn("db_auth", receiver)
            self.assertEqual(receiver["collection_interval"], "45s")
        top_queries = config["receivers"][f"mysql/{prefix}_queries"]
        self.assertTrue(top_queries["events"]["db.server.query_plan"]["enabled"])
        self.assertFalse(top_queries["events"]["db.server.query_sample"]["enabled"])
        self.assertEqual(top_queries["timeout"], "10s")
        self.assertEqual(top_queries["top_query_collection"]["collection_interval"], "2m")
        conditions = config["processors"][f"filter/{prefix}_own_queries"]["logs"]["log_record"]
        self.assertIn('attributes["user.name"] == "catalog_reader"', conditions)
        self.assertIn("aws_iam_db_auth/eu-west-1", config["service"]["extensions"])

    @unittest.skipUnless(os.environ.get("OTELCOL_BINARY"), "Set OTELCOL_BINARY to the chart Collector binary")
    def test_mysql_query_and_plan_events_keep_the_same_correlation_key(self):
        item = target(metrics={"enabled": False}, querySamples={"enabled": True},
                      topQueries={"enabled": True, "planEvents": True})
        config = render(mysql_values(item))
        pipeline = config["service"]["pipelines"][f"logs/{PREFIX}orders_queries"]
        correlation_key = {"db.namespace": "shop", "mysql.query_plan.hash": "native-hash"}
        inputs = [
            {**correlation_key, "event.name": "db.server.top_query"},
            {**correlation_key, "event.name": "db.server.query_sample"},
            {**correlation_key, "event.name": "db.server.query_plan", "mysql.query_plan": '{"query_block":{}}'},
        ]
        records = collect_logs(config, pipeline, inputs, [{"type": "json_parser", "parse_to": "attributes"}])
        attributes = [
            {a["key"]: next(iter(a["value"].values())) for a in record["attributes"]}
            for record in records
        ]
        self.assertCountEqual([record["event.name"] for record in attributes], [record["event.name"] for record in inputs])
        for record in attributes:
            with self.subTest(event=record["event.name"]):
                self.assertEqual({key: record.get(key) for key in correlation_key}, correlation_key)

    @unittest.skipUnless(os.environ.get("OTELCOL_BINARY"), "Set OTELCOL_BINARY to the chart Collector binary")
    def test_mysql_server_logs_parse_and_mask_records(self):
        item = target(metrics={"enabled": False}, serverLogs={"errorPaths": ["/logs/*.json"], "slowPaths": ["/logs/slow.log"]})
        for kind, inputs in [
            ("error", [{"msg": "Access denied for user 'secret'", "time": "2026-11-25T13:45:32.878263Z",
                        "label": "Warning", "err_code": 1045, "SQL_state": "28000"}]),
            ("slow", "# Time: 2026-11-25T13:45:32.856844Z\n"
                     "# User@Host: app[app] @ localhost [127.0.0.1]  Id:    16\n"
                     "# Query_time: 0.205133  Lock_time: 0.000000 Rows_sent: 1  Rows_examined: 1 Thread_id: 16 Errno: 0\n"
                     "use shop;\nSET timestamp=1795614332;\nSELECT SLEEP(0.2), 'secret';\n"),
        ]:
            with self.subTest(kind=kind):
                config = render(mysql_values(item))
                pipeline = config["service"]["pipelines"][f"logs/{PREFIX}orders_{kind}"]
                receiver = config["receivers"][pipeline["receivers"][0]]
                records = collect_logs(config, pipeline, inputs, receiver["operators"],
                                       receiver_options={k: v for k, v in receiver.items() if k != "include"})
                self.assertEqual(len(records), 1)
                record = records[0]
                attributes = {a["key"]: next(iter(a["value"].values())) for a in record["attributes"]}
                self.assertNotIn("secret", str(record))
                if kind == "error":
                    self.assertEqual(attributes["db.response.status_code"], "1045")
                    self.assertEqual(attributes["mysql.sql_state"], "28000")
                    self.assertEqual(record["severityText"], "Warning")
                else:
                    self.assertEqual(attributes["event.name"], "db.server.query_sample")
                    self.assertEqual(attributes["db.namespace"], "shop")
                    self.assertEqual(attributes["mysql.query_time"], 0.205133)
                    self.assertEqual(attributes["mysql.threads.thread_id"], "16")
                    self.assertEqual(attributes["user.name"], "app")
                    self.assertIn("SLEEP", attributes["db.query.text"])
                    self.assertNotIn("dbm.raw_query", attributes)
