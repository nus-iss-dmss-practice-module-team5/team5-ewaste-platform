"""Exercise real race-binding samplers without HTTP or saved user credentials."""

import copy
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as E

ROOT = Path(__file__).resolve().parents[2]
PLAN = ROOT / "artifacts/jmeter/EWaste_API_Test_Plan.jmx"
spec = importlib.util.spec_from_file_location(
    "s4_builder", ROOT / "scripts/jmeter/build_s4_extension.py"
)
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class PreservationTests(unittest.TestCase):
    def test_generator_preserves_all_existing_user_variables(self):
        tree = E.parse(PLAN)
        args = tree.find("hashTree/hashTree/Arguments/collectionProp")
        # Test arbitrary GUI values, including secrets/IDs, without using real ones.
        for index, argument in enumerate(args):
            argument.find('stringProp[@name="Argument.value"]').text = (
                f"user-value-{index}"
            )
        before = E.tostring(args)
        with tempfile.TemporaryDirectory(prefix="s4-preserve-") as tmp:
            plan = Path(tmp) / "plan.jmx"
            tree.write(plan)
            with patch.object(builder, "PLAN", plan):
                builder.build()
            after = E.parse(plan).find("hashTree/hashTree/Arguments/collectionProp")

            # Indentation may differ, but every element, attribute and value must match.
            def normalise(node):
                for item in node.iter():
                    item.tail = None
                    if item.text is not None and not item.text.strip():
                        item.text = None
                return E.tostring(node)

            self.assertEqual(normalise(E.fromstring(before)), normalise(after))


@unittest.skipUnless(os.environ.get("JMETER_BIN"), "Set JMETER_BIN to run JMeter")
class BindingTests(unittest.TestCase):
    def run_binding(self, fault="", kind="handoff"):
        with tempfile.TemporaryDirectory(prefix="s4-bind-") as tmp:
            directory = Path(tmp)
            root = E.Element(
                "jmeterTestPlan", version="1.2", properties="5.0", jmeter="5.6.3"
            )
            outer = E.SubElement(root, "hashTree")
            plan, top = builder.node(
                outer, "TestPlan", "Isolated binding regression", "TestPlanGui"
            )
            builder.prop(plan, "TestPlan.serialize_threadgroups", True, "boolProp")
            args, _ = builder.node(
                top, "Arguments", "Synthetic variables", "ArgumentsPanel"
            )
            collection = E.SubElement(
                args, "collectionProp", name="Arguments.arguments"
            )
            for name, value in {
                "run_s4": "true",
                "s4_profile": "all",
                "s4_ramp_seconds": "0",
            }.items():
                arg = E.SubElement(
                    collection, "elementProp", name=name, elementType="Argument"
                )
                builder.prop(arg, "Argument.name", name)
                builder.prop(arg, "Argument.value", value)
                builder.prop(arg, "Argument.metadata", "=")
            setup = builder.group(top, "Synthetic setup")
            seed = """import java.util.concurrent.ConcurrentHashMap
def token=[access:'private-token-sentinel',expiry:java.time.Instant.now().epochSecond+900]
def S=[failed:false,profile:'all',tokens:[collector:token,recycler:token,recycler2:token],
 fixtures:[[scenario:'handoff-race',id:'synthetic-batch',version:5,assignment:'synthetic-assignment',handoff:[notes:'private-payload-sentinel']],
           [scenario:'claim-race',id:'synthetic-batch',version:3,epoch:'1']],races:new ConcurrentHashMap()]
props.put('s4.state',S)
"""
            faults = {
                "missing_state": "props.remove('s4.state')",
                "failed_setup": "S.failed=true",
                "wrong_profile": "S.profile='claim'",
                "missing_token": "S.tokens.remove('collector')",
                "expired_token": "S.tokens.collector.expiry=1",
                "missing_fixture": "S.fixtures.clear()",
                "missing_assignment": "S.fixtures[0].remove('assignment')",
                "missing_payload": "S.fixtures[0].remove('handoff')",
            }
            builder.script(
                setup,
                "SEED",
                seed + faults.get(fault, "") + "\nreturn null",
                wrap=False,
            )
            race = builder.group(
                top, "Binding regression", threads="2" if not fault else "1"
            )
            # Copy just this sampler: never run real HTTP or saved user variables.
            sampler = copy.deepcopy(
                E.parse(PLAN).find(
                    f'.//JSR223Sampler[@testname="AUX_BIND_{kind.upper()}"]'
                )
            )
            race.append(sampler)
            E.SubElement(race, "hashTree")
            builder.script(
                race,
                "CHECK_BINDING",
                """assert vars.getObject('s4.fixture').id=='synthetic-batch'
assert props.get('s4.state').races.containsKey('"""
                + kind
                + """')
assert vars.get('s4.race_role')=="""
                + (
                    "'collector'\nassert vars.get('s4.assignment')=='synthetic-assignment'"
                    if kind == "handoff"
                    else "(ctx.threadNum%2==0?'recycler':'recycler2')"
                ),
                wrap=False,
            )
            path = directory / "plan.jmx"
            E.ElementTree(root).write(path, encoding="UTF-8", xml_declaration=True)
            results, log = directory / "results.jtl", directory / "jmeter.log"
            proc = subprocess.run(
                [
                    os.environ["JMETER_BIN"],
                    "-n",
                    "-t",
                    str(path),
                    "-l",
                    str(results),
                    "-j",
                    str(log),
                    "-Jjmeterengine.force.system.exit=true",
                    "-Jjmeter.save.saveservice.output_format=xml",
                    "-Jjmeter.save.saveservice.response_data=true",
                    "-Jjmeter.save.saveservice.response_data.on_error=true",
                    "-Jjmeter.save.saveservice.response_message=true",
                ],
                cwd=directory,
                capture_output=True,
                text=True,
                timeout=45,
            )
            self.assertTrue(results.exists(), proc.stdout + proc.stderr)
            content = results.read_text()
            rows = list(E.fromstring(content))
            bindings = [r for r in rows if r.get("lb") == f"AUX_BIND_{kind.upper()}"]
            self.assertTrue(bindings, content + log.read_text())
            for text in [content, log.read_text(), proc.stdout, proc.stderr]:
                self.assertNotIn("private-token-sentinel", text)
                self.assertNotIn("private-payload-sentinel", text)
            if not fault:
                self.assertEqual(len(bindings), 2)
                self.assertTrue(all(r.get("s") == "true" for r in rows), content)
                self.assertEqual(
                    len([r for r in rows if r.get("lb") == "CHECK_BINDING"]), 2
                )
            else:
                self.assertEqual(bindings[0].get("rc"), "CHECK_FAILED")
                self.assertEqual(bindings[0].get("s"), "false")
                self.assertEqual(
                    bindings[0].findtext("responseData"), bindings[0].get("rm")
                )
                self.assertIn(bindings[0].get("rm"), log.read_text())
            return bindings[0].get("rm")

    def test_two_handoff_threads_bind_the_shared_assignment(self):
        self.run_binding()

    def test_two_claim_threads_bind_distinct_roles(self):
        self.run_binding(kind="claim")

    def test_missing_setup_has_visible_diagnostic(self):
        self.assertIn("Enable S4 12", self.run_binding("missing_state"))

    def test_failed_setup_has_visible_diagnostic(self):
        self.assertIn("earlier S4 step failed", self.run_binding("failed_setup"))

    def test_wrong_profile_has_visible_diagnostic(self):
        self.assertIn("s4_profile=all or handoff", self.run_binding("wrong_profile"))

    def test_missing_token_has_visible_diagnostic(self):
        self.assertIn(
            "collector login token is missing", self.run_binding("missing_token")
        )

    def test_expired_token_has_visible_diagnostic(self):
        self.assertIn("120 seconds", self.run_binding("expired_token"))

    def test_incomplete_fixtures_have_visible_diagnostics(self):
        for fault in ["missing_fixture", "missing_assignment", "missing_payload"]:
            with self.subTest(fault=fault):
                self.assertIn("missing", self.run_binding(fault))


if __name__ == "__main__":
    unittest.main()
