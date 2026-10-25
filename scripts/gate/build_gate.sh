#!/usr/bin/env bash
# Gate 2 (EWCSB-241): scan one built image's SBOM with Grype and decide whether
# it may be signed. Writes $GATE_DIR/<service>/gate-decision-build.json and
# exits non-zero on REFUSED. Never signs anything itself.
#
# Usage: build_gate.sh <service> <image-name> <digest-ref> <sbom-file>
# Env:   GRYPE (path to grype), GATE_DIR, COMMIT, TARGET_ENV, RUN_URL,
#        REFUSAL_TEST (scanner-error simulates RT-17 on the API image)
set -uo pipefail

SERVICE="$1" IMAGE="$2" DIGEST="$3" SBOM="$4"
OUT_DIR="${GATE_DIR:?}/${SERVICE}"
mkdir -p "$OUT_DIR"
REPORT="$OUT_DIR/grype.json"
rm -f "$REPORT"

GRYPE_VERSION=$("${GRYPE:?}" version -o json 2>/dev/null | jq -r '.version // "unknown"' || echo unknown)

if [ "${REFUSAL_TEST:-none}" = "scanner-error" ] && [ "$SERVICE" = "api" ]; then
  echo "::warning::Refusal test RT-17: simulating a Grype failure for $SERVICE."
  SCAN_STATUS=1
else
  "$GRYPE" "sbom:${SBOM}" --output json --file "$REPORT"
  SCAN_STATUS=$?
fi

if [ "$SCAN_STATUS" -ne 0 ]; then
  # Fail closed: a partial report must never be read as a clean one.
  echo "::error::Grype exited with status $SCAN_STATUS for $SERVICE."
  rm -f "$REPORT"
fi

python3 "$(dirname "$0")/gate_policy.py" build \
  --image "$IMAGE" --digest "$DIGEST" --sbom "$SBOM" --grype "$REPORT" \
  --dispositions security/dispositions.yaml \
  --out "$OUT_DIR/gate-decision-build.json" \
  --commit "${COMMIT:-}" --environment "${TARGET_ENV:-}" --run-url "${RUN_URL:-}" \
  --tool "grype=${GRYPE_VERSION}" --tool "syft=$(syft version -o json 2>/dev/null | jq -r '.version // "unknown"' || echo unknown)"
