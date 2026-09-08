import { mockLogin, mockLogout, mockRefresh } from "./mock-auth";
import type { Session } from "./types";

export async function login(email: string, password: string): Promise<Session> {
  return mockLogin(email, password);
}

export async function refreshSession(refreshToken: string): Promise<Session> {
  return mockRefresh(refreshToken);
}

export async function logoutSession(accessToken: string): Promise<void> {
  return mockLogout(accessToken);
}
