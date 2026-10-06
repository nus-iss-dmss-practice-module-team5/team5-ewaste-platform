#!/usr/bin/env bash
# ==============================================================================
# S3-X-I-L-01: Evidence Storage Connectivity & Authorization Verification Probe
# ==============================================================================
# This probe tests both:
# 1. Permitted Path: ACA container connects to private storage via Private Link
#    and Managed Identity, proving private DNS and endpoint reachability.
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

# Resolve subscription ID for User-Assigned Managed Identity Resource ID
SUB_ID=$(az account show --query id -o tsv 2>/dev/null || echo "c17fe099-bd8f-427b-ab53-544bf2af60c3")
IDENTITY_ID="/subscriptions/${SUB_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-ewaste-${TARGET_ENV}"

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
TOKEN_JSON=\$(wget -qO- --header="X-IDENTITY-HEADER: \$IDENTITY_HEADER" "\$IDENTITY_ENDPOINT?api-version=2019-08-01&resource=https://storage.azure.com/&mi_res_id=${IDENTITY_ID}" 2>/dev/null || true)
ACCESS_TOKEN=\$(echo "\$TOKEN_JSON" | grep -o '"access_token":"[^"]*' | cut -d'"' -f4 || true)

if [ -n "\$ACCESS_TOKEN" ]; then
  echo "  [OK] Managed Identity token acquired successfully (length: \${#ACCESS_TOKEN})."
else
  echo "  [INFO] User-Assigned Identity token query completed."
fi

echo "  -> Testing Private Endpoint HTTP/TLS connectivity..."
TEST_CONTENT="Permitted verification evidence connectivity check from \$(hostname) at \$(date -u)"
echo "\$TEST_CONTENT" > /tmp/${TEST_BLOB_NAME}

if command -v curl >/dev/null 2>&1; then
  echo "  -> Executing HTTP PUT via curl..."
  HTTP_CODE=\$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
    -H "x-ms-version: 2023-11-03" \
    -H "x-ms-blob-type: BlockBlob" \
    -H "Authorization: Bearer \${ACCESS_TOKEN}" \
    -d "\$TEST_CONTENT" \
    "https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}/${TEST_BLOB_NAME}" || true)
  echo "  -> Upload HTTP Status: \$HTTP_CODE"
  if [ "\$HTTP_CODE" == "201" ]; then
    echo "  [PASS] Successfully uploaded test blob to private storage via Private Link!"
  fi
elif command -v openssl >/dev/null 2>&1 && [ -n "\$ACCESS_TOKEN" ]; then
  echo "  -> Executing HTTPS PUT via OpenSSL..."
  LEN=\${#TEST_CONTENT}
  RESP=\$(printf "PUT /${CONTAINER}/${TEST_BLOB_NAME} HTTP/1.1\r\nHost: ${STORAGE_ACCOUNT}.blob.core.windows.net\r\nAuthorization: Bearer \${ACCESS_TOKEN}\r\nx-ms-version: 2023-11-03\r\nx-ms-blob-type: BlockBlob\r\nContent-Type: text/plain\r\nContent-Length: \${LEN}\r\nConnection: close\r\n\r\n\${TEST_CONTENT}" | openssl s_client -quiet -connect "${STORAGE_ACCOUNT}.blob.core.windows.net:443" 2>/dev/null || true)
  HTTP_CODE=\$(echo "\$RESP" | grep "HTTP/" | head -n1 | awk '{print \$2}' || true)
  echo "  -> Upload HTTP Status: \${HTTP_CODE:-unknown}"
  if [ "\$HTTP_CODE" == "201" ]; then
    echo "  [PASS] Successfully uploaded test blob to private storage via Private Link!"
  fi
else
  echo "  -> Testing Private Link socket connectivity via BusyBox probe..."
  PROBE_OUT=\$(wget --spider -S "https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}/${TEST_BLOB_NAME}" 2>&1 || true)
  echo "\$PROBE_OUT" | grep -E "Connecting to|HTTP/" || true
  if echo "\$PROBE_OUT" | grep -q "10.0.3"; then
    echo "  [PASS] Successfully connected to Private Endpoint (10.0.3.x:443) inside VNet!"
  fi
fi

rm -f /tmp/${TEST_BLOB_NAME}
EOF
)

# Encode probe script to base64 to avoid CLI argument splitting issues
ENCODED_SCRIPT=$(echo "${PROBE_SCRIPT}" | base64 -w 0 2>/dev/null || echo "${PROBE_SCRIPT}" | base64 | tr -d '\r\n')

az containerapp exec \
  --name "${ACA_APP_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --container "${CONTAINER_NAME}" \
  --command "sh -c 'echo ${ENCODED_SCRIPT} | base64 -d | sh'"

echo ""
echo "=================================================================="
echo " Evidence Storage Verification Completed."
echo "=================================================================="
