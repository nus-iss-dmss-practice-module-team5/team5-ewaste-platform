package service

import (
	"strconv"

	"workflow-api/internal/dto"
	"workflow-api/internal/model"
)

func batchToDTO(batch *model.Batch) dto.BatchView {
	var estimatedWeightKg *float64
	if batch.EstimatedWeightKg != nil {
		value, err := strconv.ParseFloat(*batch.EstimatedWeightKg, 64)
		if err == nil {
			estimatedWeightKg = &value
		}
	}

	return dto.BatchView{
		BatchID:            batch.ID,
		Status:             string(batch.Status),
		Version:            int64(batch.Version),
		Category:           batch.Category,
		Quantity:           batch.Quantity,
		EstimatedWeightKg:  estimatedWeightKg,
		ConditionRating:    batch.ConditionRating,
		IsDataBearing:      &batch.IsDataBearing,
		Zone:               batch.Zone,
		CollectionDeadline: batch.CollectionDeadline,
		Notes:              batch.Notes,
		CreatedAt:          batch.CreatedAt,
		UpdatedAt:          batch.UpdatedAt,
	}
}
