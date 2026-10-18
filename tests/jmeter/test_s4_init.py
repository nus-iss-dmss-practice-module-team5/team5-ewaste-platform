"""Run the real setup sampler from outside the JMX directory, as a GUI launch can."""

import copy
import csv
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as E

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(os.environ.get("JMETER_BIN"), "Set JMETER_BIN to run JMeter")
class InitTests(unittest.TestCase):
    def run_init(self, fault=""):
        with tempfile.TemporaryDirectory(prefix="s4-gui-init-") as tmp:
            root = Path(tmp)
            plan_dir = root / "plan"
            (plan_dir / "data").mkdir(parents=True)
            launch_dir = root / "unrelated-launch-directory"
            launch_dir.mkdir()
            data = plan_dir / "data/s4-golden.json"
            if fault != "missing_data":
                shutil.copyfile(ROOT / "artifacts/jmeter/data/s4-golden.json", data)
            if fault == "invalid_json":
                data.write_text('{"secret": "fixture-private-sentinel", broken')

            tree = E.parse(ROOT / "artifacts/jmeter/EWaste_API_Test_Plan.jmx")
            init = copy.deepcopy(
                tree.find('.//JSR223Sampler[@testname="SETUP_S4_INIT"]')
            )
            top = tree.find("hashTree/hashTree")
            for index, node in enumerate(list(top)):
                if node.tag in ["ThreadGroup", "SetupThreadGroup", "PostThreadGroup"]:
                    selected = node.get("testname", "").startswith("S4 12 ")
                    node.set("enabled", str(selected).lower())
                    if selected:
                        body = list(top)[index + 1]
                        body.clear()
                        body.append(init)
                        E.SubElement(body, "hashTree")
                elif node.tag == "ResultCollector":
                    node.set("enabled", "false")
            plan = plan_dir / "EWaste_API_Test_Plan.jmx"
            tree.write(plan, encoding="UTF-8", xml_declaration=True)
            credentials = root / "private.properties"
            credentials.write_text(
                "".join(
                    f"{role}_email={role}@example.test\n"
                    f"{role}_password=credential-private-sentinel\n"
                    for role in [
                        "donor",
                        "recycler",
                        "recycler2",
                        "collector",
                        "auditor",
                    ]
                    if not (fault == "missing_credentials" and role == "donor")
                )
            )
            credentials.chmod(0o600)
            extra = []
            if fault == "output_not_directory":
                (plan_dir / "blocked").write_text("This is a file")
                extra = ["-Js4_output=blocked"]
            results, log = root / "results.jtl", root / "jmeter.log"
            proc = subprocess.run(
                [
                    os.environ["JMETER_BIN"],
                    "-n",
                    "-t",
                    str(plan),
                    "-q",
                    str(credentials),
                    "-l",
                    str(results),
                    "-j",
                    str(log),
                    "-Jhost=http://127.0.0.1:9",
                    "-Jrun_s4=true",
                    "-Jjmeterengine.force.system.exit=true",
                    "-Jjmeter.save.saveservice.output_format=csv",
                    "-Jjmeter.save.saveservice.print_field_names=true",
                    "-Jjmeter.save.saveservice.response_message=true",
                    *extra,
                ],
                cwd=launch_dir,
                capture_output=True,
                text=True,
                timeout=60,
            )
            self.assertTrue(results.exists(), proc.stdout + proc.stderr)
            with results.open(newline="") as stream:
                rows = list(csv.DictReader(stream))
            self.assertEqual([r["label"] for r in rows], ["SETUP_S4_INIT"])
            for content in [
                results.read_text(),
                log.read_text(),
                proc.stdout,
                proc.stderr,
            ]:
                self.assertNotIn("credential-private-sentinel", content)
                self.assertNotIn("fixture-private-sentinel", content)
            return rows[0], list((plan_dir / "results/gui").glob("s4-*"))

    def test_default_paths_work_outside_repository(self):
        row, directories = self.run_init()
        self.assertEqual(row["responseCode"], "200", row)
        self.assertEqual(row["success"], "true")
        self.assertEqual(len(directories), 1)

    def test_missing_data_names_setting(self):
        row, _ = self.run_init("missing_data")
        self.assertEqual(row["responseCode"], "CONFIG_FAILED")
        self.assertIn("s4_data_file was not found", row["responseMessage"])

    def test_invalid_json_does_not_echo_file_content(self):
        row, _ = self.run_init("invalid_json")
        self.assertEqual(row["responseCode"], "CONFIG_FAILED")
        self.assertIn("s4_data_file must contain valid JSON", row["responseMessage"])

    def test_missing_credentials_names_variable_without_value(self):
        row, _ = self.run_init("missing_credentials")
        self.assertEqual(row["responseCode"], "CONFIG_FAILED")
        self.assertIn("Missing donor_email", row["responseMessage"])

    def test_output_file_is_rejected_as_directory(self):
        row, _ = self.run_init("output_not_directory")
        self.assertEqual(row["responseCode"], "CONFIG_FAILED")
        self.assertIn("s4_output", row["responseMessage"])


if __name__ == "__main__":
    unittest.main()
