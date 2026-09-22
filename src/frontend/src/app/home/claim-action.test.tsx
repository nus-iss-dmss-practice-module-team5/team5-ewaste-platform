import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { WorkflowError } from "@/lib/workflow/errors";
import type { Opportunity } from "@/lib/workflow/types";
import { ClaimAction } from "./claim-action";

const listOpportunities = vi.fn();
const claimOpportunity = vi.fn();

vi.mock("@/lib/auth/session-context", () => ({
  useSession: () => ({ session: { tokens: { accessToken: "access-token" } } }),
}));

vi.mock("@/lib/workflow/api", () => ({
  listOpportunities: (...args: unknown[]) => listOpportunities(...args),
  claimOpportunity: (...args: unknown[]) => claimOpportunity(...args),
  newIdempotencyKey: () => "idem-claim",
}));

const ready: Opportunity = {
  batchId: "batch-1",
  status: "MATCHED",
  category: "laptops",
  quantity: 10,
  zone: "central",
  collectionDeadline: "2026-09-23T02:00:00.000Z",
  eligibilityReason: "Eligible",
  version: 3,
  claimEpoch: "1",
};

describe("claim action", () => {
  beforeEach(() => {
    listOpportunities.mockReset();
    claimOpportunity.mockReset();
    listOpportunities.mockResolvedValue({
      data: [ready],
      page: 1,
      pageSize: 20,
      totalCount: 1,
      correlationId: "c",
    });
  });

  it("does not report success before the API responds", async () => {
    const user = userEvent.setup();
    let resolveClaim: (value: unknown) => void = () => undefined;
    claimOpportunity.mockImplementation(
      () =>
        new Promise((resolve) => {
          resolveClaim = resolve;
        }),
    );
    render(<ClaimAction />);
    await user.click(await screen.findByTestId("claim-select-batch-1"));
    await user.click(screen.getByTestId("claim-submit"));
    expect(screen.getByTestId("claim-pending")).toHaveTextContent("Claim in progress");
    expect(screen.queryByTestId("claim-success")).not.toBeInTheDocument();
    resolveClaim({
      batchId: "batch-1",
      status: "APPROVED",
      version: 4,
      claimEpoch: "1",
      claimId: "claim-1",
      reservationId: "res-1",
      correlationId: "corr-claim",
    });
    expect(await screen.findByTestId("claim-success")).toHaveTextContent("Claim confirmed");
    expect(claimOpportunity).toHaveBeenCalledWith(
      "access-token",
      "batch-1",
      { expectedVersion: 3, claimEpoch: "1", notes: "" },
      "idem-claim",
    );
  });

  it("blocks a claim that has no version", async () => {
    const user = userEvent.setup();
    listOpportunities.mockResolvedValue({
      data: [{ ...ready, version: undefined, claimEpoch: undefined }],
      page: 1,
      pageSize: 20,
      totalCount: 1,
      correlationId: "c",
    });
    render(<ClaimAction />);
    await user.click(await screen.findByTestId("claim-select-batch-1"));
    expect(screen.getByTestId("claim-blocked")).toHaveTextContent("no claim version");
    expect(screen.queryByTestId("claim-submit")).not.toBeInTheDocument();
  });

  it("shows conflict, expired, duplicate, and network states", async () => {
    const user = userEvent.setup();
    const cases: Array<[WorkflowError, string]> = [
      [new WorkflowError("changed", "conflict", "STALE_VERSION", "c", 409), "claim-conflict"],
      [new WorkflowError("gone", "not_found", "NOT_FOUND", "c", 404), "claim-not_found"],
      [new WorkflowError("already sent", "duplicate", "DUPLICATE_CLAIM", "c", 409), "claim-duplicate"],
      [new WorkflowError("offline", "network", "NETWORK", "corr-network"), "claim-network"],
    ];
    for (const [error, testId] of cases) {
      claimOpportunity.mockRejectedValueOnce(error);
      const view = render(<ClaimAction />);
      await user.click(await screen.findByTestId("claim-select-batch-1"));
      await user.click(screen.getByTestId("claim-submit"));
      expect(await screen.findByTestId(testId)).toBeInTheDocument();
      expect(screen.queryByTestId("claim-success")).not.toBeInTheDocument();
      view.unmount();
    }
    expect(claimOpportunity).toHaveBeenCalled();
    await waitFor(() => expect(claimOpportunity.mock.calls.length).toBe(4));
  });
});
