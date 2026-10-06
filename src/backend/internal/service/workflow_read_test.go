package service

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"workflow-api/internal/model"
	"workflow-api/internal/repository"
)

func TestBatchToDTOExposesClaimEpochOnlyAfterClaim(t *testing.T) {
	batch := model.Batch{ID: "batch-1", Status: model.BatchStatusApproved, Version: 4, ClaimEpoch: 7}
	view := batchToDTO(&batch)
	if view.ClaimEpoch != "" {
		t.Fatalf("unclaimed batch exposed claim epoch %q", view.ClaimEpoch)
	}

	batch.CurrentClaimID = new("claim-1")
	view = batchToDTO(&batch)
	if view.ClaimEpoch != "7" {
		t.Fatalf("claimed batch claim epoch = %q, want 7", view.ClaimEpoch)
	}
}

func TestBatchToDTOExposesCollectorScopeID(t *testing.T) {
	scopeID := "scope-1"
	batch := model.Batch{
		ID:               "batch-1",
		Status:           model.BatchStatusApproved,
		Version:          4,
		CollectorScopeID: &scopeID,
	}

	view := batchToDTO(&batch)
	if view.CollectorScopeID != scopeID {
		t.Fatalf("collector scope id = %q, want %q", view.CollectorScopeID, scopeID)
	}
}

func TestOpportunityToDTOExposesClaimVersionAndEpoch(t *testing.T) {
	opportunity := model.WorkflowOpportunity{
		BatchID:    "batch-1",
		Status:     model.BatchStatusMatched,
		Version:    3,
		ClaimEpoch: 2,
	}

	view := opportunityToDTO(&opportunity)
	if view.Version != 3 {
		t.Fatalf("opportunity version = %d, want 3", view.Version)
	}
	if view.ClaimEpoch != "2" {
		t.Fatalf("opportunity claim epoch = %q, want 2", view.ClaimEpoch)
	}
}

type timelineRepositoryStub struct {
	repository.WorkflowReadRepository
	entries []model.BatchTimelineEntry
	total   int64
	err     error
	calls   int
	batchID string
	page    repository.WorkflowReadPage
}

func (s *timelineRepositoryStub) ListBatchTimeline(_ context.Context, batchID string, page repository.WorkflowReadPage) ([]model.BatchTimelineEntry, int64, error) {
	s.calls++
	s.batchID = batchID
	s.page = page
	return s.entries, s.total, s.err
}

var auditor = WorkflowReadActor{UserID: "USR-002", OrganisationID: "PLATFORM", RoleCode: "AUDITOR"}

func TestListBatchTimelineIsAuditorOnly(t *testing.T) {
	for _, role := range []string{"DONOR", "COLLECTOR", "RECYCLER", "SYSTEM_ADMIN", ""} {
		repo := &timelineRepositoryStub{}
		_, err := NewWorkflowReadService(repo).ListBatchTimeline(
			context.Background(), "batch-1",
			WorkflowReadActor{UserID: "USR-9", OrganisationID: "ORG-9", RoleCode: role},
			WorkflowReadPage{Page: 1, PageSize: 100},
		)
		if !errors.Is(err, ErrWorkflowReadForbidden) {
			t.Fatalf("role %q: error = %v, want forbidden", role, err)
		}
		if repo.calls != 0 {
			t.Fatalf("role %q reached the repository", role)
		}
	}
}

func TestListBatchTimelineMapsMissingBatchToNotFound(t *testing.T) {
	repo := &timelineRepositoryStub{err: repository.ErrWorkflowReadNotFound}
	_, err := NewWorkflowReadService(repo).ListBatchTimeline(context.Background(), "missing", auditor, WorkflowReadPage{Page: 1, PageSize: 100})
	if !errors.Is(err, ErrWorkflowReadNotFound) {
		t.Fatalf("error = %v, want not found", err)
	}
}

func TestListBatchTimelineRejectsInvalidInput(t *testing.T) {
	service := NewWorkflowReadService(&timelineRepositoryStub{})
	for name, call := range map[string]func() error{
		"blank batch id": func() error {
			_, err := service.ListBatchTimeline(context.Background(), "  ", auditor, WorkflowReadPage{Page: 1, PageSize: 100})
			return err
		},
		"page size above 100": func() error {
			_, err := service.ListBatchTimeline(context.Background(), "batch-1", auditor, WorkflowReadPage{Page: 1, PageSize: 101})
			return err
		},
		"page zero": func() error {
			_, err := service.ListBatchTimeline(context.Background(), "batch-1", auditor, WorkflowReadPage{Page: 0, PageSize: 100})
			return err
		},
	} {
		if err := call(); !errors.Is(err, ErrWorkflowReadInvalid) {
			t.Fatalf("%s: error = %v, want invalid", name, err)
		}
	}
}

func TestListBatchTimelineKeepsRepositoryOrderAndPage(t *testing.T) {
	repo := &timelineRepositoryStub{
		total: 5,
		entries: []model.BatchTimelineEntry{
			{ID: "evt-1", EventType: model.BatchAuditEventRequestSubmitted, FromStatus: model.BatchStatusDraft, ToStatus: model.BatchStatusSubmitted},
			{ID: "evt-2", EventType: model.BatchAuditEventClaimConfirmed, FromStatus: model.BatchStatusMatched, ToStatus: model.BatchStatusApproved},
		},
	}
	result, err := NewWorkflowReadService(repo).ListBatchTimeline(context.Background(), "batch-1", auditor, WorkflowReadPage{Page: 2, PageSize: 2})
	if err != nil {
		t.Fatalf("list timeline: %v", err)
	}
	if repo.batchID != "batch-1" || repo.page != (repository.WorkflowReadPage{Page: 2, PageSize: 2}) {
		t.Fatalf("repository called with %q %+v", repo.batchID, repo.page)
	}
	if result.Page != 2 || result.PageSize != 2 || result.TotalCount != 5 {
		t.Fatalf("page = %d/%d total %d", result.Page, result.PageSize, result.TotalCount)
	}
	if len(result.Data) != 2 || result.Data[0].EventID != "evt-1" || result.Data[1].EventID != "evt-2" {
		t.Fatalf("entries reordered: %+v", result.Data)
	}
}

func TestTimelineEntryExposesOnlyResultAndEvidenceFromDetails(t *testing.T) {
	singapore := time.FixedZone("SGT", 8*60*60)
	entry := model.BatchTimelineEntry{
		ID:               "evt-1",
		ActorUserID:      new("USR-020"),
		ActorName:        new("EcoCycle Processing Facility"),
		OrganisationID:   new("PROC-001"),
		OrganisationName: new("EcoCycle"),
		EventType:        "RecyclingCompleted",
		FromStatus:       model.BatchStatus("VERIFIED"),
		ToStatus:         model.BatchStatus("RECYCLED"),
		BatchVersion:     9,
		OccurredAt:       time.Date(2026, 10, 7, 9, 30, 0, 123456000, singapore),
		CorrelationID:    "corr-1",
		DetailsJSON:      []byte(`{"evidence_id":"evidence-1","verification_hash":"donor-proof","stored_object_key":"private/key"}`),
	}

	view := timelineEntryToDTO(&entry)
	if view.Result != "RECYCLED" {
		t.Fatalf("result = %q, want the to-status when details carry none", view.Result)
	}
	if view.EvidenceID != "evidence-1" || view.Action != "RecyclingCompleted" || view.BatchVersion != 9 {
		t.Fatalf("unexpected view: %+v", view)
	}
	if view.ActorUserID != "USR-020" || view.ActorName != "EcoCycle Processing Facility" || view.OrganisationID != "PROC-001" || view.OrganisationName != "EcoCycle" || view.ServicePrincipal != "" {
		t.Fatalf("unexpected actor: %+v", view)
	}
	if !view.OccurredAt.Equal(entry.OccurredAt) || view.OccurredAt.Location() != time.UTC {
		t.Fatalf("occurred_at = %v, want the same instant in UTC", view.OccurredAt)
	}
	encoded, err := json.Marshal(view)
	if err != nil {
		t.Fatalf("marshal view: %v", err)
	}
	for _, secret := range []string{"donor-proof", "private/key", "verification_hash", "stored_object_key"} {
		if strings.Contains(string(encoded), secret) {
			t.Fatalf("timeline leaked %q: %s", secret, encoded)
		}
	}
}

func TestTimelineEntryUsesRecordedResultAndServicePrincipal(t *testing.T) {
	entry := model.BatchTimelineEntry{
		ID:               "evt-2",
		ServicePrincipal: new("assignment-recovery"),
		EventType:        model.BatchAuditEventCollectionRecoveryApproved,
		FromStatus:       model.BatchStatusFailedCollection,
		ToStatus:         model.BatchStatusApproved,
		DetailsJSON:      []byte(`{"result":"APPROVED_FOR_REASSIGNMENT"}`),
	}

	view := timelineEntryToDTO(&entry)
	if view.Result != "APPROVED_FOR_REASSIGNMENT" || view.ServicePrincipal != "assignment-recovery" {
		t.Fatalf("unexpected view: %+v", view)
	}
	if view.ActorUserID != "" || view.OrganisationID != "" || view.EvidenceID != "" {
		t.Fatalf("service entry carried a person or evidence: %+v", view)
	}
}

func TestTimelineEntryToleratesMalformedDetails(t *testing.T) {
	entry := model.BatchTimelineEntry{ID: "evt-3", ToStatus: model.BatchStatusSubmitted, DetailsJSON: []byte(`not json`)}
	if view := timelineEntryToDTO(&entry); view.Result != "SUBMITTED" || view.EvidenceID != "" {
		t.Fatalf("unexpected view: %+v", view)
	}
}
