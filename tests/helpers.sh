# Shared assertions for the test suites (sourced, not executed).
# shellcheck shell=bash

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

_t_pass() {
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    TESTS_PASSED=$(( TESTS_PASSED + 1 ))
    echo "  PASS: $1"
}

_t_fail() {
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    TESTS_FAILED=$(( TESTS_FAILED + 1 ))
    echo "  FAIL: $1"
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        _t_pass "$desc"
    else
        _t_fail "${desc} (expected '${expected}', got '${actual}')"
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        _t_pass "$desc"
    else
        _t_fail "${desc} (missing: '${needle}')"
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        _t_pass "$desc"
    else
        _t_fail "${desc} (unexpectedly contains: '${needle}')"
    fi
}

assert_pass() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        _t_pass "$desc"
    else
        _t_fail "$desc"
    fi
}

assert_fail() {
    local desc="$1"; shift
    if ! "$@" >/dev/null 2>&1; then
        _t_pass "$desc"
    else
        _t_fail "${desc} (expected failure, got success)"
    fi
}

tests_summary() {
    echo ""
    echo "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"
    exit "$TESTS_FAILED"
}
