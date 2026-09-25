package repository

import (
	"context"
	"errors"
	"time"
	"workflow-api/internal/model"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

var (
	ErrBatchNotFound      = errors.New("repository: batch not found")
	ErrCommandNotFound    = errors.New("repository: command not found")
	ErrBatchConcurrency   = errors.New("repository: batch concurrency conflict")
	ErrCommandConcurrency = errors.New("repository: command concurrency conflict")
)

type BatchRepository interface {
	Transaction(ctx context.Context, fn func(BatchTransaction) error) error
}

type BatchTransaction interface {
	FindBatchForUpdate(ctx context.Context, batchID string) (*model.Batch, error)

	FindCommand(
		ctx context.Context,
		actorScope string,
		commandName string,
		idempotencyKey string,
	) (*model.CommandIdempotency, error)

	CreateBatch(ctx context.Context, batch *model.Batch) error
	CreateCommand(ctx context.Context, command *model.CommandIdempotency) error

	UpdateDraft(
		ctx context.Context,
		batchID string,
		organizationID string,
		createdBy string,
		expectedVersion uint32,
		changes map[string]any,
	) (*model.Batch, error)

	SubmitDraft(
		ctx context.Context,
		batchID string,
		organizationID string,
		createdBy string,
		expectedVersion uint32,
		submittedAt time.Time,
	) (*model.Batch, error)

	CompleteCommand(
		ctx context.Context,
		commandID string,
		responseStatus int,
		responseJSON []byte,
		completedAt time.Time,
	) error

	AppendAudit(ctx context.Context, event *model.BatchAuditEvent) error
	EnqueueOutbox(ctx context.Context, event *model.EventOutbox) error
}

type GormBatchRepository struct {
	db *gorm.DB
}

func NewGormBatchRepository(db *gorm.DB) *GormBatchRepository {
	return &GormBatchRepository{db: db}
}

func (r *GormBatchRepository) Transaction(
	ctx context.Context,
	fn func(BatchTransaction) error,
) error {
	if fn == nil {
		return errors.New("repository: transaction callback is nil")
	}

	return r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		return fn(&gormBatchTransaction{db: tx})
	})
}

type gormBatchTransaction struct {
	db *gorm.DB
}

func (t *gormBatchTransaction) FindBatchForUpdate(
	ctx context.Context,
	batchID string,
) (*model.Batch, error) {
	var batch model.Batch

	err := t.db.WithContext(ctx).
		Clauses(clause.Locking{Strength: "UPDATE"}).
		Where("id = ?", batchID).
		First(&batch).
		Error

	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, ErrBatchNotFound
	}
	if err != nil {
		return nil, err
	}

	return &batch, nil
}

func (t *gormBatchTransaction) FindCommand(
	ctx context.Context,
	actorScope string,
	commandName string,
	idempotencyKey string,
) (*model.CommandIdempotency, error) {
	var command model.CommandIdempotency

	err := t.db.WithContext(ctx).
		Clauses(clause.Locking{Strength: "UPDATE"}).
		Where(
			"actor_scope = ? AND command_name = ? AND idempotency_key = ?",
			actorScope,
			commandName,
			idempotencyKey,
		).
		First(&command).
		Error

	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, ErrCommandNotFound
	}
	if err != nil {
		return nil, err
	}

	return &command, nil
}

func (t *gormBatchTransaction) CreateBatch(
	ctx context.Context,
	batch *model.Batch,
) error {
	if batch == nil {
		return errors.New("repository: batch is nil")
	}

	return t.db.WithContext(ctx).Create(batch).Error
}

func (t *gormBatchTransaction) CreateCommand(
	ctx context.Context,
	command *model.CommandIdempotency,
) error {
	if command == nil {
		return errors.New("repository: command is nil")
	}

	return t.db.WithContext(ctx).Create(command).Error
}

func (t *gormBatchTransaction) UpdateDraft(
	ctx context.Context,
	batchID string,
	organizationID string,
	createdBy string,
	expectedVersion uint32,
	changes map[string]any,
) (*model.Batch, error) {
	updateValues := make(map[string]any, len(changes)+1)

	for column, value := range changes {
		updateValues[column] = value
	}

	updateValues["version"] = gorm.Expr("version + 1")

	result := t.db.WithContext(ctx).
		Model(&model.Batch{}).
		Where(
			"id = ? AND organization_id = ? AND created_by = ? AND status = ? AND version = ?",
			batchID,
			organizationID,
			createdBy,
			model.BatchStatusDraft,
			expectedVersion,
		).
		Updates(updateValues)

	if result.Error != nil {
		return nil, result.Error
	}
	if result.RowsAffected != 1 {
		return nil, ErrBatchConcurrency
	}

	var batch model.Batch
	if err := t.db.WithContext(ctx).
		Where("id = ?", batchID).
		First(&batch).
		Error; err != nil {
		return nil, err
	}

	return &batch, nil
}

func (t *gormBatchTransaction) SubmitDraft(
	ctx context.Context,
	batchID string,
	organizationID string,
	createdBy string,
	expectedVersion uint32,
	submittedAt time.Time,
) (*model.Batch, error) {
	result := t.db.WithContext(ctx).
		Model(&model.Batch{}).
		Where(
			"id = ? AND organization_id = ? AND created_by = ? AND status = ? AND version = ?",
			batchID,
			organizationID,
			createdBy,
			model.BatchStatusDraft,
			expectedVersion,
		).
		Updates(map[string]any{
			"status":       model.BatchStatusSubmitted,
			"submitted_at": submittedAt,
			"version":      gorm.Expr("version + 1"),
		})

	if result.Error != nil {
		return nil, result.Error
	}
	if result.RowsAffected != 1 {
		return nil, ErrBatchConcurrency
	}

	var batch model.Batch
	if err := t.db.WithContext(ctx).
		Where("id = ?", batchID).
		First(&batch).
		Error; err != nil {
		return nil, err
	}

	return &batch, nil
}

func (t *gormBatchTransaction) CompleteCommand(
	ctx context.Context,
	commandID string,
	responseStatus int,
	responseJSON []byte,
	completedAt time.Time,
) error {
	result := t.db.WithContext(ctx).
		Model(&model.CommandIdempotency{}).
		Where(
			"id = ? AND state = ?",
			commandID,
			model.CommandStateInProgress,
		).
		Updates(map[string]any{
			"state":           model.CommandStateCompleted,
			"response_status": responseStatus,
			"response_json":   responseJSON,
			"completed_at":    completedAt,
		})

	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected != 1 {
		return ErrCommandConcurrency
	}

	return nil
}

func (t *gormBatchTransaction) AppendAudit(
	ctx context.Context,
	event *model.BatchAuditEvent,
) error {
	if event == nil {
		return errors.New("repository: audit event is nil")
	}

	return t.db.WithContext(ctx).Create(event).Error
}

func (t *gormBatchTransaction) EnqueueOutbox(
	ctx context.Context,
	event *model.EventOutbox,
) error {
	if event == nil {
		return errors.New("repository: outbox event is nil")
	}

	return t.db.WithContext(ctx).Create(event).Error
}
