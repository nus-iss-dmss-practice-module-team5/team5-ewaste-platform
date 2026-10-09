package service

import (
	"context"
	"errors"
	"strconv"
	"testing"
	"time"

	"workflow-api/internal/dto"
	"workflow-api/internal/model"
	"workflow-api/internal/repository"
)

type fakeAssignmentRepository struct {
	batch       *model.Batch
	claim       *model.BatchClaim
	reservation *model.CapacityReservation
	scope       *model.RecyclerCollectorScope
	assignment  *model.BatchAssignment
	commands    map[string]*model.CommandIdempotency
	handoffs    []*model.BatchHandoff
	actions     []*model.AssignmentAction
	audits      []*model.BatchAuditEvent
	outbox      []*model.EventOutbox
}

func newFakeAssignmentRepository() *fakeAssignmentRepository {
	return &fakeAssignmentRepository{
		batch:       &model.Batch{ID: "batch-1", Status: model.BatchStatusApproved, Version: 1, ClaimEpoch: 1, CurrentClaimID: new("claim-1"), Zone: new("NORTH")},
		claim:       &model.BatchClaim{ID: "claim-1", BatchID: "batch-1", ClaimEpoch: 1, RecyclerOrgID: "REC-001", ClaimStatus: model.ClaimStatusAccepted},
		reservation: &model.CapacityReservation{ID: "reservation-1", BatchID: "batch-1", ClaimID: "claim-1", Status: model.CapacityReservationStatusReserved},
		scope:       &model.RecyclerCollectorScope{ID: "scope-1", RecyclerOrgID: "REC-001", CollectorOrgID: "COL-001", Zone: "NORTH", IsActive: true},
		commands:    make(map[string]*model.CommandIdempotency),
	}
}

func (r *fakeAssignmentRepository) Transaction(_ context.Context, fn func(repository.AssignmentTransaction) error) error {
	return fn(&fakeAssignmentTransaction{repo: r})
}

type fakeAssignmentTransaction struct{ repo *fakeAssignmentRepository }

func (t *fakeAssignmentTransaction) ValidateCollectorActor(context.Context, string, string) error {
	return nil
}
func (t *fakeAssignmentTransaction) FindCommand(_ context.Context, scope, name, key string) (*model.CommandIdempotency, error) {
	command, ok := t.repo.commands[scope+"|"+name+"|"+key]
	if !ok {
		return nil, repository.ErrAssignmentCommandNotFound
	}
	return command, nil
}
func (t *fakeAssignmentTransaction) CreateCommand(_ context.Context, command *model.CommandIdempotency) error {
	t.repo.commands[command.ActorScope+"|"+command.CommandName+"|"+command.IdempotencyKey] = command
	return nil
}
func (t *fakeAssignmentTransaction) LinkCommandAssignment(_ context.Context, commandID, assignmentID string) error {
	for _, command := range t.repo.commands {
		if command.ID == commandID {
			command.AssignmentID = &assignmentID
			return nil
		}
	}
	return errors.New("command missing")
}
func (t *fakeAssignmentTransaction) CompleteCommand(_ context.Context, commandID string, status int, body []byte, completedAt time.Time) error {
	for _, command := range t.repo.commands {
		if command.ID == commandID {
			command.State = model.CommandStateCompleted
			command.ResponseStatus = &status
			command.ResponseJSON = body
			command.CompletedAt = &completedAt
			return nil
		}
	}
	return errors.New("command missing")
}
func (t *fakeAssignmentTransaction) FindBatchForUpdate(context.Context, string) (*model.Batch, error) {
	return t.repo.batch, nil
}
func (t *fakeAssignmentTransaction) FindAcceptedClaimReservation(context.Context, *model.Batch) (*model.BatchClaim, *model.CapacityReservation, error) {
	return t.repo.claim, t.repo.reservation, nil
}
func (t *fakeAssignmentTransaction) FindCollectorScope(context.Context, string, string, string, string, time.Time) (*model.RecyclerCollectorScope, error) {
	return t.repo.scope, nil
}
func (t *fakeAssignmentTransaction) FindLatestAssignment(context.Context, string) (*model.BatchAssignment, error) {
	if t.repo.assignment == nil {
		return nil, repository.ErrAssignmentNotFound
	}
	return t.repo.assignment, nil
}
func (t *fakeAssignmentTransaction) FindAssignmentForUpdate(context.Context, string) (*model.BatchAssignment, error) {
	if t.repo.assignment == nil {
		return nil, repository.ErrAssignmentNotFound
	}
	return t.repo.assignment, nil
}
func (t *fakeAssignmentTransaction) CreateAssignment(_ context.Context, assignment *model.BatchAssignment) error {
	t.repo.assignment = assignment
	return nil
}
func (t *fakeAssignmentTransaction) UpdateAssignment(context.Context, *model.BatchAssignment) error {
	return nil
}
func (t *fakeAssignmentTransaction) UpdateBatchAssignment(_ context.Context, _ string, expected uint32, from, to model.BatchStatus, assignmentID *string, now time.Time) (*model.Batch, error) {
	if t.repo.batch.Version != expected || t.repo.batch.Status != from {
		return nil, repository.ErrAssignmentConcurrency
	}
	t.repo.batch.Status = to
	t.repo.batch.Version++
	t.repo.batch.CurrentAssignmentID = assignmentID
	t.repo.batch.UpdatedAt = now
	return t.repo.batch, nil
}
func (t *fakeAssignmentTransaction) CreateHandoff(_ context.Context, handoff *model.BatchHandoff) error {
	t.repo.handoffs = append(t.repo.handoffs, handoff)
	return nil
}
func (t *fakeAssignmentTransaction) CreateAction(_ context.Context, action *model.AssignmentAction) error {
	t.repo.actions = append(t.repo.actions, action)
	return nil
}
func (t *fakeAssignmentTransaction) AppendAudit(_ context.Context, audit *model.BatchAuditEvent) error {
	t.repo.audits = append(t.repo.audits, audit)
	return nil
}
func (t *fakeAssignmentTransaction) EnqueueOutbox(_ context.Context, event *model.EventOutbox) error {
	t.repo.outbox = append(t.repo.outbox, event)
	return nil
}

func testAssignmentMetadata(key string) BatchCommandMetadata {
	return BatchCommandMetadata{
		Actor:         BatchActor{UserID: "USR-001", OrganisationID: "COL-001", RoleCode: "COLLECTOR"},
		CorrelationID: "corr-1", IdempotencyKey: key, ExpectedVersion: 1,
	}
}

func TestAssignmentSelectIsIdempotentAndAudited(t *testing.T) {
	repo := newFakeAssignmentRepository()
	service := NewAssignmentWorkflowService(repo)
	service.newID = func() string { return "generated-id" }
	request := dto.AssignmentSelectionRequest{ExpectedVersion: 1, ClaimEpoch: "1", CollectorScopeID: "scope-1"}
	metadata := testAssignmentMetadata("selection-key-0001")

	first, err := service.Select(context.Background(), "batch-1", request, metadata)
	if err != nil {
		t.Fatalf("select: %v", err)
	}
	if first.Data.AssignmentStatus != model.AssignmentStatusAccepted || first.EventState != string(model.OutboxPublishStatePending) {
		t.Fatalf("unexpected selection result: %+v", first)
	}
	if repo.batch.Status != model.BatchStatusAssigned || repo.batch.Version != 2 || len(repo.audits) != 1 || len(repo.outbox) != 1 {
		t.Fatalf("selection did not commit aggregate evidence")
	}

	replay, err := service.Select(context.Background(), "batch-1", request, metadata)
	if err != nil {
		t.Fatalf("replay: %v", err)
	}
	if replay.Data.AssignmentID != first.Data.AssignmentID || len(repo.commands) != 1 || len(repo.outbox) != 1 {
		t.Fatalf("replay duplicated the command or event")
	}
}

func TestAssignmentRejectsForbiddenAndInvalidRequests(t *testing.T) {
	metadata := testAssignmentMetadata("forbidden-key-0001")
	metadata.Actor.RoleCode = "RECYCLER"
	if _, err := NewAssignmentWorkflowService(newFakeAssignmentRepository()).Select(context.Background(), "batch-1", dto.AssignmentSelectionRequest{ExpectedVersion: 1, ClaimEpoch: "1", CollectorScopeID: "scope-1"}, metadata); !errors.Is(err, ErrAssignmentForbidden) {
		t.Fatalf("expected forbidden collector scope, got %v", err)
	}
	if err := validateFailure(dto.FailedPickupRequest{FailureReason: "not-a-design-value"}); !errors.Is(err, ErrAssignmentValidation) {
		t.Fatalf("expected stable validation error, got %v", err)
	}
}

func TestAssignmentHandoffCompletesBatchAndEmitsEvent(t *testing.T) {
	repo := newFakeAssignmentRepository()
	service := NewAssignmentWorkflowService(repo)
	now := time.Date(2026, time.January, 1, 10, 0, 0, 0, time.UTC)
	service.clock = func() time.Time { return now }
	nextID := 0
	service.newID = func() string {
		nextID++
		return "generated-" + strconv.Itoa(nextID)
	}

	selection, err := service.Select(context.Background(), "batch-1", dto.AssignmentSelectionRequest{
		ExpectedVersion: 1, ClaimEpoch: "1", CollectorScopeID: "scope-1",
	}, testAssignmentMetadata("selection-key-0001"))
	if err != nil {
		t.Fatalf("select: %v", err)
	}

	handoff, err := service.Handoff(context.Background(), selection.Data.AssignmentID, dto.HandoffRequest{
		PickupOccurredAt: now, DonorRepresentativeName: "Donor representative",
		ActualItemCount: 1, VerificationHash: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
	}, BatchCommandMetadata{
		Actor:         BatchActor{UserID: "USR-001", OrganisationID: "COL-001", RoleCode: "COLLECTOR"},
		CorrelationID: "corr-handoff", IdempotencyKey: "handoff-key-0001", ExpectedVersion: 2,
	})
	if err != nil {
		t.Fatalf("handoff: %v", err)
	}
	if handoff.Data.AssignmentStatus != model.AssignmentStatusCompleted ||
		repo.batch.Status != model.BatchStatusCollected ||
		len(repo.handoffs) != 1 || len(repo.outbox) != 2 {
		t.Fatalf("handoff did not commit collection evidence")
	}
	if repo.outbox[1].EventType != model.CollectionCompletedEventType {
		t.Fatalf("expected collection completed event, got %s", repo.outbox[1].EventType)
	}
}

func TestHandoffValidationRequiresDesignBounds(t *testing.T) {
	future := time.Now().UTC().Add(time.Minute)
	if err := validateHandoff(dto.HandoffRequest{PickupOccurredAt: future, DonorRepresentativeName: "rep", ActualItemCount: 1, VerificationHash: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}, time.Now().UTC()); !errors.Is(err, ErrAssignmentValidation) {
		t.Fatalf("expected future handoff to be rejected, got %v", err)
	}
}
