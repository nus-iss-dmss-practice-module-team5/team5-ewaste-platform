export type Role = "DONOR" | "RECYCLER" | "COLLECTOR" | "AUDITOR" | "ADMIN";

export type SessionUser = {
  id: string;
  email: string;
  name: string;
  organisationId: string;
  organisationName: string;
  collectorScopeId?: string;
  role: Role;
};

export type TokenResponse = {
  accessToken: string;
  refreshToken: string;
  tokenType: "Bearer";
  expiresIn: number;
  refreshExpiresIn: number;
};

export type AuthErrorBody = {
  code: string;
  message: string;
  correlationId: string;
};

export type Session = {
  user: SessionUser;
  tokens: TokenResponse;
  accessExpiresAt: number;
  refreshExpiresAt: number;
};

export function isAuthError(error: unknown): error is AuthErrorBody {
  return (
    typeof error === "object" &&
    error !== null &&
    "message" in error &&
    "code" in error &&
    "correlationId" in error &&
    typeof (error as AuthErrorBody).message === "string" &&
    typeof (error as AuthErrorBody).code === "string" &&
    typeof (error as AuthErrorBody).correlationId === "string"
  );
}

export function sessionFromTokens(
  user: SessionUser,
  tokens: TokenResponse,
  now = Date.now(),
): Session {
  return {
    user,
    tokens,
    accessExpiresAt: now + tokens.expiresIn * 1000,
    refreshExpiresAt: now + tokens.refreshExpiresIn * 1000,
  };
}
