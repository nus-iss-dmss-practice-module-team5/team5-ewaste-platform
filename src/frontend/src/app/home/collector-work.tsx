"use client";

import { useSession } from "@/lib/auth/session-context";
import {
  listAssignments,
  listBatches,
  newIdempotencyKey,
  recordHandoff,
  rejectAssignment,
  reportFailedPickup,
  selectAssignment,
} from "@/lib/workflow/api";
import type { Assignment, Batch } from "@/lib/workflow/types";
import { FormEvent, Fragment, useEffect, useState } from "react";
import { USE_LOCAL_COLLECTOR_MOCK } from "@/lib/workflow/local-collector-mock";
import {
  Banner,
  LoadingLine,
  bannerForError,
  formatWhen,
  toUtcIso,
} from "./workflow-ui";

type Notice = { testId: string; text: string };

function selectBlockReason(
  batch: Batch,
  collectorScopeId: string,
): string | null {
  if (!collectorScopeId) {
    return "Your session has no collector scope, so this batch cannot be selected.";
  }
  if (!batch.claimEpoch) {
    return "This batch has no claim epoch yet, so it cannot be selected.";
  }
  return null;
}

export function CollectorWork({ history = false }: { history?: boolean }) {
  const { session } = useSession();
  const scopeId = session?.user.collectorScopeId ?? "";
  const [available, setAvailable] = useState<Batch[] | null>(null);
  const [assignments, setAssignments] = useState<Assignment[] | null>(null);
  const [loadError, setLoadError] = useState<unknown>(null);
  const [pending, setPending] = useState(false);
  const [actionError, setActionError] = useState<ReturnType<
    typeof bannerForError
  > | null>(null);
  const [notice, setNotice] = useState<Notice | null>(null);
  const [selectedAssignment, setSelectedAssignment] = useState<string | null>(
    null,
  );
  const [rejectionReason, setRejectionReason] = useState("");
  const [failureReason, setFailureReason] = useState("");
  const [observedDetails, setObservedDetails] = useState("");
  const [representative, setRepresentative] = useState("");
  const [actualCount, setActualCount] = useState("");
  const [pickupAt, setPickupAt] = useState("");
  const [verificationHash, setVerificationHash] = useState("");
  const [handoffNotes, setHandoffNotes] = useState("");

  const active =
    assignments?.find((row) => row.assignmentId === selectedAssignment) ?? null;

  async function reload() {
    if (!session) {
      return;
    }
    setLoadError(null);
    setAvailable(null);
    setAssignments(null);
    try {
      const [batches, assigned] = await Promise.all([
        history
          ? Promise.resolve({ data: [] as Batch[] })
          : listBatches(session.tokens.accessToken, { status: "APPROVED" }),
        listAssignments(session.tokens.accessToken),
      ]);
      setAvailable(batches.data);
      setAssignments(assigned.data);
    } catch (error) {
      setLoadError(error);
      setAvailable([]);
      setAssignments([]);
    }
  }

  useEffect(() => {
    const timer = window.setTimeout(() => {
      void reload();
    }, 0);
    return () => window.clearTimeout(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [session?.tokens.accessToken, history]);

  function beginCommand() {
    setPending(true);
    setActionError(null);
    setNotice(null);
  }

  async function finish(task: () => Promise<void>) {
    beginCommand();
    try {
      await task();
      await reload();
    } catch (error) {
      setActionError(bannerForError(error, "collector-action"));
    } finally {
      setPending(false);
    }
  }

  async function onSelect(batch: Batch) {
    const claimEpoch = batch.claimEpoch;
    if (!session || !claimEpoch || !scopeId) {
      return;
    }
    await finish(async () => {
      const created = await selectAssignment(
        session.tokens.accessToken,
        batch.batchId,
        {
          expectedVersion: batch.version,
          claimEpoch,
          collectorScopeId: scopeId,
        },
        newIdempotencyKey(),
      );
      setNotice({
        testId: "collector-accepted",
        text: `Batch selected. Assignment ${created.assignmentId} is ${created.assignmentStatus}.`,
      });
    });
  }

  async function onReject(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!session || !active || !rejectionReason.trim()) {
      return;
    }
    await finish(async () => {
      await rejectAssignment(
        session.tokens.accessToken,
        active.assignmentId,
        active.version,
        rejectionReason,
        newIdempotencyKey(),
      );
      setNotice({
        testId: "collector-rejected",
        text: `Assignment rejected because ${rejectionReason.trim()}. The batch returns to APPROVED for another collector.`,
      });
      setRejectionReason("");
    });
  }

  async function onFail(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!session || !active || !failureReason.trim()) {
      return;
    }
    await finish(async () => {
      await reportFailedPickup(
        session.tokens.accessToken,
        active.assignmentId,
        active.version,
        { failureReason, observedDetails },
        newIdempotencyKey(),
      );
      setNotice({
        testId: "collector-failed",
        text: `Pickup failed because ${failureReason.trim()}. The batch returns to APPROVED so another collector can select it.`,
      });
      setFailureReason("");
      setObservedDetails("");
    });
  }

  async function onHandoff(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!session || !active) {
      return;
    }
    const pickupOccurredAt = toUtcIso(pickupAt);
    const actualItemCount = Number(actualCount);
    if (!pickupOccurredAt || !representative.trim()) {
      setActionError({
        testId: "collector-action-validation",
        tone: "warning",
        text: "Pickup time and the donor representative are required.",
      });
      return;
    }
    if (!Number.isInteger(actualItemCount) || actualItemCount < 0) {
      setActionError({
        testId: "collector-action-validation",
        tone: "warning",
        text: "Actual item count must be a whole number.",
      });
      return;
    }
    if (!/^[0-9a-fA-F]{64}$/.test(verificationHash.trim())) {
      setActionError({
        testId: "collector-action-validation",
        tone: "warning",
        text: "Verification hash must be 64 hexadecimal characters.",
      });
      return;
    }
    await finish(async () => {
      const updated = await recordHandoff(
        session.tokens.accessToken,
        active.assignmentId,
        active.version,
        {
          pickupOccurredAt,
          donorRepresentativeName: representative,
          actualItemCount,
          verificationHash,
          notes: handoffNotes,
        },
        newIdempotencyKey(),
      );
      setNotice({
        testId: "collector-handoff",
        text: `Handoff recorded. Assignment status is ${updated.assignmentStatus}.`,
      });
    });
  }

  const visibleAssignments = (assignments ?? []).filter((row) =>
    history
      ? row.assignmentStatus === "COMPLETED" ||
        row.assignmentStatus === "FAILED" ||
        row.assignmentStatus === "SUPERSEDED"
      : row.assignmentStatus === "ACCEPTED",
  );
  const loadBanner = loadError
    ? bannerForError(loadError, "collector-list")
    : null;

  return (
    <section
      data-testid={history ? "collector-history" : "collector-work"}
      className="max-w-4xl"
    >
      <p className="mb-4 max-w-xl text-sm text-slate-600">
        {history
          ? "Completed, failed, and superseded assignments for your collector scope."
          : "Choose an APPROVED batch. Selection creates an ACCEPTED assignment. Reject or a failed pickup returns the batch to APPROVED."}
      </p>
      {USE_LOCAL_COLLECTOR_MOCK ? (
        <div className="mb-4">
          <Banner testId="collector-local-mock" tone="info">
            Local mock data. Laptops can be selected. Monitors are stale and
            conflict. Phones have no claim epoch. Tablets are already accepted,
            so Open shows reject, failed pickup, and handoff. History has a
            completed, failed, and superseded row.
          </Banner>
        </div>
      ) : null}
      {available === null || assignments === null ? (
        <LoadingLine testId="collector-loading">
          Loading collector work…
        </LoadingLine>
      ) : null}
      {loadBanner ? (
        <Banner testId={loadBanner.testId} tone={loadBanner.tone}>
          {loadBanner.text}
        </Banner>
      ) : null}
      {notice ? (
        <Banner testId={notice.testId} tone="success">
          {notice.text}
        </Banner>
      ) : null}
      {actionError ? (
        <div className="mt-3">
          <Banner testId={actionError.testId} tone={actionError.tone}>
            {actionError.text}
          </Banner>
          <button
            type="button"
            data-testid="collector-retry"
            className="mt-2 text-sm font-medium text-teal-800"
            onClick={() => void reload()}
          >
            Refresh and retry
          </button>
        </div>
      ) : null}

      {!history && available && available.length === 0 && !loadError ? (
        <Banner testId="collector-available-empty" tone="info">
          No APPROVED batches are available for your scope.
        </Banner>
      ) : null}
      {!history && available && available.length > 0 ? (
        <table className="mt-4 w-full text-left text-sm">
          <thead className="text-slate-500">
            <tr>
              <th className="py-2 pr-3">Category</th>
              <th className="py-2 pr-3">Status</th>
              <th className="py-2 pr-3">Zone</th>
              <th className="py-2">Action</th>
            </tr>
          </thead>
          <tbody>
            {available.map((batch) => {
              const blocked = selectBlockReason(batch, scopeId);
              return (
                <tr key={batch.batchId} className="border-t border-slate-200">
                  <td className="py-2 pr-3">
                    {batch.category ?? batch.batchId}
                  </td>
                  <td className="py-2 pr-3">{batch.status}</td>
                  <td className="py-2 pr-3">{batch.zone ?? "—"}</td>
                  <td className="py-2">
                    {blocked ? (
                      <span
                        data-testid={`collector-select-blocked-${batch.batchId}`}
                      >
                        {blocked}
                      </span>
                    ) : (
                      <button
                        type="button"
                        data-testid={`collector-select-${batch.batchId}`}
                        disabled={pending}
                        className="font-medium text-teal-800 disabled:opacity-50"
                        onClick={() => void onSelect(batch)}
                      >
                        Select batch
                      </button>
                    )}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      ) : null}

      {assignments && visibleAssignments.length === 0 && !loadError ? (
        <Banner testId="collector-assignments-empty" tone="info">
          {history
            ? "No completed or failed assignments yet."
            : "No accepted assignments yet."}
        </Banner>
      ) : null}
      {history && visibleAssignments.length > 0 ? (
        <table className="mt-4 w-full table-fixed text-left text-sm">
          <thead className="text-slate-500">
            <tr>
              <th className="w-[46%] py-2 pr-3 font-medium">Batch</th>
              <th className="w-[24%] py-2 pr-3 font-medium">Status</th>
              <th className="w-[30%] py-2 font-medium">Updated</th>
            </tr>
          </thead>
          <tbody>
            {visibleAssignments.map((row) => (
              <Fragment key={row.assignmentId}>
                <tr className="border-t border-slate-200">
                  <td className="break-all py-2 pr-3">{row.batchId}</td>
                  <td className="py-2 pr-3">{row.assignmentStatus}</td>
                  <td className="py-2">{formatWhen(row.updatedAt)}</td>
                </tr>
                {row.assignmentStatus === "FAILED" ? (
                  <tr>
                    <td
                      colSpan={3}
                      data-testid={`collector-reassignment-${row.assignmentId}`}
                      className="pb-2 text-slate-600"
                    >
                      Failed pickup. The batch is APPROVED again and needs
                      another collector.
                    </td>
                  </tr>
                ) : null}
              </Fragment>
            ))}
          </tbody>
        </table>
      ) : null}
      {!history && visibleAssignments.length > 0 ? (
        <ul className="mt-4 divide-y divide-slate-200 border-y border-slate-200 text-sm">
          {visibleAssignments.map((row) => (
            <li
              key={row.assignmentId}
              className="flex items-center justify-between gap-4 py-3"
            >
              <span className="min-w-0 break-all">
                {row.batchId} · {row.assignmentStatus} ·{" "}
                {formatWhen(row.updatedAt)}
              </span>
              <button
                type="button"
                data-testid={`collector-open-${row.assignmentId}`}
                className="shrink-0 font-medium text-teal-800"
                onClick={() => setSelectedAssignment(row.assignmentId)}
              >
                Open
              </button>
            </li>
          ))}
        </ul>
      ) : null}

      {!history && active ? (
        <div
          data-testid="collector-detail"
          className="mt-6 grid max-w-xl gap-6"
        >
          <p className="text-sm text-slate-700">
            Assignment {active.assignmentId} is {active.assignmentStatus}.
            Selection already accepts the assignment.
          </p>
          <form
            onSubmit={(event) => void onReject(event)}
            className="grid gap-2"
          >
            <h3 className="font-semibold text-slate-900">Reject</h3>
            <input
              data-testid="collector-rejection-reason"
              value={rejectionReason}
              onChange={(event) => setRejectionReason(event.target.value)}
              placeholder="Rejection reason"
              className="w-full min-w-0 rounded-md border border-slate-300 px-3 py-2 text-sm"
            />
            <button
              type="submit"
              data-testid="collector-reject"
              disabled={pending}
              className="w-fit text-sm font-medium text-teal-800"
            >
              Reject assignment
            </button>
          </form>
          <form onSubmit={(event) => void onFail(event)} className="grid gap-2">
            <h3 className="font-semibold text-slate-900">Failed pickup</h3>
            <input
              data-testid="collector-failure-reason"
              value={failureReason}
              onChange={(event) => setFailureReason(event.target.value)}
              placeholder="Failure reason"
              className="w-full min-w-0 rounded-md border border-slate-300 px-3 py-2 text-sm"
            />
            <textarea
              data-testid="collector-failure-details"
              value={observedDetails}
              onChange={(event) => setObservedDetails(event.target.value)}
              placeholder="What you observed"
              className="w-full min-w-0 rounded-md border border-slate-300 px-3 py-2 text-sm"
            />
            <button
              type="submit"
              data-testid="collector-fail"
              disabled={pending}
              className="w-fit text-sm font-medium text-teal-800"
            >
              Report failed pickup
            </button>
          </form>
          <form
            onSubmit={(event) => void onHandoff(event)}
            className="grid gap-2"
          >
            <h3 className="font-semibold text-slate-900">Handoff</h3>
            <input
              data-testid="collector-pickup-at"
              type="datetime-local"
              value={pickupAt}
              onChange={(event) => setPickupAt(event.target.value)}
              className="w-full min-w-0 rounded-md border border-slate-300 px-3 py-2 text-sm"
            />
            <input
              data-testid="collector-representative"
              value={representative}
              onChange={(event) => setRepresentative(event.target.value)}
              placeholder="Donor representative"
              className="w-full min-w-0 rounded-md border border-slate-300 px-3 py-2 text-sm"
            />
            <input
              data-testid="collector-actual-count"
              type="number"
              min={0}
              value={actualCount}
              onChange={(event) => setActualCount(event.target.value)}
              placeholder="Actual item count"
              className="w-full min-w-0 rounded-md border border-slate-300 px-3 py-2 text-sm"
            />
            <input
              data-testid="collector-hash"
              value={verificationHash}
              onChange={(event) => setVerificationHash(event.target.value)}
              placeholder="64-character verification hash"
              className="w-full min-w-0 rounded-md border border-slate-300 px-3 py-2 text-sm"
            />
            <textarea
              data-testid="collector-handoff-notes"
              value={handoffNotes}
              onChange={(event) => setHandoffNotes(event.target.value)}
              placeholder="Notes"
              className="w-full min-w-0 rounded-md border border-slate-300 px-3 py-2 text-sm"
            />
            <button
              type="submit"
              data-testid="collector-handoff-submit"
              disabled={pending}
              className="w-fit rounded-md bg-teal-800 px-4 py-2 text-sm font-medium text-white disabled:opacity-50"
            >
              Record handoff
            </button>
          </form>
        </div>
      ) : null}
    </section>
  );
}
