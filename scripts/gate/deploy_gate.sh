#!/usr/bin/env bash
# Gate 3 (EWCSB-241): decide whether one digest may be deployed. The digest must
# carry a valid team signature AND a passing Gate 2 (build-sign) decision,
# attested with the same key. Writes $GATE_DIR/<service>/gate-decision-<stage>.json
# and exits non-zero on REFUSED, before any `az containerapp update` runs.
#
# Usage: deploy_gate.sh <service> <image-name> <digest-ref> [deploy|rollback]
# Env:   GATE_DIR, COMMIT, TARGET_ENV, RUN_URL
set -uo pipefail

SERVICE="$1" IMAGE="$2" DIGEST="$3" STAGE="${4:-deploy}"
OUT_DIR="${GATE_DIR:?}/${SERVICE}"
mkdir -p "$OUT_DIR"
KEY=security/cosign.pub
PREDICATE_TYPE=$(python3 -c 'import sys; sys.path.insert(0, "scripts/gate"); import gate_policy; print(gate_policy.GATE_PREDICATE_TYPE)')

if [ ! -f "$KEY" ]; then
  echo "::error::Committed team public key $KEY is missing. Cannot verify release."
  SIGNATURE_OK=false
elif cosign verify --key "$KEY" "$DIGEST" > "$OUT_DIR/cosign-verify.json"; then
  SIGNATURE_OK=true
else
  echo "::error::cosign verify failed for $DIGEST."
  SIGNATURE_OK=false
fi

# An empty file (no attestation, or one not made with the team key) refuses.
: > "$OUT_DIR/attestation.json"
if [ -f "$KEY" ]; then
  cosign verify-attestation --key "$KEY" --type "$PREDICATE_TYPE" "$DIGEST" \
    > "$OUT_DIR/attestation.json" 2> "$OUT_DIR/verify-attestation.log" \
    || { echo "::error::No verified gate-decision attestation for $DIGEST."; : > "$OUT_DIR/attestation.json"; }
fi

python3 "$(dirname "$0")/gate_policy.py" deploy \
  --image "$IMAGE" --digest "$DIGEST" --stage "$STAGE" \
  --signature-ok "$SIGNATURE_OK" --attestation "$OUT_DIR/attestation.json" \
  --out "$OUT_DIR/gate-decision-${STAGE}.json" \
  --commit "${COMMIT:-}" --environment "${TARGET_ENV:-}" --run-url "${RUN_URL:-}" \
  --tool "cosign=$(cosign version --json 2>/dev/null | jq -r '.gitVersion // "unknown"' || echo unknown)"
