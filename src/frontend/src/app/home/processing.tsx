"use client";

import { useSession } from "@/lib/auth/session-context";
import {
  getProcessingBatch,
  listProcessingBatches,
  newIdempotencyKey,
  recordTreatment,
  verifyReceipt,
} from "@/lib/workflow/api";
import { formatKg, parseKg } from "@/lib/workflow/kg";
import { USE_LOCAL_PROCESSING_MOCK } from "@/lib/workflow/local-processing-mock";
import {
  EWASTE_CATEGORIES,
  type EwasteCategory,
  type ProcessingBatch,
} from "@/lib/workflow/types";
import { FormEvent, useEffect, useRef, useState } from "react";
import { Banner, LoadingLine, bannerForError } from "./workflow-ui";

type Notice = { testId: string; text: string };

const MAX_ITEM_COUNT = 100000;
// Receipt weight bounds in hundredths of a kilogram: 0.10 to 50000.00.
const MIN_RECEIPT_KG = 10;
const MAX_RECEIPT_KG = 5000000;
const INPUT_CLASS =
  "w-full min-w-0 rounded-md border border-slate-300 px-3 py-2 text-sm";

// Kept until the command succeeds or its payload changes, so retrying after a
// timeout replays the same command instead of sending a new one.
function useRetryKey() {
  const attempt = useRef<{ fingerprint: string; key: string } | null>(null);
  return {
    keyFor(fingerprint: string): string {
      if (attempt.current?.fingerprint !== fingerprint) {
        attempt.current = { fingerprint, key: newIdempotencyKey() };
      }
      return attempt.current.key;
    },
    clear() {
      attempt.current = null;
    },
  };
}

function kg(value?: string | null): string {
  return value ? `${value} kg` : "—";
}

function signed(delta: number, format: (value: number) => string): string {
  return `${delta > 0 ? "+" : "−"}${format(Math.abs(delta))}`;
}

// A difference from the declaration is saved with the receipt. It is shown
// before submitting so it is not mistaken for a validation error.
function receiptDifferences(
  batch: ProcessingBatch,
  category: string,
  count: string,
  weight: string,
): string[] {
  const differences: string[] = [];
  if (category && batch.category && category !== batch.category) {
    differences.push(`category ${category} instead of ${batch.category}`);
  }
  if (/^\d+$/.test(count) && batch.quantity !== undefined) {
    const delta = Number(count) - batch.quantity;
    if (delta !== 0) {
      differences.push(`${signed(delta, String)} items`);
    }
  }
  const received = parseKg(weight);
  const declared = parseKg(batch.estimatedWeightKg ?? "");
  if (received !== null && declared !== null && received !== declared) {
    differences.push(`${signed(received - declared, formatKg)} kg`);
  }
  return differences;
}

export function ProcessingWork() {
  const { session } = useSession();
  const [rows, setRows] = useState<ProcessingBatch[] | null>(null);
  const [detail, setDetail] = useState<ProcessingBatch | null>(null);
  const [loadError, setLoadError] = useState<unknown>(null);
  const [pending, setPending] = useState(false);
  const [actionError, setActionError] = useState<ReturnType<
    typeof bannerForError
  > | null>(null);
  const [notice, setNotice] = useState<Notice | null>(null);
  const [actualCategory, setActualCategory] = useState<EwasteCategory | "">("");
  const [actualCount, setActualCount] = useState("");
  const [actualWeight, setActualWeight] = useState("");
  const [reused, setReused] = useState("");
  const [recycled, setRecycled] = useState("");
  const [disposed, setDisposed] = useState("");
  const receiptKey = useRetryKey();
  const treatmentKey = useRetryKey();

  async function reload(batchId: string | null = detail?.batchId ?? null) {
    if (!session) {
      return;
    }
    setLoadError(null);
    setRows(null);
    try {
      const [list, opened] = await Promise.all([
        listProcessingBatches(session.tokens.accessToken),
        batchId
          ? getProcessingBatch(session.tokens.accessToken, batchId)
          : Promise.resolve(null),
      ]);
      setRows(list.data);
      setDetail(opened);
    } catch (error) {
      setLoadError(error);
      setRows([]);
      setDetail(null);
    }
  }

  useEffect(() => {
    const timer = window.setTimeout(() => {
      void reload();
    }, 0);
    return () => window.clearTimeout(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [session?.tokens.accessToken]);

  function invalid(text: string) {
    setActionError({
      testId: "processing-action-validation",
      tone: "warning",
      text,
    });
  }

  async function finish(task: () => Promise<void>) {
    setPending(true);
    setActionError(null);
    setNotice(null);
    try {
      await task();
    } catch (error) {
      setActionError(bannerForError(error, "processing-action"));
    } finally {
      setPending(false);
    }
  }

  async function onOpen(batchId: string) {
    if (!session) {
      return;
    }
    setActualCategory("");
    setActualCount("");
    setActualWeight("");
    setReused("");
    setRecycled("");
    setDisposed("");
    await finish(async () => {
      setDetail(await getProcessingBatch(session.tokens.accessToken, batchId));
    });
  }

  async function onReceipt(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!session || !detail) {
      return;
    }
    if (!actualCategory) {
      invalid("Choose the received category.");
      return;
    }
    const actualItemCount = Number(actualCount);
    if (
      !/^\d+$/.test(actualCount.trim()) ||
      actualItemCount < 1 ||
      actualItemCount > MAX_ITEM_COUNT
    ) {
      invalid(`Item count must be a whole number from 1 to ${MAX_ITEM_COUNT}.`);
      return;
    }
    const weight = parseKg(actualWeight);
    if (weight === null) {
      invalid(
        "Received weight must be in kilograms with at most two decimal places.",
      );
      return;
    }
    if (weight < MIN_RECEIPT_KG || weight > MAX_RECEIPT_KG) {
      invalid("Received weight must be from 0.10 to 50000.00 kg.");
      return;
    }
    const command = {
      actualCategory,
      actualItemCount,
      actualWeightKg: formatKg(weight),
    };
    await finish(async () => {
      const result = await verifyReceipt(
        session.tokens.accessToken,
        detail.batchId,
        detail.version,
        command,
        receiptKey.keyFor(
          JSON.stringify([detail.batchId, detail.version, command]),
        ),
      );
      receiptKey.clear();
      setNotice({
        testId: "processing-verified",
        text: `Receipt saved. The batch is ${result.status}.`,
      });
      await reload();
    });
  }

  async function onTreatment(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!session || !detail?.receipt) {
      return;
    }
    const entered = [reused, recycled, disposed].map((value) => value.trim());
    const filled = entered.filter(Boolean).length;
    if (filled !== 0 && filled !== 3) {
      invalid(
        "Enter all three weights, including 0.00, or leave all three blank.",
      );
      return;
    }
    const amounts = entered.map(parseKg);
    if (filled === 3 && amounts.some((amount) => amount === null)) {
      invalid("Weights must be in kilograms with at most two decimal places.");
      return;
    }
    const received = parseKg(detail.receipt.actualWeightKg) ?? 0;
    const total = amounts.reduce<number>(
      (sum, amount) => sum + (amount ?? 0),
      0,
    );
    if (total > received) {
      invalid(
        `Reused, recycled and disposed weight together cannot exceed the ${detail.receipt.actualWeightKg} kg received.`,
      );
      return;
    }
    const command =
      filled === 3
        ? {
            amounts: {
              reusedKg: formatKg(amounts[0] ?? 0),
              recycledKg: formatKg(amounts[1] ?? 0),
              disposedKg: formatKg(amounts[2] ?? 0),
            },
          }
        : {};
    await finish(async () => {
      const result = await recordTreatment(
        session.tokens.accessToken,
        detail.batchId,
        detail.version,
        command,
        treatmentKey.keyFor(
          JSON.stringify([detail.batchId, detail.version, command]),
        ),
      );
      treatmentKey.clear();
      setNotice({
        testId: "processing-recycled",
        text: `Treatment recorded. The batch is ${result.status}. This does not finish the batch.`,
      });
      await reload();
    });
  }

  const loadBanner = loadError
    ? bannerForError(loadError, "processing-list")
    : null;
  const differences =
    detail?.status === "COLLECTED"
      ? receiptDifferences(detail, actualCategory, actualCount, actualWeight)
      : [];
  const treatmentPreview =
    detail?.status === "VERIFIED" && detail.receipt
      ? previewTreatment(detail.receipt.actualWeightKg, [
          reused,
          recycled,
          disposed,
        ])
      : null;

  return (
    <section data-testid="processing-work" className="max-w-4xl">
      <p className="mb-4 max-w-xl text-sm text-slate-600">
        Open a COLLECTED batch to record what arrived. Then record how the
        received weight was reused, recycled and disposed.
      </p>
      {USE_LOCAL_PROCESSING_MOCK ? (
        <div className="mb-4">
          <Banner testId="processing-local-mock" tone="info">
            Local mock data. ICT equipment can be verified and then treated.
            Large appliances are stale and conflict. Batteries are forbidden.
            The second ICT batch is already VERIFIED, and consumer electronics
            are already RECYCLED.
          </Banner>
        </div>
      ) : null}
      {rows === null ? (
        <LoadingLine testId="processing-loading">
          Loading facility batches…
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
            data-testid="processing-retry"
            className="mt-2 text-sm font-medium text-teal-800"
            onClick={() => void reload()}
          >
            Refresh and retry
          </button>
        </div>
      ) : null}

      {rows && rows.length === 0 && !loadError ? (
        <Banner testId="processing-empty" tone="info">
          No collected batches are waiting at your facility.
        </Banner>
      ) : null}
      {rows && rows.length > 0 ? (
        <div className="mt-4 overflow-x-auto">
          <table className="w-full text-left text-sm">
            <thead className="text-slate-500">
              <tr>
                <th className="py-2 pr-3">Category</th>
                <th className="py-2 pr-3">Status</th>
                <th className="py-2 pr-3">Declared</th>
                <th className="py-2">Action</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => (
                <tr key={row.batchId} className="border-t border-slate-200">
                  <td className="py-2 pr-3">{row.category ?? row.batchId}</td>
                  <td className="py-2 pr-3">{row.status}</td>
                  <td className="py-2 pr-3">
                    {row.quantity ?? "—"} items · {kg(row.estimatedWeightKg)}
                  </td>
                  <td className="py-2">
                    <button
                      type="button"
                      data-testid={`processing-open-${row.batchId}`}
                      disabled={pending}
                      className="font-medium text-teal-800 disabled:opacity-50"
                      onClick={() => void onOpen(row.batchId)}
                    >
                      Open
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : null}

      {detail ? (
        <div data-testid="processing-detail" className="mt-6 grid gap-6">
          <p className="break-all text-sm text-slate-700">
            Batch {detail.batchId} is {detail.status}.
          </p>
          <div className="overflow-x-auto">
            <table
              data-testid="processing-comparison"
              className="w-full max-w-xl text-left text-sm"
            >
              <thead className="text-slate-500">
                <tr>
                  <th className="py-2 pr-3" />
                  <th className="py-2 pr-3">Category</th>
                  <th className="py-2 pr-3">Item count</th>
                  <th className="py-2">Weight</th>
                </tr>
              </thead>
              <tbody>
                <tr className="border-t border-slate-200">
                  <th className="py-2 pr-3 font-medium">Declared</th>
                  <td className="py-2 pr-3">{detail.category ?? "—"}</td>
                  <td className="py-2 pr-3">{detail.quantity ?? "—"}</td>
                  <td className="py-2">{kg(detail.estimatedWeightKg)}</td>
                </tr>
                <tr className="border-t border-slate-200">
                  <th className="py-2 pr-3 font-medium">Received</th>
                  <td className="py-2 pr-3">
                    {detail.receipt?.actualCategory ?? "—"}
                  </td>
                  <td className="py-2 pr-3">
                    {detail.receipt?.actualItemCount ?? "—"}
                  </td>
                  <td className="py-2">{kg(detail.receipt?.actualWeightKg)}</td>
                </tr>
              </tbody>
            </table>
          </div>

          {detail.status === "COLLECTED" ? (
            <form
              onSubmit={(event) => void onReceipt(event)}
              className="grid max-w-xl gap-3"
            >
              <h3 className="font-semibold text-slate-900">Verify receipt</h3>
              <div className="grid gap-3 sm:grid-cols-3">
                <label className="grid gap-1 text-sm text-slate-700">
                  Received category
                  <select
                    data-testid="processing-actual-category"
                    value={actualCategory}
                    onChange={(event) =>
                      setActualCategory(
                        event.target.value as EwasteCategory | "",
                      )
                    }
                    className={INPUT_CLASS}
                  >
                    <option value="">Choose a category</option>
                    {EWASTE_CATEGORIES.map((category) => (
                      <option key={category} value={category}>
                        {category}
                      </option>
                    ))}
                  </select>
                </label>
                <label className="grid gap-1 text-sm text-slate-700">
                  Received item count
                  <input
                    data-testid="processing-actual-count"
                    inputMode="numeric"
                    value={actualCount}
                    onChange={(event) => setActualCount(event.target.value)}
                    className={INPUT_CLASS}
                  />
                </label>
                <label className="grid gap-1 text-sm text-slate-700">
                  Received weight (kg)
                  <input
                    data-testid="processing-actual-weight"
                    inputMode="decimal"
                    value={actualWeight}
                    onChange={(event) => setActualWeight(event.target.value)}
                    placeholder="0.00"
                    className={INPUT_CLASS}
                  />
                </label>
              </div>
              {differences.length > 0 ? (
                <Banner testId="processing-receipt-difference" tone="warning">
                  Received differs from the declaration:{" "}
                  {differences.join(", ")}. The difference is saved with the
                  receipt and will be flagged. It is not an error.
                </Banner>
              ) : null}
              <button
                type="submit"
                data-testid="processing-receipt-submit"
                disabled={pending}
                className="w-fit rounded-md bg-teal-800 px-4 py-2 text-sm font-medium text-white disabled:opacity-50"
              >
                {pending ? "Saving…" : "Confirm receipt"}
              </button>
            </form>
          ) : null}

          {detail.status === "VERIFIED" && detail.receipt ? (
            <form
              onSubmit={(event) => void onTreatment(event)}
              className="grid max-w-xl gap-3"
            >
              <h3 className="font-semibold text-slate-900">Record treatment</h3>
              <p className="text-sm text-slate-600">
                Enter all three weights, including 0.00, or leave all three
                blank.
              </p>
              <div className="grid gap-3 sm:grid-cols-3">
                <label className="grid gap-1 text-sm text-slate-700">
                  Reused (kg)
                  <input
                    data-testid="processing-reused"
                    inputMode="decimal"
                    value={reused}
                    onChange={(event) => setReused(event.target.value)}
                    className={INPUT_CLASS}
                  />
                </label>
                <label className="grid gap-1 text-sm text-slate-700">
                  Recycled (kg)
                  <input
                    data-testid="processing-recycled-kg"
                    inputMode="decimal"
                    value={recycled}
                    onChange={(event) => setRecycled(event.target.value)}
                    className={INPUT_CLASS}
                  />
                </label>
                <label className="grid gap-1 text-sm text-slate-700">
                  Disposed (kg)
                  <input
                    data-testid="processing-disposed"
                    inputMode="decimal"
                    value={disposed}
                    onChange={(event) => setDisposed(event.target.value)}
                    className={INPUT_CLASS}
                  />
                </label>
              </div>
              {treatmentPreview ? (
                <Banner testId="processing-treatment-preview" tone="info">
                  {treatmentPreview}
                </Banner>
              ) : null}
              <button
                type="submit"
                data-testid="processing-treatment-submit"
                disabled={pending}
                className="w-fit rounded-md bg-teal-800 px-4 py-2 text-sm font-medium text-white disabled:opacity-50"
              >
                {pending ? "Saving…" : "Record treatment"}
              </button>
            </form>
          ) : null}

          {detail.treatment ? (
            <dl
              data-testid="processing-treatment"
              className="grid max-w-xl grid-cols-2 gap-x-6 gap-y-2 text-sm sm:grid-cols-3"
            >
              {[
                ["Reused", outcome(detail.treatment.reusedKg)],
                ["Recycled", outcome(detail.treatment.recycledKg)],
                ["Disposed", outcome(detail.treatment.disposedKg)],
                ["Unknown", kg(detail.treatment.unknownKg)],
                ["Data quality", detail.treatment.dataQuality ?? "—"],
              ].map(([label, value]) => (
                <div key={label}>
                  <dt className="text-slate-500">{label}</dt>
                  <dd className="text-slate-900">{value}</dd>
                </div>
              ))}
            </dl>
          ) : null}
        </div>
      ) : null}
    </section>
  );
}

// A null amount is an outcome that was never recorded. It is not zero.
function outcome(value: string | null): string {
  return value === null ? "Not recorded" : `${value} kg`;
}

function previewTreatment(
  receivedKg: string,
  entered: string[],
): string | null {
  const values = entered.map((value) => value.trim());
  if (values.every((value) => !value)) {
    return `No weights entered. The whole ${receivedKg} kg will be saved as unknown and the outcome flagged as missing.`;
  }
  const amounts = values.map(parseKg);
  const received = parseKg(receivedKg);
  if (received === null || amounts.some((amount) => amount === null)) {
    return null;
  }
  const total = amounts.reduce<number>((sum, amount) => sum + (amount ?? 0), 0);
  if (total > received) {
    return null;
  }
  const unknown = received - total;
  return unknown === 0
    ? `All ${receivedKg} kg is allocated.`
    : `${formatKg(total)} of ${receivedKg} kg is allocated. The remaining ${formatKg(unknown)} kg will be saved as unknown and flagged.`;
}
