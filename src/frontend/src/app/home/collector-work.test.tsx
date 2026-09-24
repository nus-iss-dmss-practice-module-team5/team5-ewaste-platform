import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { WorkflowError } from "@/lib/workflow/errors";
import type { Assignment, Batch } from "@/lib/workflow/types";
import { CollectorWork } from "./collector-work";

const listBatches = vi.fn();
const listAssignments = vi.fn();
const selectAssignment = vi.fn();
const rejectAssignment = vi.fn();
const recordHandoff = vi.fn();
const reportFailedPickup = vi.fn();
const newIdempotencyKey = vi.fn();

vi.mock("@/lib/auth/session-context", () => ({
  useSession: () => ({
    session: {
      tokens: { accessToken: "access-token" },
      user: { collectorScopeId: "9f6d5c3a-37e1-4e0e-a5f6-0f7f4e2b2c99" },
    },
  }),
}));

vi.mock("@/lib/workflow/api", () => ({
  listBatches: (...args: unknown[]) => listBatches(...args),
  listAssignments: (...args: unknown[]) => listAssignments(...args),
  selectAssignment: (...args: unknown[]) => selectAssignment(...args),
  rejectAssignment: (...args: unknown[]) => rejectAssignment(...args),
  recordHandoff: (...args: unknown[]) => recordHandoff(...args),
  reportFailedPickup: (...args: unknown[]) => reportFailedPickup(...args),
  newIdempotencyKey: () => newIdempotencyKey(),
}));

const approved: Batch = {
  batchId: "batch-1",
  status: "APPROVED",
  version: 4,
  category: "laptops",
  zone: "central",
  claimEpoch: "1",
};

const accepted: Assignment = {
  assignmentId: "asg-1",
  batchId: "batch-1",
  assignmentStatus: "ACCEPTED",
  assignmentSequence: 1,
  version: 1,
};

function page<T>(data: T[]) {
  return {
    data,
    page: 1,
    pageSize: 20,
    totalCount: data.length,
    correlationId: "c",
  };
}

describe("collector work", () => {
  beforeEach(() => {
    listBatches.mockReset();
    listAssignments.mockReset();
    selectAssignment.mockReset();
    rejectAssignment.mockReset();
    recordHandoff.mockReset();
    reportFailedPickup.mockReset();
    newIdempotencyKey.mockReset();
    newIdempotencyKey.mockReturnValue("idem-collector");
    listBatches.mockResolvedValue(page([approved]));
    listAssignments.mockResolvedValue(page([accepted]));
  });

  it("selects an approved batch into an accepted assignment", async () => {
    const user = userEvent.setup();
    selectAssignment.mockResolvedValue({
      ...accepted,
      assignmentStatus: "ACCEPTED",
    });
    render(<CollectorWork />);
    await user.click(await screen.findByTestId("collector-select-batch-1"));
    expect(selectAssignment).toHaveBeenCalledWith(
      "access-token",
      "batch-1",
      {
        expectedVersion: 4,
        claimEpoch: "1",
        collectorScopeId: "9f6d5c3a-37e1-4e0e-a5f6-0f7f4e2b2c99",
      },
      "idem-collector",
    );
    expect(await screen.findByTestId("collector-accepted")).toHaveTextContent(
      "ACCEPTED",
    );
  });

  it("reuses the idempotency key when the same selection is retried", async () => {
    const user = userEvent.setup();
    newIdempotencyKey
      .mockReturnValueOnce("idem-1")
      .mockReturnValueOnce("idem-2");
    selectAssignment
      .mockRejectedValueOnce(
        new WorkflowError("offline", "network", "NETWORK", "c"),
      )
      .mockResolvedValueOnce(accepted)
      .mockResolvedValueOnce(accepted);
    const keysSent = () => selectAssignment.mock.calls.map((call) => call[3]);
    render(<CollectorWork />);

    await user.click(await screen.findByTestId("collector-select-batch-1"));
    await screen.findByTestId("collector-action-network");
    await user.click(await screen.findByTestId("collector-select-batch-1"));
    await screen.findByTestId("collector-accepted");
    expect(keysSent()).toEqual(["idem-1", "idem-1"]);

    await user.click(await screen.findByTestId("collector-select-batch-1"));
    await waitFor(() => expect(keysSent()[2]).toBe("idem-2"));
  });

  it("uses a new idempotency key when the handoff payload changes", async () => {
    const user = userEvent.setup();
    newIdempotencyKey
      .mockReturnValueOnce("idem-1")
      .mockReturnValueOnce("idem-2");
    recordHandoff.mockRejectedValue(
      new WorkflowError("offline", "network", "NETWORK", "c"),
    );
    const keysSent = () => recordHandoff.mock.calls.map((call) => call[4]);
    render(<CollectorWork />);
    await user.click(await screen.findByTestId("collector-open-asg-1"));
    await user.type(
      screen.getByTestId("collector-pickup-at"),
      "2026-09-23T10:00",
    );
    await user.type(
      screen.getByTestId("collector-representative"),
      "Representative",
    );
    await user.type(screen.getByTestId("collector-actual-count"), "10");
    await user.type(screen.getByTestId("collector-hash"), "a".repeat(64));

    await user.click(screen.getByTestId("collector-handoff-submit"));
    await waitFor(() => expect(keysSent()).toEqual(["idem-1"]));
    await user.click(screen.getByTestId("collector-handoff-submit"));
    await waitFor(() => expect(keysSent()).toEqual(["idem-1", "idem-1"]));

    await user.clear(screen.getByTestId("collector-actual-count"));
    await user.type(screen.getByTestId("collector-actual-count"), "9");
    await user.click(screen.getByTestId("collector-handoff-submit"));
    await waitFor(() =>
      expect(keysSent()).toEqual(["idem-1", "idem-1", "idem-2"]),
    );
  });

  it("does not offer legacy accept for an accepted assignment", async () => {
    const user = userEvent.setup();
    render(<CollectorWork />);
    await user.click(await screen.findByTestId("collector-open-asg-1"));
    expect(
      screen.queryByRole("button", { name: /accept/i }),
    ).not.toBeInTheDocument();
  });

  it("explains that a failed pickup returns the batch to APPROVED", async () => {
    const user = userEvent.setup();
    reportFailedPickup.mockResolvedValue({
      ...accepted,
      assignmentStatus: "FAILED",
      version: 2,
    });
    render(<CollectorWork />);
    await user.click(await screen.findByTestId("collector-open-asg-1"));
    await user.selectOptions(
      screen.getByTestId("collector-failure-reason"),
      "DONOR_UNAVAILABLE",
    );
    await user.click(screen.getByTestId("collector-fail"));
    expect(await screen.findByTestId("collector-failed")).toHaveTextContent(
      "Donor unavailable. The batch returns to APPROVED",
    );
    expect(reportFailedPickup).toHaveBeenCalledWith(
      "access-token",
      "asg-1",
      1,
      { failureReason: "DONOR_UNAVAILABLE", observedDetails: "" },
      "idem-collector",
    );
  });

  it("offers only the backend failure reasons", async () => {
    const user = userEvent.setup();
    render(<CollectorWork />);
    await user.click(await screen.findByTestId("collector-open-asg-1"));
    const options = Array.from(
      screen.getByTestId("collector-failure-reason").querySelectorAll("option"),
    ).map((option) => option.value);
    expect(options).toEqual([
      "",
      "DONOR_UNAVAILABLE",
      "INCORRECT_ITEMS",
      "ACCESS_DENIED",
      "DAMAGED_HAZARDOUS",
      "SAFETY_CANCEL",
    ]);
  });

  it("requires a failure reason before reporting a failed pickup", async () => {
    const user = userEvent.setup();
    render(<CollectorWork />);
    await user.click(await screen.findByTestId("collector-open-asg-1"));
    await user.click(screen.getByTestId("collector-fail"));
    expect(
      await screen.findByTestId("collector-action-validation"),
    ).toHaveTextContent("Choose a failure reason");
    expect(reportFailedPickup).not.toHaveBeenCalled();
  });

  async function fillHandoff(
    user: ReturnType<typeof userEvent.setup>,
    count: string,
  ) {
    await user.click(await screen.findByTestId("collector-open-asg-1"));
    await user.type(
      screen.getByTestId("collector-pickup-at"),
      "2026-09-23T10:00",
    );
    await user.type(
      screen.getByTestId("collector-representative"),
      "Representative",
    );
    if (count) {
      await user.type(screen.getByTestId("collector-actual-count"), count);
    }
    await user.type(screen.getByTestId("collector-hash"), "a".repeat(64));
    await user.click(screen.getByTestId("collector-handoff-submit"));
  }

  it("rejects an empty actual item count before calling handoff", async () => {
    const user = userEvent.setup();
    render(<CollectorWork />);
    await fillHandoff(user, "");
    expect(
      await screen.findByTestId("collector-action-validation"),
    ).toHaveTextContent("from 1 to 100000");
    expect(recordHandoff).not.toHaveBeenCalled();
  });

  it("blocks a zero actual item count before calling handoff", async () => {
    const user = userEvent.setup();
    render(<CollectorWork />);
    await fillHandoff(user, "0");
    const count = screen.getByTestId(
      "collector-actual-count",
    ) as HTMLInputElement;
    expect(count.validity.rangeUnderflow).toBe(true);
    expect(recordHandoff).not.toHaveBeenCalled();
  });

  it("keeps conflict and network failures recoverable", async () => {
    const user = userEvent.setup();
    selectAssignment.mockRejectedValue(
      new WorkflowError("changed", "conflict", "STALE_VERSION", "c", 409),
    );
    render(<CollectorWork />);
    await user.click(await screen.findByTestId("collector-select-batch-1"));
    expect(
      await screen.findByTestId("collector-action-conflict"),
    ).toBeInTheDocument();
    expect(screen.getByTestId("collector-retry")).toBeInTheDocument();
  });

  it("rejects a short verification hash before calling handoff", async () => {
    const user = userEvent.setup();
    render(<CollectorWork />);
    await user.click(await screen.findByTestId("collector-open-asg-1"));
    await user.type(
      screen.getByTestId("collector-pickup-at"),
      "2026-09-23T10:00",
    );
    await user.type(
      screen.getByTestId("collector-representative"),
      "Representative",
    );
    await user.type(screen.getByTestId("collector-actual-count"), "10");
    await user.type(screen.getByTestId("collector-hash"), "abcd");
    await user.click(screen.getByTestId("collector-handoff-submit"));
    expect(
      await screen.findByTestId("collector-action-validation"),
    ).toHaveTextContent("64 hexadecimal");
    expect(recordHandoff).not.toHaveBeenCalled();
  });

  it("shows failed history as approved for another collector", async () => {
    listAssignments.mockResolvedValue(
      page([{ ...accepted, assignmentStatus: "FAILED" }]),
    );
    render(<CollectorWork history />);
    expect(
      await screen.findByTestId("collector-reassignment-asg-1"),
    ).toHaveTextContent("APPROVED again");
  });

  it("shows a forbidden state for another collector scope", async () => {
    listBatches.mockRejectedValue(
      new WorkflowError("denied", "forbidden", "FORBIDDEN", "c", 403),
    );
    render(<CollectorWork />);
    expect(
      await screen.findByTestId("collector-list-forbidden"),
    ).toHaveTextContent("organisation");
  });
});
