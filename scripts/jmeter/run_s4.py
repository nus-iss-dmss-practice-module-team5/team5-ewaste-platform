#!/usr/bin/env python3
"""Headless runner for just the appended S4 groups; no deployed defaults."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from urllib.parse import urlsplit
import xml.etree.ElementTree as E
from report_s4 import report

ROOT = Path(__file__).resolve().parents[2]


def properties(path):
    # Public scenario settings deliberately use only simple key=value syntax.
    result = {}
    for line in path.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith(("#", "!")):
            continue
        key, value = line.split("=", 1)
        result[key.strip()] = value.strip()
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--host", required=True, help="Explicit http(s) API base URL")
    p.add_argument(
        "--credentials",
        required=True,
        type=Path,
        help="Private JMeter .properties file",
    )
    p.add_argument(
        "--settings",
        type=Path,
        default=ROOT / "artifacts/jmeter/data/s4-functional.properties",
    )
    p.add_argument("--profile", choices=["all", "claim", "handoff", "burst", "custody"])
    p.add_argument("--output", type=Path, help="New, non-existing output directory")
    p.add_argument("--jmeter", default=os.environ.get("JMETER_BIN", "jmeter"))
    p.add_argument(
        "--mysql-config",
        type=Path,
        help="Optional MySQL defaults-extra-file for read-only reconciliation",
    )
    p.add_argument("--database", default="ewastedb")
    a = p.parse_args()
    target = urlsplit(a.host)
    if (
        target.scheme not in ["http", "https"]
        or not target.hostname
        or target.username
        or target.password
        or target.query
        or target.fragment
        or target.path not in ["", "/"]
        or re.search(r"\s", a.host)
    ):
        p.error("--host must be a plain API origin without credentials, query or path")
    if not a.credentials.is_file() or not a.settings.is_file():
        p.error("Credentials/settings file missing")
    exe = shutil.which(a.jmeter)
    if not exe:
        p.error("JMeter not found; set JMETER_BIN to Apache JMeter 5.6.3/bin/jmeter")
    cfg = properties(ROOT / "artifacts/jmeter/data/s4-functional.properties")
    custom = properties(a.settings)
    if set(custom) - set(cfg):
        p.error(
            "Settings may contain only keys from s4-functional.properties; put credentials in the private file"
        )
    cfg.update(custom)
    if a.profile:
        cfg["s4_profile"] = a.profile
    if cfg["s4_profile"] not in ["all", "claim", "handoff", "burst", "custody"]:
        p.error("Invalid s4_profile")
    try:
        for key, value in cfg.items():
            if key not in ["s4_profile", "s4_zone"]:
                assert value.isdigit(), key
                assert int(value) > 0 or key in [
                    "auth_pause_ms",
                    "s4_custody_pause_ms",
                    "s4_ramp_seconds",
                ], key
        for key in [
            "s4_claim_threads",
            "s4_handoff_threads",
            "s4_burst_threads",
            "s4_custody_threads",
        ]:
            assert 1 <= int(cfg[key]) <= 100, key
        assert (
            int(cfg["s4_claim_threads"]) >= 2 and int(cfg["s4_claim_threads"]) % 2 == 0
        )
        assert int(cfg["s4_handoff_threads"]) >= 2
        assert int(cfg["s4_burst_threads"]) % 4 == 0
        assert int(cfg["s4_barrier_ms"]) > 1000 * int(cfg["s4_ramp_seconds"])
    except AssertionError:
        p.error(
            "Invalid counts/timers: claim even >=2, handoff >=2, burst multiple of 4, <=100 threads, barrier longer than ramp"
        )
    out = (
        a.output
        or ROOT
        / "artifacts/jmeter/results"
        / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    ).resolve()
    out.mkdir(parents=True, exist_ok=False)
    os.chmod(out, 0o700)
    plan = ROOT / "artifacts/jmeter/EWaste_API_Test_Plan.jmx"
    data = ROOT / "artifacts/jmeter/data/s4-golden.json"
    tree = E.parse(plan)
    for n in tree.getroot().iter():
        if n.tag in [
            "ThreadGroup",
            "SetupThreadGroup",
            "PostThreadGroup",
            "ResultCollector",
        ]:
            n.set(
                "enabled",
                "true" if n.get("testname", "").startswith("S4 ") else "false",
            )
    for key in ["TestPlan.serialize_threadgroups", "TestPlan.tearDown_on_shutdown"]:
        plan_node = tree.find("hashTree/TestPlan")
        flag = plan_node.find(f'boolProp[@name="{key}"]')
        if flag is None:
            flag = E.SubElement(plan_node, "boolProp", name=key)
        flag.text = "true"
    # Disable expensive GUI listeners and never retain credentials in the run directory.
    tree.write(out / "selected-plan.jmx", encoding="UTF-8", xml_declaration=True)
    sha = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True
    ).stdout.strip()
    (out / "run.json").write_text(
        json.dumps(
            dict(
                host=a.host.rstrip("/"),
                configuration=cfg,
                commit=sha,
                plan_sha256=hashlib.sha256(plan.read_bytes()).hexdigest(),
                data_sha256=hashlib.sha256(data.read_bytes()).hexdigest(),
                scope="functional-concurrency",
            ),
            indent=2,
        )
        + "\n"
    )
    saves = dict(
        output_format="csv",
        print_field_names="true",
        timestamp_format="ms",
        time="true",
        successful="true",
        label="true",
        response_code="true",
        response_message="true",
        thread_name="true",
        latency="true",
        connect_time="true",
        assertion_results_failure_message="true",
        response_data="false",
        response_data_on_error="false",
        samplerData="false",
        requestHeaders="false",
        responseHeaders="false",
        url="false",
    )
    cmd = [
        exe,
        "-n",
        "-t",
        str(out / "selected-plan.jmx"),
        "-q",
        str(a.credentials.resolve()),
        "-l",
        str(out / "results.jtl"),
        "-j",
        str(out / "jmeter.log"),
    ]
    cmd += ["-J" + k + "=" + v for k, v in cfg.items()]
    cmd += [
        "-Jrun_s4=true",
        "-Jhost=" + a.host.rstrip("/"),
        "-Js4_output=" + str(out),
        "-Js4_data_file=" + str(data),
        "-Jsample_variables=run_id,batch_id,correlation_id",
        "-Jsampleresult.timestamp.start=true",
        "-Jjmeterengine.force.system.exit=true",
    ]
    cmd += ["-Jjmeter.save.saveservice." + k + "=" + v for k, v in saves.items()]
    print("Running S4 " + cfg["s4_profile"] + "; results: " + str(out), flush=True)
    proc = subprocess.run(cmd, cwd=ROOT, check=False)
    try:
        status = report(out)
    except (OSError, ValueError, KeyError) as exc:
        print(
            "Run incomplete; inspect local jmeter.log and results.jtl: " + str(exc),
            file=sys.stderr,
        )
        return 1
    if a.mysql_config:
        if not a.mysql_config.is_file() or not shutil.which("mysql"):
            p.error("Optional MySQL client/config missing")
        # Query literals are checked by report_s4; SQL is SELECT-only in a read transaction.
        with (out / "reconciliation.sql").open() as sql, (out / "sql-results.tsv").open(
            "w"
        ) as log:
            db = subprocess.run(
                [
                    "mysql",
                    "--defaults-extra-file=" + str(a.mysql_config.resolve()),
                    "--batch",
                    "--raw",
                    a.database,
                ],
                stdin=sql,
                stdout=log,
                stderr=subprocess.PIPE,
                text=True,
            )
        lines = (out / "sql-results.tsv").read_text().splitlines()
        values = [
            line.split("\t") for line in lines if not line.startswith("check_name\t")
        ]
        sql_ok = (
            db.returncode == 0
            and bool(values)
            and all(len(v) == 3 and v[2] == "0" for v in values)
        )
        result = json.loads((out / "summary.json").read_text())
        result["sql_integrity"] = "PASS" if sql_ok else "FAIL"
        (out / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
        with (out / "summary.md").open("a") as log:
            log.write(
                "\nExecuted MySQL reconciliation: **"
                + result["sql_integrity"]
                + "**. See sql-results.tsv.\n"
            )
        status = status or int(not sql_ok)
        # Do not print DB client stderr: may contain connection details.
    print("Functional result and SQL status: " + str(out / "summary.json"))
    return status or int(proc.returncode != 0)


if __name__ == "__main__":
    raise SystemExit(main())
