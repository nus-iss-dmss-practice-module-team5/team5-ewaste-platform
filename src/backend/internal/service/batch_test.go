package service

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"workflow-api/internal/dto"
	"workflow-api/internal/model"
	"workflow-api/internal/repository"
)

type fakeBatchRepository struct {
	state        *fakeBatchState
	transactionN int
}

type fakeBatchState struct {
	batches  map[string]*model.Batch
	commands []*model.CommandIdempotency
	audits   []*model.BatchAuditEvent
	outbox   []*model.EventOutbox
}

type fakeBatchTransaction struct {
	state *fakeBatchState
}

func newFakeBatchRepository() *fakeBatchRepository {
	return &fakeBatchRepository{
		state: &fakeBatchState{
			batches: make(map[string]*model.Batch),
		},
	}
}

func (r *fakeBatchRepository) Transaction(
	_ context.Context,
	fn func(repository.BatchTransaction) error,
) error {
	r.transactionN++

	if fn == nil {
		return errors.New("callback is nil")
	}

	return fn(&fakeBatchTransaction{state: r.state})
}

func (t *fakeBatchTransaction) FindBatchForUpdate(
	_ context.Context,
	batchID string,
) (*model.Batch, error) {
	batch, ok := t.state.batches[batchID]
	if !ok {
		return nil, repository.ErrBatchNotFound
	}

	return cloneBatch(batch), nil
}

func (t *fakeBatchTransaction) FindCommand(
	_ context.Context,
	actorScope string,
	commandName string,
	idempotencyKey string,
) (*model.CommandIdempotency, error) {
	for _, command := range t.state.commands {
		if command.ActorScope == actorScope &&
			command.CommandName == commandName &&
			command.IdempotencyKey == idempotencyKey {
			return cloneCommand(command), nil
		}
	}

	return nil, repository.ErrCommandNotFound
}

func (t *fakeBatchTransaction) CreateBatch(
	_ context.Context,
	batch *model.Batch,
) error {
	t.state.batches[batch.ID] = cloneBatch(batch)
	return nil
}

func (t *fakeBatchTransaction) CreateCommand(
	_ context.Context,
	command *model.CommandIdempotency,
) error {
	t.state.commands = append(t.state.commands, cloneCommand(command))
	return nil
}

func (t *fakeBatchTransaction) UpdateDraft(
	_ context.Context,
	batchID string,
	organizationID string,
	createdBy string,
	expectedVersion uint32,
	changes map[string]any,
) (*model.Batch, error) {
	batch, ok := t.state.batches[batchID]
	if !ok {
		return nil, repository.ErrBatchNotFound
	}

	if batch.OrganizationID != organizationID ||
		batch.CreatedBy != createdBy ||
		batch.Status != model.BatchStatusDraft ||
		batch.Version != expectedVersion {
		return nil, repository.ErrBatchConcurrency
	}

	applyFakeChanges(batch, changes)
	batch.Version++
	batch.UpdatedAt = time.Now().UTC()

	return cloneBatch(batch), nil
}

func (t *fakeBatchTransaction) SubmitDraft(
	_ context.Context,
	batchID string,
	organizationID string,
	createdBy string,
	expectedVersion uint32,
	submittedAt time.Time,
) (*model.Batch, error) {
	batch, ok := t.state.batches[batchID]
	if !ok {
		return nil, repository.ErrBatchNotFound
	}

	if batch.OrganizationID != organizationID ||
		batch.CreatedBy != createdBy ||
		batch.Status != model.BatchStatusDraft ||
		batch.Version != expectedVersion {
		return nil, repository.ErrBatchConcurrency
	}

	batch.Status = model.BatchStatusSubmitted
	batch.SubmittedAt = &submittedAt
	batch.Version++
	batch.UpdatedAt = submittedAt

	return cloneBatch(batch), nil
}

func (t *fakeBatchTransaction) CompleteCommand(
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
			command.ResponseJSON = append([]byte(nil), responseJSON...)
			command.CompletedAt = &completedAt
			return nil
		}
	}

	return repository.ErrCommandConcurrency
}

func (t *fakeBatchTransaction) AppendAudit(
	_ context.Context,
	event *model.BatchAuditEvent,
) error {
	t.state.audits = append(t.state.audits, event)
	return nil
}

func (t *fakeBatchTransaction) EnqueueOutbox(
	_ context.Context,
	event *model.EventOutbox,
) error {
	t.state.outbox = append(t.state.outbox, event)
	return nil
}

func cloneBatch(source *model.Batch) *model.Batch {
	if source == nil {
		return nil
	}

	copy := *source
	return &copy
}

func cloneCommand(source *model.CommandIdempotency) *model.CommandIdempotency {
	if source == nil {
		return nil
	}

	copy := *source
	copy.ResponseJSON = append([]byte(nil), source.ResponseJSON...)
	return &copy
}

func applyFakeChanges(batch *model.Batch, changes map[string]any) {
	for field, value := range changes {
		switch field {
		case "category":
			normalized := value.(string)
			batch.Category = &normalized

		case "quantity":
			quantity := value.(int)
			batch.Quantity = &quantity

		case "estimated_weight_kg":
			weight := value.(string)
			batch.EstimatedWeightKg = &weight

		case "condition_rating":
			condition := value.(string)
			batch.ConditionRating = &condition

		case "is_data_bearing":
			batch.IsDataBearing = value.(bool)

		case "zone":
			zone := value.(string)
			batch.Zone = &zone

		case "collection_deadline":
			deadline := value.(time.Time)
			batch.CollectionDeadline = &deadline

		case "notes":
			notes := value.(string)
			batch.Notes = &notes
		}
	}
}

func testBatchService() (*BatchService, *fakeBatchRepository, time.Time) {
	now := time.Date(2026, 9, 22, 10, 0, 0, 0, time.UTC)

	repo := newFakeBatchRepository()
	service := NewBatchService(repo)
	service.clock = func() time.Time {
		return now
	}

	return service, repo, now
}

func testDonorMetadata(
	idempotencyKey string,
	correlationID string,
) BatchCommandMetadata {
	return BatchCommandMetadata{
		Actor: BatchActor{
			UserID:         "donor-001",
			OrganisationID: "org-001",
			RoleCode:       "DONOR",
		},
		IdempotencyKey: idempotencyKey,
		CorrelationID:  correlationID,
	}
}

func testDraftRequest(now time.Time) dto.BatchDraftRequest {
	category := "ICT_EQUIPMENT"
	quantity := 3
	weight := 2.50
	condition := "FUNCTIONAL"
	dataBearing := false
	zone := "CENTRAL"
	deadline := now.Add(72 * time.Hour)
	notes := "working test batch"

	return dto.BatchDraftRequest{
		Category:           &category,
		Quantity:           &quantity,
		EstimatedWeightKg:  &weight,
		ConditionRating:    &condition,
		IsDataBearing:      &dataBearing,
		Zone:               &zone,
		CollectionDeadline: &deadline,
		Notes:              &notes,
	}
}

func TestBatchServiceCreateDraftPersistsCommandAndAudit(t *testing.T) {
	service, repo, now := testBatchService()

	result, err := service.CreateDraft(
		context.Background(),
		testDraftRequest(now),
		testDonorMetadata("create-001", "corr-create-001"),
	)
	if err != nil {
		t.Fatalf("create draft returned error: %v", err)
	}

	if result.Batch.Status != string(model.BatchStatusDraft) {
		t.Fatalf("expected DRAFT status, got %s", result.Batch.Status)
	}

	if result.Batch.Version != 1 {
		t.Fatalf("expected version 1, got %d", result.Batch.Version)
	}

	if len(repo.state.batches) != 1 {
		t.Fatalf("expected one batch, got %d", len(repo.state.batches))
	}

	if len(repo.state.commands) != 1 {
		t.Fatalf("expected one command, got %d", len(repo.state.commands))
	}

	if repo.state.commands[0].State != model.CommandStateCompleted {
		t.Fatalf("expected completed command, got %s", repo.state.commands[0].State)
	}

	if len(repo.state.audits) != 1 {
		t.Fatalf("expected one audit event, got %d", len(repo.state.audits))
	}

	audit := repo.state.audits[0]

	if audit.EventType != model.BatchAuditEventDraftSaved {
		t.Fatalf("unexpected audit event type: %s", audit.EventType)
	}

	if audit.CorrelationID != "corr-create-001" {
		t.Fatalf("unexpected correlation ID: %s", audit.CorrelationID)
	}

	if audit.ActorUserID == nil || *audit.ActorUserID != "donor-001" {
		t.Fatalf("audit actor was not persisted")
	}

	if repo.transactionN != 1 {
		t.Fatalf("expected one transaction, got %d", repo.transactionN)
	}
}

func TestBatchServiceSubmitPersistsAuditAndOutbox(t *testing.T) {
	service, repo, now := testBatchService()

	created, err := service.CreateDraft(
		context.Background(),
		testDraftRequest(now),
		testDonorMetadata("create-002", "corr-create-002"),
	)
	if err != nil {
		t.Fatalf("create draft returned error: %v", err)
	}

	metadata := testDonorMetadata("submit-002", "corr-submit-002")
	metadata.ExpectedVersion = created.Batch.Version

	result, err := service.Submit(
		context.Background(),
		created.Batch.BatchID,
		metadata,
	)
	if err != nil {
		t.Fatalf("submit returned error: %v", err)
	}

	if result.Batch.Status != string(model.BatchStatusSubmitted) {
		t.Fatalf("expected SUBMITTED status, got %s", result.Batch.Status)
	}

	if result.Batch.Version != 2 {
		t.Fatalf("expected version 2, got %d", result.Batch.Version)
	}

	if result.EventState != string(model.OutboxPublishStatePending) {
		t.Fatalf("expected pending event state, got %s", result.EventState)
	}

	if len(repo.state.audits) != 2 {
		t.Fatalf("expected create and submit audits, got %d", len(repo.state.audits))
	}

	submitAudit := repo.state.audits[1]

	if submitAudit.EventType != model.BatchAuditEventRequestSubmitted {
		t.Fatalf("unexpected submit audit type: %s", submitAudit.EventType)
	}

	if submitAudit.FromStatus != model.BatchStatusDraft ||
		submitAudit.ToStatus != model.BatchStatusSubmitted {
		t.Fatalf("unexpected lifecycle transition: %s -> %s",
			submitAudit.FromStatus,
			submitAudit.ToStatus,
		)
	}

	if submitAudit.CorrelationID != "corr-submit-002" {
		t.Fatalf("unexpected submit correlation ID: %s", submitAudit.CorrelationID)
	}

	if len(repo.state.outbox) != 1 {
		t.Fatalf("expected one outbox event, got %d", len(repo.state.outbox))
	}

	outbox := repo.state.outbox[0]

	if outbox.EventType != model.RequestSubmittedEventType {
		t.Fatalf("unexpected outbox event type: %s", outbox.EventType)
	}

	if outbox.BatchID != created.Batch.BatchID {
		t.Fatalf("unexpected outbox batch ID: %s", outbox.BatchID)
	}

	if outbox.CorrelationID != "corr-submit-002" {
		t.Fatalf("unexpected outbox correlation ID: %s", outbox.CorrelationID)
	}

	if !json.Valid(outbox.PayloadJSON) {
		t.Fatalf("outbox payload is not valid JSON")
	}
}

func TestBatchServiceRejectsIncompleteSubmit(t *testing.T) {
	service, repo, _ := testBatchService()

	created, err := service.CreateDraft(
		context.Background(),
		dto.BatchDraftRequest{},
		testDonorMetadata("create-incomplete", "corr-incomplete"),
	)
	if err != nil {
		t.Fatalf("incomplete draft creation returned error: %v", err)
	}

	metadata := testDonorMetadata("submit-incomplete", "corr-submit-incomplete")
	metadata.ExpectedVersion = created.Batch.Version

	_, err = service.Submit(
		context.Background(),
		created.Batch.BatchID,
		metadata,
	)

	if !errors.Is(err, ErrBatchValidation) {
		t.Fatalf("expected validation error, got %v", err)
	}

	if len(repo.state.outbox) != 0 {
		t.Fatalf("invalid submit must not enqueue an outbox event")
	}

	if len(repo.state.commands) != 1 {
		t.Fatalf("invalid submit must not create a submit command")
	}
}

func TestBatchServiceRejectsForbiddenActor(t *testing.T) {
	service, repo, now := testBatchService()

	metadata := testDonorMetadata("forbidden-001", "corr-forbidden")
	metadata.Actor.RoleCode = "COLLECTOR"

	_, err := service.CreateDraft(
		context.Background(),
		testDraftRequest(now),
		metadata,
	)

	if !errors.Is(err, ErrBatchForbidden) {
		t.Fatalf("expected forbidden error, got %v", err)
	}

	if repo.transactionN != 0 {
		t.Fatalf("forbidden request must not start a transaction")
	}
}

func TestBatchServiceReplaysIdempotentCreateAndRejectsHashMismatch(t *testing.T) {
	service, repo, now := testBatchService()
	request := testDraftRequest(now)
	metadata := testDonorMetadata("replay-001", "corr-replay-001")

	first, err := service.CreateDraft(
		context.Background(),
		request,
		metadata,
	)
	if err != nil {
		t.Fatalf("first create returned error: %v", err)
	}

	second, err := service.CreateDraft(
		context.Background(),
		request,
		metadata,
	)
	if err != nil {
		t.Fatalf("replayed create returned error: %v", err)
	}

	if second.Batch.BatchID != first.Batch.BatchID {
		t.Fatalf("replay returned a different batch ID")
	}

	if len(repo.state.batches) != 1 {
		t.Fatalf("replay must not create another batch")
	}

	if len(repo.state.commands) != 1 {
		t.Fatalf("replay must not create another command")
	}

	changedRequest := request
	changedNotes := "changed payload"
	changedRequest.Notes = &changedNotes

	_, err = service.CreateDraft(
		context.Background(),
		changedRequest,
		metadata,
	)

	if !errors.Is(err, ErrBatchIdempotencyConflict) {
		t.Fatalf("expected idempotency conflict, got %v", err)
	}

	if len(repo.state.batches) != 1 {
		t.Fatalf("conflicting replay must not create another batch")
	}

	if len(repo.state.commands) != 1 {
		t.Fatalf("conflicting replay must not create another command")
	}
}

func TestBatchServiceEnforcesVersionAndLifecycleGuards(t *testing.T) {
	service, repo, now := testBatchService()

	created, err := service.CreateDraft(
		context.Background(),
		testDraftRequest(now),
		testDonorMetadata("create-lifecycle", "corr-lifecycle-create"),
	)
	if err != nil {
		t.Fatalf("create draft returned error: %v", err)
	}

	staleMetadata := testDonorMetadata("edit-stale", "corr-edit-stale")
	staleMetadata.ExpectedVersion = 2

	_, err = service.EditDraft(
		context.Background(),
		created.Batch.BatchID,
		testDraftRequest(now),
		staleMetadata,
	)

	if !errors.Is(err, ErrBatchStaleVersion) {
		t.Fatalf("expected stale version error, got %v", err)
	}

	submitMetadata := testDonorMetadata("submit-lifecycle", "corr-lifecycle-submit")
	submitMetadata.ExpectedVersion = created.Batch.Version

	submitted, err := service.Submit(
		context.Background(),
		created.Batch.BatchID,
		submitMetadata,
	)
	if err != nil {
		t.Fatalf("submit returned error: %v", err)
	}

	editSubmittedMetadata := testDonorMetadata(
		"edit-submitted",
		"corr-edit-submitted",
	)
	editSubmittedMetadata.ExpectedVersion = submitted.Batch.Version

	_, err = service.EditDraft(
		context.Background(),
		submitted.Batch.BatchID,
		testDraftRequest(now),
		editSubmittedMetadata,
	)

	if !errors.Is(err, ErrBatchInvalidState) {
		t.Fatalf("expected invalid state error, got %v", err)
	}

	if len(repo.state.batches) != 1 {
		t.Fatalf("expected one batch, got %d", len(repo.state.batches))
	}
}
