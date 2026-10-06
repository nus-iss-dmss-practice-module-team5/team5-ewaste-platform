package dto

type ReceiptRequest struct {
	ActualCategory  string `json:"actual_category"`
	ActualItemCount uint32 `json:"actual_item_count"`
	ActualWeightKg  string `json:"actual_weight_kg"`
}

type ReceiptView struct {
	BatchID         string `json:"batch_id"`
	Status          string `json:"status"`
	Version         int64  `json:"version"`
	ReceiptID       string `json:"receipt_id"`
	ActualCategory  string `json:"actual_category"`
	ActualItemCount uint32 `json:"actual_item_count"`
	ActualWeightKg  string `json:"actual_weight_kg"`
}

type ReceiptMutationResult struct {
	Data          ReceiptView `json:"data"`
	CorrelationID string      `json:"correlation_id"`
	EventID       string      `json:"event_id,omitempty"`
	EventState    string      `json:"event_state,omitempty"`
}

type TreatmentRequest struct {
	ReusedKg   *string `json:"reused_kg"`
	RecycledKg *string `json:"recycled_kg"`
	DisposedKg *string `json:"disposed_kg"`
	EvidenceID *string `json:"evidence_id"`
}

type TreatmentView struct {
	BatchID        string  `json:"batch_id"`
	Status         string  `json:"status"`
	Version        int64   `json:"version"`
	TreatmentID    string  `json:"treatment_id"`
	ReusedKg       *string `json:"reused_kg"`
	RecycledKg     *string `json:"recycled_kg"`
	DisposedKg     *string `json:"disposed_kg"`
	UnknownKg      *string `json:"unknown_kg"`
	DivertedKg     *string `json:"diverted_kg"`
	DataQuality    string  `json:"data_quality"`
	EvidenceStatus string  `json:"evidence_status"`
}

type TreatmentMutationResult struct {
	Data          TreatmentView `json:"data"`
	CorrelationID string        `json:"correlation_id"`
	EventID       string        `json:"event_id,omitempty"`
	EventState    string        `json:"event_state,omitempty"`
}
