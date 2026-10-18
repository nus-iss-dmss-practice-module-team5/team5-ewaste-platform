#!/usr/bin/env bash
# Run from any directory. Credentials stay in an external JMeter properties file.
set -euo pipefail
TASK_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
exec "${PYTHON_BIN:-python3}" "$TASK_ROOT/scripts/jmeter/run_s4.py" "$@"
