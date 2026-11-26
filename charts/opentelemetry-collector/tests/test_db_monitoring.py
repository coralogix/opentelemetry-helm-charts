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
TRACE_ID = "4bf92f3577b34da6a3ce929d0e0e4736"
SPAN_ID = "00f067aa0ba902b7"
TRACEPARENT = f"00-{TRACE_ID}-{SPAN_ID}-01"


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


def target(name="orders", *, username="monitor", auth=None, **options):
    if auth is None:
        auth = {"password": f"${{env:{name.upper()}_PASSWORD}}"}
    return dict(name=name, host=f"{name}.example.com", username=username, auth=auth,
                instanceId=f"production/{name}", **options)


def collect_logs(config, pipeline, inputs, operators, *, receiver_options=None):
    with tempfile.TemporaryDirectory() as directory:
        directory = Path(directory)
        source = directory / "input.jsonl"
        output = directory / "output.jsonl"
        source.write_text(inputs if isinstance(inputs, str) else "".join(json.dumps(record) + "\n" for record in inputs))
        config["receivers"] = {"file_log": {
            **(receiver_options or {}),
            "include": [str(source)], "start_at": "beginning", "operators": operators,
        }}
        config["exporters"] = {"file": {"path": str(output), "flush_interval": "100ms"}}
        pipeline.update(receivers=["file_log"], exporters=["file"])
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
            if process.returncode != 0 or not output.exists():
                raise AssertionError(log.read())
        return [record for line in output.read_text().splitlines()
                for resource in json.loads(line).get("resourceLogs", [])
                for scope in resource["scopeLogs"] for record in scope["logRecords"]]


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
                self.assertEqual(connection["password"], item["auth"]["password"])
                if receiver.startswith("sql_query/"):
                    self.assertEqual(connection["host"], item["host"])
            identity = config["processors"][f"resource/{PREFIX}{item['name']}"]
            attributes = {a["key"]: a["value"] for a in identity["attributes"]}
            self.assertEqual(attributes["cx.db.instance.id"], item["instanceId"])
            self.assertEqual(attributes["server.address"], item["host"])
            self.assertFalse(any(p.startswith("resourcedetection/") for p in pipeline["processors"]))

    def test_features_are_independent_and_all_disabled_emits_nothing(self):
        switches = {key: {"enabled": False} for key in ["metrics", "querySamples", "activitySnapshots", "topQueries", "catalog"]}
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

    def test_database_logs_route_each_coralogix_destination_without_changing_normal_logs(self):
        configured = values(target(catalog={"enabled": True}, topQueries={"enabled": True}))
        configured["presets"]["coralogixExporter"] = {
            "enabled": True, "domain": "example.com", "privateKey": "${env:CX_KEY}",
            "additionalEndpoints": [{"enabled": True, "name": "secondary", "domain": "other.example.com", "privateKey": "${env:SECOND_KEY}"}],
        }
        config = render(configured)
        regular = config["service"]["pipelines"]["logs"]["exporters"]
        catalog = config["service"]["pipelines"][f"logs/{PREFIX}orders_catalog"]["exporters"]
        queries = config["service"]["pipelines"][f"logs/{PREFIX}orders_queries"]["exporters"]
        self.assertIn("coralogix", regular)
        self.assertIn("debug", queries)
        self.assertIn("debug", catalog)
        for source in ["coralogix", "coralogix/secondary"]:
            original = config["exporters"][source]
            for kind, exporters in [("catalog", catalog), ("queries", queries)]:
                clone = f"coralogix/{source.split('/')[-1]}_db_monitoring_{kind}"
                self.assertIn(clone, exporters)
                self.assertNotIn(source, exporters)
                self.assertNotIn(clone, regular)
                settings = config["exporters"][clone]
                self.assertEqual(settings["domain"], original["domain"])
                self.assertEqual(settings["private_key"], original["private_key"])
                self.assertEqual(settings["subsystem_name_attributes"], [])
                if kind == "catalog":
                    self.assertEqual(settings["logs"]["headers"]["x-coralogix-ingress"], "metadata-as-otlp-logs/v1")
                    self.assertEqual(settings["application_name_attributes"], [])
                else:
                    self.assertEqual(settings["subsystem_name"], "postgresql-slow-queries")
                    self.assertEqual(settings["application_name_attributes"], original["application_name_attributes"])
                    self.assertEqual(settings["logs"], original["logs"])

    def test_receiver_schedules_and_plan_cache_can_be_set_independently(self):
        configured = values(target(
            databases=["orders", "billing"], collectionInterval="45s",
            querySamples={"enabled": True}, topQueries={"enabled": True, "planCacheTTL": "2h"},
            activitySnapshots={"enabled": True}, catalog={"enabled": True},
            receivers={
                "health": {"collectionInterval": "1m"},
                "tables": {"collectionInterval": "2m"},
                "querySamples": {"collectionInterval": "10s", "initialDelay": "0s"},
                "activitySnapshots": {"collectionInterval": "15s", "initialDelay": "2s", "timeout": "8s"},
                "topQueries": {"collectionInterval": "3m", "initialDelay": "30s", "timeout": "20s"},
                "details": {"collectionInterval": "15m", "initialDelay": "1m"},
                "schema": {"collectionInterval": "30m", "initialDelay": "4m"},
            },
        ))
        config = render(configured)
        receivers = config["receivers"]
        expected = {
            f"postgresql/{PREFIX}orders_metrics": "45s",
            f"postgresql/{PREFIX}orders_samples": "10s",
            f"postgresql/{PREFIX}orders_queries": "3m",
            f"sql_query/{PREFIX}orders_activity": "15s",
            f"sql_query/{PREFIX}orders_health": "1m",
            f"sql_query/{PREFIX}orders_details": "15m",
        }
        for database in ["orders", "billing"]:
            expected[f"sql_query/{PREFIX}orders_tables_{database}"] = "2m"
            expected[f"sql_query/{PREFIX}orders_schema_{database}"] = "30m"
            self.assertEqual(receivers[f"sql_query/{PREFIX}orders_schema_{database}"]["initial_delay"], "4m")
        self.assertEqual({name: receivers[name]["collection_interval"] for name in expected}, expected)
        self.assertEqual(receivers[f"sql_query/{PREFIX}orders_details"]["initial_delay"], "1m")
        samples = receivers[f"postgresql/{PREFIX}orders_samples"]
        top = receivers[f"postgresql/{PREFIX}orders_queries"]
        self.assertEqual(samples["initial_delay"], "0s")
        self.assertEqual(top["initial_delay"], "30s")
        self.assertEqual(top["timeout"], "20s")
        activity = receivers[f"sql_query/{PREFIX}orders_activity"]
        self.assertEqual(activity["initial_delay"], "2s")
        self.assertEqual(activity["timeout"], "8s")
        self.assertEqual(top["top_query_collection"]["collection_interval"], "3m")
        self.assertEqual(top["top_query_collection"]["query_plan_cache_ttl"], "2h")
        self.assertTrue(samples["events"]["db.server.query_sample"]["enabled"])
        self.assertFalse(samples["events"]["db.server.top_query"]["enabled"])
        self.assertFalse(top["events"]["db.server.query_sample"]["enabled"])
        self.assertTrue(top["events"]["db.server.top_query"]["enabled"])
        pipeline = config["service"]["pipelines"][f"logs/{PREFIX}orders_queries"]
        self.assertEqual(set(pipeline["receivers"]), {f"postgresql/{PREFIX}orders_queries", f"postgresql/{PREFIX}orders_samples"})

    def test_top_queries_and_activity_snapshots_use_separate_default_schedules(self):
        config = render(values(target(collectionInterval="45s", topQueries={"enabled": True},
                                      activitySnapshots={"enabled": True})))
        pipelines = config["service"]["pipelines"]
        queries = pipelines[f"logs/{PREFIX}orders_queries"]
        snapshots = pipelines[f"logs/{PREFIX}orders_activity"]
        top = config["receivers"][queries["receivers"][0]]
        activity = config["receivers"][snapshots["receivers"][0]]
        self.assertEqual(top["collection_interval"], "60s")
        self.assertEqual(top["top_query_collection"]["collection_interval"], "60s")
        self.assertEqual(top["top_query_collection"]["top_n_query"], 200)
        self.assertEqual(top["top_query_collection"]["max_rows_per_query"], 200)
        self.assertFalse(top["events"]["db.server.query_sample"]["enabled"])
        self.assertEqual(activity["collection_interval"], "10s")
        self.assertEqual(snapshots["exporters"], queries["exporters"])

    def test_postgresql_default_schedules_and_rds_database_exclusions(self):
        features = {
            "databases": ["postgres", "rdsadmin"],
            "querySamples": {"enabled": True}, "topQueries": {"enabled": True}, "catalog": {"enabled": True},
        }
        inventory = target("inventory", **features)
        inventory["host"] = "inventory.example.us-east-1.rds.amazonaws.com"
        config = render(values(target(**features), inventory))
        receivers = config["receivers"]
        for name, schema_delay in [("orders", "3m"), ("inventory", "30s")]:
            prefix = f"{PREFIX}{name}"
            expected = {
                f"postgresql/{prefix}_metrics": "60s",
                f"postgresql/{prefix}_queries": "60s",
                f"sql_query/{prefix}_health": "60s",
                f"sql_query/{prefix}_tables_postgres": "5m",
                f"sql_query/{prefix}_details": "5m",
                f"sql_query/{prefix}_schema_postgres": "5m",
            }
            self.assertEqual({key: receivers[key]["collection_interval"] for key in expected}, expected)
            self.assertEqual(receivers[f"sql_query/{prefix}_details"]["initial_delay"], "30s")
            self.assertEqual(receivers[f"sql_query/{prefix}_schema_postgres"]["initial_delay"], schema_delay)
            self.assertTrue(receivers[f"postgresql/{prefix}_queries"]["events"]["db.server.query_sample"]["enabled"])

        for component in ["metrics", "queries"]:
            self.assertEqual(receivers[f"postgresql/{PREFIX}inventory_{component}"]["exclude_databases"], ["rdsadmin"])
            self.assertNotIn("exclude_databases", receivers[f"postgresql/{PREFIX}orders_{component}"])
        for component in ["tables", "schema"]:
            self.assertNotIn(f"sql_query/{PREFIX}inventory_{component}_rdsadmin", receivers)
            self.assertIn(f"sql_query/{PREFIX}orders_{component}_rdsadmin", receivers)

        inventory["excludeDatabases"] = []
        receivers = render(values(inventory))["receivers"]
        self.assertNotIn("exclude_databases", receivers[f"postgresql/{PREFIX}inventory_queries"])
        self.assertIn(f"sql_query/{PREFIX}inventory_schema_rdsadmin", receivers)

    def test_auth_applies_to_every_receiver_for_each_target(self):
        features = {
            "querySamples": {"enabled": True}, "topQueries": {"enabled": True}, "catalog": {"enabled": True},
            "activitySnapshots": {"enabled": True},
            "receivers": {"querySamples": {"collectionInterval": "30s"}},
        }
        orders = target(**features)
        inventory = target("inventory", username="inventory_reader", auth={"aws_iam": {"region": "us-east-1"}}, **features)
        billing = target("billing", username="billing_reader", auth={"aws_iam": {"region": "us-west-2"}}, **features)
        config = render(values(orders, inventory, billing))
        east, west = "aws_iam_db_auth/us-east-1", "aws_iam_db_auth/us-west-2"
        self.assertEqual(config["extensions"][east]["region"], "us-east-1")
        self.assertEqual(config["extensions"][west]["region"], "us-west-2")
        self.assertEqual(config["service"]["extensions"].count(east), 1)
        self.assertEqual(config["service"]["extensions"].count(west), 1)
        self.assertIn("health_check", config["service"]["extensions"])
        for item, expected in [
            (orders, {"username": "monitor", "password": orders["auth"]["password"]}),
            (inventory, {"username": "inventory_reader", "db_auth": east}),
            (billing, {"username": "billing_reader", "db_auth": west}),
        ]:
            receiver_id = PREFIX + item["name"]
            receivers = [receiver for name, receiver in config["receivers"].items() if f"/{receiver_id}_" in name]
            self.assertEqual(len(receivers), 8)
            for receiver in receivers:
                self.assertEqual({key: receiver[key] for key in ["username", "password", "db_auth"] if key in receiver}, expected)
            conditions = config["processors"][f"filter/{receiver_id}_own_queries"]["logs"]["log_record"]
            self.assertIn(f'attributes["user.name"] == "{expected["username"]}"', conditions)

    def test_custom_query_exclusions_replace_defaults(self):
        filter_name = f"filter/{PREFIX}orders_own_queries"
        switches = {"metrics": {"enabled": False}, "querySamples": {"enabled": True}}
        config = render(values(target(excludeUsers=['custom"reader'], **switches)))
        self.assertEqual(config["processors"][filter_name]["logs"]["log_record"], [
            'attributes["postgresql.rolname"] == "custom\\"reader"',
            'attributes["user.name"] == "custom\\"reader"',
        ])
        config = render(values(target(excludeUsers=[], **switches)))
        self.assertNotIn(filter_name, config["processors"])
        self.assertNotIn(filter_name, config["service"]["pipelines"][f"logs/{PREFIX}orders_queries"]["processors"])

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
                self.assertEqual(pipelines[f"logs/{PREFIX}orders_queries"]["exporters"],
                                 ["coralogix/coralogix_db_monitoring_queries"])
                self.assertEqual(pipelines[f"logs/{PREFIX}orders_catalog"]["exporters"],
                                 ["coralogix/coralogix_db_monitoring_catalog"])
                for pipeline in pipelines.values():
                    self.assertTrue(pipeline["receivers"])
                    self.assertTrue(pipeline["exporters"])

    def test_polling_only_preserves_other_log_inputs(self):
        configured = values(target(querySamples={"enabled": True}))
        configured["presets"]["otlpReceiver"] = {"enabled": False}
        configured["config"] = {
            "receivers": {"file_log/application": {"include": ["/var/log/application/*.log"]}},
            "service": {"pipelines": {"logs": {"receivers": ["file_log/application"]}}},
        }
        config = render(configured)
        self.assertEqual(config["service"]["pipelines"]["logs"]["receivers"], ["file_log/application"])
        self.assertIn(f"logs/{PREFIX}orders_queries", config["service"]["pipelines"])

    def test_rds_logs_read_only_configured_groups_and_streams(self):
        instance = "/aws/rds/instance/inventory/postgresql"
        cluster = "/aws/rds/cluster/billing/postgresql"
        inventory = target(
            "inventory", auth={"aws_iam": {"region": "us-east-1"}}, metrics={"enabled": False},
            rdsLogs={"enabled": True},
        )
        billing = target(
            "billing", querySamples={"enabled": True}, excludeUsers=["migrator"],
            rdsLogs={"enabled": True, "region": "us-west-2", "logGroup": cluster,
                     "logStreams": ["billing-reader"], "pollInterval": "15s", "initialLookback": "2m"},
        )
        configured = values(target(), inventory, billing)
        configured["presets"]["coralogixExporter"] = {"enabled": True, "domain": "example.com"}
        config = render(configured)
        receivers = {key: entry for key, entry in config["receivers"].items() if key.startswith("aws_cloudwatch/")}
        self.assertEqual(receivers, {
            f"aws_cloudwatch/{PREFIX}inventory_rds_logs": {"region": "us-east-1", "logs": {
                "poll_interval": "30s", "initial_lookback": "1m", "groups": {"named": {instance: {}}},
            }},
            f"aws_cloudwatch/{PREFIX}billing_rds_logs": {"region": "us-west-2", "logs": {
                "poll_interval": "15s", "initial_lookback": "2m",
                "groups": {"named": {cluster: {"names": ["billing-reader"]}}},
            }},
        })
        self.assertNotIn("aws_iam_db_auth/us-east-1", config["extensions"])
        pipelines = config["service"]["pipelines"]
        plans = pipelines[f"logs/{PREFIX}billing_rds_plans"]
        queries = pipelines[f"logs/{PREFIX}billing_queries"]
        self.assertEqual(plans["exporters"], queries["exporters"])
        self.assertIn("coralogix/coralogix_db_monitoring_queries", plans["exporters"])
        self.assertIn(f"filter/{PREFIX}billing_own_queries", plans["processors"])

    def test_invalid_targets_fail_before_deploy(self):
        cases = [values(target(), target())]
        for field, value in [("port", 0), ("port", 65536), ("host", ""), ("name", "bad/name"),
                             ("databases", []), ("databases", ["orders", "orders"]), ("typo", True),
                             ("receivers", {"unknown": {}}), ("receivers", {"performance": {"collectionInterval": "never"}}),
                             ("receivers", {"health": {"dbAuth": "aws_iam"}}),
                             ("auth", {}), ("auth", {"basic": {"password": "test"}}), ("auth", {"aws_iam": {}}),
                             ("auth", {"aws_iam": {"username": "monitor", "region": "us-east-1"}}),
                             ("auth", {"password": "test", "aws_iam": {"region": "us-east-1"}})]:
            item = target()
            item[field] = value
            cases.append(values(item))
        for field in ["instanceId", "username", "auth"]:
            item = target()
            del item[field]
            cases.append(values(item))
        cases.append(values(target(auth={"aws_iam": {"region": "us-east-1"}}, tls={"insecure": True})))
        cases.append(values(target(rdsLogs={"enabled": True})))
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
        config = render(values(target(catalog={"enabled": True}, activitySnapshots={"enabled": True})))
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
    def test_catalog_events_report_their_receiver_interval(self):
        configured = values(target(
            metrics={"enabled": False}, databases=["orders", "billing"], catalog={"enabled": True},
            receivers={"details": {"collectionInterval": "7m"}, "schema": {"collectionInterval": "30m"}},
        ))
        configured["config"] = {"receivers": {
            f"sql_query/{PREFIX}orders_schema_billing": {"collection_interval": "12m"},
        }}
        config = render(configured)
        pipeline = config["service"]["pipelines"][f"logs/{PREFIX}orders_catalog"]
        records = collect_logs(config, pipeline, [
            {"kind": "db.instance", "databases": "[]", "extensions": "[]", "replication_slots": "[]", "settings": "[]"},
            {"kind": "db.schema", "datname": "orders", "schema_variants": "[]"},
            {"kind": "db.schema", "datname": "billing", "schema_variants": "[]"},
        ], [
            {"type": "json_parser", "parse_to": "attributes"},
            {"type": "move", "from": "attributes.kind", "to": "body"},
        ])
        intervals = {}
        for record in records:
            attributes = {a["key"]: a["value"] for a in record["attributes"]}
            key = attributes.get("db.namespace", record["body"])["stringValue"]
            intervals[key] = int(attributes["otel.entity.interval"]["intValue"])
        self.assertEqual(intervals, {"db.instance": 420_000, "orders": 1_800_000, "billing": 720_000})

    @unittest.skipUnless(os.environ.get("OTELCOL_BINARY"), "Set OTELCOL_BINARY to the collector version in Chart.yaml")
    def test_collector_filters_both_query_user_fields(self):
        config = render(values(target(metrics={"enabled": False}, querySamples={"enabled": True})))
        pipeline = config["service"]["pipelines"][f"logs/{PREFIX}orders_queries"]
        inputs = [{field: user} for field in ["postgresql.rolname", "user.name"]
                  for user in ["monitor", "otel", "rdsadmin", "otel_catalog", "application"]]
        records = collect_logs(config, pipeline, inputs, [{"type": "json_parser", "parse_to": "attributes"}])
        self.assertEqual(len(records), 2)
        for record in records:
            attributes = {a["key"]: a["value"].get("stringValue") for a in record["attributes"]}
            self.assertEqual(attributes["user.name"], "application")

    @unittest.skipUnless(os.environ.get("OTELCOL_BINARY"), "Set OTELCOL_BINARY to the collector version in Chart.yaml")
    def test_collector_normalizes_and_redacts_activity_snapshots(self):
        config = render(values(target(metrics={"enabled": False}, activitySnapshots={"enabled": True})))
        pipeline = config["service"]["pipelines"][f"logs/{PREFIX}orders_activity"]
        inputs = [
            {"user.name": user, "db.query.text": query, "postgresql.pid": str(pid),
             "postgresql.queryid": "101", "postgresql.state": "active", "postgresql.total_exec_time": "12",
             "dbm.traceparent": traceparent, "message": f"{pid} active"}
            for pid, user, query, traceparent in [
                (1, "app", f"SELECT * FROM orders WHERE id = 42 AND email = 'secret' /*traceparent='{TRACEPARENT}'*/", TRACEPARENT),
                (2, "app", "SELECT 'incomplete secret", ""),
                (3, "app", "SELECT order２ FROM orders", f"00-{'0' * 32}-{SPAN_ID}-01"),
                (4, "monitor", "SELECT 1", ""),
            ]
        ]
        records = collect_logs(config, pipeline, inputs, [
            {"type": "json_parser", "parse_to": "attributes"},
            {"type": "move", "from": "attributes.message", "to": "body"},
        ])
        self.assertEqual(len(records), 3)
        queries = {}
        for record in records:
            attributes = {a["key"]: next(iter(a["value"].values())) for a in record["attributes"]}
            pid = attributes["postgresql.pid"]
            self.assertEqual(record["eventName"], "db.server.query_sample")
            self.assertEqual(attributes["event.name"], "db.server.query_sample")
            self.assertEqual(record["body"]["stringValue"], f"{pid} active")
            self.assertEqual(attributes["postgresql.queryid"], "101")
            self.assertEqual(attributes["postgresql.state"], "active")
            self.assertEqual(attributes["postgresql.total_exec_time"], "12")
            self.assertNotIn("db.event.kind", attributes)
            self.assertNotIn("db.query.id", attributes)
            self.assertNotIn("dbm.raw_query", attributes)
            self.assertNotIn("dbm.activity_body", attributes)
            self.assertNotIn("dbm.traceparent", attributes)
            if pid == "1":
                self.assertEqual(attributes["trace.id"], TRACE_ID)
                self.assertEqual(attributes["span.id"], SPAN_ID)
                self.assertEqual(record["traceId"], TRACE_ID)
                self.assertEqual(record["spanId"], SPAN_ID)
            else:
                self.assertNotIn("trace.id", attributes)
                self.assertNotIn("span.id", attributes)
            queries[pid] = attributes.get("db.query.text")
        self.assertEqual(queries, {
            "1": "SELECT * FROM orders WHERE id = ? AND email = ?",
            "2": "SELECT ?",
            "3": "SELECT order2 FROM orders",
        })

    @unittest.skipUnless(os.environ.get("OTELCOL_BINARY"), "Set OTELCOL_BINARY to the collector version in Chart.yaml")
    def test_collector_extracts_and_sanitizes_rds_plans(self):
        config = render(values(target(metrics={"enabled": False}, rdsLogs={
            "enabled": True, "region": "us-east-1",
        })))
        pipeline = config["service"]["pipelines"][f"logs/{PREFIX}orders_rds_plans"]

        def message(user, query_id, extra="", query="SELECT secret"):
            plan = json.dumps({
                "Query Identifier": query_id,
                "Query Text": query,
                "Query Parameters": "$1 = 'secret'",
                "Plan": {"Node Type": "Seq Scan", "Alias": "someone's table", "Filter": "(email = 'secret'::text)"},
            }, indent=2)
            return f"2026-11-25 12:00:00 UTC:2001:db8::1(9000):{user}@orders:[123]:{extra}LOG:  duration: 12.5 ms  plan:\n{plan}"

        extended = "16:00000:2026-11-25 11:00:00 UTC:SELECT:1:abc.123:db-client:"
        inputs = [{"message": line} for line in [
            message("application", -9223372036854775807),
            message("application", 42, extended, f"SELECT 1 /*traceparent='{TRACEPARENT}'*/"),
            message("monitor", 43),
            message("rdsadmin", 44),
            message("application", 0),
            message("application", 45)[:-3],
            "2026-11-25 12:00:00 UTC:LOG: ordinary PostgreSQL message",
        ]]
        records = collect_logs(config, pipeline, inputs, [
            {"type": "json_parser", "parse_to": "attributes"},
            {"type": "move", "from": "attributes.message", "to": "body"},
        ])
        self.assertEqual(len(records), 2)
        ids = set()
        for record in records:
            self.assertEqual(record["eventName"], "db.server.query_plan")
            self.assertEqual(record["body"]["stringValue"], "auto_explain plan")
            attributes = {a["key"]: next(iter(a["value"].values())) for a in record["attributes"]}
            self.assertEqual(attributes["event.name"], "db.server.query_plan")
            self.assertEqual(attributes["db.plan.source"], "auto_explain")
            self.assertEqual(attributes["db.query.duration_ms"], 12.5)
            self.assertEqual(attributes["db.namespace"], "orders")
            self.assertEqual(attributes["client.address"], "2001:db8::1")
            self.assertNotIn("db.query.plan", attributes)
            self.assertNotIn("dbm.traceparent", attributes)
            query_id = int(attributes["postgresql.queryid"])
            ids.add(query_id)
            self.assertEqual(json.loads(attributes["postgresql.query_plan"]), {
                "Query Identifier": query_id,
                "Plan": {"Node Type": "Seq Scan", "Alias": "someone's table", "Filter": "(email = '?'::text)"},
            })
            if query_id == 42:
                self.assertEqual(attributes["postgresql.application_name"], "db-client")
                self.assertEqual(attributes["trace.id"], TRACE_ID)
                self.assertEqual(attributes["span.id"], SPAN_ID)
            else:
                self.assertNotIn("trace.id", attributes)
        self.assertEqual(ids, {-9223372036854775807, 42})


if __name__ == "__main__":
    unittest.main()
