"use client";

import { ROLE_HOME_TITLE, ROLE_LABEL, ROLE_NAV } from "@/lib/auth/roles";
import { useSession } from "@/lib/auth/session-context";
import { useState } from "react";
import { DonorBatchForm, DonorBatchList } from "./donor-batches";
import { OpportunityView } from "./opportunities";

export function HomeShell() {
  const { session, justRenewed, logout } = useSession();
  const [activeNav, setActiveNav] = useState<string | null>(null);
  const [loggingOut, setLoggingOut] = useState(false);

  if (!session) {
    return null;
  }

  const { user } = session;
  const nav = ROLE_NAV[user.role];
  const current = activeNav ?? nav[0]?.id;
  const title = ROLE_HOME_TITLE[user.role];
  const workflow =
    user.role === "DONOR" && current === "requests" ? (
      <DonorBatchList />
    ) : user.role === "DONOR" && current === "new-request" ? (
      <DonorBatchForm />
    ) : user.role === "RECYCLER" && current === "opportunities" ? (
      <OpportunityView />
    ) : null;

  async function onLogout() {
    setLoggingOut(true);
    await logout();
  }

  return (
    <div className="flex h-full min-h-0 w-full flex-1 overflow-hidden bg-slate-50">
      <aside className="flex w-56 flex-col bg-teal-900 text-white">
        <div className="border-b border-teal-800 px-4 py-4 text-sm font-semibold">
          {ROLE_LABEL[user.role]}
        </div>
        <nav className="flex flex-col gap-1 p-3" aria-label="Role navigation">
          {nav.map((item) => (
            <button
              key={item.id}
              type="button"
              onClick={() => setActiveNav(item.id)}
              className={`rounded-md px-3 py-2 text-left text-sm ${
                current === item.id ? "bg-teal-700" : "hover:bg-teal-800"
              }`}
            >
              {item.label}
            </button>
          ))}
        </nav>
      </aside>

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="flex items-center justify-end gap-4 border-b border-slate-200 bg-white px-6 py-3">
          <span
            className="rounded-full bg-teal-50 px-3 py-1 text-sm font-medium text-teal-900"
            aria-label={`Role ${ROLE_LABEL[user.role]}`}
          >
            {ROLE_LABEL[user.role]}
          </span>
          <span className="text-sm text-slate-700">{user.name}</span>
          <button
            type="button"
            onClick={onLogout}
            disabled={loggingOut}
            data-testid="logout"
            className="text-sm text-slate-600 hover:text-slate-900 disabled:opacity-50"
          >
            {loggingOut ? "Signing out…" : "Logout"}
          </button>
        </header>

        <main className="min-h-0 min-w-0 flex-1 overflow-y-auto px-8 py-6">
          <h1 className="mb-4 text-2xl font-bold text-slate-900">{title}</h1>
          {justRenewed ? (
            <p
              role="status"
              data-testid="session-renewed"
              className="mb-4 rounded-md border border-teal-200 bg-teal-50 px-3 py-2 text-sm text-teal-900"
            >
              Session renewed.
            </p>
          ) : null}
          {workflow ? (
            workflow
          ) : (
            <p className="max-w-xl text-sm text-slate-600">
              Signed in as {user.name} ({ROLE_LABEL[user.role]}). This section
              stays a placeholder until later sprint work.
            </p>
          )}
          <p className="mt-3 text-sm text-slate-500">
            Current section: {nav.find((item) => item.id === current)?.label}
          </p>
        </main>
      </div>
    </div>
  );
}
