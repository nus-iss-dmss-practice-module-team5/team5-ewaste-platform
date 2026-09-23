package service

import (
	"context"
	"errors"
	"testing"
	"time"

	"workflow-api/internal/dto"
	"workflow-api/internal/lease"
	"workflow-api/internal/model"
	"workflow-api/internal/repository"
)

type fakeClaimState struct {
	batch        *model.Batch
	match        *model.ClaimMatch
	pool         *model.CapacityPool
	commands     []*model.CommandIdempotency
	claims       []*model.BatchClaim
	reservations []*model.CapacityReservation
	audits       []*model.BatchAuditEvent
	outbox       []*model.EventOutbox
}

type fakeClaimRepository struct {
	state fakeClaimState
}

func (r *fakeClaimRepository) Transaction(
	ctx context.Context,
	fn func(repository.ClaimTransaction) error,
) error {
	return fn(&fakeClaimTransaction{state: &r.state})
}

type fakeClaimTransaction struct {
	state *fakeClaimState
}

func (t *fakeClaimTransaction) FindCommand(
	_ context.Context,
	actorScope string,
	commandName string,
	idempotencyKey string,
) (*model.CommandIdempotency, error) {
	for _, command := range t.state.commands {
		if command.ActorScope == actorScope &&
			command.CommandName == commandName &&
			command.IdempotencyKey == idempotencyKey {
			return command, nil
		}
	}
	return nil, repository.ErrClaimCommandNotFound
}

func (t *fakeClaimTransaction) CreateCommand(
	_ context.Context,
	command *model.CommandIdempotency,
) error {
	t.state.commands = append(t.state.commands, command)
	return nil
}

func (t *fakeClaimTransaction) FindBatchForUpdate(
	_ context.Context,
	_ string,
) (*model.Batch, error) {
	if t.state.batch == nil {
		return nil, repository.ErrClaimBatchNotFound
	}
	return t.state.batch, nil
}

func (t *fakeClaimTransaction) FindEligibleMatch(
	_ context.Context,
	_ *model.Batch,
	_ string,
) (*model.ClaimMatch, error) {
	if t.state.match == nil {
		return nil, repository.ErrClaimOpportunityNotFound
	}
	return t.state.match, nil
}

func (t *fakeClaimTransaction) LockCapacityPoolForUpdate(
	_ context.Context,
	_ string,
	_ string,
) (*model.CapacityPool, error) {
	if t.state.pool == nil {
		return nil, repository.ErrClaimPoolNotFound
	}
	return t.state.pool, nil
}

func (t *fakeClaimTransaction) ReserveCapacity(
	_ context.Context,
	_ string,
	_ string,
	_ string,
	_ time.Time,
) error {
	t.state.pool.ReservedKg = "100.00"
	t.state.pool.Version++
	return nil
}

func (t *fakeClaimTransaction) CreateClaim(
	_ context.Context,
	claim *model.BatchClaim,
) error {
	t.state.claims = append(t.state.claims, claim)
	return nil
}

func (t *fakeClaimTransaction) CreateReservation(
	_ context.Context,
	reservation *model.CapacityReservation,
) error {
	t.state.reservations = append(t.state.reservations, reservation)
	return nil
}

func (t *fakeClaimTransaction) ApproveBatch(
	_ context.Context,
	_ string,
	_ uint64,
	_ uint32,
	claimID string,
	_ time.Time,
) (*model.Batch, error) {
	t.state.batch.Status = model.BatchStatusApproved
	t.state.batch.CurrentClaimID = &claimID
	t.state.batch.Version++
	return t.state.batch, nil
}

func (t *fakeClaimTransaction) CompleteCommand(
	_ context.Context,
	commandID string,
	responseStatus int,
	responseJSON []byte,
	completedAt time.Time,
) error {
	for _, command := range t.state.commands {
		if command.ID == commandID {
			command.State = model.CommandStateCompleted
			command.ResponseStatus = &responseStatus
			command.ResponseJSON = responseJSON
			command.CompletedAt = &completedAt
			return nil
		}
	}
	return errors.New("test command not found")
}

func (t *fakeClaimTransaction) AppendAudit(
	_ context.Context,
	event *model.BatchAuditEvent,
) error {
	t.state.audits = append(t.state.audits, event)
	return nil
}

func (t *fakeClaimTransaction) EnqueueOutbox(
	_ context.Context,
	event *model.EventOutbox,
) error {
	t.state.outbox = append(t.state.outbox, event)
	return nil
}

type fakeLease struct{}

func (fakeLease) Acquire(context.Context, string) (lease.Handle, error) {
	return fakeLeaseHandle{}, nil
}

type fakeLeaseHandle struct{}

func (fakeLeaseHandle) Release(context.Context) error { return nil }

func newClaimServiceFixture() (
	*ClaimWorkflowService,
	*fakeClaimRepository,
	dto.ClaimRequest,
	BatchCommandMetadata,
) {
	now := time.Date(2026, 9, 23, 12, 0, 0, 0, time.UTC)
	weight := "100.00"
	deadline := now.Add(48 * time.Hour)

	repo := &fakeClaimRepository{state: fakeClaimState{
		batch: &model.Batch{
			ID:                 "batch-001",
			Status:             model.BatchStatusMatched,
			ClaimEpoch:         1,
			Version:            3,
			EstimatedWeightKg:  &weight,
			CollectionDeadline: &deadline,
			UpdatedAt:          now,
		},
		match: &model.ClaimMatch{
			DecisionID:           "decision-001",
			MatchedResultID:      "result-001",
			CapacityPoolID:       "pool-001",
			RecyclerOrgID:        "PROC-001",
			ClaimEpoch:           1,
			DecisionBatchVersion: 2,
		},
		pool: &model.CapacityPool{
			ID:            "pool-001",
			RecyclerOrgID: "PROC-001",
			TotalKg:       "1000.00",
			ReservedKg:    "0.00",
			IsActive:      true,
			Version:       7,
		},
	}}

	service := NewClaimWorkflowService(repo, fakeLease{})
	service.clock = func() time.Time { return now }
	ids := []string{"claim-001", "reservation-001", "event-001"}
	service.newID = func() string {
		id := ids[0]
		ids = ids[1:]
		return id
	}

	return service, repo, dto.ClaimRequest{
			ExpectedVersion: 3,
			ClaimEpoch:      "1",
		}, BatchCommandMetadata{
			Actor: BatchActor{
				UserID:         "USR-007",
				OrganisationID: "PROC-001",
				RoleCode:       "RECYCLER",
			},
			CorrelationID:   "corr-claim-001",
			IdempotencyKey:  "claim-key-000001",
			ExpectedVersion: 3,
		}
}

func TestClaimSuccessCreatesAtomicEvidence(t *testing.T) {
	service, repo, request, metadata := newClaimServiceFixture()

	result, err := service.Claim(
		context.Background(),
		"batch-001",
		request,
		metadata,
	)
	if err != nil {
		t.Fatalf("claim failed: %v", err)
	}
	if result.Status != string(model.BatchStatusApproved) || result.Version != 4 {
		t.Fatalf("unexpected claim result: %+v", result)
	}
	if len(repo.state.claims) != 1 || len(repo.state.reservations) != 1 {
		t.Fatalf("expected one claim and reservation")
	}
	if len(repo.state.audits) != 1 || repo.state.audits[0].EventType != model.BatchAuditEventClaimConfirmed {
		t.Fatalf("claim audit evidence missing")
	}
	if len(repo.state.outbox) != 1 || repo.state.outbox[0].EventType != model.ClaimConfirmedEventType {
		t.Fatalf("claim outbox evidence missing")
	}
}

func TestClaimReplayReturnsOriginalResponseWithoutNewWrites(t *testing.T) {
	service, repo, request, metadata := newClaimServiceFixture()

	first, err := service.Claim(context.Background(), "batch-001", request, metadata)
	if err != nil {
		t.Fatalf("first claim failed: %v", err)
	}
	second, err := service.Claim(context.Background(), "batch-001", request, metadata)
	if err != nil {
		t.Fatalf("replay failed: %v", err)
	}
	if first != second {
		t.Fatalf("replay changed the original response")
	}
	if len(repo.state.claims) != 1 || len(repo.state.reservations) != 1 ||
		len(repo.state.audits) != 1 || len(repo.state.outbox) != 1 {
		t.Fatalf("replay created additional domain evidence")
	}
}

func TestClaimChangedPayloadReturnsIdempotencyConflict(t *testing.T) {
	service, _, request, metadata := newClaimServiceFixture()

	if _, err := service.Claim(context.Background(), "batch-001", request, metadata); err != nil {
		t.Fatalf("first claim failed: %v", err)
	}
	notes := "different payload"
	request.Notes = &notes
	_, err := service.Claim(context.Background(), "batch-001", request, metadata)
	if !errors.Is(err, ErrClaimIdempotencyConflict) {
		t.Fatalf("expected idempotency conflict, got %v", err)
	}
}

func TestClaimRejectsForbiddenRoleBeforeTransaction(t *testing.T) {
	service, repo, request, metadata := newClaimServiceFixture()
	metadata.Actor.RoleCode = "DONOR"

	_, err := service.Claim(context.Background(), "batch-001", request, metadata)
	if !errors.Is(err, ErrClaimForbidden) {
		t.Fatalf("expected forbidden error, got %v", err)
	}
	if len(repo.state.commands) != 0 {
		t.Fatalf("forbidden claim created a command")
	}
}
