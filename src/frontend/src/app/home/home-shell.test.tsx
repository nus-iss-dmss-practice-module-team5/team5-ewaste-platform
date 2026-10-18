import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Role } from "@/lib/auth/types";
import { HomeShell } from "./home-shell";

let role: Role = "ADMIN";

vi.mock("@/lib/auth/session-context", () => ({
  useSession: () => ({
    session: {
      user: { id: "USR-005", name: "Platform Administrator", role },
      tokens: { accessToken: "access-token" },
    },
    justRenewed: false,
    logout: vi.fn(),
  }),
}));

// Each screen is replaced by a marker so only the shell's routing is tested.
vi.mock("./admin", () => ({
  PlatformHealthView: () => <p data-testid="screen-platform-health" />,
  ReleaseView: () => <p data-testid="screen-release" />,
}));
vi.mock("./custody", () => ({
  CustodyView: () => <p data-testid="screen-custody" />,
}));
vi.mock("./impact", () => ({
  ImpactView: () => <p data-testid="screen-impact" />,
}));
vi.mock("./claim-action", () => ({ ClaimAction: () => null }));
vi.mock("./collector-work", () => ({ CollectorWork: () => null }));
vi.mock("./donor-batches", () => ({
  DonorBatchForm: () => null,
  DonorBatchList: () => null,
}));
vi.mock("./opportunities", () => ({ OpportunityView: () => null }));
vi.mock("./processing", () => ({ ProcessingWork: () => null }));

function navLabels(): string[] {
  return within(screen.getByRole("navigation", { name: "Role navigation" }))
    .getAllByRole("button")
    .map((button) => button.textContent ?? "");
}

beforeEach(() => {
  role = "ADMIN";
});

describe("HomeShell for the Administrator", () => {
  it("opens on Platform health and offers only Platform health and Release", async () => {
    render(<HomeShell />);

    expect(navLabels()).toEqual(["Platform health", "Release"]);
    expect(screen.getByRole("heading", { level: 1 })).toHaveTextContent(
      "Platform health",
    );
    expect(screen.getByTestId("screen-platform-health")).toBeInTheDocument();

    await userEvent.click(screen.getByRole("button", { name: "Release" }));

    expect(screen.getByRole("heading", { level: 1 })).toHaveTextContent(
      "Release",
    );
    expect(screen.getByTestId("screen-release")).toBeInTheDocument();
  });

  it("has no Custody or Impact route (D5)", () => {
    render(<HomeShell />);

    expect(navLabels()).not.toContain("Custody");
    expect(screen.queryByTestId("screen-custody")).toBeNull();
    expect(screen.queryByTestId("screen-impact")).toBeNull();
  });
});

describe.each<Role>(["AUDITOR", "RECYCLER", "DONOR", "COLLECTOR"])(
  "HomeShell for %s",
  (other) => {
    it("shows no Admin tab and never renders the Admin screens", () => {
      role = other;
      render(<HomeShell />);

      expect(navLabels()).not.toContain("Platform health");
      expect(navLabels()).not.toContain("Release");
      expect(screen.queryByTestId("screen-platform-health")).toBeNull();
      expect(screen.queryByTestId("screen-release")).toBeNull();
    });
  },
);
