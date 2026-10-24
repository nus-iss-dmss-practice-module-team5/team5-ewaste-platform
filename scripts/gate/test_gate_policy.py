"""Refusal-case tests for gate_policy.py (EWCSB-241 section 8).

Run: python3 -m unittest discover -s scripts/gate   (needs PyYAML)
"""

import base64
import datetime as dt
import json
import tempfile
import unittest
from pathlib import Path

import gate_policy as gp

TODAY = dt.date(2026, 10, 20)
IMAGE = "workflow-api"
DIGEST = "acrewaste.azurecr.io/workflow-api@sha256:" + "a" * 64
OTHER_DIGEST = "acrewaste.azurecr.io/workflow-api@sha256:" + "b" * 64
LEAD = "Shalett Paulson"


def disposition(**overrides):
    entry = {
        "id": "CVE-2026-85091", "scope": IMAGE, "severity": "High", "reason": "no fix available",
        "justification": "no fixed package yet", "owner": "Lakshanya Poovannan",
        "approved_by": [LEAD, "Jiamin Wang"], "approved_on": "2026-10-19",
        "expires_on": "2026-10-24", "ticket": "EWCSB-249",
    }
    entry.update(overrides)
    return entry


def match(cve, severity, related=()):
    return {"vulnerability": {"id": cve, "severity": severity},
            "relatedVulnerabilities": [{"id": r} for r in related],
            "artifact": {"name": "zlib", "version": "1.3.2-r0"}}


class GateTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        self.sbom = self.dir / "sbom.json"
        self.sbom.write_text(json.dumps({"packages": [{"name": "zlib"}]}))
        self.grype = self.dir / "grype.json"
        self.dispositions = self.dir / "dispositions.yaml"
        self.write_dispositions([])

    def tearDown(self):
        self._tmp.cleanup()

    def write_grype(self, matches):
        self.grype.write_text(json.dumps({"matches": matches}))

    def write_dispositions(self, entries, lead=LEAD):
        import yaml
        self.dispositions.write_text(yaml.safe_dump({"security_lead": lead, "dispositions": entries}))

    def build(self, digest=DIGEST):
        try:
            return gp.evaluate_build(IMAGE, digest, self.sbom, self.grype, self.dispositions, TODAY)
        except gp.PolicyError as error:
            return {"decision": "REFUSED", "reasons": [str(error)]}


class Gate2Tests(GateTestCase):
    def test_rt01_clean_image_passes(self):
        self.write_grype([match("CVE-1", "Medium"), match("CVE-2", "Low")])
        result = self.build()
        self.assertEqual(result["decision"], "PASS")
        self.assertEqual(result["findings"]["medium"], 1)

    def test_rt06_critical_refused(self):
        self.write_grype([match("CVE-9", "Critical")])
        result = self.build()
        self.assertEqual(result["decision"], "REFUSED")
        self.assertIn("Critical finding CVE-9", result["reasons"][0])

    def test_rt07_high_without_disposition_refused(self):
        self.write_grype([match("CVE-2026-85091", "High")])
        self.assertEqual(self.build()["decision"], "REFUSED")

    def test_rt08_high_with_valid_disposition_passes_and_is_recorded(self):
        self.write_grype([match("CVE-2026-85091", "High")])
        self.write_dispositions([disposition()])
        result = self.build()
        self.assertEqual(result["decision"], "PASS")
        self.assertEqual(result["dispositions_applied"], ["CVE-2026-85091"])

    def test_disposition_matches_related_cve_of_a_ghsa_finding(self):
        self.write_grype([match("GHSA-xxxx", "High", related=["CVE-2026-85091"])])
        self.write_dispositions([disposition()])
        self.assertEqual(self.build()["decision"], "PASS")

    def test_rt09_expired_disposition_refused(self):
        self.write_grype([match("CVE-2026-85091", "High")])
        self.write_dispositions([disposition(approved_on="2026-10-10", expires_on="2026-10-18")])
        result = self.build()
        self.assertEqual(result["decision"], "REFUSED")
        self.assertIn("expired on 2026-10-18", result["reasons"][0])

    def test_rt10_self_approved_disposition_refused(self):
        self.write_grype([match("CVE-2026-85091", "High")])
        self.write_dispositions([disposition(owner="Jiamin Wang")])
        self.assertIn("own owner", self.build()["reasons"][0])

    def test_rt11_critical_disposition_still_refused(self):
        self.write_grype([match("CVE-2026-85091", "Critical")])
        self.write_dispositions([disposition(severity="Critical")])
        result = self.build()
        self.assertEqual(result["decision"], "REFUSED")
        self.assertIn("Critical cannot be dispositioned", result["reasons"][0])

    def test_disposition_rules(self):
        cases = {
            "expiry is more than 14 days": dict(approved_on="2026-10-01", expires_on="2026-10-20"),
            "after 2026-10-24": dict(approved_on="2026-10-19", expires_on="2026-10-25"),
            "security lead": dict(approved_by=["Jiamin Wang", "Mrigakshi Roy Choudhury"]),
            "plus one technical approver": dict(approved_by=[LEAD]),
            "compensating_control is required": dict(reason="compensating control"),
            "reason must be one of": dict(reason="we will fix it later"),
        }
        for expected, overrides in cases.items():
            with self.subTest(expected):
                problem = gp.disposition_problem(disposition(**overrides), LEAD, TODAY)
                self.assertIsNotNone(problem)
                self.assertIn(expected, problem)

    def test_disposition_scoped_to_another_digest_does_not_apply(self):
        self.write_grype([match("CVE-2026-85091", "High")])
        self.write_dispositions([disposition(scope=f"{IMAGE}@{OTHER_DIGEST.split('@')[1]}")])
        self.assertEqual(self.build()["decision"], "REFUSED")
        self.write_dispositions([disposition(scope=f"{IMAGE}@{DIGEST.split('@')[1]}")])
        self.assertEqual(self.build()["decision"], "PASS")

    def test_rt16_missing_sbom_refused(self):
        self.write_grype([])
        self.sbom.unlink()
        self.assertIn("SBOM is missing", self.build()["reasons"][0])

    def test_rt17_missing_or_broken_scanner_report_refused(self):
        self.assertIn("Grype produced no report", self.build()["reasons"][0])
        self.grype.write_text("{not json")
        self.assertIn("not valid JSON", self.build()["reasons"][0])

    def test_invalid_disposition_file_refuses(self):
        self.write_grype([])
        self.dispositions.write_text("security_lead: x\ndispositions:\n  - id: CVE-1\n")
        self.assertIn("missing", self.build()["reasons"][0])

    def test_rt05_tag_reference_refused(self):
        self.write_grype([])
        result = self.build(digest="acrewaste.azurecr.io/workflow-api:latest")
        self.assertIn("immutable", result["reasons"][0])


def attestation_line(digest, decision="PASS", stage="build-sign", predicate_type=gp.GATE_PREDICATE_TYPE):
    sha = digest.split("@sha256:")[1]
    statement = {"predicateType": predicate_type,
                 "subject": [{"name": "workflow-api", "digest": {"sha256": sha}}],
                 "predicate": {"decision": decision, "stage": stage, "run_url": "https://run/1",
                               "image": {"name": IMAGE, "digest": digest},
                               "dispositions_applied": []}}
    payload = base64.b64encode(json.dumps(statement).encode()).decode()
    return json.dumps({"payloadType": "application/vnd.in-toto+json", "payload": payload})


class Gate3Tests(GateTestCase):
    def deploy(self, signature_ok, lines, digest=DIGEST):
        path = self.dir / "attestation.json"
        path.write_text("\n".join(lines))
        try:
            return gp.evaluate_deploy(digest, signature_ok, path)
        except gp.PolicyError as error:
            return {"decision": "REFUSED", "reasons": [str(error)]}

    def test_rt01_signed_with_passing_record(self):
        self.assertEqual(self.deploy(True, [attestation_line(DIGEST)])["decision"], "PASS")

    def test_rt02_unsigned_refused(self):
        result = self.deploy(False, [])
        self.assertEqual(result["decision"], "REFUSED")
        self.assertIn("signature missing", result["reasons"][0])

    def test_rt03_record_for_a_different_digest_refused(self):
        result = self.deploy(True, [attestation_line(OTHER_DIGEST)])
        self.assertIn("no passing Gate 2 decision", result["reasons"][0])

    def test_refused_or_foreign_attestations_do_not_count(self):
        lines = [attestation_line(DIGEST, decision="REFUSED"),
                 attestation_line(DIGEST, predicate_type="https://example.com/other")]
        self.assertEqual(self.deploy(True, lines)["decision"], "REFUSED")

    def test_rt05_deploy_by_tag_refused(self):
        result = self.deploy(True, [], digest="acrewaste.azurecr.io/workflow-api:dev-abc1234")
        self.assertIn("deploy by digest only", result["reasons"][0])


class CliTests(GateTestCase):
    def test_build_writes_refused_record_and_exits_1(self):
        out = self.dir / "decision.json"
        code = gp.main(["build", "--image", IMAGE, "--digest", DIGEST, "--sbom", str(self.sbom),
                        "--grype", str(self.dir / "missing.json"), "--dispositions", str(self.dispositions),
                        "--out", str(out), "--commit", "abc", "--tool", "grype=v0.120.1",
                        "--today", "2026-10-20"])
        record = json.loads(out.read_text())
        self.assertEqual(code, 1)
        self.assertEqual(record["decision"], "REFUSED")
        self.assertEqual(record["stage"], "build-sign")
        self.assertEqual(record["tools"], {"grype": "v0.120.1"})
        self.assertEqual(record["image"]["digest"], DIGEST)

    def test_repository_dispositions_file_is_valid(self):
        repo_file = Path(__file__).resolve().parents[2] / "security" / "dispositions.yaml"
        self.assertEqual(gp.main(["validate", "--dispositions", str(repo_file), "--today", "2026-10-20"]), 0)


if __name__ == "__main__":
    unittest.main()
