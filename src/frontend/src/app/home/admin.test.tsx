import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { WorkflowError } from "@/lib/workflow/errors";
import type { PlatformStatus } from "@/lib/workflow/types";
import {
  PlatformHealthView,
  ReleaseView,
  formatReadAt,
  shortDigest,
} from "./admin";

const getPlatformStatus = vi.fn();

vi.mock("@/lib/auth/session-context", () => ({
  useSession: () => ({ session: { tokens: { accessToken: "access-token" } } }),
}));

vi.mock("@/lib/workflow/api", () => ({
  getPlatformStatus: (...args: unknown[]) => getPlatformStatus(...args),
}));

function healthy(): PlatformStatus {
  return {
    readAt: "2026-10-21T14:02:11Z",
    environment: "prod",
    summary: "OK",
    readiness: { status: "ready", mysql: "ok", redis: "ok" },
    latency: {
      apiP95Ms: 388,
      apiSamples: 1204,
      eventP95Ms: 1240,
      eventSamples: 96,
      windowMinutes: 15,
      readAt: "2026-10-21T13:57:00Z",
    },
    consumerLag: {
      records: 0,
      partitions: 3,
      sampledAt: "2026-10-21T14:01:31Z",
    },
    outbox: {
      pending: 0,
      oldestPendingCreatedAt: null,
      quarantined: 0,
      recentQuarantined: [],
    },
    processingFailuresLastHour: 0,
    evidence: { completedBatches: 128, withEvidence: 120, withoutEvidence: 8 },
    release: {
      id: "s4-rc2",
      commit: "4f1c2a9",
      deployedAt: "2026-10-21T09:14:00Z",
      gateRunUrl: "https://github.com/org/repo/actions/runs/412",
      gateDecision: "PASS",
      images: [
        {
          name: "workflow-api",
          digest: "sha256:9b1e00000000000000000000000004c7",
        },
        {
          name: "workflow-ui",
          digest: "sha256:52aa0000000000000000000000000e1d0",
        },
      ],
      rollbackTarget: {
        id: "s4-rc1",
        commit: "b83d0e2",
        gateRunUrl: "https://github.com/org/repo/actions/runs/398",
        images: [
          {
            name: "workflow-api",
            digest: "sha256:aaaa000000000000000000000000007e21",
          },
        ],
      },
    },
    workbookUrl: "https://portal.azure.com/#workbook",
    unknown: {},
  };
}

function attention(): PlatformStatus {
  const status = healthy();
  status.summary = "ATTENTION";
  status.processingFailuresLastHour = 3;
  status.outbox = {
    pending: 0,
    oldestPendingCreatedAt: null,
    quarantined: 2,
    recentQuarantined: [
      {
        eventType: "TreatmentRecorded",
        schemaVersion: 1,
        batchId: "ae95ae4f-0000-4000-8000-00000000c322",
        attemptCount: 8,
        lastErrorCode: "BROKER_TIMEOUT",
        createdAt: "2026-10-15T13:41:00Z",
        correlationId: "corr-8f31c2",
      },
      {
        eventType: "CollectorAssigned",
        schemaVersion: 1,
        batchId: "231d73cd-0000-4000-8000-0000000b1b5",
        attemptCount: 8,
        lastErrorCode: "SCHEMA_REJECTED",
        createdAt: "2026-10-15T09:12:00Z",
        correlationId: "corr-11ad90",
      },
    ],
  };
  return status;
}

function tileOrder(): string[] {
  return within(screen.getByTestId("admin-tiles"))
    .getAllByRole("listitem")
    .map((item) => item.getAttribute("data-testid") ?? "");
}

function expectNoCustodyControls() {
  expect(
    screen.queryByRole("button", { name: /download|evidence|custody/i }),
  ).toBeNull();
  expect(
    screen.queryByRole("link", { name: /download|evidence file|custody/i }),
  ).toBeNull();
}

beforeEach(() => {
  getPlatformStatus.mockReset();
});

describe("PlatformHealthView", () => {
  it("shows every tile within target and only evidence counts", async () => {
    getPlatformStatus.mockResolvedValue(healthy());
    render(<PlatformHealthView />);

    expect(await screen.findByTestId("admin-summary-OK")).toHaveTextContent(
      "All signals within target.",
    );
    expect(getPlatformStatus).toHaveBeenCalledWith("access-token");
    expect(screen.getByTestId("admin-health-header")).toHaveTextContent(
      "Environment prod · release s4-rc2 · read at 14:02:11 UTC (",
    );
    expect(screen.getByTestId("admin-tile-readiness")).toHaveTextContent(
      "ReadyMySQL ok · Redis ok",
    );
    expect(screen.getByTestId("admin-tile-api-latency")).toHaveTextContent(
      "388 ms",
    );
    expect(screen.getByTestId("admin-tile-api-latency")).toHaveTextContent(
      "Target under 3 s · 1,204 requests",
    );
    expect(screen.getByTestId("admin-tile-api-latency")).toHaveTextContent(
      "5 min old",
    );
    expect(screen.getByTestId("admin-tile-event-latency")).toHaveTextContent(
      "1.24 s",
    );
    expect(screen.getByTestId("admin-tile-consumer-lag")).toHaveTextContent(
      "0 records3 partitions · sampled 40 s ago",
    );
    expect(screen.getByTestId("admin-tile-dead-lettered")).toHaveTextContent(
      "Processing failures last hour: 0",
    );
    expect(screen.getByTestId("admin-evidence-completed")).toHaveTextContent(
      "128",
    );
    expect(screen.getByTestId("admin-evidence-with")).toHaveTextContent("120");
    expect(screen.getByTestId("admin-evidence-without")).toHaveTextContent("8");
    expect(screen.getByTestId("admin-evidence-files")).toHaveTextContent(
      "Not available to administrators",
    );
    expect(screen.queryByTestId("admin-dead-lettered")).toBeNull();
    const workbook = screen.getByTestId("admin-workbook-link");
    expect(workbook).toHaveAttribute(
      "href",
      "https://portal.azure.com/#workbook",
    );
    expect(workbook).toHaveAttribute("target", "_blank");
    expect(workbook).toHaveAttribute("rel", "noopener noreferrer");
    expectNoCustodyControls();
  });

  it("puts dead-lettered events first and lists them without payloads", async () => {
    getPlatformStatus.mockResolvedValue(attention());
    render(<PlatformHealthView />);

    expect(
      await screen.findByTestId("admin-summary-ATTENTION"),
    ).toHaveTextContent(
      "Attention: 2 events are dead-lettered and need investigation. Everything else is within target.",
    );
    expect(tileOrder()[0]).toBe("admin-tile-dead-lettered");
    expect(screen.getByTestId("admin-tile-dead-lettered")).toHaveAttribute(
      "data-state",
      "bad",
    );
    expect(screen.getByTestId("admin-tile-dead-lettered")).toHaveTextContent(
      "newest created 15 Oct 13:41 UTC",
    );
    expect(screen.getByTestId("admin-tile-dead-lettered")).toHaveTextContent(
      "Processing failures last hour: 3 (query 4)",
    );
    const list = screen.getByTestId("admin-dead-lettered");
    expect(list).toHaveTextContent("Dead-lettered events (newest 2)");
    expect(within(list).getAllByRole("row")).toHaveLength(3);
    expect(within(list).getAllByText("TreatmentRecorded v1")).toHaveLength(2); // row and phone card
    expect(
      within(list).getAllByTestId("admin-dead-lettered-card")[0],
    ).toHaveTextContent(
      "Created 15 Oct 13:41 UTC · 8 attempts · BROKER_TIMEOUT",
    );
    expectNoCustodyControls();
  });

  it("says a single dead-lettered event needs investigation", async () => {
    const status = attention();
    status.outbox!.quarantined = 1;
    status.outbox!.recentQuarantined.pop();
    getPlatformStatus.mockResolvedValue(status);
    render(<PlatformHealthView />);

    expect(
      await screen.findByTestId("admin-summary-ATTENTION"),
    ).toHaveTextContent("1 event is dead-lettered and needs investigation.");
  });

  it("shows Unknown with a reason, never 0, when Azure Monitor did not answer", async () => {
    const status = healthy();
    status.summary = "UNKNOWN";
    status.latency = null;
    status.consumerLag = null;
    status.processingFailuresLastHour = null;
    status.unknown = {
      latency: "LOG_QUERY_FAILED",
      consumer_lag: "LOG_QUERY_FAILED",
      processing_failures: "LOG_QUERY_FAILED",
    };
    getPlatformStatus.mockResolvedValue(status);
    render(<PlatformHealthView />);

    expect(
      await screen.findByTestId("admin-summary-UNKNOWN"),
    ).toHaveTextContent(
      "Some signals are unknown. Latency, consumer lag and processing failures could not be read. Do not read this as healthy.",
    );
    for (const id of ["api-latency", "event-latency", "consumer-lag"]) {
      const tile = screen.getByTestId(`admin-tile-${id}`);
      expect(tile).toHaveAttribute("data-state", "unknown");
      expect(tile).toHaveTextContent("Unknown");
      expect(tile).toHaveTextContent("Azure Monitor did not answer");
      expect(tile).not.toHaveTextContent(/\b0 (ms|records)\b/);
    }
    expect(screen.getByTestId("admin-tile-dead-lettered")).toHaveTextContent(
      "Processing failures last hour: unknown",
    );
    // The readiness reading that did come back still shows.
    expect(screen.getByTestId("admin-tile-readiness")).toHaveTextContent(
      "Ready",
    );
  });

  it("says how old a stale lag sample is", async () => {
    const status = healthy();
    status.summary = "UNKNOWN";
    status.consumerLag = {
      records: null,
      partitions: 3,
      sampledAt: "2026-10-21T13:56:11Z",
    };
    status.unknown = { consumer_lag: "STALE_SAMPLE" };
    getPlatformStatus.mockResolvedValue(status);
    render(<PlatformHealthView />);

    expect(
      await screen.findByTestId("admin-tile-consumer-lag"),
    ).toHaveTextContent("UnknownLast sample 6 min ago (limit 90 s)");
  });

  it("says when Azure Monitor is not connected", async () => {
    const status = healthy();
    status.summary = "UNKNOWN";
    status.latency = null;
    status.unknown = { latency: "NOT_CONFIGURED" };
    status.workbookUrl = null;
    getPlatformStatus.mockResolvedValue(status);
    render(<PlatformHealthView />);

    expect(
      await screen.findByTestId("admin-tile-api-latency"),
    ).toHaveTextContent("Azure Monitor is not connected to this deployment");
    expect(screen.getByTestId("admin-workbook")).toHaveTextContent(
      "no link is configured",
    );
    expect(screen.queryByTestId("admin-workbook-link")).toBeNull();
  });

  it("names the dependency that is down", async () => {
    const status = healthy();
    status.summary = "NOT_READY";
    status.readiness = {
      status: "not_ready",
      mysql: "ok",
      redis: "unavailable",
    };
    getPlatformStatus.mockResolvedValue(status);
    render(<PlatformHealthView />);

    expect(
      await screen.findByTestId("admin-summary-NOT_READY"),
    ).toHaveTextContent("Not ready: Redis is unavailable.");
    expect(tileOrder()[0]).toBe("admin-tile-readiness");
  });

  it.each([500, 502, 503, 504])(
    "shows the unavailable sentence and no tiles for %i",
    async (status) => {
      getPlatformStatus.mockRejectedValue(
        new WorkflowError("server text", "error", "INTERNAL", "corr-1", status),
      );
      render(<PlatformHealthView />);

      expect(
        await screen.findByTestId("admin-health-unavailable"),
      ).toHaveTextContent(
        "The workflow service is temporarily unavailable. Try again.",
      );
      expect(screen.queryByTestId("admin-tiles")).toBeNull();
      expect(screen.queryByText(/server text|INTERNAL|corr-1/)).toBeNull();
    },
  );

  it("tries again after a network failure", async () => {
    getPlatformStatus
      .mockRejectedValueOnce(
        new WorkflowError("x", "network", "NETWORK", "corr-network"),
      )
      .mockResolvedValueOnce(healthy());
    render(<PlatformHealthView />);

    await userEvent.click(await screen.findByTestId("admin-health-retry"));

    expect(await screen.findByTestId("admin-summary-OK")).toBeInTheDocument();
    expect(getPlatformStatus).toHaveBeenCalledTimes(2);
  });

  it("shows only the access sentence for a non-Admin token", async () => {
    getPlatformStatus.mockRejectedValue(
      new WorkflowError("Forbidden", "forbidden", "FORBIDDEN", "corr-2", 403),
    );
    render(<PlatformHealthView />);

    expect(
      await screen.findByTestId("admin-health-forbidden"),
    ).toHaveTextContent(
      "You do not have access to this record for your organisation.",
    );
    expect(screen.queryByTestId("admin-health-retry")).toBeNull();
    expect(screen.queryByTestId("admin-tiles")).toBeNull();
  });

  it("re-reads only when Refresh is pressed", async () => {
    getPlatformStatus.mockResolvedValue(healthy());
    render(<PlatformHealthView />);
    await screen.findByTestId("admin-summary-OK");
    expect(getPlatformStatus).toHaveBeenCalledTimes(1);

    getPlatformStatus.mockResolvedValue(attention());
    await userEvent.click(screen.getByTestId("admin-health-refresh"));

    expect(
      await screen.findByTestId("admin-summary-ATTENTION"),
    ).toBeInTheDocument();
    expect(getPlatformStatus).toHaveBeenCalledTimes(2);
  });
});

describe("ReleaseView", () => {
  it("shows the running release, its digests and links to the retained artifacts", async () => {
    getPlatformStatus.mockResolvedValue(healthy());
    render(<ReleaseView />);

    expect(
      await screen.findByTestId("admin-release-identity"),
    ).toHaveTextContent(
      "Running on prod: release s4-rc2 from commit 4f1c2a9, deployed 21 Oct 2026 09:14 UTC by GitHub Actions run",
    );
    expect(screen.getByTestId("admin-gate-PASS")).toHaveTextContent(
      "Gate decision PASS",
    );
    const api = screen.getByTestId("admin-image-workflow-api");
    expect(
      within(api).getByTitle("sha256:9b1e00000000000000000000000004c7"),
    ).toHaveTextContent("sha256:9b1e…04c7");
    expect(api).toHaveTextContent("Verified at deploy");
    expect(screen.getByTestId("admin-sbom-workflow-api")).toHaveAttribute(
      "href",
      "https://github.com/org/repo/actions/runs/412#artifacts",
    );
    expect(screen.getByTestId("admin-gate-record-link")).toHaveAttribute(
      "href",
      "https://github.com/org/repo/actions/runs/412",
    );
    expect(screen.getAllByTestId("admin-image-card")).toHaveLength(2);
    expect(screen.getByTestId("admin-card-scan-workflow-ui")).toHaveAttribute(
      "href",
      "https://github.com/org/repo/actions/runs/412#artifacts",
    );
    expect(screen.getByTestId("admin-rollback-line")).toHaveTextContent(
      "Previous signed release s4-rc1 (commit b83d0e2): api …7e21.",
    );
    expect(screen.getByTestId("admin-rollback-record")).toHaveAttribute(
      "href",
      "https://github.com/org/repo/actions/runs/398",
    );
    expectNoCustodyControls();
  });

  it("says the release was not recorded", async () => {
    getPlatformStatus.mockResolvedValue({
      ...healthy(),
      release: null,
      unknown: { release: "NOT_RECORDED" },
    });
    render(<ReleaseView />);

    expect(
      await screen.findByTestId("admin-release-not-recorded"),
    ).toHaveTextContent("Release details not recorded for this deployment.");
    expect(screen.queryByTestId("admin-images")).toBeNull();
  });

  it("flags a release with no gate record and does not claim a signature", async () => {
    const status = healthy();
    status.release = { ...status.release!, gateDecision: null };
    getPlatformStatus.mockResolvedValue(status);
    render(<ReleaseView />);

    expect(await screen.findByTestId("admin-gate-missing")).toHaveTextContent(
      "No gate record for the running release.",
    );
    expect(screen.getByTestId("admin-image-workflow-api")).toHaveTextContent(
      "Not recorded",
    );
    expect(
      screen.getByTestId("admin-image-workflow-api"),
    ).not.toHaveTextContent("Verified");
  });

  it("does not render a link that is not https", async () => {
    const status = healthy();
    status.release = { ...status.release!, gateRunUrl: "javascript:alert(1)" };
    getPlatformStatus.mockResolvedValue(status);
    render(<ReleaseView />);

    await screen.findByTestId("admin-release-identity");
    expect(screen.queryByTestId("admin-release-run")).toBeNull();
    expect(screen.queryByTestId("admin-gate-record-link")).toBeNull();
    expect(screen.queryByTestId("admin-sbom-workflow-api")).toBeNull();
    expect(screen.queryByTestId("admin-card-sbom-workflow-api")).toBeNull();
    expect(document.querySelector('a[href^="javascript"]')).toBeNull();
  });

  it("shows the unavailable sentence and no release rows when the API is down", async () => {
    getPlatformStatus.mockRejectedValue(
      new WorkflowError(
        "x",
        "unavailable",
        "SERVICE_UNAVAILABLE",
        "corr-3",
        503,
      ),
    );
    render(<ReleaseView />);

    expect(
      await screen.findByTestId("admin-release-unavailable"),
    ).toBeInTheDocument();
    expect(screen.queryByTestId("admin-images")).toBeNull();
  });

  it("copies the full digest", async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, "clipboard", {
      value: { writeText },
      configurable: true,
    });
    getPlatformStatus.mockResolvedValue(healthy());
    render(<ReleaseView />);

    await userEvent.click(await screen.findByTestId("admin-copy-workflow-api"));

    expect(writeText).toHaveBeenCalledWith(
      "sha256:9b1e00000000000000000000000004c7",
    );
    await waitFor(() =>
      expect(screen.getByTestId("admin-copy-workflow-api")).toHaveTextContent(
        "Copied",
      ),
    );
  });
});

describe("formatting", () => {
  it("shows UTC first with local time and zone beside it", () => {
    expect(formatReadAt("2026-10-21T14:02:11Z")).toMatch(
      /^14:02:11 UTC \(\d{2}:\d{2} .+\)$/,
    );
  });

  it("shortens a digest to its first and last four characters", () => {
    expect(shortDigest("sha256:9b1e1234567890abcdef04c7")).toBe(
      "sha256:9b1e…04c7",
    );
    expect(shortDigest("sha256:abc")).toBe("sha256:abc");
  });
});
