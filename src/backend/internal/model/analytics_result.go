package model

import "time"

type AnalyticsDataQuality string

const (
	AnalyticsDataQualityComplete AnalyticsDataQuality = "COMPLETE"
	AnalyticsDataQualityPartial  AnalyticsDataQuality = "PARTIAL"
	AnalyticsDataQualityMissing  AnalyticsDataQuality = "MISSING"
)

type AnalyticsResult struct {
	ResultID           string               `gorm:"column:result_id;primaryKey;size:36"`
	BatchID            string               `gorm:"column:batch_id;size:36;uniqueIndex"`
	SourceEventID      string               `gorm:"column:source_event_id;size:36;uniqueIndex:uq_analytics_results_source_run,priority:1"`
	SourceEventVersion uint32               `gorm:"column:source_event_version"`
	ReceiptID          string               `gorm:"column:receipt_id;size:36"`
	TreatmentID        string               `gorm:"column:treatment_id;size:36"`
	ClaimEpoch         *string              `gorm:"column:claim_epoch;size:32"`
	AnalyticsRunID     string               `gorm:"column:analytics_run_id;size:128;uniqueIndex:uq_analytics_results_source_run,priority:2"`
	InputHash          string               `gorm:"column:input_hash;size:64"`
	RuleVersion        string               `gorm:"column:rule_version;size:64"`
	DataQuality        AnalyticsDataQuality `gorm:"column:data_quality;size:16"`
	MetricsJSON        []byte               `gorm:"column:metrics_json;type:json"`
	AcknowledgedAt     time.Time            `gorm:"column:acknowledged_at"`
}

func (AnalyticsResult) TableName() string { return "analytics_results" }
