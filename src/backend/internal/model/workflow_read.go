package model

import "time"

// WorkflowOpportunity is the deliberately small public projection of a
// persisted matching result. Matching evidence, organisation identifiers, and
// claim internals stay behind the repository boundary.
type WorkflowOpportunity struct {
	BatchID            string      `gorm:"column:batch_id"`
	Status             BatchStatus `gorm:"column:status"`
	Version            uint32      `gorm:"column:version"`
	ClaimEpoch         uint64      `gorm:"column:claim_epoch"`
	Category           *string     `gorm:"column:category"`
	Quantity           *int        `gorm:"column:quantity"`
	EstimatedWeightKg  *string     `gorm:"column:estimated_weight_kg"`
	Zone               *string     `gorm:"column:zone"`
	CollectionDeadline *time.Time  `gorm:"column:collection_deadline"`
	EligibilityReason  string      `gorm:"column:eligibility_reason"`
}

// BatchTimelineEntry is one append-only audit record with the actor and
// organisation names resolved. Only whitelisted details leave the service.
type BatchTimelineEntry struct {
	ID                string      `gorm:"column:id"`
	ActorUserID       *string     `gorm:"column:actor_user_id"`
	ActorName         *string     `gorm:"column:actor_name"`
	OrganisationID    *string     `gorm:"column:actor_org_id"`
	OrganisationName  *string     `gorm:"column:organisation_name"`
	ServicePrincipal  *string     `gorm:"column:service_principal"`
	EventType         string      `gorm:"column:event_type"`
	FromStatus        BatchStatus `gorm:"column:from_status"`
	ToStatus          BatchStatus `gorm:"column:to_status"`
	BatchVersion      uint32      `gorm:"column:batch_version"`
	SequenceInCommand uint32      `gorm:"column:sequence_in_command"`
	OccurredAt        time.Time   `gorm:"column:occurred_at"`
	CorrelationID     string      `gorm:"column:correlation_id"`
	DetailsJSON       []byte      `gorm:"column:details_json"`
}
