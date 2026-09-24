import { AxiosError, AxiosHeaders } from "axios";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { api } from "@/lib/auth/api-client";
import {
  claimOpportunity,
  createBatchDraft,
  draftBody,
  listBatches,
  listOpportunities,
  reportFailedPickup,
  selectAssignment,
  submitBatch,
} from "./api";

vi.mock("@/lib/auth/api-client", () => ({
  api: {
    get: vi.fn(),
    post: vi.fn(),
    patch: vi.fn(),
  },
}));

const get = vi.mocked(api.get);
const post = vi.mocked(api.post);

function axiosError(status: number | undefined, data?: unknown) {
  if (status === undefined) {
    return new AxiosError("network");
  }
  return new AxiosError("request failed", undefined, undefined, undefined, {
    status,
    statusText: "Error",
    data,
    headers: new AxiosHeaders(),
    config: { headers: new AxiosHeaders() },
  });
}

const batch = {
  batch_id: "batch-1",
  status: "DRAFT",
  version: 2,
  category: "laptops",
};

describe("workflow api", () => {
  beforeEach(() => {
    get.mockReset();
    post.mockReset();
  });

  it("sends snake_case draft fields and no version in the body", async () => {
    post.mockResolvedValue({
      data: { data: batch, correlationId: "corr-1" },
    });

    await createBatchDraft(
      "token",
      {
        category: " laptops ",
        quantity: 10,
        estimatedWeightKg: 25.5,
        conditionRating: " reusable ",
        isDataBearing: true,
        zone: " central ",
        collectionDeadline: "2026-09-23T02:00:00.000Z",
        notes: "  ",
      },
      "idem-1",
    );

    const body = post.mock.calls[0]?.[1] as Record<string, unknown>;
    expect(body).toEqual({
      category: "laptops",
      quantity: 10,
      estimated_weight_kg: 25.5,
      condition_rating: "reusable",
      is_data_bearing: true,
      zone: "central",
      collection_deadline: "2026-09-23T02:00:00.000Z",
    });
    expect(body).not.toHaveProperty("version");
    expect(body).not.toHaveProperty("notes");
    expect(post.mock.calls[0]?.[2]).toEqual({
      headers: {
        Authorization: "Bearer token",
        "Idempotency-Key": "idem-1",
      },
    });
  });

  it("submits with If-Match-Version and an empty body", async () => {
    post.mockResolvedValue({
      data: {
        data: { ...batch, status: "SUBMITTED", version: 3 },
        correlationId: "corr-2",
      },
    });

    const submitted = await submitBatch("token", "batch-1", 2, "idem-submit");

    expect(submitted.status).toBe("SUBMITTED");
    expect(post).toHaveBeenCalledWith(
      "/api/v1/batches/batch-1/submit",
      undefined,
      {
        headers: {
          Authorization: "Bearer token",
          "Idempotency-Key": "idem-submit",
          "If-Match-Version": "2",
        },
      },
    );
  });

  it("lists batches with page_size and maps snake_case fields", async () => {
    get.mockResolvedValue({
      data: {
        data: [batch],
        page: 1,
        page_size: 20,
        total_count: 1,
        correlation_id: "corr-list",
      },
    });

    const page = await listBatches("token", { status: "DRAFT" });

    expect(page.data[0]?.batchId).toBe("batch-1");
    expect(get).toHaveBeenCalledWith("/api/v1/batches", {
      headers: { Authorization: "Bearer token" },
      params: { page: 1, page_size: 20, status: "DRAFT" },
    });
  });

  it("lists opportunities with page_size and maps snake_case fields", async () => {
    get.mockResolvedValue({
      data: {
        data: [
          {
            batch_id: "batch-1",
            status: "MATCHED",
            category: "laptops",
            quantity: 10,
            estimated_weight_kg: 25.5,
            zone: "central",
            collection_deadline: "2026-09-23T02:00:00.000Z",
            eligibility_reason: "Zone and category match.",
          },
        ],
        page: 1,
        page_size: 20,
        total_count: 1,
        correlation_id: "corr-opp",
      },
    });

    const page = await listOpportunities("token");

    expect(page.data[0]).toMatchObject({
      batchId: "batch-1",
      estimatedWeightKg: 25.5,
      collectionDeadline: "2026-09-23T02:00:00.000Z",
      eligibilityReason: "Zone and category match.",
    });
    expect(page.correlationId).toBe("corr-opp");
    expect(get).toHaveBeenCalledWith("/api/v1/opportunities", {
      headers: { Authorization: "Bearer token" },
      params: { page: 1, page_size: 20 },
    });
  });

  it("claims with the version header and expected_version body", async () => {
    post.mockResolvedValue({
      data: {
        data: {
          batch_id: "batch-1",
          status: "APPROVED",
          version: 4,
          claim_epoch: "1",
          claim_id: "claim-1",
          reservation_id: "res-1",
          correlation_id: "corr-claim",
        },
        correlation_id: "corr-claim",
      },
    });

    const result = await claimOpportunity(
      "token",
      "batch-1",
      { expectedVersion: 3, claimEpoch: "1", notes: "Ready" },
      "idem-claim",
    );

    expect(result.status).toBe("APPROVED");
    expect(post).toHaveBeenCalledWith(
      "/api/v1/batches/batch-1/claim",
      { expected_version: 3, claim_epoch: "1", notes: "Ready" },
      {
        headers: {
          Authorization: "Bearer token",
          "Idempotency-Key": "idem-claim",
          "If-Match-Version": "3",
        },
      },
    );
  });

  it("selects an assignment with the collector scope", async () => {
    post.mockResolvedValue({
      data: {
        data: {
          assignment_id: "asg-1",
          batch_id: "batch-1",
          assignment_status: "ACCEPTED",
          assignment_sequence: 1,
          version: 1,
        },
        correlationId: "corr-asg",
      },
    });

    await selectAssignment(
      "token",
      "batch-1",
      {
        expectedVersion: 4,
        claimEpoch: "1",
        collectorScopeId: "9f6d5c3a-37e1-4e0e-a5f6-0f7f4e2b2c99",
      },
      "idem-select",
    );

    expect(post.mock.calls[0]?.[1]).toEqual({
      expected_version: 4,
      claim_epoch: "1",
      collector_scope_id: "9f6d5c3a-37e1-4e0e-a5f6-0f7f4e2b2c99",
    });
  });

  it("maps conflict, missing, duplicate, and network failures", async () => {
    get.mockRejectedValueOnce(
      axiosError(409, {
        code: "STALE_VERSION",
        message: "The resource has changed. Refresh and retry.",
        correlationId: "corr-conflict",
      }),
    );
    await expect(listBatches("token")).rejects.toMatchObject({
      kind: "conflict",
      correlationId: "corr-conflict",
    });

    get.mockRejectedValueOnce(
      axiosError(404, {
        code: "NOT_FOUND",
        message: "missing",
        correlationId: "corr-404",
      }),
    );
    await expect(listBatches("token")).rejects.toMatchObject({
      kind: "not_found",
    });

    get.mockRejectedValueOnce(
      axiosError(409, {
        code: "DUPLICATE_CLAIM",
        message: "already sent",
        correlationId: "corr-dup",
      }),
    );
    await expect(listBatches("token")).rejects.toMatchObject({
      kind: "duplicate",
    });

    get.mockRejectedValueOnce(axiosError(undefined));
    await expect(listBatches("token")).rejects.toMatchObject({
      name: "WorkflowError",
      kind: "network",
    });
  });

  it("sends the failed-pickup reason without a version field in the body", async () => {
    post.mockResolvedValue({
      data: {
        data: {
          assignment_id: "asg-1",
          batch_id: "batch-1",
          assignment_status: "FAILED",
          assignment_sequence: 1,
          version: 2,
        },
        correlationId: "corr-fail",
      },
    });

    await reportFailedPickup(
      "token",
      "asg-1",
      1,
      { failureReason: " collector absent ", observedDetails: "No recipient" },
      "idem-fail",
    );

    const body = post.mock.calls[0]?.[1] as Record<string, unknown>;
    expect(body).toEqual({
      failure_reason: "collector absent",
      observed_details: "No recipient",
    });
    expect(body).not.toHaveProperty("version");
  });

  it("drops blank notes from a draft body", () => {
    expect(
      draftBody({
        category: "laptops",
        quantity: 1,
        estimatedWeightKg: 1,
        conditionRating: "reusable",
        isDataBearing: false,
        zone: "central",
        collectionDeadline: "2026-09-23T02:00:00.000Z",
        notes: " ",
      }),
    ).not.toHaveProperty("notes");
  });
});
