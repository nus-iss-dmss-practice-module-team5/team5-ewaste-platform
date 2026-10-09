import axios from "axios";

export type WorkflowErrorKind =
  | "validation"
  | "forbidden"
  | "not_found"
  | "conflict"
  | "duplicate"
  | "network"
  | "unavailable"
  | "session"
  | "error";

export class WorkflowError extends Error {
  readonly kind: WorkflowErrorKind;
  readonly code: string;
  readonly correlationId: string;
  readonly status?: number;

  constructor(
    message: string,
    kind: WorkflowErrorKind,
    code: string,
    correlationId: string,
    status?: number,
  ) {
    super(message);
    this.name = "WorkflowError";
    this.kind = kind;
    this.code = code;
    this.correlationId = correlationId;
    this.status = status;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

export function isWorkflowError(error: unknown): error is WorkflowError {
  return error instanceof WorkflowError;
}

function kindForStatus(status: number, code: string): WorkflowErrorKind {
  if (status === 422) {
    return "validation";
  }
  if (status === 403) {
    return "forbidden";
  }
  if (status === 404) {
    return "not_found";
  }
  if (status === 409) {
    return /duplicate|replay/i.test(code) ? "duplicate" : "conflict";
  }
  if (status === 401) {
    return "session";
  }
  if (status === 503) {
    return "unavailable";
  }
  return "error";
}

function readErrorBody(data: unknown): {
  code: string;
  message: string;
  correlationId: string;
} {
  if (!isRecord(data)) {
    return {
      code: "REQUEST_FAILED",
      message: "The request failed.",
      correlationId: "corr-unknown",
    };
  }
  const code = typeof data.code === "string" ? data.code : "REQUEST_FAILED";
  const message =
    typeof data.message === "string" ? data.message : "The request failed.";
  const correlationId =
    typeof data.correlation_id === "string"
      ? data.correlation_id
      : "corr-unknown";
  return { code, message, correlationId };
}

export function toWorkflowError(error: unknown): WorkflowError {
  if (error instanceof WorkflowError) {
    return error;
  }
  if (axios.isAxiosError(error)) {
    if (!error.response) {
      return new WorkflowError(
        "Could not reach the workflow service. Try again.",
        "network",
        "NETWORK",
        "corr-network",
      );
    }
    const body = readErrorBody(error.response.data);
    return new WorkflowError(
      body.message,
      kindForStatus(error.response.status, body.code),
      body.code,
      body.correlationId,
      error.response.status,
    );
  }
  return new WorkflowError(
    "The request failed.",
    "error",
    "REQUEST_FAILED",
    "corr-unknown",
  );
}

export function contractError(message: string): WorkflowError {
  return new WorkflowError(
    message,
    "error",
    "INVALID_RESPONSE",
    "corr-contract",
  );
}
