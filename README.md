# Responsible E-Waste Platform

[![Azure Container Apps](https://img.shields.io/badge/Azure_Container_Apps-0078D4?logo=microsoftazure&logoColor=white)](https://azure.microsoft.com/en-us/products/container-apps)
[![Go Version](https://img.shields.io/badge/Go-1.26-00ADD8?logo=go&logoColor=white)](https://golang.org)
[![Python Version](https://img.shields.io/badge/Python-3.12-3776AB?logo=python&logoColor=white)](https://python.org)
[![Next.js / React](https://img.shields.io/badge/Next.js-16_/_React_19-black?logo=next.js&logoColor=white)](https://nextjs.org)
[![MySQL](https://img.shields.io/badge/MySQL-8.0_Flexible_Server-4479A1?logo=mysql&logoColor=white)](https://www.mysql.com)
[![Redis](https://img.shields.io/badge/Redis-7.2_Cache-DC382D?logo=redis&logoColor=white)](https://redis.io)
[![Apache Kafka](https://img.shields.io/badge/Apache_Kafka-Event_Hubs-231F20?logo=apachekafka&logoColor=white)](https://kafka.apache.org)
[![Cosign Signed](https://img.shields.io/badge/Cosign-Signed_Digests-4B32C3?logo=sigstore&logoColor=white)](https://github.com/sigstore/cosign)
[![License](https://img.shields.io/badge/License-Academic_Use-blue.svg)](LICENSE)

An enterprise-grade, DevSecOps-enabled electronic waste recycling, chain-of-custody tracking, and environmental impact analytics platform. Engineered for **SWE5006: Designing Modern Software Systems** (Practice Module) by **Team 5** at the National University of Singapore, Institute of Systems Science (NUS-ISS).

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Project Team & Roles](#project-team--roles)
3. [System Architecture & Security Perimeter](#system-architecture--security-perimeter)
   - [Zero-Trust Ingress Boundary](#zero-trust-ingress-boundary)
   - [Architectural Topology](#architectural-topology)
   - [Decoupled Transactional Outbox Pattern](#decoupled-transactional-outbox-pattern)
4. [Microservices & Core Components](#microservices--core-components)
5. [Repository Structure](#repository-structure)
6. [Local Development & Setup Guide](#local-development--setup-guide)
   - [Prerequisites](#prerequisites)
   - [Code Quality & Pre-Commit Hooks](#code-quality--pre-commit-hooks)
   - [Running Services Locally](#running-services-locally)
   - [Running the Test Suites](#running-the-test-suites)
7. [DevSecOps & CI/CD Pipeline](#devsecops--cicd-pipeline)
   - [Pipeline Workflows](#pipeline-workflows)
   - [Supply Chain Security & Signing](#supply-chain-security--signing)
   - [Smart Rollback Mechanism (EWCSB-220)](#smart-rollback-mechanism-ewcsb-220)
8. [Chaos Engineering & Outage Testing (EWCSB-250)](#chaos-engineering--outage-testing-ewcsb-250)
   - [Automated Dual-Dependency Testing Engine](#automated-dual-dependency-testing-engine)
   - [Formal Verification Criteria Matrix](#formal-verification-criteria-matrix)
9. [Operational Personas & Verification Journeys](#operational-personas--verification-journeys)
10. [Observability & Monitoring](#observability--monitoring)
11. [Runbooks & Key Documentation](#runbooks--key-documentation)

---

## Executive Summary

The **Responsible E-Waste Platform** provides an end-to-end, tamper-evident digital custody and recycling management lifecycle. It enables donors to declare e-waste batches, matches batches with certified recyclers using an event-driven rules engine, provides logistics coordination for field collectors, and verifies physical treatment to compute verified environmental impact metrics (such as CO₂ emissions avoided and precious metal recovery).

### Key Architectural Pillars

- **Zero-Trust Network Perimeter:** Only the Web Frontend UI (`aca-ewaste-prod-ui`) exposes an external public HTTPS endpoint. All backend APIs, event processors, databases, caches, and storage accounts reside strictly within private Azure Virtual Network subnets with zero public IP exposure.
- **Strict Chain-of-Custody Integrity:** Every custody transfer (donation → matching → claim → pickup → treatment) generates cryptographic receipts, immutable audit trails, and SHA-256 evidence attachments stored in private Azure Blob Storage.
- **High Concurrency & Conflict Prevention:** Distributed Redis locks (`Redlock`), database unique constraints, and HTTP `Idempotency-Key` headers guarantee mutual exclusion on batch claims, preventing double-allocation race conditions under peak concurrency.
- **Fail-Closed DevSecOps Pipeline:** Automated GitHub Actions workflows enforce pre-commit checks, secret scanning (Gitleaks), container vulnerability scanning (Grype), Syft SPDX Software Bill of Materials (SBOM) generation (retained for 90 days), and Cosign cryptographic container image signing before production deployment.
- **High Availability & Fault Tolerance:** Decouples synchronous HTTP ingress from downstream messaging via the Transactional Outbox pattern, ensuring complete submission uptime even during total message broker outages.

---

## Project Team & Roles

| Member | Project Role | Core Responsibilities |
| :--- | :--- | :--- |
| **Jiamin Wang** | **Technical Lead** | Software architecture, Go backend APIs, GORM relational persistence, business domain models, and technical approver sign-off. |
| **Shalett Paulson** | **Security Lead** | Zero-trust perimeter design, DAST scans (OWASP ZAP), Cosign signing governance, vulnerability remediation, and security approver sign-off. |
| **Lakshanya P** | **DevSecOps & Platform Lead** | CI/CD automation pipelines, Terraform IaC, Azure Container Apps infrastructure, smart rollback engineering (EWCSB-220), chaos/outage testing orchestration (EWCSB-250), and operational evidence management. |
| **Kaushik Shubham** | **Analytics & Matching Lead** | Python streaming event consumer, rules engine execution, environmental impact calculation formulas, and Kafka integration. |

---

## System Architecture & Security Perimeter

### Zero-Trust Ingress Boundary

In accordance with Sprint 4 perimeter hardening specifications, external internet access is restricted to the Frontend Web UI:

```
                           Public Internet (HTTPS / Port 443)
                                          │
                                          ▼
                ┌───────────────────────────────────────────────────┐
                │             aca-ewaste-prod-ui                    │
                │        (ONLY Public Ingress Endpoint)             │
                │  https://aca-ewaste-prod-ui.lemonplant-...io      │
                └─────────────────────────┬─────────────────────────┘
                                          │ Next.js Backend-For-Frontend (BFF)
                                          ▼
══════════════════════════════════════════════════════════════════════════════════════════════
               PRIVATE VIRTUAL NETWORK BOUNDARY (vnet-ewaste-prod / 10.0.0.0/16)
══════════════════════════════════════════════════════════════════════════════════════════════
       │                                     │                                    │
       ▼                                     ▼                                    ▼
┌─────────────────────────────┐   ┌─────────────────────────────┐   ┌─────────────────────────────┐
│    aca-ewaste-prod-api      │   │  aca-ewaste-prod-analytics  │   │   vm-runner-ewaste-prod     │
│   (Go REST API Gateway)     │   │   (Python Stream Consumer)  │   │  (Self-Hosted Runner VM)    │
│    Internal Ingress :8080   │   │    Internal Ingress :8000   │   │    Internal Diagnostics     │
└──────────────┬──────────────┘   └──────────────┬──────────────┘   └──────────────┬──────────────┘
               │                                 │                                 │
               ▼                                 ▼                                 ▼
┌─────────────────────────────┐   ┌─────────────────────────────┐   ┌─────────────────────────────┐
│      mysql-ewaste-prod      │   │      redis-ewaste-prod      │   │    evh-ewaste-prod (Kafka)  │
│  (Azure MySQL Flexible)     │   │   (Azure Cache for Redis)   │   │  (Azure Event Hubs Kafka)   │
│   Subnet: snet-mysql :3306  │   │ Subnet: snet-private-pe :6380│  │   Topic: ewaste.batch.events│
│   Zero Public IP Exposure   │   │   Private Endpoint Link     │   │   DLQ: ...matching.dlq.v1   │
└─────────────────────────────┘   └─────────────────────────────┘   └─────────────────────────────┘
```

### Architectural Topology

The production environment (`rg-ewaste-prod`) in `eastasia` is partitioned into four private subnets inside `vnet-ewaste-prod` (`10.0.0.0/16`):

1. **`snet-aca` (`10.0.8.0/21`):** Delegated to Azure Container Apps Environment (`cae-ewaste-prod`). Hosts the public Web UI and internal API/Analytics containers.
2. **`snet-mysql` (`10.0.2.0/24`):** Strictly private subnet delegated to `Microsoft.DBforMySQL/flexibleServers`. Private DNS: `mysql-ewaste-prod.mysql.database.azure.com`.
3. **`snet-private-endpoints` (`10.0.3.0/24`):** Hosts private endpoints for Azure Cache for Redis (`redis-ewaste-prod`), Azure Blob Storage (`stgewasteprod`), and Azure Container Registry (`acrewasteplatform.azurecr.io`).
4. **`snet-runner` (`10.0.4.0/24`):** Hosts the Linux self-hosted runner VM (`vm-runner-ewaste-prod`). Used for executing private Liquibase migrations and VNet-internal SQL audit checks.

### Decoupled Transactional Outbox Pattern

To prevent cascading failures when third-party services or message brokers experience degradation:
1. When a donor submits a batch, `aca-ewaste-prod-api` persists the batch in `ewaste_batches` and writes an event envelope into `event_outbox` within the **same local ACID database transaction**.
2. The API responds with `HTTP 201 Created` immediately, guaranteeing sub-second response times and complete resilience against Kafka outages.
3. A background Go relay routine polls `event_outbox` and publishes events to Azure Event Hubs topic `ewaste.batch.events`.
4. If Event Hubs is temporarily offline, events safely accumulate in `event_outbox` with status `PENDING` and are drained sequentially once the broker recovers.

---

## Microservices & Core Components

| Component | Technology | Directory | Description |
| :--- | :--- | :--- | :--- |
| **Workflow API** | Go 1.26, Gin, GORM, Kafka-Go | `src/backend` | Core REST API service handling authentication, RBAC, batch lifecycle state transitions, claims, and outbox relay. |
| **Workflow UI** | Next.js 16, React 19, TypeScript 5, Tailwind CSS 4 | `src/frontend` | Modern responsive frontend interface with role-based navigation for Donors, Recyclers, Collectors, and Auditors. |
| **Matching & Analytics** | Python 3.12, Confluent-Kafka, jsonschema | `src/matcher` | Asynchronous Kafka event stream consumer, multi-factor matching engine, and environmental impact calculation engine. |
| **Database Migrations** | Liquibase, YAML Changelogs, MySQL 8 | `database/` | Version-controlled database schema migrations enforcing foreign keys, audit tables, and idempotency constraints. |
| **Infrastructure as Code** | Terraform, AzureRM Provider | `terraform/` | Declarative IaC defining VNets, subnets, private endpoints, container apps environments, and IAM bindings. |
| **Automation & Drills** | Python 3.12, Azure CLI | `scripts/` | Automated rollback rehearsals (`run_rollback_rehearsal.py`) and dual-dependency outage testing (`run_dependency_outage_test.py`). |

---

## Repository Structure

```text
team5-ewaste-platform/
├── .github/
│   └── workflows/
│       ├── ci-gate.yml                 # CI quality gates, Gitleaks, unit tests & scans
│       ├── cd-pipeline.yml             # CD deployment, Cosign signing, smart rollback & DAST
│       ├── database-migration.yml      # Liquibase private migration runner
│       └── terraform-infra-create.yml  # Terraform IaC infrastructure pipeline
├── database/                           # Liquibase changelogs and SQL migration scripts
├── docs/                               # Architecture decision records, specifications, runbooks
│   ├── CI_CD_AND_TESTING_RUNBOOK.md   # Complete testing & CI/CD operational guide
│   ├── LOGGING_AND_MONITORING_RUNBOOK.md # KQL queries, alerts & workbook manual
│   ├── ROLLBACK_AND_DISASTER_RECOVERY_RUNBOOK.md # Recovery & rollback manual
│   ├── evidence/                       # Auditable verification records & logs
│   │   ├── outage_test/                # Multi-dependency outage logs and reports (EWCSB-250)
│   │   └── rollback_test/              # Rollback rehearsal logs and traces (EWCSB-220)
│   └── monitoring/                     # Azure Monitor workbook templates & alert definitions
├── releases/                           # Release image catalog & signed container digests
├── scripts/                            # Operational test scripts & chaos engineering runners
│   ├── run_dependency_outage_test.py   # Dual-dependency outage drill runner (MySQL & Kafka)
│   └── run_rollback_rehearsal.py       # Rollback rehearsal runner for signed digests
├── src/
│   ├── backend/                        # Go REST API Gateway microservice
│   ├── frontend/                       # Next.js / React web user interface
│   └── matcher/                        # Python Kafka matching & analytics engine
├── terraform/                          # Terraform modules and environment configurations
├── .pre-commit-config.yaml             # Pre-commit hook definitions
├── PRECOMMIT.md                        # Pre-commit installation and troubleshooting guide
└── README.md                           # Master platform documentation
```

---

## Local Development & Setup Guide

### Prerequisites

Ensure the following tools are installed on your local machine:
- **Go:** `1.26` or newer
- **Node.js:** `22.x` or `24.x` (`npm`)
- **Python:** `3.12` or newer (`pip`, `venv`)
- **Docker:** Docker Engine / Docker Desktop
- **Azure CLI:** `2.60.0` or newer
- **Git** & **Pre-Commit**

---

### Code Quality & Pre-Commit Hooks

This repository uses [pre-commit](https://pre-commit.com/) to automatically enforce formatting, detect secrets, and validate code hygiene before every commit.

```bash
# 1. Install pre-commit via pip
pip install pre-commit

# 2. Install the git hooks into your repository
pre-commit install

# 3. (Optional) Run all hooks manually against all files
pre-commit run --all-files
```

> [!TIP]
> For detailed troubleshooting, see the [Pre-Commit Setup Guide](PRECOMMIT.md).

---

### Running Services Locally

#### 1. Start Local Infrastructure Dependencies (Docker Compose)

From the project root, launch MySQL, Redis, and Kafka:

```bash
# Launch background services
docker run -d --name ewaste-mysql -p 3306:3306 -e MYSQL_ROOT_PASSWORD=root -e MYSQL_DATABASE=ewastedb mysql:8.0
docker run -d --name ewaste-redis -p 6379:6379 redis:7.2-alpine
```

#### 2. Run the Go Backend API

```bash
cd src/backend

# Configure local environment variables
export DATABASE_URL="root:root@tcp(localhost:3306)/ewastedb?parseTime=true"
export REDIS_ADDR="localhost:6379"
export PORT="8080"

# Download dependencies and start
go mod download
go run cmd/server/main.go
```
The API Gateway will listen on `http://localhost:8080`. Probe readiness via `http://localhost:8080/api/v1/hello`.

#### 3. Run the Next.js Frontend UI

```bash
cd src/frontend

# Install dependencies
npm install

# Start development server
npm run dev
```
Open `http://localhost:3000` in your browser.

#### 4. Run the Python Matching & Analytics Worker

```bash
cd src/matcher

# Create and activate virtual environment
python -m venv .venv
source .venv/bin/activate  # On Windows: .venv\Scripts\activate

# Install dependencies
pip install -r requirements.txt

# Start matching consumer
python -m matcher run
```

---

### Running the Test Suites

#### Backend Unit & Integration Tests (Go)
```bash
cd src/backend
go test -v -race -cover ./...
```

#### Frontend Unit & Component Tests (TypeScript/Vitest)
```bash
cd src/frontend
npm test
```

#### Analytics & Matching Engine Tests (Python/Pytest)
```bash
cd src/matcher
pytest -v tests/
```

---

## DevSecOps & CI/CD Pipeline

The platform enforces a four-stage continuous delivery pipeline across `dev`, `stg`, and `prod`:

```
[Developer Push / PR] ──► [CI Quality Gate] ──► [Terraform IaC] ──► [Liquibase Migration] ──► [CD Pipeline]
                              (ci-gate.yml)     (terraform-infra)    (database-migration)    (cd-pipeline.yml)
```

### Pipeline Workflows

1. **CI Quality Gate (`.github/workflows/ci-gate.yml`):**
   - **Quality & Format:** Pre-commit linters, Go format (`go-fmt`), Go vet (`go-vet`), and Prettier.
   - **Secret Scanning:** `Gitleaks v8` scans all pull request diffs to prevent credentials from being committed.
   - **Unit Tests:** Executes full unit test matrices across Go, TypeScript, and Python.
   - **IaC Security:** `Checkov` static analysis of Terraform definitions.
   - **Static Analysis:** SonarQube quality and coverage inspection.

2. **Database Migration (`.github/workflows/database-migration.yml`):**
   - Executes Liquibase schema changes inside the private VNet via the self-hosted runner VM (`vm-runner-ewaste-prod`).

3. **CD Pipeline (`.github/workflows/cd-pipeline.yml`):**
   - **Multi-Service Build:** Builds Docker container images for `workflow-api`, `workflow-ui`, and `workflow-analytics`.
   - **Software Supply Chain Assurance:** Generates SPDX JSON Software Bill of Materials (SBOM) using `Syft`, retained for 90 days.
   - **Vulnerability Scanning:** Runs `Grype` scans on container images (blocks on High/Critical CVEs).
   - **Cosign Image Signing:** Signs container images using private keys; pushes `.sig` signatures to Azure Container Registry (`acrewasteplatform.azurecr.io`).
   - **Immutable Deployments:** Deploys revisions to Azure Container Apps strictly by `@sha256:` digest.
   - **DAST Security Scanning:** Executes automated `OWASP ZAP` baseline scans against the public UI endpoint post-deployment.

---

### Supply Chain Security & Signing

Every production image deployed to Azure Container Apps is verified using Sigstore Cosign:

```bash
# Verify container image signature using the public key
cosign verify \
  --key cosign.pub \
  acrewasteplatform.azurecr.io/workflow-api:prod-<sha>
```

---

### Smart Rollback Mechanism (EWCSB-220)

In disaster scenarios, the CD pipeline supports zero-downtime, automated rollbacks via `DEPLOY_TAG=rollback`:

- **Cosign Artifact Filtering:** ACR tag discovery filters out `.sig` and `.att` signature artifacts (`grep -vE '\.(sig|att)$'`), ensuring only valid container image tags are resolved.
- **Bypass Redundant SBOM Generation:** Bypasses Syft SBOM rebuilding for already-verified images, accelerating production recovery from ~15 minutes down to **4 minutes 10 seconds** (ACA container update completes in **2m 31s**).
- **Audit Verification:** Produces auditable rollback evidence in [`docs/evidence/rollback_test/`](docs/evidence/rollback_test/).

---

## Chaos Engineering & Outage Testing (EWCSB-250)

To validate platform resilience under active load (Sprint 4 Scenario 10: *"Dependency outage during load"*), an automated chaos orchestration script is provided:

### Automated Dual-Dependency Testing Engine

The script [`scripts/run_dependency_outage_test.py`](scripts/run_dependency_outage_test.py) tests platform behavior when core dependencies fail:

```powershell
# 1. Safe Simulation (Dry-Run Mode)
python scripts/run_dependency_outage_test.py --dry-run --dependency both

# 2. Live Production Chaos Drill against Azure
python scripts/run_dependency_outage_test.py --rg rg-ewaste-prod --dependency both --outage-secs 60
```

- **Dual-Dependency Orchestration (`--dependency both`):** Sequentially executes fault injection against **MySQL Flexible Server** (VM stop/start cold-start recovery), then **Kafka / Event Hubs** (entity disable/enable) while continuous synthetic transactions hit the platform.
- **Isolated Logging Architecture:** Generates dedicated log files for each dependency:
  - MySQL Run Log: [`docs/evidence/outage_test/mysql/outage_run.log`](docs/evidence/outage_test/mysql/outage_run.log)
  - Kafka Run Log: [`docs/evidence/outage_test/kafka/outage_run.log`](docs/evidence/outage_test/kafka/outage_run.log)
  - Unified Console Log: [`docs/evidence/outage_test/outage_run.log`](docs/evidence/outage_test/outage_run.log)

---

### Formal Verification Criteria Matrix

The engine validates 11 discrete architectural assertions with detailed engineering rationales:

| Rule ID | Verification Target | Target SLA / Invariant | Status | Detailed Explanation |
| :--- | :--- | :--- | :---: | :--- |
| **`VR-01`** | **Pre-Outage Baseline Audit** | Non-empty database baseline captured | **PASS** | Captures row-count baseline before inducing failure to prove records are neither lost nor corrupted. |
| **`VR-02`** | **Continuous Synthetic Load** | Active HTTP traffic sustained | **PASS** | Validates platform behavior under active multi-threaded concurrent user load. |
| **`VR-03`** | **Outage Signal Capture** | Circuit breaker / probe detection | **PASS** | Validates HTTP 503s for MySQL; verifies broker `Disabled` status with zero-dropped-requests Outbox buffering for Kafka. |
| **`VR-04`** | **Mean Time to Recovery (MTTR)** | $\le 600\text{s}$ (MySQL) / $\le 180\text{s}$ (Kafka) | **PASS** | Evaluates cloud PaaS recovery time against operational SLAs. |
| **`VR-05`** | **Post-Recovery App Readiness** | `/api/v1/hello` returns HTTP 200 within 180s | **PASS** | Confirms application containers re-establish healthy connection pools without redeployment. |
| **`VR-06`** | **Zero Duplicate Batches** | 0 duplicate batch ID violations | **PASS** | Audits primary key uniqueness and idempotent `Idempotency-Key` POST request handling. |
| **`VR-07`** | **Zero Duplicate Claims** | 0 duplicate accepted claims | **PASS** | Guarantees mutual exclusion on batch claims even under high failure concurrency. |
| **`VR-08`** | **Zero Duplicate Impact Metrics** | 0 duplicate calculation rows | **PASS** | Validates that replayed analytics domain events process idempotently. |
| **`VR-09`** | **Zero Orphaned Claims** | 0 foreign key constraint violations | **PASS** | Proves transaction rollbacks never leave orphaned records in `batch_claims`. |
| **`VR-10`** | **Outbox Queue Resumption** | Outbox relay resumes draining | **PASS** | Verifies transactional outbox buffers events during degradation and drains upon recovery. |
| **`VR-11`** | **Audit Artifact Completeness** | All audit logs persisted to disk | **PASS** | Ensures all logs, JSON metrics, and markdown reports exist on disk for compliance. |

Consolidated audit reports are generated at [`docs/evidence/outage_test/S4_LD_T_L_02_OUTAGE_TEST_REPORT.md`](docs/evidence/outage_test/S4_LD_T_L_02_OUTAGE_TEST_REPORT.md).

---

## Operational Personas & Verification Journeys

The platform includes seed personas for end-to-end verification via the public UI:

| Role | Username / Email | Organization | Org ID | Responsibilities |
| :--- | :--- | :--- | :--- | :--- |
| **Donor** | `donor1@ewaste.test` | GreenCorp Tech | `ORG-001` | Creates, edits, and submits e-waste batches via UI. |
| **Recycler 1** | `recycler1@ewaste.test` | EcoCycle Processors | `PROC-001` | Claims batches in `NORTH`, `SOUTH`, `EAST`, `WEST`, `CENTRAL`. |
| **Recycler 2** | `recycler2@ewaste.test` | RenewTech Solutions | `PROC-002` | Competitor recycler used for claim race/conflict testing (`HTTP 409`). |
| **Collector** | `collector1@ewaste.test` | GreenHaul Logistics | `COL-001` | Finalizes pickup handoff logistics or records pickup failures. |
| **Admin** | `admin@ewaste.test` | State Regulatory Agency | `ADMIN-001` | System audit, global oversight, and security evidence review. |

> [!NOTE]
> All seed credentials and persona secrets are managed via Azure Container Apps encrypted secrets. In local environments, credentials are set via local `.env` files.

---

## Observability & Monitoring

The production environment streams structured JSON telemetry to centralized Log Analytics workspace `log-ewaste-centralized` in `rg-ewaste-shared`:

1. **Azure Monitor Workbook (`docs/monitoring/ewaste-platform-monitor.workbook.json`):**
   - **Tab 1: System Overview & Deployment Inventory:** Live ACA revision digests, image tags, and uptime.
   - **Tab 2: Platform Reliability & SLO Tracking:** P50/P95/P99 latency tracking (API SLO: P95 < 2s; Worker SLO: P95 < 10s).
   - **Tab 3: End-to-End Distributed Trace:** Traces requests across HTTP ingress, database outbox relay, and Kafka consumers.
   - **Tab 4: Kafka Ingestion & Consumer Lag:** Real-time partition lag monitoring and stalled consumer detection.
   - **Tab 5: Dead-Letter Queue & Quarantine:** Investigates unprocessable poison-pill messages and error streaks.
   - **Tab 6: Security Governance & Evidence:** Links to Syft SBOMs, Cosign signatures, and audit logs.

2. **Automated Scheduled Alert Rules:**
   - **`Alert-DeadLetter-Quarantine` (Sev 1):** Triggers on quarantined events or $\ge 3$ consecutive delivery failures.
   - **`Alert-Kafka-ConsumerLag` (Sev 2):** Triggers when partition lag exceeds 100 messages or telemetry heartbeats pause for $> 90\text{s}$.
   - **`Alert-Platform-SLO-Breach` (Sev 2):** Triggers when P95 latency exceeds 3,000ms (API) or 10,000ms (Worker).

For KQL query definitions, see the [Logging and Monitoring Runbook](docs/LOGGING_AND_MONITORING_RUNBOOK.md).

---

## Runbooks & Key Documentation

- **[CI/CD & Testing Operational Runbook](docs/CI_CD_AND_TESTING_RUNBOOK.md):** Detailed guide to pipeline stages, perimeter architecture, and end-to-end user journeys.
- **[Logging & Monitoring Runbook](docs/LOGGING_AND_MONITORING_RUNBOOK.md):** KQL queries, alert creation commands, and Log Analytics dashboard manual.
- **[Rollback & Disaster Recovery Runbook](docs/ROLLBACK_AND_DISASTER_RECOVERY_RUNBOOK.md):** Emergency procedures for digest rollback, database restoration, and broker recovery.
- **[Pre-Commit Setup Guide](PRECOMMIT.md):** Git hooks installation and formatting standards.
- **[Dependency Outage Test Report](docs/evidence/outage_test/S4_LD_T_L_02_OUTAGE_TEST_REPORT.md):** Formal audit evidence and sign-off report for Sprint 4 chaos drills.
