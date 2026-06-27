#!/usr/bin/env bash
# Fail if total line coverage in app/coverage/lcov.info is below a threshold.
# Usage: bash tool/check_coverage.sh <min_percent> [lcov_path]
set -euo pipefail

THRESHOLD="${1:?usage: check_coverage.sh <min_percent> [lcov_path]}"
LCOV="${2:-app/coverage/lcov.info}"

if [ ! -f "$LCOV" ]; then
  echo "::error::coverage file not found at $LCOV"
  exit 1
fi

hit=$(awk -F: '/^LH:/ {s+=$2} END {print s+0}' "$LCOV")
found=$(awk -F: '/^LF:/ {s+=$2} END {print s+0}' "$LCOV")

if [ "$found" -eq 0 ]; then
  echo "::error::no lines found in coverage report"
  exit 1
fi

pct=$(awk -v h="$hit" -v f="$found" 'BEGIN { printf "%.2f", 100 * h / f }')
echo "Line coverage: ${pct}% (${hit}/${found} lines) — threshold ${THRESHOLD}%"

if awk -v p="$pct" -v t="$THRESHOLD" 'BEGIN { exit !(p + 0 >= t + 0) }'; then
  echo "Coverage check passed."
else
  echo "::error::coverage ${pct}% is below the required ${THRESHOLD}%"
  exit 1
fi
