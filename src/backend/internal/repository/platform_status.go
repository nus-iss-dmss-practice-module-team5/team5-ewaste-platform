package repository

import (
	"context"
	"database/sql"
	"strings"

	"workflow-api/internal/model"

	"gorm.io/gorm"
)

// PlatformStatusRepository holds the read-only projections behind the
// Administrator health view. It deliberately has no mutation methods and no
// method that returns custody evidence or event payloads.
type PlatformStatusRepository interface {
	ValidateAdmin(ctx context.Context, userID string) error
	SummariseOutbox(ctx context.Context, recentLimit int) (*model.OutboxSummary, error)
	SummariseEvidence(ctx context.Context) (*model.EvidenceSummary, error)
}

type GormPlatformStatusRepository struct {
	db *gorm.DB
}

func NewGormPlatformStatusRepository(db *gorm.DB) *GormPlatformStatusRepository {
	return &GormPlatformStatusRepository{db: db}
}

func (r *GormPlatformStatusRepository) ValidateAdmin(ctx context.Context, userID string) error {
	if r == nil || r.db == nil || strings.TrimSpace(userID) == "" {
		return ErrWorkflowReadForbidden
	}
	var count int64
	if err := r.db.WithContext(ctx).Table("users AS u").
		Joins("INNER JOIN roles AS role ON role.role_code = u.role_code").
		Where("u.user_id = ? AND u.status = 'ACTIVE' AND u.role_code = 'SYSTEM_ADMIN' AND role.is_active = TRUE AND role.allowed_organisation_type = 'PLATFORM'", userID).
		Count(&count).Error; err != nil {
		return err
	}
	if count != 1 {
		return ErrWorkflowReadForbidden
	}
	return nil
}

// SummariseOutbox reads by publish_state, which leads idx_outbox_due. The
// table has no quarantine timestamp, so the newest rows are by created_at.
func (r *GormPlatformStatusRepository) SummariseOutbox(ctx context.Context, recentLimit int) (*model.OutboxSummary, error) {
	db := r.db.WithContext(ctx)
	var pending struct {
		Count  int64
		Oldest sql.NullTime
	}
	if err := db.Model(&model.EventOutbox{}).
		Select("COUNT(*) AS count, MIN(created_at) AS oldest").
		Where("publish_state = ?", model.OutboxPublishStatePending).
		Scan(&pending).Error; err != nil {
		return nil, err
	}
	var quarantined int64
	if err := db.Model(&model.EventOutbox{}).
		Where("publish_state = ?", model.OutboxPublishStateQuarantined).
		Count(&quarantined).Error; err != nil {
		return nil, err
	}
	var rows []model.EventOutbox
	if quarantined > 0 {
		if err := db.
			Select("event_type", "schema_version", "batch_id", "attempt_count", "last_error_code", "created_at", "correlation_id").
			Where("publish_state = ?", model.OutboxPublishStateQuarantined).
			Order("created_at DESC, event_id DESC").
			Limit(recentLimit).
			Find(&rows).Error; err != nil {
			return nil, err
		}
	}
	summary := &model.OutboxSummary{
		Pending: pending.Count, Quarantined: quarantined,
		RecentQuarantined: make([]model.QuarantinedEvent, 0, len(rows)),
	}
	if pending.Oldest.Valid {
		oldest := pending.Oldest.Time.UTC()
		summary.OldestPendingCreatedAt = &oldest
	}
	for _, row := range rows {
		summary.RecentQuarantined = append(summary.RecentQuarantined, model.QuarantinedEvent{
			EventType: row.EventType, SchemaVersion: row.SchemaVersion, BatchID: row.BatchID,
			AttemptCount: row.AttemptCount, LastErrorCode: row.LastErrorCode,
			CreatedAt: row.CreatedAt.UTC(), CorrelationID: row.CorrelationID,
		})
	}
	return summary, nil
}

func (r *GormPlatformStatusRepository) SummariseEvidence(ctx context.Context) (*model.EvidenceSummary, error) {
	var counts struct {
		Completed    int64
		WithEvidence int64
	}
	err := r.db.WithContext(ctx).Table("ewaste_batches AS b").
		Select(`COUNT(*) AS completed,
			COALESCE(SUM(EXISTS (SELECT 1 FROM batch_evidence AS e WHERE e.batch_id = b.id)), 0) AS with_evidence`).
		Where("b.status = ?", model.BatchStatusCompleted).
		Scan(&counts).Error
	if err != nil {
		return nil, err
	}
	return &model.EvidenceSummary{CompletedBatches: counts.Completed, WithEvidence: counts.WithEvidence}, nil
}

var _ PlatformStatusRepository = (*GormPlatformStatusRepository)(nil)
