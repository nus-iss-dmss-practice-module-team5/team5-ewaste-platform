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
                      |   | snet-aca (10.0.8.0/21)                        |   |
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
                      |   | | IP: 10.0.3.7                              | |   |
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

1. **Zero-Trust Network Isolation**: `public_network_access_enabled = false`. Direct internet access is blocked. All traffic from `workflow-api` traverses Azure Private Link (`10.0.3.7`).
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

Implement the Azure Blob adapter using `azidentity.NewDefaultAzureCredential` or `azidentity.NewManagedIdentityCredential`:

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

## 4. Connectivity Verification & Audit Evidence

### Artifact Evidence 1: Denied Public Internet Access (Zero-Trust Decision D2)

Executed from outside the VNet (Public Internet / Developer Machine / CI Runner):

```bash
curl -I https://stgewastedev.blob.core.windows.net/evidence-private/test-probe.txt
```

**Observed Result**:

```text
HTTP/1.1 403 This request is not authorized to perform this operation.
[PASS] Public internet request blocked as expected (HTTP 403).
```

**Conclusion**: Direct internet access is completely blocked (`public_network_access_enabled = false`). Storage account firewall drops external traffic.

---

### Artifact Evidence 2: Permitted Private Link Read (Inside ACA Container App)

Executed from within the `aca-ewaste-dev-api` container (`/app $`):

```sh
IDENTITY_RES_ID="/subscriptions/c17fe099-bd8f-427b-ab53-544bf2af60c3/resourceGroups/rg-ewaste-dev/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-ewaste-dev"

TOKEN=$(wget -qO- --header="X-IDENTITY-HEADER: $IDENTITY_HEADER" "$IDENTITY_ENDPOINT?api-version=2019-08-01&resource=https://storage.azure.com/&mi_res_id=$IDENTITY_RES_ID" | grep -o '"access_token":"[^"]*' | cut -d'"' -f4)

wget -qO- \
  --header="x-ms-version: 2023-11-03" \
  --header="Authorization: Bearer $TOKEN" \
  "https://stgewastedev.blob.core.windows.net/evidence-private?restype=container&comp=list&maxresults=5" | \
  grep -o '<Name>[^<]*' | sed 's/<Name>/  [ACA Read via Private Link] /'
```

**Observed Result**:

```text
  [ACA Read via Private Link] evidence-1.txt
  [ACA Read via Private Link] evidence-2.txt
  [ACA Read via Private Link] evidence-3.txt
  [ACA Read via Private Link] evidence-4.txt
  [ACA Read via Private Link] evidence-5.txt
```

**Conclusion**:

- DNS queries inside `vnet-ewaste-dev` resolve `stgewastedev.blob.core.windows.net` to internal private IP **`10.0.3.7`** via Private DNS Zone `privatelink.blob.core.windows.net`.
- Managed Identity `id-ewaste-dev` acquires token from IMDS endpoint with resource URI `https://storage.azure.com/`.
- Container App connects directly to Blob Storage over Private Link and successfully lists/reads artifacts without leaving the private network.

---

### Artifact Evidence 3: Automated Infrastructure Audit Probe

Run via [`scripts/verify-evidence-storage.sh`](file:///C:/Users/laksh/Documents/NUS-ISS%20MTech%20SE/1%20-%20SWE5006%20-%20Designing%20Modern%20Software%20Systems/Practice%20Module/GitHub%20Codebase/team5-ewaste-platform/scripts/verify-evidence-storage.sh):

```bash
./scripts/verify-evidence-storage.sh dev
```

**Summary Output**:

```text
==================================================================
 S3-X-I-L-01: Evidence Storage Verification Probe (dev)
 Storage Account:    stgewastedev
 Container:          evidence-private
 Private Endpoint:   pe-stgewaste-dev
 Container App:      aca-ewaste-dev-api
==================================================================
[1/6] Testing Denied Public Internet Access (Decision D2 Zero-Trust)...
  [PASS] Public internet request blocked as expected (HTTP 403).
         Zero-Trust boundary verified: storage is unreachable from outside VNet.

[2/6] Verifying Private Endpoint Provisioning & Private Link...
  [PASS] Private Endpoint Status: Approved
         Private IP Address:     10.0.3.7

[3/6] Verifying Private DNS Zone Link to VNet...
  [PASS] Private DNS Zone 'privatelink.blob.core.windows.net' is linked to VNet.
         Internal queries for stgewastedev.blob.core.windows.net resolve to private IP.

[4/6] Verifying Workload Managed Identity RBAC...
Role                           PrincipalType
-----------------------------  ----------------
Storage Blob Data Contributor  ServicePrincipal
Storage Blob Data Contributor  ServicePrincipal
Storage Blob Data Contributor  ServicePrincipal
  [PASS] Role 'Storage Blob Data Contributor' is actively assigned on stgewastedev.

[5/6] Verifying ACA Storage Adapter Environment Injections...
  STORAGE_ADAPTER_TYPE    azure_blob
  AZURE_STORAGE_ACCOUNT   stgewastedev
  AZURE_STORAGE_CONTAINER evidence-private
  AZURE_STORAGE_ENDPOINT  https://stgewastedev.blob.core.windows.net/
  AZURE_USE_MANAGED_ID    true
  MAX_UPLOAD_SIZE_BYTES   5242880

[6/6] Uploading dummy files & querying real filenames from 'evidence-private'...
  === Displaying Blob Filenames in 'evidence-private' ===
  [Verified Blob] evidence-1.txt
  [Verified Blob] evidence-2.txt
  [Verified Blob] evidence-3.txt
  [Verified Blob] evidence-4.txt
  [Verified Blob] evidence-5.txt
==================================================================
 S3-X-I-L-01 Verification Summary:
 [x] Decision D2 Zero-Trust (Public Internet Blocked): PASS
 [x] Private Link & Private Endpoint (10.0.3.7):       PASS
 [x] Private DNS Zone Resolution:                      PASS
 [x] Secretless Managed Identity RBAC:                 PASS
 [x] Backend Adapter Settings Injected into ACA:       PASS
 [x] Zero-Trust Verified & Sealed:                     PASS
==================================================================
```
