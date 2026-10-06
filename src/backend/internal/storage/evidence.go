package storage

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"github.com/Azure/azure-sdk-for-go/sdk/storage/azblob"
	"github.com/Azure/azure-sdk-for-go/sdk/storage/azblob/blob"

	"workflow-api/internal/config"
)

var (
	ErrEvidenceStorageUnavailable = errors.New("evidence storage unavailable")
	ErrEvidenceObjectNotFound     = errors.New("evidence object not found")
)

// EvidenceStorage is deliberately narrower than the Azure client. Workflow
// code can only put, get, and compensate an object; it cannot expose a public
// URL, list a container, or delete an arbitrary user-selected key.
type EvidenceStorage interface {
	Put(ctx context.Context, objectKey string, content []byte, contentType string) error
	Get(ctx context.Context, objectKey string) ([]byte, error)
	Delete(ctx context.Context, objectKey string) error
}

type unavailableEvidenceStorage struct{}

func (unavailableEvidenceStorage) Put(context.Context, string, []byte, string) error {
	return ErrEvidenceStorageUnavailable
}
func (unavailableEvidenceStorage) Get(context.Context, string) ([]byte, error) {
	return nil, ErrEvidenceStorageUnavailable
}
func (unavailableEvidenceStorage) Delete(context.Context, string) error {
	return ErrEvidenceStorageUnavailable
}

// NewEvidenceStorage creates the configured private adapter. The disabled
// default keeps local development fail-closed: metadata is never saved when
// object storage is unavailable.
func NewEvidenceStorage(cfg config.StorageConfig) (EvidenceStorage, error) {
	switch strings.ToLower(strings.TrimSpace(cfg.AdapterType)) {
	case "", "disabled":
		return unavailableEvidenceStorage{}, nil
	case "azure", "azure_blob":
		return newAzureBlobEvidenceStorage(cfg)
	default:
		return nil, fmt.Errorf("unsupported evidence storage adapter %q", cfg.AdapterType)
	}
}

type azureBlobEvidenceStorage struct {
	client    *azblob.Client
	container string
	maxBytes  int64
}

func newAzureBlobEvidenceStorage(cfg config.StorageConfig) (EvidenceStorage, error) {
	if !cfg.AzureUseManagedID {
		return nil, errors.New("azure evidence storage requires managed identity")
	}
	endpoint := strings.TrimRight(strings.TrimSpace(cfg.AzureStorageEndpoint), "/")
	if endpoint == "" && strings.TrimSpace(cfg.AzureStorageAccount) != "" {
		endpoint = "https://" + strings.TrimSpace(cfg.AzureStorageAccount) + ".blob.core.windows.net"
	}
	if endpoint == "" {
		return nil, errors.New("azure evidence storage endpoint is required")
	}
	container := strings.TrimSpace(cfg.AzureStorageContainer)
	if container == "" {
		return nil, errors.New("azure evidence storage container is required")
	}
	if cfg.MaxUploadSizeBytes < 1 {
		return nil, errors.New("evidence upload size limit must be positive")
	}

	credential, err := azidentity.NewDefaultAzureCredential(nil)
	if err != nil {
		return nil, fmt.Errorf("create managed identity credential: %w", err)
	}
	client, err := azblob.NewClient(endpoint, credential, nil)
	if err != nil {
		return nil, fmt.Errorf("create azure blob client: %w", err)
	}

	return &azureBlobEvidenceStorage{
		client:    client,
		container: container,
		maxBytes:  cfg.MaxUploadSizeBytes,
	}, nil
}

func (s *azureBlobEvidenceStorage) Put(ctx context.Context, objectKey string, content []byte, contentType string) error {
	if err := validateObjectKey(objectKey); err != nil {
		return err
	}
	if int64(len(content)) > s.maxBytes {
		return fmt.Errorf("evidence object exceeds configured size limit")
	}
	_, err := s.client.UploadBuffer(ctx, s.container, objectKey, content, &azblob.UploadBufferOptions{
		HTTPHeaders: &blob.HTTPHeaders{BlobContentType: &contentType},
		// The service generates unique keys. Never overwrite an existing object.
		AccessConditions: &blob.AccessConditions{ModifiedAccessConditions: &blob.ModifiedAccessConditions{IfNoneMatch: new(azcore.ETagAny)}},
	})
	return err
}

func (s *azureBlobEvidenceStorage) Get(ctx context.Context, objectKey string) ([]byte, error) {
	if err := validateObjectKey(objectKey); err != nil {
		return nil, err
	}
	resp, err := s.client.DownloadStream(ctx, s.container, objectKey, nil)
	if err != nil {
		return nil, mapAzureStorageError(err)
	}
	content, readErr := io.ReadAll(io.LimitReader(resp.Body, s.maxBytes+1))
	closeErr := resp.Body.Close()
	if readErr != nil {
		return nil, readErr
	}
	if closeErr != nil {
		return nil, fmt.Errorf("close evidence object response: %w", closeErr)
	}
	if int64(len(content)) > s.maxBytes {
		return nil, errors.New("evidence object exceeds configured size limit")
	}
	return content, nil
}

func (s *azureBlobEvidenceStorage) Delete(ctx context.Context, objectKey string) error {
	if err := validateObjectKey(objectKey); err != nil {
		return err
	}
	_, err := s.client.DeleteBlob(ctx, s.container, objectKey, nil)
	return mapAzureStorageError(err)
}

func validateObjectKey(objectKey string) error {
	objectKey = strings.TrimSpace(objectKey)
	if objectKey == "" || strings.HasPrefix(objectKey, "/") || strings.Contains(objectKey, "..") {
		return errors.New("invalid evidence object key")
	}
	return nil
}

func mapAzureStorageError(err error) error {
	if err == nil {
		return nil
	}
	// The adapter intentionally does not expose provider details to callers.
	// Missing objects are mapped for the service; all other failures fail closed.
	if strings.Contains(strings.ToLower(err.Error()), "blobnotfound") || strings.Contains(strings.ToLower(err.Error()), "blob not found") {
		return ErrEvidenceObjectNotFound
	}
	return err
}
