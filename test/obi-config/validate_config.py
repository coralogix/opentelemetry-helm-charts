import argparse
import json
import pathlib
import sys
import time
import urllib.error
import urllib.request

import yaml
from jsonschema import Draft202012Validator

TEST_DIR = pathlib.Path(__file__).resolve().parent
REPO_ROOT = TEST_DIR.parent.parent
CHART_DIR = REPO_ROOT / "charts" / "opentelemetry-ebpf-instrumentation"
SCHEMA_URL_TEMPLATE = (
    "https://raw.githubusercontent.com/open-telemetry/"
    "opentelemetry-ebpf-instrumentation/{version}/devdocs/config/config-schema.json"
)
FETCH_ATTEMPTS = 3
FETCH_TIMEOUT = 30
MAX_DEPTH = 40
BOOL_AS_STRING = {True: "true", False: "false"}


def chart_app_version():
    chart = yaml.safe_load((CHART_DIR / "Chart.yaml").read_text())
    return str(chart.get("appVersion", "")).strip()


def fetch_schema(url):
    last_error = None
    for attempt in range(1, FETCH_ATTEMPTS + 1):
        try:
            with urllib.request.urlopen(url, timeout=FETCH_TIMEOUT) as response:
                return json.loads(response.read().decode())
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
            last_error = error
            if attempt < FETCH_ATTEMPTS:
                time.sleep(2 * attempt)
    raise SystemExit(f"could not fetch the OBI config schema from {url}: {last_error}")


def resolve_ref(schema, root, depth=0):
    while isinstance(schema, dict) and "$ref" in schema and depth < MAX_DEPTH:
        ref = schema["$ref"]
        if not ref.startswith("#/$defs/"):
            break
        schema = root.get("$defs", {}).get(ref.split("/")[-1], {})
        depth += 1
    return schema if isinstance(schema, dict) else {}


def accepts_type(schema, root, type_name, depth=0):
    if depth > MAX_DEPTH:
        return False
    schema = resolve_ref(schema, root)
    declared = schema.get("type")
    if declared == type_name:
        return True
    if isinstance(declared, list) and type_name in declared:
        return True
    enum = schema.get("enum")
    if enum and type_name == "string" and any(isinstance(v, str) for v in enum):
        return True
    for combinator in ("oneOf", "anyOf", "allOf"):
        for branch in schema.get(combinator, []):
            if accepts_type(branch, root, type_name, depth + 1):
                return True
    return False


def coerce_yaml_scalars(value, schema, root, depth=0):
    if depth > MAX_DEPTH:
        return value
    schema = resolve_ref(schema, root)
    if isinstance(value, bool):
        if accepts_type(schema, root, "string") and not accepts_type(schema, root, "boolean"):
            return BOOL_AS_STRING[value]
        return value
    if isinstance(value, dict):
        properties = schema.get("properties", {})
        extra = schema.get("additionalProperties")
        coerced = {}
        for key, item in value.items():
            if key in properties:
                coerced[key] = coerce_yaml_scalars(item, properties[key], root, depth + 1)
            elif isinstance(extra, dict):
                coerced[key] = coerce_yaml_scalars(item, extra, root, depth + 1)
            else:
                coerced[key] = item
        return coerced
    if isinstance(value, list):
        items = schema.get("items")
        if isinstance(items, dict):
            return [coerce_yaml_scalars(item, items, root, depth + 1) for item in value]
    return value


def extract_obi_configs(configmap_path):
    configs = []
    for doc in yaml.safe_load_all(configmap_path.read_text()):
        if not isinstance(doc, dict) or doc.get("kind") != "ConfigMap":
            continue
        for key, value in (doc.get("data") or {}).items():
            if "config" in key and isinstance(value, str):
                configs.append((key, yaml.safe_load(value)))
    return configs


def main():
    parser = argparse.ArgumentParser(
        description="Validate every rendered OBI ConfigMap in the chart examples against "
        "OBI's JSON schema. The schema is fetched from the OBI release matching the "
        "chart's appVersion, so it can never drift from the image the chart deploys. "
        "YAML scalars are coerced the way OBI's own yaml.v3 unmarshalling coerces them "
        "into string-typed fields, so an unquoted 'enable: true' is accepted exactly as "
        "OBI accepts it."
    )
    parser.add_argument(
        "--schema",
        help="path to a local schema file, bypassing the download (for offline runs)",
    )
    args = parser.parse_args()

    app_version = chart_app_version()
    if not app_version:
        print("could not read appVersion from the chart's Chart.yaml", file=sys.stderr)
        return 1

    if args.schema:
        schema = yaml.safe_load(pathlib.Path(args.schema).read_text())
        print(f"schema: {args.schema}")
    else:
        url = SCHEMA_URL_TEMPLATE.format(version=app_version)
        schema = fetch_schema(url)
        print(f"schema: OBI {app_version}")

    validator = Draft202012Validator(schema)

    configmaps = sorted((CHART_DIR / "examples").glob("*/rendered/configmap.yaml"))
    if not configmaps:
        print("no rendered example ConfigMaps found", file=sys.stderr)
        return 1

    failures = 0
    checked = 0
    for configmap_path in configmaps:
        for key, config in extract_obi_configs(configmap_path):
            checked += 1
            rel = configmap_path.relative_to(REPO_ROOT)
            normalized = coerce_yaml_scalars(config, schema, schema)
            errors = sorted(validator.iter_errors(normalized), key=lambda e: list(e.path))
            if errors:
                failures += 1
                print(f"INVALID {rel} [{key}]")
                for error in errors:
                    loc = "/".join(str(p) for p in error.path) or "(root)"
                    print(f"  {loc}: {error.message}")
            else:
                print(f"OK {rel} [{key}]")

    if checked == 0:
        print("no OBI config found inside the rendered ConfigMaps", file=sys.stderr)
        return 1
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
