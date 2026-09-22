package model

import "time"

type BatchStatus string

const (
	BatchStatusDraft            BatchStatus = "DRAFT"
	BatchStatusSubmitted        BatchStatus = "SUBMITTED"
	BatchStatusMatched          BatchStatus = "MATCHED"
	BatchStatusApproved         BatchStatus = "APPROVED"
	BatchStatusAssigned         BatchStatus = "ASSIGNED"
	BatchStatusCollected        BatchStatus = "COLLECTED"
	BatchStatusFailedCollection BatchStatus = "FAILED_COLLECTION"
)

type Batch struct {
	BatchID             string      `gorm:"column:batch_id;primaryKey;size:36"`
	DonorUserID         string      `gorm:"column:donor_user_id;size:36;index"`
	DonorOrganisationID string      `gorm:"column:donor_organisation_id;size:32;index"`
	Status              BatchStatus `gorm:"column:status;size:32;index"`
	Version             int64       `gorm:"column:version"`
	Category            *string     `gorm:"column:category;size:100"`
	Quantity            *int        `gorm:"column:quantity"`
	EstimatedWeightKg   *float64    `gorm:"column:estimated_weight_kg"`
	ConditionRating     *string     `gorm:"column:condition_rating;size:50"`
	IsDataBearing       *bool       `gorm:"column:is_data_bearing"`
	Zone                *string     `gorm:"column:zone;size:100"`
	CollectionDeadline  *time.Time  `gorm:"column:collection_deadline"`
	Notes               *string     `gorm:"column:notes;size:500"`
	CreatedAt           time.Time   `gorm:"column:created_at"`
	UpdatedAt           time.Time   `gorm:"column:updated_at"`
}

func (Batch) TableName() string {
	return "batches"
}

func (b Batch) CanEdit() bool {
	return b.Status == BatchStatusDraft
}

func (b Batch) CanSubmit() bool {
	return b.Status == BatchStatusDraft
}
