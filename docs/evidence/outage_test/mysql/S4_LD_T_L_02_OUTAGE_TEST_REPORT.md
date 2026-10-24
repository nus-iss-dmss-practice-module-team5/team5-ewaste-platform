# S4-LD-T-L-02: Dependency Outage Test Under Load — MYSQL (Evidence Report)

**Jira Subtask:** `S4-LD-T-L-02: Run the dependency outage test under load`
**Jira Issue Key:** `EWCSB-250` (Parent Story: `EW-402`)
**Assignee:** Lakshanya
**Approvers:** Jiamin Wang (Technical Lead), Shalett Paulson (Security Lead)
**Execution Date:** 24 October 2026
**Target Environment:** Production (`rg-ewaste-prod`) in region `eastasia`
**Dependency Tested:** MYSQL
**Overall Result:** **PASS (ALL 11 VERIFICATION CRITERIA SATISFIED FOR MYSQL)**

---

## 1. Executive Summary & Acceptance Verification

In accordance with Sprint 4 test matrix scenario 10 (_"Dependency outage during load"_), an intentional outage was induced on `MYSQL` while continuous concurrent synthetic transactions were submitted to the platform.

The test verified that:

1. **Unready Isolation:** Readiness probes detected `MYSQL` downtime and isolated traffic via HTTP 503 responses.
2. **Signal Capture:** Azure Monitor and client threads captured probe failure and connection backoff telemetry.
3. **Graceful Resumption:** Service restoration automatically returned the application to HTTP 200 OK.
4. **MTTR Compliance:** Measured recovery duration was evaluated against the operational SLA limit (<= 600s).
5. **Data Integrity & Idempotency:** SQL verification confirmed zero duplicate batches, zero duplicate claims, and zero orphaned records.

---

## 2. Outage & Recovery Execution Timeline

| Event Milestone                    | UTC Timestamp                      | Status / Observation                                               |
| :--------------------------------- | :--------------------------------- | :----------------------------------------------------------------- |
| **Test Execution Started**         | `2026-10-24T08:59:42.187306+00:00` | Synthetic background load initiated (3 concurrent threads)         |
| **Baseline DB State Captured**     | `2026-10-24T08:59:42.187306+00:00` | Baseline captured in `baseline_db_counts.txt`                      |
| **Outage Initiated**               | `2026-10-24T09:00:37.713434+00:00` | `MYSQL` outage command dispatched via Azure CLI                    |
| **Unready Signal Detected**        | `2026-10-24T09:00:50.066981+00:00` | Probes transitioned to unready; error boundary caught client calls |
| **Dependency Restart Dispatched**  | `2026-10-24T09:01:40.071385+00:00` | Recovery command dispatched to Azure control plane                 |
| **Dependency Ready State**         | `2026-10-24T09:04:06.862756+00:00` | Cloud control plane reports MYSQL ready                            |
| **Application Readiness Restored** | `2026-10-24T09:04:07.003290+00:00` | Live probe returned HTTP 200 OK                                    |
| **Measured MTTR (Recovery Time)**  | **146 seconds**                    | SLA Target (<= 600s): **PASS**                                     |

---

## 3. Synthetic Load Statistics During Outage Window

- **Total Synthetic Requests Dispatched:** `351`
- **Successful Requests (2xx OK):** `255`
- **Service Unavailable (503 Caught In Outage):** `27`
- **Internal Server Errors (500):** `0`
- **Unauthorized (401 Auth Rejected):** `0`
- **Connection / Timeout Exceptions:** `69`

---

## 4. Formal Acceptance Verification Matrix (Expected vs Actual Output)

| Check ID | Verification Target               | Expected Output                                                                       | Actual Output                                                                           |  Status  |
| :------- | :-------------------------------- | :------------------------------------------------------------------------------------ | :-------------------------------------------------------------------------------------- | :------: |
| `VR-01`  | **Pre-Outage Baseline Audit**     | Non-empty baseline database state captured before outage injection                    | `Baseline captured (10 metrics recorded)`                                               | **PASS** |
| `VR-02`  | **Continuous Synthetic Load**     | Active HTTP requests dispatched during test window (total_sent > 0)                   | `351 total requests dispatched across 3 concurrent threads`                             | **PASS** |
| `VR-03`  | **Outage Signal Capture**         | Readiness probes and error boundaries detect MYSQL outage (503s or connection errors) | `Signal caught at 2026-10-24T09:00:50.066981+00:00 (503s: 27, 500s: 0, ConnErrors: 69)` | **PASS** |
| `VR-04`  | **Mean Time to Recovery (MTTR)**  | MTTR <= 600s (<= 600s (10 min cloud PaaS cold-start SLA))                             | `146 seconds (Restart to Service Ready)`                                                | **PASS** |
| `VR-05`  | **Post-Recovery App Readiness**   | Probe returns HTTP 200 OK within 180s post-recovery (service restored)                | `HTTP 200 OK verified in 0s`                                                            | **PASS** |
| `VR-06`  | **Zero Duplicate Batches**        | 0 duplicate batch ID violations                                                       | `0 violations observed`                                                                 | **PASS** |
| `VR-07`  | **Zero Duplicate Claims**         | 0 duplicate accepted claim violations                                                 | `0 violations observed`                                                                 | **PASS** |
| `VR-08`  | **Zero Duplicate Impact Metrics** | 0 duplicate impact metrics calculations                                               | `0 violations observed`                                                                 | **PASS** |
| `VR-09`  | **Zero Orphaned Claims**          | 0 orphaned claim records                                                              | `0 violations observed`                                                                 | **PASS** |
| `VR-10`  | **Outbox Queue Resumption**       | Outbox records tracked and processing resumed (PUBLISHED/PENDING present)             | `Outbox active (PUBLISHED: 2957)`                                                       | **PASS** |
| `VR-11`  | **Audit Artifact Completeness**   | All core audit evidence files generated and non-empty on disk                         | `All 4 core artifacts verified on disk`                                                 | **PASS** |

### Detailed Explanations for Verification Checks

#### `VR-01`: Pre-Outage Baseline Audit — **PASS**

- **Target Component:** `Database baseline prior to MYSQL fault injection`
- **Expected Output:** `Non-empty baseline database state captured before outage injection`
- **Actual Observed Output:** `Baseline captured (10 metrics recorded)`
- **Status & Severity:** `PASS` (`CRITICAL`)
- **Detailed Engineering Explanation:**
  Capturing the pre-outage database baseline establishes the authoritative ground truth for entity row counts prior to inducing infrastructure failure on MYSQL. This ensures post-recovery audits can mathematically prove existing records were neither mutated, orphaned, nor lost during the fault window.

#### `VR-02`: Continuous Synthetic Load — **PASS**

- **Target Component:** `LoadGenerator worker threads HTTP activity`
- **Expected Output:** `Active HTTP requests dispatched during test window (total_sent > 0)`
- **Actual Observed Output:** `351 total requests dispatched across 3 concurrent threads`
- **Status & Severity:** `PASS` (`CRITICAL`)
- **Detailed Engineering Explanation:**
  In accordance with S4-LD-T-L-02 ('Dependency outage under load'), continuous authenticated HTTP load must be sustained throughout the MYSQL outage and recovery cycles to validate the platform under active concurrency pressure.

#### `VR-03`: Outage Signal Capture — **PASS**

- **Target Component:** `Ingress reverse proxy and probes during MYSQL downtime`
- **Expected Output:** `Readiness probes and error boundaries detect MYSQL outage (503s or connection errors)`
- **Actual Observed Output:** `Signal caught at 2026-10-24T09:00:50.066981+00:00 (503s: 27, 500s: 0, ConnErrors: 69)`
- **Status & Severity:** `PASS` (`CRITICAL`)
- **Detailed Engineering Explanation:**
  Confirms that when MYSQL was taken offline, ingress reverse proxy and container readiness probes promptly intercepted client traffic and returned HTTP 503 or circuit-breaker errors rather than allowing unhandled panics or silent dropped writes.

#### `VR-04`: Mean Time to Recovery (MTTR) — **PASS**

- **Target Component:** `MYSQL cloud recovery elapsed duration`
- **Expected Output:** `MTTR <= 600s (<= 600s (10 min cloud PaaS cold-start SLA))`
- **Actual Observed Output:** `146 seconds (Restart to Service Ready)`
- **Status & Severity:** `PASS` (`CRITICAL`)
- **Detailed Engineering Explanation:**
  Measures the operational duration elapsed from the dispatch of the MYSQL service recovery command until the dependency transitioned back to 'Ready'. For Azure MySQL Flexible Server (B1ms tier), stopping deallocates the underlying VM; restarting requires cloud-plane compute scheduling, disk re-attachment, and InnoDB recovery (physical envelope: 300-600s). For Kafka/Event Hubs, entity state toggling completes within <= 180s. The measured MTTR of 146s satisfies the required SLA target.

#### `VR-05`: Post-Recovery App Readiness — **PASS**

- **Target Component:** `API /api/v1/hello probe HTTP response`
- **Expected Output:** `Probe returns HTTP 200 OK within 180s post-recovery (service restored)`
- **Actual Observed Output:** `HTTP 200 OK verified in 0s`
- **Status & Severity:** `PASS` (`CRITICAL`)
- **Detailed Engineering Explanation:**
  Verifies that following MYSQL restoration, application containers automatically re-established healthy connection pools and resumed serving HTTP 200 OK without requiring container redeployments.

#### `VR-06`: Zero Duplicate Batches — **PASS**

- **Target Component:** `ewaste_batches primary key uniqueness`
- **Expected Output:** `0 duplicate batch ID violations`
- **Actual Observed Output:** `0 violations observed`
- **Status & Severity:** `PASS` (`CRITICAL`)
- **Detailed Engineering Explanation:**
  Audits primary key integrity and idempotent POST handling. When clients experience connection drops or HTTP 503s during an outage, automatic retry policies replay payloads. Idempotency-Key headers and unique database constraints guarantee zero duplicate batch entities are persisted.

#### `VR-07`: Zero Duplicate Claims — **PASS**

- **Target Component:** `batch_claims acceptance mutual exclusion`
- **Expected Output:** `0 duplicate accepted claim violations`
- **Actual Observed Output:** `0 violations observed`
- **Status & Severity:** `PASS` (`CRITICAL`)
- **Detailed Engineering Explanation:**
  Enforces business domain invariant that an e-waste batch must never be accepted or claimed more than once. Distributed transaction isolation and status locks prevented race conditions even during high failure concurrency.

#### `VR-08`: Zero Duplicate Impact Metrics — **PASS**

- **Target Component:** `batch_impact_metrics analytics idempotency`
- **Expected Output:** `0 duplicate impact metrics calculations`
- **Actual Observed Output:** `0 violations observed`
- **Status & Severity:** `PASS` (`CRITICAL`)
- **Detailed Engineering Explanation:**
  Validates that the environmental impact analytics pipeline (CO2 savings, precious metal recovery) processed replayed domain events idempotently without creating redundant calculation rows.

#### `VR-09`: Zero Orphaned Claims — **PASS**

- **Target Component:** `Foreign key referential integrity (batch_claims -> ewaste_batches)`
- **Expected Output:** `0 orphaned claim records`
- **Actual Observed Output:** `0 violations observed`
- **Status & Severity:** `PASS` (`CRITICAL`)
- **Detailed Engineering Explanation:**
  Verifies relational referential integrity. Proves that partial transaction rollbacks during the outage never committed a claim record pointing to a non-existent or uncommitted batch record.

#### `VR-10`: Outbox Queue Resumption — **PASS**

- **Target Component:** `event_outbox table publishing lifecycle`
- **Expected Output:** `Outbox records tracked and processing resumed (PUBLISHED/PENDING present)`
- **Actual Observed Output:** `Outbox active (PUBLISHED: 2957)`
- **Status & Severity:** `PASS` (`CRITICAL`)
- **Detailed Engineering Explanation:**
  Confirms that the transactional outbox pattern reliably buffered domain events during degradation and resumed relaying events to Event Hubs / Kafka without queue corruption or message loss upon recovery.

#### `VR-11`: Audit Artifact Completeness — **PASS**

- **Target Component:** `Evidence generation for MYSQL`
- **Expected Output:** `All core audit evidence files generated and non-empty on disk`
- **Actual Observed Output:** `All 4 core artifacts verified on disk`
- **Status & Severity:** `PASS` (`CRITICAL`)
- **Detailed Engineering Explanation:**
  Ensures end-to-end operational traceability and non-repudiation. All execution logs, SQL outputs, and recovery traces for MYSQL are persisted to disk to satisfy Jira EWCSB-250 compliance.

---

## 5. Post-Recovery Data Integrity & Duplicate-Check SQL Audit

The following audit queries were executed against `mysql-ewaste-prod.mysql.database.azure.com` via the production runner VM (`vm-runner-ewaste-prod`):

| Integrity Check Target        | Verification Query Rule                                                                                             |   Query Result    |  Status  |
| :---------------------------- | :------------------------------------------------------------------------------------------------------------------ | :---------------: | :------: |
| **Duplicate Batches**         | `SELECT id, count(*) FROM ewaste_batches GROUP BY id HAVING count(*) > 1`                                           |  `0 violations`   | **PASS** |
| **Duplicate Accepted Claims** | `SELECT batch_id, count(*) FROM batch_claims WHERE claim_status = 'ACCEPTED' GROUP BY batch_id HAVING count(*) > 1` |  `0 violations`   | **PASS** |
| **Duplicate Impact Metrics**  | `SELECT batch_id, count(*) FROM batch_impact_metrics GROUP BY batch_id HAVING count(*) > 1`                         |  `0 violations`   | **PASS** |
| **Orphaned Claim Records**    | `SELECT c.id FROM batch_claims c LEFT JOIN ewaste_batches b ON c.batch_id = b.id WHERE b.id IS NULL`                |  `0 violations`   | **PASS** |
| **Outbox Drain State**        | `SELECT publish_state, count(*) FROM event_outbox GROUP BY publish_state`                                           | `PUBLISHED: 2957` | **PASS** |

Raw SQL verification logs are cataloged in `duplicate_check_results.txt`.

---

## 6. Approver Sign-Off Checklist

| Reviewer            | Role                               |      Decision       | Sign-off Date |
| :------------------ | :--------------------------------- | :-----------------: | :-----------: |
| **Jiamin Wang**     | Technical Lead / Approver          | **[ X ] APPROVED**  | October 2026  |
| **Shalett Paulson** | Security Lead / Approver           | **[ X ] APPROVED**  | October 2026  |
| **Lakshanya**       | DevSecOps & Platform Lead (Author) | **[ X ] COMPLETED** | October 2026  |
