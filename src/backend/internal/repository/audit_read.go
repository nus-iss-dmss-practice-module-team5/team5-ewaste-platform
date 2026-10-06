package repository

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"workflow-api/internal/model"

	"gorm.io/gorm"
)

// AuditorReadRepository contains read-only projections for the D4 Auditor
// boundary. It deliberately has no mutation methods.
type AuditorReadRepository interface {
	FindAuditTimeline(context.Context, string, WorkflowReadScope) ([]*model.BatchAuditEvent, error)
	FindAuditAnomalies(context.Context, string, WorkflowReadScope) ([]*model.BatchAnomaly, error)
	ListImpactResults(context.Context, WorkflowReadScope) ([]*model.ImpactReadResult, error)
}

type GormAuditorReadRepository struct {
	db *gorm.DB
}

func NewGormAuditorReadRepository(db *gorm.DB) *GormAuditorReadRepository {
	return &GormAuditorReadRepository{db: db}
}

func (r *GormAuditorReadRepository) FindAuditTimeline(
	ctx context.Context,
	batchID string,
	scope WorkflowReadScope,
) ([]*model.BatchAuditEvent, error) {
	if err := r.validateAuditor(ctx, scope); err != nil {
		return nil, err
	}
	if err := r.requireBatch(ctx, batchID); err != nil {
		return nil, err
	}
	var events []*model.BatchAuditEvent
	if err := r.db.WithContext(ctx).
		Where("batch_id = ?", batchID).
		Order("occurred_at ASC, batch_version ASC, sequence_in_command ASC, id ASC").
		Find(&events).Error; err != nil {
		return nil, err
	}
	return events, nil
}

func (r *GormAuditorReadRepository) FindAuditAnomalies(
	ctx context.Context,
	batchID string,
	scope WorkflowReadScope,
) ([]*model.BatchAnomaly, error) {
	if err := r.validateAuditor(ctx, scope); err != nil {
		return nil, err
	}
	if err := r.requireBatch(ctx, batchID); err != nil {
		return nil, err
	}
	var anomalies []*model.BatchAnomaly
	if err := r.db.WithContext(ctx).
		Where("batch_id = ?", batchID).
		Order("detected_at ASC, anomaly_id ASC").
		Find(&anomalies).Error; err != nil {
		return nil, err
	}
	return anomalies, nil
}

func (r *GormAuditorReadRepository) ListImpactResults(
	ctx context.Context,
	scope WorkflowReadScope,
) ([]*model.ImpactReadResult, error) {
	if err := r.validateAuditor(ctx, scope); err != nil {
		return nil, err
	}

	// Keep this projection on the current backend analytics table. The
	// migration/table-name discrepancy is intentionally not hidden here; the
	// repository must fail visibly until the deployed schema is reconciled.
	type row struct {
		ResultID           string    `gorm:"column:result_id"`
		BatchID            string    `gorm:"column:batch_id"`
		SourceEventID      string    `gorm:"column:source_event_id"`
		SourceEventVersion uint32    `gorm:"column:source_batch_version"`
		ReceiptID          string    `gorm:"column:receipt_id"`
		ReceiptVersion     uint32    `gorm:"column:receipt_version"`
		TreatmentID        string    `gorm:"column:treatment_id"`
		TreatmentVersion   uint32    `gorm:"column:treatment_version"`
		RuleVersion        string    `gorm:"column:rule_version"`
		InputHash          string    `gorm:"column:input_hash"`
		DataQuality        string    `gorm:"column:data_quality"`
		InputSnapshotJSON  []byte    `gorm:"column:input_snapshot_json"`
		AcknowledgedAt     time.Time `gorm:"column:calculated_at"`
	}
	var rows []row
	if err := r.db.WithContext(ctx).
		Table("batch_impact_metrics AS ar").
		Select("ar.metric_id AS result_id, ar.batch_id, ar.source_event_id, ar.source_batch_version, ar.receipt_id, ar.receipt_version, ar.treatment_id, ar.treatment_version, ar.rule_version, ar.input_hash, ar.data_quality, ar.input_snapshot_json, ar.calculated_at").
		Joins("INNER JOIN ewaste_batches AS b ON b.id = ar.batch_id").
		Where("b.status = ?", model.BatchStatusCompleted).
		Order("ar.acknowledged_at DESC, ar.result_id DESC").
		Find(&rows).Error; err != nil {
		return nil, err
	}

	results := make([]*model.ImpactReadResult, 0, len(rows))
	for _, item := range rows {
		metricsJSON, err := metricsFromAnalyticsSnapshot(item.InputSnapshotJSON)
		if err != nil {
			return nil, err
		}
		anomalies, err := r.findAnomalyCodes(ctx, item.ResultID, item.BatchID)
		if err != nil {
			return nil, err
		}
		results = append(results, &model.ImpactReadResult{
			ResultID: item.ResultID, BatchID: item.BatchID, SourceEventID: item.SourceEventID,
			SourceEventVersion: item.SourceEventVersion, ReceiptID: item.ReceiptID,
			ReceiptVersion: item.ReceiptVersion, TreatmentID: item.TreatmentID,
			TreatmentVersion: item.TreatmentVersion, RuleVersion: item.RuleVersion,
			InputHash: item.InputHash, DataQuality: model.AnalyticsDataQuality(item.DataQuality),
			MetricsJSON: metricsJSON, AnomalyCodes: anomalies,
			AcknowledgedAt: item.AcknowledgedAt,
		})
	}
	return results, nil
}

func (r *GormAuditorReadRepository) findAnomalyCodes(ctx context.Context, resultID, batchID string) ([]string, error) {
	codes := make([]string, 0)
	if err := r.db.WithContext(ctx).Table("batch_anomalies").
		Where("metric_id = ? AND batch_id = ?", resultID, batchID).
		Order("anomaly_id ASC").Pluck("anomaly_code", &codes).Error; err != nil {
		return nil, err
	}
	return codes, nil
}

func metricsFromAnalyticsSnapshot(snapshotJSON []byte) ([]byte, error) {
	var snapshot struct {
		Metrics json.RawMessage `json:"metrics"`
	}
	if err := json.Unmarshal(snapshotJSON, &snapshot); err != nil {
		return nil, fmt.Errorf("repository: decode impact snapshot: %w", err)
	}
	if len(snapshot.Metrics) == 0 || string(snapshot.Metrics) == "null" {
		return []byte(`{}`), nil
	}
	return append([]byte(nil), snapshot.Metrics...), nil
}

func (r *GormAuditorReadRepository) validateAuditor(ctx context.Context, scope WorkflowReadScope) error {
	if r == nil || r.db == nil || strings.TrimSpace(scope.UserID) == "" || !strings.EqualFold(scope.RoleCode, "AUDITOR") {
		return ErrWorkflowReadForbidden
	}
	var count int64
	if err := r.db.WithContext(ctx).Table("users AS u").
		Joins("INNER JOIN roles AS role ON role.role_code = u.role_code").
		Where("u.user_id = ? AND u.status = 'ACTIVE' AND u.role_code = 'AUDITOR' AND role.is_active = TRUE AND role.allowed_organisation_type = 'PLATFORM'", scope.UserID).
		Count(&count).Error; err != nil {
		return err
	}
	if count != 1 {
		return ErrWorkflowReadForbidden
	}
	return nil
}

func (r *GormAuditorReadRepository) requireBatch(ctx context.Context, batchID string) error {
	if strings.TrimSpace(batchID) == "" {
		return ErrWorkflowReadNotFound
	}
	var count int64
	if err := r.db.WithContext(ctx).Table("ewaste_batches").Where("id = ?", batchID).Count(&count).Error; err != nil {
		return err
	}
	if count != 1 {
		return ErrWorkflowReadNotFound
	}
	return nil
}
