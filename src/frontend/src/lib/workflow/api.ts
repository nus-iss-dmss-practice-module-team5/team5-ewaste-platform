import { api } from "@/lib/auth/api-client";
import { toWorkflowError } from "./errors";
import {
  USE_LOCAL_OPPORTUNITY_MOCK,
  mockGetOpportunity,
  mockListOpportunities,
} from "./local-opportunity-mock";
import {
  parseAssignment,
  parseAssignmentPage,
  parseBatch,
  parseBatchPage,
  parseClaimResult,
  parseData,
  parseOpportunity,
  parseOpportunityPage,
} from "./parse";
import type {
  Assignment,
  Batch,
  BatchDraftRequest,
  BatchStatus,
  ClaimCommand,
  ClaimResult,
  FailPickupCommand,
  HandoffCommand,
  Opportunity,
  Page,
  SelectAssignmentCommand,
} from "./types";

export function newIdempotencyKey(): string {
  return globalThis.crypto?.randomUUID?.() ?? `idem-${Date.now()}`;
}

function authHeaders(accessToken: string, extra?: Record<string, string>) {
  return {
    headers: {
      Authorization: `Bearer ${accessToken}`,
      ...extra,
    },
  };
}

function commandHeaders(
  accessToken: string,
  idempotencyKey: string,
  version?: number,
) {
  return authHeaders(accessToken, {
    "Idempotency-Key": idempotencyKey,
    ...(version === undefined
      ? {}
      : { "If-Match-Version": String(version) }),
  });
}

async function call<T>(request: Promise<{ data: unknown }>, parse: (data: unknown) => T): Promise<T> {
  try {
    const response = await request;
    return parse(response.data);
  } catch (error) {
    throw toWorkflowError(error);
  }
}

export async function listBatches(
  accessToken: string,
  query: { status?: BatchStatus; page?: number; pageSize?: number } = {},
): Promise<Page<Batch>> {
  return call(
    api.get("/api/v1/batches", {
      ...authHeaders(accessToken),
      params: {
        page: query.page ?? 1,
        pageSize: query.pageSize ?? 20,
        ...(query.status ? { status: query.status } : {}),
      },
    }),
    parseBatchPage,
  );
}

export async function getBatch(
  accessToken: string,
  batchId: string,
): Promise<Batch> {
  return call(
    api.get(`/api/v1/batches/${batchId}`, authHeaders(accessToken)),
    (data) => parseData(data, parseBatch, "Batch"),
  );
}

export function draftBody(input: BatchDraftRequest): BatchDraftRequest {
  const body: BatchDraftRequest = {
    category: input.category.trim(),
    quantity: input.quantity,
    estimatedWeightKg: input.estimatedWeightKg,
    conditionRating: input.conditionRating.trim(),
    isDataBearing: input.isDataBearing,
    zone: input.zone.trim(),
    collectionDeadline: input.collectionDeadline,
  };
  const notes = input.notes?.trim();
  if (notes) {
    body.notes = notes;
  }
  return body;
}

export async function createBatchDraft(
  accessToken: string,
  input: BatchDraftRequest,
  idempotencyKey: string,
): Promise<Batch> {
  return call(
    api.post(
      "/api/v1/batches",
      draftBody(input),
      commandHeaders(accessToken, idempotencyKey),
    ),
    (data) => parseData(data, parseBatch, "Batch"),
  );
}

export async function editBatchDraft(
  accessToken: string,
  batchId: string,
  version: number,
  input: BatchDraftRequest,
  idempotencyKey: string,
): Promise<Batch> {
  return call(
    api.patch(
      `/api/v1/batches/${batchId}`,
      draftBody(input),
      commandHeaders(accessToken, idempotencyKey, version),
    ),
    (data) => parseData(data, parseBatch, "Batch"),
  );
}

export async function submitBatch(
  accessToken: string,
  batchId: string,
  version: number,
  idempotencyKey: string,
): Promise<Batch> {
  return call(
    api.post(
      `/api/v1/batches/${batchId}/submit`,
      undefined,
      commandHeaders(accessToken, idempotencyKey, version),
    ),
    (data) => parseData(data, parseBatch, "Batch"),
  );
}

export async function listOpportunities(
  accessToken: string,
  query: { page?: number; pageSize?: number } = {},
): Promise<Page<Opportunity>> {
  if (USE_LOCAL_OPPORTUNITY_MOCK) {
    return mockListOpportunities();
  }
  return call(
    api.get("/api/v1/opportunities", {
      ...authHeaders(accessToken),
      params: {
        page: query.page ?? 1,
        pageSize: query.pageSize ?? 20,
      },
    }),
    parseOpportunityPage,
  );
}

export async function getOpportunity(
  accessToken: string,
  batchId: string,
): Promise<Opportunity> {
  if (USE_LOCAL_OPPORTUNITY_MOCK) {
    return mockGetOpportunity(batchId);
  }
  return call(
    api.get(`/api/v1/opportunities/${batchId}`, authHeaders(accessToken)),
    (data) => parseData(data, parseOpportunity, "Opportunity"),
  );
}

export async function claimOpportunity(
  accessToken: string,
  batchId: string,
  command: ClaimCommand,
  idempotencyKey: string,
): Promise<ClaimResult> {
  const body: ClaimCommand = {
    expectedVersion: command.expectedVersion,
    claimEpoch: command.claimEpoch,
  };
  const notes = command.notes?.trim();
  if (notes) {
    body.notes = notes;
  }
  return call(
    api.post(
      `/api/v1/batches/${batchId}/claim`,
      body,
      commandHeaders(accessToken, idempotencyKey, command.expectedVersion),
    ),
    (data) => parseData(data, parseClaimResult, "Claim"),
  );
}

export async function selectAssignment(
  accessToken: string,
  batchId: string,
  command: SelectAssignmentCommand,
  idempotencyKey: string,
): Promise<Assignment> {
  return call(
    api.post(
      `/api/v1/batches/${batchId}/assignments`,
      {
        expectedVersion: command.expectedVersion,
        claimEpoch: command.claimEpoch,
        collectorScopeId: command.collectorScopeId,
      },
      commandHeaders(accessToken, idempotencyKey, command.expectedVersion),
    ),
    (data) => parseData(data, parseAssignment, "Assignment"),
  );
}

export async function listAssignments(
  accessToken: string,
  query: { status?: Assignment["assignmentStatus"]; page?: number; pageSize?: number } = {},
): Promise<Page<Assignment>> {
  return call(
    api.get("/api/v1/assignments", {
      ...authHeaders(accessToken),
      params: {
        page: query.page ?? 1,
        pageSize: query.pageSize ?? 20,
        ...(query.status ? { status: query.status } : {}),
      },
    }),
    parseAssignmentPage,
  );
}

export async function acceptAssignment(
  accessToken: string,
  assignmentId: string,
  version: number,
  idempotencyKey: string,
): Promise<Assignment> {
  return call(
    api.post(
      `/api/v1/assignments/${assignmentId}/accept`,
      undefined,
      commandHeaders(accessToken, idempotencyKey, version),
    ),
    (data) => parseData(data, parseAssignment, "Assignment"),
  );
}

export async function rejectAssignment(
  accessToken: string,
  assignmentId: string,
  version: number,
  rejectionReason: string,
  idempotencyKey: string,
): Promise<Assignment> {
  return call(
    api.post(
      `/api/v1/assignments/${assignmentId}/reject`,
      { rejectionReason: rejectionReason.trim() },
      commandHeaders(accessToken, idempotencyKey, version),
    ),
    (data) => parseData(data, parseAssignment, "Assignment"),
  );
}

export async function recordHandoff(
  accessToken: string,
  assignmentId: string,
  version: number,
  command: HandoffCommand,
  idempotencyKey: string,
): Promise<Assignment> {
  const body: HandoffCommand = {
    pickupOccurredAt: command.pickupOccurredAt,
    donorRepresentativeName: command.donorRepresentativeName.trim(),
    actualItemCount: command.actualItemCount,
    verificationHash: command.verificationHash.trim(),
  };
  const notes = command.notes?.trim();
  if (notes) {
    body.notes = notes;
  }
  return call(
    api.post(
      `/api/v1/assignments/${assignmentId}/handoff`,
      body,
      commandHeaders(accessToken, idempotencyKey, version),
    ),
    (data) => parseData(data, parseAssignment, "Assignment"),
  );
}

export async function reportFailedPickup(
  accessToken: string,
  assignmentId: string,
  version: number,
  command: FailPickupCommand,
  idempotencyKey: string,
): Promise<Assignment> {
  const body: FailPickupCommand = {
    failureReason: command.failureReason.trim(),
  };
  const observedDetails = command.observedDetails?.trim();
  if (observedDetails) {
    body.observedDetails = observedDetails;
  }
  return call(
    api.post(
      `/api/v1/assignments/${assignmentId}/fail`,
      body,
      commandHeaders(accessToken, idempotencyKey, version),
    ),
    (data) => parseData(data, parseAssignment, "Assignment"),
  );
}
