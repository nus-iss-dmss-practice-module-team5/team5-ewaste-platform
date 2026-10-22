# Operational Runbook: CI/CD Pipeline & End-to-End Application Testing

**Platform:** Enterprise E-Waste Recycling & Chain-of-Custody Tracking System
**Active Production Environment:** Azure East Asia (`rg-ewaste-prod`)
**Perimeter Access Security Model:** **Only the Web Frontend UI (`aca-ewaste-prod-ui`) is accessible to the public endpoint.** Backend API Gateway (`aca-ewaste-prod-api`), Analytics Matcher Worker (`aca-ewaste-prod-analytics`), MySQL Flexible Server, and Redis Cache are strictly internal to the private Virtual Network (`vnet-ewaste-prod`).
**Environment Evolution:** `dev` $\rightarrow$ `stg` $\rightarrow$ `prod`
**Architecture:** Zero-Trust Private VNet Delegation, Microservices on Azure Container Apps (ACA), Private MySQL Flexible Server, Kafka/Redis Outbox Messaging.

---

## Table of Contents

1. [Environment Evolution & Architectural Perimeter](#1-environment-evolution--architectural-perimeter)
   - [Environment Progression (`dev` $\rightarrow$ `stg` $\rightarrow$ `prod`)](#environment-progression-dev-stg-prod)
   - [Ingress Perimeter & Access Boundary](#ingress-perimeter--access-boundary)
   - [Network Layout (`vnet-ewaste-prod`)](#network-layout-vnet-ewaste-prod)
   - [Active Service Endpoints & Discovery](#active-service-endpoints--discovery)
2. [CI/CD Pipeline Operations](#2-cicd-pipeline-operations)
   - [Workflow Matrix](#workflow-matrix)
   - [Pipeline 1: Infrastructure Deployment (Terraform)](#pipeline-1-infrastructure-deployment-terraform)
   - [Pipeline 2: CI Quality Gate & Security Baseline](#pipeline-2-ci-quality-gate--security-baseline)
   - [Pipeline 3: Private Database Migration (Liquibase)](#pipeline-3-private-database-migration-liquibase)
   - [Pipeline 4: Continuous Delivery (Build, Push & Deploy)](#pipeline-4-continuous-delivery-build-push--deploy)
3. [Test Personas & System Credentials](#3-test-personas--system-credentials)
4. [End-to-End Functional Testing (MVP Walkthrough via Public UI)](#4-end-to-end-functional-testing-mvp-walkthrough-via-public-ui)
   - [Phase 1: Donor Submits Batch](#phase-1-donor-submits-batch)
   - [Phase 2: Event-Driven Matching Engine Processing](#phase-2-event-driven-matching-engine-processing)
   - [Phase 3: Recycler Claim Flow](#phase-3-recycler-claim-flow)
   - [Phase 4: Concurrency Lock Verification (409 Conflict)](#phase-4-concurrency-lock-verification-409-conflict)
   - [Phase 5: Collector Logistics & Custody Finalization](#phase-5-collector-logistics--custody-finalization)
5. [Diagnostics & Troubleshooting Runbook (Internal Probes)](#5-diagnostics--troubleshooting-runbook-internal-probes)
6. [Rollback & Disaster Recovery Overview](#6-rollback--disaster-recovery-overview)

---

## 1. Environment Evolution & Architectural Perimeter

### Environment Progression (`dev` $\rightarrow$ `stg` $\rightarrow$ `prod`)

The deployment architecture matured through three distinct stages across sprints, transitioning from permissive development configurations to a fully hardened, zero-trust production posture:

```
┌─────────────────────────────────┐      ┌─────────────────────────────────┐      ┌─────────────────────────────────┐
│     dev (Sprint 1 & 2)          │      │     stg (Sprint 3)              │      │     prod (Sprint 4 - Active)    │
├─────────────────────────────────┤      ├─────────────────────────────────┤      ├─────────────────────────────────┤
│ • Region: malaysiawest          │      │ • Region: malaysiawest          │      │ • Region: eastasia              │
│ • Resource Group: rg-ewaste-dev │ ───► │ • Resource Group: rg-ewaste-stg │ ───► │ • Resource Group: rg-ewaste-prod│
│ • Permissive Ingress All Public │      │ • Perimeter Hardening           │      │ • ZERO-TRUST PERIMETER LOCKDOWN │
│ • Destroyed: 09-Oct-2026        │      │ • Pre-production Validation     │      │ • ONLY Web UI Publicly Exposed  │
└─────────────────────────────────┘      └─────────────────────────────────┘      └─────────────────────────────────┘
```

1. **Development (`dev` - Sprints 1 & 2):** Initial proof-of-concept deployed in `malaysiawest` (`rg-ewaste-dev`). For rapid testing, container apps were configured with external ingress (`*.kindflower-300f4866...` and `*.salmoncoast-1b1c8372...`). Following subscription migration to `f79417cc-cf5f-4407-809a-1d1bf544571d`, this environment was **permanently decommissioned and destroyed on 9 October 2026** (resolving Finding 9).
2. **Staging (`stg` - Sprint 3):** Pre-production integration environment deployed in `eastasia` (`rg-ewaste-stg`). Began perimeter lockdown: the analytics matcher worker ingress was converted to internal-only, and Key Vault was removed in favor of ACA encrypted secrets and User-Assigned Managed Identity.
3. **Production (`prod` - Sprint 4):** Live production baseline in `eastasia` (`rg-ewaste-prod`). Full defense-in-depth perimeter enforcement: **only the Web Frontend UI is accessible from the public internet**. All backend microservices, data stores, and message brokers are isolated within private virtual network boundaries.

---

### Ingress Perimeter & Access Boundary

> [!IMPORTANT]
> **Production Ingress Security Rule:**
> **Only the Web Frontend UI (`aca-ewaste-prod-ui`) exposes a public endpoint.**
> The Backend API Gateway (`aca-ewaste-prod-api`) and Analytics Matcher Worker (`aca-ewaste-prod-analytics`) have **internal ingress only**. Outside users, browsers, and external networks cannot establish direct connections to the backend API.

```
Public Internet (Users, Donors, Recyclers, Collectors, Admins)
                           │
                           │ HTTPS (Port 443)
                           ▼
  ┌─────────────────────────────────────────────────────────────┐
  │  aca-ewaste-prod-ui (PUBLIC INGRESS - ONLY PUBLIC ENDPOINT) │
  │  https://aca-ewaste-prod-ui.eastasia.azurecontainerapps.io  │
  └──────────────────────────────┬──────────────────────────────┘
                                 │ Internal VNet Proxy (Next.js BFF / API Route Proxy)
                                 ▼
════════════════════════════════════════════════════════════════════════════════════════
  PRIVATE VIRTUAL NETWORK PERIMETER (vnet-ewaste-prod / 10.0.0.0/16)
════════════════════════════════════════════════════════════════════════════════════════
    │                                                   │
    ▼                                                   ▼
┌──────────────────────────────────────┐     ┌──────────────────────────────────────┐
│ aca-ewaste-prod-api                  │     │ aca-ewaste-prod-analytics            │
│ (INTERNAL INGRESS ONLY - Port 8080)  │ ◄─► │ (INTERNAL INGRESS ONLY - Port 8000)  │
│ Host: internal ACA cluster DNS       │     │ Host: internal ACA cluster DNS       │
└──────────────────┬───────────────────┘     └──────────────────────────────────────┘
                   │                                            │
                   ▼                                            ▼
┌──────────────────────────────────────┐     ┌──────────────────────────────────────┐
│ mysql-ewaste-prod (snet-mysql)       │     │ redis-ewaste-prod (snet-pe)          │
│ Private VNet Delegation (Port 3306)  │     │ Private Endpoint (Port 6380)         │
│ Zero Public IP                       │     │ Zero Public IP                       │
└──────────────────────────────────────┘     └──────────────────────────────────────┘
```

---

### Network Layout (`vnet-ewaste-prod` - Production CIDR: `10.0.0.0/16`, Region: `eastasia`)

The production infrastructure architecture is partitioned into **exactly 4 dedicated subnets** inside `vnet-ewaste-prod` (`10.0.0.0/16`):

| Subnet Name                  | Address Prefix | Ingress Visibility                             | Purpose & Access Model                                                                                                                                                                                                                                           |
| :--------------------------- | :------------- | :--------------------------------------------- | :--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`snet-aca`**               | `10.0.8.0/21`  | **Mixed** (UI: Public; API & Worker: Internal) | Delegated to Azure Container Apps environment (`cae-ewaste-prod`). Hosts `aca-ewaste-prod-ui` (external: true, ONLY public endpoint), `aca-ewaste-prod-api` (external: false, internal cluster ingress only), and `aca-ewaste-prod-analytics` (external: false). |
| **`snet-mysql`**             | `10.0.2.0/24`  | **Strictly Private** (Zero Public IP)          | 100% Private Delegation to `Microsoft.DBforMySQL/flexibleServers`. Private DNS: `mysql-ewaste-prod.mysql.database.azure.com:3306`.                                                                                                                               |
| **`snet-private-endpoints`** | `10.0.3.0/24`  | **Strictly Private** (Zero Public IP)          | Shared private endpoints subnet hosting Azure Cache for Redis (`redis-ewaste-prod.redis.cache.windows.net:6380`), Production Blob Storage (`stgewasteprod`), and Shared Container Registry (`acrewasteplatform.azurecr.io`).                                     |
| **`snet-runner`**            | `10.0.4.0/24`  | **Internal Egress Only**                       | Production Self-Hosted Runner VM (`vm-runner-ewaste-prod`). Inbound strictly denied by NSG; outbound long-polling to GitHub Actions. Used for Liquibase migrations and private diagnostic commands.                                                              |

---

### Active Service Endpoints & Discovery

All live service addresses are cataloged in the canonical **[Endpoint Registry](file:///C:/Users/laksh/Documents/NUS-ISS%20MTech%20SE/1%20-%20SWE5006%20-%20Designing%20Modern%20Software%20Systems/Practice%20Module/GitHub%20Codebase/team5-ewaste-platform/docs/ENDPOINT_REGISTRY.md)**.

| Component                     | Azure Resource              | Ingress Exposure                    | Accessible Host / URL                             | Primary Health Probe                                    |
| :---------------------------- | :-------------------------- | :---------------------------------- | :------------------------------------------------ | :------------------------------------------------------ |
| **Web Frontend UI**           | `aca-ewaste-prod-ui`        | **PUBLIC (External)**               | Refer to query below to get UI FQDN               | `GET /` (HTTP 200)                                      |
| **Backend API Gateway**       | `aca-ewaste-prod-api`       | **INTERNAL ONLY**                   | Internal cluster DNS / `snet-aca`                 | `GET /healthz`, `GET /readyz` (via Runner VM or UI BFF) |
| **Analytics Matcher Worker**  | `aca-ewaste-prod-analytics` | **INTERNAL ONLY**                   | Internal cluster DNS / `snet-aca`                 | `GET /readyz` (via internal cluster ingress)            |
| **MySQL Flexible Server**     | `mysql-ewaste-prod`         | **INTERNAL ONLY**                   | `mysql-ewaste-prod.mysql.database.azure.com:3306` | TCP 3306 Handshake via `vm-runner-ewaste-prod`          |
| **Azure Cache for Redis**     | `redis-ewaste-prod`         | **INTERNAL ONLY**                   | `redis-ewaste-prod.redis.cache.windows.net:6380`  | Redis PING via internal VNet link                       |
| **Shared Container Registry** | `acrewasteplatform`         | **Private Link / Managed Identity** | `acrewasteplatform.azurecr.io`                    | `az acr check-health` (Cosign signed)                   |
| **Centralized Log Analytics** | `log-ewaste-centralized`    | **Private / Azure RBAC**            | Diagnostic sink for ACA & PaaS logs (East Asia)   | KQL Workspace API                                       |

#### Dynamic Endpoint Discovery CLI

To query active FQDNs from Azure CLI:

```bash
export RG="rg-ewaste-prod"

# 1. Query the PUBLIC Web Frontend UI endpoint (Accessible from anywhere)
UI_FQDN=$(az containerapp show \
  --name "aca-ewaste-prod-ui" \
  --resource-group "$RG" \
  --query "properties.configuration.ingress.fqdn" -o tsv)
echo "Public Frontend UI: https://${UI_FQDN}"
```

---

## 2. CI/CD Pipeline Operations

### Workflow Matrix

```
       [Developer Push / PR]
                 │
                 ▼
      ┌─────────────────────┐
      │     ci-gate.yml     │  (Pre-commit, Gitleaks, Unit Tests, Checkov, Syft SBOM)
      └──────────┬──────────┘
                 │ (Merge to main / production release)
                 ▼
 ┌───────────────────────────┐
 │   terraform-infra-create.yml  (Provisions/updates vnet-ewaste-prod in eastasia)
 └───────────┬───────────────┘
                 │
                 ▼
 ┌───────────────────────────┐
 │    database-migration.yml   │  (Runs Liquibase on Self-Hosted Runner inside snet-runner)
 └───────────┬───────────────┘
                 │
                 ▼
 ┌───────────────────────────┐
 │        cd-pipeline.yml      │  (Build Docker -> Cosign Sign -> Deploy to prod ACA by Digest)
 └───────────────────────────┘
```

---

### Pipeline 1: Infrastructure Deployment (Terraform)

- **Workflow:** `.github/workflows/terraform-infra-create.yml`
- **Trigger:** Manual dispatch or push modifying `terraform/**`.
- **Execution Environment:** GitHub-hosted Ubuntu runner using Azure OIDC federated credentials.
- **Key Tasks:**
  1. Checks out repository and initializes remote state in Azure Blob Storage (`rg-ewaste-tfstate`).
  2. Runs Checkov static analysis across all `.tf` modules.
  3. Executes `terraform apply` targeting `terraform/shared` and `terraform/environments` in **`eastasia`**.
  4. Enforces ingress boundary: `azurerm_container_app.ui` configured with `external_enabled = true`; `azurerm_container_app.api` and `azurerm_container_app.analytics` configured with internal ingress.

---

### Pipeline 2: CI Quality Gate & Security Baseline

- **Workflow:** `.github/workflows/ci-gate.yml`
- **Trigger:** Pull Requests targeting `main`; pushes to `main`.
- **Gate Checks:**
  1. **Pre-commit Quality Checks:** Linting, whitespace, markdown formatting.
  2. **Gitleaks Secret Detection:** Prevents credential leaks in commits.
  3. **Backend Service Gate:** Go 1.26 tests (`go test -race ./...`) and `golangci-lint`.
  4. **Frontend UI Gate:** Node.js 22 linting, unit test suite (`npm run test`), and bundle build (`npm run build`).
  5. **Matcher Analytics Gate:** Python 3.12 `pytest` with enforced minimum code coverage threshold (85%).
  6. **Checkov Security Gate:** Enforces zero high/critical vulnerabilities across IaC templates.

---

### Pipeline 3: Private Database Migration (Liquibase)

- **Workflow:** `.github/workflows/database-migration.yml`
- **Trigger:** Dispatch or push modifying `database/**`.
- **Execution Environment:** **Production Self-Hosted Runner (`runs-on: [self-hosted, azure-vnet, prod]`)** inside `snet-runner`.
- **Key Tasks:**
  1. **Internal VNet Connectivity:** Runs directly on `vm-runner-ewaste-prod` with native line-of-sight to `mysql-ewaste-prod.mysql.database.azure.com:3306`.
  2. **Pre-flight Healthcheck:** Validates Azure login, retrieves DB credentials via ACA encrypted secrets, and verifies `ewastedb` connectivity.
  3. **Liquibase Migration:** Executes Liquibase Docker container directly on the internal VNet.
  4. Applies changesets `001` through `032+` with non-breaking Expand/Contract conventions.

---

### Pipeline 4: Continuous Delivery (Build, Push & Deploy)

- **Workflow:** `.github/workflows/cd-pipeline.yml`
- **Trigger:** Push to `main` or manual workflow dispatch targeting `prod`.
- **Execution Environment:** Self-hosted runner for zero-network-egress deployment.
- **Key Tasks:**
  1. **ACR Authentication:** Authenticates using Azure User-Assigned Managed Identity via OIDC (No admin passwords).
  2. **Immutable Image Build & Signing:** Builds immutable container images, generates Syft SBOMs, Grype CVE scans, and signs with Cosign:
     - `workflow-api:prod-<sha>@sha256:...`
     - `workflow-ui:prod-<sha>@sha256:...`
     - `workflow-analytics:prod-<sha>@sha256:...`
  3. **Container App Revisions:** Deploys new revisions to `rg-ewaste-prod` using `az containerapp update --image <digest>` strictly by `@sha256:` digest with zero-downtime rolling updates.
  4. **Health Validation:** Validates internal readiness probes before traffic shift.

---

## 3. Test Personas & System Credentials

All mock accounts share the unified test password:

> **Default Test Password:** `TestOnly#2026!`

| Role           | Username / Email         | Organization            | Org ID      | Capabilities / Responsibilities                                                                                                                 |
| :------------- | :----------------------- | :---------------------- | :---------- | :---------------------------------------------------------------------------------------------------------------------------------------------- |
| **Donor**      | `donor1@ewaste.test`     | GreenCorp Tech          | `ORG-001`   | Creates, edits, and submits e-waste disposal batches via the public UI.                                                                         |
| **Recycler 1** | `recycler1@ewaste.test`  | EcoCycle Processors     | `PROC-001`  | Claims batches in `NORTH`, `SOUTH`, `EAST`, `WEST`, `CENTRAL`. Handles `ICT_EQUIPMENT`, `LARGE_APPLIANCE`, `BATTERIES`, `CONSUMER_ELECTRONICS`. |
| **Recycler 2** | `recycler2@ewaste.test`  | RenewTech Solutions     | `PROC-002`  | Competitor recycler. Used for concurrency conflict testing (409) via the public UI.                                                             |
| **Collector**  | `collector1@ewaste.test` | GreenHaul Logistics     | `COL-001`   | Linked to `PROC-001`. Finalizes pickup completion or logs pickup failure.                                                                       |
| **Admin**      | `admin@ewaste.test`      | State Regulatory Agency | `ADMIN-001` | System audit, global batch oversight, matching rule inspection, and release security artifact review (D5: no custody evidence file download).   |

---

## 4. End-to-End Functional Testing (MVP Walkthrough via Public UI)

Because the Backend API is internal to the VNet, **all functional testing and user verification flows are executed through the Public Frontend UI (`https://${UI_FQDN}`)**:

```
[Donor via Public UI] ──► [Matcher Worker (Internal)] ──► [Recycler via Public UI] ──► [Collector via Public UI]
     (SUBMITTED)                   (MATCHED)                       (CLAIMED)                (COLLECTED / FAILED)
```

---

### Phase 1: Donor Submits Batch

1. Open the **Public Production UI**: `https://${UI_FQDN}` (e.g. `https://aca-ewaste-prod-ui.eastasia.azurecontainerapps.io`).
2. Log in as **`donor1@ewaste.test`** / `TestPassword123!`.
3. Click **"New Batch"** and fill in valid parameters:
   - **Category:** `ICT_EQUIPMENT`
   - **Estimated Weight (kg):** `150.50` _(Maximum 2 decimal places, 0.10 to 50000.00)_
   - **Quantity:** `10` _(Integer, 1 to 100000)_
   - **Condition:** `REPAIRABLE`
   - **Data Bearing:** `Yes`
   - **Collection Zone:** `NORTH`
   - **Collection Deadline:** Choose a date between **48 hours** and **90 days** in the future.
4. Click **"Submit Batch"**.
5. **Expected Result:**
   - Next.js UI forwards request to internal API Gateway.
   - Status updates to **`SUBMITTED`**.
   - Batch is written to `ewaste_batches` and an event is queued in Kafka topic `ewaste.batch.events`.

---

### Phase 2: Event-Driven Matching Engine Processing

1. The internal production analytics container (`aca-ewaste-prod-analytics`) polls the Kafka topic.
2. The worker extracts the batch event and queries internal API endpoint `POST /internal/v1/matching/runs`.
3. The matching engine evaluates the 5 business rules:
   - `M1` (Category Capability): `PROC-001` supports `ICT_EQUIPMENT`.
   - `M2` (Condition & Data): `PROC-001` accepts `REPAIRABLE` and supports data wipe.
   - `M3` (Capacity Pool): Pool capacity (`50000 kg`) >= `150.50 kg`.
   - `M4` (Zone Coverage): `NORTH` is active in service zones.
   - `M5` (Feasibility): Evaluation timestamp + minimum lead time <= Collection deadline.
4. **Expected Result:**
   - Matcher successfully posts run decision.
   - Batch transitions from `SUBMITTED` to **`MATCHED`**.
   - An opportunity record is created for `PROC-001`.

---

### Phase 3: Recycler Claim Flow

1. Log out and log in as **`recycler1@ewaste.test`** / `TestPassword123!` via the public UI.
2. Navigate to **"Matched Opportunities"** (`/opportunities`).
3. Locate the batch submitted in Phase 1.
4. Click **"Claim Opportunity"**.
5. Select default collector: **`COL-001 (GreenHaul Logistics)`**.
6. Submit the claim.
7. **Expected Result:**
   - Batch status transitions to **`CLAIMED`**.
   - Assigned Recycler is set to `PROC-001`.
   - Assigned Collector is set to `COL-001`.

---

### Phase 4: Concurrency Lock Verification (409 Conflict)

To prove the MVP requirement: _"Exactly one concurrent claim succeeds"_:

1. Open an Incognito window or second browser pointing to the public UI.
2. Log in as **`recycler2@ewaste.test`** / `TestPassword123!`.
3. Attempt to call the claim endpoint for the exact same batch ID.
4. **Expected Result:**
   - UI receives HTTP **`409 Conflict`** from internal API.
   - UI surfaces error message: `BATCH_ALREADY_CLAIMED` or `CLAIM_EPOCH_MISMATCH`.
   - The database record remains assigned exclusively to `PROC-001`.

---

### Phase 5: Collector Logistics & Custody Finalization

1. Log in as **`collector1@ewaste.test`** / `TestPassword123!` via the public UI.
2. Navigate to **"My Pickups"**.
3. Select the claimed batch.

#### Scenario A: Successful Pickup

1. Click **"Complete Pickup"**.
2. Enter:
   - **Gross Weight (kg):** `152.00`
   - **Weighbridge / Scale Ticket Reference:** `WT-99482`
   - **Donor Handover Signature / Notes:** `Confirmed by site manager.`
3. Submit handover.
4. **Expected Result:** Batch status transitions to **`COLLECTED`**. Chain of custody is finalized.

#### Scenario B: Pickup Exception / Failure

1. If the premises are closed or materials mismatch: Click **"Report Pickup Failure"**.
2. Select reason: `PREMISES_UNREACHABLE` or `HAZARDOUS_MISMATCH`.
3. Submit report.
4. **Expected Result:** Batch status transitions to **`PICKUP_FAILED`**. Alert is triggered for donor re-coordination.

---

## 5. Diagnostics & Troubleshooting Runbook (Internal Probes)

Because the Backend API, Matcher Worker, and MySQL database have **no public IP endpoints**, administrative checks and direct database queries must be executed through the internal Virtual Network via the production runner VM (`vm-runner-ewaste-prod`) or Azure CLI.

### 1. Direct MySQL Query via Production Runner VM

```bash
RG="rg-ewaste-prod"
RUNNER_VM="vm-runner-ewaste-prod"
MYSQL_HOST="mysql-ewaste-prod.mysql.database.azure.com"

az vm run-command invoke \
  --resource-group "$RG" \
  --name "$RUNNER_VM" \
  --command-id RunShellScript \
  --scripts "docker run --rm mysql:8.0 mysql -h ${MYSQL_HOST} -u ewasteadmin -p'\$DB_PASSWORD' ewastedb -e 'SELECT id, status, category, estimated_weight_kg FROM ewaste_batches ORDER BY created_at DESC LIMIT 5;'" \
  --query "value[0].message" -o tsv
```

### 2. Inspecting Real-Time Production Container Logs

Stream logs directly via the Azure control plane (Zero public ingress required):

```bash
RG="rg-ewaste-prod"

# Backend API Gateway Request & Error Logs
az containerapp logs show \
  --name "aca-ewaste-prod-api" \
  --resource-group "$RG" \
  --tail 50 \
  --follow

# Matcher Analytics Worker Event Processing Logs
az containerapp logs show \
  --name "aca-ewaste-prod-analytics" \
  --resource-group "$RG" \
  --tail 50 \
  --follow
```

### 3. Internal API Health Probe via Runner VM

To test the internal Backend API directly without going through the UI:

```bash
RG="rg-ewaste-prod"
RUNNER_VM="vm-runner-ewaste-prod"

az vm run-command invoke \
  --resource-group "$RG" \
  --name "$RUNNER_VM" \
  --command-id RunShellScript \
  --scripts "curl -fsSL https://aca-ewaste-prod-api.eastasia.azurecontainerapps.io/healthz" \
  --query "value[0].message" -o tsv
```

### 4. Common Error Signatures & Remediation

| Symptom                                            | Root Cause                                                 | Remediation Step                                                                              |
| :------------------------------------------------- | :--------------------------------------------------------- | :-------------------------------------------------------------------------------------------- |
| `VALIDATION_ERROR: one or more fields are invalid` | Collection deadline < 48 hours or weight decimals > 2.     | Set collection date at least 3 days into the future; ensure weight has max 2 decimal places.  |
| `503 UNSUPPORTED_RULE_SET`                         | `matching_rule_sets` table has no active records.          | Run seed changeset `105-seed-matching-fixtures.sql` via Liquibase on `vm-runner-ewaste-prod`. |
| Recycler sees 0 opportunities                      | Capabilities, pools, or zones not seeded for recycler org. | Verify recycler records in `recycler_category_capabilities` and `recycler_service_zones`.     |
| Concurrency test returns 500 instead of 409        | Transaction isolation or lock missing.                     | Verify `claim_epoch` conditional update in `store.go:ClaimOpportunity()`.                     |

---

## 6. Rollback & Disaster Recovery Overview

The platform implements an **Atomic Blue/Green Revision Gating & Smart Fast-Path Rollback** architecture designed for `< 2 minutes` MTTR, zero downtime, and zero cloud resource waste.

> [!IMPORTANT]
> **Dedicated Runbook:** For the comprehensive architectural trade-off analysis (Atomic Blue/Green vs. Canary), step-by-step dispatch walkthroughs, out-of-band Azure CLI commands, Liquibase schema rollback protocols, and the official rehearsal sign-off checklist, refer directly to the dedicated runbook:
> 📄 **[ROLLBACK_AND_DISASTER_RECOVERY_RUNBOOK.md](file:///C:/Users/laksh/Documents/NUS-ISS%20MTech%20SE/1%20-%20SWE5006%20-%20Designing%20Modern%20Software%20Systems/Practice%20Module/GitHub%20Codebase/team5-ewaste-platform/docs/ROLLBACK_AND_DISASTER_RECOVERY_RUNBOOK.md)**

### Key SLA & Operational Guarantees

- **MTTR Target:** `< 2 minutes` from regression detection to active stable baseline.
- **Smart Zero-Lookup Dispatch:** Operators enter `PREVIOUS` (or `N-1`) under `rollback_tag` in GitHub Actions. The pipeline autonomously queries ACR for the preceding verified image (`sed -n '2p'`), skipping manual catalog searches.
- **Build Bypass:** Docker build and image push steps are bypassed entirely; verified immutable images are pulled directly from ACR.
- **Atomic Zero-Downtime Cutover:** Azure Container Apps switches 100% traffic only after new revision readiness probes (`/healthz`, UI root, `/readyz`) return HTTP 200.
- **Retention Protection:** Historical container image pruning is automatically disabled during rollback operations (`is_rollback == 'true'`).

### Quick Reference: Fast-Path Rollback Trigger on Production

1. Navigate to GitHub **Actions** $\rightarrow$ **`CD - Multi-Environment Deployment & Evidence Pipeline`**.
2. Click **Run workflow**:
   - **Target Azure Runtime Environment:** `prod`
   - **Optional: Image tag to rollback to:** Enter **`PREVIOUS`** (or an explicit tag e.g. `prod-06b1ee6`).
3. Click **Run workflow** (Recovers in $\approx 90$ seconds).
