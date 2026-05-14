#!/usr/bin/env bash
# Run all test suites
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
total_failed=0

echo "==============================="
echo "  Running All Tests"
echo "==============================="
echo ""

for test_file in "${SCRIPT_DIR}"/test-*.sh; do
    if [[ -f "$test_file" ]]; then
        echo "--- $(basename "$test_file") ---"
        if bash "$test_file"; then
            true
        else
            (( total_failed += $? ))
        fi
        echo ""
    fi
done

echo "==============================="
if [[ "$total_failed" -eq 0 ]]; then
    echo "  All tests passed!"
else
    echo "  ${total_failed} test(s) failed"
fi
echo "==============================="

exit "$total_failed"
