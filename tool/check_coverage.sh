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

# Exclude generated sources (*.g.dart, *.freezed.dart) — they are not
# hand-written and testing them is meaningless, so they shouldn't dilute the
# coverage metric.
read -r hit found < <(awk -F: '
  /^SF:/ { gen = ($0 ~ /\.g\.dart$/ || $0 ~ /\.freezed\.dart$/) }
  /^LH:/ { if (!gen) h += $2 }
  /^LF:/ { if (!gen) f += $2 }
  END { print h+0, f+0 }
' "$LCOV")

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
