"""Tests for render_report.py. Run: python3 -m unittest discover -s scripts/sonar"""

import json
import tempfile
import unittest
from pathlib import Path

import render_report as rr

KEY = "team5-ewaste-platform"


def write_inputs(directory: Path) -> None:
    files = {
        "status.json": {"projectStatus": {"status": "ERROR", "conditions": [
            {"metricKey": "new_coverage", "status": "ERROR", "actualValue": "41.0", "errorThreshold": "80"}]}},
        "measures.json": {"component": {"measures": [
            {"metric": "bugs", "value": "3"},
            {"metric": "reliability_rating", "value": "3.0"},
            {"metric": "vulnerabilities", "value": "0"},
            {"metric": "security_rating", "value": "1.0"},
            {"metric": "security_hotspots", "value": "2"},
            {"metric": "security_review_rating", "value": "5.0"},
            {"metric": "code_smells", "value": "57"},
            {"metric": "sqale_rating", "value": "1.0"},
            {"metric": "coverage", "value": "72.345"},
            {"metric": "duplicated_lines_density", "value": "2.1"},
            {"metric": "ncloc", "value": "18234"},
        ]}},
        "issues.json": {"issues": [
            {"rule": "go:S1", "component": f"{KEY}:src/backend/a.go", "line": 9, "message": "Fix | this",
             "impacts": [{"softwareQuality": "RELIABILITY", "severity": "HIGH"},
                         {"softwareQuality": "MAINTAINABILITY", "severity": "LOW"}]},
            {"rule": "py:S2", "component": f"{KEY}:src/matcher/matcher/b.py", "message": "Minor thing",
             "type": "CODE_SMELL", "severity": "MINOR"},
            {"rule": "ts:S3", "component": f"{KEY}:src/frontend/src/c.tsx", "line": 3,
             "message": "<script>alert(1)</script>", "type": "BUG", "severity": "BLOCKER"},
        ]},
        "hotspots.json": {"hotspots": [
            {"component": f"{KEY}:src/backend/d.go", "line": 4, "securityCategory": "weak-cryptography",
             "vulnerabilityProbability": "MEDIUM", "message": "Make sure this is safe."}]},
    }
    for name, content in files.items():
        (directory / name).write_text(json.dumps(content), encoding="utf-8")


class RenderTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        write_inputs(self.dir)
        self.report = rr.build(self.dir, KEY, "abc1234", "https://example/run/1")

    def tearDown(self):
        self._tmp.cleanup()

    def test_overview_ratings_and_measures(self):
        overview = {o["label"]: o for o in self.report["overview"]}
        self.assertEqual(overview["Bugs"]["count"], "3")
        self.assertEqual(overview["Bugs"]["rating"], "C")
        self.assertEqual(overview["Security hotspots"]["rating"], "E")
        self.assertEqual(self.report["coverage"], "72.3%")
        self.assertEqual(self.report["gate"], "ERROR")

    def test_issue_severity_prefers_impacts_and_orders_top_issues(self):
        top = self.report["top_issues"]
        self.assertEqual([i["severity"] for i in top], ["BLOCKER", "HIGH"])
        self.assertEqual(top[1]["quality"], "Reliability")
        self.assertEqual(top[1]["where"], "src/backend/a.go:9")
        self.assertEqual(dict(self.report["by_severity"]), {"BLOCKER": 1, "HIGH": 1, "MINOR": 1})

    def test_markdown_escapes_pipes_and_shows_gate(self):
        md = rr.to_markdown(self.report)
        self.assertIn("Quality gate: **Failed**", md)
        self.assertIn("Fix \\| this", md)
        self.assertIn("| Reliability | Bugs | 3 | C |", md)

    def test_html_escapes_messages(self):
        page = rr.to_html(self.report)
        self.assertNotIn("<script>alert(1)</script>", page)
        self.assertIn("&lt;script&gt;", page)

    def test_missing_inputs_render_without_error(self):
        with tempfile.TemporaryDirectory() as empty:
            report = rr.build(Path(empty), KEY, "", "")
            self.assertEqual(report["gate"], "NONE")
            self.assertIn("Not computed", rr.to_markdown(report))
            rr.to_html(report)

    def test_cli_writes_three_files(self):
        with tempfile.TemporaryDirectory() as out:
            self.assertEqual(rr.main(["--input-dir", str(self.dir), "--output-dir", out,
                                      "--project-key", KEY, "--commit", "abc"]), 0)
            self.assertEqual(sorted(p.name for p in Path(out).iterdir()),
                             ["report.html", "report.md", "summary.json"])


if __name__ == "__main__":
    unittest.main()
