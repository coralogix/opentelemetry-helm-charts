#!/usr/bin/env python3
"""Strict otelcol-contrib validation of the databaseMonitoring golden render (DBM EC-09).

validate-configs.sh ignores the whole validator output as soon as one ignore pattern matches,
so an unknown DBM component type would hide every other error. Here only the DBM components
that otelcol-contrib does not ship are removed (processors dbm, dbmkey and dbmlogparser, connector dbentity,
and the entity pipeline that only exists for the connector); everything else, including the
postgresql receivers, filelog, filter, resource, batch and coralogix exporter, must validate
with no ignored errors.

Usage: validate_database_monitoring.py <rendered configmap yaml> <otelcol-contrib binary>
"""
import os
import re
import subprocess
import sys
import tempfile

import yaml

DBM_PROCESSORS = ("dbm", "dbmkey", "dbmlogparser")
DBM_CONNECTORS = ("dbentity",)
DBM_ONLY_PIPELINES = ("logs/dbm_entity",)


def strip_dbm_components(cfg: dict) -> dict:
    for p in DBM_PROCESSORS:
        cfg.get("processors", {}).pop(p, None)
    for c in DBM_CONNECTORS:
        cfg.get("connectors", {}).pop(c, None)
    if not cfg.get("connectors"):
        cfg.pop("connectors", None)
    pipelines = cfg["service"]["pipelines"]
    for name in DBM_ONLY_PIPELINES:
        pipelines.pop(name, None)
    for name, pl in pipelines.items():
        pl["processors"] = [p for p in pl.get("processors", []) if p not in DBM_PROCESSORS]
        pl["exporters"] = [e for e in pl.get("exporters", []) if e not in DBM_CONNECTORS]
        if not pl["exporters"]:
            cfg.setdefault("exporters", {}).setdefault("debug", {})
            pl["exporters"] = ["debug"]
    if not any("nop" in pl.get("exporters", []) for pl in pipelines.values()):
        cfg.get("exporters", {}).pop("nop", None)
    return cfg


def main() -> int:
    configmap_path, binary = sys.argv[1], sys.argv[2]
    with open(configmap_path, encoding="utf-8") as f:
        configmap = yaml.safe_load(f)
    relay = configmap["data"]["relay"]
    cfg = strip_dbm_components(yaml.safe_load(relay))
    # Every ${env:NAME} gets a non-empty placeholder value so the validator checks the
    # configuration itself; no real credential is involved.
    env = dict(os.environ)
    for name in sorted(set(re.findall(r"\$\{env:([A-Za-z_][A-Za-z0-9_]*)\}", relay))):
        env[name] = "127.0.0.1" if name == "MY_POD_IP" else "validate-placeholder"
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as tmp:
        yaml.safe_dump(cfg, tmp, sort_keys=True)
        path = tmp.name
    print(f"validating {configmap_path} without {DBM_PROCESSORS + DBM_CONNECTORS}")
    proc = subprocess.run([binary, "validate", f"--config={path}"], env=env,
                          capture_output=True, text=True, check=False)
    sys.stdout.write(proc.stdout)
    sys.stderr.write(proc.stderr)
    if proc.returncode != 0:
        print("FAIL: database-monitoring example is not valid for otelcol-contrib")
        return 1
    print("PASS: database-monitoring example is valid (DBM-only components removed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
