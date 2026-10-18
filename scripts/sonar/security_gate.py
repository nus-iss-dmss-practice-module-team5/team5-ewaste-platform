#!/usr/bin/env python3
"""Fail CI on open Blocker or Critical SonarQube vulnerabilities (EWCSB-214).

Policy EWCSB-241 section 4: these block; hotspots and SonarQube's own quality
gate stay in the report as residual risk. Reads issues.json saved by the CI job
and exits 1 when a blocking issue is open, or when the export is missing.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from render_report import location

# Standard-mode severities, and their Multi-Quality-Rule-mode equivalents.
BLOCKING = {"BLOCKER", "CRITICAL", "HIGH"}


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


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--issues", required=True)
    parser.add_argument("--project-key", required=True)
    args = parser.parse_args(argv)

    path = Path(args.issues)
    try:
        issues = json.loads(path.read_text(encoding="utf-8"))["issues"]
    except (OSError, ValueError, KeyError) as error:
        print(f"::error::SonarQube issues export is unreadable ({error}); refusing.")
        return 1

    found = blocking_issues(issues)
    for issue in found:
        print(f"::error::SonarQube {issue.get('rule', '?')} at {location(issue, args.project_key)}: "
              f"{issue.get('message', '')}")
    print(f"SonarQube security gate: {len(found)} blocking vulnerability(ies) of {len(issues)} open issues.")
    return 1 if found else 0


if __name__ == "__main__":
    raise SystemExit(main())
