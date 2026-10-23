"use client";

import { useSession } from "@/lib/auth/session-context";
import { getPlatformStatus } from "@/lib/workflow/api";
import { isWorkflowError } from "@/lib/workflow/errors";
import type {
  PlatformStatus,
  QuarantinedEvent,
  ReleaseImage,
} from "@/lib/workflow/types";
import { useEffect, useState } from "react";
import { Banner, LoadingLine, dateParts, messageForKind } from "./workflow-ui";

// Targets shared with the API summary and the EWCSB-223 alert rules.
const API_P95_TARGET_MS = 3000;
const EVENT_P95_TARGET_MS = 10000;
const LAG_TARGET_RECORDS = 100;

type TileState = "bad" | "attention" | "unknown" | "ok";

type Tile = {
  id: string;
  label: string;
  state: TileState;
  value: string;
  detail: string;
  source: string;
};

const STATE_RANK: Record<TileState, number> = {
  bad: 0,
  attention: 1,
  unknown: 2,
  ok: 3,
};

const STATE_BORDER: Record<TileState, string> = {
  bad: "border-l-red-600",
  attention: "border-l-amber-500",
  unknown: "border-l-slate-400",
  ok: "border-l-green-600",
};

const UNKNOWN_REASON: Record<string, string> = {
  NOT_CONFIGURED: "Azure Monitor is not connected to this deployment",
  LOG_QUERY_FAILED: "Azure Monitor did not answer",
  TIMED_OUT: "The read took longer than 3 s",
  NO_SAMPLE: "No sample in the window",
  STALE_SAMPLE: "The last sample is too old",
  READ_FAILED: "Could not be read",
};

const UNKNOWN_SOURCE: Record<string, string> = {
  latency: "latency",
  consumer_lag: "consumer lag",
  processing_failures: "processing failures",
  outbox: "the outbox",
  evidence: "evidence counts",
};

function reasonText(reason?: string): string {
  return (reason && UNKNOWN_REASON[reason]) ?? "Could not be read";
}

function joinWords(words: string[]): string {
  if (words.length <= 1) {
    return words.join("");
  }
  return `${words.slice(0, -1).join(", ")} and ${words[words.length - 1]}`;
}

function capitalise(text: string): string {
  return text.charAt(0).toUpperCase() + text.slice(1);
}

function plural(count: number, one: string, many: string): string {
  return `${count.toLocaleString("en-GB")} ${count === 1 ? one : many}`;
}

// Only https links are rendered; anything else stays plain text.
function safeUrl(value: string | null | undefined): string | null {
  return value && /^https:\/\//i.test(value) ? value : null;
}

function validDate(iso: string | null | undefined): Date | null {
  if (!iso) {
    return null;
  }
  const date = new Date(iso);
  return Number.isNaN(date.getTime()) ? null : date;
}

// "14:02:11 UTC (22:02 SGT)": UTC first, local time with its zone beside it.
export function formatReadAt(iso: string): string {
  const date = validDate(iso);
  if (!date) {
    return iso;
  }
  const utc = new Intl.DateTimeFormat("en-GB", {
    timeZone: "UTC",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  }).format(date);
  const local = new Intl.DateTimeFormat("en-GB", {
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
    timeZoneName: "short",
  }).format(date);
  return `${utc} UTC (${local})`;
}

// UTC parts for "15 Oct 13:41" and "21 Oct 2026 09:14 UTC".
function utcParts(date: Date): Record<string, string> {
  return dateParts(date, "UTC");
}

// For rows under a "(UTC)" heading.
function formatUtcShort(iso: string | null | undefined): string {
  const date = validDate(iso);
  if (!date) {
    return "—";
  }
  const p = utcParts(date);
  return `${p.day} ${p.month} ${p.hour}:${p.minute}`;
}

function formatUtcDate(iso: string | null | undefined): string {
  const date = validDate(iso);
  if (!date) {
    return "an unrecorded time";
  }
  const p = utcParts(date);
  return `${p.day} ${p.month} ${p.year} ${p.hour}:${p.minute} UTC`;
}

function age(iso: string | null | undefined, readAt: string): string {
  const then = validDate(iso);
  const now = validDate(readAt);
  if (!then || !now) {
    return "age unknown";
  }
  const seconds = Math.max(
    0,
    Math.round((now.getTime() - then.getTime()) / 1000),
  );
  if (seconds < 90) {
    return `${seconds} s`;
  }
  return `${Math.round(seconds / 60)} min`;
}

function formatMs(value: number): string {
  return value < 1000
    ? `${Math.round(value)} ms`
    : `${(value / 1000).toFixed(2).replace(/\.?0+$/, "")} s`;
}

export function shortDigest(digest: string): string {
  const [algorithm, hex] = digest.includes(":")
    ? digest.split(":", 2)
    : ["", digest];
  if (!hex || hex.length <= 8) {
    return digest;
  }
  return `${algorithm ? `${algorithm}:` : ""}${hex.slice(0, 4)}…${hex.slice(-4)}`;
}

function buildTiles(status: PlatformStatus): Tile[] {
  const { readiness, latency, consumerLag, outbox, unknown, readAt } = status;
  const tiles: Tile[] = [];

  tiles.push({
    id: "readiness",
    label: "Service readiness",
    state: readiness.status === "ready" ? "ok" : "bad",
    value: readiness.status === "ready" ? "Ready" : "Not ready",
    detail: `MySQL ${readiness.mysql} · Redis ${readiness.redis}`,
    source: "Source: API readiness check · now",
  });

  const latencyTile = (
    id: string,
    label: string,
    p95: number | null | undefined,
    samples: number,
    targetMs: number,
    noun: string,
  ): Tile => {
    if (!latency) {
      return {
        id,
        label,
        state: "unknown",
        value: "Unknown",
        detail: reasonText(unknown.latency),
        source: "Source: Azure Monitor query 2",
      };
    }
    const source = `Source: Azure Monitor query 2 · ${age(latency.readAt, readAt)} old`;
    if (p95 === null || p95 === undefined || samples === 0) {
      return {
        id,
        label,
        state: "unknown",
        value: "Unknown",
        detail: `No ${noun} in the last ${latency.windowMinutes} min`,
        source,
      };
    }
    return {
      id,
      label,
      state: p95 > targetMs ? "attention" : "ok",
      value: formatMs(p95),
      detail: `Target under ${formatMs(targetMs)} · ${plural(samples, noun.replace(/s$/, ""), noun)}`,
      source,
    };
  };
  tiles.push(
    latencyTile(
      "api-latency",
      `API latency, P95 (${latency?.windowMinutes ?? 15} min)`,
      latency?.apiP95Ms,
      latency?.apiSamples ?? 0,
      API_P95_TARGET_MS,
      "requests",
    ),
    latencyTile(
      "event-latency",
      `Event processing, P95 (${latency?.windowMinutes ?? 15} min)`,
      latency?.eventP95Ms,
      latency?.eventSamples ?? 0,
      EVENT_P95_TARGET_MS,
      "events",
    ),
  );

  if (consumerLag && consumerLag.records !== null) {
    tiles.push({
      id: "consumer-lag",
      label: "Consumer lag",
      state: consumerLag.records > LAG_TARGET_RECORDS ? "attention" : "ok",
      value: plural(consumerLag.records, "record", "records"),
      detail: `${plural(consumerLag.partitions, "partition", "partitions")} · sampled ${age(consumerLag.sampledAt, readAt)} ago`,
      source: "Source: Azure Monitor query 3",
    });
  } else {
    // A stale sample keeps its time so the tile can say how old it is.
    tiles.push({
      id: "consumer-lag",
      label: "Consumer lag",
      state: "unknown",
      value: "Unknown",
      detail: consumerLag?.sampledAt
        ? `Last sample ${age(consumerLag.sampledAt, readAt)} ago (limit 90 s)`
        : reasonText(unknown.consumer_lag),
      source: "Source: Azure Monitor query 3",
    });
  }

  if (outbox) {
    tiles.push({
      id: "pending",
      label: "Events waiting to publish",
      state: "ok",
      value: String(outbox.pending),
      detail: `Outbox PENDING · oldest ${outbox.oldestPendingCreatedAt ? `created ${formatUtcShort(outbox.oldestPendingCreatedAt)} UTC` : "—"}`,
      source: "Source: event outbox · now",
    });
    const newest = outbox.recentQuarantined[0];
    const failures =
      status.processingFailuresLastHour === null
        ? "unknown"
        : String(status.processingFailuresLastHour);
    tiles.push({
      id: "dead-lettered",
      label: "Dead-lettered events",
      state: outbox.quarantined > 0 ? "bad" : "ok",
      value: String(outbox.quarantined),
      detail: `Outbox QUARANTINED${newest ? ` · newest created ${formatUtcShort(newest.createdAt)} UTC` : ""}`,
      source: `Processing failures last hour: ${failures} (query 4)`,
    });
  } else {
    for (const [id, label] of [
      ["pending", "Events waiting to publish"],
      ["dead-lettered", "Dead-lettered events"],
    ]) {
      tiles.push({
        id,
        label,
        state: "unknown",
        value: "Unknown",
        detail: reasonText(unknown.outbox),
        source: "Source: event outbox",
      });
    }
  }

  return tiles
    .map((tile, index) => ({ tile, index }))
    .sort(
      (a, b) =>
        STATE_RANK[a.tile.state] - STATE_RANK[b.tile.state] ||
        a.index - b.index,
    )
    .map(({ tile }) => tile);
}

function summaryBanner(status: PlatformStatus) {
  const unknownSources = Object.keys(status.unknown)
    .filter((source) => source !== "release")
    .map((source) => UNKNOWN_SOURCE[source] ?? source.replace(/_/g, " "));
  if (status.summary === "NOT_READY") {
    const down = [
      status.readiness.mysql !== "ok" ? "MySQL" : null,
      status.readiness.redis !== "ok" ? "Redis" : null,
    ].filter((item): item is string => item !== null);
    return {
      tone: "error" as const,
      lead: "Not ready:",
      text: down.length
        ? `${joinWords(down)} ${down.length === 1 ? "is" : "are"} unavailable.`
        : "the API readiness check failed.",
    };
  }
  if (status.summary === "ATTENTION") {
    const reasons: string[] = [];
    const quarantined = status.outbox?.quarantined ?? 0;
    if (quarantined > 0) {
      reasons.push(
        `${plural(quarantined, "event is", "events are")} dead-lettered and need${quarantined === 1 ? "s" : ""} investigation.`,
      );
    }
    if ((status.latency?.apiP95Ms ?? 0) > API_P95_TARGET_MS) {
      reasons.push("API latency is over target.");
    }
    if ((status.latency?.eventP95Ms ?? 0) > EVENT_P95_TARGET_MS) {
      reasons.push("Event processing is over target.");
    }
    if ((status.consumerLag?.records ?? 0) > LAG_TARGET_RECORDS) {
      reasons.push(`Consumer lag is over ${LAG_TARGET_RECORDS} records.`);
    }
    return {
      tone: "warning" as const,
      lead: "Attention:",
      text: `${reasons.join(" ")} ${unknownSources.length ? "Some signals are unknown." : "Everything else is within target."}`,
    };
  }
  if (status.summary === "UNKNOWN") {
    return {
      tone: "warning" as const,
      lead: "Some signals are unknown.",
      text: `${capitalise(joinWords(unknownSources))} could not be read. Do not read this as healthy.`,
    };
  }
  return {
    tone: "success" as const,
    lead: "All signals within target.",
    text: "",
  };
}

const UNAVAILABLE_STATUSES = [500, 502, 503, 504];

// Failure and denied states draw no tiles, so no old reading can be mistaken
// for a current one.
function failureFor(error: unknown) {
  if (isWorkflowError(error)) {
    if (error.kind === "forbidden") {
      return {
        kind: "forbidden",
        text: messageForKind("forbidden"),
        retry: false,
      };
    }
    if (error.kind === "session") {
      return { kind: "session", text: messageForKind("session"), retry: false };
    }
    if (
      error.kind === "unavailable" ||
      error.kind === "network" ||
      (error.status !== undefined &&
        UNAVAILABLE_STATUSES.includes(error.status))
    ) {
      return {
        kind: "unavailable",
        text: messageForKind("unavailable"),
        retry: true,
      };
    }
  }
  return { kind: "error", text: messageForKind("error"), retry: true };
}

function usePlatformStatus() {
  const { session } = useSession();
  const [status, setStatus] = useState<PlatformStatus | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<unknown>(null);

  async function load() {
    if (!session) {
      return;
    }
    setLoading(true);
    setError(null);
    try {
      setStatus(await getPlatformStatus(session.tokens.accessToken));
    } catch (caught) {
      setStatus(null);
      setError(caught);
    } finally {
      setLoading(false);
    }
  }

  // One read when the tab opens. There is no polling; Refresh re-reads.
  useEffect(() => {
    const timer = window.setTimeout(() => {
      void load();
    }, 0);
    return () => window.clearTimeout(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [session?.tokens.accessToken]);

  return { status, loading, error, refresh: load };
}

function Failure({
  error,
  testId,
  onRetry,
}: {
  error: unknown;
  testId: string;
  onRetry: () => void;
}) {
  const failure = failureFor(error);
  return (
    <div className="grid max-w-md gap-3">
      <Banner testId={`${testId}-${failure.kind}`} tone="error">
        {failure.text}
      </Banner>
      {failure.retry ? (
        <button
          type="button"
          data-testid={`${testId}-retry`}
          onClick={onRetry}
          className="justify-self-start rounded-md border border-teal-800 px-4 py-2 text-sm font-medium text-teal-900"
        >
          Try again
        </button>
      ) : null}
    </div>
  );
}

function RefreshButton({
  loading,
  onClick,
  testId,
}: {
  loading: boolean;
  onClick: () => void;
  testId: string;
}) {
  return (
    <button
      type="button"
      data-testid={testId}
      disabled={loading}
      onClick={onClick}
      className="font-medium text-teal-800 disabled:opacity-50"
    >
      {loading ? "Refreshing…" : "Refresh"}
    </button>
  );
}

function ExternalLink({
  href,
  testId,
  children,
}: {
  href: string;
  testId: string;
  children: string;
}) {
  return (
    <a
      href={href}
      target="_blank"
      rel="noopener noreferrer"
      data-testid={testId}
      className="font-medium whitespace-nowrap text-teal-800 underline-offset-2 hover:underline"
    >
      {children} ↗
    </a>
  );
}

function DeadLettered({ events }: { events: QuarantinedEvent[] }) {
  const eventName = (event: QuarantinedEvent) =>
    `${event.eventType} v${event.schemaVersion}`;
  return (
    <section data-testid="admin-dead-lettered" className="grid gap-2">
      <h2 className="text-base font-semibold text-slate-900">
        Dead-lettered events (newest {events.length})
      </h2>
      <div className="hidden overflow-x-auto sm:block">
        <table className="w-full text-left text-sm">
          <thead className="text-slate-500">
            <tr>
              <th className="py-2 pr-3">Event created (UTC)</th>
              <th className="py-2 pr-3">Event</th>
              <th className="py-2 pr-3">Batch</th>
              <th className="py-2 pr-3">Attempts</th>
              <th className="py-2 pr-3">Last error</th>
              <th className="py-2">Correlation</th>
            </tr>
          </thead>
          <tbody>
            {events.map((event) => (
              <tr
                key={`${event.correlationId}-${event.createdAt}-${event.batchId}`}
                className="border-t border-slate-200 align-top"
              >
                <td className="py-2 pr-3 whitespace-nowrap">
                  {formatUtcShort(event.createdAt)}
                </td>
                <td className="py-2 pr-3">{eventName(event)}</td>
                <td className="py-2 pr-3 font-mono break-all">
                  {event.batchId}
                </td>
                <td className="py-2 pr-3">{event.attemptCount}</td>
                <td className="py-2 pr-3">{event.lastErrorCode ?? "—"}</td>
                <td className="py-2 font-mono break-all">
                  {event.correlationId}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <ul className="grid gap-2 sm:hidden">
        {events.map((event) => (
          <li
            key={`${event.correlationId}-${event.createdAt}-${event.batchId}`}
            data-testid="admin-dead-lettered-card"
            className="rounded-md border border-l-4 border-slate-200 border-l-red-600 bg-white p-3 text-sm"
          >
            <p className="font-semibold text-slate-900">{eventName(event)}</p>
            <p className="text-slate-600">
              Created {formatUtcShort(event.createdAt)} UTC ·{" "}
              {plural(event.attemptCount, "attempt", "attempts")} ·{" "}
              {event.lastErrorCode ?? "no error code"}
            </p>
            <p className="font-mono text-xs break-all text-slate-700">
              Batch {event.batchId}
            </p>
            <p className="font-mono text-xs break-all text-slate-700">
              {event.correlationId}
            </p>
          </li>
        ))}
      </ul>
    </section>
  );
}

export function PlatformHealthView() {
  const { status, loading, error, refresh } = usePlatformStatus();

  if (loading && !status) {
    return (
      <LoadingLine testId="admin-health-loading">
        Reading platform health…
      </LoadingLine>
    );
  }
  if (error || !status) {
    return (
      <Failure
        error={error}
        testId="admin-health"
        onRetry={() => void refresh()}
      />
    );
  }

  const banner = summaryBanner(status);
  const tiles = buildTiles(status);
  const workbook = safeUrl(status.workbookUrl);

  return (
    <section data-testid="admin-health" className="grid max-w-6xl gap-5">
      <p data-testid="admin-health-header" className="text-sm text-slate-600">
        Environment{" "}
        <strong className="text-slate-900">
          {status.environment ?? "not recorded"}
        </strong>{" "}
        · release{" "}
        <strong className="text-slate-900">
          {status.release?.id ?? "not recorded"}
        </strong>{" "}
        · read at {formatReadAt(status.readAt)} ·{" "}
        <RefreshButton
          testId="admin-health-refresh"
          loading={loading}
          onClick={() => void refresh()}
        />
      </p>

      <Banner testId={`admin-summary-${status.summary}`} tone={banner.tone}>
        <strong>{banner.lead}</strong>
        {banner.text ? ` ${banner.text}` : null}
      </Banner>

      <ul
        data-testid="admin-tiles"
        className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3"
      >
        {tiles.map((tile) => (
          <li
            key={tile.id}
            data-testid={`admin-tile-${tile.id}`}
            data-state={tile.state}
            className={`min-w-0 rounded-md border border-l-4 border-slate-200 bg-white p-4 ${STATE_BORDER[tile.state]}`}
          >
            <p className="text-sm text-slate-600">{tile.label}</p>
            <p className="text-2xl font-bold text-slate-900">{tile.value}</p>
            <p className="text-sm break-words text-slate-600">{tile.detail}</p>
            <p className="text-xs break-words text-slate-500">{tile.source}</p>
          </li>
        ))}
      </ul>

      {status.outbox && status.outbox.recentQuarantined.length > 0 ? (
        <DeadLettered events={status.outbox.recentQuarantined} />
      ) : null}

      <section data-testid="admin-evidence" className="grid gap-2">
        <h2 className="text-base font-semibold text-slate-900">
          Custody evidence status
        </h2>
        {status.evidence ? (
          <dl className="grid grid-cols-2 gap-x-6 gap-y-3 text-sm sm:grid-cols-4">
            {[
              [
                "completed",
                "Completed batches",
                status.evidence.completedBatches,
              ],
              ["with", "With validated evidence", status.evidence.withEvidence],
              ["without", "Without evidence", status.evidence.withoutEvidence],
            ].map(([id, label, value]) => (
              <div key={id} data-testid={`admin-evidence-${id}`}>
                <dt className="text-slate-500">{label}</dt>
                <dd className="text-lg font-semibold text-slate-900">
                  {value}
                </dd>
              </div>
            ))}
            <div
              data-testid="admin-evidence-files"
              className="col-span-2 sm:col-span-1"
            >
              <dt className="text-slate-500">Files</dt>
              <dd className="text-slate-700">
                Not available to administrators. Auditors read them on Custody.
              </dd>
            </div>
          </dl>
        ) : (
          <p
            data-testid="admin-evidence-unknown"
            className="text-sm text-slate-600"
          >
            Unknown: {reasonText(status.unknown.evidence).toLowerCase()}.
          </p>
        )}
      </section>

      <p data-testid="admin-workbook" className="text-sm text-slate-600">
        Charts and history:{" "}
        {workbook ? (
          <ExternalLink href={workbook} testId="admin-workbook-link">
            Open the Azure Monitor workbook
          </ExternalLink>
        ) : (
          "in the Azure Monitor workbook (no link is configured for this deployment)."
        )}
      </p>
    </section>
  );
}

function CopyDigest({ digest, testId }: { digest: string; testId: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <button
      type="button"
      data-testid={testId}
      className="font-medium whitespace-nowrap text-teal-800"
      onClick={() => {
        void navigator.clipboard?.writeText(digest).then(
          () => setCopied(true),
          () => setCopied(false),
        );
      }}
    >
      {copied ? "Copied" : "Copy digest"}
    </button>
  );
}

function imageLabel(name: string): string {
  return name.replace(/^workflow-/, "");
}

export function ReleaseView() {
  const { status, loading, error, refresh } = usePlatformStatus();

  if (loading && !status) {
    return (
      <LoadingLine testId="admin-release-loading">
        Reading release details…
      </LoadingLine>
    );
  }
  if (error || !status) {
    return (
      <Failure
        error={error}
        testId="admin-release"
        onRetry={() => void refresh()}
      />
    );
  }

  const { release } = status;
  if (!release) {
    return (
      <section data-testid="admin-release" className="grid max-w-3xl gap-3">
        <Banner testId="admin-release-not-recorded" tone="info">
          Release details not recorded for this deployment.
        </Banner>
        <p className="text-sm text-slate-600">
          Read at {formatReadAt(status.readAt)} ·{" "}
          <RefreshButton
            testId="admin-release-refresh"
            loading={loading}
            onClick={() => void refresh()}
          />
        </p>
      </section>
    );
  }

  const run = safeUrl(release.gateRunUrl);
  const decision = release.gateDecision;
  const passed = decision === "PASS";
  const signature = passed ? "Verified at deploy" : "Not recorded";

  return (
    <section data-testid="admin-release" className="grid max-w-6xl gap-5">
      <p
        data-testid="admin-release-identity"
        className="text-sm text-slate-600"
      >
        Running on{" "}
        <strong className="text-slate-900">
          {status.environment ?? "an unrecorded environment"}
        </strong>
        : release <strong className="text-slate-900">{release.id}</strong>
        {release.commit ? (
          <>
            {" "}
            from commit <code className="font-mono">{release.commit}</code>
          </>
        ) : null}
        , deployed {formatUtcDate(release.deployedAt)}
        {run ? (
          <>
            {" "}
            by{" "}
            <ExternalLink href={run} testId="admin-release-run">
              GitHub Actions run
            </ExternalLink>
          </>
        ) : null}{" "}
        ·{" "}
        <RefreshButton
          testId="admin-release-refresh"
          loading={loading}
          onClick={() => void refresh()}
        />
      </p>

      {decision === null ? (
        <Banner testId="admin-gate-missing" tone="error">
          <strong>No gate record for the running release.</strong> That is
          itself a finding: the deploy job did not stamp a gate decision.
        </Banner>
      ) : passed ? (
        <Banner testId="admin-gate-PASS" tone="success">
          <strong>Gate decision PASS</strong> for the running release, as
          recorded by the deploy job. Gate 3 verifies each signature before
          deploy.
        </Banner>
      ) : (
        <Banner testId={`admin-gate-${decision}`} tone="error">
          <strong>Gate decision {decision}</strong> for the running release.
        </Banner>
      )}

      <section data-testid="admin-images" className="grid gap-2">
        <h2 className="text-base font-semibold text-slate-900">
          Images running now
        </h2>
        {release.images.length === 0 ? (
          <p className="text-sm text-slate-600">No image digests recorded.</p>
        ) : (
          <>
            <div className="hidden overflow-x-auto sm:block">
              <table className="w-full text-left text-sm">
                <thead className="text-slate-500">
                  <tr>
                    <th className="py-2 pr-3">Image</th>
                    <th className="py-2 pr-3">Digest</th>
                    <th className="py-2 pr-3">Signature</th>
                    <th className="py-2">Evidence</th>
                  </tr>
                </thead>
                <tbody>
                  {release.images.map((image) => (
                    <tr
                      key={image.name}
                      data-testid={`admin-image-${image.name}`}
                      className="border-t border-slate-200 align-top"
                    >
                      <td className="py-2 pr-3">{image.name}</td>
                      <td className="py-2 pr-3">
                        <code className="font-mono" title={image.digest}>
                          {shortDigest(image.digest)}
                        </code>{" "}
                        <CopyDigest
                          digest={image.digest}
                          testId={`admin-copy-${image.name}`}
                        />
                      </td>
                      <td className="py-2 pr-3">{signature}</td>
                      <td className="py-2">
                        <ImageLinks run={run} image={image} />
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <ul className="grid gap-2 sm:hidden">
              {release.images.map((image) => (
                <li
                  key={image.name}
                  data-testid="admin-image-card"
                  className="rounded-md border border-slate-200 bg-white p-3 text-sm"
                >
                  <p className="flex flex-wrap justify-between gap-2">
                    <span className="font-semibold text-slate-900">
                      {image.name}
                    </span>
                    <span className="text-slate-600">{signature}</span>
                  </p>
                  <p className="font-mono text-xs break-all text-slate-700">
                    {image.digest}
                  </p>
                  <p className="mt-1 flex flex-wrap gap-3">
                    <ImageLinks run={run} image={image} card />
                    <CopyDigest
                      digest={image.digest}
                      testId={`admin-copy-card-${image.name}`}
                    />
                  </p>
                </li>
              ))}
            </ul>
          </>
        )}
      </section>

      <section data-testid="admin-gate-record" className="grid gap-1 text-sm">
        <h2 className="text-base font-semibold text-slate-900">
          Gate record for this release
        </h2>
        <p className="text-slate-600">
          The SBOM, Grype scan, signature check, gate decision and ZAP report
          are kept on the workflow run for 90 days. Opening them needs a GitHub
          sign-in. Scan counts and dispositions are read there; this page does
          not copy them.
        </p>
        {run ? (
          <p>
            <ExternalLink href={run} testId="admin-gate-record-link">
              Open the gate record
            </ExternalLink>
          </p>
        ) : (
          <p className="text-slate-600">No run link recorded.</p>
        )}
      </section>

      <section data-testid="admin-rollback" className="grid gap-1 text-sm">
        <h2 className="text-base font-semibold text-slate-900">
          Rollback target
        </h2>
        {release.rollbackTarget ? (
          <RollbackLine target={release.rollbackTarget} />
        ) : (
          <p className="text-slate-600">No rollback target recorded.</p>
        )}
      </section>
    </section>
  );
}

function ImageLinks({
  run,
  image,
  card = false,
}: {
  run: string | null;
  image: ReleaseImage;
  card?: boolean;
}) {
  const prefix = card ? "admin-card" : "admin";
  if (!run) {
    return <span className="text-slate-500">No run link</span>;
  }
  return (
    <span className="flex flex-wrap gap-3">
      <ExternalLink
        href={`${run}#artifacts`}
        testId={`${prefix}-sbom-${image.name}`}
      >
        SBOM
      </ExternalLink>
      <ExternalLink
        href={`${run}#artifacts`}
        testId={`${prefix}-scan-${image.name}`}
      >
        Scan
      </ExternalLink>
    </span>
  );
}

function RollbackLine({
  target,
}: {
  target: NonNullable<NonNullable<PlatformStatus["release"]>["rollbackTarget"]>;
}) {
  const record = safeUrl(target.gateRunUrl);
  const digests = target.images
    .map((image) => `${imageLabel(image.name)} …${image.digest.slice(-4)}`)
    .join(", ");
  return (
    <p data-testid="admin-rollback-line" className="text-slate-700">
      Previous signed release <strong>{target.id}</strong>
      {target.commit ? (
        <>
          {" "}
          (commit <code className="font-mono">{target.commit}</code>)
        </>
      ) : null}
      {digests ? `: ${digests}.` : "."}{" "}
      {record ? (
        <ExternalLink href={record} testId="admin-rollback-record">
          Record
        </ExternalLink>
      ) : null}
    </p>
  );
}
