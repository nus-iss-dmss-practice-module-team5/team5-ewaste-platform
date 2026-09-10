import { apiLogin, apiLogout, apiRefresh } from "./api-auth";
import { USE_MOCK_AUTH } from "./config";
import { mockLogin, mockLogout, mockRefresh } from "./mock-auth";
import type { Session, SessionUser } from "./types";

export async function login(email: string, password: string): Promise<Session> {
  if (USE_MOCK_AUTH) {
    return mockLogin(email, password);
  }
  return apiLogin(email, password);
}

export async function refreshSession(
  refreshToken: string,
  previous?: SessionUser,
): Promise<Session> {
  if (USE_MOCK_AUTH) {
    return mockRefresh(refreshToken);
  }
  return apiRefresh(refreshToken, previous);
}

export async function logoutSession(accessToken: string): Promise<void> {
  if (USE_MOCK_AUTH) {
    return mockLogout(accessToken);
  }
  return apiLogout(accessToken);
}
