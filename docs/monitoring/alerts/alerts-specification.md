# Platform Alerting Rules Specification

**Task:** Build Azure Monitor workbook, dead-letter & lag alerts, and release evidence links
**Governance Standards:** Release Security Gate Policy & Administrator Observability Architecture
**Observability Leads:** Lakshanya Poovannan (Platform / DevOps), Mrigakshi Roy Choudhury (Observability / UI), Shalett Paulson (Security / Governance)

---

## 1. Executive Summary

This document specifies the automated **Azure Monitor Scheduled Query Rules (Alerts)** deployed to protect the Responsible E-Waste Platform across `dev`, `stg`, and `prod` environments. These rules continuously monitor structured telemetry emitted by `workflow-api`, `matcher-worker`, and the underlying Azure infrastructure (Kafka, MySQL, Container Apps).

---

## 2. Alerts Matrix

| Alert Name                        | Target Signal                                                      | Evaluation Frequency | Window Period |       Severity       |     Threshold      | Escalation & Notification             |
| :-------------------------------- | :----------------------------------------------------------------- | :------------------: | :-----------: | :------------------: | :----------------: | :------------------------------------ |
| **`Alert-DeadLetter-Quarantine`** | `Outcome in ("QUARANTINED", "REJECTED")` or `failure_streak >= 3`  |        5 mins        |    5 mins     | **Sev 1** (Critical) |  $> 0$ incidents   | On-Call Lead, Security Lead (Shalett) |
| **`Alert-Kafka-ConsumerLag`**     | `consumer_lag > 100` or `Stale == true` ($> 90\text{s}$)           |        2 mins        |    5 mins     | **Sev 2** (Warning)  |  $> 0$ partitions  | Platform Ops, Component Lead (Jiamin) |
| **`Alert-SLO-LatencyBreach`**     | API P95 $> 3\text{s}$ or Worker P95 $> 10\text{s}$                 |        5 mins        |    15 mins    | **Sev 2** (Warning)  |   $> 0$ breaches   | DevSecOps Lead (Lakshanya)            |
| **`Alert-Readiness-Absence`**     | Missing `/readyz` signals ($> 5\text{m}$) or `Outcome == "FAILED"` |        5 mins        |    5 mins     | **Sev 1** (Critical) | $> 0$ unready apps | Infrastructure Team, SRE              |

---

## 3. Detailed Rule Definitions

### 3.1 Alert: Dead-Letter & Quarantined Events (`Alert-DeadLetter-Quarantine`)

- **Query File:** [`dead-letter-quarantine-alert.kql`](./dead-letter-quarantine-alert.kql)
- **Rationale:** Quarantined events mean an e-waste batch failed contract validation or exceeded retry thresholds. Per Administrator Observability requirements, these persistent failures must be brought to administrator attention immediately.
- **Triage Runbook:**
  1. Inspect the `AffectedBatches` and `SampleCorrelation` from the alert payload.
  2. Navigate to the **E-Waste Operations Workbook** $\rightarrow$ **Tab 3: Dead-Letter & Quarantine**.
  3. Filter by the specific `batch_id` to determine if the error is schema violation (`VALIDATION_FAILED`) or cryptographic hash mismatch (`CONTRACT_VIOLATION`).
  4. Perform data repair prior to authorizing an outbox redrive.

### 3.2 Alert: Kafka Consumer Lag & Stalled Partitions (`Alert-Kafka-ConsumerLag`)

- **Query File:** [`consumer-lag-stalled-partition-alert.kql`](./consumer-lag-stalled-partition-alert.kql)
- **Rationale:** When Kafka consumer lag rises above 100 or when telemetry heartbeats cease for $> 90\text{s}$, events are queuing faster than processing or the worker has entered an exponential backoff pause.
- **Triage Runbook:**
  1. Open the **E-Waste Operations Workbook** $\rightarrow$ **Tab 4: Kafka Ingestion & Consumer Lag**.
  2. Verify whether `delivery_paused` is active on any partition.
  3. Check the Python worker logs for dependency health (MySQL connection pool or Redis token validation).
  4. If consumer offsets fail to commit (`offset_commit_failed`), verify transactional integrity on `matching_decisions`.

### 3.3 Alert: Platform Response Latency SLO Breach (`Alert-SLO-LatencyBreach`)

- **Query File:** [`platform-slo-latency-alert.kql`](./platform-slo-latency-alert.kql)
- **Rationale:** Ensures compliance with Sprint 3 / 4 platform SLO targets:
  - **API Command Latency:** $P_{95} \le 3,000\text{ ms}$.
  - **Worker Processing Latency:** $P_{95} \le 10,000\text{ ms}$.
- **Triage Runbook:**
  1. Open the **E-Waste Operations Workbook** $\rightarrow$ **Tab 2: Service Latency & SLOs**.
  2. Identify whether latency spikes originate from HTTP ingress (`workflow-api`) or async computation (`matcher-worker`).
  3. Check database locks in Azure Database for MySQL Flexible Server if API latency is elevated.
