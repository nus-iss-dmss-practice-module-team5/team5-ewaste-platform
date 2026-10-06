# Sprint 3 fake integration test report

Date: 2026-10-06  
Branch: `feature/EWCSB-170`  
Scope: EWCSB-164, EWCSB-166, EWCSB-167, EWCSB-170

## Test

`internal/service/sprint3_integration_test.go` — `TestFakeSprint3ReceiptTreatmentAnalyticsCompletionFlow`

The test uses the real Go receipt, treatment, and analytics services with the existing transactional fake repository. It replaces external infrastructure with:

- an in-memory fake Kafka broker with Go-to-Python and Python-to-Go channels;
- a mock Python analytics worker that consumes `RecyclingCompleted`, independently reconstructs the canonical frozen-input JSON, calculates the SHA-256 input hash, and calls the Go analytics acknowledgement façade;
- the fake repository transaction to verify durable atomic effects.

## Exercised flow

```text
COLLECTED (v5)
  -> VerifyReceipt
  -> VERIFIED (v6) + ReceiptVerified
  -> RecordTreatment with missing outcomes
  -> RECYCLED (v7) + RecyclingCompleted
  -> fake Kafka
  -> mock Python worker
  -> POST-equivalent analytics acknowledgement
  -> COMPLETED (v8) + AnalyticsCompleted audit + RequestCompleted
```

## Assertions

- Receipt and treatment events are persisted in order on `ewaste.batch.events`.
- Kafka partition key equals the batch ID and event schema version is `1`.
- Python receives the frozen treatment event rather than reading Go tables directly.
- Python and Go calculate the same frozen-input hash.
- Only the analytics service scope acknowledges completion.
- `MISSING` treatment data produces `MISSING_OUTCOME` and does not block completion after a valid acknowledgement.
- The final state is `COMPLETED` at aggregate version `8`.
- Analytics result, audit record, and `RequestCompleted` outbox row are durable together.

## Result

```text
PASS — TestFakeSprint3ReceiptTreatmentAnalyticsCompletionFlow
```

Commands used:

```text
go test ./internal/service -run TestFakeSprint3ReceiptTreatmentAnalyticsCompletionFlow -v
go test ./...
go vet ./...
```

This is a deterministic contract/integration test. It does not replace staging evidence with real MySQL, Redis, Kafka/Event Hubs, Azure Blob Storage, or the deployed Python worker. Those environments still require an end-to-end run and traceability links before the Jira items can be administratively marked Done.
