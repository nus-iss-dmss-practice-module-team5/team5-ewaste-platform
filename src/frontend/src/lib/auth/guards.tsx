"use client";

import { useEffect, type ReactNode } from "react";
import { HOME_PATH, LOGIN_PATH } from "./config";
import { useSession } from "./session-context";
import { replaceLocation } from "./storage";

export function Redirecting({ children = "Loading…" }: { children?: string }) {
  return (
    <main className="flex min-h-full flex-1 items-center justify-center bg-slate-100 text-sm text-slate-600">
      {children}
    </main>
  );
}

export function RequireAuth({ children }: { children: ReactNode }) {
  const { session, ready } = useSession();

  useEffect(() => {
    if (!ready || session) {
      return;
    }
    replaceLocation(LOGIN_PATH);
  }, [ready, session]);

  if (!ready) {
    return <Redirecting />;
  }

  if (!session) {
    return <Redirecting>Redirecting to sign in…</Redirecting>;
  }

  return children;
}

export function GuestOnly({ children }: { children: ReactNode }) {
  const { session, ready } = useSession();

  useEffect(() => {
    if (!ready || !session) {
      return;
    }
    replaceLocation(HOME_PATH);
  }, [ready, session]);

  if (!ready) {
    return <Redirecting />;
  }

  if (session) {
    return <Redirecting>Redirecting to home…</Redirecting>;
  }

  return children;
}
