package dto

import "time"

type AuditTimelineView struct {
	AuditID           string         `json:"audit_id"`
	BatchID           string         `json:"batch_id"`
	CommandID         string         `json:"command_id"`
	ActorUserID       *string        `json:"actor_user_id"`
	ActorOrganisation *string        `json:"actor_organisation_id"`
	ServicePrincipal  *string        `json:"service_principal"`
	EventType         string         `json:"event_type"`
	FromStatus        string         `json:"from_status"`
	ToStatus          string         `json:"to_status"`
	BatchVersion      uint32         `json:"batch_version"`
	Sequence          uint32         `json:"sequence_in_command"`
	OccurredAt        time.Time      `json:"occurred_at"`
	CorrelationID     string         `json:"correlation_id"`
	Details           map[string]any `json:"details"`
}

type AnomalyView struct {
	AnomalyID     string    `json:"anomaly_id"`
	BatchID       string    `json:"batch_id"`
	ResultID      string    `json:"result_id"`
	Code          string    `json:"code"`
	DeclaredValue *string   `json:"declared_value"`
	ActualValue   *string   `json:"actual_value"`
	DeltaKg       *string   `json:"delta_kg"`
	DetectedAt    time.Time `json:"detected_at"`
}

type ImpactResultView struct {
	ResultID           string           `json:"result_id"`
	BatchID            string           `json:"batch_id"`
	SourceEventID      string           `json:"source_event_id"`
	SourceEventVersion uint32           `json:"source_event_version"`
	ReceiptID          string           `json:"receipt_id"`
	ReceiptVersion     uint32           `json:"receipt_version"`
	TreatmentID        string           `json:"treatment_id"`
	TreatmentVersion   uint32           `json:"treatment_version"`
	RuleVersion        string           `json:"rule_version"`
	InputHash          string           `json:"input_hash"`
	DataQuality        string           `json:"data_quality"`
	Metrics            AnalyticsMetrics `json:"metrics"`
	AnomalyCodes       []string         `json:"anomaly_codes"`
	AcknowledgedAt     time.Time        `json:"acknowledged_at"`
}

type ImpactCollectionView struct {
	Items      []ImpactResultView `json:"items"`
	TotalCount int64              `json:"total_count"`
}
