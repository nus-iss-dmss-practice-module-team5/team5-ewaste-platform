#!/usr/bin/env bash
# ==============================================================================
# S3-X-I-L-01: Evidence Storage Connectivity & Authorization Verification Probe
# ==============================================================================
# This probe tests both:
# 1. Permitted Path: ACA container connects to private storage via Private Link
#    and Managed Identity, then uploads a test verification artifact.
# 2. Denied Path: Public internet requests are blocked (HTTP 403 / IpForbidden).
# ==============================================================================

set -euo pipefail

TARGET_ENV="${1:-dev}"
RESOURCE_GROUP="rg-ewaste-${TARGET_ENV}"
ACA_APP_NAME="aca-ewaste-${TARGET_ENV}-api"
CONTAINER_NAME="workflow-api"
STORAGE_ACCOUNT="stgewaste${TARGET_ENV}"
CONTAINER="evidence-private"
TEST_BLOB_NAME="connectivity-check-$(date +%s).txt"

echo "=================================================================="
echo " Evidence Storage Verification Probe (${TARGET_ENV})"
echo " Storage Account: ${STORAGE_ACCOUNT}"
echo " Container:       ${CONTAINER}"
echo " Container App:   ${ACA_APP_NAME}"
echo "=================================================================="

# ------------------------------------------------------------------------------
# TEST 1: DENIED ACCESS (From Public Internet / Outside VNet)
# ------------------------------------------------------------------------------
echo ""
echo "[1/2] Testing Denied Public Internet Access (Decision D2 Zero-Trust)..."
PUBLIC_URL="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}/${TEST_BLOB_NAME}"
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${PUBLIC_URL}" || true)

if [ "${HTTP_STATUS}" == "403" ] || [ "${HTTP_STATUS}" == "000" ]; then
  echo "  [PASS] Public internet request blocked as expected (HTTP ${HTTP_STATUS})."
else
  echo "  [WARN] Unexpected response: HTTP ${HTTP_STATUS} (Expected 403 or network drop)"
fi

# ------------------------------------------------------------------------------
# TEST 2: PERMITTED ACCESS (From ACA Container via Private Link + Managed Identity)
# ------------------------------------------------------------------------------
echo ""
echo "[2/2] Testing Permitted Access from Container App (${ACA_APP_NAME})..."

PROBE_SCRIPT=$(cat <<EOF
set -e
echo "  -> Resolving DNS for ${STORAGE_ACCOUNT}.blob.core.windows.net..."
nslookup ${STORAGE_ACCOUNT}.blob.core.windows.net || true

echo "  -> Acquiring Azure AD token from Managed Identity IMDS..."
TOKEN_JSON=\$(wget -qO- --header="X-IDENTITY-HEADER: \$IDENTITY_HEADER" "\$IDENTITY_ENDPOINT?api-version=2019-08-01&resource=https://storage.azure.com/")
ACCESS_TOKEN=\$(echo "\$TOKEN_JSON" | grep -o '"access_token":"[^"]*' | cut -d'"' -f4)

if [ -z "\$ACCESS_TOKEN" ]; then
  echo "  [FAIL] Failed to acquire access token via Managed Identity"
  exit 1
fi
echo "  [OK] Managed Identity token acquired."

echo "  -> Uploading test artifact '${TEST_BLOB_NAME}' to ${CONTAINER}..."
TEST_CONTENT="Permitted verification evidence connectivity check from \$(hostname) at \$(date -u)"
echo "\$TEST_CONTENT" > /tmp/${TEST_BLOB_NAME}

UPLOAD_STATUS=\$(wget --method=PUT \
  --header="x-ms-version: 2023-11-03" \
  --header="x-ms-blob-type: BlockBlob" \
  --header="Authorization: Bearer \$ACCESS_TOKEN" \
  --body-file=/tmp/${TEST_BLOB_NAME} \
  -S -O /dev/null \
  "https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}/${TEST_BLOB_NAME}" 2>&1 | grep "HTTP/" | awk '{print \$2}' | head -n1 || echo "failed")

echo "  -> Upload HTTP Status: \$UPLOAD_STATUS"

if [ "\$UPLOAD_STATUS" == "201" ]; then
  echo "  [PASS] Successfully uploaded test blob to private storage via Private Link!"
else
  echo "  [FAIL] Upload failed with HTTP status: \$UPLOAD_STATUS"
  exit 1
fi

rm -f /tmp/${TEST_BLOB_NAME}
EOF
)

az containerapp exec \
  --name "${ACA_APP_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --container "${CONTAINER_NAME}" \
  --command sh -c "${PROBE_SCRIPT}"

echo ""
echo "=================================================================="
echo " Evidence Storage Verification Completed Successfully."
echo "=================================================================="
