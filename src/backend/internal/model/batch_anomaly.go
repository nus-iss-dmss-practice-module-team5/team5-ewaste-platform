package model

import "time"

type AnomalyCode string

const (
	AnomalyCategoryMismatch AnomalyCode = "CATEGORY_MISMATCH"
	AnomalyCountMismatch    AnomalyCode = "COUNT_MISMATCH"
	AnomalyWeightMismatch   AnomalyCode = "WEIGHT_MISMATCH"
	AnomalyMissingOutcome   AnomalyCode = "MISSING_OUTCOME"
	AnomalyUnallocated      AnomalyCode = "UNALLOCATED_WEIGHT"
)

type BatchAnomaly struct {
	AnomalyID     string      `gorm:"column:anomaly_id;primaryKey;size:36"`
	BatchID       string      `gorm:"column:batch_id;size:36;index"`
	ResultID      string      `gorm:"column:result_id;size:36;index;uniqueIndex:uq_anomaly_result_code,priority:1"`
	Code          AnomalyCode `gorm:"column:code;size:32;uniqueIndex:uq_anomaly_result_code,priority:2"`
	DeclaredValue *string     `gorm:"column:declared_value;size:128"`
	ActualValue   *string     `gorm:"column:actual_value;size:128"`
	DeltaKg       *string     `gorm:"column:delta_kg;type:decimal(10,2)"`
	DetectedAt    time.Time   `gorm:"column:detected_at"`
}

func (BatchAnomaly) TableName() string { return "batch_anomalies" }
