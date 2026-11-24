"""Run with python3 -m unittest discover -s tests (requires Helm and PyYAML)."""

import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
import uuid

import yaml


CHART = Path(__file__).resolve().parents[1]
PREFIX = "db_monitoring_postgresql_"


def render(values):
    result = subprocess.run(
        ["helm", "template", "test", str(CHART), "-f", "-"],
        input=yaml.safe_dump(values), text=True, capture_output=True,
    )
    if result.returncode:
        raise ValueError(result.stderr)
    for document in yaml.safe_load_all(result.stdout):
        if document and document["kind"] == "ConfigMap" and "relay" in document.get("data", {}):
            return yaml.safe_load(document["data"]["relay"])
    raise AssertionError("No collector config found")


def values(*targets):
    return {"mode": "deployment", "presets": {"dbMonitoring": {
        "enabled": True, "postgresql": list(targets),
    }}}


def target(name="orders", **options):
    return dict(name=name, host=f"{name}.example.com", username="monitor",
                password=f"${{env:{name.upper()}_PASSWORD}}", instanceId=f"production/{name}", **options)


class DbMonitoringTests(unittest.TestCase):
    def test_disabled_preset_does_not_change_config(self):
        configured = values(target())
        configured["presets"]["dbMonitoring"]["enabled"] = False
        self.assertEqual(render({}), render(configured))
        self.assertEqual(render({}), render(values()))

    def test_targets_keep_connections_and_identity_when_reordered(self):
        first = target(databases=["orders", "billing"])
        second = target("inventory", port=5433, connectDatabase="inventory",
                        resourceAttributes={"cloud.region": "eu-west-1"})
        config = render(values(first, second))
        self.assertEqual(config, render(values(second, first)))
        for item in [first, second]:
            pipeline = config["service"]["pipelines"][f"metrics/{PREFIX}{item['name']}"]
            for receiver in pipeline["receivers"]:
                connection = config["receivers"][receiver]
                self.assertEqual(connection["password"], item["password"])
                if receiver.startswith("sql_query/"):
                    self.assertEqual(connection["host"], item["host"])
            identity = config["processors"][f"resource/{PREFIX}{item['name']}"]
            attributes = {a["key"]: a["value"] for a in identity["attributes"]}
            self.assertEqual(attributes["cx.db.instance.id"], item["instanceId"])
            self.assertEqual(attributes["server.address"], item["host"])
            self.assertFalse(any(p.startswith("resourcedetection/") for p in pipeline["processors"]))

    def test_features_are_independent_and_all_disabled_emits_nothing(self):
        switches = {key: {"enabled": False} for key in ["metrics", "querySamples", "topQueries", "catalog"]}
        self.assertEqual(render({}), render(values(target(**switches))))
        for feature in switches:
            with self.subTest(feature=feature):
                options = copy.deepcopy(switches)
                options[feature]["enabled"] = True
                config = render(values(target(**options)))
                pipelines = {k: v for k, v in config["service"]["pipelines"].items() if PREFIX in k}
                self.assertEqual(len(pipelines), 1)
                if feature in ["querySamples", "topQueries"]:
                    receiver = config["receivers"][f"postgresql/{PREFIX}orders_queries"]
                    self.assertEqual(receiver["events"]["db.server.query_sample"]["enabled"], feature == "querySamples")
                    self.assertEqual(receiver["events"]["db.server.top_query"]["enabled"], feature == "topQueries")

    def test_tls_applies_to_native_and_sql_receivers(self):
        for tls, mode in [({}, "verify-full"), ({"insecure": True}, "disable"),
                          ({"insecure_skip_verify": True}, "require"),
                          ({"ca_file": "/certs/ca.pem", "cert_file": "/certs/client.pem", "key_file": "/certs/key.pem"}, "verify-full")]:
            with self.subTest(tls=tls):
                config = render(values(target(tls=tls, catalog={"enabled": True})))
                for name, receiver in config["receivers"].items():
                    if name.startswith(f"sql_query/{PREFIX}"):
                        self.assertEqual(receiver["additional_params"]["sslmode"], mode)
                        if "ca_file" in tls:
                            self.assertEqual(receiver["additional_params"]["sslrootcert"], tls["ca_file"])
                            self.assertEqual(receiver["additional_params"]["sslcert"], tls["cert_file"])
                            self.assertEqual(receiver["additional_params"]["sslkey"], tls["key_file"])
                native = config["receivers"][f"postgresql/{PREFIX}orders_metrics"]
                self.assertEqual(native["tls"].get("insecure", False), tls.get("insecure", False))

    def test_ipv6_host_has_brackets_only_in_native_endpoint(self):
        item = target()
        item["host"] = "2001:db8::1"
        config = render(values(item))
        self.assertEqual(config["receivers"][f"postgresql/{PREFIX}orders_metrics"]["endpoint"], "[2001:db8::1]:5432")
        self.assertEqual(config["receivers"][f"sql_query/{PREFIX}orders_health"]["host"], item["host"])

    def test_catalog_routes_each_coralogix_destination_without_changing_normal_logs(self):
        configured = values(target(catalog={"enabled": True}))
        configured["presets"]["coralogixExporter"] = {
            "enabled": True, "domain": "example.com", "privateKey": "${env:CX_KEY}",
            "additionalEndpoints": [{"enabled": True, "name": "secondary", "domain": "other.example.com", "privateKey": "${env:SECOND_KEY}"}],
        }
        config = render(configured)
        regular = config["service"]["pipelines"]["logs"]["exporters"]
        catalog = config["service"]["pipelines"][f"logs/{PREFIX}orders_catalog"]["exporters"]
        self.assertIn("coralogix", regular)
        for source in ["coralogix", "coralogix/secondary"]:
            clone = f"coralogix/{source.split('/')[-1]}_db_monitoring_catalog"
            self.assertIn(clone, catalog)
            self.assertNotIn(clone, regular)
            settings = config["exporters"][clone]
            self.assertEqual(settings["domain"], config["exporters"][source]["domain"])
            self.assertEqual(settings["private_key"], config["exporters"][source]["private_key"])
            self.assertEqual(settings["logs"]["headers"]["x-coralogix-ingress"], "metadata-as-otlp-logs/v1")
            self.assertEqual(settings["application_name_attributes"], [])
            self.assertEqual(settings["subsystem_name_attributes"], [])

    def test_config_overrides_generated_receiver(self):
        configured = values(target())
        receiver = f"postgresql/{PREFIX}orders_metrics"
        configured["config"] = {"receivers": {receiver: {"collection_interval": "37s"}}}
        self.assertEqual(render(configured)["receivers"][receiver]["collection_interval"], "37s")

    def test_polling_only_inherits_exporters_and_keeps_self_metrics(self):
        for self_metrics in [False, True]:
            with self.subTest(self_metrics=self_metrics):
                configured = values(target(querySamples={"enabled": True}, catalog={"enabled": True}))
                configured["presets"].update({
                    "otlpReceiver": {"enabled": False},
                    "collectorMetrics": {"enabled": self_metrics},
                    "coralogixExporter": {"enabled": True, "domain": "example.com"},
                })
                configured["config"] = {"service": {"pipelines": {
                    signal: {"exporters": []} for signal in ["logs", "metrics", "traces"]
                }}}
                config = render(configured)
                pipelines = config["service"]["pipelines"]
                self.assertNotIn("logs", pipelines)
                self.assertNotIn("traces", pipelines)
                self.assertEqual("metrics" in pipelines, self_metrics)
                self.assertNotIn("otlp", config["receivers"])
                self.assertEqual(pipelines[f"metrics/{PREFIX}orders"]["exporters"], ["coralogix"])
                self.assertEqual(pipelines[f"logs/{PREFIX}orders_queries"]["exporters"], ["coralogix"])
                self.assertEqual(pipelines[f"logs/{PREFIX}orders_catalog"]["exporters"],
                                 ["coralogix/coralogix_db_monitoring_catalog"])
                for pipeline in pipelines.values():
                    self.assertTrue(pipeline["receivers"])
                    self.assertTrue(pipeline["exporters"])

    def test_polling_only_preserves_other_log_inputs(self):
        configured = values(target(querySamples={"enabled": True}))
        configured["presets"]["otlpReceiver"] = {"enabled": False}
        configured["config"] = {
            "receivers": {"filelog/application": {"include": ["/var/log/application/*.log"]}},
            "service": {"pipelines": {"logs": {"receivers": ["filelog/application"]}}},
        }
        config = render(configured)
        self.assertEqual(config["service"]["pipelines"]["logs"]["receivers"], ["filelog/application"])
        self.assertIn(f"logs/{PREFIX}orders_queries", config["service"]["pipelines"])

    def test_invalid_targets_fail_before_deploy(self):
        cases = [values(target(), target())]
        for field, value in [("port", 0), ("port", 65536), ("host", ""), ("name", "bad/name"),
                             ("databases", []), ("databases", ["orders", "orders"]), ("typo", True)]:
            item = target()
            item[field] = value
            cases.append(values(item))
        item = target()
        del item["instanceId"]
        cases.append(values(item))
        for configured in cases:
            with self.subTest(configured=configured), self.assertRaises(ValueError):
                render(configured)

    @unittest.skipUnless(os.environ.get("OTELCOL_BINARY"), "Set OTELCOL_BINARY to the collector version in Chart.yaml")
    def test_collector_accepts_example_in_each_mode(self):
        configured = yaml.safe_load((CHART / "examples/db-monitoring/values.yaml").read_text())
        env = dict(
            os.environ,
            MY_POD_IP="127.0.0.1",
            ORDERS_DB_PASSWORD="test",
            INVENTORY_DB_PASSWORD="test",
            CORALOGIX_PRIVATE_KEY="test",
        )
        for mode in ["daemonset", "deployment", "statefulset"]:
            configured["mode"] = mode
            if mode != "deployment":
                configured["rollout"] = {"strategy": "RollingUpdate"}
            config = render(configured)
            with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml") as output:
                yaml.safe_dump(config, output)
                output.flush()
                result = subprocess.run([os.environ["OTELCOL_BINARY"], "validate", "--config", output.name],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)

    @unittest.skipUnless(os.environ.get("DB_MONITORING_TEST_DSN"), "Set DB_MONITORING_TEST_DSN to a scratch PostgreSQL database")
    def test_queries_read_real_database_and_schema_hash_changes(self):
        def sql(statement):
            result = subprocess.run(["psql", os.environ["DB_MONITORING_TEST_DSN"], "-X", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-c", statement],
                                    capture_output=True, text=True, check=True)
            return result.stdout.strip()

        schema = "dbm_test_" + uuid.uuid4().hex
        config = render(values(target(catalog={"enabled": True})))
        sql(f'CREATE SCHEMA "{schema}"; CREATE TABLE "{schema}".orders (id integer PRIMARY KEY, total numeric NOT NULL) WITH (fillfactor = 80);')
        try:
            for name, receiver in config["receivers"].items():
                if name.startswith("sql_query/"):
                    for query in receiver["queries"]:
                        sql(query["sql"])
            query = config["receivers"][f"sql_query/{PREFIX}orders_schema_postgres"]["queries"][0]["sql"]
            snapshot = lambda: json.loads(sql(f"SELECT row_to_json(result) FROM ({query.strip()}) result"))
            before = snapshot()
            self.assertEqual(before["schema_hash"], snapshot()["schema_hash"])
            tables = json.loads(before["schema_variants"])[0]["tables"]
            table = next(t for t in tables if t["schema"] == schema and t["name"] == "orders")
            self.assertEqual([c["name"] for c in table["columns"]], ["id", "total"])
            self.assertTrue(table["indexes"][0]["primary"])
            self.assertEqual(table["options"], ["fillfactor=80"])
            sql(f'ALTER TABLE "{schema}".orders SET (fillfactor = 90)')
            updated = snapshot()
            self.assertNotEqual(before["schema_hash"], updated["schema_hash"])
            sql(f'ALTER TABLE "{schema}".orders ADD COLUMN note text')
            self.assertNotEqual(updated["schema_hash"], snapshot()["schema_hash"])
        finally:
            sql(f'DROP SCHEMA "{schema}" CASCADE')

    @unittest.skipUnless(os.environ.get("OTELCOL_BINARY"), "Set OTELCOL_BINARY to the collector version in Chart.yaml")
    def test_collector_filters_both_query_user_fields(self):
        config = render(values(target(metrics={"enabled": False}, querySamples={"enabled": True})))
        pipeline = config["service"]["pipelines"][f"logs/{PREFIX}orders_queries"]
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            source = directory / "queries.jsonl"
            output = directory / "output.jsonl"
            source.write_text("".join(json.dumps({field: user}) + "\n"
                                      for field in ["postgresql.rolname", "user.name"]
                                      for user in ["monitor", "application"]))
            config["receivers"] = {"filelog": {
                "include": [str(source)], "start_at": "beginning",
                "operators": [{"type": "json_parser", "parse_to": "attributes"}],
            }}
            config["exporters"] = {"file": {"path": str(output), "flush_interval": "100ms"}}
            pipeline.update(receivers=["filelog"], exporters=["file"])
            config["service"] = {"pipelines": {"logs/test": pipeline}, "telemetry": {"metrics": {"level": "none"}}}
            path = directory / "config.yaml"
            path.write_text(yaml.safe_dump(config))
            with (directory / "collector.log").open("w+") as log:
                process = subprocess.Popen([os.environ["OTELCOL_BINARY"], "--config", str(path)],
                                           stdout=log, stderr=log)
                try:
                    deadline = time.monotonic() + 10
                    while time.monotonic() < deadline and process.poll() is None:
                        if output.exists() and output.stat().st_size:
                            break
                        time.sleep(0.1)
                finally:
                    if process.poll() is None:
                        process.terminate()
                    process.wait(timeout=5)
                log.seek(0)
                self.assertEqual(process.returncode, 0, log.read())
            records = [record for line in output.read_text().splitlines()
                       for resource in json.loads(line).get("resourceLogs", [])
                       for scope in resource["scopeLogs"] for record in scope["logRecords"]]
            self.assertEqual(len(records), 2)
            for record in records:
                attributes = {a["key"]: a["value"].get("stringValue") for a in record["attributes"]}
                self.assertEqual(attributes["user.name"], "application")


if __name__ == "__main__":
    unittest.main()
