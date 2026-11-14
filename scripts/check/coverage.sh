#!/bin/sh
# Print the coverage of a Go profile and fail below a floor. POSIX sh: also
# runs in the Gitea CI job image (alpine, no bash).
# Usage: coverage.sh <coverprofile> <minimum percent>   (go on PATH)
set -eu
profile=$1
min=$2
total=$(go tool cover -func="$profile" | awk '/^total:/ {sub("%", "", $3); print $3}')
echo "Coverage: ${total}% (floor ${min}%)"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "**Go coverage: ${total}%** (floor ${min}%)" >> "$GITHUB_STEP_SUMMARY"
fi
if ! awk -v t="$total" -v m="$min" 'BEGIN { exit !(t >= m) }'; then
  echo "Coverage ${total}% is below the floor ${min}%"
  exit 1
fi
