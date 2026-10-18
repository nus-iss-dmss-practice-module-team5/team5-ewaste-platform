package model

import "time"

// OutboxSummary is the Administrator's view of event delivery. It carries
// metadata only: no payload leaves the outbox table.
type OutboxSummary struct {
	Pending                int64
	OldestPendingCreatedAt *time.Time
	Quarantined            int64
	RecentQuarantined      []QuarantinedEvent
}

type QuarantinedEvent struct {
	EventType     string
	SchemaVersion uint32
	BatchID       string
	AttemptCount  uint32
	LastErrorCode *string
	CreatedAt     time.Time
	CorrelationID string
}

// EvidenceSummary counts COMPLETED batches with and without validated
// custody evidence. D5: the Administrator sees counts, never files.
type EvidenceSummary struct {
	CompletedBatches int64
	WithEvidence     int64
}
