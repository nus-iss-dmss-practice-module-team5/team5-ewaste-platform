package service

import (
	"workflow-api/internal/dto"
	"workflow-api/internal/model"
)

func batchToDTO(batch *model.Batch) dto.BatchView {
	return dto.BatchView{
		BatchID:            batch.BatchID,
		Status:             string(batch.Status),
		Version:            batch.Version,
		Category:           batch.Category,
		Quantity:           batch.Quantity,
		EstimatedWeightKg:  batch.EstimatedWeightKg,
		ConditionRating:    batch.ConditionRating,
		IsDataBearing:      batch.IsDataBearing,
		Zone:               batch.Zone,
		CollectionDeadline: batch.CollectionDeadline,
		Notes:              batch.Notes,
		CreatedAt:          batch.CreatedAt,
		UpdatedAt:          batch.UpdatedAt,
	}
}
