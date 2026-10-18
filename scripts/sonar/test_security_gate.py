"""Tests for security_gate.py. Run: python3 -m unittest discover -s scripts/sonar"""

import json
import tempfile
import unittest
from pathlib import Path

import security_gate as sg

KEY = "team5-ewaste-platform"


def issue(**fields):
    return {"rule": "go:S2068", "component": f"{KEY}:src/backend/a.go", "line": 3, "message": "m", **fields}


class SecurityGateTests(unittest.TestCase):
    def run_gate(self, issues):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "issues.json"
            path.write_text(json.dumps({"issues": issues}))
            return sg.main(["--issues", str(path), "--project-key", KEY])

    def test_high_security_impact_blocks_even_when_not_the_top_impact(self):
        found = sg.blocking_issues([issue(impacts=[
            {"softwareQuality": "RELIABILITY", "severity": "BLOCKER"},
            {"softwareQuality": "SECURITY", "severity": "HIGH"}])])
        self.assertEqual(len(found), 1)

    def test_classic_critical_vulnerability_blocks(self):
        self.assertEqual(self.run_gate([issue(type="VULNERABILITY", severity="CRITICAL")]), 1)

    def test_lower_severities_and_other_qualities_pass(self):
        self.assertEqual(self.run_gate([
            issue(impacts=[{"softwareQuality": "SECURITY", "severity": "MEDIUM"}]),
            issue(impacts=[{"softwareQuality": "RELIABILITY", "severity": "BLOCKER"}]),
            issue(type="VULNERABILITY", severity="MAJOR"),
            issue(type="BUG", severity="BLOCKER"),
        ]), 0)

    def test_missing_export_refuses(self):
        self.assertEqual(sg.main(["--issues", "/nonexistent/issues.json", "--project-key", KEY]), 1)


if __name__ == "__main__":
    unittest.main()
