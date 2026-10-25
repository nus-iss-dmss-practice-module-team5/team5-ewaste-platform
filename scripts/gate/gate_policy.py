#!/usr/bin/env python3
"""Release security gate policy (EWCSB-214, policy EWCSB-241).

Subcommands
  build     Gate 2: decide whether one built image may be signed. Reads the
            Syft SBOM, the Grype report produced against that SBOM and
            security/dispositions.yaml.
  deploy    Gate 3: decide whether a digest may be deployed. Needs the result
            of `cosign verify` and the verified gate-decision attestation.
  validate  Check security/dispositions.yaml against the section 5 rules.

Every build and deploy run writes a gate decision record (policy section 6)
and exits 0 for PASS or 1 for REFUSED. Any error while deciding - a missing or
unreadable report, an invalid disposition file, a crash - is a refusal: the
gate fails closed (principle 1).
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys
import traceback
from pathlib import Path

POLICY = "EWCSB-241"
RECORD_VERSION = 1
GATE_PREDICATE_TYPE = (
    "https://github.com/nus-iss-dmss-practice-module-team5/team5-ewaste-platform/gate-decision/v1"
)
DIGEST_REF = re.compile(r"^[a-z0-9.\-]+(:[0-9]+)?/[a-z0-9._/\-]+@sha256:[0-9a-f]{64}$")
MAX_DISPOSITION_DAYS = 14
RELEASE_DEADLINE = dt.date(2026, 10, 24)
DISPOSITION_REASONS = {"no fix available", "not reachable", "compensating control"}
REQUIRED_DISPOSITION_FIELDS = (
    "id", "scope", "severity", "reason", "justification", "owner",
    "approved_by", "approved_on", "expires_on", "ticket",
)


class PolicyError(Exception):
    """The inputs cannot be trusted; the gate refuses."""


# ---------------------------------------------------------------------------
# Dispositions (policy section 5)

def load_yaml(path: Path):
    try:
        import yaml  # PyYAML ships with Ubuntu runners (cloud-init depends on it).
    except ImportError as error:
        raise PolicyError("PyYAML is not installed, so dispositions cannot be read") from error
    try:
        return yaml.safe_load(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise PolicyError(f"{path} does not exist") from error
    except yaml.YAMLError as error:
        raise PolicyError(f"{path} is not valid YAML: {error}") from error


def parse_date(value, field: str, entry_id: str) -> dt.date:
    if isinstance(value, dt.date):
        return value
    try:
        return dt.date.fromisoformat(str(value))
    except ValueError as error:
        raise PolicyError(f"disposition {entry_id}: {field} must be a YYYY-MM-DD date") from error


def load_dispositions(path: Path) -> tuple[list[dict], str]:
    """Returns the entries and the security lead; raises PolicyError when the file is invalid."""
    data = load_yaml(path) or {}
    if not isinstance(data, dict):
        raise PolicyError(f"{path} must be a mapping with security_lead and dispositions")
    lead = data.get("security_lead")
    if not isinstance(lead, str) or not lead.strip():
        raise PolicyError(f"{path} must name the security_lead")
    entries = data.get("dispositions") or []
    if not isinstance(entries, list):
        raise PolicyError(f"{path}: dispositions must be a list")
    seen = set()
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            raise PolicyError(f"disposition #{index + 1} is not a mapping")
        entry_id = str(entry.get("id", f"#{index + 1}"))
        missing = [field for field in REQUIRED_DISPOSITION_FIELDS if not entry.get(field)]
        if missing:
            raise PolicyError(f"disposition {entry_id} is missing {', '.join(missing)}")
        key = (entry_id, str(entry["scope"]))
        if key in seen:
            raise PolicyError(f"disposition {entry_id} for {entry['scope']} is listed twice")
        seen.add(key)
    return entries, lead.strip()


def disposition_problem(entry: dict, lead: str, today: dt.date) -> str | None:
    """Why this disposition cannot be used, or None when it is valid."""
    entry_id = str(entry["id"])
    if str(entry["severity"]).strip().lower() == "critical":
        return "a Critical finding cannot be dispositioned"
    if str(entry["severity"]).strip().lower() != "high":
        return f"severity must be High, not {entry['severity']}"
    reason = str(entry["reason"]).strip().lower()
    if reason not in DISPOSITION_REASONS:
        return f"reason must be one of: {', '.join(sorted(DISPOSITION_REASONS))}"
    if reason == "compensating control" and not entry.get("compensating_control"):
        return "compensating_control is required when the reason is a compensating control"
    approvers = entry["approved_by"]
    approvers = [approvers] if isinstance(approvers, str) else list(approvers)
    approvers = [str(a).strip() for a in approvers if str(a).strip()]
    owner = str(entry["owner"]).strip()
    if owner.lower() in {a.lower() for a in approvers}:
        return "approved by its own owner (no self-approval)"
    if lead.lower() not in {a.lower() for a in approvers}:
        return f"not approved by the security lead ({lead})"
    if len(approvers) < 2:
        return "needs the security lead plus one technical approver"
    approved_on = parse_date(entry["approved_on"], "approved_on", entry_id)
    expires_on = parse_date(entry["expires_on"], "expires_on", entry_id)
    if expires_on < approved_on:
        return "expires before it was approved"
    if (expires_on - approved_on).days > MAX_DISPOSITION_DAYS:
        return f"expiry is more than {MAX_DISPOSITION_DAYS} days after approval"
    if expires_on > RELEASE_DEADLINE:
        return f"expiry is after {RELEASE_DEADLINE.isoformat()}"
    if today > expires_on:
        return f"expired on {expires_on.isoformat()}"
    if approved_on > today:
        return f"approval date {approved_on.isoformat()} is in the future"
    return None


def scope_matches(scope: str, image: str, digest: str) -> bool:
    """Scope is an image name (any digest) or image@sha256:... (one digest)."""
    scope = scope.strip()
    if "@" in scope:
        name, _, scoped_digest = scope.partition("@")
        return name == image and scoped_digest == digest.partition("@")[2]
    return scope == image


# ---------------------------------------------------------------------------
# Gate 2: build and sign

def finding_ids(match: dict) -> set[str]:
    vulnerability = match.get("vulnerability", {})
    ids = {vulnerability.get("id", "")}
    ids.update(r.get("id", "") for r in match.get("relatedVulnerabilities", []))
    return {i for i in ids if i}


def read_grype(path: Path) -> list[dict]:
    if not path.is_file() or path.stat().st_size == 0:
        raise PolicyError("Grype produced no report")
    try:
        report = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise PolicyError(f"Grype report is not valid JSON: {error}") from error
    matches = report.get("matches")
    if not isinstance(matches, list):
        raise PolicyError("Grype report has no matches list")
    return matches


def check_sbom(path: Path) -> int:
    if not path.is_file() or path.stat().st_size == 0:
        raise PolicyError("SBOM is missing or empty")
    try:
        sbom = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise PolicyError(f"SBOM is not valid JSON: {error}") from error
    packages = sbom.get("packages")
    if not isinstance(packages, list) or not packages:
        raise PolicyError("SBOM lists no packages")
    return len(packages)


def evaluate_build(image: str, digest: str, sbom_path: Path, grype_path: Path,
                   dispositions_path: Path, today: dt.date) -> dict:
    """Returns {decision, reasons, checks, dispositions_applied, findings}."""
    checks, reasons, applied = [], [], []
    findings = {"critical": [], "high": [], "medium": 0, "low": 0, "other": 0}

    if not DIGEST_REF.match(digest):
        raise PolicyError(f"{digest!r} is not an immutable registry@sha256 reference")

    package_count = check_sbom(sbom_path)
    checks.append({"check": "sbom", "result": "PASS", "detail": f"{package_count} packages"})

    matches = read_grype(grype_path)
    entries, lead = load_dispositions(dispositions_path)

    for match in matches:
        severity = str(match.get("vulnerability", {}).get("severity", "")).lower()
        ids = finding_ids(match)
        artifact = match.get("artifact", {})
        label = f"{sorted(ids)[0] if ids else '?'} in {artifact.get('name', '?')} {artifact.get('version', '')}".strip()
        if severity == "critical":
            findings["critical"].append(label)
            scoped = [e for e in entries if str(e["id"]) in ids and scope_matches(str(e["scope"]), image, digest)]
            note = " (a disposition exists but Critical cannot be dispositioned)" if scoped else ""
            reasons.append(f"Critical finding {label}{note}")
        elif severity == "high":
            findings["high"].append(label)
            candidates = [e for e in entries if str(e["id"]) in ids and scope_matches(str(e["scope"]), image, digest)]
            if not candidates:
                reasons.append(f"High finding {label} has no disposition")
                continue
            problems = [(e, disposition_problem(e, lead, today)) for e in candidates]
            valid = [e for e, problem in problems if problem is None]
            if valid:
                applied.append(str(valid[0]["id"]))
            else:
                detail = "; ".join(problem for _, problem in problems)
                reasons.append(f"High finding {label} has no valid disposition: {detail}")
        elif severity == "medium":
            findings["medium"] += 1
        elif severity in ("low", "negligible"):
            findings["low"] += 1
        else:
            findings["other"] += 1

    checks.append({
        "check": "grype",
        "result": "REFUSED" if reasons else "PASS",
        "detail": (f"{len(findings['critical'])} critical, {len(findings['high'])} high, "
                   f"{findings['medium']} medium, {findings['low']} low"),
    })
    return {
        "decision": "REFUSED" if reasons else "PASS",
        "reasons": reasons,
        "checks": checks,
        "dispositions_applied": sorted(set(applied)),
        "findings": findings,
    }


# ---------------------------------------------------------------------------
# Gate 3: deploy (and rollback)

def attested_decisions(path: Path) -> list[dict]:
    """Decodes `cosign verify-attestation --output json` (one envelope per line)."""
    import base64

    if not path.is_file() or path.stat().st_size == 0:
        return []
    statements = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            envelope = json.loads(line)
            statement = json.loads(base64.b64decode(envelope["payload"]))
        except (ValueError, KeyError, TypeError) as error:
            raise PolicyError(f"attestation output is not readable: {error}") from error
        statements.append(statement)
    return statements


def evaluate_deploy(digest: str, signature_ok: bool, attestation_path: Path) -> dict:
    checks, reasons = [], []
    if not DIGEST_REF.match(digest):
        raise PolicyError(f"{digest!r} is not an immutable registry@sha256 reference (deploy by digest only)")
    sha = digest.split("@", 1)[1]

    checks.append({"check": "cosign-signature", "result": "PASS" if signature_ok else "REFUSED"})
    if not signature_ok:
        reasons.append("signature missing, invalid or not made with the team key")

    passing = None
    for statement in attested_decisions(attestation_path):
        if statement.get("predicateType") != GATE_PREDICATE_TYPE:
            continue
        subjects = {f"sha256:{s.get('digest', {}).get('sha256', '')}" for s in statement.get("subject", [])}
        record = statement.get("predicate", {})
        if sha in subjects and record.get("decision") == "PASS" and record.get("stage") == "build-sign" \
                and record.get("image", {}).get("digest", "").endswith(sha):
            passing = record
            break
    checks.append({"check": "gate2-record", "result": "PASS" if passing else "REFUSED",
                   "detail": passing.get("run_url", "") if passing else ""})
    if not passing:
        reasons.append("no passing Gate 2 decision is attested for this digest")
    return {"decision": "REFUSED" if reasons else "PASS", "reasons": reasons, "checks": checks,
            "dispositions_applied": passing.get("dispositions_applied", []) if passing else []}


# ---------------------------------------------------------------------------
# Records and CLI

def write_record(path: Path, stage: str, image: str, digest: str, result: dict, args) -> dict:
    record = {
        "record_version": RECORD_VERSION,
        "policy": POLICY,
        "stage": stage,
        "decision": result["decision"],
        "reasons": result.get("reasons", []),
        "image": {"name": image, "digest": digest},
        "commit": args.commit,
        "environment": args.environment,
        "run_url": args.run_url,
        "checks": result.get("checks", []),
        "tools": dict(item.split("=", 1) for item in (args.tool or []) if "=" in item),
        "dispositions_applied": result.get("dispositions_applied", []),
        "findings": result.get("findings", {}),
        "reviewer": args.reviewer or "",
        "decided_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    return record


def refused(message: str) -> dict:
    return {"decision": "REFUSED", "reasons": [message], "checks": []}


def run_build(args) -> int:
    today = dt.date.fromisoformat(args.today) if args.today else dt.datetime.now(dt.timezone.utc).date()
    try:
        result = evaluate_build(args.image, args.digest, Path(args.sbom), Path(args.grype),
                                Path(args.dispositions), today)
    except PolicyError as error:
        result = refused(str(error))
    except Exception:  # noqa: BLE001 - any crash must refuse, never pass
        result = refused("gate evaluation crashed: " + traceback.format_exc(limit=1).strip().splitlines()[-1])
    record = write_record(Path(args.out), "build-sign", args.image, args.digest, result, args)
    return report(record)


def run_deploy(args) -> int:
    try:
        result = evaluate_deploy(args.digest, args.signature_ok == "true", Path(args.attestation))
    except PolicyError as error:
        result = refused(str(error))
    except Exception:  # noqa: BLE001
        result = refused("gate evaluation crashed: " + traceback.format_exc(limit=1).strip().splitlines()[-1])
    record = write_record(Path(args.out), args.stage, args.image, args.digest, result, args)
    return report(record)


def run_validate(args) -> int:
    today = dt.date.fromisoformat(args.today) if args.today else dt.datetime.now(dt.timezone.utc).date()
    try:
        entries, lead = load_dispositions(Path(args.dispositions))
    except PolicyError as error:
        print(f"INVALID: {error}")
        return 1
    problems = [(e["id"], e["scope"], disposition_problem(e, lead, today)) for e in entries]
    for entry_id, scope, problem in problems:
        print(f"{'INVALID' if problem else 'valid  '} {entry_id} ({scope}){': ' + problem if problem else ''}")
    print(f"{len(entries)} disposition(s), security lead {lead}")
    return 1 if any(problem for *_, problem in problems) else 0


def report(record: dict) -> int:
    print(f"Gate {record['stage']} for {record['image']['name']}: {record['decision']}")
    for reason in record["reasons"]:
        print(f"::error::{record['image']['name']}: {reason}")
    return 0 if record["decision"] == "PASS" else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    def common(p):
        p.add_argument("--image", required=True, help="image name, e.g. workflow-api")
        p.add_argument("--digest", required=True, help="registry/repo@sha256:...")
        p.add_argument("--out", required=True, help="where to write gate-decision.json")
        p.add_argument("--commit", default="")
        p.add_argument("--environment", default="")
        p.add_argument("--run-url", default="")
        p.add_argument("--reviewer", default="")
        p.add_argument("--tool", action="append", help="name=version, repeatable")

    build = sub.add_parser("build", help="Gate 2: may this image be signed?")
    common(build)
    build.add_argument("--sbom", required=True)
    build.add_argument("--grype", required=True)
    build.add_argument("--dispositions", default="security/dispositions.yaml")
    build.add_argument("--today", help="override today's date (YYYY-MM-DD), for tests")
    build.set_defaults(func=run_build)

    deploy = sub.add_parser("deploy", help="Gate 3: may this digest be deployed?")
    common(deploy)
    deploy.add_argument("--stage", choices=("deploy", "rollback"), default="deploy")
    deploy.add_argument("--signature-ok", choices=("true", "false"), required=True)
    deploy.add_argument("--attestation", required=True, help="cosign verify-attestation output")
    deploy.set_defaults(func=run_deploy)

    validate = sub.add_parser("validate", help="check security/dispositions.yaml")
    validate.add_argument("--dispositions", default="security/dispositions.yaml")
    validate.add_argument("--today")
    validate.set_defaults(func=run_validate)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
