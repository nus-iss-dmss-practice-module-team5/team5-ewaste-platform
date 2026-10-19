import { describe, expect, it } from "vitest";
import { parseData, parsePlatformStatus } from "./parse";

const wire = {
  read_at: "2026-10-21T14:02:11Z",
  environment: "prod",
  summary: "UNKNOWN",
  readiness: { status: "ready", mysql: "ok", redis: "ok" },
  latency: null,
  consumer_lag: {
    records: null,
    partitions: 3,
    sampled_at: "2026-10-21T13:56:11Z",
  },
  outbox: {
    pending: 1,
    oldest_pending_created_at: "2026-10-21T13:59:00Z",
    quarantined: 1,
    recent_quarantined: [
      {
        event_type: "TreatmentRecorded",
        schema_version: 1,
        batch_id: "ae95ae4f",
        attempt_count: 8,
        last_error_code: null,
        created_at: "2026-10-15T13:41:00Z",
        correlation_id: "corr-8f31c2",
      },
    ],
  },
  processing_failures_last_hour: null,
  evidence: { completed_batches: 128, with_evidence: 120, without_evidence: 8 },
  release: {
    id: "s4-rc2",
    commit: "4f1c2a9",
    deployed_at: null,
    gate_run_url: "https://github.com/org/repo/actions/runs/412",
    gate_decision: "PASS",
    images: [{ name: "workflow-api", digest: "sha256:9b1e" }],
    rollback_target: null,
  },
  workbook_url: null,
  unknown: {
    latency: "LOG_QUERY_FAILED",
    consumer_lag: "STALE_SAMPLE",
    processing_failures: "LOG_QUERY_FAILED",
  },
};

describe("parsePlatformStatus", () => {
  it("keeps unread sources null instead of 0", () => {
    const status = parseData(
      { data: wire },
      parsePlatformStatus,
      "Platform status",
    );

    expect(status.latency).toBeNull();
    expect(status.consumerLag).toEqual({
      records: null,
      partitions: 3,
      sampledAt: "2026-10-21T13:56:11Z",
    });
    expect(status.processingFailuresLastHour).toBeNull();
    expect(status.outbox?.recentQuarantined[0]).toMatchObject({
      batchId: "ae95ae4f",
      lastErrorCode: null,
      attemptCount: 8,
    });
    expect(status.release).toMatchObject({
      id: "s4-rc2",
      deployedAt: null,
      rollbackTarget: null,
    });
    expect(status.unknown).toEqual(wire.unknown);
  });

  it("rejects an unknown summary and a non-numeric count", () => {
    expect(() => parsePlatformStatus({ ...wire, summary: "GREEN" })).toThrow();
    expect(() =>
      parsePlatformStatus({
        ...wire,
        evidence: { ...wire.evidence, completed_batches: "128" },
      }),
    ).toThrow();
    expect(() =>
      parsePlatformStatus({
        ...wire,
        consumer_lag: { ...wire.consumer_lag, records: "0" },
      }),
    ).toThrow();
  });
});
