#!/usr/bin/env bash
# Gate 1 (EWCSB-241): the commit being released must have a successful run of
# the CI quality gate. Waits for a run that is still going; refuses when there
# is no run, when every run failed or was cancelled, or on timeout.
# Writes $GATE_DIR/gate-decision-ci.json and exits non-zero on REFUSED.
#
# Usage: ci_gate.sh <commit-sha>
# Env:   GH_TOKEN, GITHUB_REPOSITORY, GATE_DIR, TARGET_ENV, RUN_URL,
#        CI_WORKFLOW (default "CI Quality Gate & Security Baseline"),
#        CI_GATE_TIMEOUT (seconds, default 2400)
set -uo pipefail

SHA="$1"
WORKFLOW="${CI_WORKFLOW:-CI Quality Gate & Security Baseline}"
TIMEOUT="${CI_GATE_TIMEOUT:-2400}"
NO_RUN_GRACE=300
INTERVAL=30
mkdir -p "${GATE_DIR:?}"

decide() {
  jq -n --arg decision "$1" --arg reason "$2" --arg sha "$SHA" --arg workflow "$WORKFLOW" \
    --arg ci_run "$3" --arg env "${TARGET_ENV:-}" --arg run_url "${RUN_URL:-}" \
    '{record_version: 1, policy: "EWCSB-241", stage: "ci", decision: $decision,
      reasons: (if $reason == "" then [] else [$reason] end), commit: $sha,
      environment: $env, run_url: $run_url,
      checks: [{check: $workflow, result: $decision, detail: $ci_run}],
      decided_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))}' > "$GATE_DIR/gate-decision-ci.json"
  echo "Gate ci for $SHA: $1${2:+ ($2)}"
  if [ "$1" = PASS ]; then exit 0; fi
  echo "::error::Gate 1 refused: $2"
  exit 1
}

WAITED=0
while :; do
  if ! RUNS=$(gh run list --repo "$GITHUB_REPOSITORY" --workflow "$WORKFLOW" --commit "$SHA" \
      --limit 20 --json databaseId,status,conclusion,url); then
    decide REFUSED "could not read CI runs for $SHA" ""
  fi
  PASSED=$(jq -r '[.[] | select(.conclusion == "success")][0].url // ""' <<< "$RUNS")
  [ -n "$PASSED" ] && decide PASS "" "$PASSED"

  ACTIVE=$(jq '[.[] | select(.status != "completed")] | length' <<< "$RUNS")
  TOTAL=$(jq 'length' <<< "$RUNS")
  if [ "$TOTAL" -gt 0 ] && [ "$ACTIVE" -eq 0 ]; then
    decide REFUSED "no successful '$WORKFLOW' run for $SHA" "$(jq -r '.[0].url' <<< "$RUNS")"
  fi
  if [ "$TOTAL" -eq 0 ] && [ "$WAITED" -ge "$NO_RUN_GRACE" ]; then
    decide REFUSED "'$WORKFLOW' never ran for $SHA" ""
  fi
  if [ "$WAITED" -ge "$TIMEOUT" ]; then
    decide REFUSED "timed out after ${TIMEOUT}s waiting for '$WORKFLOW' on $SHA" ""
  fi
  echo "Waiting for '$WORKFLOW' on $SHA ($ACTIVE running, ${WAITED}s elapsed)..."
  sleep "$INTERVAL"
  WAITED=$((WAITED + INTERVAL))
done
