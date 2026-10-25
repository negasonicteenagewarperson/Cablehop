#!/bin/zsh
# Runs the unit tests.
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/env.sh
swift test ${TEST_FLAGS[@]} "$@"
