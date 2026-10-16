package dto

import "time"

// PlatformStatusView is the Administrator health and release read
// (GET /api/v1/admin/platform-status). A source that could not be read is
// null and named in Unknown with a reason code; it is never reported as 0.
type PlatformStatusView struct {
	ReadAt                     time.Time          `json:"read_at"`
	Environment                *string            `json:"environment"`
	Summary                    string             `json:"summary"`
	Readiness                  ReadinessView      `json:"readiness"`
	Latency                    *LatencyView       `json:"latency"`
	ConsumerLag                *ConsumerLagView   `json:"consumer_lag"`
	Outbox                     *OutboxStatusView  `json:"outbox"`
	ProcessingFailuresLastHour *int64             `json:"processing_failures_last_hour"`
	Evidence                   *EvidenceCountView `json:"evidence"`
	Release                    *ReleaseView       `json:"release"`
	WorkbookURL                *string            `json:"workbook_url"`
	Unknown                    map[string]string  `json:"unknown"`
}

type ReadinessView struct {
	Status string `json:"status"`
	MySQL  string `json:"mysql"`
	Redis  string `json:"redis"`
}

type LatencyView struct {
	APIP95Ms      *float64  `json:"api_p95_ms"`
	APISamples    int64     `json:"api_samples"`
	EventP95Ms    *float64  `json:"event_p95_ms"`
	EventSamples  int64     `json:"event_samples"`
	WindowMinutes int       `json:"window_minutes"`
	ReadAt        time.Time `json:"read_at"`
}

// ConsumerLagView.Records is null when a partition sample is missing or
// older than 90 seconds.
type ConsumerLagView struct {
	Records    *int64     `json:"records"`
	Partitions int64      `json:"partitions"`
	SampledAt  *time.Time `json:"sampled_at"`
}

type OutboxStatusView struct {
	Pending                int64                  `json:"pending"`
	OldestPendingCreatedAt *time.Time             `json:"oldest_pending_created_at"`
	Quarantined            int64                  `json:"quarantined"`
	RecentQuarantined      []QuarantinedEventView `json:"recent_quarantined"`
}

// QuarantinedEventView is outbox metadata only. No payload is returned.
type QuarantinedEventView struct {
	EventType     string    `json:"event_type"`
	SchemaVersion uint32    `json:"schema_version"`
	BatchID       string    `json:"batch_id"`
	AttemptCount  uint32    `json:"attempt_count"`
	LastErrorCode *string   `json:"last_error_code"`
	CreatedAt     time.Time `json:"created_at"`
	CorrelationID string    `json:"correlation_id"`
}

// EvidenceCountView is platform-wide counts only (D5): no file list and no
// batch drill-down.
type EvidenceCountView struct {
	CompletedBatches int64 `json:"completed_batches"`
	WithEvidence     int64 `json:"with_evidence"`
	WithoutEvidence  int64 `json:"without_evidence"`
}

type ReleaseView struct {
	ID             string             `json:"id"`
	Commit         *string            `json:"commit"`
	DeployedAt     *time.Time         `json:"deployed_at"`
	GateRunURL     *string            `json:"gate_run_url"`
	GateDecision   *string            `json:"gate_decision"`
	Images         []ReleaseImageView `json:"images"`
	RollbackTarget *RollbackView      `json:"rollback_target"`
}

type RollbackView struct {
	ID         string             `json:"id"`
	Commit     *string            `json:"commit"`
	GateRunURL *string            `json:"gate_run_url"`
	Images     []ReleaseImageView `json:"images"`
}

type ReleaseImageView struct {
	Name   string `json:"name"`
	Digest string `json:"digest"`
}
