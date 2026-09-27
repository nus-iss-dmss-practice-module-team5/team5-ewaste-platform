package repository

import (
	"context"
	"errors"
	"strings"
	"time"

	"workflow-api/internal/model"

	"gorm.io/gorm"
)

var (
	ErrWorkflowReadNotFound  = errors.New("repository: workflow resource not found")
	ErrWorkflowReadForbidden = errors.New("repository: workflow resource forbidden")
)

type WorkflowReadScope struct {
	UserID         string
	OrganisationID string
	RoleCode       string
}

type WorkflowReadPage struct {
	Page     int
	PageSize int
}

type WorkflowReadRepository interface {
	ListBatches(context.Context, WorkflowReadScope, *model.BatchStatus, WorkflowReadPage) ([]model.Batch, int64, error)
	FindBatch(context.Context, string, WorkflowReadScope) (*model.Batch, error)
	FindRecyclerOrganisation(context.Context, string) (string, error)
	ListOpportunities(context.Context, string, WorkflowReadPage) ([]model.WorkflowOpportunity, int64, error)
	FindOpportunity(context.Context, string, string) (*model.WorkflowOpportunity, error)
	ListAssignments(context.Context, string, string, string, WorkflowReadPage) ([]model.BatchAssignment, int64, error)
	FindAssignment(context.Context, string, string, string) (*model.BatchAssignment, error)
}

type GormWorkflowReadRepository struct {
	db *gorm.DB
}

func NewGormWorkflowReadRepository(db *gorm.DB) *GormWorkflowReadRepository {
	return &GormWorkflowReadRepository{db: db}
}

func (r *GormWorkflowReadRepository) ListBatches(
	ctx context.Context,
	scope WorkflowReadScope,
	status *model.BatchStatus,
	page WorkflowReadPage,
) ([]model.Batch, int64, error) {
	query, err := r.scopedBatchQuery(ctx, scope)
	if err != nil {
		return nil, 0, err
	}
	if status != nil {
		query = query.Where("b.status = ?", *status)
	}

	var countResult struct {
		Total int64 `gorm:"column:total"`
	}
	if err := query.Session(&gorm.Session{}).Select("COUNT(*) AS total").Scan(&countResult).Error; err != nil {
		return nil, 0, err
	}
	total := countResult.Total

	var batches []model.Batch
	err = query.
		Order("b.created_at DESC, b.id DESC").
		Offset((page.Page - 1) * page.PageSize).
		Limit(page.PageSize).
		Find(&batches).
		Error
	return batches, total, err
}

func (r *GormWorkflowReadRepository) FindBatch(
	ctx context.Context,
	batchID string,
	scope WorkflowReadScope,
) (*model.Batch, error) {
	query, err := r.scopedBatchQuery(ctx, scope)
	if err != nil {
		return nil, err
	}

	var batch model.Batch
	if err := query.Where("b.id = ?", batchID).First(&batch).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, ErrWorkflowReadNotFound
		}
		return nil, err
	}
	return &batch, nil
}

func (r *GormWorkflowReadRepository) scopedBatchQuery(
	ctx context.Context,
	scope WorkflowReadScope,
) (*gorm.DB, error) {
	if r == nil || r.db == nil {
		return nil, errors.New("repository: workflow read database is nil")
	}
	if strings.TrimSpace(scope.OrganisationID) == "" {
		return nil, ErrWorkflowReadForbidden
	}

	query := r.db.WithContext(ctx).
		Table("ewaste_batches AS b").
		Select("b.*")

	switch strings.ToUpper(strings.TrimSpace(scope.RoleCode)) {
	case "DONOR":
		return query.Where("b.organization_id = ?", scope.OrganisationID), nil
	case "COLLECTOR":
		if strings.TrimSpace(scope.UserID) == "" {
			return nil, ErrWorkflowReadForbidden
		}
		now := time.Now().UTC()
		query = query.
			Select(`b.*, (
				SELECT collector_scope.id
				FROM batch_claims AS claim
				INNER JOIN recycler_collector_scopes AS collector_scope
					ON collector_scope.recycler_org_id = claim.recycler_org_id
					AND collector_scope.collector_org_id = ?
					AND collector_scope.zone = b.zone
					AND collector_scope.is_active = TRUE
					AND collector_scope.valid_from <= ?
					AND (collector_scope.valid_until IS NULL OR collector_scope.valid_until > ?)
				WHERE claim.id = b.current_claim_id
					AND claim.batch_id = b.id
					AND claim.claim_epoch = b.claim_epoch
					AND claim.claim_status = ?
				LIMIT 1
			) AS collector_scope_id`, scope.OrganisationID, now, now, model.ClaimStatusAccepted).
			Where(`EXISTS (
				SELECT 1
				FROM batch_claims AS claim
				INNER JOIN recycler_collector_scopes AS collector_scope
					ON collector_scope.recycler_org_id = claim.recycler_org_id
					AND collector_scope.collector_org_id = ?
					AND collector_scope.zone = b.zone
					AND collector_scope.is_active = TRUE
					AND collector_scope.valid_from <= ?
					AND (collector_scope.valid_until IS NULL OR collector_scope.valid_until > ?)
				WHERE claim.id = b.current_claim_id
					AND claim.batch_id = b.id
					AND claim.claim_epoch = b.claim_epoch
					AND claim.claim_status = ?
			)`, scope.OrganisationID, now, now, model.ClaimStatusAccepted).
			Where("b.status = ?", model.BatchStatusApproved)
		return query, nil
	default:
		return nil, ErrWorkflowReadForbidden
	}
}

// Resolve opportunity scope from current database membership, not stale JWT claims.
func (r *GormWorkflowReadRepository) FindRecyclerOrganisation(ctx context.Context, userID string) (string, error) {
	if r == nil || r.db == nil {
		return "", errors.New("repository: workflow read database is nil")
	}
	var actor struct{ OrganisationID string }
	result := r.db.WithContext(ctx).Table("users AS u").Select("u.organisation_id").
		Joins("JOIN organisations AS o ON o.organisation_id = u.organisation_id").
		Joins("JOIN roles AS r ON r.role_code = u.role_code").
		Where("u.user_id = ? AND u.status = 'ACTIVE' AND u.role_code = 'RECYCLER' AND r.is_active = TRUE AND r.allowed_organisation_type = 'PROCESSING_FACILITY' AND o.status = 'ACTIVE' AND o.organisation_type = 'PROCESSING_FACILITY'", userID).
		Scan(&actor)
	if result.Error != nil {
		return "", result.Error
	}
	if result.RowsAffected != 1 {
		return "", ErrWorkflowReadForbidden
	}
	return actor.OrganisationID, nil
}

func (r *GormWorkflowReadRepository) ListOpportunities(
	ctx context.Context,
	recyclerOrganisationID string,
	page WorkflowReadPage,
) ([]model.WorkflowOpportunity, int64, error) {
	query, err := r.opportunityQuery(ctx, recyclerOrganisationID)
	if err != nil {
		return nil, 0, err
	}

	var countResult struct {
		Total int64 `gorm:"column:total"`
	}
	if err := query.Session(&gorm.Session{}).Select("COUNT(*) AS total").Scan(&countResult).Error; err != nil {
		return nil, 0, err
	}
	total := countResult.Total

	var opportunities []model.WorkflowOpportunity
	err = query.
		Order("b.collection_deadline ASC, b.id ASC").
		Offset((page.Page - 1) * page.PageSize).
		Limit(page.PageSize).
		Scan(&opportunities).
		Error
	return opportunities, total, err
}

func (r *GormWorkflowReadRepository) FindOpportunity(
	ctx context.Context,
	batchID string,
	recyclerOrganisationID string,
) (*model.WorkflowOpportunity, error) {
	query, err := r.opportunityQuery(ctx, recyclerOrganisationID)
	if err != nil {
		return nil, err
	}

	var opportunity model.WorkflowOpportunity
	if err := query.Where("b.id = ?", batchID).Scan(&opportunity).Error; err != nil {
		return nil, err
	}
	if opportunity.BatchID == "" {
		return nil, ErrWorkflowReadNotFound
	}
	return &opportunity, nil
}

func (r *GormWorkflowReadRepository) opportunityQuery(
	ctx context.Context,
	recyclerOrganisationID string,
) (*gorm.DB, error) {
	if r == nil || r.db == nil {
		return nil, errors.New("repository: workflow read database is nil")
	}
	if strings.TrimSpace(recyclerOrganisationID) == "" {
		return nil, ErrWorkflowReadForbidden
	}

	return r.db.WithContext(ctx).
		Table("matched_results AS mr").
		Select(`
			b.id AS batch_id,
			b.status,
			b.version,
			b.claim_epoch,
			b.category,
			b.quantity,
			b.estimated_weight_kg,
			b.zone,
			b.collection_deadline,
			mr.reason_code AS eligibility_reason
		`).
		Joins(`
			INNER JOIN ewaste_batches AS b
				ON b.id = mr.batch_id
		`).
		Joins(`
			INNER JOIN matching_decisions AS decision
				ON decision.id = mr.decision_id
				AND decision.batch_id = mr.batch_id
				AND decision.batch_version = b.version - 1
				AND decision.claim_epoch = b.claim_epoch
		`).
		Where(`
			mr.recycler_org_id = ?
			AND mr.is_matched = TRUE
			AND mr.reason_code = 'ELIGIBLE'
			AND decision.outcome = 'MATCHED'
			AND b.status = ?
		`, recyclerOrganisationID, model.BatchStatusMatched), nil
}

func (r *GormWorkflowReadRepository) ListAssignments(
	ctx context.Context,
	collectorUserID string,
	collectorOrganisationID string,
	status string,
	page WorkflowReadPage,
) ([]model.BatchAssignment, int64, error) {
	query, err := r.assignmentQuery(ctx, collectorUserID, collectorOrganisationID)
	if err != nil {
		return nil, 0, err
	}
	if status != "" {
		query = query.Where("assignment_status = ?", status)
	}

	var countResult struct {
		Total int64 `gorm:"column:total"`
	}
	if err := query.Session(&gorm.Session{}).Select("COUNT(*) AS total").Scan(&countResult).Error; err != nil {
		return nil, 0, err
	}
	total := countResult.Total

	var assignments []model.BatchAssignment
	err = query.
		Order("created_at DESC, id DESC").
		Offset((page.Page - 1) * page.PageSize).
		Limit(page.PageSize).
		Find(&assignments).
		Error
	return assignments, total, err
}

func (r *GormWorkflowReadRepository) FindAssignment(
	ctx context.Context,
	assignmentID string,
	collectorUserID string,
	collectorOrganisationID string,
) (*model.BatchAssignment, error) {
	query, err := r.assignmentQuery(ctx, collectorUserID, collectorOrganisationID)
	if err != nil {
		return nil, err
	}

	var assignment model.BatchAssignment
	if err := query.Where("id = ?", assignmentID).First(&assignment).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, ErrWorkflowReadNotFound
		}
		return nil, err
	}
	return &assignment, nil
}

func (r *GormWorkflowReadRepository) assignmentQuery(
	ctx context.Context,
	collectorUserID string,
	collectorOrganisationID string,
) (*gorm.DB, error) {
	if r == nil || r.db == nil {
		return nil, errors.New("repository: workflow read database is nil")
	}
	if strings.TrimSpace(collectorUserID) == "" || strings.TrimSpace(collectorOrganisationID) == "" {
		return nil, ErrWorkflowReadForbidden
	}

	return r.db.WithContext(ctx).
		Model(&model.BatchAssignment{}).
		Where("collector_user_id = ? AND collector_org_id = ?", collectorUserID, collectorOrganisationID), nil
}
