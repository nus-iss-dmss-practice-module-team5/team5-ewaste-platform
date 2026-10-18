"""Loopback-only contract double. Tests the JMX, NOT the real API or MySQL."""

import base64
import copy
from datetime import datetime, timezone
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import threading
import time
from urllib.parse import urlsplit
from uuid import uuid4

ROOT = Path(__file__).resolve().parents[2]


def uid():
    return str(uuid4())


def now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


class MockAPI(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, fault=""):
        super().__init__(("127.0.0.1", 0), Handler)
        self.fault = fault
        self.lock = threading.Lock()
        self.batches = {}
        self.assignments = {}
        self.commands = {}
        self.golden = json.loads(
            (ROOT / "artifacts/jmeter/data/s4-golden.json").read_text()
        )["cases"]
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *args):
        self.shutdown()
        self.server_close()
        self.thread.join()

    @property
    def origin(self):
        return f"http://127.0.0.1:{self.server_port}"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        self.handle_api()

    def do_POST(self):
        self.handle_api()

    def handle_api(self):
        self.body = json.loads(
            self.rfile.read(int(self.headers.get("Content-Length", 0))) or "{}"
        )
        self.path_only = urlsplit(self.path).path
        self.parts = self.path_only.split("/")
        # Keep requests in flight long enough to verify overlap on a local host.
        if self.path_only.endswith(("/claim", "/handoff")):
            time.sleep(0.06)
        with self.server.lock:
            try:
                status, result = self.route()
            except (AssertionError, KeyError, ValueError) as exc:
                status, result = 422, dict(code="MOCK_CONTRACT_ERROR", message=str(exc))
        result = copy.deepcopy(result)
        result["correlation_id"] = self.headers.get("X-Correlation-ID", "")
        payload = json.dumps(result).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("X-Correlation-ID", self.headers.get("X-Correlation-ID", ""))
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def error(self, status, code):
        return status, dict(code=code, message="Synthetic rejection")

    def route(self):
        s = self.server
        p = self.parts
        if self.path_only == "/api/v1/auth/login":
            role = self.body["email"].split("@")[0]
            assert role in ["donor", "recycler", "recycler2", "collector", "auditor"]
            claims = dict(
                role="RECYCLER" if role == "recycler2" else role.upper(),
                org=role + "-org",
                sub=role,
                exp=int(time.time()) + 3600,
            )
            token = (
                "mock."
                + base64.urlsafe_b64encode(json.dumps(claims).encode())
                .decode()
                .rstrip("=")
                + ".unsigned"
            )
            return 200, dict(
                access_token=token,
                refresh_token="synthetic-refresh-" + role,
                expires_in=3600,
            )
        token = self.headers.get("Authorization", "").split(".")
        if len(token) != 3:
            return self.error(401, "INVALID_TOKEN")
        self.role = json.loads(base64.urlsafe_b64decode(token[1] + "==="))["sub"]
        if self.path_only == "/api/v1/batches" and self.command == "POST":
            assert self.role == "donor"
            assert self.body["quantity"] == 5 and self.body["estimated_weight_kg"] == 12
            assert self.body["notes"].startswith("S4LD:")
            b = dict(
                batch_id=uid(), status="DRAFT", version=1, claim_epoch="1", timeline=[]
            )
            s.batches[b["batch_id"]] = b
            return 201, dict(data=self.batch(b))
        if p[3] == "opportunities":
            b = s.batches[p[4]]
            if s.fault == "matching_timeout":
                return self.error(404, "NOT_FOUND")
            if b["status"] == "SUBMITTED":
                b.update(status="MATCHED", version=3)
            return 200, dict(data=self.batch(b))
        if p[3] == "processing":
            b = s.batches[p[5]]
            if b["status"] == "RECYCLED":
                if not b.get("polled"):
                    b["polled"] = True
                else:
                    b.update(status="COMPLETED", version=9)
                    self.audit(b, "AnalyticsCompleted")
            g = b.get("golden")
            result = self.batch(b)
            if g:
                result.update(
                    g["metrics"],
                    data_quality=g["quality"],
                    anomaly_codes=g["flags"],
                    **g["receipt"],
                )
                if s.fault == "wrong_metric":
                    result["diverted_kg"] = "999.00"
            return 200, dict(data=result)
        if p[3] == "audit":
            if self.role != "auditor":
                return self.error(403, "FORBIDDEN")
            if p[4] == "impact":
                items = [
                    self.impact(b)
                    for b in s.batches.values()
                    if b["status"] == "COMPLETED"
                ]
                return 200, dict(
                    data=dict(items=items, total_count=len(items), totals={}, filter={})
                )
            b = s.batches[p[5]]
            data = (
                b["timeline"]
                if p[6] == "timeline"
                else [
                    dict(
                        anomaly_id=uid(),
                        batch_id=b["batch_id"],
                        result_id=b["result"],
                        code=c,
                    )
                    for c in b["golden"]["flags"]
                ]
            )
            return 200, dict(data=data, total_count=len(data), page=1, page_size=100)
        if p[3] == "assignments":
            assignment = s.assignments[p[4]]
            b = s.batches[assignment["batch_id"]]
            if self.command == "GET":
                return 200, dict(data=copy.deepcopy(assignment))
        else:
            b = s.batches[p[4]]
            assignment = s.assignments.get(b.get("assignment"))
            if self.command == "GET":
                return 200, dict(data=self.batch(b))
        operation = p[-1]
        command_key = (self.role, self.headers["Idempotency-Key"])
        digest = (self.path_only, self.headers["If-Match-Version"], self.body)
        if command_key in s.commands:
            saved, response = s.commands[command_key]
            if saved != digest:
                return self.error(409, "IDEMPOTENCY_CONFLICT")
            return copy.deepcopy(response)
        if operation == "receipt":
            if self.role != "recycler":
                return self.error(403, "FORBIDDEN")
            if self.body["actual_item_count"] == 0:
                return self.error(422, "VALIDATION_ERROR")
        if int(self.headers["If-Match-Version"]) != b["version"]:
            if s.fault == "two_claim_winners" and operation == "claim":
                return 200, dict(
                    data=dict(
                        batch_id=b["batch_id"],
                        status="APPROVED",
                        version=4,
                        claim_id=uid(),
                        reservation_id=uid(),
                        event_id=uid(),
                    )
                )
            return self.error(409, "STALE_VERSION")
        event = uid()
        if operation == "submit":
            assert b["status"] == "DRAFT" and self.body == {}
            b.update(status="SUBMITTED", version=2)
            result = dict(data=self.batch(b), event_id=event)
        elif operation == "claim":
            assert b["status"] == "MATCHED" and self.role in ["recycler", "recycler2"]
            assert (
                self.body["expected_version"] == b["version"]
                and self.body["claim_epoch"] == "1"
            )
            b.update(status="APPROVED", version=4, claim=uid())
            self.audit(b, "ClaimConfirmed")
            result = dict(
                data=dict(
                    batch_id=b["batch_id"],
                    status="APPROVED",
                    version=4,
                    claim_id=b["claim"],
                    reservation_id=uid(),
                    event_id=event,
                )
            )
        elif operation == "assignments":
            assert b["status"] == "APPROVED" and self.role == "collector"
            assert (
                self.body["collector_scope_id"] == "scope-1"
                and self.body["expected_version"] == 4
            )
            b.update(status="ASSIGNED", version=5, assignment=uid())
            assignment = dict(
                assignment_id=b["assignment"],
                batch_id=b["batch_id"],
                assignment_status="ACCEPTED",
                created_at=now(),
                version=1,
            )
            s.assignments[b["assignment"]] = assignment
            result = dict(data=copy.deepcopy(assignment), event_id=event)
        elif operation == "handoff":
            assert self.role == "collector" and b["status"] == "ASSIGNED"
            assert (
                self.body["pickup_occurred_at"] >= assignment["created_at"]
                and len(self.body["verification_hash"]) == 64
            )
            assignment.update(assignment_status="COMPLETED", version=2)
            b.update(status="COLLECTED", version=6)
            self.audit(b, "CollectionCompleted")
            result = dict(data=copy.deepcopy(assignment), event_id=event)
        elif operation == "receipt":
            assert b["status"] == "COLLECTED"
            b.update(status="VERIFIED", version=7, receipt=uid(), received=self.body)
            self.audit(b, "ReceiptVerified")
            result = dict(
                data=dict(
                    batch_id=b["batch_id"],
                    status="VERIFIED",
                    version=7,
                    receipt_id=b["receipt"],
                    **self.body,
                ),
                event_id=event,
            )
        elif operation == "treatment":
            assert b["status"] == "VERIFIED" and self.role == "recycler"
            g = next(
                g
                for g in s.golden
                if g["receipt"] == b["received"] and g["treatment"] == self.body
            )
            b.update(
                status="RECYCLED",
                version=8,
                treatment=uid(),
                golden=g,
                source_event=event,
                result=uid(),
            )
            self.audit(b, "TreatmentRecorded")
            result = dict(
                data=dict(
                    batch_id=b["batch_id"],
                    status="RECYCLED",
                    version=8,
                    treatment_id=b["treatment"],
                    evidence_status="ABSENT",
                    data_quality=g["quality"],
                    **g["metrics"],
                ),
                event_id=event,
            )
        else:
            raise AssertionError("Unsupported mock operation")
        response = (201 if operation == "assignments" else 200, result)
        s.commands[command_key] = copy.deepcopy((digest, response))
        return response

    def batch(self, b):
        return {k: b[k] for k in ["batch_id", "status", "version", "claim_epoch"]} | {
            "collector_scope_id": "scope-1"
        }

    def audit(self, b, event):
        b["timeline"].append(
            dict(
                audit_id=uid(),
                command_id=uid(),
                correlation_id=self.headers["X-Correlation-ID"],
                occurred_at=now(),
                batch_id=b["batch_id"],
                event_type=event,
            )
        )

    def impact(self, b):
        return dict(
            batch_id=b["batch_id"],
            result_id=b["result"],
            source_event_id=b["source_event"],
            receipt_id=b["receipt"],
            treatment_id=b["treatment"],
            rule_version="d3-v1",
            input_hash="a" * 64,
            data_quality=b["golden"]["quality"],
            metrics=b["golden"]["analytics_metrics"],
            anomaly_codes=b["golden"]["flags"],
        )
