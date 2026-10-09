"use client";

import { SessionProvider } from "@/lib/auth/session-context";
import type { ReactNode } from "react";

export function Providers({ children }: { children: ReactNode }) {
  return <SessionProvider>{children}</SessionProvider>;
}
