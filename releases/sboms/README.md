# Retained Software Bill of Materials (SBOM) Catalog

**Task Reference:** `S4-SG-I-L-01: Promote only signed digests from ACR and retain each release's SBOM` (EWCSB-215)
**Governance Standard:** `EWCSB-241: Release Security Gate Policy` (Section 2 Principle 2, Section 6)
**Lead / Author:** Lakshanya Poovannan (DevSecOps & Cloud Platform Lead)
**Approver / Reviewer:** Shalett Paulson (Security & Release Governance Lead)
**Date:** 15 October 2026
**Format:** SPDX 2.3 JSON (`format: spdx-json`)
**Retention Mandate:** 90 Days (Workflow run artifacts & Release Evidence Repository)

---

## 1. Scope & Purpose

In compliance with **EW-401 Acceptance Criterion 2** and **Refusal Test RT-16 (Missing SBOM blocks signing & deployment)**, every container release candidate built for the E-Waste Platform generates an immutable Software Bill of Materials (SBOM) using **Anchore Syft**.

SBOMs are generated at container build time, pinned to the exact container image SHA-256 digest, and retained for 90 days. They serve as:
1. The authoritative inventory for **Grype vulnerability scanning** during Gate 2.
2. Supply chain transparency records for release sign-off (EWCSB-224).
3. Runtime verification metadata linked on the System Administrator Release Dashboard (EWCSB-240 / EWCSB-245).

---

## 2. Retained Release SBOM Catalog

| Service Component | Container Image | SBOM Artifact File | Target Runtime | Package Manager | Direct & Transitive Dependencies |
| :--- | :--- | :--- | :---: | :---: | :---: |
| **Backend REST Engine** | `workflow-api` | [`sbom-workflow-api.spdx.json`](file:///C:/Users/laksh/Documents/NUS-ISS%20MTech%20SE/1%20-%20SWE5006%20-%20Designing%20Modern%20Software%20Systems/Practice%20Module/GitHub%20Codebase/team5-ewaste-platform/releases/sboms/sbom-workflow-api.spdx.json) | Go 1.26 Static ELF | `go.mod` (Go Modules) | 60 Packages (Gin, GORM, Azure SDK, Kafka, Zap) |
| **Frontend Web Portal** | `workflow-ui` | [`sbom-workflow-ui.spdx.json`](file:///C:/Users/laksh/Documents/NUS-ISS%20MTech%20SE/1%20-%20SWE5006%20-%20Designing%20Modern%20Software%20Systems/Practice%20Module/GitHub%20Codebase/team5-ewaste-platform/releases/sboms/sbom-workflow-ui.spdx.json) | Next.js 16.3.6 / Node 20 | `package.json` (npm) | 18 Packages (React 19, Tailwind, Axios, Vitest) |
| **Matching & Analytics Worker** | `workflow-analytics` | [`sbom-workflow-analytics.spdx.json`](file:///C:/Users/laksh/Documents/NUS-ISS%20MTech%20SE/1%20-%20SWE5006%20-%20Designing%20Modern%20Software%20Systems/Practice%20Module/GitHub%20Codebase/team5-ewaste-platform/releases/sboms/sbom-workflow-analytics.spdx.json) | Python 3.12 (Debian slim) | `requirements.txt` (pip) | 7 Packages (confluent-kafka, jsonschema, referencing) |

---

## 3. Automated Generation & Promotion Pipeline

In the CD pipeline ([`.github/workflows/cd-pipeline.yml`](file:///C:/Users/laksh/Documents/NUS-ISS%20MTech%20SE/1%20-%20SWE5006%20-%20Designing%20Modern%20Software%20Systems/Practice%20Module/GitHub%20Codebase/team5-ewaste-platform/.github/workflows/cd-pipeline.yml)), SBOMs are automatically produced and archived:

```bash
# 1. Automated Generation via Anchore Syft
syft packages "${ACR_SERVER}/${SERVICE}:${TARGET_TAG}" \
  --output spdx-json > "releases/sboms/sbom-${SERVICE}.spdx.json"

# 2. Gate 2 Failure Rule (RT-16: Fail Closed)
if [ ! -s "releases/sboms/sbom-${SERVICE}.spdx.json" ]; then
  echo "::error::Missing or empty SBOM for ${SERVICE}. Refusing deployment (RT-16)."
  exit 1
fi
```

---

## 4. Retention & Traceability Guarantee

1. **90-Day GitHub Actions Artifact Retention:** Every CI/CD run uploads `sbom-spdx-json` with `retention-days: 90`.
2. **Digest Pinned (`Principle 2`):** The SBOM document namespace and root package locator embed the immutable `@sha256:...` digest matching the deployed revision.
3. **Refusal Enforcement (RT-16):** If the SBOM step fails or is skipped for any image in the release set, Cosign signing is blocked, and deployment is strictly **REFUSED**.
