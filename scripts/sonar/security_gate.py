#!/usr/bin/env python3
"""Fail CI on open Blocker or Critical SonarQube vulnerabilities (EWCSB-214).

Policy EWCSB-241 section 4: these block; hotspots and SonarQube's own quality
gate stay in the report as residual risk. Reads issues.json saved by the CI job
and exits 1 when a blocking issue is open, or when the export is missing.
A reviewed false positive in security/sonar-exceptions.yaml does not block.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from render_report import location

# Standard-mode severities, and their Multi-Quality-Rule-mode equivalents.
BLOCKING = {"BLOCKER", "CRITICAL", "HIGH"}
REQUIRED_EXCEPTION_FIELDS = ("rule", "path", "justification", "approved_by", "approved_on", "ticket")


class ExceptionsError(Exception):
    """The exceptions file cannot be trusted; the gate refuses."""


def blocking_issues(issues: list[dict]) -> list[dict]:
    """Every security impact is checked, not just the issue's top one."""
    found = []
    for issue in issues:
        impacts = issue.get("impacts") or []
        if impacts:
            hit = any(i.get("softwareQuality") == "SECURITY" and i.get("severity") in BLOCKING for i in impacts)
        else:
            hit = issue.get("type") == "VULNERABILITY" and issue.get("severity") in BLOCKING
        if hit:
            found.append(issue)
    return found


def load_exceptions(path: Path | None) -> list[dict]:
    if path is None:
        return []
    try:
        import yaml  # PyYAML ships with Ubuntu runners (cloud-init depends on it).
    except ImportError as error:
        raise ExceptionsError("PyYAML is not installed") from error
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except OSError as error:
        raise ExceptionsError(f"{path} cannot be read: {error}") from error
    except yaml.YAMLError as error:
        raise ExceptionsError(f"{path} is not valid YAML: {error}") from error
    if not isinstance(data, dict):
        raise ExceptionsError(f"{path} must be a mapping with security_lead and exceptions")
    lead = data.get("security_lead")
    entries = data.get("exceptions") or []
    if not isinstance(lead, str) or not lead.strip() or not isinstance(entries, list):
        raise ExceptionsError(f"{path} must name security_lead and list exceptions")
    for entry in entries:
        missing = [f for f in REQUIRED_EXCEPTION_FIELDS if not entry.get(f)] if isinstance(entry, dict) else ["all"]
        if missing:
            raise ExceptionsError(f"{path}: an exception is missing {', '.join(missing)}")
        approvers = set(entry["approved_by"]) if isinstance(entry["approved_by"], list) else set()
        if lead not in approvers or len(approvers) < 2:
            raise ExceptionsError(f"{path}: {entry['rule']} on {entry['path']} needs the security lead "
                                  "plus one technical approver")
    return entries


def is_excepted(issue: dict, exceptions: list[dict], project_key: str) -> bool:
    path = location({"component": issue.get("component", "")}, project_key)
    return any(e["rule"] == issue.get("rule") and e["path"] == path for e in exceptions)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--issues", required=True)
    parser.add_argument("--project-key", required=True)
    parser.add_argument("--exceptions", help="security/sonar-exceptions.yaml")
    args = parser.parse_args(argv)

    try:
        issues = json.loads(Path(args.issues).read_text(encoding="utf-8"))["issues"]
    except (OSError, ValueError, KeyError) as error:
        print(f"::error::SonarQube issues export is unreadable ({error}); refusing.")
        return 1
    try:
        exceptions = load_exceptions(Path(args.exceptions) if args.exceptions else None)
    except ExceptionsError as error:
        print(f"::error::{error}; refusing.")
        return 1

    found = blocking_issues(issues)
    blocked = 0
    for issue in found:
        where = location(issue, args.project_key)
        if is_excepted(issue, exceptions, args.project_key):
            print(f"Accepted false positive {issue.get('rule', '?')} at {where} (security/sonar-exceptions.yaml)")
            continue
        blocked += 1
        print(f"::error::SonarQube {issue.get('rule', '?')} at {where}: {issue.get('message', '')}")
    print(f"SonarQube security gate: {blocked} blocking vulnerability(ies), {len(found) - blocked} accepted "
          f"false positive(s), of {len(issues)} open issues.")
    return 1 if blocked else 0


if __name__ == "__main__":
    raise SystemExit(main())
