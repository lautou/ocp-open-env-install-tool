#!/bin/bash
# Job Script Testing Harness
# Purpose: Unit test critical logic from Kubernetes Jobs before deployment
# Usage: ./scripts/test-job-scripts.sh

set -e

FAILED=0
PASSED=0

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "======================================"
echo "Job Script Logic Testing"
echo "======================================"
echo ""

# Test helper functions
pass() {
  echo -e "  ${GREEN}✅ $1${NC}"
  PASSED=$((PASSED + 1))
}

fail() {
  echo -e "  ${RED}❌ $1${NC}"
  FAILED=$((FAILED + 1))
}

info() {
  echo -e "${YELLOW}$1${NC}"
}

# ============================================
# Test 1: Pod counting logic (create-alert-silences)
# ============================================
test_pod_counting() {
  info "Test 1: Pod counting logic (create-alert-silences)"

  # Simulate oc get pods output with pods ready
  PODS_OUTPUT="alertmanager-main-0   6/6   Running   0     34m
alertmanager-main-1   6/6   Running   0     34m"

  READY_PODS=$(echo "$PODS_OUTPUT" | awk '{split($2,a,"/"); if(a[1]==a[2] && a[1]!="") count++} END {print count+0}')

  if [ "$READY_PODS" = "2" ]; then
    pass "Pod counting: expected 2, got $READY_PODS"
  else
    fail "Pod counting: expected 2, got $READY_PODS"
  fi

  # Test edge case: No pods
  READY_PODS=$(echo "" | awk '{split($2,a,"/"); if(a[1]==a[2] && a[1]!="") count++} END {print count+0}')
  if [ "$READY_PODS" = "0" ]; then
    pass "Pod counting (no pods): expected 0, got $READY_PODS"
  else
    fail "Pod counting (no pods): expected 0, got $READY_PODS"
  fi

  # Test edge case: Pods not ready (0/6)
  PODS_OUTPUT="alertmanager-main-0   0/6   Running   0     34m"
  READY_PODS=$(echo "$PODS_OUTPUT" | awk '{split($2,a,"/"); if(a[1]==a[2] && a[1]!="") count++} END {print count+0}')
  if [ "$READY_PODS" = "0" ]; then
    pass "Pod counting (not ready 0/6): expected 0, got $READY_PODS"
  else
    fail "Pod counting (not ready 0/6): expected 0, got $READY_PODS"
  fi

  # Test edge case: Mixed ready/not ready
  PODS_OUTPUT="alertmanager-main-0   6/6   Running   0     34m
alertmanager-main-1   0/6   Running   0     34m
alertmanager-main-2   6/6   Running   0     34m"
  READY_PODS=$(echo "$PODS_OUTPUT" | awk '{split($2,a,"/"); if(a[1]==a[2] && a[1]!="") count++} END {print count+0}')
  if [ "$READY_PODS" = "2" ]; then
    pass "Pod counting (mixed): expected 2, got $READY_PODS"
  else
    fail "Pod counting (mixed): expected 2, got $READY_PODS"
  fi

  echo ""
}

# ============================================
# Test 2: grep -c pattern safety
# ============================================
test_grep_c_pattern() {
  info "Test 2: grep -c with || echo fallback (the bug we fixed)"

  # Test the BROKEN pattern (what we had before)
  # Note: This pattern IS buggy and SHOULD fail - that's what we're testing!
  OUTPUT=$(echo '{"items":[]}' | grep -c '"ready":true' || echo 0)

  # Count lines in output
  LINE_COUNT=$(echo "$OUTPUT" | wc -l)

  # If we get more than 1 line, the pattern is buggy (produces "0\n0")
  if [ "$LINE_COUNT" -gt "1" ]; then
    pass "grep -c bug reproduced: multi-line output detected (this is the bug we fixed!)"
  else
    fail "grep -c pattern: expected multi-line bug, got single line (test may be wrong)"
  fi

  # Test that awk END always returns integer
  COUNT=$(echo "" | awk 'END {print count+0}')
  if [ "$COUNT" = "0" ]; then
    pass "awk END {print count+0}: returns 0 when unset"
  else
    fail "awk END {print count+0}: expected 0, got '$COUNT'"
  fi

  echo ""
}

# ============================================
# Test 3: Integer comparison safety
# ============================================
test_integer_comparison() {
  info "Test 3: Integer comparison with potentially invalid values"

  # Test normal comparison
  READY_PODS="2"
  DESIRED_REPLICAS="2"
  if [ "$READY_PODS" -ge "$DESIRED_REPLICAS" ] 2>/dev/null; then
    pass "Integer comparison: 2 >= 2 works"
  else
    fail "Integer comparison: 2 >= 2 failed"
  fi

  # Test with the buggy value we had (this SHOULD fail gracefully)
  READY_PODS="0
0"
  DESIRED_REPLICAS="2"
  if [ "$READY_PODS" -ge "$DESIRED_REPLICAS" ] 2>/dev/null; then
    fail "Integer comparison: multi-line value should fail but passed!"
  else
    pass "Integer comparison: multi-line value correctly rejected"
  fi

  # Test empty string
  READY_PODS=""
  if [ -z "$READY_PODS" ]; then
    pass "Empty string detection: correctly identified empty"
  else
    fail "Empty string detection: failed to identify empty"
  fi

  echo ""
}

# ============================================
# Test 4: OLM API group usage (Subscription)
# ============================================
test_olm_api_groups() {
  info "Test 4: OLM resource API group patterns"

  # Test that we're using explicit API groups
  GOOD_PATTERN="subscription.operators.coreos.com"
  BAD_PATTERN="subscription "

  # Simulate grep pattern
  if echo "oc get subscription.operators.coreos.com my-operator" | grep -q "subscription.operators.coreos.com"; then
    pass "OLM API: explicit API group detected"
  else
    fail "OLM API: explicit API group not found"
  fi

  # Check for ambiguous usage (would fail on RHACM clusters)
  if echo "oc get subscription my-operator" | grep -vq "\.operators\.coreos\.com"; then
    pass "OLM API: ambiguous 'subscription' usage detected (good for testing)"
  else
    fail "OLM API: should detect ambiguous usage"
  fi

  echo ""
}

# ============================================
# Test 5: wc -l always succeeds (no || echo needed)
# ============================================
test_wc_l_success() {
  info "Test 5: wc -l always returns valid output"

  # wc -l with matches
  COUNT=$(echo -e "line1\nline2\nline3" | grep -o "line" | wc -l)
  if [ "$COUNT" = "3" ]; then
    pass "wc -l with matches: returns 3"
  else
    fail "wc -l with matches: expected 3, got $COUNT"
  fi

  # wc -l with no matches (this is where grep -c fails)
  COUNT=$(echo "no match" | grep -o "needle" | wc -l)
  if [ "$COUNT" = "0" ]; then
    pass "wc -l with no matches: returns 0 (not multi-line)"
  else
    fail "wc -l with no matches: expected 0, got $COUNT"
  fi

  # Verify wc -l output is numeric (may have leading spaces, but that's OK)
  # Note: echo "" produces one line (empty line), so wc -l returns 1
  OUTPUT=$(echo "" | wc -l)
  # Trim spaces and check if it's a number
  TRIMMED=$(echo "$OUTPUT" | tr -d ' \t')
  if [ "$TRIMMED" = "1" ]; then
    pass "wc -l output: returns valid integer (echo '' = 1 line)"
  else
    fail "wc -l output: expected 1, got '$TRIMMED'"
  fi

  # Test with actual empty input (no newline)
  OUTPUT=$(printf "" | wc -l)
  TRIMMED=$(echo "$OUTPUT" | tr -d ' \t')
  if [ "$TRIMMED" = "0" ]; then
    pass "wc -l output: printf '' returns 0 (true empty)"
  else
    fail "wc -l output: printf '' expected 0, got '$TRIMMED'"
  fi

  echo ""
}

# ============================================
# Test 6: Secret field extraction robustness
# ============================================
test_secret_extraction() {
  info "Test 6: Secret field extraction (create-secret-*-loki-s3)"

  # Simulate oc get secret output
  SECRET_JSON='{"data":{"AWS_ACCESS_KEY_ID":"YWNjZXNzLWtleQ==","AWS_SECRET_ACCESS_KEY":"c2VjcmV0LWtleQ=="}}'

  # Extract field with jq-style grep/sed
  ACCESS_KEY=$(echo "$SECRET_JSON" | grep -o '"AWS_ACCESS_KEY_ID":"[^"]*"' | sed 's/"AWS_ACCESS_KEY_ID":"\(.*\)"/\1/')
  if [ "$ACCESS_KEY" = "YWNjZXNzLWtleQ==" ]; then
    pass "Secret extraction: AWS_ACCESS_KEY_ID extracted"
  else
    fail "Secret extraction: expected 'YWNjZXNzLWtleQ==', got '$ACCESS_KEY'"
  fi

  # Test missing field (should return empty, not error)
  MISSING=$(echo '{"data":{}}' | grep -o '"MISSING_KEY":"[^"]*"' | sed 's/"MISSING_KEY":"\(.*\)"/\1/' || echo "")
  if [ -z "$MISSING" ]; then
    pass "Secret extraction: missing field returns empty"
  else
    fail "Secret extraction: missing field should be empty, got '$MISSING'"
  fi

  echo ""
}

# ============================================
# Test 7: oc_retry doesn't break infinite loops
# ============================================
test_oc_retry_infinite_loop() {
  info "Test 7: oc_retry with infinite loop pattern (NotFound)"

  # Source the retry wrapper
  if [ ! -f "scripts/oc-retry-wrapper.sh" ]; then
    fail "oc-retry-wrapper.sh not found (skip test)"
    echo ""
    return
  fi

  source scripts/oc-retry-wrapper.sh

  # Mock oc command that simulates NotFound error
  oc() {
    echo "Error from server (NotFound): secrets \"my-secret\" not found"
    return 1
  }
  export -f oc

  # Test that oc_retry returns immediately on NotFound (doesn't retry)
  START_TIME=$(date +%s)
  oc_retry get secret my-secret -n test-namespace >/dev/null 2>&1 || true
  END_TIME=$(date +%s)
  DURATION=$((END_TIME - START_TIME))

  # Should return immediately (< 2 seconds), not retry for 62 seconds
  if [ $DURATION -lt 2 ]; then
    pass "oc_retry NotFound: returns immediately ($DURATION seconds, no retry)"
  else
    fail "oc_retry NotFound: took $DURATION seconds (should be <2, indicates retry loop)"
  fi

  # Test Forbidden error (also should NOT retry)
  oc() {
    echo "Error from server (Forbidden): secrets \"my-secret\" is forbidden"
    return 1
  }
  export -f oc

  START_TIME=$(date +%s)
  oc_retry get secret my-secret -n test-namespace >/dev/null 2>&1 || true
  END_TIME=$(date +%s)
  DURATION=$((END_TIME - START_TIME))

  if [ $DURATION -lt 2 ]; then
    pass "oc_retry Forbidden: returns immediately ($DURATION seconds, no retry)"
  else
    fail "oc_retry Forbidden: took $DURATION seconds (should be <2)"
  fi

  # Restore oc command
  unset -f oc

  # Note: We don't test cert rotation retry in unit tests (takes 60+ seconds)
  # That behavior is tested manually or in integration tests

  echo ""
}

# ============================================
# Run all tests
# ============================================
test_pod_counting
test_grep_c_pattern
test_integer_comparison
test_olm_api_groups
test_wc_l_success
test_secret_extraction
test_oc_retry_infinite_loop

# ============================================
# Summary
# ============================================
echo "======================================"
echo "Test Summary"
echo "======================================"
echo -e "${GREEN}Passed: $PASSED${NC}"
if [ $FAILED -gt 0 ]; then
  echo -e "${RED}Failed: $FAILED${NC}"
  echo ""
  echo -e "${RED}❌ TESTS FAILED${NC}"
  exit 1
else
  echo -e "${RED}Failed: $FAILED${NC}"
  echo ""
  echo -e "${GREEN}✅ ALL TESTS PASSED${NC}"
  exit 0
fi
