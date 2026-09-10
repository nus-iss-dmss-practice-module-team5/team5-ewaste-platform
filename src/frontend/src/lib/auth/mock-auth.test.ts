import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { isAuthError } from "./types";
import { mockLogin, mockRefresh } from "./mock-auth";

async function flushLogin() {
  await vi.advanceTimersByTimeAsync(700);
}

describe("mockLogin", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("returns tokens for a seeded account", async () => {
    const pending = mockLogin("  DONOR@example.com  ", "Password1!");
    await flushLogin();
    const session = await pending;

    expect(session.user.email).toBe("donor@example.com");
    expect(session.user.role).toBe("DONOR");
    expect(session.tokens.tokenType).toBe("Bearer");
    expect(session.tokens.accessToken).toBeTruthy();
    expect(session.tokens.refreshToken).toBeTruthy();
    expect(session.tokens.expiresIn).toBe(900);
    expect(session.tokens.refreshExpiresIn).toBe(86400);
  });

  it("rejects a wrong password with a generic credentials error", async () => {
    const pending = mockLogin("donor@example.com", "wrong-password");
    const assertion = expect(pending).rejects.toMatchObject({
      code: "AUTH_INVALID_CREDENTIALS",
      message: "Invalid email or password",
    });
    await flushLogin();
    await assertion;
  });

  it("rejects an unknown email with the same generic error and no leaked input", async () => {
    const pending = mockLogin("unknown@example.com", "Password1!");
    let caught: unknown;
    const assertion = pending.catch((error) => {
      caught = error;
    });
    await flushLogin();
    await assertion;

    expect(isAuthError(caught)).toBe(true);
    if (!isAuthError(caught)) {
      return;
    }
    expect(caught.code).toBe("AUTH_INVALID_CREDENTIALS");
    expect(caught.message).toBe("Invalid email or password");
    expect(JSON.stringify(caught)).not.toContain("unknown@example.com");
    expect(JSON.stringify(caught)).not.toContain("Password1!");
  });
});

describe("mockRefresh", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("rotates the refresh token after a successful login", async () => {
    const loginPending = mockLogin("donor@example.com", "Password1!");
    await vi.advanceTimersByTimeAsync(700);
    const session = await loginPending;

    const refreshPending = mockRefresh(session.tokens.refreshToken);
    await vi.advanceTimersByTimeAsync(200);
    const rotated = await refreshPending;

    expect(rotated.tokens.refreshToken).not.toBe(session.tokens.refreshToken);

    const reusePending = mockRefresh(session.tokens.refreshToken);
    const reuseAssertion = expect(reusePending).rejects.toMatchObject({
      code: "AUTH_INVALID_SESSION",
    });
    await vi.advanceTimersByTimeAsync(200);
    await reuseAssertion;
  });
});
