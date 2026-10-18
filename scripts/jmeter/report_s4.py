#!/usr/bin/env python3
"""Summarise native JMeter timings and generate read-only MySQL integrity checks."""

import argparse
import csv
import json
import math
import re
from collections import Counter, defaultdict
from pathlib import Path


def literal(value):
    # Only generated UUIDs/keys, fixed enums and decimal strings enter SQL.
    value = str(value)
    if not re.fullmatch(r"[A-Za-z0-9_.:-]+", value):
        raise ValueError("Unsafe SQL identity")
    return "'" + value + "'"


def reconciliation(manifest, requests):
    queries = []

    def test(name, batch, expression):
        queries.append(
            f"SELECT {literal(name)} AS check_name, {literal(batch)} AS batch_id, ({expression}) AS violations"
        )

    def count(name, batch, table, predicate="", expected=1):
        test(
            name,
            batch,
            f"(SELECT COUNT(*) FROM {table} WHERE batch_id={literal(batch)}{predicate}) <> {expected}",
        )

    for f in manifest["fixtures"]:
        if not f.get("id"):
            continue
        b = f["id"]
        stage = f["scenario"]
        expected = (
            "APPROVED"
            if stage == "claim-race"
            else "COLLECTED" if stage == "handoff-race" else "COMPLETED"
        )
        test(
            "batch_state",
            b,
            f"(SELECT COUNT(*) FROM ewaste_batches WHERE id={literal(b)} AND status={literal(expected)} AND version={int(f.get('completed_version', f['version']))}) <> 1",
        )
        count("one_claim", b, "batch_claims")
        count("accepted_claim", b, "batch_claims", " AND claim_status='ACCEPTED'")
        count("one_reservation", b, "capacity_reservations")
        count(
            "claim_command",
            b,
            "command_idempotency",
            " AND command_name='ClaimOpportunity' AND state='COMPLETED'",
        )
        count(
            "claim_audit", b, "batch_audit_events", " AND event_type='ClaimConfirmed'"
        )
        count("claim_outbox", b, "event_outbox", " AND event_type='ClaimConfirmed'")
        if stage == "claim-race":
            continue
        count(
            "one_assignment",
            b,
            "batch_assignments",
            " AND assignment_status='COMPLETED'",
        )
        count("one_handoff", b, "batch_handoffs", " AND pickup_status='COLLECTED'")
        count(
            "handoff_command",
            b,
            "command_idempotency",
            " AND command_name='RecordHandoff' AND state='COMPLETED'",
        )
        count(
            "handoff_audit",
            b,
            "batch_audit_events",
            " AND event_type='CollectionCompleted'",
        )
        count(
            "handoff_outbox", b, "event_outbox", " AND event_type='CollectionCompleted'"
        )
        if stage == "handoff-race":
            continue
        for name, table in [
            ("receipt", "batch_receipts"),
            ("treatment", "batch_treatments"),
            ("result", "batch_impact_metrics"),
        ]:
            count("one_" + name, b, table)
        for command, audit, event in [
            ("VerifyReceipt", "ReceiptVerified", "ReceiptVerified"),
            ("RecordTreatment", "TreatmentRecorded", "RecyclingCompleted"),
            ("AcknowledgeAnalyticsResult", "AnalyticsCompleted", "RequestCompleted"),
        ]:
            count(
                command + "_command",
                b,
                "command_idempotency",
                f" AND command_name={literal(command)} AND state='COMPLETED'",
            )
            count(
                audit + "_audit",
                b,
                "batch_audit_events",
                f" AND event_type={literal(audit)}",
            )
            count(
                event + "_outbox",
                b,
                "event_outbox",
                f" AND event_type={literal(event)} AND partition_key={literal(b)}",
            )
        if not all(f.get(k) for k in ["source_event", "receipt", "treatment"]):
            continue
        g = f["golden"]
        clauses = [
            f"source_event_id={literal(f['source_event'])}",
            f"receipt_id={literal(f['receipt'])}",
            f"treatment_id={literal(f['treatment'])}",
            "rule_version='d3-v1'",
            f"data_quality={literal(g['quality'])}",
            f"received_weight_kg={literal(g['receipt']['actual_weight_kg'])}",
        ]
        clauses += [
            f"{k} <=> {'NULL' if v is None else literal(v)}"
            for k, v in g["metrics"].items()
        ]
        count(
            "golden_result",
            b,
            "batch_impact_metrics",
            " AND " + " AND ".join("(" + c + ")" for c in clauses),
        )
    # Exclude changed-payload reuse of a successful key: that command must exist.
    rejected = [
        r
        for r in requests
        if r["label"].startswith("NEG_RECEIPT_")
        or (r["label"] in ["FCFS_CLAIM", "RACE_HANDOFF"] and r["http"] == "409")
    ]
    for r in rejected:
        if r["label"] != "NEG_RECEIPT_CHANGED_KEY_PAYLOAD":
            test(
                "rejected_key_has_no_command",
                r["batch_id"],
                f"(SELECT COUNT(*) FROM command_idempotency WHERE idempotency_key={literal(r['key'])})",
            )
        for table in ["batch_audit_events", "event_outbox"]:
            test(
                "rejected_request_no_" + table,
                r["batch_id"],
                f"(SELECT COUNT(*) FROM {table} WHERE correlation_id={literal(r['correlation_id'])})",
            )
    return (
        "-- Read-only checks for this generated run. Every violations value must be 0.\n-- Run on the SAME database used by the API; retain output as sql-results.tsv.\nSTART TRANSACTION READ ONLY;\n"
        + ";\n".join(queries)
        + ";\nCOMMIT;\n"
    )


def report(output):
    output = Path(output)
    manifests = list(output.glob("s4-*/manifest.json"))
    errors = []
    if len(manifests) != 1:
        raise ValueError(
            "Expected one completed evidence manifest; inspect jmeter.log and results.jtl"
        )
    evidence = manifests[0].parent
    m = json.loads(manifests[0].read_text())
    rows = list(csv.DictReader((output / "results.jtl").open()))
    requests = [
        json.loads(line)
        for line in (evidence / "requests.jsonl").read_text().splitlines()
    ]
    if not rows or m["failed"]:
        errors.append("Missing samples or failed JMX assertion")
    failed = [r for r in rows if r["success"].lower() != "true"]
    if failed:
        errors.append(
            f"{len(failed)} failed JMeter samples; inspect assertion failure messages in results.jtl"
        )
    counts = Counter(r["label"] for r in requests)
    profile = m["profile"]
    cfg = json.loads((output / "run.json").read_text())["configuration"]
    for kind, label in [("claim", "FCFS_CLAIM"), ("handoff", "RACE_HANDOFF")]:
        if profile in ["all", kind]:
            race = m["races"].get(kind, [])
            n = int(cfg["s4_" + kind + "_threads"])
            if (
                len(race) != n
                or sum(r["http"] == "200" for r in race) != 1
                or sum(r["http"] == "409" for r in race) != n - 1
            ):
                errors.append(
                    label + ": incomplete race or wrong winner/conflict count"
                )
    if profile in ["all", "burst", "custody"]:
        n = int(cfg["s4_burst_threads"])
        for label in [
            "TX_CLAIM",
            "TX_ASSIGN",
            "TX_HANDOFF",
            "TX_RECEIPT",
            "TX_TREATMENT",
            "REPLAY_HANDOFF",
            "REPLAY_RECEIPT",
            "REPLAY_TREATMENT",
        ]:
            if counts[label] != n:
                errors.append(label + ": expected one sample per independent fixture")
        if sum(f.get("completed", False) for f in m["fixtures"]) != n:
            errors.append("Not all processing fixtures reached COMPLETED")
    if profile in ["all", "custody"]:
        n = int(cfg["s4_custody_threads"]) * int(cfg["s4_custody_loops"])
        for label, multiple in [
            ("STD_TIMELINE", 2),
            ("STD_ANOMALIES", 1),
            ("STD_IMPACT", 1),
        ]:
            if counts[label] != n * multiple:
                errors.append(label + ": incomplete custody workload")
    groups = defaultdict(list)
    for r in requests:
        if r["label"].startswith(("TX_", "STD_", "FCFS_", "RACE_")):
            groups[r["label"]].append(r)
    summary = []
    for label, values in sorted(groups.items()):
        # Never average percentiles or mix setup/polls/negative checks into a latency metric.
        times = sorted(int(r["elapsed"]) for r in values)
        p95 = times[math.ceil(0.95 * len(times)) - 1]
        limit = (
            2000
            if label.startswith("STD_")
            else 3000 if label.startswith("TX_") else None
        )
        summary.append(
            dict(
                transaction=label,
                count=len(times),
                p95_ms=p95,
                max_ms=max(times),
                unexpected_errors=sum(not r["success"] for r in values),
                threshold_ms=limit,
                threshold_observation=(
                    ("BELOW" if p95 < limit else "AT_OR_ABOVE")
                    if limit
                    else "RACE_SEPARATE"
                ),
            )
        )
    scored = [r for r in requests if r["label"].startswith(("TX_", "STD_"))]
    error_rate = sum(not r["success"] for r in scored) / len(scored) if scored else None
    result = dict(
        functional_status="FAIL" if errors else "PASS",
        errors=errors,
        run_id=m["run_id"],
        measured_transactions=summary,
        unexpected_error_rate=error_rate,
        error_rate_threshold=0.01,
        performance_status="NOT_CERTIFIED: bounded functional bursts, not the sustained D8 campaign",
        event_latency="NOT_MEASURED: completion polls are observations, not event timestamp evidence",
        sql_integrity="NOT_RUN",
    )
    (output / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
    (output / "reconciliation.sql").write_text(reconciliation(m, requests))
    lines = [
        "# S4 JMeter run",
        "",
        f"Functional assertions: **{result['functional_status']}**. SQL reconciliation: **NOT RUN**.",
        "",
        "Native sampler elapsed time. Nearest-rank p95, per named transaction. Intentional conflicts are separate.",
        "",
        "| Transaction | Samples | p95 ms | Max ms | Unexpected errors | Target observation |",
        "|---|---:|---:|---:|---:|---|",
    ]
    lines += [
        f"| {x['transaction']} | {x['count']} | {x['p95_ms']} | {x['max_ms']} | {x['unexpected_errors']} | {x['threshold_observation']} |"
        for x in summary
    ]
    lines += [
        "",
        result["performance_status"],
        "",
        "For durable integrity evidence, execute reconciliation.sql on the API database. Every violations column must be 0. A functional HTTP pass alone does not prove row uniqueness.",
        "",
    ]
    lines += ["- " + e for e in errors]
    (output / "summary.md").write_text("\n".join(lines))
    return 1 if errors else 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("output")
    args = parser.parse_args()
    try:
        raise SystemExit(report(args.output))
    except (ValueError, OSError, KeyError) as exc:
        parser.exit(1, f"Evidence incomplete: {exc}\n")
