package service

import (
	"context"
	"errors"
	"testing"

	"workflow-api/internal/model"
	"workflow-api/internal/storage"
)

type fakeEvidenceStorage struct {
	objects     map[string][]byte
	putCalls    int
	deleteCalls int
	getCalls    int
	putErr      error
	getErr      error
	deleteErr   error
}

func newFakeEvidenceStorage() *fakeEvidenceStorage {
	return &fakeEvidenceStorage{objects: make(map[string][]byte)}
}

func (s *fakeEvidenceStorage) Put(_ context.Context, key string, content []byte, _ string) error {
	s.putCalls++
	if s.putErr != nil {
		return s.putErr
	}
	s.objects[key] = append([]byte(nil), content...)
	return nil
}

func (s *fakeEvidenceStorage) Get(_ context.Context, key string) ([]byte, error) {
	s.getCalls++
	if s.getErr != nil {
		return nil, s.getErr
	}
	content, ok := s.objects[key]
	if !ok {
		return nil, storage.ErrEvidenceObjectNotFound
	}
	return append([]byte(nil), content...), nil
}

func (s *fakeEvidenceStorage) Delete(_ context.Context, key string) error {
	s.deleteCalls++
	if s.deleteErr != nil {
		return s.deleteErr
	}
	delete(s.objects, key)
	return nil
}

func TestEvidenceServiceUploadValidatesAndPersistsValidatedEvidence(t *testing.T) {
	repo := newFakeBatchRepository()
	repo.state.batches["batch-receipt-001"] = collectedReceiptBatch()
	objectStorage := newFakeEvidenceStorage()
	svc := NewEvidenceService(repo, objectStorage)
	svc.newID = func() string { return "evidence-001" }

	result, err := svc.Upload(context.Background(), "batch-receipt-001", EvidenceUploadRequest{
		Filename:       "receipt.pdf",
		LifecycleStage: model.EvidenceLifecycleReceipt,
		Content:        []byte("%PDF-1.7\nvalidated evidence"),
	}, recyclerMetadata("evidence-upload-001", "corr-evidence-001", 0))
	if err != nil {
		t.Fatalf("upload returned error: %v", err)
	}
	if result.Data.ValidationStatus != string(model.EvidenceValidationValidated) || result.Data.MIMEType != "application/pdf" {
		t.Fatalf("unexpected evidence response: %+v", result.Data)
	}
	if len(repo.state.evidence) != 1 || len(repo.state.audits) != 1 || len(repo.state.commands) != 1 {
		t.Fatalf("expected metadata, command, and audit: evidence=%d commands=%d audits=%d", len(repo.state.evidence), len(repo.state.commands), len(repo.state.audits))
	}
	if repo.state.audits[0].EventType != model.BatchAuditEventEvidenceUploaded {
		t.Fatalf("unexpected audit type: %s", repo.state.audits[0].EventType)
	}
	if objectStorage.putCalls != 1 || len(objectStorage.objects) != 1 {
		t.Fatalf("expected one stored object: puts=%d objects=%d", objectStorage.putCalls, len(objectStorage.objects))
	}
}

func TestEvidenceServiceUploadRejectsInvalidFileWithoutDurableEffects(t *testing.T) {
	repo := newFakeBatchRepository()
	repo.state.batches["batch-receipt-001"] = collectedReceiptBatch()
	objectStorage := newFakeEvidenceStorage()
	svc := NewEvidenceService(repo, objectStorage)

	_, err := svc.Upload(context.Background(), "batch-receipt-001", EvidenceUploadRequest{
		Filename:       "notes.txt",
		LifecycleStage: model.EvidenceLifecycleReceipt,
		Content:        []byte("not an accepted evidence file"),
	}, recyclerMetadata("evidence-upload-invalid", "corr-evidence-invalid", 0))
	if !errors.Is(err, ErrBatchValidation) {
		t.Fatalf("expected validation error, got %v", err)
	}
	if len(repo.state.evidence) != 0 || len(repo.state.commands) != 0 || len(repo.state.audits) != 0 || objectStorage.putCalls != 0 {
		t.Fatalf("invalid upload created durable effects: evidence=%d commands=%d audits=%d puts=%d", len(repo.state.evidence), len(repo.state.commands), len(repo.state.audits), objectStorage.putCalls)
	}
}

func TestEvidenceServiceUploadReplaysWithoutDuplicateObjectOrAudit(t *testing.T) {
	repo := newFakeBatchRepository()
	repo.state.batches["batch-receipt-001"] = collectedReceiptBatch()
	objectStorage := newFakeEvidenceStorage()
	svc := NewEvidenceService(repo, objectStorage)
	nextID := 0
	svc.newID = func() string {
		nextID++
		return "evidence-" + string(rune('0'+nextID))
	}
	request := EvidenceUploadRequest{Filename: "receipt.png", LifecycleStage: model.EvidenceLifecycleReceipt, Content: pngFixture()}
	metadata := recyclerMetadata("evidence-upload-replay", "corr-evidence-replay", 0)

	first, err := svc.Upload(context.Background(), "batch-receipt-001", request, metadata)
	if err != nil {
		t.Fatalf("first upload returned error: %v", err)
	}
	second, err := svc.Upload(context.Background(), "batch-receipt-001", request, metadata)
	if err != nil {
		t.Fatalf("replay returned error: %v", err)
	}
	if first.Data.EvidenceID != second.Data.EvidenceID || len(repo.state.evidence) != 1 || len(repo.state.audits) != 1 || objectStorage.putCalls != 1 {
		t.Fatalf("replay duplicated durable effects: first=%+v second=%+v evidence=%d audits=%d puts=%d", first.Data, second.Data, len(repo.state.evidence), len(repo.state.audits), objectStorage.putCalls)
	}
}

func TestEvidenceServiceUploadCleansObjectWhenMetadataTransactionRollsBack(t *testing.T) {
	repo := newFakeBatchRepository()
	repo.state.batches["batch-receipt-001"] = collectedReceiptBatch()
	repo.failAudit = true
	objectStorage := newFakeEvidenceStorage()
	svc := NewEvidenceService(repo, objectStorage)

	_, err := svc.Upload(context.Background(), "batch-receipt-001", EvidenceUploadRequest{
		Filename: "receipt.pdf", LifecycleStage: model.EvidenceLifecycleReceipt, Content: []byte("%PDF-1.7\ncontent"),
	}, recyclerMetadata("evidence-upload-storage-error", "corr-evidence-storage-error", 0))
	if err == nil {
		t.Fatal("expected audit failure")
	}
	if len(repo.state.evidence) != 0 || len(repo.state.commands) != 0 || objectStorage.deleteCalls != 1 || len(objectStorage.objects) != 0 {
		t.Fatalf("storage failure left effects: evidence=%d commands=%d deletes=%d", len(repo.state.evidence), len(repo.state.commands), objectStorage.deleteCalls)
	}
}

func TestEvidenceServiceDownloadAuthorizesOwnerAndAuditsAdmin(t *testing.T) {
	repo := newFakeBatchRepository()
	repo.state.batches["batch-receipt-001"] = collectedReceiptBatch()
	repo.state.evidence["evidence-001"] = &model.BatchEvidence{
		EvidenceID: "evidence-001", BatchID: "batch-receipt-001", OrganisationID: "facility-001", UploadedBy: "recycler-user-001",
		LifecycleStage: model.EvidenceLifecycleReceipt, OriginalFileName: "receipt.pdf", StoredObjectKey: "batches/batch-receipt-001/evidence/evidence-001",
		MIMEType: "application/pdf", FileSizeBytes: 16, ValidationStatus: model.EvidenceValidationValidated,
	}
	objectStorage := newFakeEvidenceStorage()
	objectStorage.objects["batches/batch-receipt-001/evidence/evidence-001"] = []byte("%PDF-1.7\ncontent")
	svc := NewEvidenceService(repo, objectStorage)

	owner, err := svc.Download(context.Background(), "batch-receipt-001", "evidence-001", EvidenceDownloadActor{BatchActor: recyclerMetadata("unused", "corr-download-owner", 0).Actor}, "corr-download-owner")
	if err != nil || string(owner.Content) != "%PDF-1.7\ncontent" {
		t.Fatalf("owner download failed: result=%+v err=%v", owner, err)
	}

	admin, err := svc.Download(context.Background(), "batch-receipt-001", "evidence-001", EvidenceDownloadActor{
		BatchActor:        BatchActor{UserID: "admin-001", OrganisationID: "platform-001", RoleCode: "SYSTEM_ADMIN"},
		AdminAccessReason: "incident review",
	}, "corr-download-admin")
	if err != nil || len(admin.Content) == 0 {
		t.Fatalf("admin download failed: result=%+v err=%v", admin, err)
	}
	if len(repo.state.audits) != 1 || repo.state.audits[0].EventType != model.BatchAuditEventEvidenceDownloaded {
		t.Fatalf("expected one admin download audit, got %+v", repo.state.audits)
	}
}

func TestEvidenceServiceDownloadRequiresAdminReasonAndRejectsOtherRoles(t *testing.T) {
	repo := newFakeBatchRepository()
	repo.state.batches["batch-receipt-001"] = collectedReceiptBatch()
	repo.state.evidence["evidence-001"] = &model.BatchEvidence{
		EvidenceID: "evidence-001", BatchID: "batch-receipt-001", OrganisationID: "facility-001", ValidationStatus: model.EvidenceValidationValidated,
		StoredObjectKey: "batches/batch-receipt-001/evidence/evidence-001", OriginalFileName: "receipt.pdf", MIMEType: "application/pdf",
	}
	objectStorage := newFakeEvidenceStorage()
	objectStorage.objects["batches/batch-receipt-001/evidence/evidence-001"] = []byte("%PDF-1.7\ncontent")
	svc := NewEvidenceService(repo, objectStorage)

	_, err := svc.Download(context.Background(), "batch-receipt-001", "evidence-001", EvidenceDownloadActor{
		BatchActor: BatchActor{UserID: "admin-001", OrganisationID: "platform-001", RoleCode: "SYSTEM_ADMIN"},
	}, "corr-admin-no-reason")
	if !errors.Is(err, ErrBatchValidation) {
		t.Fatalf("expected missing admin reason validation error, got %v", err)
	}

	_, err = svc.Download(context.Background(), "batch-receipt-001", "evidence-001", EvidenceDownloadActor{
		BatchActor: BatchActor{UserID: "donor-001", OrganisationID: "org-001", RoleCode: "DONOR"},
	}, "corr-donor-download")
	if !errors.Is(err, ErrBatchForbidden) {
		t.Fatalf("expected donor forbidden error, got %v", err)
	}
}

func pngFixture() []byte {
	return []byte{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a, 0x00}
}
