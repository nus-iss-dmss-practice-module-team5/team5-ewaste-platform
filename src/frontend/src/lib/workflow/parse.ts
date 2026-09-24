import { contractError } from "./errors";
import {
  ASSIGNMENT_STATUSES,
  BATCH_STATUSES,
  OPPORTUNITY_STATUSES,
  type Assignment,
  type AssignmentStatus,
  type Batch,
  type BatchStatus,
  type ClaimResult,
  type Opportunity,
  type OpportunityStatus,
  type Page,
} from "./types";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function readString(
  record: Record<string, unknown>,
  key: string,
): string | undefined {
  const value = record[key];
  return typeof value === "string" && value.trim() ? value : undefined;
}

function readNumber(
  record: Record<string, unknown>,
  key: string,
): number | undefined {
  const value = record[key];
  return typeof value === "number" && Number.isFinite(value)
    ? value
    : undefined;
}

function requireString(
  record: Record<string, unknown>,
  key: string,
  label: string,
): string {
  const value = readString(record, key);
  if (!value) {
    throw contractError(`${label} is missing ${key}.`);
  }
  return value;
}

function requireNumber(
  record: Record<string, unknown>,
  key: string,
  label: string,
): number {
  const value = readNumber(record, key);
  if (value === undefined) {
    throw contractError(`${label} is missing ${key}.`);
  }
  return value;
}

function oneOf<T extends string>(
  value: string,
  allowed: readonly T[],
  label: string,
): T {
  const match = allowed.find((item) => item === value);
  if (!match) {
    throw contractError(`${label} has an unknown status.`);
  }
  return match;
}

export function parseBatch(value: unknown): Batch {
  if (!isRecord(value)) {
    throw contractError("Batch response is not an object.");
  }
  const status = oneOf(
    requireString(value, "status", "Batch"),
    BATCH_STATUSES,
    "Batch",
  ) as BatchStatus;
  const batch: Batch = {
    batchId: requireString(value, "batch_id", "Batch"),
    status,
    version: requireNumber(value, "version", "Batch"),
  };
  const category = readString(value, "category");
  const quantity = readNumber(value, "quantity");
  const estimatedWeightKg = readNumber(value, "estimated_weight_kg");
  const conditionRating = readString(value, "condition_rating");
  const zone = readString(value, "zone");
  const collectionDeadline = readString(value, "collection_deadline");
  const notes = readString(value, "notes");
  const claimEpoch = readString(value, "claim_epoch");
  const createdAt = readString(value, "created_at");
  const updatedAt = readString(value, "updated_at");
  if (category) batch.category = category;
  if (quantity !== undefined) batch.quantity = quantity;
  if (estimatedWeightKg !== undefined)
    batch.estimatedWeightKg = estimatedWeightKg;
  if (conditionRating) batch.conditionRating = conditionRating;
  if (typeof value.is_data_bearing === "boolean") {
    batch.isDataBearing = value.is_data_bearing;
  }
  if (zone) batch.zone = zone;
  if (collectionDeadline) batch.collectionDeadline = collectionDeadline;
  if (notes) batch.notes = notes;
  if (claimEpoch) batch.claimEpoch = claimEpoch;
  if (createdAt) batch.createdAt = createdAt;
  if (updatedAt) batch.updatedAt = updatedAt;
  return batch;
}

export function parseOpportunity(value: unknown): Opportunity {
  if (!isRecord(value)) {
    throw contractError("Opportunity response is not an object.");
  }
  const status = oneOf(
    requireString(value, "status", "Opportunity"),
    OPPORTUNITY_STATUSES,
    "Opportunity",
  ) as OpportunityStatus;
  const opportunity: Opportunity = {
    batchId: requireString(value, "batch_id", "Opportunity"),
    status,
    category: requireString(value, "category", "Opportunity"),
    quantity: requireNumber(value, "quantity", "Opportunity"),
    zone: requireString(value, "zone", "Opportunity"),
    collectionDeadline: requireString(
      value,
      "collection_deadline",
      "Opportunity",
    ),
    eligibilityReason: requireString(
      value,
      "eligibility_reason",
      "Opportunity",
    ),
  };
  const estimatedWeightKg = readNumber(value, "estimated_weight_kg");
  const version = readNumber(value, "version");
  const claimEpoch = readString(value, "claim_epoch");
  if (estimatedWeightKg !== undefined) {
    opportunity.estimatedWeightKg = estimatedWeightKg;
  }
  if (version !== undefined) opportunity.version = version;
  if (claimEpoch) opportunity.claimEpoch = claimEpoch;
  return opportunity;
}

export function parseClaimResult(value: unknown): ClaimResult {
  if (!isRecord(value)) {
    throw contractError("Claim response is not an object.");
  }
  const status = requireString(value, "status", "Claim");
  if (status !== "APPROVED") {
    throw contractError("Claim did not end at APPROVED.");
  }
  return {
    batchId: requireString(value, "batch_id", "Claim"),
    status: "APPROVED",
    version: requireNumber(value, "version", "Claim"),
    claimEpoch: requireString(value, "claim_epoch", "Claim"),
    claimId: requireString(value, "claim_id", "Claim"),
    reservationId: requireString(value, "reservation_id", "Claim"),
    correlationId: requireString(value, "correlation_id", "Claim"),
  };
}

export function parseAssignment(value: unknown): Assignment {
  if (!isRecord(value)) {
    throw contractError("Assignment response is not an object.");
  }
  const assignmentStatus = oneOf(
    requireString(value, "assignment_status", "Assignment"),
    ASSIGNMENT_STATUSES,
    "Assignment",
  ) as AssignmentStatus;
  const assignment: Assignment = {
    assignmentId: requireString(value, "assignment_id", "Assignment"),
    batchId: requireString(value, "batch_id", "Assignment"),
    assignmentStatus,
    assignmentSequence: requireNumber(
      value,
      "assignment_sequence",
      "Assignment",
    ),
    version: requireNumber(value, "version", "Assignment"),
  };
  const claimId = readString(value, "claim_id");
  const collectorScopeId = readString(value, "collector_scope_id");
  const createdAt = readString(value, "created_at");
  const updatedAt = readString(value, "updated_at");
  if (claimId) assignment.claimId = claimId;
  if (collectorScopeId) assignment.collectorScopeId = collectorScopeId;
  if (createdAt) assignment.createdAt = createdAt;
  if (updatedAt) assignment.updatedAt = updatedAt;
  return assignment;
}

function parsePage<T>(
  value: unknown,
  parseItem: (item: unknown) => T,
  label: string,
): Page<T> {
  if (!isRecord(value) || !Array.isArray(value.data)) {
    throw contractError(`${label} list is missing data.`);
  }
  return {
    data: value.data.map(parseItem),
    page: requireNumber(value, "page", label),
    pageSize: requireNumber(value, "page_size", label),
    totalCount: requireNumber(value, "total_count", label),
    correlationId: requireString(value, "correlation_id", label),
  };
}

export function parseBatchPage(value: unknown): Page<Batch> {
  return parsePage(value, parseBatch, "Batch");
}

export function parseOpportunityPage(value: unknown): Page<Opportunity> {
  return parsePage(value, parseOpportunity, "Opportunity");
}

export function parseAssignmentPage(value: unknown): Page<Assignment> {
  return parsePage(value, parseAssignment, "Assignment");
}

export function parseData<T>(
  value: unknown,
  parseItem: (item: unknown) => T,
  label: string,
): T {
  if (!isRecord(value) || !("data" in value)) {
    throw contractError(`${label} response is missing data.`);
  }
  return parseItem(value.data);
}
