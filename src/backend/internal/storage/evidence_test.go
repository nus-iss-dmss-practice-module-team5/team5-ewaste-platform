package storage

import (
	"context"
	"errors"
	"testing"

	"workflow-api/internal/config"
)

func TestNewEvidenceStorageDisabledFailsClosed(t *testing.T) {
	adapter, err := NewEvidenceStorage(config.StorageConfig{AdapterType: "disabled"})
	if err != nil {
		t.Fatalf("create disabled adapter: %v", err)
	}

	if err := adapter.Put(context.Background(), "batches/batch/evidence/evidence", []byte("content"), "application/pdf"); !errors.Is(err, ErrEvidenceStorageUnavailable) {
		t.Fatalf("expected disabled Put to fail closed, got %v", err)
	}
	if _, err := adapter.Get(context.Background(), "batches/batch/evidence/evidence"); !errors.Is(err, ErrEvidenceStorageUnavailable) {
		t.Fatalf("expected disabled Get to fail closed, got %v", err)
	}
	if err := adapter.Delete(context.Background(), "batches/batch/evidence/evidence"); !errors.Is(err, ErrEvidenceStorageUnavailable) {
		t.Fatalf("expected disabled Delete to fail closed, got %v", err)
	}
}

func TestNewEvidenceStorageRejectsUnsupportedAdapter(t *testing.T) {
	if _, err := NewEvidenceStorage(config.StorageConfig{AdapterType: "filesystem"}); err == nil {
		t.Fatal("expected unsupported adapter error")
	}
}

func TestLocalEvidenceStorageRoundTripAndNoOverwrite(t *testing.T) {
	adapter, err := NewEvidenceStorage(config.StorageConfig{
		AdapterType:        "local",
		LocalBaseDir:       t.TempDir(),
		MaxUploadSizeBytes: 1024,
	})
	if err != nil {
		t.Fatalf("create local adapter: %v", err)
	}

	key := "batches/batch-001/evidence/evidence-001"
	content := []byte("local evidence")
	if err := adapter.Put(context.Background(), key, content, "application/pdf"); err != nil {
		t.Fatalf("put local evidence: %v", err)
	}
	got, err := adapter.Get(context.Background(), key)
	if err != nil || string(got) != string(content) {
		t.Fatalf("get local evidence: content=%q err=%v", got, err)
	}
	if err := adapter.Put(context.Background(), key, []byte("overwrite"), "text/plain"); err == nil {
		t.Fatal("expected local evidence adapter to reject overwrite")
	}
	if err := adapter.Delete(context.Background(), key); err != nil {
		t.Fatalf("delete local evidence: %v", err)
	}
	if _, err := adapter.Get(context.Background(), key); !errors.Is(err, ErrEvidenceObjectNotFound) {
		t.Fatalf("expected missing local evidence error, got %v", err)
	}
}

func TestNewAzureBlobEvidenceStorageRequiresManagedIdentityAndEndpoint(t *testing.T) {
	base := config.StorageConfig{
		AdapterType:           "azure_blob",
		AzureStorageContainer: "evidence-private",
		AzureStorageEndpoint:  "https://storage.example.test",
		AzureUseManagedID:     true,
		MaxUploadSizeBytes:    5 * 1024 * 1024,
	}
	if _, err := newAzureBlobEvidenceStorage(config.StorageConfig{
		AdapterType:           base.AdapterType,
		AzureStorageContainer: base.AzureStorageContainer,
		AzureStorageEndpoint:  base.AzureStorageEndpoint,
		AzureUseManagedID:     false,
		MaxUploadSizeBytes:    base.MaxUploadSizeBytes,
	}); err == nil {
		t.Fatal("expected managed identity requirement")
	}
	if _, err := newAzureBlobEvidenceStorage(config.StorageConfig{
		AdapterType:           base.AdapterType,
		AzureStorageContainer: base.AzureStorageContainer,
		AzureUseManagedID:     true,
		MaxUploadSizeBytes:    base.MaxUploadSizeBytes,
	}); err == nil {
		t.Fatal("expected endpoint requirement")
	}
}

func TestValidateObjectKey(t *testing.T) {
	for _, testCase := range []struct {
		name string
		key  string
		ok   bool
	}{
		{name: "generated key", key: "batches/batch-001/evidence/evidence-001", ok: true},
		{name: "empty", key: "", ok: false},
		{name: "absolute", key: "/batches/batch/evidence", ok: false},
		{name: "path traversal", key: "batches/../secret", ok: false},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			err := validateObjectKey(testCase.key)
			if (err == nil) != testCase.ok {
				t.Fatalf("validateObjectKey(%q) error=%v, want valid=%t", testCase.key, err, testCase.ok)
			}
		})
	}
}

func TestMapAzureStorageErrorMapsMissingBlob(t *testing.T) {
	if !errors.Is(mapAzureStorageError(errors.New("BlobNotFound")), ErrEvidenceObjectNotFound) {
		t.Fatal("expected BlobNotFound to map to ErrEvidenceObjectNotFound")
	}
	if mapAzureStorageError(nil) != nil {
		t.Fatal("expected nil storage error to remain nil")
	}
}
