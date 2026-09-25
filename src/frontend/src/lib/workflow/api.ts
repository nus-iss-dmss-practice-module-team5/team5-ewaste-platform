import { api } from "@/lib/auth/api-client";
import { toWorkflowError } from "./errors";
import {
  USE_LOCAL_BATCH_MOCK,
  mockCreateBatchDraft,
  mockEditBatchDraft,
  mockGetBatch,
  mockListBatches,
  mockSubmitBatch,
} from "./local-batch-mock";
import { USE_LOCAL_CLAIM_MOCK, mockClaimOpportunity } from "./local-claim-mock";
import {
  USE_LOCAL_COLLECTOR_MOCK,
  mockAcceptAssignment,
  mockListAssignments,
  mockListBatches as mockListCollectorBatches,
  mockRecordHandoff,
  mockRejectAssignment,
  mockReportFailedPickup,
  mockSelectAssignment,
} from "./local-collector-mock";
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
  FailureReason,
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
    ...(version === undefined ? {} : { "If-Match-Version": String(version) }),
  });
}

async function call<T>(
  request: Promise<{ data: unknown }>,
  parse: (data: unknown) => T,
): Promise<T> {
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
  if (USE_LOCAL_BATCH_MOCK) {
    return mockListBatches(query.status);
  }
  if (USE_LOCAL_COLLECTOR_MOCK) {
    return mockListCollectorBatches(query.status);
  }
  return call(
    api.get("/api/v1/batches", {
      ...authHeaders(accessToken),
      params: {
        page: query.page ?? 1,
        page_size: query.pageSize ?? 20,
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
  if (USE_LOCAL_BATCH_MOCK) {
    return mockGetBatch(batchId);
  }
  return call(
    api.get(`/api/v1/batches/${batchId}`, authHeaders(accessToken)),
    (data) => parseData(data, parseBatch, "Batch"),
  );
}

type BatchDraftWire = {
  category?: string;
  quantity?: number;
  estimated_weight_kg?: number;
  condition_rating?: string;
  is_data_bearing?: boolean;
  zone?: string;
  collection_deadline?: string;
  notes?: string;
};

export function draftBody(input: BatchDraftRequest): BatchDraftWire {
  const body: BatchDraftWire = {};
  const category = input.category?.trim();
  if (category) body.category = category;
  if (input.quantity !== undefined) body.quantity = input.quantity;
  if (input.estimatedWeightKg !== undefined) {
    body.estimated_weight_kg = input.estimatedWeightKg;
  }
  const conditionRating = input.conditionRating?.trim();
  if (conditionRating) body.condition_rating = conditionRating;
  if (input.isDataBearing !== undefined)
    body.is_data_bearing = input.isDataBearing;
  const zone = input.zone?.trim();
  if (zone) body.zone = zone;
  if (input.collectionDeadline)
    body.collection_deadline = input.collectionDeadline;
  const notes = input.notes?.trim();
  if (notes) body.notes = notes;
  return body;
}

export async function createBatchDraft(
  accessToken: string,
  input: BatchDraftRequest,
  idempotencyKey: string,
): Promise<Batch> {
  if (USE_LOCAL_BATCH_MOCK) {
    return mockCreateBatchDraft(input);
  }
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
  if (USE_LOCAL_BATCH_MOCK) {
    return mockEditBatchDraft(batchId, version, input);
  }
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
  if (USE_LOCAL_BATCH_MOCK) {
    return mockSubmitBatch(batchId, version);
  }
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
        page_size: query.pageSize ?? 20,
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
  if (USE_LOCAL_CLAIM_MOCK) {
    return mockClaimOpportunity(batchId, command);
  }
  const body: {
    expected_version: number;
    claim_epoch: string;
    notes?: string;
  } = {
    expected_version: command.expectedVersion,
    claim_epoch: command.claimEpoch,
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
  if (USE_LOCAL_COLLECTOR_MOCK) {
    return mockSelectAssignment(batchId, command);
  }
  return call(
    api.post(
      `/api/v1/batches/${batchId}/assignments`,
      {
        expected_version: command.expectedVersion,
        claim_epoch: command.claimEpoch,
        collector_scope_id: command.collectorScopeId,
      },
      commandHeaders(accessToken, idempotencyKey, command.expectedVersion),
    ),
    (data) => parseData(data, parseAssignment, "Assignment"),
  );
}

export async function listAssignments(
  accessToken: string,
  query: {
    status?: Assignment["assignmentStatus"];
    page?: number;
    pageSize?: number;
  } = {},
): Promise<Page<Assignment>> {
  if (USE_LOCAL_COLLECTOR_MOCK) {
    return mockListAssignments();
  }
  return call(
    api.get("/api/v1/assignments", {
      ...authHeaders(accessToken),
      params: {
        page: query.page ?? 1,
        page_size: query.pageSize ?? 20,
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
  if (USE_LOCAL_COLLECTOR_MOCK) {
    return mockAcceptAssignment(assignmentId, version);
  }
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
  if (USE_LOCAL_COLLECTOR_MOCK) {
    return mockRejectAssignment(assignmentId, version);
  }
  return call(
    api.post(
      `/api/v1/assignments/${assignmentId}/reject`,
      { rejection_reason: rejectionReason.trim() },
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
  if (USE_LOCAL_COLLECTOR_MOCK) {
    return mockRecordHandoff(assignmentId, version);
  }
  const body: {
    pickup_occurred_at: string;
    donor_representative_name: string;
    actual_item_count: number;
    verification_hash: string;
    notes?: string;
  } = {
    pickup_occurred_at: command.pickupOccurredAt,
    donor_representative_name: command.donorRepresentativeName.trim(),
    actual_item_count: command.actualItemCount,
    verification_hash: command.verificationHash.trim(),
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
  if (USE_LOCAL_COLLECTOR_MOCK) {
    return mockReportFailedPickup(assignmentId, version);
  }
  const body: {
    failure_reason: FailureReason;
    observed_details?: string;
  } = {
    failure_reason: command.failureReason,
  };
  const observedDetails = command.observedDetails?.trim();
  if (observedDetails) {
    body.observed_details = observedDetails;
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
