import {
  sessionFromTokens,
  type AuthErrorBody,
  type Session,
  type SessionUser,
  type TokenResponse,
} from "./types";

type SeededUser = SessionUser & { password: string };

type RefreshRecord = {
  user: SessionUser;
  accessToken: string;
  refreshExpiresAt: number;
};

const MOCK_PASSWORD = "Password1!";
const ACCESS_EXPIRES_IN = 900;
const REFRESH_EXPIRES_IN = 86400;

const SEEDED_USERS: SeededUser[] = [
  {
    id: "usr-donor-001",
    email: "donor@example.com",
    password: MOCK_PASSWORD,
    name: "Alex Tan",
    organisationId: "org-donor-001",
    organisationName: "Campus Labs",
    role: "DONOR",
  },
  {
    id: "usr-recycler-001",
    email: "recycler@example.com",
    password: MOCK_PASSWORD,
    name: "Mei Chen",
    organisationId: "org-recycler-001",
    organisationName: "GreenCycle",
    role: "RECYCLER",
  },
  {
    id: "usr-collector-001",
    email: "collector@example.com",
    password: MOCK_PASSWORD,
    name: "Ravi Kumar",
    organisationId: "org-recycler-001",
    organisationName: "GreenCycle",
    role: "COLLECTOR",
  },
  {
    id: "usr-auditor-001",
    email: "auditor@example.com",
    password: MOCK_PASSWORD,
    name: "Priya Nair",
    organisationId: "org-platform",
    organisationName: "E-Waste Platform",
    role: "AUDITOR",
  },
  {
    id: "usr-admin-001",
    email: "admin@example.com",
    password: MOCK_PASSWORD,
    name: "Jordan Lee",
    organisationId: "org-platform",
    organisationName: "E-Waste Platform",
    role: "ADMIN",
  },
];

const refreshSessions = new Map<string, RefreshRecord>();

function toBase64Url(value: string): string {
  return btoa(unescape(encodeURIComponent(value)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

function newRefreshToken(): string {
  const id =
    globalThis.crypto?.randomUUID?.() ??
    `${Date.now()}-${Math.random().toString(16).slice(2)}`;
  return `mock-refresh-${id}`;
}

function mockAccessToken(user: SessionUser, expiresIn: number): string {
  const nowSec = Math.floor(Date.now() / 1000);
  const header = toBase64Url(JSON.stringify({ alg: "none", typ: "JWT" }));
  const payload = toBase64Url(
    JSON.stringify({
      sub: user.id,
      email: user.email,
      name: user.name,
      role: user.role,
      organisationId: user.organisationId,
      organisationName: user.organisationName,
      iat: nowSec,
      exp: nowSec + expiresIn,
    }),
  );
  return `${header}.${payload}.mock`;
}

function tokenResponse(user: SessionUser): TokenResponse {
  return {
    accessToken: mockAccessToken(user, ACCESS_EXPIRES_IN),
    refreshToken: newRefreshToken(),
    tokenType: "Bearer",
    expiresIn: ACCESS_EXPIRES_IN,
    refreshExpiresIn: REFRESH_EXPIRES_IN,
  };
}

function rememberRefresh(session: Session): Session {
  refreshSessions.set(session.tokens.refreshToken, {
    user: session.user,
    accessToken: session.tokens.accessToken,
    refreshExpiresAt: session.refreshExpiresAt,
  });
  return session;
}

export function mockRestoreRefresh(session: Session): void {
  rememberRefresh(session);
}

function invalidSession(): AuthErrorBody {
  return {
    code: "AUTH_INVALID_SESSION",
    message: "Session expired. Please sign in again.",
    correlationId: "corr-mock-session",
  };
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function toPublicUser(match: SeededUser): SessionUser {
  return {
    id: match.id,
    email: match.email,
    name: match.name,
    organisationId: match.organisationId,
    organisationName: match.organisationName,
    role: match.role,
  };
}

export function mockRevokeRefresh(refreshToken: string): void {
  refreshSessions.delete(refreshToken);
}

export async function mockLogin(
  email: string,
  password: string,
): Promise<Session> {
  await delay(700);

  const trimmedEmail = email.trim();
  if (!trimmedEmail || !password) {
    const error: AuthErrorBody = {
      code: "AUTH_INVALID_REQUEST",
      message: "Email and password are required",
      correlationId: "corr-mock-400",
    };
    throw error;
  }

  const match = SEEDED_USERS.find(
    (user) =>
      user.email.toLowerCase() === trimmedEmail.toLowerCase() &&
      user.password === password,
  );
  if (!match) {
    const error: AuthErrorBody = {
      code: "AUTH_INVALID_CREDENTIALS",
      message: "Invalid email or password",
      correlationId: "corr-mock-401",
    };
    throw error;
  }

  const user = toPublicUser(match);
  return rememberRefresh(sessionFromTokens(user, tokenResponse(user)));
}

export async function mockRefresh(refreshToken: string): Promise<Session> {
  await delay(200);

  const record = refreshSessions.get(refreshToken);
  if (!record || Date.now() >= record.refreshExpiresAt) {
    refreshSessions.delete(refreshToken);
    throw invalidSession();
  }

  refreshSessions.delete(refreshToken);
  return rememberRefresh(
    sessionFromTokens(record.user, tokenResponse(record.user)),
  );
}

export async function mockLogout(accessToken: string): Promise<void> {
  await delay(150);
  for (const [refreshToken, record] of refreshSessions) {
    if (record.accessToken === accessToken) {
      refreshSessions.delete(refreshToken);
      return;
    }
  }
}
