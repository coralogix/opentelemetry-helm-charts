#!/usr/bin/env python3
"""Render regression checks; optionally exercise rendered DB pipelines in kind.

Requires Python 3 + PyYAML, helm; runtime checks also require kubectl and a
kind context with the collector and busybox images available. See README.md.
"""
import argparse
import copy
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

import yaml

CHART = Path(__file__).resolve().parents[1]
PROCESSOR = "transform/db_deprecated_semconv"
COLLECTION_KEYS = ["db.sql.table", "db.cassandra.table", "db.mongodb.collection",
                   "db.redis.database_index", "db.elasticsearch.path_parts.index",
                   "db.cosmosdb.container", "aws_dynamodb.table_names"]
NAMESPACE_KEYS = ["db.name", "server.address", "network.peer.name", "net.peer.name", "db.system"]


def run(*args, input=None, check=True):
    result = subprocess.run(args, input=input, text=True, capture_output=True)
    if check and result.returncode:
        raise RuntimeError(f"{args}: {result.stderr}\n{result.stdout}")
    return result


def render(preset, enabled, db=True, compact=True, mode="deployment"):
    db_settings = {"enabled": db, "compactMetrics": {"enabled": compact}}
    if enabled is not None:
        db_settings["deprecatedSemConv"] = {"enabled": enabled}
    values = {"mode": mode, "presets": {
        "fleetManagement": {"enabled": False},
        "batch": {"enabled": True},
        "spanMetricsSanitization": {"enabled": False},
        preset: {"enabled": True, "dbMetrics": db_settings,
                 "compactMetrics": {"enabled": False}, "collectionInterval": "1s",
                 "seriesExpiration": "", "aggregationCardinalityLimit": 100}}}
    with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml") as f:
        yaml.safe_dump(values, f)
        f.flush()
        manifests = run("helm", "template", "semconv", str(CHART), "-f", f.name).stdout
    configs = [yaml.safe_load(d["data"]["relay"])
               for d in yaml.safe_load_all(manifests)
               if d and d["kind"] == "ConfigMap" and "relay" in d.get("data", {})]
    assert len(configs) == 1, configs
    config = configs[0]
    assert "Error" not in config, config.get("Error")
    return config


def render_checks():
    count = 0
    for preset in ("spanMetrics", "spanMetricsMulti"):
        for mode in ("deployment", "daemonset"):
            for enabled in (None, False, True):
                for db, compact in ((True, True), (True, False), (False, True), (False, False)):
                    config = render(preset, enabled, db, compact, mode)
                    effective_enabled = preset == "spanMetrics" if enabled is None else enabled
                    present = effective_enabled and (db or compact)
                    assert (PROCESSOR in config.get("processors", {})) == present
                    if present:
                        statements = config["processors"][PROCESSOR]["trace_statements"][0]["statements"]
                        expected = []
                        for key in NAMESPACE_KEYS:
                            guard = ' and attributes["db.system"] != nil' if key != "db.name" else ""
                            expected.append(f'set(attributes["db.namespace"], attributes["{key}"]) where attributes["db.namespace"] == nil{guard}')
                        expected.append('set(attributes["db.operation.name"], attributes["db.operation"]) where attributes["db.operation.name"] == nil')
                        expected += [f'set(attributes["db.collection.name"], attributes["{key}"]) where attributes["db.collection.name"] == nil' for key in COLLECTION_KEYS]
                        assert statements == expected
                    for suffix, active in (("db", db), ("db_compact", compact)):
                        pipeline = config["service"]["pipelines"].get("traces/" + suffix)
                        assert bool(pipeline) == active
                        if active:
                            processors = pipeline["processors"]
                            assert (PROCESSOR in processors) == present
                            if present:
                                assert processors.index(PROCESSOR) + 1 == processors.index("filter/" + suffix + "_spanmetrics")
                    count += 1
    assert render("spanMetrics", None) == render("spanMetrics", True)
    assert render("spanMetricsMulti", None) == render("spanMetricsMulti", False)
    print(f"PASS: {count} render cases (both presets, both modes, defaults and independent DB pipelines)", flush=True)


def any_value(value):
    if isinstance(value, int):
        return {"intValue": str(value)}
    if isinstance(value, list):
        return {"arrayValue": {"values": [any_value(v) for v in value]}}
    return {"stringValue": value}


def attributes(values):
    return [{"key": key, "value": any_value(value)} for key, value in values.items()]


def decode_attributes(values):
    def decode(v):
        if "intValue" in v:
            return int(v["intValue"])
        if "arrayValue" in v:
            return [decode(item) for item in v["arrayValue"]["values"]]
        return next(iter(v.values()), None)
    return {a["key"]: decode(a["value"]) for a in values}


def fixtures():
    cases = []
    for index, key in enumerate(NAMESPACE_KEYS):
        # Include lower-priority alternatives to prove fallback ordering.
        attrs = {k: f"namespace-{i}" for i, k in enumerate(NAMESPACE_KEYS[index:-1], index)}
        attrs["db.system"] = "postgresql"
        cases.append((f"namespace-{index}", attrs, "postgresql" if key == "db.system" else f"namespace-{index}", 3))
    for index, key in enumerate(COLLECTION_KEYS):
        value = 7 if key == "db.redis.database_index" else ["table-a", "table-b"] if key == "aws_dynamodb.table_names" else f"table-{index}"
        cases.append((f"collection-{index}", {"db.system": "postgresql", "db.name": f"collection-db-{index}", "db.operation": "SELECT", key: value}, f"collection-db-{index}", 3))
    cases += [("modern", {"db.system": "postgresql", "db.namespace": "modern-db", "db.name": "old-db", "db.operation.name": "modern-op", "db.operation": "old-op", "db.collection.name": "modern-table", "db.sql.table": "old-table"}, "modern-db", 3),
              ("server", {"db.system": "postgresql", "db.name": "server-db"}, "server-db", 2),
              ("not-db", {"server.address": "web", "db.name": "not-db"}, None, 3),
              ("modern-system", {"db.system.name": "postgresql", "db.namespace": "modern-system-db"}, "modern-system-db", 3)]
    now = time.time_ns()
    spans = [{"traceId": f"{index+1:032x}", "spanId": f"{index+1:016x}", "name": name, "kind": kind,
              "startTimeUnixNano": str(now), "endTimeUnixNano": str(now+5_000_000), "attributes": attributes(attrs)}
             for index, (name, attrs, _, kind) in enumerate(cases)]
    return cases, {"resourceSpans": [{"resource": {"attributes": attributes({"service.name": "legacy-db-test"})}, "scopeSpans": [{"scope": {"name": "db-semconv-test"}, "spans": spans}]}]}


def runtime_config(rendered):
    # Keep the actual rendered DB processor and connector settings; replace only
    # external receivers/exporters with local test endpoints and capture traces.
    c = {"receivers": {"otlp": {"protocols": {"http": {"endpoint": "0.0.0.0:4318"}}}},
         "exporters": {"file/traces": {"path": "/output/traces.json", "flush_interval": "100ms"},
                       "file/metrics": {"path": "/output/metrics.json", "flush_interval": "100ms"}},
         "processors": {}, "connectors": {}, "service": {"pipelines": {}}}
    for suffix in ("db", "db_compact"):
        pipeline = copy.deepcopy(rendered["service"]["pipelines"]["traces/" + suffix])
        pipeline["receivers"] = ["otlp"]
        if suffix == "db":
            pipeline["exporters"].append("file/traces")
        c["service"]["pipelines"]["traces/" + suffix] = pipeline
        for processor in pipeline["processors"]:
            c["processors"][processor] = copy.deepcopy(rendered["processors"][processor])
        connector = "spanmetrics/" + suffix
        c["connectors"][connector] = copy.deepcopy(rendered["connectors"][connector])
        c["service"]["pipelines"]["metrics/" + suffix] = {"receivers": [connector], "exporters": ["file/metrics"]}
    return c


def check_output(cases, enabled, traces, metrics):
    spans = {s["name"]: decode_attributes(s.get("attributes", [])) for record in traces
             for resource in record.get("resourceSpans", []) for scope in resource.get("scopeSpans", []) for s in scope.get("spans", [])}
    assert "not-db" not in spans
    for name, attrs, namespace, _ in cases:
        if namespace is None:
            continue
        actual = spans[name]
        if enabled:
            assert actual["db.namespace"] == namespace, (name, actual)
            if name.startswith("collection-"):
                assert actual["db.operation.name"] == "SELECT", (name, actual)
                key = COLLECTION_KEYS[int(name.split("-")[1])]
                assert actual["db.collection.name"] == attrs[key], (name, actual)
        elif "db.namespace" not in attrs:
            assert "db.namespace" not in actual, (name, actual)
    assert spans["modern"]["db.operation.name"] == "modern-op"
    assert spans["modern"]["db.collection.name"] == "modern-table"
    points = {}
    for record in metrics:
        for resource in record.get("resourceMetrics", []):
            for scope in resource.get("scopeMetrics", []):
                for metric in scope.get("metrics", []):
                    points.setdefault(metric["name"], []).extend(metric.get("sum", metric.get("histogram", {})).get("dataPoints", []))
    expected = {namespace for _, attrs, namespace, kind in cases if namespace and kind == 3 and (enabled or "db.namespace" in attrs)}
    for metric_name in ("db_compact.calls", "db_compact.duration"):
        observed = {decode_attributes(p.get("attributes", []))["db.namespace"] for p in points.get(metric_name, [])}
        assert observed == expected, (metric_name, observed, expected)
    # Detailed DB metric dimensions also retain the mapped operation/collection.
    db_points = [decode_attributes(p.get("attributes", [])) for p in points["db.calls"]]
    if enabled:
        for index in range(len(COLLECTION_KEYS)):
            point = next(p for p in db_points if p.get("span.name") == f"collection-{index}")
            assert point["db.operation.name"] == "SELECT", point
            assert "db.collection.name" in point, point
    return {"spans": len(spans), "compact_namespaces": sorted(expected), "metric_names": sorted(points)}


def kind_check(args, preset, enabled):
    case_name = f"{preset.lower()}-{'enabled' if enabled else 'disabled'}"
    folder = args.output / case_name
    folder.mkdir(parents=True, exist_ok=True)
    rendered = render(preset, enabled)
    config = runtime_config(rendered)
    (folder / "rendered.yaml").write_text(yaml.safe_dump(rendered))
    (folder / "collector.yaml").write_text(yaml.safe_dump(config))
    cases, payload = fixtures()
    (folder / "spans.json").write_text(json.dumps(payload, indent=2))
    name = "db-semconv-" + case_name
    def kubectl(*command, **kwargs):
        return run("kubectl", "--context", args.context, *command, **kwargs)
    configmap = {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": name}, "data": {"collector.yaml": yaml.safe_dump(config)}}
    pod = {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": name}, "spec": {
        "securityContext": {"fsGroup": 1000},
        "containers": [{"name": "collector", "image": args.image, "args": ["--config=/config/collector.yaml"],
                        "volumeMounts": [{"name": "config", "mountPath": "/config"}, {"name": "output", "mountPath": "/output"}]},
                       {"name": "reader", "image": "busybox:1.37", "command": ["sleep", "3600"],
                        "volumeMounts": [{"name": "output", "mountPath": "/output"}]}],
        "volumes": [{"name": "config", "configMap": {"name": name}}, {"name": "output", "emptyDir": {}}]}}
    kubectl("apply", "-f", "-", input=yaml.safe_dump(configmap)+"---\n"+yaml.safe_dump(pod))
    forward = None
    try:
        ready = kubectl("wait", "--for=condition=Ready", "pod/"+name, "--timeout=60s", check=False)
        if ready.returncode:
            raise AssertionError(kubectl("logs", name, "-c", "collector", check=False).stdout + ready.stderr)
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        forward = subprocess.Popen(["kubectl", "--context", args.context, "port-forward", "pod/"+name, f"{port}:4318"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic()+15
        while True:
            try:
                request = urllib.request.Request(f"http://127.0.0.1:{port}/v1/traces", data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"})
                with urllib.request.urlopen(request, timeout=5) as response:
                    result = json.load(response)
                    assert not result.get("partialSuccess", {}).get("rejectedSpans"), result
                break
            except urllib.error.URLError:
                if time.monotonic() > deadline:
                    raise
                time.sleep(0.2)
        deadline = time.monotonic()+25
        last_error = None
        while time.monotonic() < deadline:
            outputs = {}
            for signal in ("traces", "metrics"):
                contents = kubectl("exec", name, "-c", "reader", "--", "cat", f"/output/{signal}.json", check=False).stdout
                (folder / (signal+".jsonl")).write_text(contents)
                outputs[signal] = [json.loads(line) for line in contents.splitlines() if line.strip()]
            try:
                result = check_output(cases, enabled, outputs["traces"], outputs["metrics"])
                (folder / "result.json").write_text(json.dumps(result, indent=2))
                print(f"PASS: kind {preset} enabled={enabled}: {result['spans']} DB spans; {len(result['compact_namespaces'])} compact namespaces", flush=True)
                return
            except (AssertionError, KeyError) as error:
                last_error = error
                time.sleep(0.5)
        raise AssertionError(f"Runtime assertions failed: {last_error}")
    finally:
        (folder / "collector.log").write_text(kubectl("logs", name, "-c", "collector", check=False).stdout)
        if forward:
            forward.terminate()
            forward.wait(timeout=5)
        kubectl("delete", "pod", name, "--wait=false", check=False)
        kubectl("delete", "configmap", name, check=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--context", help="Dedicated kind context to run actual Collector tests")
    parser.add_argument("--image", default="otel/opentelemetry-collector-contrib:0.161.0")
    parser.add_argument("--output", type=Path, default=Path(tempfile.gettempdir()) / "db-deprecated-semconv-results")
    args = parser.parse_args()
    if args.context and not args.context.startswith("kind-"):
        parser.error("Use a dedicated kind context")
    render_checks()
    if args.context:
        for preset in ("spanMetrics", "spanMetricsMulti"):
            for enabled in (False, True):
                kind_check(args, preset, enabled)


if __name__ == "__main__":
    main()
