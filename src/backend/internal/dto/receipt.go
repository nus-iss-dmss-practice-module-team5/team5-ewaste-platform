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
