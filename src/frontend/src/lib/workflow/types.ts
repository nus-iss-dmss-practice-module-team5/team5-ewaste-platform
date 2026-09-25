export const BATCH_STATUSES = [
  "DRAFT",
  "SUBMITTED",
  "MATCHED",
  "APPROVED",
  "ASSIGNED",
  "COLLECTED",
  "FAILED_COLLECTION",
] as const;

export type BatchStatus = (typeof BATCH_STATUSES)[number];

export const OPPORTUNITY_STATUSES = [
  "MATCHED",
  "APPROVED",
  "ASSIGNED",
] as const;

export type OpportunityStatus = (typeof OPPORTUNITY_STATUSES)[number];

export const ASSIGNMENT_STATUSES = [
  "ACCEPTED",
  "COMPLETED",
  "FAILED",
  "SUPERSEDED",
] as const;

export type AssignmentStatus = (typeof ASSIGNMENT_STATUSES)[number];

export type BatchDraftRequest = {
  category?: string;
  quantity?: number;
  estimatedWeightKg?: number;
  conditionRating?: string;
  isDataBearing?: boolean;
  zone?: string;
  collectionDeadline?: string;
  notes?: string;
};

export type Batch = {
  batchId: string;
  status: BatchStatus;
  version: number;
  category?: string;
  quantity?: number;
  estimatedWeightKg?: number;
  conditionRating?: string;
  isDataBearing?: boolean;
  zone?: string;
  collectionDeadline?: string;
  notes?: string;
  claimEpoch?: string;
  collectorScopeId?: string;
  createdAt?: string;
  updatedAt?: string;
};

export type Page<T> = {
  data: T[];
  page: number;
  pageSize: number;
  totalCount: number;
  correlationId: string;
};

export type Opportunity = {
  batchId: string;
  status: OpportunityStatus;
  category: string;
  quantity: number;
  estimatedWeightKg?: number;
  zone: string;
  collectionDeadline: string;
  eligibilityReason: string;
  version?: number;
  claimEpoch?: string;
};

export type ClaimResult = {
  batchId: string;
  status: "APPROVED";
  version: number;
  claimEpoch: string;
  claimId: string;
  reservationId: string;
  correlationId: string;
};

export type Assignment = {
  assignmentId: string;
  batchId: string;
  assignmentStatus: AssignmentStatus;
  assignmentSequence: number;
  version: number;
  claimId?: string;
  collectorScopeId?: string;
  createdAt?: string;
  updatedAt?: string;
};

export type ClaimCommand = {
  expectedVersion: number;
  claimEpoch: string;
  notes?: string;
};

export type SelectAssignmentCommand = {
  expectedVersion: number;
  claimEpoch: string;
  collectorScopeId: string;
};

export type HandoffCommand = {
  pickupOccurredAt: string;
  donorRepresentativeName: string;
  actualItemCount: number;
  verificationHash: string;
  notes?: string;
};

export const FAILURE_REASONS = [
  "DONOR_UNAVAILABLE",
  "INCORRECT_ITEMS",
  "ACCESS_DENIED",
  "DAMAGED_HAZARDOUS",
  "SAFETY_CANCEL",
] as const;

export type FailureReason = (typeof FAILURE_REASONS)[number];

export type FailPickupCommand = {
  failureReason: FailureReason;
  observedDetails?: string;
};
