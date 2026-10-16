# Retained Software Bill of Materials (SBOM) Catalog

**Task Reference:** `S4-SG-I-L-01: Promote only signed digests from ACR and retain each release's SBOM` (EWCSB-215)
**Governance Standard:** `EWCSB-241: Release Security Gate Policy`
**Lead / Author:** Lakshanya Poovannan (DevSecOps & Cloud Platform Lead)
**Approver / Reviewer:** Shalett Paulson (Security & Release Governance Lead)
**Date:** 16 October 2026
**Format:** SPDX 2.3 JSON (`format: spdx-json`)
**Retention Mandate:** 90 Days (Workflow run artifacts)

---

## 1. Scope & Purpose

Every container release candidate built for the E-Waste Platform generates a Software Bill of Materials (SBOM) using **Anchore Syft** in the CD pipeline.

SBOMs are retained for 90 days as GitHub Actions workflow artifacts. They provide:
1. Machine-readable software component and package inventories for compliance and security auditing.
2. Supply chain transparency records for release verification.
3. Traceable manifests linked to each deployed container image digest.

---

## 2. Release SBOM Artifacts & Repository Baseline Catalog

| Service Component | Container Image | Repository Baseline File | Target Runtime | Package Ecosystem |
| :--- | :--- | :--- | :---: | :---: |
| **Backend REST Engine** | `workflow-api` | [`sbom-workflow-api.spdx.json`](./sbom-workflow-api.spdx.json) | Go 1.26 Static ELF | `go.mod` (Go Modules) |
| **Frontend Web Portal** | `workflow-ui` | [`sbom-workflow-ui.spdx.json`](./sbom-workflow-ui.spdx.json) | Next.js 16.3.6 / Node 20 | `package.json` (npm) |
| **Matching & Analytics Worker** | `workflow-analytics` | [`sbom-workflow-analytics.spdx.json`](./sbom-workflow-analytics.spdx.json) | Python 3.12 (Debian slim) | `requirements.txt` (pip) |

> [!NOTE]
> **Baseline Files vs. Pipeline Artifacts:**
> The committed `.spdx.json` files in this directory represent application-level baseline dependency manifests derived directly from repository source manifests (`go.mod`, `package.json`, `requirements.txt`).
> During each CD pipeline run, Anchore Syft scans the **entire built container image** (`syft "$IMAGE_TAG"`), capturing all underlying OS packages (`apk` / `dpkg`), runtime libraries, and application dependencies into 90-day retained workflow artifacts named `sbom-workflow-<service>-<tag>`.

---

## 3. Automated Pipeline Generation & Verification

In the CD pipeline ([`.github/workflows/cd-pipeline.yml`](../../.github/workflows/cd-pipeline.yml)), the following sequence executes for each container:

1. **Immutable Digest Verification:**
   The image digest is retrieved from Docker inspect and strictly verified to ensure it contains an immutable `@sha256:` locator:
   ```bash
   API_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "$IMAGE_TAG")
   [[ "$API_DIGEST" == *@sha256:* ]] || { echo '::error::API image digest is missing or mutable.' >&2; exit 1; }
   ```

2. **Automated Generation via Anchore Syft:**
   ```bash
   syft "${IMAGE_TAG}" -o spdx-json="releases/sboms/sbom-${SERVICE}.spdx.json"
   test -s "releases/sboms/sbom-${SERVICE}.spdx.json" || { echo "::error::SBOM is missing or empty." >&2; exit 1; }
   ```

3. **90-Day Artifact Upload:**
   Archived using `actions/upload-artifact@v4` with `retention-days: 90`.

4. **Cryptographic Signing (Fresh Builds Only):**
   Fresh builds (`is_rollback != 'true'`) are signed with Cosign using the repository secret `COSIGN_PRIVATE_KEY`.
   *(During rollbacks, existing images in ACR are not re-signed; their existing signature must be valid).*

5. **Signature Verification Gate:**
   Prior to updating Azure Container Apps, Cosign verifies the image digest strictly against the committed team public key:
   ```bash
   cosign verify --key security/cosign.pub "${IMAGE_DIGEST}"
   ```
