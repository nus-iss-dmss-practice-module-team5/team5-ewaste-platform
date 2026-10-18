"""Execute the real JMX on a loopback contract double, including failure paths."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from mock_api import MockAPI, ROOT


@unittest.skipUnless(
    os.environ.get("JMETER_BIN"), "Set JMETER_BIN to run JMX contract smoke tests"
)
class PlanTests(unittest.TestCase):
    def run_plan(self, fault="", profile="all", credentials=True):
        self.tmp = tempfile.TemporaryDirectory(prefix="jmeter-s4-test-")
        self.addCleanup(self.tmp.cleanup)
        path = Path(self.tmp.name)
        private = path / "accounts.properties"
        private.write_text(
            "".join(
                f"{r}_email={r}@example.test\n{r}_password=synthetic-only\n"
                for r in ["donor", "recycler", "recycler2", "collector", "auditor"]
            )
            if credentials
            else ""
        )
        private.chmod(0o600)
        settings = path / "settings.properties"
        settings.write_text(
            f"s4_profile={profile}\nauth_pause_ms=0\ns4_ramp_seconds=0\ns4_poll_interval_ms=10\ns4_poll_timeout_seconds=1\ns4_custody_pause_ms=0\ns4_start_spread_ms=500\n"
        )
        output = path / "results"
        with MockAPI(fault) as server:
            proc = subprocess.run(
                [
                    str(ROOT / "scripts/run-jmeter-s4.sh"),
                    "--host",
                    server.origin,
                    "--credentials",
                    str(private),
                    "--settings",
                    str(settings),
                    "--output",
                    str(output),
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                timeout=180,
            )
        if os.environ.get("S4_KEEP_TEST_OUTPUT"):
            import shutil

            shutil.copytree(
                output,
                Path(os.environ["S4_KEEP_TEST_OUTPUT"])
                / (fault or ("success" if credentials else "missing_credentials")),
                dirs_exist_ok=True,
            )
        return proc, output

    def test_full_plan_and_safe_artifacts(self):
        proc, out = self.run_plan()
        self.assertEqual(
            proc.returncode,
            0,
            proc.stdout
            + proc.stderr
            + "\n"
            + (out / "jmeter.log").read_text()[-12000:],
        )
        result = json.loads((out / "summary.json").read_text())
        self.assertEqual(result["functional_status"], "PASS")
        self.assertEqual(result["sql_integrity"], "NOT_RUN")
        self.assertEqual(result["unexpected_error_rate"], 0)
        sql = (out / "reconciliation.sql").read_text()
        self.assertIn("rejected_key_has_no_command", sql)
        self.assertIn("golden_result", sql)
        for file in out.rglob("*"):
            if file.is_file():
                text = file.read_text()
                self.assertNotIn("synthetic-only", text, file.name)
                self.assertNotIn("synthetic-refresh-", text, file.name)

    def test_two_winners_are_rejected(self):
        proc, out = self.run_plan("two_claim_winners", "claim")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn(
            "Race must have exactly one winner", (out / "results.jtl").read_text()
        )

    def test_wrong_metric_is_rejected(self):
        proc, out = self.run_plan("wrong_metric", "burst")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Metric mismatch", (out / "results.jtl").read_text())

    def test_matching_poll_is_bounded(self):
        proc, out = self.run_plan("matching_timeout", "claim")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("MATCH timeout", (out / "results.jtl").read_text())

    def test_missing_credentials_fail_before_http(self):
        proc, out = self.run_plan(profile="claim", credentials=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("CONFIG_FAILED", (out / "results.jtl").read_text())
        self.assertNotIn("SETUP_LOGIN", (out / "results.jtl").read_text())


if __name__ == "__main__":
    unittest.main()
