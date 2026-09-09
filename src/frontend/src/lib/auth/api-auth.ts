import axios from "axios";
import { api } from "./api-client";
import { userFromAccessToken } from "./jwt";
import {
  isAuthError,
  sessionFromTokens,
  type AuthErrorBody,
  type Session,
  type TokenResponse,
} from "./types";

const NETWORK_ERROR: AuthErrorBody = {
  code: "AUTH_SERVICE_UNAVAILABLE",
  message: "Could not reach the sign-in service. Try again.",
  correlationId: "corr-network",
};

function credentialsMessage(body: AuthErrorBody): AuthErrorBody {
  if (body.code === "AUTH_INVALID_CREDENTIALS") {
    return { ...body, message: "Invalid email or password" };
  }
  return body;
}

function toAuthError(error: unknown): AuthErrorBody {
  if (axios.isAxiosError(error)) {
    const data: unknown = error.response?.data;
    if (isAuthError(data)) {
      return credentialsMessage(data);
    }
    if (!error.response) {
      return NETWORK_ERROR;
    }
    return NETWORK_ERROR;
  }
  if (isAuthError(error)) {
    return credentialsMessage(error);
  }
  return NETWORK_ERROR;
}

function isTokenResponse(value: unknown): value is TokenResponse {
  if (typeof value !== "object" || value === null) {
    return false;
  }
  const record = value as TokenResponse;
  return (
    typeof record.accessToken === "string" &&
    typeof record.refreshToken === "string" &&
    record.tokenType === "Bearer" &&
    typeof record.expiresIn === "number" &&
    typeof record.refreshExpiresIn === "number"
  );
}

function sessionFromResponse(
  data: unknown,
  fallbacks?: { email?: string; name?: string; organisationName?: string },
): Session {
  if (!isTokenResponse(data)) {
    throw NETWORK_ERROR;
  }
  try {
    return sessionFromTokens(
      userFromAccessToken(data.accessToken, fallbacks),
      data,
    );
  } catch {
    const error: AuthErrorBody = {
      code: "AUTH_INVALID_SESSION",
      message: "Session expired. Please sign in again.",
      correlationId: "corr-token-claims",
    };
    throw error;
  }
}

export async function apiLogin(
  email: string,
  password: string,
): Promise<Session> {
  const trimmedEmail = email.trim();
  try {
    const response = await api.post<TokenResponse>("/api/v1/auth/login", {
      email: trimmedEmail,
      password,
    });
    return sessionFromResponse(response.data, { email: trimmedEmail });
  } catch (error) {
    throw toAuthError(error);
  }
}

export async function apiRefresh(
  refreshToken: string,
  previous?: { email: string; name: string; organisationName: string },
): Promise<Session> {
  try {
    const response = await api.post<TokenResponse>("/api/v1/auth/refresh", {
      refreshToken,
    });
    return sessionFromResponse(response.data, previous);
  } catch (error) {
    throw toAuthError(error);
  }
}

export async function apiLogout(accessToken: string): Promise<void> {
  try {
    await api.post("/api/v1/auth/logout", undefined, {
      headers: { Authorization: `Bearer ${accessToken}` },
    });
  } catch (error) {
    throw toAuthError(error);
  }
}
