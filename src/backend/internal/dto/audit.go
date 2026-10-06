package dto

import "time"

// TimelineEntryView is one row of a batch custody timeline. Audit details are
// not passed through: only the result and an evidence id are exposed.
type TimelineEntryView struct {
	EventID          string    `json:"event_id"`
	OccurredAt       time.Time `json:"occurred_at"`
	Action           string    `json:"action"`
	FromStatus       string    `json:"from_status"`
	ToStatus         string    `json:"to_status"`
	Result           string    `json:"result"`
	BatchVersion     int64     `json:"batch_version"`
	ActorUserID      string    `json:"actor_user_id,omitempty"`
	ActorName        string    `json:"actor_name,omitempty"`
	OrganisationID   string    `json:"organisation_id,omitempty"`
	OrganisationName string    `json:"organisation_name,omitempty"`
	ServicePrincipal string    `json:"service_principal,omitempty"`
	EvidenceID       string    `json:"evidence_id,omitempty"`
	CorrelationID    string    `json:"correlation_id"`
}
