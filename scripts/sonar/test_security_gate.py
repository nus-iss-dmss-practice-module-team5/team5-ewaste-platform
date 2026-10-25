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

    def run_with_exceptions(self, issues, exceptions_yaml):
        with tempfile.TemporaryDirectory() as directory:
            issues_path, exceptions_path = Path(directory) / "issues.json", Path(directory) / "exceptions.yaml"
            issues_path.write_text(json.dumps({"issues": issues}))
            exceptions_path.write_text(exceptions_yaml)
            return sg.main(["--issues", str(issues_path), "--project-key", KEY, "--exceptions", str(exceptions_path)])

    EXCEPTION = """security_lead: Shalett Paulson
exceptions:
  - rule: go:S2068
    path: src/backend/a.go
    justification: verified false positive
    approved_by: [{approvers}]
    approved_on: 2026-10-18
    ticket: EWCSB-214
"""
    CRITICAL = dict(type="VULNERABILITY", severity="CRITICAL")

    def test_reviewed_false_positive_does_not_block_but_others_do(self):
        exceptions = self.EXCEPTION.format(approvers="Shalett Paulson, Shubham Kaushik")
        self.assertEqual(self.run_with_exceptions([issue(**self.CRITICAL)], exceptions), 0)
        other_file = issue(component=f"{KEY}:src/backend/b.go", **self.CRITICAL)
        self.assertEqual(self.run_with_exceptions([issue(**self.CRITICAL), other_file], exceptions), 1)

    def test_exception_without_lead_and_second_approver_refuses(self):
        for approvers in ("Shubham Kaushik, Jiamin Wang", "Shalett Paulson"):
            with self.subTest(approvers=approvers):
                exceptions = self.EXCEPTION.format(approvers=approvers)
                self.assertEqual(self.run_with_exceptions([issue(**self.CRITICAL)], exceptions), 1)

    def test_repository_exceptions_file_is_valid(self):
        repo_file = Path(__file__).resolve().parents[2] / "security" / "sonar-exceptions.yaml"
        self.assertTrue(sg.load_exceptions(repo_file))


if __name__ == "__main__":
    unittest.main()
