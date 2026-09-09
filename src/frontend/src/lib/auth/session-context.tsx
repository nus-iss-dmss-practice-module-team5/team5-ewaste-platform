"use client";

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import {
  ACCESS_REFRESH_SKEW_MS,
  EXPIRED_LOGIN_PATH,
  LOGIN_PATH,
  USE_MOCK_AUTH,
} from "./config";
import { logoutSession, refreshSession } from "./login";
import { mockRestoreRefresh, mockRevokeRefresh } from "./mock-auth";
import {
  readStoredSession,
  replaceLocation,
  writeStoredSession,
} from "./storage";
import type { Session } from "./types";

type SessionContextValue = {
  session: Session | null;
  ready: boolean;
  justRenewed: boolean;
  setSession: (session: Session) => void;
  logout: () => Promise<void>;
  simulateAccessExpiry: () => void;
  simulateSessionExpiry: () => void;
};

const SessionContext = createContext<SessionContextValue | null>(null);

export function SessionProvider({ children }: { children: ReactNode }) {
  const [session, setSessionState] = useState<Session | null>(null);
  const [ready, setReady] = useState(false);
  const [justRenewed, setJustRenewed] = useState(false);
  const sessionRef = useRef<Session | null>(null);

  useEffect(() => {
    sessionRef.current = session;
  }, [session]);

  useEffect(() => {
    const timer = window.setTimeout(() => {
      const stored = readStoredSession();
      if (stored && stored.refreshExpiresAt > Date.now()) {
        if (USE_MOCK_AUTH) {
          mockRestoreRefresh(stored);
        }
        setSessionState(stored);
      } else if (stored) {
        writeStoredSession(null);
        setReady(true);
        replaceLocation(EXPIRED_LOGIN_PATH);
        return;
      }
      setReady(true);
    }, 0);
    return () => window.clearTimeout(timer);
  }, []);

  useEffect(() => {
    if (!ready) {
      return;
    }
    writeStoredSession(session);
  }, [ready, session]);

  const setSession = useCallback((next: Session) => {
    setJustRenewed(false);
    writeStoredSession(next);
    setSessionState(next);
  }, []);

  const expireSession = useCallback(() => {
    const current = sessionRef.current;
    if (USE_MOCK_AUTH && current) {
      mockRevokeRefresh(current.tokens.refreshToken);
    }
    setJustRenewed(false);
    setSessionState(null);
    writeStoredSession(null);
    replaceLocation(EXPIRED_LOGIN_PATH);
  }, []);

  const logout = useCallback(async () => {
    const current = sessionRef.current;
    if (current) {
      try {
        await logoutSession(current.tokens.accessToken);
      } catch {
        if (USE_MOCK_AUTH) {
          mockRevokeRefresh(current.tokens.refreshToken);
        }
      }
    }
    setJustRenewed(false);
    setSessionState(null);
    writeStoredSession(null);
    replaceLocation(LOGIN_PATH);
  }, []);

  const simulateAccessExpiry = useCallback(() => {
    setSessionState((current) =>
      current ? { ...current, accessExpiresAt: Date.now() - 1 } : current,
    );
  }, []);

  const simulateSessionExpiry = useCallback(() => {
    const current = sessionRef.current;
    if (!current) {
      return;
    }
    if (USE_MOCK_AUTH) {
      mockRevokeRefresh(current.tokens.refreshToken);
    }
    setSessionState({
      ...current,
      accessExpiresAt: Date.now() - 1,
      refreshExpiresAt: Date.now() - 1,
    });
  }, []);

  useEffect(() => {
    if (!justRenewed) {
      return;
    }
    const timer = window.setTimeout(() => setJustRenewed(false), 4000);
    return () => window.clearTimeout(timer);
  }, [justRenewed]);

  useEffect(() => {
    if (!session) {
      return;
    }

    const now = Date.now();
    const refreshRemaining = session.refreshExpiresAt - now;
    const accessDelay = Math.max(
      0,
      session.accessExpiresAt - now - ACCESS_REFRESH_SKEW_MS,
    );
    let cancelled = false;

    if (refreshRemaining <= 0) {
      const hardExpiry = window.setTimeout(() => {
        if (!cancelled) {
          expireSession();
        }
      }, 0);
      return () => {
        cancelled = true;
        window.clearTimeout(hardExpiry);
      };
    }

    const refreshTimer = window.setTimeout(async () => {
      const current = sessionRef.current;
      if (cancelled || !current) {
        return;
      }
      try {
        const next = await refreshSession(
          current.tokens.refreshToken,
          current.user,
        );
        if (cancelled) {
          return;
        }
        setSessionState(next);
        setJustRenewed(true);
      } catch {
        if (!cancelled) {
          expireSession();
        }
      }
    }, accessDelay);

    const hardExpiry = window.setTimeout(() => {
      if (!cancelled) {
        expireSession();
      }
    }, refreshRemaining);

    return () => {
      cancelled = true;
      window.clearTimeout(refreshTimer);
      window.clearTimeout(hardExpiry);
    };
  }, [session, expireSession]);

  const value = useMemo(
    () => ({
      session,
      ready,
      justRenewed,
      setSession,
      logout,
      simulateAccessExpiry,
      simulateSessionExpiry,
    }),
    [
      session,
      ready,
      justRenewed,
      setSession,
      logout,
      simulateAccessExpiry,
      simulateSessionExpiry,
    ],
  );

  return (
    <SessionContext.Provider value={value}>{children}</SessionContext.Provider>
  );
}

export function useSession(): SessionContextValue {
  const context = useContext(SessionContext);
  if (!context) {
    throw new Error("useSession must be used within SessionProvider");
  }
  return context;
}
