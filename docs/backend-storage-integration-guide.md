# Backend Integration Guide: Private Evidence Storage (Azure Blob)

**Task**: `S3-X-I-L-01` (Jira: `EWCSB-162`) — Provision Evidence Storage and Configuration
**Architectural Baseline**: Decision D2 (Zero-Trust Private Evidence Store), Sprint 3
**Target Workload**: `workflow-api` Container App (`aca-ewaste-{env}-api`)

---

## 1. Executive Summary & Architecture

The e-Waste platform evidence storage securely stores physical verification and chain-of-custody artifacts (weighbridge tickets, destruction certificates, device photos).

### Architecture Overview

```
                      +-------------------------------------------------------+
                      | Azure Virtual Network (vnet-ewaste-dev)                |
                      |                                                       |
                      |   +-----------------------------------------------+   |
                      |   | snet-aca (10.0.4.0/23)                        |   |
                      |   | +-------------------------------------------+ |   |
                      |   | | Azure Container App: aca-ewaste-dev-api   | |   |
                      |   | | - Identity: id-ewaste-dev (Managed Id)   | |   |
                      |   | +-------------------------------------------+ |   |
                      |   +-----------------------+-----------------------+   |
                      |                           |                           |
                      |        Internal VNet Call | (Private DNS Resolution)   |
                      |                           v                           |
                      |   +-----------------------------------------------+   |
                      |   | snet-private-endpoints (10.0.3.0/24)          |   |
                      |   | +-------------------------------------------+ |   |
                      |   | | Private Endpoint: pe-stgewaste-dev        | |   |
                      |   | | IP: 10.0.3.x                              | |   |
                      |   | +-------------------------------------------+ |   |
                      |   +-----------------------+-----------------------+   |
                      +---------------------------|---------------------------+
                                                  | Private Link
                                                  v
                      +-------------------------------------------------------+
                      | Azure Blob Storage: stgewastedev                      |
                      | - Public Network Access: DISABLED (Zero-Trust)       |
                      | - Authentication: Secretless Azure AD (RBAC)         |
                      | - Container: evidence-private                         |
                      | - RBAC Role: Storage Blob Data Contributor            |
                      +-------------------------------------------------------+
                                                  ^
                                                  |
                                   Public Internet Requests
                                        [BLOCKED: 403]
```

### Key Security Guardrails

1. **Zero-Trust Network Isolation**: `public_network_access_enabled = false`. Direct internet access is blocked. All traffic from `workflow-api` traverses Azure Private Link.
2. **Secretless Authentication**: No storage account access keys or connection strings are stored in code, environment variables, or config files. The application authenticates dynamically using the User-Assigned Managed Identity (`id-ewaste-{env}`).
3. **Least Privilege RBAC**: The Managed Identity is assigned the built-in role **Storage Blob Data Contributor** scoped specifically to the evidence storage account.

---

## 2. Injected Environment Variables

The IaC pipeline automatically provisions and injects the following configuration variables into the `workflow-api` container app:

| Variable Name             | Example Dev Value                             | Description                                                                               |
| :------------------------ | :-------------------------------------------- | :---------------------------------------------------------------------------------------- |
| `STORAGE_ADAPTER_TYPE`    | `azure_blob`                                  | Tells backend to instantiate the Azure Blob storage adapter (`local` for dev/unit tests). |
| `AZURE_STORAGE_ACCOUNT`   | `stgewastedev`                                | The name of the target Azure Storage Account.                                             |
| `AZURE_STORAGE_CONTAINER` | `evidence-private`                            | The dedicated private blob container for verification evidence.                           |
| `AZURE_STORAGE_ENDPOINT`  | `https://stgewastedev.blob.core.windows.net/` | Private endpoint URL. If omitted, derived automatically from `AZURE_STORAGE_ACCOUNT`.     |
| `AZURE_USE_MANAGED_ID`    | `true`                                        | Enables secretless token exchange via Azure Instance Metadata Service (IMDS).             |
| `MAX_UPLOAD_SIZE_BYTES`   | `5242880`                                     | Maximum upload size allowed per file (**5 MB**).                                          |

> **Note**: Backward compatibility variables `EWASTE_STORAGE_AZURE_ACCOUNT_NAME`, `EWASTE_STORAGE_AZURE_CONTAINER_NAME`, and `EWASTE_STORAGE_AZURE_ENDPOINT` are also bound to provide full compatibility with existing configuration loaders.

---

## 3. Go Backend Implementation Guide

### Step 1: Add Azure Go SDK Dependencies

Run the following in `src/backend`:

```bash
go get github.com/Azure/azure-sdk-for-go/sdk/azidentity
go get github.com/Azure/azure-sdk-for-go/sdk/storage/azblob
```

### Step 2: Storage Adapter Interface

Define the storage interface in `internal/storage/evidence.go`:

```go
package storage

import (
	"context"
	"io"
	"time"
)

// EvidenceStorage defines the contract for storing verification artifacts.
type EvidenceStorage interface {
	// Upload uploads a stream of bytes to the evidence store.
	Upload(ctx context.Context, blobName string, reader io.Reader, size int64, contentType string) (string, error)
	// Download retrieves the blob content.
	Download(ctx context.Context, blobName string) (io.ReadCloser, error)
	// Delete removes an evidence artifact.
	Delete(ctx context.Context, blobName string) error
	// GetURL returns the canonical resource URL.
	GetURL(blobName string) string
}
```

### Step 3: Azure Blob Adapter Implementation

Implement the Azure Blob adapter using `azidentity.NewDefaultAzureCredential`:

```go
package storage

import (
	"context"
	"fmt"
	"io"
	"strings"

	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"github.com/Azure/azure-sdk-for-go/sdk/storage/azblob"
	"workflow-api/internal/config"
)

type AzureBlobStorage struct {
	client        *azblob.Client
	containerName string
	serviceURL    string
	maxSizeBytes  int64
}

func NewAzureBlobStorage(cfg config.StorageConfig) (*AzureBlobStorage, error) {
	serviceURL := cfg.AzureEndpoint
	if serviceURL == "" {
		serviceURL = fmt.Sprintf("https://%s.blob.core.windows.net/", cfg.AzureAccountName)
	}
	if !strings.HasSuffix(serviceURL, "/") {
		serviceURL += "/"
	}

	// Secretless authentication via Azure Managed Identity
	cred, err := azidentity.NewDefaultAzureCredential(nil)
	if err != nil {
		return nil, fmt.Errorf("create azure credential: %w", err)
	}

	client, err := azblob.NewClient(serviceURL, cred, nil)
	if err != nil {
		return nil, fmt.Errorf("create azblob client: %w", err)
	}

	return &AzureBlobStorage{
		client:        client,
		containerName: cfg.AzureContainerName,
		serviceURL:    serviceURL,
		maxSizeBytes:  cfg.MaxUploadSizeBytes,
	}, nil
}

func (s *AzureBlobStorage) Upload(ctx context.Context, blobName string, reader io.Reader, size int64, contentType string) (string, error) {
	if s.maxSizeBytes > 0 && size > s.maxSizeBytes {
		return "", fmt.Errorf("file size %d bytes exceeds maximum limit of %d bytes", size, s.maxSizeBytes)
	}

	options := &azblob.UploadStreamOptions{
		HTTPHeaders: &azblob.BlobHTTPHeaders{
			BlobContentType: &contentType,
		},
	}

	_, err := s.client.UploadStream(ctx, s.containerName, blobName, reader, options)
	if err != nil {
		return "", fmt.Errorf("upload blob %s: %w", blobName, err)
	}

	return s.GetURL(blobName), nil
}

func (s *AzureBlobStorage) Download(ctx context.Context, blobName string) (io.ReadCloser, error) {
	resp, err := s.client.DownloadStream(ctx, s.containerName, blobName, nil)
	if err != nil {
		return nil, fmt.Errorf("download blob %s: %w", blobName, err)
	}
	return resp.Body, nil
}

func (s *AzureBlobStorage) Delete(ctx context.Context, blobName string) error {
	_, err := s.client.DeleteBlob(ctx, s.containerName, blobName, nil)
	if err != nil {
		return fmt.Errorf("delete blob %s: %w", blobName, err)
	}
	return nil
}

func (s *AzureBlobStorage) GetURL(blobName string) string {
	return fmt.Sprintf("%s%s/%s", s.serviceURL, s.containerName, blobName)
}
```

### Step 4: Factory Method with Local Fallback

For local testing without Azure connection, support the `local` fallback:

```go
func NewEvidenceStorage(cfg config.StorageConfig) (EvidenceStorage, error) {
	switch strings.ToLower(cfg.Type) {
	case "azure_blob", "azure":
		return NewAzureBlobStorage(cfg)
	case "local", "":
		return NewLocalStorage(cfg.LocalBaseDir, cfg.MaxUploadSizeBytes)
	default:
		return nil, fmt.Errorf("unsupported storage adapter type: %s", cfg.Type)
	}
}
```

---

## 4. Connectivity Verification & Evidence Tests

### Test 1: Live Verification from ACA Container (Permitted Path)

To verify that the running container app can authenticate via Managed Identity, resolve private DNS, and upload to the storage account, run this command from Azure Cloud Shell or local terminal:

```bash
# Execute probe inside the running Container App
az containerapp exec \
  --name aca-ewaste-dev-api \
  --resource-group rg-ewaste-dev \
  --container workflow-api \
  --command sh
```

Inside the container shell, test DNS resolution and authenticated upload:

```sh
# 1. Verify Private Link DNS resolution (resolves to 10.0.3.x private IP)
nslookup stgewastedev.blob.core.windows.net

# 2. Acquire Azure AD OAuth token using Container App Managed Identity IMDS
TOKEN_RESPONSE=$(wget -qO- \
  --header="X-IDENTITY-HEADER: $IDENTITY_HEADER" \
  "$IDENTITY_ENDPOINT?api-version=2019-08-01&resource=https://storage.azure.com/")
ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -o '"access_token":"[^"]*' | cut -d'"' -f4)

# 3. Upload test verification evidence file
echo "Verification evidence connectivity check $(date -u)" > /tmp/evidence-probe.txt
wget --method=PUT \
  --header="x-ms-version: 2023-11-03" \
  --header="x-ms-blob-type: BlockBlob" \
  --header="Authorization: Bearer $ACCESS_TOKEN" \
  --body-file=/tmp/evidence-probe.txt \
  -O /dev/null \
  -S \
  "https://stgewastedev.blob.core.windows.net/evidence-private/evidence-probe.txt"

# Expected Output: HTTP/1.1 201 Created
```

### Test 2: Public Internet Access Denied (Decision D2 Evidence)

Verify that public network access is strictly rejected:

```bash
# Run from your local terminal / public internet:
curl -I https://stgewastedev.blob.core.windows.net/evidence-private/evidence-probe.txt

# Expected Result:
# HTTP/1.1 403 This request is not authorized to perform this operation.
# ErrorCode: IpForbidden / PublicNetworkAccessDenied
```

This confirms that:

1. Permitted traffic from ACA via Private Endpoint succeeds (HTTP 201).
2. Unpermitted traffic from outside the VNet is denied (HTTP 403).
3. ADR Decision D2 compliance is verified.
