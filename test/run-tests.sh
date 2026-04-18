#!/usr/bin/env bash
# Run all ERT tests for use-package-ensure-system-package+.
# Usage:
#   ./run-tests.sh          # run all suites
#   ./run-tests.sh unit     # run unit tests only
#   ./run-tests.sh func     # run functional tests only

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"

SUITE="${1:-all}"

UNIT_FILE="$TEST_DIR/test-unit.el"
FUNC_FILE="$TEST_DIR/test-functional.el"

case "$SUITE" in
  unit) FILES=("$UNIT_FILE") ;;
  func) FILES=("$FUNC_FILE") ;;
  all)  FILES=("$UNIT_FILE" "$FUNC_FILE") ;;
  *)
    echo "Usage: $0 [unit|func|all]" >&2
    exit 1
    ;;
esac

LOAD_ARGS=()
for f in "${FILES[@]}"; do
  LOAD_ARGS+=(-l "$f")
done

exec emacs --batch --no-site-file --no-site-lisp \
  --eval "(add-to-list 'load-path \"$PLUGIN_DIR\")" \
  "${LOAD_ARGS[@]}" \
  -f ert-run-tests-batch-and-exit
