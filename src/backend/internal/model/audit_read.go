package model

import "time"

// ImpactReadResult is the read-side projection exposed to Auditor APIs. The
// write-side analytics entity remains separate so read concerns do not leak
// into the completion transaction.
type ImpactReadResult struct {
	ResultID           string
	BatchID            string
	SourceEventID      string
	SourceEventVersion uint32
	ReceiptID          string
	ReceiptVersion     uint32
	TreatmentID        string
	TreatmentVersion   uint32
	RuleVersion        string
	InputHash          string
	DataQuality        AnalyticsDataQuality
	MetricsJSON        []byte
	AnomalyCodes       []string
	AcknowledgedAt     time.Time
}
